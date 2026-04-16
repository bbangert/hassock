defmodule Hassock.IntegrationTest do
  @moduledoc """
  Live test against a real Home Assistant instance.

  Run with:

      HASSOCK_URL=http://homeassistant.local:8123 \\
      HASSOCK_TOKEN=... \\
      HASSOCK_LIGHT_ENTITY=light.foo \\
      mix test --include integration test/integration_test.exs

  All tests are tagged `:integration` and excluded by default. Without the
  env vars set, every test is skipped.
  """

  use ExUnit.Case

  alias Hassock.{Cache, Config, Connection, ServiceCall}

  @moduletag :integration
  @timeout 10_000

  setup_all do
    case env_config() do
      {:ok, config} ->
        light = System.get_env("HASSOCK_LIGHT_ENTITY")
        %{config: config, light: light, skip: false}

      :error ->
        IO.puts("\n  HASSOCK_URL/HASSOCK_TOKEN not set — skipping integration tests")
        %{skip: true}
    end
  end

  setup ctx do
    if ctx[:skip], do: :ignore, else: :ok
  end

  describe "Connection only" do
    test "connects, lists services, calls a service", ctx do
      {:ok, conn} = Connection.start_link(config: ctx.config)

      assert_receive {:hassock, ^conn, :connected}, @timeout

      assert {:ok, services} = Connection.get_services(conn)
      assert is_map(services) and map_size(services) > 0

      assert {:ok, states} = Connection.get_states(conn)
      assert is_list(states) and states != []
      IO.puts("\n  Loaded #{length(states)} entities, #{map_size(services)} service domains")
    end

    test "subscribe_entities delivers initial snapshot then deltas", ctx do
      {:ok, conn} = Connection.start_link(config: ctx.config)
      assert_receive {:hassock, ^conn, :connected}, @timeout

      assert {:ok, _sub_id} = Connection.subscribe_entities(conn, nil)

      assert_receive {:hassock, ^conn, {:event, {:entities, %{added: added}}}}, @timeout
      assert map_size(added) > 0
      IO.puts("\n  Initial snapshot: #{map_size(added)} entities")
    end

    test "subscribe_entities scoped to a single entity emits only that one", ctx do
      light = ctx.light || Connection.start_link(config: ctx.config) |> first_light()

      if light do
        {:ok, conn} = Connection.start_link(config: ctx.config)
        assert_receive {:hassock, ^conn, :connected}, @timeout

        {:ok, _sub} = Connection.subscribe_entities(conn, [light])
        assert_receive {:hassock, ^conn, {:event, {:entities, %{added: added}}}}, @timeout

        assert Map.has_key?(added, light)
        assert map_size(added) == 1

        {:ok, _} =
          Connection.call_service(conn, %ServiceCall{
            domain: "light",
            service: "toggle",
            target: %{entity_id: light}
          })

        assert_receive {:hassock, ^conn, {:event, {:entities, %{changed: changed}}}}, @timeout
        assert Map.has_key?(changed, light)

        # Toggle back
        Process.sleep(300)

        {:ok, _} =
          Connection.call_service(conn, %ServiceCall{
            domain: "light",
            service: "toggle",
            target: %{entity_id: light}
          })
      else
        IO.puts("\n  No light entity available — skipping scoped subscribe test")
      end
    end
  end

  describe "Connection + Cache" do
    test "cache becomes ready and exposes entities", ctx do
      {:ok, conn} = Connection.start_link(config: ctx.config)
      assert_receive {:hassock, ^conn, :connected}, @timeout

      {:ok, cache} = Cache.start_link(connection: conn)
      assert_receive {:hassock_cache, ^cache, :ready}, @timeout

      states = Cache.get_all(cache)
      assert states != []
      IO.puts("\n  Cache loaded #{length(states)} entities")
    end

    test "cache emits :changes after an entity toggles", ctx do
      {:ok, conn} = Connection.start_link(config: ctx.config)
      assert_receive {:hassock, ^conn, :connected}, @timeout

      {:ok, cache} = Cache.start_link(connection: conn)
      assert_receive {:hassock_cache, ^cache, :ready}, @timeout

      light =
        ctx.light ||
          cache
          |> Cache.get_domain("light")
          |> List.first()
          |> case do
            nil -> nil
            es -> es.entity_id
          end

      if light do
        {:ok, _} =
          Connection.call_service(conn, %ServiceCall{
            domain: "light",
            service: "toggle",
            target: %{entity_id: light}
          })

        assert_receive {:hassock_cache, ^cache, {:changes, payload}}, @timeout
        assert Enum.any?(payload.changed, fn {id, _new, _old} -> id == light end)

        # Toggle back
        Process.sleep(300)

        {:ok, _} =
          Connection.call_service(conn, %ServiceCall{
            domain: "light",
            service: "toggle",
            target: %{entity_id: light}
          })
      else
        IO.puts("\n  No light entity available — skipping cache change test")
      end
    end
  end

  defp env_config do
    with url when is_binary(url) <- System.get_env("HASSOCK_URL"),
         token when is_binary(token) <- System.get_env("HASSOCK_TOKEN") do
      {:ok, %Config{url: url, token: token}}
    else
      _ -> :error
    end
  end

  defp first_light({:ok, conn}) do
    {:ok, states} = Connection.get_states(conn)

    states
    |> Enum.find(&String.starts_with?(&1.entity_id, "light."))
    |> case do
      nil -> nil
      es -> es.entity_id
    end
  end
end
