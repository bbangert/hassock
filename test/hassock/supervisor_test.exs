defmodule Hassock.SupervisorTest do
  use ExUnit.Case, async: true

  alias Hassock.{Cache, FakeHA, Fixtures, RegistryCache}

  setup do
    ha = FakeHA.start()
    on_exit(fn -> FakeHA.stop(ha) end)
    %{ha: ha}
  end

  test "runs the entity cache and the registry cache side by side", %{ha: ha} do
    n = System.unique_integer([:positive])
    names = [conn: :"conn_#{n}", cache: :"cache_#{n}", reg: :"reg_#{n}"]

    {:ok, _sup} =
      Hassock.Supervisor.start_link(
        config: FakeHA.config(ha.port),
        cache: true,
        registries: true,
        connection_name: names[:conn],
        cache_name: names[:cache],
        registry_cache_name: names[:reg]
      )

    assert_receive {:fake_ha, sock, :authenticated}, 2_000
    serve(sock)

    assert_receive {:hassock_cache, _cache, :ready}, 2_000
    assert_receive {:hassock_registry, _reg, :ready}, 2_000
    assert %{entity_id: "light.a"} = Cache.get(names[:cache], "light.a")
    assert [_ | _] = RegistryCache.list(names[:reg], :area)
  end

  test "without a cache, the controller gets the connection's messages", %{ha: ha} do
    name = :"conn_#{System.unique_integer([:positive])}"
    test = self()
    controller = spawn(fn -> receive(do: (msg -> send(test, {:controller_got, msg}))) end)

    {:ok, _sup} =
      Hassock.Supervisor.start_link(
        config: FakeHA.config(ha.port),
        connection_name: name,
        controller: controller
      )

    assert_receive {:controller_got, {:hassock, _conn, :connected}}, 2_000
    refute_received {:hassock, _, _}
  end

  test "restarts everything when the connection crashes", %{ha: ha} do
    n = System.unique_integer([:positive])
    conn_name = :"conn_#{n}"
    cache_name = :"cache_#{n}"

    {:ok, sup} =
      Hassock.Supervisor.start_link(
        config: FakeHA.config(ha.port),
        cache: true,
        connection_name: conn_name,
        cache_name: cache_name
      )

    assert_receive {:fake_ha, sock, :authenticated}, 2_000
    serve_one(sock)
    assert_receive {:hassock_cache, cache, :ready}, 2_000

    Process.exit(Process.whereis(conn_name), :kill)

    assert_receive {:fake_ha, sock2, :authenticated}, 2_000
    serve_one(sock2)
    assert_receive {:hassock_cache, cache2, :ready}, 2_000
    assert cache2 != cache
    assert Process.alive?(sup)
    assert %{entity_id: "light.a"} = Cache.get(cache_name, "light.a")
  end

  defp serve_one(sock) do
    assert_receive {:fake_ha, ^sock, %{"id" => id, "type" => type}}, 2_000
    answer(sock, id, type)
  end

  # Answer the six subscriptions and five lists, in whatever order they come.
  defp serve(sock) do
    for _ <- 1..11 do
      assert_receive {:fake_ha, ^sock, %{"id" => id, "type" => type}}, 2_000
      answer(sock, id, type)
    end
  end

  defp answer(sock, id, "subscribe_entities") do
    FakeHA.result(sock, id, nil)
    FakeHA.event(sock, id, %{a: %{"light.a" => %{s: "on", a: %{}}}})
  end

  defp answer(sock, id, "subscribe_events"), do: FakeHA.result(sock, id, nil)

  defp answer(sock, id, "config/" <> rest) do
    kind = rest |> String.replace_suffix("_registry/list", "") |> String.to_existing_atom()
    FakeHA.result(sock, id, Fixtures.registry(kind))
  end
end
