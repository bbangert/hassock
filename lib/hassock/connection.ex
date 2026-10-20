defmodule Hassock.Connection do
  @moduledoc """
  WebSocket client for Home Assistant.

  `start_link/1` returns at once; the connection is made in the background
  and re-made after every loss, with exponential backoff (see
  `Hassock.Connection.Backoff`). Home Assistant being down at boot never
  blocks the caller or its supervisor.

  The process that calls `start_link/1` becomes the **controlling process**
  and receives async messages of the shape `{:hassock, conn, payload}`:

    * `{:hassock, conn, :connected}` - after each successful `auth_ok`
    * `{:hassock, conn, {:event, payload}}` - for each inbound HA event
    * `{:hassock, conn, {:disconnected, reason}}` - once per outage, when the
      connection is lost (or the first attempt fails); retries are silent
    * `{:hassock, conn, {:auth_failed, reason}}` - on `auth_invalid`. The
      connection then stops retrying (HA bans IPs after repeated failed
      logins); restart it with a fixed token. A controller set with
      `controlling_process/2` after the failure gets this message then.

  Other processes can receive the lifecycle messages (all of the above
  except events) with `watch/1`.

  If a subscription can't be restored after a reconnect (HA returned an
  error), it is dropped and its receiver gets
  `{:hassock, conn, {:subscription_lost, subscription_id, error}}`.

  Event payload variants:

    * `{:state_changed, new_state, old_state}` - from `subscribe_events("state_changed")`;
      `new_state` is `nil` when the entity was removed
    * `{:entities, %{added: _, changed: _, removed: _}}` - from `subscribe_entities/2`
    * `{:registry_updated, kind, action, id}` - from `subscribe_events/2` with
      one of `Hassock.Protocol.registry_event_types/0`
    * `{:other, event_type, raw_event}` - from any other `subscribe_events/2`
      type, and (with `event_type` `nil`) events without one, such as those
      of a `render_template` subscription made with `command/4`

  ## Subscriptions

  Subscriptions survive reconnects: after each re-auth the connection
  re-sends every active subscription, and the id returned by
  `subscribe_entities/2` / `subscribe_events/2` stays valid. A
  `subscribe_entities/2` subscription starts with a full snapshot again.

  Events go to the controlling process (and follow it through
  `controlling_process/2`), unless the subscription is made with the `:to`
  option: then they go to that pid, and the subscription is cancelled when
  it exits. `Hassock.RegistryCache` uses this to run beside another
  controller.

  ## Keepalive

  While connected, the connection sends HA a `ping` every `:ping_interval` ms
  (see `Hassock.Config`) and reconnects if the `pong` doesn't arrive within
  `:ping_timeout`, so a half-open TCP link is noticed. An attempt that
  hasn't authenticated within `:connect_timeout` is abandoned and retried.
  """

  use GenServer
  require Logger

  alias Hassock.{Config, Protocol, ServiceCall}
  alias Hassock.Connection.{Backoff, Socket}

  defmodule State do
    @moduledoc false
    # ws_opts can hold the whole system CA list; keep it out of crash reports.
    @derive {Inspect, except: [:ws_opts]}
    defstruct [
      :config,
      :url,
      :ws_opts,
      :controlling_pid,
      :controlling_monitor,
      :socket,
      :retry_timer,
      :retry_at,
      :ping_timer,
      :pong_timer,
      # tags the current ping/pong timer messages, so stale ones are ignored
      :ping_ref,
      # message id of the keepalive ping awaiting its pong
      :ping_id,
      :connect_timer,
      :connect_ref,
      :connected_at,
      :auth_error,
      status: :connecting,
      attempt: 0,
      outage: false,
      next_id: 1,
      # HA message id => {reply_ref | nil, kind, expiry_timer | nil}; a kind
      # of {:cancelled, kind} means the caller gave up waiting
      pending: %{},
      # subscription id => %{type:, payload:, kind:, ref:,
      #                       subscriber: :controller | pid}
      subscriptions: %{},
      # HA ids of subscriptions cancelled on this connection: their in-flight
      # events are dropped instead of reaching the controller
      retired: MapSet.new(),
      # HA id of a live subscription => subscription id, and the inverse
      ha_subs: %{},
      sub_ha_ids: %{},
      # pid => monitor ref
      watchers: %{},
      subscriber_monitors: %{}
    ]
  end

  @type status :: :connecting | :authenticating | :connected | :waiting | :auth_failed
  @type command_error ::
          map()
          | :not_connected
          | :disconnected
          | :timeout
          | {:connection_down, term}
          | {:unexpected_result, term}

  @default_timeout 10_000

  # -- Public API --

  @doc """
  Start a Home Assistant connection. Returns once the process is up; it
  connects in the background.

  Options:

    * `:config` - `%Hassock.Config{}` (required)
    * `:name` - register the process under this name (optional)
    * `:controlling_pid` - receiver of async messages (default: caller)

  The controller receives `{:hassock, ^conn, :connected}` once
  authentication completes, and again after every reconnect.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    controlling_pid = Keyword.get(opts, :controlling_pid, self())
    gen_opts = Keyword.take(opts, [:name])
    GenServer.start_link(__MODULE__, {config, controlling_pid}, gen_opts)
  end

  @doc """
  Transfer the controlling process. Only the current controller may transfer
  ownership, or anyone once the controller has exited.
  """
  @spec controlling_process(GenServer.server(), pid) ::
          :ok | {:error, :not_owner | :not_alive | :timeout | {:connection_down, term}}
  def controlling_process(conn, new_pid) when is_pid(new_pid) do
    sync_request(conn, {:set_controlling, self(), new_pid}, @default_timeout)
  end

  @doc """
  Also send the lifecycle messages (`:connected`, `{:disconnected, _}`,
  `{:auth_failed, _}`) to the caller, until it exits or calls `unwatch/1`.
  Returns the current status, so the caller knows whether to wait for
  `:connected`.
  """
  @spec watch(GenServer.server()) :: {:ok, status} | {:error, :timeout | {:connection_down, term}}
  def watch(conn), do: sync_request(conn, {:watch, self()}, @default_timeout)

  @doc "Stop sending lifecycle messages to the caller."
  @spec unwatch(GenServer.server()) :: :ok | {:error, :timeout | {:connection_down, term}}
  def unwatch(conn), do: sync_request(conn, {:unwatch, self()}, @default_timeout)

  @doc """
  Send any Home Assistant WebSocket command and wait for its result.

  `payload` is merged into the message next to `id` and `type`:

      Hassock.command(conn, "config/area_registry/list")
      Hassock.command(conn, "config/entity_registry/get", %{entity_id: "light.kitchen"}, timeout: 5_000)

  Returns `{:ok, result}`, `{:error, %{"code" => _, "message" => _}}` for an
  HA error, or `{:error, :not_connected | :disconnected | :timeout}`.
  Options: `:timeout` in ms (default 10 s).

  Use it for one-shot commands. A subscription made through it is not
  restored after a reconnect and its events go to the controlling process;
  prefer `subscribe_events/2` and `subscribe_entities/2`.
  """
  @spec command(GenServer.server(), String.t(), map, keyword) ::
          {:ok, term} | {:error, command_error}
  def command(conn, type, payload \\ %{}, opts \\ []) when is_binary(type) and is_map(payload) do
    request(conn, type, payload, :raw, opts)
  end

  @doc """
  Subscribe to entity state updates. Pass `nil` to subscribe to all entities,
  or a list of `entity_id`s to scope. Strictly preferred over
  `subscribe_events("state_changed")`.

  Returns `{:ok, subscription_id}` on success. Options:

    * `:to` - deliver the events to this pid instead of the controlling
      process (see "Subscriptions" above)
    * `:timeout` - ms to wait for HA (default 10 s); a subscription whose
      result comes after the caller gave up is cancelled
  """
  @spec subscribe_entities(GenServer.server(), [String.t()] | nil, keyword) ::
          {:ok, integer} | {:error, command_error}
  def subscribe_entities(conn, entity_ids \\ nil, opts \\ []) do
    payload = if entity_ids, do: %{"entity_ids" => entity_ids}, else: %{}
    request(conn, "subscribe_entities", payload, {:subscribe, :entities, to(opts), self()}, opts)
  end

  @doc """
  Subscribe to an HA event type (e.g. `"automation_triggered"`). Don't use
  this with `"state_changed"` - use `subscribe_entities/2` instead.
  Options: `:to` and `:timeout`, as for `subscribe_entities/3`.
  """
  @spec subscribe_events(GenServer.server(), String.t(), keyword) ::
          {:ok, integer} | {:error, command_error}
  def subscribe_events(conn, event_type, opts \\ []) when is_binary(event_type) do
    payload = %{"event_type" => event_type}
    request(conn, "subscribe_events", payload, {:subscribe, :events, to(opts), self()}, opts)
  end

  defp to(opts) do
    case Keyword.get(opts, :to) do
      to when is_pid(to) or is_nil(to) -> to
      other -> raise ArgumentError, ":to must be a pid, got: #{inspect(other)}"
    end
  end

  @doc """
  Cancel a subscription returned by `subscribe_entities/2` or
  `subscribe_events/2`. While disconnected this just forgets the
  subscription, so it isn't restored.
  """
  @spec unsubscribe_events(GenServer.server(), integer) :: :ok | {:error, command_error}
  def unsubscribe_events(conn, subscription_id) when is_integer(subscription_id) do
    sync_request(conn, {:unsubscribe, subscription_id}, @default_timeout)
  end

  @doc """
  Call a Home Assistant service and wait for the result: the raw result map,
  with the service's response data under `"response"` when the call sets
  `return_response: true`. Options: `:timeout` in ms (default 10 s).
  """
  @spec call_service(GenServer.server(), ServiceCall.t(), keyword) ::
          {:ok, map} | {:error, command_error}
  def call_service(conn, %ServiceCall{} = call, opts \\ []) do
    request(conn, "call_service", Protocol.call_service_payload(call), :raw, opts)
  end

  @doc "Fetch a one-shot snapshot of all entity states."
  @spec get_states(GenServer.server()) ::
          {:ok, [Hassock.EntityState.t()]} | {:error, command_error}
  def get_states(conn), do: request(conn, "get_states", %{}, :get_states, [])

  @doc "Fetch all available service domains and their services."
  @spec get_services(GenServer.server()) ::
          {:ok, %{String.t() => [String.t()]}} | {:error, command_error}
  def get_services(conn), do: request(conn, "get_services", %{}, :get_services, [])

  @doc "True if authenticated and the underlying socket is connected."
  @spec connected?(GenServer.server()) :: boolean
  def connected?(conn), do: sync_request(conn, :connected?, 1_000) == true

  @doc """
  Connection status:

    * `:status` - `:connecting`, `:authenticating`, `:connected`, `:waiting`
      (a retry is scheduled) or `:auth_failed`
    * `:attempt` - consecutive failed attempts; it resets once a connection
      has stayed up for `backoff_max`, so a server that accepts and then
      drops the connection is still backed off
    * `:next_retry_in` - ms until the next attempt while `:waiting`, else `nil`
  """
  @spec status(GenServer.server()) ::
          %{status: status, attempt: non_neg_integer, next_retry_in: non_neg_integer | nil}
          | {:error, term}
  def status(conn), do: sync_request(conn, :status, @default_timeout)

  defp request(conn, type, payload, kind, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    sync_request(conn, {:command, type, payload, kind, timeout}, timeout)
  end

  # -- GenServer callbacks --

  @impl true
  def init({%Config{} = config, controlling_pid}) do
    url = Config.websocket_url(config)

    with :ok <- validate(config),
         {:ok, _uri} <- WebSockex.Conn.parse_url(url) do
      # Trap exits so a dying socket arrives as a message, not a crash.
      Process.flag(:trap_exit, true)

      state = %State{
        config: config,
        url: url,
        ws_opts: Config.websocket_options(config),
        controlling_pid: controlling_pid,
        controlling_monitor: controlling_pid && Process.monitor(controlling_pid)
      }

      {:ok, state, {:continue, :connect}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp validate(config) do
    timeouts = [:ping_timeout, :backoff_initial, :backoff_max, :connect_timeout]
    ping_ok = config.ping_interval == nil or pos_integer?(config.ping_interval)

    case Enum.reject(timeouts, &pos_integer?(Map.fetch!(config, &1))) do
      [] when ping_ok -> :ok
      [] -> {:error, {:invalid_config, :ping_interval}}
      [key | _] -> {:error, {:invalid_config, key}}
    end
  end

  defp pos_integer?(value), do: is_integer(value) and value > 0

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  def handle_cast({:sync, request, ref}, state) do
    {:noreply, handle_sync(request, ref, state)}
  end

  @impl true
  def handle_info({:hassock_socket, socket, msg}, %State{socket: socket} = state) do
    {:noreply, handle_socket(msg, state)}
  end

  def handle_info({:hassock_socket, _old_socket, _msg}, state), do: {:noreply, state}

  def handle_info({:EXIT, socket, reason}, %State{socket: socket} = state) do
    {:noreply, socket_down(reason, state)}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:retry, %State{status: :waiting} = state) do
    {:noreply, connect(%{state | retry_timer: nil, retry_at: nil})}
  end

  def handle_info(:retry, state), do: {:noreply, state}

  def handle_info({:ping, ref}, %State{ping_ref: ref, status: :connected} = state) do
    {:noreply, send_ping(state)}
  end

  def handle_info({:pong_timeout, ref}, %State{ping_ref: ref, status: :connected} = state) do
    Logger.warning("Hassock: no pong within #{state.config.ping_timeout} ms, reconnecting")
    {:noreply, socket_down(:ping_timeout, kill_socket(state))}
  end

  def handle_info({:connect_timeout, ref}, %State{connect_ref: ref, status: status} = state)
      when status in [:connecting, :authenticating] do
    Logger.warning("Hassock: not authenticated within #{state.config.connect_timeout} ms")
    {:noreply, socket_down(:connect_timeout, kill_socket(state))}
  end

  def handle_info({tag, _ref}, state) when tag in [:ping, :pong_timeout, :connect_timeout],
    do: {:noreply, state}

  def handle_info({:expire, id}, state) do
    case Map.fetch(state.pending, id) do
      # Its caller gave up and HA still hasn't answered after a grace period.
      {:ok, {nil, {:cancelled, _kind}, _timer}} ->
        Logger.warning("Hassock: HA never answered subscription request #{id}, reconnecting")
        {:noreply, socket_down(:subscribe_timeout, kill_socket(state))}

      # HA answers pings but not this restore: re-make the connection, which
      # keeps the subscription and restores it again.
      {:ok, {nil, {:resubscribe, sub_id}, _timer}} ->
        Logger.warning("Hassock: restoring subscription #{sub_id} timed out, reconnecting")
        {:noreply, socket_down(:resubscribe_timeout, kill_socket(state))}

      {:ok, {ref, kind, _timer}} ->
        if ref, do: reply(ref, {:error, :timeout})
        {:noreply, cancel_pending(state, id, kind)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{controlling_monitor: ref} = state) do
    Logger.warning(
      "Hassock: controlling process died; events will be dropped until a new owner is set"
    )

    {:noreply, %{state | controlling_pid: nil, controlling_monitor: nil}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = %{state | watchers: Map.delete(state.watchers, pid)}
    {:noreply, drop_subscriber(pid, state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Connecting --

  defp connect(state) do
    case Socket.start_link(state.url, self(), state.ws_opts) do
      {:ok, socket} ->
        ref = make_ref()
        timer = Process.send_after(self(), {:connect_timeout, ref}, state.config.connect_timeout)
        %{state | socket: socket, status: :connecting, connect_timer: timer, connect_ref: ref}

      {:error, reason} ->
        socket_down(reason, state)
    end
  end

  defp kill_socket(%State{socket: nil} = state), do: state

  defp kill_socket(%State{socket: socket} = state) do
    Process.unlink(socket)
    Process.exit(socket, :kill)
    %{state | socket: nil}
  end

  # The socket is gone: fail in-flight calls, forget the HA-side ids, tell the
  # controller once per outage and schedule the next attempt.
  defp socket_down(reason, state) do
    state = state |> cancel_ping() |> cancel_connect_timer()

    Enum.each(state.pending, fn {_id, {ref, _kind, timer}} ->
      if timer, do: Process.cancel_timer(timer)
      if ref, do: reply(ref, {:error, :disconnected})
    end)

    stable? =
      state.connected_at != nil and now() - state.connected_at >= state.config.backoff_max

    state = %{
      state
      | socket: nil,
        pending: %{},
        ha_subs: %{},
        sub_ha_ids: %{},
        retired: MapSet.new(),
        connected_at: nil,
        attempt: if(stable?, do: 0, else: state.attempt)
    }

    if state.status == :auth_failed do
      state
    else
      state = announce_outage(reason, state)
      attempt = state.attempt + 1
      delay = Backoff.delay(attempt, state.config.backoff_initial, state.config.backoff_max)
      Logger.debug("Hassock: reconnect attempt #{attempt} in #{delay} ms")

      %{
        state
        | status: :waiting,
          attempt: attempt,
          retry_timer: Process.send_after(self(), :retry, delay),
          retry_at: now() + delay
      }
    end
  end

  defp announce_outage(_reason, %State{outage: true} = state), do: state

  defp announce_outage(reason, state) do
    Logger.warning("Hassock: disconnected (#{inspect(reason)}), reconnecting with backoff")
    notify_lifecycle(state, {:disconnected, reason})
    %{state | outage: true}
  end

  # -- Inbound --

  defp handle_socket(:open, state), do: %{state | status: :authenticating}
  defp handle_socket({:frame, parsed}, state), do: route(parsed, state)
  defp handle_socket({:closed, reason}, state), do: socket_down(reason, state)

  defp route(:auth_required, state) do
    send_text(state, Protocol.encode_auth(state.config.token))
    state
  end

  defp route(:auth_ok, state) do
    Logger.info("Hassock: authenticated")
    state = cancel_connect_timer(state)
    state = %{state | status: :connected, outage: false, connected_at: now()}
    notify_lifecycle(state, :connected)
    state |> schedule_ping() |> resubscribe()
  end

  defp route({:auth_invalid, reason}, state) do
    Logger.error("Hassock: auth invalid: #{inspect(reason)}; not retrying")
    notify_lifecycle(state, {:auth_failed, reason})
    state = %{state | status: :auth_failed, auth_error: reason}
    socket_down({:auth_failed, reason}, kill_socket(state))
  end

  defp route({:result, id, success, result}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {{ref, kind, timer}, pending} ->
        if timer, do: Process.cancel_timer(timer)
        handle_result(kind, id, success, result, ref, %{state | pending: pending})
    end
  end

  defp route({:entities, id, payload}, state),
    do: deliver(state, id, {:event, {:entities, payload}})

  defp route({:state_changed, id, new, old}, state),
    do: deliver(state, id, {:event, {:state_changed, new, old}})

  defp route({:registry_updated, id, kind, action, item_id}, state),
    do: deliver(state, id, {:event, {:registry_updated, kind, action, item_id}})

  defp route({:event, id, type, raw}, state),
    do: deliver(state, id, {:event, {:other, type, raw}})

  # A pong answers either a "ping" sent through command/4 or the keepalive
  # ping. Only the keepalive's own pong restarts the ping cycle; any other
  # would start a second cycle.
  defp route({:pong, id}, state) when is_map_key(state.pending, id),
    do: route({:result, id, true, nil}, state)

  defp route({:pong, id}, %State{ping_id: id, pong_timer: timer} = state) when timer != nil do
    Process.cancel_timer(timer)
    schedule_ping(%{state | pong_timer: nil, ping_id: nil})
  end

  defp route({:pong, _id}, state), do: state

  defp route({:invalid, error}, state) do
    Logger.warning("Hassock: dropping undecodable frame: #{Exception.message(error)}")
    state
  end

  defp route({:unknown, _msg}, state), do: state

  # Results are decoded by the kind recorded when the command was sent, never
  # by the shape of the result (an entity registry list looks like states).
  defp handle_result(_kind, _id, false, error, ref, state) when ref != nil do
    reply(ref, {:error, error})
    state
  end

  defp handle_result({:resubscribe, sub_id}, _id, false, error, nil, state) do
    Logger.warning("Hassock: restoring subscription #{sub_id} failed: #{inspect(error)}")

    case Map.fetch(state.subscriptions, sub_id) do
      {:ok, sub} ->
        deliver_to(state, sub.subscriber, {:subscription_lost, sub_id, error})
        remove_subscription(state, sub_id)

      :error ->
        state
    end
  end

  # The unsubscribe is done; no more events can come for this id. On
  # failure the id stays retired, so its events are still dropped.
  defp handle_result({kind, ha_id}, _id, true, _result, ref, state)
       when kind in [:unsubscribe, :retire] do
    if ref, do: reply(ref, :ok)
    %{state | retired: MapSet.delete(state.retired, ha_id)}
  end

  defp handle_result(_kind, _id, false, _error, nil, state), do: state

  # The caller gave up before HA answered. A subscription it never learned
  # the id of is cancelled at HA rather than kept forever.
  defp handle_result({:cancelled, {:subscribe, _, _, _, _, _}}, id, true, _result, nil, state),
    do: retire_ha_id(state, id)

  defp handle_result({:cancelled, _kind}, _id, true, _result, nil, state), do: state

  # Nobody can learn the id of a subscription whose requester died while
  # waiting, so it is cancelled rather than kept.
  defp handle_result(
         {:subscribe, kind, subscriber, type, payload, caller},
         id,
         true,
         _result,
         ref,
         state
       ) do
    if Process.alive?(caller) do
      reply(ref, {:ok, id})
      sub = %{type: type, payload: payload, kind: kind, ref: ref}
      add_subscription(state, id, sub, subscriber)
    else
      retire_ha_id(state, id)
    end
  end

  defp handle_result(:get_states, _id, true, result, ref, state) when is_list(result) do
    reply(ref, decode_states(result))
    state
  end

  defp handle_result(:get_services, _id, true, result, ref, state) when is_map(result) do
    reply(ref, decode_services(result))
    state
  end

  defp handle_result(kind, _id, true, result, ref, state)
       when kind in [:get_states, :get_services] do
    reply(ref, {:error, {:unexpected_result, result}})
    state
  end

  defp handle_result(_kind, _id, true, result, ref, state) do
    if ref, do: reply(ref, {:ok, result})
    state
  end

  defp decode_states(result) do
    if Enum.all?(result, &match?(%{"entity_id" => id} when is_binary(id), &1)),
      do: {:ok, Protocol.decode_states(result)},
      else: {:error, {:unexpected_result, result}}
  end

  defp decode_services(result) do
    if Enum.all?(Map.values(result), &is_map/1),
      do: {:ok, Protocol.decode_services(result)},
      else: {:error, {:unexpected_result, result}}
  end

  # -- Sync requests --

  defp handle_sync(:connected?, ref, state) do
    reply(ref, state.status == :connected)
    state
  end

  defp handle_sync(:status, ref, state) do
    next_retry_in = if state.retry_at, do: max(state.retry_at - now(), 0)
    reply(ref, %{status: state.status, attempt: state.attempt, next_retry_in: next_retry_in})
    state
  end

  defp handle_sync({:watch, pid}, ref, state) do
    watchers = Map.put_new_lazy(state.watchers, pid, fn -> Process.monitor(pid) end)
    reply(ref, {:ok, state.status})
    %{state | watchers: watchers}
  end

  defp handle_sync({:unwatch, pid}, ref, state) do
    {monitor, watchers} = Map.pop(state.watchers, pid)
    if monitor, do: Process.demonitor(monitor, [:flush])
    reply(ref, :ok)
    %{state | watchers: watchers}
  end

  defp handle_sync({:set_controlling, caller, new_pid}, ref, state) do
    cond do
      state.controlling_pid not in [nil, caller] ->
        reply(ref, {:error, :not_owner})
        state

      not Process.alive?(new_pid) ->
        reply(ref, {:error, :not_alive})
        state

      true ->
        if state.controlling_monitor,
          do: Process.demonitor(state.controlling_monitor, [:flush])

        monitor = Process.monitor(new_pid)
        reply(ref, :ok)
        state = %{state | controlling_pid: new_pid, controlling_monitor: monitor}

        # A controller that takes over after the auth failure (such as a
        # Cache started under the Supervisor) would never hear of it.
        if state.status == :auth_failed, do: notify(state, {:auth_failed, state.auth_error})
        state
    end
  end

  defp handle_sync({:unsubscribe, sub_id}, ref, state) do
    if Map.has_key?(state.subscriptions, sub_id) do
      ha_id = Map.get(state.sub_ha_ids, sub_id)
      state = remove_subscription(state, sub_id)

      if ha_id && state.status == :connected do
        payload = %{"subscription" => ha_id}
        state = %{state | retired: MapSet.put(state.retired, ha_id)}

        send_command(
          state,
          "unsubscribe_events",
          payload,
          ref,
          {:unsubscribe, ha_id},
          @default_timeout
        )
      else
        reply(ref, :ok)
        state
      end
    else
      reply(ref, {:error, %{"code" => "not_found", "message" => "Subscription not found."}})
      state
    end
  end

  # The caller timed out. Forget its pending command, or cancel the
  # subscription whose id it never received.
  defp handle_sync({:cancel, ref}, _ref, state) do
    pending = Enum.find(state.pending, fn {_id, {r, _kind, _timer}} -> r == ref end)
    sub = Enum.find(state.subscriptions, fn {_id, sub} -> sub.ref == ref end)

    case {pending, sub} do
      {{id, {_ref, kind, _timer}}, _} -> cancel_pending(state, id, kind)
      {nil, {sub_id, _sub}} -> cancel_subscription(state, sub_id)
      {nil, nil} -> state
    end
  end

  defp handle_sync({:command, type, payload, kind, timeout}, ref, state) do
    if state.status == :connected do
      send_command(state, type, payload, ref, command_kind(kind, type, payload), timeout)
    else
      reply(ref, {:error, :not_connected})
      state
    end
  end

  defp command_kind({:subscribe, sub_kind, to, caller}, type, payload)
       when is_pid(to) or is_nil(to),
       do: {:subscribe, sub_kind, to || :controller, type, payload, caller}

  defp command_kind(kind, _type, _payload), do: kind

  defp send_command(state, type, payload, ref, kind, timeout) do
    id = state.next_id
    send_text(state, Protocol.encode_command(id, type, payload))
    # With a caller, outlive its own timeout so the caller is the one that
    # gives up; this then only cleans up after callers that died waiting.
    timeout = if ref, do: timeout + 1_000, else: timeout
    timer = Process.send_after(self(), {:expire, id}, timeout)
    %{state | next_id: id + 1, pending: Map.put(state.pending, id, {ref, kind, timer})}
  end

  # -- Subscriptions --

  defp add_subscription(state, id, sub, subscriber) do
    monitors =
      if is_pid(subscriber),
        do:
          Map.put_new_lazy(state.subscriber_monitors, subscriber, fn ->
            Process.monitor(subscriber)
          end),
        else: state.subscriber_monitors

    %{
      state
      | subscriptions: Map.put(state.subscriptions, id, Map.put(sub, :subscriber, subscriber)),
        ha_subs: Map.put(state.ha_subs, id, id),
        sub_ha_ids: Map.put(state.sub_ha_ids, id, id),
        subscriber_monitors: monitors
    }
  end

  defp remove_subscription(state, sub_id) do
    state = drop_pending_restore(state, sub_id)
    {sub, subscriptions} = Map.pop(state.subscriptions, sub_id)
    {ha_id, sub_ha_ids} = Map.pop(state.sub_ha_ids, sub_id)

    state = %{
      state
      | subscriptions: subscriptions,
        sub_ha_ids: sub_ha_ids,
        ha_subs: Map.delete(state.ha_subs, ha_id)
    }

    with %{subscriber: pid} when is_pid(pid) <- sub,
         false <- subscriber?(state, pid),
         {monitor, monitors} when monitor != nil <- Map.pop(state.subscriber_monitors, pid) do
      Process.demonitor(monitor, [:flush])
      %{state | subscriber_monitors: monitors}
    else
      _ -> state
    end
  end

  # A restore still waiting for HA would otherwise expire and re-make the
  # connection for a subscription that no longer exists.
  defp drop_pending_restore(state, sub_id) do
    case Enum.find(state.pending, fn {_id, {_ref, kind, _timer}} ->
           kind == {:resubscribe, sub_id}
         end) do
      {id, {_ref, _kind, timer}} ->
        cancel_expiry(timer, id)
        %{state | pending: Map.delete(state.pending, id)}

      nil ->
        state
    end
  end

  defp subscriber?(state, pid) do
    Enum.any?(state.subscriptions, fn {_id, sub} -> sub.subscriber == pid end)
  end

  # A `:to` subscriber exited: cancel its subscriptions.
  defp drop_subscriber(pid, state) do
    state = %{state | subscriber_monitors: Map.delete(state.subscriber_monitors, pid)}

    state.subscriptions
    |> Enum.filter(fn {_id, sub} -> sub.subscriber == pid end)
    |> Enum.reduce(state, fn {sub_id, _sub}, acc -> cancel_subscription(acc, sub_id) end)
  end

  defp cancel_subscription(state, sub_id) do
    ha_id = Map.get(state.sub_ha_ids, sub_id)
    state = remove_subscription(state, sub_id)
    if ha_id, do: retire_ha_id(state, ha_id), else: state
  end

  # Unsubscribe at HA (fire and forget) and drop events still in flight.
  defp retire_ha_id(%State{status: :connected} = state, ha_id) do
    state = %{state | retired: MapSet.put(state.retired, ha_id)}
    payload = %{"subscription" => ha_id}
    send_command(state, "unsubscribe_events", payload, nil, {:retire, ha_id}, @default_timeout)
  end

  defp retire_ha_id(state, _ha_id), do: state

  # Keep a pending subscribe after its caller gave up, so its result can be
  # cancelled at HA; drop any other kind.
  defp cancel_pending(state, id, kind) do
    {{_ref, _kind, timer}, pending} = Map.pop(state.pending, id)
    cancel_expiry(timer, id)

    case kind do
      # Wait a while longer for HA's answer, so a subscription that does
      # succeed can be cancelled; a connection that never answers is re-made.
      {:subscribe, _, _, _, _, _} ->
        grace = Process.send_after(self(), {:expire, id}, state.config.connect_timeout)
        %{state | pending: Map.put(pending, id, {nil, {:cancelled, kind}, grace})}

      _ ->
        %{state | pending: pending}
    end
  end

  # A timer that already fired has queued its {:expire, id}; drop it, or the
  # grace period below would end at once.
  defp cancel_expiry(nil, _id), do: :ok

  defp cancel_expiry(timer, id) do
    if Process.cancel_timer(timer) == false do
      receive do
        {:expire, ^id} -> :ok
      after
        0 -> :ok
      end
    end

    :ok
  end

  defp resubscribe(state) do
    Enum.reduce(state.subscriptions, state, fn {sub_id, sub}, acc ->
      id = acc.next_id

      kind = {:resubscribe, sub_id}
      acc = send_command(acc, sub.type, sub.payload, nil, kind, acc.config.connect_timeout)

      %{
        acc
        | ha_subs: Map.put(acc.ha_subs, id, sub_id),
          sub_ha_ids: Map.put(acc.sub_ha_ids, sub_id, id)
      }
    end)
  end

  # Events for an id with no tracked subscription (one made through
  # command/4) go to the controller, as every event did in 0.2; events for
  # a cancelled subscription are dropped.
  defp deliver(state, ha_id, payload) do
    cond do
      MapSet.member?(state.retired, ha_id) ->
        :ok

      Map.has_key?(state.ha_subs, ha_id) ->
        sub = Map.fetch!(state.subscriptions, Map.fetch!(state.ha_subs, ha_id))
        deliver_to(state, sub.subscriber, payload)

      true ->
        notify(state, payload)
    end

    state
  end

  defp deliver_to(state, :controller, payload), do: notify(state, payload)
  defp deliver_to(_state, pid, payload), do: send(pid, {:hassock, self(), payload})

  # -- Keepalive --

  defp schedule_ping(%State{config: %Config{ping_interval: nil}} = state), do: state

  # Each ping cycle gets a fresh ref, so a timer message that was already
  # queued when its timer was cancelled can't act on a later cycle.
  defp schedule_ping(state) do
    ref = make_ref()
    timer = Process.send_after(self(), {:ping, ref}, state.config.ping_interval)
    %{state | ping_timer: timer, ping_ref: ref}
  end

  defp send_ping(state) do
    id = state.next_id
    send_text(state, Protocol.encode_ping(id))
    ref = make_ref()
    timer = Process.send_after(self(), {:pong_timeout, ref}, state.config.ping_timeout)
    %{state | next_id: id + 1, ping_timer: nil, pong_timer: timer, ping_ref: ref, ping_id: id}
  end

  defp cancel_ping(state) do
    if state.ping_timer, do: Process.cancel_timer(state.ping_timer)
    if state.pong_timer, do: Process.cancel_timer(state.pong_timer)
    %{state | ping_timer: nil, pong_timer: nil, ping_ref: nil, ping_id: nil}
  end

  defp cancel_connect_timer(%State{connect_timer: nil} = state), do: state

  defp cancel_connect_timer(state) do
    Process.cancel_timer(state.connect_timer)
    %{state | connect_timer: nil, connect_ref: nil}
  end

  # -- Internals --

  defp send_text(%State{socket: socket}, text), do: Socket.send_text(socket, text)

  defp notify(%State{controlling_pid: nil}, _payload), do: :ok

  defp notify(%State{controlling_pid: pid}, payload) do
    send(pid, {:hassock, self(), payload})
  end

  defp notify_lifecycle(state, payload) do
    notify(state, payload)

    for {pid, _monitor} <- state.watchers, pid != state.controlling_pid do
      send(pid, {:hassock, self(), payload})
    end

    :ok
  end

  defp now, do: System.monotonic_time(:millisecond)

  # Send a sync reply through a `:reply_demonitor` alias ref. If the caller
  # has already timed out and deactivated the alias, the runtime silently
  # drops this message - no orphaned response piles up in their mailbox.
  defp reply(ref, response), do: send(ref, {:hassock_response, ref, response})

  # Ref-correlated request answered from handle_cast, so the connection can
  # reply later (when HA's result arrives) without blocking a GenServer.call.
  # The monitor doubles as a process alias (`:reply_demonitor`) so that:
  #   - the caller can `send/2` directly to `ref` from Connection,
  #   - after the reply fires, the alias auto-deactivates (one-shot),
  #   - on timeout, demonitor+flush deactivates the alias and drains `:DOWN`,
  # ensuring late replies are discarded rather than leaking into the mailbox.
  defp sync_request(conn, request, timeout) do
    case GenServer.whereis(conn) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid, alias: :reply_demonitor)
        GenServer.cast(pid, {:sync, request, ref})

        receive do
          {:hassock_response, ^ref, response} ->
            response

          {:DOWN, ^ref, :process, _, reason} ->
            {:error, {:connection_down, reason}}
        after
          timeout ->
            Process.demonitor(ref, [:flush])
            GenServer.cast(pid, {:sync, {:cancel, ref}, nil})
            # A reply that raced the timeout is already in the mailbox.
            receive do
              {:hassock_response, ^ref, _} -> :ok
            after
              0 -> :ok
            end

            {:error, :timeout}
        end

      _ ->
        {:error, {:connection_down, :noproc}}
    end
  end
end
