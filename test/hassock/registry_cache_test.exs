defmodule Hassock.RegistryCacheTest do
  use ExUnit.Case, async: true

  import Hassock.TestHelpers
  alias Hassock.{Area, Connection, Device, FakeHA, Fixtures, RegistryCache}

  setup do: connect()

  # Answer `count` commands from the cache: subscriptions succeed, registry
  # lists return the fixtures (or `overrides[kind]`; `:error` sends an HA
  # error). Returns what was seen, in order: `{:subscribe, event_type, id}`
  # or the list command's type.
  defp serve(sock, count, overrides \\ %{}) do
    for _ <- 1..count//1 do
      assert_receive {:fake_ha, ^sock, %{"id" => _} = msg}, 2_000
      answer(sock, msg, overrides)
    end
  end

  defp answer(sock, %{"type" => "subscribe_events", "id" => id} = msg, _overrides) do
    FakeHA.result(sock, id, nil)
    {:subscribe, msg["event_type"], id}
  end

  defp answer(sock, %{"type" => "config/" <> rest = type, "id" => id}, overrides) do
    kind = rest |> String.replace_suffix("_registry/list", "") |> String.to_existing_atom()

    case Map.get_lazy(overrides, kind, fn -> Fixtures.registry(kind) end) do
      :error -> FakeHA.error(sock, id, "home_assistant_error", "busy")
      items -> FakeHA.result(sock, id, items)
    end

    type
  end

  defp start_cache(%{conn: conn, sock: sock}, opts \\ []) do
    {:ok, cache} = RegistryCache.start_link([connection: conn] ++ opts)
    seen = serve(sock, 10)
    assert_receive {:hassock_registry, ^cache, :ready}, 2_000
    {cache, seen}
  end

  defp sub_id(seen, event_type) do
    Enum.find_value(seen, fn
      {:subscribe, ^event_type, id} -> id
      _ -> nil
    end)
  end

  test "subscribes to the five update events, then lists all five registries", ctx do
    {cache, seen} = start_cache(ctx)

    assert seen |> Enum.take(5) |> Enum.map(&elem(&1, 1)) |> Enum.sort() ==
             Enum.sort(Hassock.Protocol.registry_event_types())

    assert Enum.drop(seen, 5) == [
             "config/floor_registry/list",
             "config/area_registry/list",
             "config/device_registry/list",
             "config/entity_registry/list",
             "config/label_registry/list"
           ]

    assert length(RegistryCache.list(cache, :area)) == length(Fixtures.registry(:area))
    assert %Area{name: "Area 3"} = RegistryCache.get(cache, :area, "area_3")
    assert RegistryCache.get(cache, :area, "nope") == nil
    assert RegistryCache.list(cache, :label) |> length() == 1
  end

  test "is readable by name without calling the process", ctx do
    {_cache, _seen} = start_cache(ctx, name: :registry_cache_by_name)
    assert [_ | _] = RegistryCache.list(:registry_cache_by_name, :floor)
  end

  test "is readable through a {:global, _} name", ctx do
    name = {:global, {__MODULE__, make_ref()}}
    {_cache, _seen} = start_cache(ctx, name: name)
    assert [_ | _] = RegistryCache.list(name, :floor)
    assert RegistryCache.list({:global, :no_such_cache}, :floor) == []
  end

  test "a burst of update events causes one debounced re-list", %{sock: sock} = ctx do
    {cache, seen} = start_cache(ctx, debounce: 50)
    device_sub = sub_id(seen, "device_registry_updated")

    for n <- 1..5 do
      FakeHA.event(sock, device_sub, %{
        event_type: "device_registry_updated",
        data: %{action: "update", device_id: "device#{n}"}
      })
    end

    renamed =
      Fixtures.registry(:device)
      |> Enum.take(1)
      |> Enum.map(&Map.put(&1, "name_by_user", "Renamed"))

    assert serve(sock, 1, %{device: renamed}) == ["config/device_registry/list"]
    assert_receive {:hassock_registry, ^cache, {:changed, :device}}, 1_000
    refute_receive {:fake_ha, ^sock, %{}}, 200

    assert [%Device{name_by_user: "Renamed"}] = RegistryCache.list(cache, :device)
  end

  test "retries a re-list that failed", %{sock: sock} = ctx do
    {cache, seen} = start_cache(ctx, debounce: 10, retry: 50)

    FakeHA.event(sock, sub_id(seen, "label_registry_updated"), %{
      event_type: "label_registry_updated",
      data: %{action: "create", label_id: "new"}
    })

    assert serve(sock, 1, %{label: :error}) == ["config/label_registry/list"]
    refute_received {:hassock_registry, ^cache, {:changed, :label}}
    assert serve(sock, 1) == ["config/label_registry/list"]
    assert_receive {:hassock_registry, ^cache, {:changed, :label}}, 1_000
  end

  test "retries a load that failed", %{conn: conn, sock: sock} do
    {:ok, cache} = RegistryCache.start_link(connection: conn, retry: 50)

    seen = serve(sock, 7, %{area: :error})
    assert List.last(seen) == "config/area_registry/list"
    refute_receive {:hassock_registry, ^cache, :ready}, 30

    # The retry lists again; the subscriptions are already in place.
    assert serve(sock, 5) |> Enum.all?(&is_binary/1)
    assert_receive {:hassock_registry, ^cache, :ready}, 1_000
  end

  test "re-lists everything after a reconnect, without re-subscribing", %{sock: sock} = ctx do
    {cache, _seen} = start_cache(ctx)

    FakeHA.close(sock)
    assert_receive {:fake_ha, sock2, :authenticated}, 2_000

    # The connection restores the five subscriptions; the cache only re-lists.
    seen = serve(sock2, 10)
    assert Enum.count(seen, &match?({:subscribe, _, _}, &1)) == 5
    assert Enum.count(seen, &is_binary/1) == 5
    assert_receive {:hassock_registry, ^cache, :ready}, 2_000
    refute_receive {:fake_ha, ^sock2, %{}}, 200
  end

  test "re-subscribes and reloads when a subscription is lost", %{sock: sock} = ctx do
    {cache, _seen} = start_cache(ctx)

    FakeHA.close(sock)
    assert_receive {:fake_ha, sock2, :authenticated}, 2_000

    # HA refuses to restore one of the five subscriptions.
    for _ <- 1..5 do
      assert_receive {:fake_ha, ^sock2, %{"type" => "subscribe_events", "id" => id} = msg},
                     1_000

      if msg["event_type"] == "area_registry_updated",
        do: FakeHA.error(sock2, id, "home_assistant_error", "busy"),
        else: FakeHA.result(sock2, id, nil)
    end

    # It subscribes to that event type again and lists everything.
    seen = serve(sock2, 11)
    assert [{:subscribe, "area_registry_updated", _}] = Enum.filter(seen, &is_tuple/1)
    assert_receive {:hassock_registry, ^cache, :ready}, 2_000
  end

  test "waits for the connection when started before it authenticates" do
    ha = FakeHA.start(hold_auth: true)
    on_exit(fn -> FakeHA.stop(ha) end)
    {:ok, conn} = Connection.start_link(config: FakeHA.config(ha.port))
    assert_receive {:fake_ha, sock, :open}, 1_000

    {:ok, cache} = RegistryCache.start_link(connection: conn)
    refute_receive {:fake_ha, ^sock, %{}}, 100

    FakeHA.release_auth(sock)
    serve(sock, 10)
    assert_receive {:hassock_registry, ^cache, :ready}, 2_000
  end

  test "drops a load result that arrives after the connection went away",
       %{conn: conn, sock: sock} do
    {:ok, cache} = RegistryCache.start_link(connection: conn)
    serve(sock, 5)

    # The connection drops while the lists are in flight; their results
    # reach the cache after it heard about it.
    send(cache, {:hassock, conn, {:disconnected, :closed}})
    serve(sock, 5)
    refute_receive {:hassock_registry, ^cache, :ready}, 200

    send(cache, {:hassock, conn, :connected})
    assert serve(sock, 5) |> Enum.all?(&is_binary/1)
    assert_receive {:hassock_registry, ^cache, :ready}, 1_000
  end

  test "a subscription lost during a load isn't added back by its result",
       %{conn: conn, sock: sock} do
    {:ok, cache} = RegistryCache.start_link(connection: conn)
    area_sub = serve(sock, 5) |> sub_id("area_registry_updated")

    send(cache, {:hassock, conn, {:subscription_lost, area_sub, %{"code" => "x"}}})
    serve(sock, 5)

    # The next load subscribes to that event type again.
    assert [{:subscribe, "area_registry_updated", _} | lists] = serve(sock, 6)
    assert Enum.all?(lists, &is_binary/1)
    assert_receive {:hassock_registry, ^cache, :ready}, 1_000
  end

  test "a killed cache leaves no table registration behind", ctx do
    {cache, _seen} = start_cache(ctx, name: :registry_cache_killed)
    Process.unlink(cache)
    Process.exit(cache, :kill)

    wait_until(fn ->
      Registry.lookup(Hassock.TableRef, {RegistryCache, cache}) == [] and
        Registry.lookup(Hassock.TableRef, {RegistryCache, :registry_cache_killed}) == []
    end)

    assert RegistryCache.list(cache, :floor) == []
  end
end
