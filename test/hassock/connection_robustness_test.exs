defmodule Hassock.ConnectionDownTest do
  # Not async: free_port/0 is only free while no other test's server can
  # bind it.
  use ExUnit.Case, async: false

  import Hassock.TestHelpers
  alias Hassock.{Connection, FakeHA}

  test "start_link returns at once and connects when HA comes up" do
    port = FakeHA.free_port()
    {:ok, conn} = Connection.start_link(config: FakeHA.config(port))

    assert_receive {:hassock, ^conn, {:disconnected, _reason}}, 1_000
    assert %{status: status} = Connection.status(conn)
    assert status in [:waiting, :connecting]

    ha = FakeHA.start(port: port)
    on_exit(fn -> FakeHA.stop(ha) end)
    await_auth(conn)
    assert %{status: :connected, next_retry_in: nil, attempt: attempt} = Connection.status(conn)
    assert attempt >= 1
  end

  test "sends one :disconnected per outage, not one per attempt" do
    port = FakeHA.free_port()
    {:ok, conn} = Connection.start_link(config: FakeHA.config(port, backoff_max: 20))

    assert_receive {:hassock, ^conn, {:disconnected, _}}, 1_000
    wait_until(fn -> Connection.status(conn).attempt >= 4 end)
    refute_received {:hassock, ^conn, {:disconnected, _}}
  end

  test "status reports the next retry while waiting" do
    port = FakeHA.free_port()

    config = FakeHA.config(port, backoff_initial: 5_000, backoff_max: 5_000)
    {:ok, conn} = Connection.start_link(config: config)
    assert_receive {:hassock, ^conn, {:disconnected, _}}, 1_000

    assert %{status: :waiting, attempt: 1, next_retry_in: ms} = Connection.status(conn)
    assert ms > 1_000 and ms <= 5_000
    assert {:error, :not_connected} = Hassock.command(conn, "get_config")
  end
end

defmodule Hassock.ConnectionRobustnessTest do
  use ExUnit.Case, async: true

  import Hassock.TestHelpers
  alias Hassock.{Connection, FakeHA}

  describe "configuration" do
    test "rejects invalid timings" do
      Process.flag(:trap_exit, true)
      config = FakeHA.config(1, backoff_initial: 0)

      assert {:error, {:invalid_config, :backoff_initial}} =
               Connection.start_link(config: config)
    end

    test ":to must be a pid" do
      %{conn: conn} = connect()

      assert_raise ArgumentError, fn ->
        Hassock.subscribe_events(conn, "x", to: :not_a_pid)
      end
    end
  end

  describe "reconnecting" do
    test "re-authenticates after the socket drops" do
      %{conn: conn, sock: sock} = connect()
      FakeHA.close(sock)

      assert_receive {:hassock, ^conn, {:disconnected, _}}, 1_000
      sock2 = await_auth(conn)
      assert sock2 != sock
      assert %{status: :connected} = Connection.status(conn)
    end

    test "keeps backing off when the server drops the link right after auth" do
      %{conn: conn, sock: sock} = connect(backoff_initial: 20, backoff_max: 5_000)

      Enum.reduce(1..3, sock, fn _, sock ->
        FakeHA.close(sock)
        await_auth(conn)
      end)

      assert %{status: :connected, attempt: 3} = Connection.status(conn)
    end

    test "resets the attempt count once a connection stayed up for backoff_max" do
      %{conn: conn, sock: sock} = connect(backoff_initial: 10, backoff_max: 50)
      FakeHA.close(sock)
      sock = await_auth(conn)
      FakeHA.close(sock)
      sock = await_auth(conn)
      assert %{attempt: 2} = Connection.status(conn)

      Process.sleep(80)
      FakeHA.close(sock)
      await_auth(conn)
      assert %{attempt: 1} = Connection.status(conn)
    end

    test "message ids keep increasing across connections" do
      %{conn: conn, sock: sock} = connect()
      task = Task.async(fn -> Hassock.command(conn, "a") end)
      assert_receive {:fake_ha, ^sock, %{"id" => first}}, 1_000
      FakeHA.result(sock, first, nil)
      Task.await(task)

      FakeHA.close(sock)
      sock2 = await_auth(conn)
      task = Task.async(fn -> Hassock.command(conn, "b") end)
      assert_receive {:fake_ha, ^sock2, %{"id" => second}}, 1_000
      FakeHA.result(sock2, second, nil)
      Task.await(task)
      assert second > first
    end

    test "auth_invalid stops retrying" do
      ha = FakeHA.start()
      on_exit(fn -> FakeHA.stop(ha) end)
      {:ok, conn} = Connection.start_link(config: FakeHA.config(ha.port, token: "bad"))

      assert_receive {:hassock, ^conn, {:auth_failed, "Invalid access token"}}, 1_000
      assert_receive {:fake_ha, _sock, :open}
      refute_receive {:fake_ha, _sock, :open}, 300
      refute_received {:hassock, ^conn, {:disconnected, _}}
      assert %{status: :auth_failed, next_retry_in: nil} = Connection.status(conn)
    end

    test "an attempt that never authenticates is abandoned after connect_timeout" do
      ha = FakeHA.start(hold_auth: true)
      on_exit(fn -> FakeHA.stop(ha) end)
      config = FakeHA.config(ha.port, connect_timeout: 150)
      {:ok, conn} = Connection.start_link(config: config)

      assert_receive {:fake_ha, sock, :open}, 1_000
      wait_until(fn -> Connection.status(conn).status == :authenticating end)
      assert Hassock.command(conn, "get_config") == {:error, :not_connected}

      assert_receive {:hassock, ^conn, {:disconnected, :connect_timeout}}, 1_000
      assert_receive {:fake_ha, sock2, :open}, 1_000
      assert sock2 != sock

      FakeHA.release_auth(sock2)
      assert_receive {:fake_ha, ^sock2, :authenticated}, 1_000
      assert_receive {:hassock, ^conn, :connected}, 1_000
    end
  end

  describe "keepalive" do
    test "pings while connected and stays up while HA answers" do
      %{conn: conn, sock: sock} = connect(ping_interval: 30, ping_timeout: 30)

      for _ <- 1..5, do: assert_receive({:fake_ha, ^sock, %{"type" => "ping"}}, 500)

      refute_received {:hassock, ^conn, {:disconnected, _}}
      # No reconnect happened (await_auth consumed the first :open).
      assert count_messages(&match?({:fake_ha, _, :open}, &1)) == 0
      assert Hassock.connected?(conn)
    end

    test "reconnects when the pong doesn't come" do
      %{conn: conn, sock: sock} = connect(ping_interval: 30, ping_timeout: 50)
      FakeHA.auto_pong(sock, false)

      assert_receive {:hassock, ^conn, {:disconnected, :ping_timeout}}, 1_000
      assert await_auth(conn) != sock
    end

    test "a ping sent with command/4 gets its pong, which doesn't count for the keepalive" do
      %{conn: conn, sock: sock} = connect(ping_interval: 30, ping_timeout: 150)
      FakeHA.auto_pong(sock, false)
      assert_receive {:fake_ha, ^sock, %{"type" => "ping", "id" => _keepalive}}, 500

      task = Task.async(fn -> Hassock.command(conn, "ping") end)
      assert_receive {:fake_ha, ^sock, %{"type" => "ping", "id" => id}}, 500
      FakeHA.push(sock, %{id: id, type: "pong"})
      assert Task.await(task) == {:ok, nil}

      assert_receive {:hassock, ^conn, {:disconnected, :ping_timeout}}, 1_000
    end

    test "an unsolicited pong doesn't start a second ping cycle" do
      %{sock: sock} = connect(ping_interval: 100, ping_timeout: 1_000)
      for id <- 1..5, do: FakeHA.push(sock, %{id: 1_000 + id, type: "pong"})

      # One cycle pings at ~100, ~200 and ~300 ms.
      Process.sleep(350)
      assert count_messages(&match?({:fake_ha, ^sock, %{"type" => "ping"}}, &1)) in 2..4
    end
  end

  describe "subscriptions across reconnects" do
    test "are restored with a stable id, and events keep flowing" do
      %{conn: conn, sock: sock} = connect()

      {ent_id, _} = subscribe(conn, sock, &Hassock.subscribe_entities(&1, ["light.a"]))
      subscribe(conn, sock, &Hassock.subscribe_events(&1, "call_service"))

      FakeHA.close(sock)
      sock2 = await_auth(conn)

      assert_receive {:fake_ha, ^sock2, %{"type" => "subscribe_entities", "id" => new_ent} = m1},
                     1_000

      assert m1["entity_ids"] == ["light.a"]

      assert_receive {:fake_ha, ^sock2,
                      %{
                        "type" => "subscribe_events",
                        "id" => new_ev,
                        "event_type" => "call_service"
                      }},
                     1_000

      FakeHA.result(sock2, new_ent, nil)
      FakeHA.result(sock2, new_ev, nil)

      FakeHA.event(sock2, new_ent, %{a: %{"light.a" => %{s: "on", a: %{}}}})
      assert_receive {:hassock, ^conn, {:event, {:entities, %{added: %{"light.a" => _}}}}}, 1_000

      FakeHA.event(sock2, new_ev, %{event_type: "call_service", data: %{}})
      assert_receive {:hassock, ^conn, {:event, {:other, "call_service", _}}}, 1_000

      # Unsubscribing by the original id cancels the current HA subscription.
      task = Task.async(fn -> Hassock.unsubscribe_events(conn, ent_id) end)

      assert_receive {:fake_ha, ^sock2,
                      %{"type" => "unsubscribe_events", "subscription" => ^new_ent, "id" => id}},
                     1_000

      FakeHA.result(sock2, id, nil)
      assert Task.await(task) == :ok

      # Only the events subscription comes back after the next reconnect.
      FakeHA.close(sock2)
      sock3 = await_auth(conn)
      assert_receive {:fake_ha, ^sock3, %{"type" => "subscribe_events"}}, 1_000
      refute_receive {:fake_ha, ^sock3, %{"type" => "subscribe_entities"}}, 200
    end

    test "unsubscribing while disconnected forgets the subscription" do
      %{conn: conn, sock: sock} = connect(backoff_initial: 5_000, backoff_max: 5_000)
      {sub_id, _} = subscribe(conn, sock, &Hassock.subscribe_events(&1, "x"))

      FakeHA.close(sock)
      assert_receive {:hassock, ^conn, {:disconnected, _}}, 1_000
      assert Hassock.unsubscribe_events(conn, sub_id) == :ok
      assert {:error, %{"code" => "not_found"}} = Hassock.unsubscribe_events(conn, sub_id)
    end

    test "events still in flight after an unsubscribe are dropped" do
      %{conn: conn, sock: sock} = connect()
      {sub_id, _} = subscribe(conn, sock, &Hassock.subscribe_events(&1, "x"))

      task = Task.async(fn -> Hassock.unsubscribe_events(conn, sub_id) end)
      assert_receive {:fake_ha, ^sock, %{"type" => "unsubscribe_events", "id" => id}}, 1_000
      FakeHA.event(sock, sub_id, %{event_type: "x", data: %{}})
      FakeHA.result(sock, id, nil)
      assert Task.await(task) == :ok

      refute_receive {:hassock, ^conn, {:event, _}}, 100
    end

    test "a subscription HA refuses to restore is dropped and reported" do
      %{conn: conn, sock: sock} = connect()
      {sub_id, _} = subscribe(conn, sock, &Hassock.subscribe_events(&1, "x"))

      FakeHA.close(sock)
      sock2 = await_auth(conn)
      assert_receive {:fake_ha, ^sock2, %{"type" => "subscribe_events", "id" => id}}, 1_000
      FakeHA.error(sock2, id, "unauthorized", "Unauthorized")

      assert_receive {:hassock, ^conn,
                      {:subscription_lost, ^sub_id, %{"code" => "unauthorized"}}},
                     1_000

      FakeHA.close(sock2)
      sock3 = await_auth(conn)
      refute_receive {:fake_ha, ^sock3, %{"type" => "subscribe_events"}}, 200
    end

    test "a restore HA never answers re-makes the connection and keeps the subscription" do
      %{conn: conn, sock: sock} = connect(connect_timeout: 200)
      {_sub_id, _} = subscribe(conn, sock, &Hassock.subscribe_events(&1, "x"))

      FakeHA.close(sock)
      sock2 = await_auth(conn)
      assert_receive {:fake_ha, ^sock2, %{"type" => "subscribe_events"}}, 1_000

      assert_receive {:hassock, ^conn, {:disconnected, :resubscribe_timeout}}, 1_000
      sock3 = await_auth(conn)
      assert_receive {:fake_ha, ^sock3, %{"type" => "subscribe_events"}}, 1_000
    end

    test "unsubscribing while its restore is pending doesn't later drop the connection" do
      %{conn: conn, sock: sock} = connect(connect_timeout: 200)
      {sub_id, _} = subscribe(conn, sock, &Hassock.subscribe_events(&1, "x"))

      FakeHA.close(sock)
      assert_receive {:hassock, ^conn, {:disconnected, _}}, 1_000
      sock2 = await_auth(conn)
      assert_receive {:fake_ha, ^sock2, %{"type" => "subscribe_events", "id" => restore}}, 1_000

      task = Task.async(fn -> Hassock.unsubscribe_events(conn, sub_id) end)

      assert_receive {:fake_ha, ^sock2,
                      %{"type" => "unsubscribe_events", "subscription" => ^restore, "id" => id}},
                     1_000

      FakeHA.result(sock2, id, nil)
      assert Task.await(task) == :ok

      refute_receive {:hassock, ^conn, {:disconnected, :resubscribe_timeout}}, 400
    end

    test "a subscribe that completes after the caller timed out is cancelled" do
      %{conn: conn, sock: sock} = connect()

      assert {:error, :timeout} = Hassock.subscribe_events(conn, "x", timeout: 50)
      assert_receive {:fake_ha, ^sock, %{"type" => "subscribe_events", "id" => id}}

      FakeHA.result(sock, id, nil)

      assert_receive {:fake_ha, ^sock, %{"type" => "unsubscribe_events", "subscription" => ^id}},
                     1_000

      FakeHA.event(sock, id, %{event_type: "x", data: %{}})
      refute_receive {:hassock, ^conn, {:event, _}}, 100

      FakeHA.close(sock)
      sock2 = await_auth(conn)
      refute_receive {:fake_ha, ^sock2, %{"type" => "subscribe_events"}}, 200
    end

    test "a subscribe HA never answers re-makes the connection after a grace period" do
      %{conn: conn, sock: sock} = connect(connect_timeout: 200)

      assert {:error, :timeout} = Hassock.subscribe_events(conn, "x", timeout: 50)
      assert_receive {:fake_ha, ^sock, %{"type" => "subscribe_events"}}

      assert_receive {:hassock, ^conn, {:disconnected, :subscribe_timeout}}, 1_000
      await_auth(conn)
    end

    test "a subscribe granted after its caller died is cancelled" do
      %{conn: conn, sock: sock} = connect()

      caller = spawn(fn -> Hassock.subscribe_events(conn, "x") end)
      assert_receive {:fake_ha, ^sock, %{"type" => "subscribe_events", "id" => id}}
      ref = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}

      FakeHA.result(sock, id, nil)

      assert_receive {:fake_ha, ^sock, %{"type" => "unsubscribe_events", "subscription" => ^id}},
                     1_000

      FakeHA.event(sock, id, %{event_type: "x", data: %{}})
      refute_receive {:hassock, ^conn, {:event, _}}, 100
    end

    test "a subscribe whose caller died is cancelled after the expiry" do
      %{conn: conn, sock: sock} = connect()

      caller = spawn(fn -> Hassock.subscribe_events(conn, "x", timeout: 50) end)
      assert_receive {:fake_ha, ^sock, %{"type" => "subscribe_events", "id" => id}}
      Process.exit(caller, :kill)

      # The connection's own expiry (timeout + 1 s) marks it cancelled.
      Process.sleep(1_150)
      FakeHA.result(sock, id, nil)

      assert_receive {:fake_ha, ^sock, %{"type" => "unsubscribe_events", "subscription" => ^id}},
                     1_000
    end
  end

  describe "failed unsubscribes" do
    test "events of a :to subscriber whose unsubscribe failed stay dropped" do
      %{conn: conn, sock: sock} = connect()
      test = self()

      subscriber =
        spawn(fn ->
          send(test, {:subscribed, Hassock.subscribe_events(conn, "x", to: self())})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:fake_ha, ^sock, %{"type" => "subscribe_events", "id" => id}}, 1_000
      FakeHA.result(sock, id, nil)
      assert_receive {:subscribed, {:ok, ^id}}

      send(subscriber, :stop)

      assert_receive {:fake_ha, ^sock,
                      %{"type" => "unsubscribe_events", "subscription" => ^id, "id" => unsub}},
                     1_000

      FakeHA.error(sock, unsub, "home_assistant_error", "busy")
      FakeHA.event(sock, id, %{event_type: "x", data: %{}})
      refute_receive {:hassock, ^conn, {:event, _}}, 100
    end
  end

  describe "ownership" do
    test "only the controller can hand over control" do
      %{conn: conn} = connect()
      test = self()

      spawn(fn -> send(test, {:result, Connection.controlling_process(conn, self())}) end)
      assert_receive {:result, {:error, :not_owner}}

      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, _, _, _}
      assert Connection.controlling_process(conn, dead) == {:error, :not_alive}
    end

    test "controller subscriptions follow a handover" do
      %{conn: conn, sock: sock} = connect()
      {sub_id, _} = subscribe(conn, sock, &Hassock.subscribe_events(&1, "x"))
      test = self()

      new_owner =
        spawn(fn ->
          receive do
            {:hassock, ^conn, msg} -> send(test, {:new_owner_got, msg})
          end
        end)

      assert :ok = Connection.controlling_process(conn, new_owner)
      FakeHA.event(sock, sub_id, %{event_type: "x", data: %{}})
      assert_receive {:new_owner_got, {:event, {:other, "x", _}}}, 1_000
      refute_receive {:hassock, ^conn, {:event, _}}, 100
    end

    test "anyone can take over once the controller has exited" do
      ha = FakeHA.start()
      on_exit(fn -> FakeHA.stop(ha) end)
      owner = spawn(fn -> receive do: (:stop -> :ok) end)
      {:ok, conn} = Connection.start_link(config: FakeHA.config(ha.port), controlling_pid: owner)
      assert_receive {:fake_ha, sock, :authenticated}, 1_000

      ref = Process.monitor(owner)
      send(owner, :stop)
      assert_receive {:DOWN, ^ref, _, _, _}

      wait_until(fn -> Connection.controlling_process(conn, self()) == :ok end)
      FakeHA.close(sock)
      assert_receive {:hassock, ^conn, {:disconnected, _}}, 1_000
    end
  end

  describe "routing" do
    test "a :to subscription delivers to that pid and is cancelled when it exits" do
      %{conn: conn, sock: sock} = connect()
      test = self()

      subscriber =
        spawn(fn ->
          send(test, {:subscribed, Hassock.subscribe_events(conn, "x", to: self())})

          receive do
            {:hassock, ^conn, event} -> send(test, {:subscriber_got, event})
          end

          receive do: (:stop -> :ok)
        end)

      assert_receive {:fake_ha, ^sock, %{"type" => "subscribe_events", "id" => id}}, 1_000
      FakeHA.result(sock, id, nil)
      assert_receive {:subscribed, {:ok, ^id}}

      FakeHA.event(sock, id, %{event_type: "x", data: %{}})
      assert_receive {:subscriber_got, {:event, {:other, "x", _}}}, 1_000
      refute_receive {:hassock, ^conn, {:event, _}}, 100

      send(subscriber, :stop)

      assert_receive {:fake_ha, ^sock, %{"type" => "unsubscribe_events", "subscription" => ^id}},
                     1_000

      # Its late events don't fall through to the controller.
      FakeHA.event(sock, id, %{event_type: "x", data: %{}})
      refute_receive {:hassock, ^conn, {:event, _}}, 100
    end

    test "watchers get lifecycle messages until they unwatch" do
      %{conn: conn, sock: sock} = connect()
      test = self()

      watcher =
        spawn(fn ->
          send(test, {:watching, Connection.watch(conn)})
          relay(test, conn)
        end)

      assert_receive {:watching, {:ok, :connected}}
      FakeHA.close(sock)
      assert_receive {:watcher, {:disconnected, _}}, 1_000
      assert_receive {:watcher, :connected}, 2_000
      sock2 = await_auth(conn)

      send(watcher, :unwatch)
      assert_receive :unwatched
      FakeHA.close(sock2)
      assert_receive {:hassock, ^conn, {:disconnected, _}}, 1_000
      refute_receive {:watcher, _}, 200
    end
  end

  defp relay(test, conn) do
    receive do
      :unwatch ->
        :ok = Connection.unwatch(conn)
        send(test, :unwatched)

      {:hassock, ^conn, msg} ->
        send(test, {:watcher, msg})
    end

    relay(test, conn)
  end
end
