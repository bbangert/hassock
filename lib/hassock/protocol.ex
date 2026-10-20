defmodule Hassock.Protocol do
  @moduledoc """
  Pure functions for parsing and encoding Home Assistant WebSocket frames.

  No side effects, no processes — data in, data out. `Hassock.Connection`
  uses these to translate between JSON on the wire and tagged Elixir terms.

  ## HA WebSocket protocol summary

  All messages are JSON objects with a `type` field. After authentication,
  client commands carry an integer `id` for response correlation.

  ### Server → Client
  - `auth_required`, `auth_ok`, `auth_invalid`
  - `result` — response to a command (keyed by `id`)
  - `event` — subscription event (state_changed, entities deltas, etc.)
  - `pong` — response to ping

  ### Client → Server
  - `auth` — send access token
  - `subscribe_events` — subscribe to a generic event type
  - `subscribe_entities` — efficient targeted entity subscription
  - `unsubscribe_events` — cancel any subscription
  - `call_service`, `get_states`, `get_services`, `ping`
  - any other command through `encode_command/3`

  Results are returned undecoded (`{:result, id, success, result}`): only the
  sender knows which command an id belongs to, so `Hassock.Connection`
  decodes them by command kind with `decode_states/1` and `decode_services/1`.
  """

  alias Hassock.{EntityState, ServiceCall}

  # -- Parsing --

  @type entities_payload :: %{
          added: %{String.t() => EntityState.t()},
          changed: %{String.t() => entity_diff()},
          removed: [String.t()]
        }

  @type entity_diff :: %{
          added: %{
            optional(:state) => String.t(),
            optional(:attributes) => map(),
            optional(:last_changed) => String.t(),
            optional(:last_updated) => String.t()
          },
          removed: %{optional(:attributes) => [String.t()]}
        }

  @type parsed ::
          :auth_required
          | :auth_ok
          | {:auth_invalid, String.t()}
          | {:result, integer(), boolean(), term()}
          | {:state_changed, integer(), EntityState.t() | nil, EntityState.t() | nil}
          | {:entities, integer(), entities_payload()}
          | {:registry_updated, integer(), registry_kind(), registry_action(), String.t() | nil}
          | {:event, integer(), String.t(), map()}
          | {:pong, integer() | nil}
          | {:unknown, term()}
          | {:invalid, Exception.t()}

  @typedoc "Which registry a `*_registry_updated` event is about."
  @type registry_kind :: :floor | :area | :device | :entity | :label

  @typedoc "Registry change action; unrecognised actions are kept as strings."
  @type registry_action :: :create | :update | :remove | String.t()

  @registry_events %{
    "floor_registry_updated" => {:floor, "floor_id"},
    "area_registry_updated" => {:area, "area_id"},
    "device_registry_updated" => {:device, "device_id"},
    "entity_registry_updated" => {:entity, "entity_id"},
    "label_registry_updated" => {:label, "label_id"}
  }

  @doc "The HA event types that `parse/1` decodes into `:registry_updated`."
  @spec registry_event_types() :: [String.t()]
  def registry_event_types, do: Map.keys(@registry_events)

  @doc """
  Parse a raw JSON string from the HA WebSocket into a tagged term.

  Text that isn't valid JSON, or JSON whose fields don't have the types HA
  sends, returns `{:invalid, exception}` rather than raising: frames come
  from the network, and one bad frame shouldn't take the connection down.
  Fields of an entities event that have the wrong type are dropped.
  """
  @spec parse(String.t()) :: parsed()
  def parse(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> parse_decoded(decoded)
      {:error, error} -> {:invalid, error}
    end
  rescue
    error in [FunctionClauseError, BadMapError, ArgumentError, KeyError, Protocol.UndefinedError] ->
      {:invalid, error}
  end

  defp parse_decoded(%{"type" => "auth_required"}), do: :auth_required
  defp parse_decoded(%{"type" => "auth_ok"}), do: :auth_ok

  defp parse_decoded(%{"type" => "auth_invalid", "message" => msg}),
    do: {:auth_invalid, msg}

  defp parse_decoded(%{"type" => "auth_invalid"}),
    do: {:auth_invalid, "unknown reason"}

  defp parse_decoded(%{"type" => "pong"} = msg), do: {:pong, Map.get(msg, "id")}

  defp parse_decoded(%{
         "type" => "event",
         "id" => id,
         "event" => %{
           "event_type" => "state_changed",
           "data" => %{"entity_id" => entity_id, "new_state" => new_state_map} = data
         }
       })
       when is_binary(entity_id) and (is_map(new_state_map) or is_nil(new_state_map)) do
    old_state =
      case Map.get(data, "old_state") do
        %{} = old_state_map -> parse_state(entity_id, old_state_map)
        _ -> nil
      end

    # new_state is nil when the entity was removed.
    new_state = if new_state_map, do: parse_state(entity_id, new_state_map)
    {:state_changed, id, new_state, old_state}
  end

  defp parse_decoded(%{"type" => "event", "id" => id, "event" => %{} = ev})
       when not is_map_key(ev, "event_type") do
    {:entities, id, parse_entities_event(ev)}
  end

  defp parse_decoded(%{
         "type" => "event",
         "id" => id,
         "event" => %{"event_type" => type} = event
       })
       when is_map_key(@registry_events, type) do
    {kind, id_key} = Map.fetch!(@registry_events, type)

    case Map.get(event, "data") do
      %{} = data -> {:registry_updated, id, kind, registry_action(data["action"]), data[id_key]}
      _ -> {:event, id, type, event}
    end
  end

  defp parse_decoded(%{
         "type" => "event",
         "id" => id,
         "event" => %{"event_type" => type} = event
       }),
       do: {:event, id, type, event}

  defp parse_decoded(%{"type" => "result", "id" => id, "success" => false} = msg),
    do: {:result, id, false, Map.get(msg, "error")}

  defp parse_decoded(%{"type" => "result", "id" => id, "success" => success} = msg),
    do: {:result, id, success, Map.get(msg, "result")}

  defp parse_decoded(msg), do: {:unknown, msg}

  defp registry_action("create"), do: :create
  defp registry_action("update"), do: :update
  defp registry_action("remove"), do: :remove
  defp registry_action(action), do: action

  @doc "Decode a `get_states` result into `%Hassock.EntityState{}` structs."
  @spec decode_states([map()]) :: [EntityState.t()]
  def decode_states(states) when is_list(states) do
    for %{"entity_id" => entity_id} = s <- states,
        is_binary(entity_id),
        do: parse_state(entity_id, s)
  end

  @doc "Decode a `get_services` result into `%{domain => [service_name]}`."
  @spec decode_services(map()) :: %{String.t() => [String.t()]}
  def decode_services(result) when is_map(result) do
    Map.new(result, fn {domain, services} ->
      {domain, services |> Map.keys() |> Enum.sort()}
    end)
  end

  defp parse_state(entity_id, %{} = state_map) when is_binary(entity_id) do
    %EntityState{
      entity_id: entity_id,
      state: Map.get(state_map, "state", "unknown"),
      attributes: map_or_empty(Map.get(state_map, "attributes", %{})),
      last_changed: Map.get(state_map, "last_changed"),
      last_updated: Map.get(state_map, "last_updated")
    }
  end

  # -- subscribe_entities event payload --
  #
  # HA emits compressed event bodies of the form:
  #   {"a": {entity_id => compressed_state}, ...}        # added (full snapshot)
  #   {"c": {entity_id => {"+": additions, "-": removals}}, ...}  # changed (diff)
  #   {"r": [entity_id, ...]}                            # removed
  #
  # compressed_state has:
  #   "s"  — state value
  #   "a"  — attributes map
  #   "c"  — context (ignored — we don't surface this)
  #   "lc" — last_changed
  #   "lu" — last_updated
  #
  # In a "+" diff, only the changed/added subset of those keys appears. For "a"
  # in the diff, the value is a partial attribute map (additions/changes).
  # In a "-" diff, "a" is a list of attribute keys to remove.

  defp parse_entities_event(event) do
    %{
      added: parse_entities_added(Map.get(event, "a", %{})),
      changed: parse_entities_changed(Map.get(event, "c", %{})),
      removed: parse_entities_removed(Map.get(event, "r", []))
    }
  end

  defp parse_entities_added(%{} = added) do
    for {entity_id, %{} = compressed} <- added, into: %{} do
      {entity_id, decompress_full_state(entity_id, compressed)}
    end
  end

  defp parse_entities_added(_added), do: %{}

  defp parse_entities_changed(%{} = changed) do
    for {entity_id, %{} = diff} <- changed, into: %{} do
      {entity_id,
       %{
         added: decompress_diff_added(Map.get(diff, "+", %{})),
         removed: decompress_diff_removed(Map.get(diff, "-", %{}))
       }}
    end
  end

  defp parse_entities_changed(_changed), do: %{}

  defp parse_entities_removed(removed) when is_list(removed),
    do: Enum.filter(removed, &is_binary/1)

  defp parse_entities_removed(_removed), do: []

  defp decompress_full_state(entity_id, %{} = c) do
    %EntityState{
      entity_id: entity_id,
      state: Map.get(c, "s", "unknown"),
      attributes: map_or_empty(Map.get(c, "a", %{})),
      last_changed: Map.get(c, "lc"),
      last_updated: Map.get(c, "lu")
    }
  end

  defp decompress_diff_added(%{} = added) do
    keys = [{:state, "s"}, {:attributes, "a"}, {:last_changed, "lc"}, {:last_updated, "lu"}]

    Enum.reduce(keys, %{}, fn {atom, k}, acc ->
      case Map.fetch(added, k) do
        {:ok, v} when atom == :attributes and not is_map(v) -> acc
        {:ok, v} -> Map.put(acc, atom, v)
        :error -> acc
      end
    end)
  end

  defp decompress_diff_added(_added), do: %{}

  defp map_or_empty(%{} = map), do: map
  defp map_or_empty(_other), do: %{}

  defp decompress_diff_removed(%{} = removed) do
    case Map.fetch(removed, "a") do
      {:ok, attrs} when is_list(attrs) -> %{attributes: attrs}
      _ -> %{}
    end
  end

  defp decompress_diff_removed(_removed), do: %{}

  # -- Encoding --

  @doc """
  Encode any command: `payload` merged with `id` and `type`. Top-level
  payload keys may be atoms or strings; `id` and `type` always win.
  """
  @spec encode_command(integer(), String.t(), map()) :: String.t()
  def encode_command(id, type, payload \\ %{}) when is_binary(type) and is_map(payload) do
    payload
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.merge(%{"id" => id, "type" => type})
    |> Jason.encode!()
  end

  @doc "Encode an authentication message."
  @spec encode_auth(String.t()) :: String.t()
  def encode_auth(token), do: Jason.encode!(%{type: "auth", access_token: token})

  @doc "Encode a `subscribe_events` command for a given event type."
  @spec encode_subscribe_events(integer(), String.t()) :: String.t()
  def encode_subscribe_events(id, event_type) do
    Jason.encode!(%{id: id, type: "subscribe_events", event_type: event_type})
  end

  @doc """
  Encode a `subscribe_entities` command. Pass `nil` to subscribe to every
  entity, or a list of entity_ids to scope the subscription.
  """
  @spec encode_subscribe_entities(integer(), [String.t()] | nil) :: String.t()
  def encode_subscribe_entities(id, nil) do
    Jason.encode!(%{id: id, type: "subscribe_entities"})
  end

  def encode_subscribe_entities(id, entity_ids) when is_list(entity_ids) do
    Jason.encode!(%{id: id, type: "subscribe_entities", entity_ids: entity_ids})
  end

  @doc "Encode an `unsubscribe_events` command (works for both subscription types)."
  @spec encode_unsubscribe_events(integer(), integer()) :: String.t()
  def encode_unsubscribe_events(id, subscription_id) do
    Jason.encode!(%{id: id, type: "unsubscribe_events", subscription: subscription_id})
  end

  @doc "Encode a `get_states` command."
  @spec encode_get_states(integer()) :: String.t()
  def encode_get_states(id), do: Jason.encode!(%{id: id, type: "get_states"})

  @doc "Encode a `get_services` command."
  @spec encode_get_services(integer()) :: String.t()
  def encode_get_services(id), do: Jason.encode!(%{id: id, type: "get_services"})

  @doc "Encode a `call_service` command."
  @spec encode_call_service(integer(), ServiceCall.t()) :: String.t()
  def encode_call_service(id, %ServiceCall{} = call) do
    encode_command(id, "call_service", call_service_payload(call))
  end

  @doc "The `call_service` fields (everything but `id` and `type`) for a call."
  @spec call_service_payload(ServiceCall.t()) :: map()
  def call_service_payload(%ServiceCall{} = call) do
    %{"domain" => call.domain, "service" => call.service}
    |> put_if("target", call.target, call.target != nil)
    |> put_if("service_data", call.service_data, call.service_data != %{})
    |> put_if("return_response", true, call.return_response)
  end

  defp put_if(map, key, value, true), do: Map.put(map, key, value)
  defp put_if(map, _key, _value, _), do: map

  @doc "Encode a `ping` command."
  @spec encode_ping(integer()) :: String.t()
  def encode_ping(id), do: Jason.encode!(%{id: id, type: "ping"})

  # -- State diffing --

  @doc """
  True if a new state differs from the prior in a meaningful way (state value
  or attributes). Returns `true` when `old` is `nil`. `last_updated`-only churn
  returns `false`.
  """
  @spec state_changed?(EntityState.t() | nil, EntityState.t()) :: boolean()
  def state_changed?(nil, _new), do: true

  def state_changed?(%EntityState{} = old, %EntityState{} = new) do
    old.state != new.state or old.attributes != new.attributes
  end
end
