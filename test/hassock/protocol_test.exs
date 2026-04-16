defmodule Hassock.ProtocolTest do
  use ExUnit.Case, async: true

  alias Hassock.{EntityState, Protocol, ServiceCall}

  describe "parse/1 — auth" do
    test "auth_required" do
      assert :auth_required = Protocol.parse(~s({"type": "auth_required"}))
    end

    test "auth_ok" do
      assert :auth_ok = Protocol.parse(~s({"type": "auth_ok", "ha_version": "2024.1.0"}))
    end

    test "auth_invalid with message" do
      json = ~s({"type": "auth_invalid", "message": "Invalid access token"})
      assert {:auth_invalid, "Invalid access token"} = Protocol.parse(json)
    end

    test "auth_invalid without message" do
      assert {:auth_invalid, "unknown reason"} = Protocol.parse(~s({"type": "auth_invalid"}))
    end
  end

  describe "parse/1 — state_changed events" do
    test "with new and old state" do
      json =
        Jason.encode!(%{
          type: "event",
          id: 1,
          event: %{
            event_type: "state_changed",
            data: %{
              entity_id: "light.living_room",
              new_state: %{
                state: "on",
                attributes: %{brightness: 255},
                last_changed: "2024-01-01T00:00:00Z",
                last_updated: "2024-01-01T00:00:00Z"
              },
              old_state: %{state: "off", attributes: %{brightness: 0}}
            }
          }
        })

      assert {:state_changed, 1, new_state, old_state} = Protocol.parse(json)
      assert %EntityState{entity_id: "light.living_room", state: "on"} = new_state
      assert new_state.attributes["brightness"] == 255
      assert %EntityState{state: "off"} = old_state
    end

    test "with nil old_state" do
      json =
        Jason.encode!(%{
          type: "event",
          id: 5,
          event: %{
            event_type: "state_changed",
            data: %{
              entity_id: "sensor.temp",
              new_state: %{state: "72.5", attributes: %{}}
            }
          }
        })

      assert {:state_changed, 5, new_state, nil} = Protocol.parse(json)
      assert new_state.state == "72.5"
    end
  end

  describe "parse/1 — subscribe_entities events" do
    test "initial snapshot decodes added entities from compressed form" do
      json =
        Jason.encode!(%{
          type: "event",
          id: 7,
          event: %{
            a: %{
              "light.kitchen" => %{
                s: "on",
                a: %{brightness: 200},
                lc: "2024-01-01T00:00:00Z",
                lu: "2024-01-01T00:00:00Z"
              },
              "sensor.temp" => %{s: "72", a: %{unit: "F"}}
            }
          }
        })

      assert {:entities, 7, %{added: added, changed: changed, removed: removed}} =
               Protocol.parse(json)

      assert changed == %{}
      assert removed == []

      assert %EntityState{state: "on", attributes: %{"brightness" => 200}} =
               added["light.kitchen"]

      assert %EntityState{state: "72"} = added["sensor.temp"]
    end

    test "delta decodes changed entities with attribute additions and removals" do
      json =
        Jason.encode!(%{
          type: "event",
          id: 8,
          event: %{
            c: %{
              "light.kitchen" => %{
                "+" => %{s: "off", a: %{brightness: 0}, lu: "2024-01-02T00:00:00Z"},
                "-" => %{a: ["color_mode"]}
              }
            }
          }
        })

      assert {:entities, 8, %{added: %{}, changed: changed, removed: []}} = Protocol.parse(json)

      assert changed["light.kitchen"] == %{
               added: %{
                 state: "off",
                 attributes: %{"brightness" => 0},
                 last_updated: "2024-01-02T00:00:00Z"
               },
               removed: %{attributes: ["color_mode"]}
             }
    end

    test "delta decodes removed entities" do
      json =
        Jason.encode!(%{
          type: "event",
          id: 9,
          event: %{r: ["light.gone", "switch.deleted"]}
        })

      assert {:entities, 9, %{added: %{}, changed: %{}, removed: removed}} = Protocol.parse(json)
      assert Enum.sort(removed) == ["light.gone", "switch.deleted"]
    end

    test "combined a/c/r in one event" do
      json =
        Jason.encode!(%{
          type: "event",
          id: 10,
          event: %{
            a: %{"sensor.new" => %{s: "fresh"}},
            c: %{"light.k" => %{"+" => %{s: "on"}}},
            r: ["sensor.old"]
          }
        })

      assert {:entities, 10, payload} = Protocol.parse(json)
      assert Map.has_key?(payload.added, "sensor.new")
      assert payload.changed["light.k"].added.state == "on"
      assert payload.removed == ["sensor.old"]
    end
  end

  describe "parse/1 — results" do
    test "success result" do
      assert {:result, 3, true, nil} =
               Protocol.parse(~s({"type": "result", "id": 3, "success": true, "result": null}))
    end

    test "failure result" do
      json = Jason.encode!(%{type: "result", id: 4, success: false, result: nil})
      assert {:result, 4, false, nil} = Protocol.parse(json)
    end

    test "get_states result becomes :states" do
      json =
        Jason.encode!(%{
          type: "result",
          id: 2,
          success: true,
          result: [
            %{entity_id: "light.a", state: "on", attributes: %{}},
            %{entity_id: "switch.b", state: "off", attributes: %{}}
          ]
        })

      assert {:states, 2, states} = Protocol.parse(json)
      assert length(states) == 2
      assert %EntityState{entity_id: "light.a", state: "on"} = hd(states)
    end
  end

  describe "parse/1 — other events" do
    test "non-state_changed event is passed through" do
      json =
        Jason.encode!(%{
          type: "event",
          id: 10,
          event: %{event_type: "automation_triggered", data: %{}}
        })

      assert {:event, 10, "automation_triggered", _} = Protocol.parse(json)
    end

    test "unknown" do
      assert {:unknown, %{"type" => "something_new"}} =
               Protocol.parse(~s({"type": "something_new", "data": "hello"}))
    end
  end

  describe "encode_*" do
    test "encode_auth/1" do
      assert %{"type" => "auth", "access_token" => "tok"} =
               Protocol.encode_auth("tok") |> Jason.decode!()
    end

    test "encode_subscribe_events/2" do
      assert %{"id" => 1, "type" => "subscribe_events", "event_type" => "state_changed"} =
               Protocol.encode_subscribe_events(1, "state_changed") |> Jason.decode!()
    end

    test "encode_subscribe_entities/2 with nil subscribes to all" do
      decoded = Protocol.encode_subscribe_entities(2, nil) |> Jason.decode!()
      assert decoded["type"] == "subscribe_entities"
      assert decoded["id"] == 2
      refute Map.has_key?(decoded, "entity_ids")
    end

    test "encode_subscribe_entities/2 with a list scopes the subscription" do
      decoded = Protocol.encode_subscribe_entities(3, ["light.a", "light.b"]) |> Jason.decode!()
      assert decoded["entity_ids"] == ["light.a", "light.b"]
    end

    test "encode_unsubscribe_events/2" do
      decoded = Protocol.encode_unsubscribe_events(4, 99) |> Jason.decode!()
      assert decoded["type"] == "unsubscribe_events"
      assert decoded["subscription"] == 99
    end

    test "encode_get_states/1" do
      assert %{"id" => 5, "type" => "get_states"} =
               Protocol.encode_get_states(5) |> Jason.decode!()
    end

    test "encode_call_service/2 minimal" do
      call = %ServiceCall{domain: "light", service: "toggle"}
      decoded = Protocol.encode_call_service(6, call) |> Jason.decode!()
      assert decoded["type"] == "call_service"
      assert decoded["domain"] == "light"
      assert decoded["service"] == "toggle"
      refute Map.has_key?(decoded, "target")
      refute Map.has_key?(decoded, "service_data")
    end

    test "encode_call_service/2 with target and data" do
      call = %ServiceCall{
        domain: "light",
        service: "turn_on",
        target: %{entity_id: "light.a"},
        service_data: %{brightness: 128}
      }

      decoded = Protocol.encode_call_service(7, call) |> Jason.decode!()
      assert decoded["target"]["entity_id"] == "light.a"
      assert decoded["service_data"]["brightness"] == 128
    end
  end

  describe "state_changed?/2" do
    test "true when old is nil" do
      assert Protocol.state_changed?(nil, %EntityState{entity_id: "x", state: "on"})
    end

    test "true when state value changes" do
      old = %EntityState{entity_id: "x", state: "off"}
      new = %EntityState{entity_id: "x", state: "on"}
      assert Protocol.state_changed?(old, new)
    end

    test "true when attributes change" do
      old = %EntityState{entity_id: "x", state: "on", attributes: %{"b" => 100}}
      new = %EntityState{entity_id: "x", state: "on", attributes: %{"b" => 200}}
      assert Protocol.state_changed?(old, new)
    end

    test "false when only last_updated churns" do
      old = %EntityState{entity_id: "x", state: "on", last_updated: "2024-01-01"}
      new = %EntityState{entity_id: "x", state: "on", last_updated: "2024-01-02"}
      refute Protocol.state_changed?(old, new)
    end
  end
end
