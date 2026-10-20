defmodule Hassock.RegistriesTest do
  use ExUnit.Case, async: true

  alias Hassock.{
    Area,
    Connection,
    Device,
    EntityEntry,
    FakeHA,
    Fixtures,
    Floor,
    Label,
    Registries
  }

  describe "decoding recorded HA 2026.10 responses" do
    test "floors" do
      floors = Enum.map(Fixtures.registry(:floor), &Floor.from_map/1)
      assert [%Floor{floor_id: "floor_1", name: "Floor 1", level: nil, aliases: []} | _] = floors
      assert Enum.map(floors, & &1.level) == [nil, 1, 2]
    end

    test "areas" do
      areas = Enum.map(Fixtures.registry(:area), &Area.from_map/1)
      assert Enum.all?(areas, &match?(%Area{area_id: "area_" <> _, floor_id: "floor_" <> _}, &1))

      assert %Area{icon: "mdi:garage", temperature_entity_id: "sensor." <> _} =
               Enum.find(areas, & &1.icon)
    end

    test "devices" do
      devices = Enum.map(Fixtures.registry(:device), &Device.from_map/1)
      assert Enum.all?(devices, &is_binary(&1.id))
      assert Enum.any?(devices, &(&1.entry_type == "service"))
      assert Enum.any?(devices, &(&1.disabled_by == "user"))

      renamed = Enum.find(devices, & &1.name_by_user)
      assert Device.display_name(renamed) == renamed.name_by_user
      plain = Enum.find(devices, &is_nil(&1.name_by_user))
      assert Device.display_name(plain) == plain.name
    end

    test "entities" do
      entries = Enum.map(Fixtures.registry(:entity), &EntityEntry.from_map/1)
      assert Enum.all?(entries, &String.contains?(&1.entity_id, "."))

      assert Enum.map(entries, & &1.hidden_by) |> Enum.uniq() |> Enum.sort(:desc) ==
               ["user", "integration", nil]

      assert Enum.any?(entries, &(&1.disabled_by == "integration"))
      assert Enum.any?(entries, &(&1.entity_category == "diagnostic"))
      assert Enum.any?(entries, &(&1.entity_category == "config"))
      assert Enum.any?(entries, &(&1.icon == "mdi:light-recessed"))
      assert Enum.any?(entries, &(&1.categories != %{}))
    end

    test "labels" do
      assert [%Label{label_id: "label_1", color: "yellow", icon: "mdi:floor-lamp"}] =
               Enum.map(Fixtures.registry(:label), &Label.from_map/1)
    end

    test "missing keys decode to nil or empty, unknown keys are ignored" do
      assert %EntityEntry{entity_id: "light.x", labels: [], categories: %{}, hidden_by: nil} =
               EntityEntry.from_map(%{"entity_id" => "light.x", "brand_new_field" => 1})

      assert %Area{aliases: [], labels: []} = Area.from_map(%{"area_id" => "a"})
    end
  end

  describe "list functions" do
    setup do
      ha = FakeHA.start()
      on_exit(fn -> FakeHA.stop(ha) end)
      {:ok, conn} = Connection.start_link(config: FakeHA.config(ha.port))
      assert_receive {:fake_ha, sock, :authenticated}, 2_000
      assert_receive {:hassock, ^conn, :connected}, 2_000
      %{conn: conn, sock: sock}
    end

    for {fun, kind, struct} <- [
          {:list_floors, :floor, Floor},
          {:list_areas, :area, Area},
          {:list_devices, :device, Device},
          {:list_entities, :entity, EntityEntry},
          {:list_labels, :label, Label}
        ] do
      test "#{fun}/2 sends config/#{kind}_registry/list and decodes", %{conn: conn, sock: sock} do
        kind = unquote(kind)
        task = Task.async(fn -> apply(Registries, unquote(fun), [conn]) end)
        type = "config/#{kind}_registry/list"
        assert_receive {:fake_ha, ^sock, %{"type" => ^type, "id" => id}}, 1_000
        FakeHA.result(sock, id, Fixtures.registry(kind))

        assert {:ok, [_ | _] = items} = Task.await(task)
        assert Enum.all?(items, &is_struct(&1, unquote(struct)))
        assert length(items) == length(Fixtures.registry(kind))
      end
    end

    test "a list with an item that isn't a map is reported", %{conn: conn, sock: sock} do
      task = Task.async(fn -> Registries.list_areas(conn) end)
      assert_receive {:fake_ha, ^sock, %{"id" => id}}, 1_000
      FakeHA.result(sock, id, [nil])
      assert Task.await(task) == {:error, {:unexpected_result, [nil]}}
    end

    test "an HA error is returned", %{conn: conn, sock: sock} do
      task = Task.async(fn -> Registries.list_floors(conn) end)
      assert_receive {:fake_ha, ^sock, %{"id" => id}}, 1_000
      FakeHA.error(sock, id, "unauthorized", "Unauthorized")
      assert {:error, %{"code" => "unauthorized"}} = Task.await(task)
    end
  end
end
