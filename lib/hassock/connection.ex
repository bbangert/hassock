defmodule Hassock.Connection do
  @moduledoc """
  WebSocket client for Home Assistant.

  The process that calls `start_link/1` becomes the **controlling process**
  and receives async messages of the shape `{:hassock, conn, payload}`:

    * `{:hassock, conn, :connected}` — once, after `auth_ok`
    * `{:hassock, conn, {:event, payload}}` — for each inbound HA event
    * `{:hassock, conn, {:disconnected, reason}}` — on socket loss
    * `{:hassock, conn, {:auth_failed, reason}}` — on `auth_invalid`

  Event payload variants:

    * `{:state_changed, new_state, old_state}` — from `subscribe_events("state_changed")`
    * `{:entities, %{added: _, changed: _, removed: _}}` — from `subscribe_entities/2`
    * `{:other, event_type, raw_event}` — from any other `subscribe_events/2` type

  Use `controlling_process/2` to transfer ownership to a different pid.

  This module performs the auth handshake and nothing else automatically. It
  does not subscribe to anything on its own — callers drive subscriptions
  explicitly via `subscribe_entities/2`, `subscribe_events/2`, etc.
  """

  use WebSockex
  require Logger

  alias Hassock.{Config, Protocol, ServiceCall}

  defmodule State do
    @moduledoc false
    defstruct [
      :config,
      :controlling_pid,
      :controlling_monitor,
      next_id: 1,
      pending: %{},
      authenticated: false
    ]
  end

  @default_timeout 10_000

  # -- Public API --

  @doc """
  Open a Home Assistant WebSocket connection.

  Options:

    * `:config` — `%Hassock.Config{}` (required)
    * `:name` — register the process under this name (optional)

  The calling process becomes the controlling process. If `start_link/1`
  returns `{:ok, conn}`, the controller will receive a `{:hassock, ^conn,
  :connected}` message once authentication completes.
  """
  @spec start_link(keyword) :: {:ok, pid} | {:error, term}
  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    name = Keyword.get(opts, :name)
    controlling_pid = Keyword.get(opts, :controlling_pid, self())

    state = %State{config: config, controlling_pid: controlling_pid}
    url = Config.websocket_url(config)

    ws_opts = if name, do: [name: name], else: []
    WebSockex.start_link(url, __MODULE__, state, ws_opts)
  end

  @doc """
  Transfer the controlling process. Only the current controller may transfer
  ownership.
  """
  @spec controlling_process(pid | atom, pid) :: :ok | {:error, :not_owner | :not_alive}
  def controlling_process(conn, new_pid) when is_pid(new_pid) do
    sync_request(conn, {:set_controlling, self(), new_pid}, @default_timeout)
  end

  @doc """
  Subscribe to entity state updates. Pass `nil` to subscribe to all entities,
  or a list of `entity_id`s to scope. Strictly preferred over
  `subscribe_events("state_changed")`.

  Returns `{:ok, subscription_id}` on success.
  """
  @spec subscribe_entities(pid | atom, [String.t()] | nil) ::
          {:ok, integer} | {:error, term}
  def subscribe_entities(conn, entity_ids \\ nil) do
    sync_request(
      conn,
      {:command, {:subscribe_entities, entity_ids}, :subscribe},
      @default_timeout
    )
  end

  @doc """
  Subscribe to a non-entity HA event type (e.g. `"automation_triggered"`).
  Don't use this with `"state_changed"` — use `subscribe_entities/2` instead.
  """
  @spec subscribe_events(pid | atom, String.t()) :: {:ok, integer} | {:error, term}
  def subscribe_events(conn, event_type) when is_binary(event_type) do
    sync_request(
      conn,
      {:command, {:subscribe_events, event_type}, :subscribe},
      @default_timeout
    )
  end

  @doc "Cancel a subscription returned by `subscribe_entities/2` or `subscribe_events/2`."
  @spec unsubscribe_events(pid | atom, integer) :: :ok | {:error, term}
  def unsubscribe_events(conn, subscription_id) when is_integer(subscription_id) do
    sync_request(
      conn,
      {:command, {:unsubscribe_events, subscription_id}, :unsubscribe},
      @default_timeout
    )
  end

  @doc "Call a Home Assistant service and wait for the result."
  @spec call_service(pid | atom, ServiceCall.t()) :: {:ok, term} | {:error, term}
  def call_service(conn, %ServiceCall{} = call) do
    sync_request(conn, {:command, {:call_service, call}, :call_service}, @default_timeout)
  end

  @doc "Fetch a one-shot snapshot of all entity states."
  @spec get_states(pid | atom) :: {:ok, [Hassock.EntityState.t()]} | {:error, term}
  def get_states(conn) do
    sync_request(conn, {:command, :get_states, :get_states}, @default_timeout)
  end

  @doc "Fetch all available service domains and their services."
  @spec get_services(pid | atom) :: {:ok, %{String.t() => [String.t()]}} | {:error, term}
  def get_services(conn) do
    sync_request(conn, {:command, :get_services, :get_services}, @default_timeout)
  end

  @doc "True if authenticated and the underlying socket is connected."
  @spec connected?(pid | atom) :: boolean
  def connected?(conn) do
    case sync_request(conn, :connected?, 1_000) do
      true -> true
      _ -> false
    end
  end

  # -- WebSockex callbacks --

  @impl true
  def handle_connect(_conn, %State{controlling_pid: pid} = state) when is_pid(pid) do
    monitor = Process.monitor(pid)
    {:ok, %{state | controlling_monitor: monitor}}
  end

  def handle_connect(_conn, state), do: {:ok, state}

  @impl true
  def handle_frame({:text, json}, state) do
    json |> Protocol.parse() |> route(state)
  end

  def handle_frame(_frame, state), do: {:ok, state}

  defp route(:auth_required, state) do
    {:reply, {:text, Protocol.encode_auth(state.config.token)}, state}
  end

  defp route(:auth_ok, state) do
    Logger.info("Hassock: authenticated")
    notify(state, :connected)
    {:ok, %{state | authenticated: true}}
  end

  defp route({:auth_invalid, reason}, state) do
    Logger.error("Hassock: auth invalid: #{reason}")
    notify(state, {:auth_failed, reason})
    {:close, state}
  end

  defp route({:result, id, success, result}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:ok, state}

      {{ref, kind}, pending} ->
        reply(ref, format_result(kind, id, success, result))
        {:ok, %{state | pending: pending}}
    end
  end

  defp route({:states, id, states}, state) do
    case Map.pop(state.pending, id) do
      {{ref, :get_states}, pending} ->
        reply(ref, {:ok, states})
        {:ok, %{state | pending: pending}}

      _ ->
        {:ok, state}
    end
  end

  defp route({:services, id, services}, state) do
    case Map.pop(state.pending, id) do
      {{ref, :get_services}, pending} ->
        reply(ref, {:ok, services})
        {:ok, %{state | pending: pending}}

      _ ->
        {:ok, state}
    end
  end

  defp route({:state_changed, _id, new, old}, state) do
    notify(state, {:event, {:state_changed, new, old}})
    {:ok, state}
  end

  defp route({:entities, _id, payload}, state) do
    notify(state, {:event, {:entities, payload}})
    {:ok, state}
  end

  defp route({:event, _id, type, raw}, state) do
    notify(state, {:event, {:other, type, raw}})
    {:ok, state}
  end

  defp route(:pong, state), do: {:ok, state}
  defp route({:unknown, _msg}, state), do: {:ok, state}

  @impl true
  def handle_cast({:sync, request, ref}, state) do
    handle_sync(request, ref, state)
  end

  defp handle_sync(:connected?, ref, state) do
    reply(ref, state.authenticated)
    {:ok, state}
  end

  defp handle_sync({:set_controlling, caller, new_pid}, ref, state) do
    cond do
      state.controlling_pid != caller ->
        reply(ref, {:error, :not_owner})
        {:ok, state}

      not Process.alive?(new_pid) ->
        reply(ref, {:error, :not_alive})
        {:ok, state}

      true ->
        if state.controlling_monitor,
          do: Process.demonitor(state.controlling_monitor, [:flush])

        monitor = Process.monitor(new_pid)
        reply(ref, :ok)
        {:ok, %{state | controlling_pid: new_pid, controlling_monitor: monitor}}
    end
  end

  defp handle_sync({:command, command, kind}, ref, state) do
    if state.authenticated do
      id = state.next_id
      frame = encode_command(id, command)
      pending = Map.put(state.pending, id, {ref, kind})
      state = %{state | next_id: id + 1, pending: pending}
      {:reply, {:text, frame}, state}
    else
      reply(ref, {:error, :not_connected})
      {:ok, state}
    end
  end

  defp encode_command(id, {:subscribe_events, event_type}),
    do: Protocol.encode_subscribe_events(id, event_type)

  defp encode_command(id, {:subscribe_entities, entity_ids}),
    do: Protocol.encode_subscribe_entities(id, entity_ids)

  defp encode_command(id, {:unsubscribe_events, sub_id}),
    do: Protocol.encode_unsubscribe_events(id, sub_id)

  defp encode_command(id, {:call_service, call}),
    do: Protocol.encode_call_service(id, call)

  defp encode_command(id, :get_states), do: Protocol.encode_get_states(id)
  defp encode_command(id, :get_services), do: Protocol.encode_get_services(id)

  defp format_result(_kind, _id, false, error), do: {:error, error}
  defp format_result(:subscribe, id, true, _), do: {:ok, id}
  defp format_result(:unsubscribe, _id, true, _), do: :ok
  defp format_result(:call_service, _id, true, result), do: {:ok, result}
  defp format_result(_kind, _id, true, result), do: {:ok, result}

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %State{controlling_monitor: ref} = state
      ) do
    Logger.warning(
      "Hassock: controlling process died; events will be dropped until a new owner is set"
    )

    {:ok, %{state | controlling_pid: nil, controlling_monitor: nil}}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("Hassock: disconnected (#{inspect(reason)}), reconnecting...")
    notify(state, {:disconnected, reason})

    Enum.each(state.pending, fn {_id, {ref, _kind}} ->
      reply(ref, {:error, :disconnected})
    end)

    {:reconnect, %{state | authenticated: false, pending: %{}, next_id: 1}}
  end

  # -- Internals --

  defp notify(%State{controlling_pid: nil}, _payload), do: :ok

  defp notify(%State{controlling_pid: pid}, payload) do
    send(pid, {:hassock, self(), payload})
  end

  # Send a sync reply through a `:reply_demonitor` alias ref. If the caller
  # has already timed out and deactivated the alias, the runtime silently
  # drops this message — no orphaned response piles up in their mailbox.
  defp reply(ref, response), do: send(ref, {:hassock_response, ref, response})

  # Ref-correlated request against a non-GenServer WebSockex process.
  # The monitor doubles as a process alias (`:reply_demonitor`) so that:
  #   - the caller can `send/2` directly to `ref` from Connection,
  #   - after the reply fires, the alias auto-deactivates (one-shot),
  #   - on timeout, demonitor+flush deactivates the alias and drains `:DOWN`,
  # ensuring late replies are discarded rather than leaking into the mailbox.
  defp sync_request(conn, request, timeout) do
    ref = Process.monitor(conn_pid(conn), alias: :reply_demonitor)
    WebSockex.cast(conn, {:sync, request, ref})

    receive do
      {:hassock_response, ^ref, response} ->
        response

      {:DOWN, ^ref, :process, _, reason} ->
        {:error, {:connection_down, reason}}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end

  defp conn_pid(pid) when is_pid(pid), do: pid
  defp conn_pid(name) when is_atom(name), do: Process.whereis(name)
end
