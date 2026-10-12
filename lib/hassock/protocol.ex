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
  - `lovelace/dashboards/list`, `lovelace/config` — dashboard listing and config
  - `render_template` — subscribe to a rendered template
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

  @typedoc """
  A `render_template` event. `result` is whatever the template renders to:
  HA turns output that parses as a number, list, or map into that type.
  `listeners` says what HA watches to re-render it. Error events only arrive
  when the subscription asked for `report_errors: true`.
  """
  @type template_payload ::
          %{result: term(), listeners: map()}
          | %{error: String.t(), level: String.t()}

  @type parsed ::
          :auth_required
          | :auth_ok
          | {:auth_invalid, String.t()}
          | {:result, integer(), boolean(), term()}
          | {:state_changed, integer(), EntityState.t(), EntityState.t() | nil}
          | {:entities, integer(), entities_payload()}
          | {:event, integer(), String.t(), map()}
          | {:states, integer(), [EntityState.t()]}
          | {:services, integer(), %{String.t() => [String.t()]}}
          | {:template, integer(), template_payload()}
          | :pong
          | {:unknown, map()}

  @doc """
  Parse a raw JSON string from the HA WebSocket into a tagged term.

  Options:

    * `:raw_result?` — a 1-arity function called with a result's `id`. When
      it returns `true`, the result is returned as `{:result, id, success,
      result}` without shape detection. Use it for commands whose payload
      could be mistaken for a `get_states` or `get_services` result, such as
      a dashboard config.
    * `:template_event?` — a 1-arity function called with an event's `id`.
      When it returns `true`, the event is parsed as a `render_template`
      event. Template events carry no `event_type`, so without this they are
      indistinguishable from `subscribe_entities` events.
  """
  @spec parse(String.t(), keyword) :: parsed()
  def parse(json, opts \\ []) do
    raw_result? = Keyword.get(opts, :raw_result?, fn _id -> false end)
    template_event? = Keyword.get(opts, :template_event?, fn _id -> false end)

    case Jason.decode!(json) do
      %{"type" => "result", "id" => id} = msg ->
        if raw_result?.(id), do: parse_raw_result(msg), else: parse_decoded(msg)

      %{"type" => "event", "id" => id, "event" => %{} = event} = msg ->
        if template_event?.(id), do: parse_template_event(id, event), else: parse_decoded(msg)

      msg ->
        parse_decoded(msg)
    end
  end

  defp parse_template_event(id, %{"error" => error} = event),
    do: {:template, id, %{error: error, level: Map.get(event, "level", "ERROR")}}

  defp parse_template_event(id, event),
    do: {:template, id, %{result: event["result"], listeners: Map.get(event, "listeners", %{})}}

  defp parse_raw_result(%{"id" => id, "success" => true} = msg),
    do: {:result, id, true, Map.get(msg, "result")}

  defp parse_raw_result(%{"id" => id} = msg),
    do: {:result, id, false, Map.get(msg, "error")}

  defp parse_decoded(%{"type" => "auth_required"}), do: :auth_required
  defp parse_decoded(%{"type" => "auth_ok"}), do: :auth_ok

  defp parse_decoded(%{"type" => "auth_invalid", "message" => msg}),
    do: {:auth_invalid, msg}

  defp parse_decoded(%{"type" => "auth_invalid"}),
    do: {:auth_invalid, "unknown reason"}

  defp parse_decoded(%{"type" => "pong"}), do: :pong

  defp parse_decoded(%{
         "type" => "event",
         "id" => id,
         "event" => %{
           "event_type" => "state_changed",
           "data" => %{"entity_id" => entity_id, "new_state" => new_state_map} = data
         }
       }) do
    new_state = parse_state(entity_id, new_state_map)
    old_state = data |> Map.get("old_state") |> parse_state(entity_id)
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
       }),
       do: {:event, id, type, event}

  defp parse_decoded(%{"type" => "result", "id" => id, "success" => true, "result" => result})
       when is_list(result) do
    if Enum.all?(result, &(is_map(&1) and Map.has_key?(&1, "entity_id"))) do
      states = Enum.map(result, fn s -> parse_state(s, s["entity_id"]) end)
      {:states, id, states}
    else
      {:result, id, true, result}
    end
  end

  defp parse_decoded(%{"type" => "result", "id" => id, "success" => true, "result" => result})
       when is_map(result) do
    if services_result?(result) do
      {:services, id, parse_services(result)}
    else
      {:result, id, true, result}
    end
  end

  defp parse_decoded(%{"type" => "result", "id" => id, "success" => false} = msg),
    do: {:result, id, false, Map.get(msg, "error")}

  defp parse_decoded(%{"type" => "result", "id" => id, "success" => success} = msg),
    do: {:result, id, success, Map.get(msg, "result")}

  defp parse_decoded(msg), do: {:unknown, msg}

  # parse_state/2 — accepts (entity_id, state_map) for state_changed events,
  # or (state_map, entity_id) for get_states results which embed entity_id in the map.
  defp parse_state(nil, _entity_id), do: nil
  defp parse_state(_entity_id, nil), do: nil

  defp parse_state(entity_id, %{} = state_map) when is_binary(entity_id) do
    %EntityState{
      entity_id: entity_id,
      state: Map.get(state_map, "state", "unknown"),
      attributes: Map.get(state_map, "attributes", %{}),
      last_changed: Map.get(state_map, "last_changed"),
      last_updated: Map.get(state_map, "last_updated")
    }
  end

  defp parse_state(%{} = state_map, entity_id) when is_binary(entity_id) do
    parse_state(entity_id, state_map)
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
      removed: Map.get(event, "r", [])
    }
  end

  defp parse_entities_added(added) when is_map(added) do
    Map.new(added, fn {entity_id, compressed} ->
      {entity_id, decompress_full_state(entity_id, compressed)}
    end)
  end

  defp parse_entities_changed(changed) when is_map(changed) do
    Map.new(changed, fn {entity_id, diff} ->
      {entity_id,
       %{
         added: decompress_diff_added(Map.get(diff, "+", %{})),
         removed: decompress_diff_removed(Map.get(diff, "-", %{}))
       }}
    end)
  end

  defp decompress_full_state(entity_id, %{} = c) do
    %EntityState{
      entity_id: entity_id,
      state: Map.get(c, "s", "unknown"),
      attributes: Map.get(c, "a", %{}),
      last_changed: Map.get(c, "lc"),
      last_updated: Map.get(c, "lu")
    }
  end

  defp decompress_diff_added(%{} = added) do
    keys = [{:state, "s"}, {:attributes, "a"}, {:last_changed, "lc"}, {:last_updated, "lu"}]

    Enum.reduce(keys, %{}, fn {atom, k}, acc ->
      case Map.fetch(added, k) do
        {:ok, v} -> Map.put(acc, atom, v)
        :error -> acc
      end
    end)
  end

  defp decompress_diff_removed(%{} = removed) do
    case Map.fetch(removed, "a") do
      {:ok, attrs} when is_list(attrs) -> %{attributes: attrs}
      _ -> %{}
    end
  end

  # -- Encoding --

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
    msg = %{id: id, type: "call_service", domain: call.domain, service: call.service}
    msg = if call.target, do: Map.put(msg, :target, call.target), else: msg

    msg =
      if call.service_data != %{}, do: Map.put(msg, :service_data, call.service_data), else: msg

    Jason.encode!(msg)
  end

  @doc "Encode a `lovelace/dashboards/list` command."
  @spec encode_lovelace_dashboards(integer()) :: String.t()
  def encode_lovelace_dashboards(id),
    do: Jason.encode!(%{id: id, type: "lovelace/dashboards/list"})

  @doc """
  Encode a `lovelace/config` command. A `nil` `url_path` asks for the default
  dashboard. `force: true` makes HA reload a YAML dashboard from disk.
  """
  @spec encode_lovelace_config(integer(), String.t() | nil, boolean()) :: String.t()
  def encode_lovelace_config(id, url_path, force \\ false) do
    msg = %{id: id, type: "lovelace/config", force: force}
    msg = if url_path, do: Map.put(msg, :url_path, url_path), else: msg
    Jason.encode!(msg)
  end

  @doc """
  Encode a `render_template` command. Options: `:variables` (map),
  `:timeout` (seconds; HA rejects the template if a test render takes
  longer), `:strict` (error on undefined variables), and `:report_errors`
  (send render errors as events).
  """
  @spec encode_render_template(integer(), String.t(), keyword) :: String.t()
  def encode_render_template(id, template, opts \\ []) do
    optional =
      opts
      |> Keyword.take([:variables, :timeout, :strict, :report_errors])
      |> Map.new()

    Jason.encode!(Map.merge(optional, %{id: id, type: "render_template", template: template}))
  end

  @doc "Encode a `ping` command."
  @spec encode_ping(integer()) :: String.t()
  def encode_ping(id), do: Jason.encode!(%{id: id, type: "ping"})

  # -- get_services result helpers --

  defp services_result?(result) when is_map(result) do
    case Enum.take(result, 1) do
      [{_domain, services}] when is_map(services) ->
        case Enum.take(services, 1) do
          [{_name, detail}] when is_map(detail) -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp parse_services(result) do
    Map.new(result, fn {domain, services} ->
      {domain, services |> Map.keys() |> Enum.sort()}
    end)
  end

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
