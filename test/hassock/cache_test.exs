defmodule Hassock.CacheTest do
  use ExUnit.Case, async: true

  import Hassock.TestHelpers
  alias Hassock.{Cache, Connection, EntityState, FakeHA}

  setup do: connect()

  defp compressed(states) do
    Map.new(states, fn {id, s} -> {id, %{s: s, a: %{"friendly_name" => id}, lc: 1.0, lu: 1.0}} end)
  end

  # Answer the cache's subscribe_entities and send the snapshot.
  defp snapshot(sock, states) do
    assert_receive {:fake_ha, ^sock, %{"type" => "subscribe_entities", "id" => id} = msg}, 1_000
    refute Map.has_key?(msg, "entity_ids")
    FakeHA.result(sock, id, nil)
    FakeHA.event(sock, id, %{a: compressed(states)})
    id
  end

  defp start_cache(%{conn: conn, sock: sock}, opts \\ []) do
    {:ok, cache} = Cache.start_link([connection: conn] ++ opts)
    sub = snapshot(sock, %{"light.a" => "off", "light.b" => "on", "sensor.c" => "21"})
    assert_receive {:hassock_cache, ^cache, :ready}, 1_000
    {cache, sub}
  end

  test "loads the snapshot and sends only :ready for the initial load", ctx do
    {cache, _sub} = start_cache(ctx)
    refute_received {:hassock_cache, ^cache, {:changes, _}}

    assert %EntityState{state: "off"} = Cache.get(cache, "light.a")
    assert length(Cache.get_all(cache)) == 3

    assert cache |> Cache.get_domain("light") |> Enum.map(& &1.entity_id) |> Enum.sort() ==
             ["light.a", "light.b"]
  end

  test "applies deltas and reports them", %{sock: sock} = ctx do
    {cache, sub} = start_cache(ctx)

    FakeHA.event(sock, sub, %{c: %{"light.a" => %{"+" => %{s: "on"}}}, r: ["sensor.c"]})

    assert_receive {:hassock_cache, ^cache,
                    {:changes,
                     %{
                       changed: [{"light.a", %EntityState{state: "on"}, _}],
                       removed: ["sensor.c"]
                     }}}

    assert Cache.get(cache, "sensor.c") == nil
  end

  test "after a reconnect, diffs the new snapshot and drops entities removed meanwhile",
       %{sock: sock} = ctx do
    {cache, _sub} = start_cache(ctx)

    FakeHA.close(sock)
    assert_receive {:hassock_cache, ^cache, :disconnected}, 1_000
    assert_receive {:fake_ha, sock2, :authenticated}, 2_000

    # The connection restores the subscription; the cache doesn't add another.
    snapshot(sock2, %{"light.a" => "on", "sensor.c" => "21", "switch.d" => "off"})
    refute_receive {:fake_ha, ^sock2, %{"type" => "subscribe_entities"}}, 100

    assert_receive {:hassock_cache, ^cache, {:changes, changes}}, 1_000
    assert [{"switch.d", %EntityState{state: "off"}}] = changes.added
    assert [{"light.a", %EntityState{state: "on"}, %EntityState{state: "off"}}] = changes.changed
    assert changes.removed == ["light.b"]
    assert_receive {:hassock_cache, ^cache, :ready}, 1_000

    assert Cache.get(cache, "light.b") == nil

    assert Cache.get_all(cache) |> Enum.map(& &1.entity_id) |> Enum.sort() ==
             ["light.a", "sensor.c", "switch.d"]
  end

  test "an unchanged snapshot after a reconnect sends only :ready", %{sock: sock} = ctx do
    {cache, _sub} = start_cache(ctx)
    FakeHA.close(sock)
    assert_receive {:fake_ha, sock2, :authenticated}, 2_000

    snapshot(sock2, %{"light.a" => "off", "light.b" => "on", "sensor.c" => "21"})
    assert_receive {:hassock_cache, ^cache, :ready}, 1_000
    refute_received {:hassock_cache, ^cache, {:changes, _}}
  end

  test "reads by name, and returns empty results once the cache is gone", ctx do
    {cache, _sub} = start_cache(ctx, name: :cache_test_named)
    assert %EntityState{} = Cache.get(:cache_test_named, "light.a")
    assert Cache.get_all(:cache_test_named) != []

    GenServer.stop(cache)
    assert Cache.get(:cache_test_named, "light.a") == nil
    assert Cache.get(cache, "light.a") == nil
    assert Cache.get_all(cache) == []
  end

  test "applies added entities and attribute removals from deltas", %{sock: sock} = ctx do
    {cache, sub} = start_cache(ctx)

    FakeHA.event(sock, sub, %{
      a: %{"switch.new" => %{s: "on", a: %{}}},
      c: %{"light.a" => %{"-" => %{a: ["friendly_name"]}}}
    })

    assert_receive {:hassock_cache, ^cache, {:changes, changes}}, 1_000
    assert [{"switch.new", %EntityState{state: "on"}}] = changes.added
    assert [{"light.a", %EntityState{attributes: attrs}, _old}] = changes.changed
    assert attrs == %{}
    assert %EntityState{} = Cache.get(cache, "switch.new")
  end

  test "re-subscribes when the connection loses its subscription", %{sock: sock} = ctx do
    {cache, _sub} = start_cache(ctx)

    FakeHA.close(sock)
    assert_receive {:fake_ha, sock2, :authenticated}, 2_000
    assert_receive {:fake_ha, ^sock2, %{"type" => "subscribe_entities", "id" => id}}, 1_000
    FakeHA.error(sock2, id, "home_assistant_error", "try again")

    # The cache subscribes again by itself and resyncs.
    snapshot(sock2, %{"light.a" => "off", "light.b" => "on", "sensor.c" => "21"})
    assert_receive {:hassock_cache, ^cache, :ready}, 1_000
  end

  test "can start before the connection has authenticated" do
    ha = FakeHA.start(hold_auth: true)
    on_exit(fn -> FakeHA.stop(ha) end)
    {:ok, conn} = Connection.start_link(config: FakeHA.config(ha.port))
    assert_receive {:fake_ha, sock, :open}, 1_000

    {:ok, cache} = Cache.start_link(connection: conn)
    FakeHA.release_auth(sock)

    snapshot(sock, %{"light.a" => "on"})
    assert_receive {:hassock_cache, ^cache, :ready}, 1_000
    assert %EntityState{state: "on"} = Cache.get(cache, "light.a")
  end

  test "passes auth_failed on to its controller" do
    ha = FakeHA.start()
    on_exit(fn -> FakeHA.stop(ha) end)

    {:ok, _sup} =
      Hassock.Supervisor.start_link(
        config: FakeHA.config(ha.port, token: "bad"),
        cache: true,
        connection_name: :"cache_auth_conn_#{System.unique_integer([:positive])}",
        cache_name: :"cache_auth_cache_#{System.unique_integer([:positive])}"
      )

    assert_receive {:hassock_cache, _cache, {:auth_failed, "Invalid access token"}}, 1_000
  end

  test "a stopped cache's subscription ends with it", %{sock: sock} = ctx do
    {cache, sub} = start_cache(ctx)
    GenServer.stop(cache)

    assert_receive {:fake_ha, ^sock, %{"type" => "unsubscribe_events", "subscription" => ^sub}},
                   1_000
  end
end
