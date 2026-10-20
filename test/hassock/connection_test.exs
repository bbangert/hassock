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
      refute Hassock.connected?(conn)
    end

    test "a missing named connection returns an error instead of raising" do
      assert {:error, {:connection_down, :noproc}} = Hassock.command(:no_such_conn, "get_config")
    end
  end
end
