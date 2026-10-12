defmodule Hassock.EntityStateTest do
  use ExUnit.Case, async: true

  alias Hassock.EntityState

  @current %EntityState{
    entity_id: "sensor.p1",
    state: "100",
    attributes: %{"unit_of_measurement" => "W", "friendly_name" => "P1", "stale" => true},
    last_changed: "2026-10-12T10:00:00Z",
    last_updated: "2026-10-12T10:00:00Z"
  }

  describe "apply_diff/2" do
    test "replaces state and timestamps, merges and drops attributes" do
      diff = %{
        added: %{
          state: "120",
          attributes: %{"friendly_name" => "P1 meter", "phase" => 3},
          last_changed: "2026-10-12T10:00:05Z",
          last_updated: "2026-10-12T10:00:05Z"
        },
        removed: %{attributes: ["stale"]}
      }

      assert %EntityState{
               entity_id: "sensor.p1",
               state: "120",
               attributes: %{
                 "unit_of_measurement" => "W",
                 "friendly_name" => "P1 meter",
                 "phase" => 3
               },
               last_changed: "2026-10-12T10:00:05Z",
               last_updated: "2026-10-12T10:00:05Z"
             } = EntityState.apply_diff(@current, diff)
    end

    test "an attribute-only diff keeps the state value and last_changed" do
      diff = %{added: %{attributes: %{"phase" => 1}, last_updated: "t2"}, removed: %{}}
      new = EntityState.apply_diff(@current, diff)

      assert new.state == "100"
      assert new.last_changed == @current.last_changed
      assert new.last_updated == "t2"
      assert new.attributes["phase"] == 1
    end

    test "an attribute both removed and re-added keeps the new value" do
      diff = %{added: %{attributes: %{"stale" => false}}, removed: %{attributes: ["stale"]}}
      assert EntityState.apply_diff(@current, diff).attributes["stale"] == false
    end

    test "matches what Protocol decodes from a delta event" do
      json =
        Jason.encode!(%{
          type: "event",
          id: 1,
          event: %{
            c: %{"sensor.p1" => %{"+" => %{s: "130", a: %{"x" => 1}}, "-" => %{a: ["stale"]}}}
          }
        })

      {:entities, 1, %{changed: %{"sensor.p1" => diff}}} = Hassock.Protocol.parse(json)
      new = EntityState.apply_diff(@current, diff)

      assert new.state == "130"
      assert new.attributes["x"] == 1
      refute Map.has_key?(new.attributes, "stale")
    end
  end
end
