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

    test "failure result carries the error map" do
      error = %{"code" => "not_found", "message" => "Entity not found."}
      json = Jason.encode!(%{type: "result", id: 4, success: false, error: error})
      assert {:result, 4, false, ^error} = Protocol.parse(json)
    end

    test "list results stay raw, even when every item has an entity_id" do
      entries = [%{"entity_id" => "light.a", "platform" => "hue"}]
      json = Jason.encode!(%{type: "result", id: 2, success: true, result: entries})
      assert {:result, 2, true, ^entries} = Protocol.parse(json)
    end

    test "map results stay raw, even when shaped like get_services" do
      services = %{"light" => %{"turn_on" => %{}}}
      json = Jason.encode!(%{type: "result", id: 3, success: true, result: services})
      assert {:result, 3, true, ^services} = Protocol.parse(json)
    end

    test "empty list result" do
      assert {:result, 4, true, []} =
               Protocol.parse(~s({"type": "result", "id": 4, "success": true, "result": []}))
    end
  end

  describe "decode_states/1 and decode_services/1" do
    test "decode_states/1 builds EntityState structs" do
      states = [
        %{"entity_id" => "light.a", "state" => "on", "attributes" => %{"b" => 1}},
        %{"entity_id" => "switch.b", "state" => "off"}
      ]

      assert [
               %EntityState{entity_id: "light.a", state: "on", attributes: %{"b" => 1}},
               %EntityState{entity_id: "switch.b", state: "off", attributes: %{}}
             ] = Protocol.decode_states(states)
    end

    test "decode_services/1 lists sorted service names per domain" do
      result = %{"light" => %{"turn_on" => %{}, "toggle" => %{}}, "scene" => %{}}

      assert Protocol.decode_services(result) == %{
               "light" => ["toggle", "turn_on"],
               "scene" => []
             }
    end
  end

  describe "parse/1 — bad input" do
    test "invalid JSON returns {:invalid, error} instead of raising" do
      assert {:invalid, %Jason.DecodeError{}} = Protocol.parse("{not json")
    end

    test "valid JSON that isn't an object is unknown" do
      assert {:unknown, [1, 2]} = Protocol.parse("[1, 2]")
    end
  end

  describe "parse/1 — pong and removals" do
    test "pong keeps its id" do
      assert {:pong, 5} = Protocol.parse(~s({"id": 5, "type": "pong"}))
    end

    test "state_changed for a removed entity has a nil new_state" do
      json =
        Jason.encode!(%{
          type: "event",
          id: 2,
          event: %{
            event_type: "state_changed",
            data: %{entity_id: "light.gone", new_state: nil, old_state: %{state: "on"}}
          }
        })

      assert {:state_changed, 2, nil, %EntityState{entity_id: "light.gone", state: "on"}} =
               Protocol.parse(json)
    end
  end

  describe "parse/1 — events without an event_type" do
    test "a render_template event is passed through whole, not as an entities update" do
      json =
        Jason.encode!(%{
          type: "event",
          id: 4,
          event: %{result: "21 °C", listeners: %{all: false, entities: ["sensor.t"]}}
        })

      assert {:event, 4, nil, %{"result" => "21 °C", "listeners" => _}} = Protocol.parse(json)
    end
  end

  describe "parse/1 — malformed fields" do
    defp event(event), do: Jason.encode!(%{type: "event", id: 3, event: event})

    test "a registry event whose data isn't a map is passed through as a plain event" do
      assert {:event, 3, "area_registry_updated", _} =
               Protocol.parse(event(%{event_type: "area_registry_updated", data: 42}))
    end

    test "a state_changed event whose new_state isn't a map is passed through" do
      json = event(%{event_type: "state_changed", data: %{entity_id: "x.y", new_state: 5}})
      assert {:event, 3, "state_changed", _} = Protocol.parse(json)
    end

    test "a state_changed event with a malformed old_state keeps old_state nil" do
      json =
        event(%{
          event_type: "state_changed",
          data: %{entity_id: "x.y", new_state: %{state: "on"}, old_state: 5}
        })

      assert {:state_changed, 3, %EntityState{state: "on"}, nil} = Protocol.parse(json)
    end

    test "entities events drop fields of the wrong type" do
      assert {:entities, 3, %{added: %{}, changed: %{}, removed: []}} =
               Protocol.parse(event(%{a: 5, c: "x", r: 7}))

      assert {:entities, 3, %{added: added, changed: changed, removed: ["light.b"]}} =
               Protocol.parse(
                 event(%{
                   a: %{"light.bad" => 5, "light.ok" => %{s: "on", a: 9}},
                   c: %{"light.bad" => 5, "light.c" => %{"+" => %{s: "off", a: 1}, "-" => 3}},
                   r: ["light.b", 4]
                 })
               )

      assert %{"light.ok" => %EntityState{state: "on", attributes: %{}}} = added
      assert %{"light.c" => %{added: %{state: "off"}, removed: %{}}} = changed
    end
  end

  describe "parse/1 — registry events" do
    for {type, kind, key} <- [
          {"floor_registry_updated", :floor, "floor_id"},
          {"area_registry_updated", :area, "area_id"},
          {"device_registry_updated", :device, "device_id"},
          {"entity_registry_updated", :entity, "entity_id"},
          {"label_registry_updated", :label, "label_id"}
        ] do
      test "#{type} becomes :registry_updated" do
        json =
          Jason.encode!(%{
            type: "event",
            id: 9,
            event: %{
              event_type: unquote(type),
              data: %{"action" => "update", unquote(key) => "x"}
            }
          })

        assert {:registry_updated, 9, unquote(kind), :update, "x"} = Protocol.parse(json)
      end
    end

    test "actions map to atoms; unknown actions stay strings" do
      parse = fn action ->
        %{
          type: "event",
          id: 1,
          event: %{event_type: "area_registry_updated", data: %{action: action, area_id: "a"}}
        }
        |> Jason.encode!()
        |> Protocol.parse()
      end

      assert {:registry_updated, 1, :area, :create, "a"} = parse.("create")
      assert {:registry_updated, 1, :area, :remove, "a"} = parse.("remove")
      assert {:registry_updated, 1, :area, "reorder", "a"} = parse.("reorder")
    end

    test "registry_event_types/0 lists the five types" do
      assert Enum.sort(Protocol.registry_event_types()) == [
               "area_registry_updated",
               "device_registry_updated",
               "entity_registry_updated",
               "floor_registry_updated",
               "label_registry_updated"
             ]
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

    test "encode_command/3 merges the payload under id and type" do
      decoded =
        Protocol.encode_command(6, "config/area_registry/list", %{:a => 1, "id" => 0})
        |> Jason.decode!()

      assert decoded == %{"id" => 6, "type" => "config/area_registry/list", "a" => 1}
    end

    test "encode_call_service/2 with return_response" do
      call = %ServiceCall{domain: "weather", service: "get_forecasts", return_response: true}

      assert %{"return_response" => true} =
               Protocol.encode_call_service(1, call) |> Jason.decode!()
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
