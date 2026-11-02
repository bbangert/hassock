defmodule Hassock.ConnectionTest do
  use ExUnit.Case, async: true

  import Hassock.TestHelpers
  alias Hassock.{Connection, EntityState, FakeHA, ServiceCall}

  # Run a blocking call in a task and return the command HA received for it.
  defp call_async(fun) do
    task = Task.async(fun)
    assert_receive {:fake_ha, _sock, %{"id" => _} = msg}, 1_000
    {task, msg}
  end

  # A process that forwards everything it receives to the test.
  defp forwarder do
    test = self()
    spawn_link(fn -> forward(test) end)
  end

  defp forward(test) do
    receive do
      msg -> send(test, {:forwarded, msg})
    end

    forward(test)
  end

  describe "command/4" do
    setup do: connect()

    test "returns an entity registry list as-is, not as states", %{conn: conn, sock: sock} do
      entries = [%{"entity_id" => "light.kitchen", "platform" => "hue", "hidden_by" => nil}]

      {task, msg} = call_async(fn -> Hassock.command(conn, "config/entity_registry/list") end)
      assert %{"type" => "config/entity_registry/list", "id" => id} = msg

      FakeHA.result(sock, id, entries)
      assert Task.await(task) == {:ok, entries}
    end

    test "returns an empty list result", %{conn: conn, sock: sock} do
      {task, %{"id" => id}} =
        call_async(fn -> Hassock.command(conn, "config/label_registry/list") end)

      FakeHA.result(sock, id, [])
      assert Task.await(task) == {:ok, []}
    end

    test "merges the payload; id and type can't be overridden", %{conn: conn, sock: sock} do
      {task, msg} =
        call_async(fn ->
          Hassock.command(conn, "render_template", %{:template => "x", "id" => 0, type: "nope"})
        end)

      assert %{"type" => "render_template", "template" => "x", "id" => id} = msg
      assert id > 0
      FakeHA.result(sock, id, nil)
      assert Task.await(task) == {:ok, nil}
    end

    test "returns HA errors", %{conn: conn, sock: sock} do
      {task, %{"id" => id}} = call_async(fn -> Hassock.command(conn, "bogus") end)
      FakeHA.error(sock, id, "unknown_command", "Unknown command.")

      assert Task.await(task) ==
               {:error, %{"code" => "unknown_command", "message" => "Unknown command."}}
    end

    test "times out after :timeout", %{conn: conn} do
      assert {:error, :timeout} = Hassock.command(conn, "slow", %{}, timeout: 50)
    end

    test "fails in-flight commands with :disconnected", %{conn: conn, sock: sock} do
      {task, _msg} = call_async(fn -> Hassock.command(conn, "slow") end)
      FakeHA.close(sock)
      assert Task.await(task) == {:error, :disconnected}
    end
  end

  describe "fixed commands" do
    setup do: connect()

    test "get_states decodes entity states", %{conn: conn, sock: sock} do
      {task, %{"type" => "get_states", "id" => id}} =
        call_async(fn -> Hassock.get_states(conn) end)

      FakeHA.result(sock, id, [%{entity_id: "sun.sun", state: "above_horizon", attributes: %{}}])

      assert {:ok, [%EntityState{entity_id: "sun.sun", state: "above_horizon"}]} =
               Task.await(task)
    end

    test "get_states reports a result that isn't a list", %{conn: conn, sock: sock} do
      {task, %{"id" => id}} = call_async(fn -> Hassock.get_states(conn) end)
      FakeHA.result(sock, id, %{"not" => "a list"})
      assert Task.await(task) == {:error, {:unexpected_result, %{"not" => "a list"}}}
      assert Hassock.connected?(conn)
    end

    test "get_services reports a domain whose services aren't a map", %{conn: conn, sock: sock} do
      {task, %{"id" => id}} = call_async(fn -> Hassock.get_services(conn) end)
      FakeHA.result(sock, id, %{"light" => nil})
      assert {:error, {:unexpected_result, %{"light" => nil}}} = Task.await(task)
      assert Hassock.connected?(conn)
    end

    test "get_states reports entries without a string entity_id", %{conn: conn, sock: sock} do
      {task, %{"id" => id}} = call_async(fn -> Hassock.get_states(conn) end)
      FakeHA.result(sock, id, [%{"entity_id" => 123, "state" => "on"}])
      assert {:error, {:unexpected_result, _}} = Task.await(task)
      assert Hassock.connected?(conn)
    end

    test "get_states decodes an empty list", %{conn: conn, sock: sock} do
      {task, %{"id" => id}} = call_async(fn -> Hassock.get_states(conn) end)
      FakeHA.result(sock, id, [])
      assert Task.await(task) == {:ok, []}
    end

    test "get_services decodes to sorted service names", %{conn: conn, sock: sock} do
      {task, %{"type" => "get_services", "id" => id}} =
        call_async(fn -> Hassock.get_services(conn) end)

      FakeHA.result(sock, id, %{light: %{turn_on: %{}, toggle: %{}}})
      assert Task.await(task) == {:ok, %{"light" => ["toggle", "turn_on"]}}
    end

    test "call_service sends return_response and returns the response", %{conn: conn, sock: sock} do
      call = %ServiceCall{
        domain: "weather",
        service: "get_forecasts",
        target: %{entity_id: "weather.home"},
        service_data: %{type: "daily"},
        return_response: true
      }

      {task, msg} = call_async(fn -> Hassock.call_service(conn, call) end)

      assert %{
               "type" => "call_service",
               "domain" => "weather",
               "service" => "get_forecasts",
               "target" => %{"entity_id" => "weather.home"},
               "service_data" => %{"type" => "daily"},
               "return_response" => true,
               "id" => id
             } = msg

      FakeHA.result(sock, id, %{context: %{id: "c"}, response: %{"weather.home" => %{}}})
      assert {:ok, %{"response" => %{"weather.home" => %{}}}} = Task.await(task)
    end

    test "call_service omits return_response by default", %{conn: conn, sock: sock} do
      call = %ServiceCall{domain: "light", service: "toggle"}
      {task, msg} = call_async(fn -> Hassock.call_service(conn, call) end)
      refute Map.has_key?(msg, "return_response")
      FakeHA.result(sock, msg["id"], %{context: %{id: "c"}})
      assert {:ok, %{"context" => _}} = Task.await(task)
    end
  end

  describe "events" do
    setup do: connect()

    test "registry update events arrive typed", %{conn: conn, sock: sock} do
      {task, %{"id" => id, "event_type" => "area_registry_updated"}} =
        call_async(fn -> Hassock.subscribe_events(conn, "area_registry_updated") end)

      FakeHA.result(sock, id, nil)
      assert {:ok, ^id} = Task.await(task)

      FakeHA.event(sock, id, %{
        event_type: "area_registry_updated",
        data: %{action: "create", area_id: "porch"}
      })

      assert_receive {:hassock, ^conn, {:event, {:registry_updated, :area, :create, "porch"}}}
    end

    test "a malformed registry event doesn't disturb commands in flight",
         %{conn: conn, sock: sock} do
      {task, %{"id" => id}} = call_async(fn -> Hassock.command(conn, "get_config") end)
      FakeHA.event(sock, 99, %{event_type: "area_registry_updated", data: 42})
      FakeHA.result(sock, id, %{"version" => "2026.10.0"})
      assert {:ok, %{"version" => _}} = Task.await(task)
    end

    test "events of a subscription made with command/4 keep their body",
         %{conn: conn, sock: sock} do
      {task, %{"id" => id, "type" => "render_template"}} =
        call_async(fn -> Hassock.command(conn, "render_template", %{template: "{{ 1 }}"}) end)

      FakeHA.result(sock, id, nil)
      assert Task.await(task) == {:ok, nil}

      FakeHA.event(sock, id, %{result: "1", listeners: %{all: false}})
      assert_receive {:hassock, ^conn, {:event, {:other, nil, %{"result" => "1"}}}}, 1_000
    end

    test "undecodable frames are dropped without crashing", %{conn: conn, sock: sock} do
      FakeHA.push_raw(sock, "{not json")
      {task, %{"id" => id}} = call_async(fn -> Hassock.command(conn, "get_config") end)
      FakeHA.result(sock, id, %{"version" => "2026.10.0"})
      assert {:ok, %{"version" => _}} = Task.await(task)
      assert Hassock.connected?(conn)
    end
  end

  describe "before auth" do
    test "commands return :not_connected" do
      ha = FakeHA.start(hold_auth: true)
      on_exit(fn -> FakeHA.stop(ha) end)
      {:ok, conn} = Connection.start_link(config: FakeHA.config(ha.port))
      assert_receive {:fake_ha, _sock, :open}, 1_000

      assert Hassock.command(conn, "get_config") == {:error, :not_connected}
      assert Hassock.lovelace_dashboards(conn) == {:error, :not_connected}
      assert Hassock.lovelace_config(conn, nil) == {:error, :not_connected}
      assert Hassock.subscribe_template(conn, "{{ 1 }}") == {:error, :not_connected}
      refute Hassock.connected?(conn)
    end

    test "a missing named connection returns an error instead of raising" do
      assert {:error, {:connection_down, :noproc}} = Hassock.command(:no_such_conn, "get_config")
    end
  end

  describe "lovelace" do
    setup do: connect()

    test "a strategy config shaped like get_services reaches the caller unchanged",
         %{conn: conn, sock: sock} do
      config = %{"strategy" => %{"options" => %{"areas" => %{}}, "type" => "original-states"}}

      {task, msg} = call_async(fn -> Hassock.lovelace_config(conn, "dashboard-energy") end)

      assert %{"type" => "lovelace/config", "url_path" => "dashboard-energy", "force" => false} =
               msg

      FakeHA.result(sock, msg["id"], config)
      assert Task.await(task) == {:ok, config}
    end

    test "a nil url_path asks for the default dashboard, with :force", %{conn: conn, sock: sock} do
      {task, msg} = call_async(fn -> Hassock.lovelace_config(conn, nil, force: true) end)
      assert %{"type" => "lovelace/config", "force" => true} = msg
      refute Map.has_key?(msg, "url_path")
      FakeHA.error(sock, msg["id"], "config_not_found", "No config found.")
      assert {:error, %{"code" => "config_not_found"}} = Task.await(task)
    end

    test "a dashboard list is returned as maps", %{conn: conn, sock: sock} do
      {task, %{"type" => "lovelace/dashboards/list", "id" => id}} =
        call_async(fn -> Hassock.lovelace_dashboards(conn) end)

      FakeHA.result(sock, id, [
        %{id: "dashboard_energy", url_path: "dashboard-energy", mode: "storage"}
      ])

      assert {:ok, [%{"url_path" => "dashboard-energy", "mode" => "storage"}]} = Task.await(task)
    end

    test ":timeout bounds the wait", %{conn: conn} do
      assert Hassock.lovelace_dashboards(conn, timeout: 50) == {:error, :timeout}
      assert Hassock.lovelace_config(conn, nil, timeout: 50) == {:error, :timeout}
      assert Hassock.connected?(conn)
    end
  end

  describe "template subscriptions" do
    setup do: connect()

    test "sends the template and its options, and routes its events",
         %{conn: conn, sock: sock} do
      {id, msg} =
        subscribe(conn, sock, fn c ->
          Hassock.subscribe_template(c, "{{ x }}",
            variables: %{x: 1},
            render_timeout: 3,
            report_errors: true
          )
        end)

      assert %{
               "type" => "render_template",
               "template" => "{{ x }}",
               "variables" => %{"x" => 1},
               "timeout" => 3,
               "report_errors" => true
             } = msg

      FakeHA.event(sock, id, %{result: "Aan", listeners: %{all: false}})
      assert_receive {:hassock, ^conn, {:event, {:template, ^id, %{result: "Aan"}}}}, 1_000
    end

    test "an error event before the subscribe result is still a template event",
         %{conn: conn, sock: sock} do
      {task, %{"id" => id}} =
        call_async(fn -> Hassock.subscribe_template(conn, "{{ x }}", report_errors: true) end)

      FakeHA.event(sock, id, %{error: "boom", level: "WARNING"})
      FakeHA.result(sock, id, nil)
      assert {:ok, ^id} = Task.await(task)

      assert_receive {:hassock, ^conn,
                      {:event, {:template, ^id, %{error: "boom", level: "WARNING"}}}},
                     1_000
    end

    test "a failed subscribe returns HA's error", %{conn: conn, sock: sock} do
      {task, %{"id" => id}} = call_async(fn -> Hassock.subscribe_template(conn, "{{") end)
      FakeHA.error(sock, id, "template_error", "bad")
      assert {:error, %{"code" => "template_error"}} = Task.await(task)
    end

    test "unsubscribing drops its in-flight events", %{conn: conn, sock: sock} do
      {id, _msg} = subscribe(conn, sock, &Hassock.subscribe_template(&1, "{{ 1 }}"))

      task = Task.async(fn -> Hassock.unsubscribe_events(conn, id) end)
      assert_receive {:fake_ha, ^sock, %{"type" => "unsubscribe_events", "id" => unsub_id}}, 1_000
      FakeHA.event(sock, id, %{result: "1", listeners: %{}})
      FakeHA.result(sock, unsub_id, nil)
      assert Task.await(task) == :ok

      refute_receive {:hassock, ^conn, {:event, _}}, 100
    end

    test "a template subscription is restored after a reconnect, with the same id",
         %{conn: conn, sock: sock} do
      {id, _msg} = subscribe(conn, sock, &Hassock.subscribe_template(&1, "{{ 1 }}"))

      FakeHA.close(sock)
      assert_receive {:hassock, ^conn, {:disconnected, _}}, 1_000
      sock2 = await_auth(conn)

      assert_receive {:fake_ha, ^sock2,
                      %{"type" => "render_template", "template" => "{{ 1 }}", "id" => ha_id}},
                     1_000

      FakeHA.result(sock2, ha_id, nil)
      FakeHA.event(sock2, ha_id, %{result: "1", listeners: %{}})
      assert_receive {:hassock, ^conn, {:event, {:template, ^id, %{result: "1"}}}}, 1_000
    end

    test ":to delivers template events to another process", %{conn: conn, sock: sock} do
      receiver = forwarder()
      {id, _msg} = subscribe(conn, sock, &Hassock.subscribe_template(&1, "{{ 1 }}", to: receiver))
      FakeHA.event(sock, id, %{result: "1", listeners: %{}})
      FakeHA.event(sock, id, %{result: "2", listeners: %{}})

      assert_receive {:forwarded, {:hassock, ^conn, {:event, {:template, ^id, %{result: "1"}}}}},
                     1_000

      assert_receive {:forwarded, {:hassock, ^conn, {:event, {:template, ^id, %{result: "2"}}}}},
                     1_000

      refute_received {:hassock, ^conn, {:event, _}}
    end

    test "a payload that can't be encoded raises in the caller, not the connection",
         %{conn: conn} do
      assert_raise Protocol.UndefinedError, fn ->
        Hassock.subscribe_template(conn, "{{ x }}", variables: %{x: {:a, :tuple}})
      end

      assert Hassock.connected?(conn)
    end

    test "events of a subscribe whose caller timed out are dropped", %{conn: conn, sock: sock} do
      task = Task.async(fn -> Hassock.subscribe_template(conn, "{{ 1 }}", timeout: 50) end)
      assert_receive {:fake_ha, ^sock, %{"type" => "render_template", "id" => id}}, 1_000
      assert Task.await(task) == {:error, :timeout}

      FakeHA.event(sock, id, %{result: "1", listeners: %{}})
      FakeHA.result(sock, id, nil)

      assert_receive {:fake_ha, ^sock, %{"type" => "unsubscribe_events", "subscription" => ^id}},
                     1_000

      refute_received {:hassock, ^conn, {:event, _}}
    end

    test "an event before the subscribe result goes to the :to receiver",
         %{conn: conn, sock: sock} do
      receiver = forwarder()

      task =
        Task.async(fn ->
          Hassock.subscribe_template(conn, "{{ x }}", to: receiver, report_errors: true)
        end)

      assert_receive {:fake_ha, ^sock, %{"type" => "render_template", "id" => id}}, 1_000
      FakeHA.event(sock, id, %{error: "boom", level: "ERROR"})
      FakeHA.result(sock, id, nil)
      assert {:ok, ^id} = Task.await(task)

      assert_receive {:forwarded,
                      {:hassock, ^conn, {:event, {:template, ^id, %{error: "boom"}}}}},
                     1_000

      refute_received {:hassock, ^conn, {:event, _}}
    end

    test "a :to receiver that exits cancels its template subscription",
         %{conn: conn, sock: sock} do
      receiver = forwarder()
      {id, _msg} = subscribe(conn, sock, &Hassock.subscribe_template(&1, "{{ 1 }}", to: receiver))

      Process.unlink(receiver)
      Process.exit(receiver, :kill)

      assert_receive {:fake_ha, ^sock, %{"type" => "unsubscribe_events", "subscription" => ^id}},
                     1_000
    end

    test ":to must be a pid", %{conn: conn} do
      assert_raise ArgumentError, fn -> Hassock.subscribe_template(conn, "{{ 1 }}", to: :nope) end
    end
  end
end
