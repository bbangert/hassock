defmodule Hassock.Cache do
  @moduledoc """
  Optional ETS-backed cache of all Home Assistant entity states.

  Subscribes the underlying `Hassock.Connection` to every entity using HA's
  `subscribe_entities` command. The first event payload contains the full
  initial snapshot; later payloads ship compressed `a`/`c`/`r` deltas
  including newly created and deleted entities. ETS is kept in sync.

  ## Ownership

  Starting a cache for a connection **transfers ownership of that
  connection to the cache** (`Hassock.Connection.controlling_process/2`).
  The transfer is performed inside `start_link/1` itself — so the process
  that calls `start_link/1` must currently own the connection.

  The same caller becomes the cache's own controlling process and receives:

    * `{:hassock_cache, cache, :ready}` — after the initial snapshot loads, and
      again after each reconnect once the table is back in sync
    * `{:hassock_cache, cache, {:changes, %{added: _, changed: _, removed: _}}}`
       — after each delta event, and before `:ready` after a reconnect with
       whatever changed during the outage (entities removed in the meantime
       are deleted from the table and listed in `removed`)
    * `{:hassock_cache, cache, :disconnected}` — on socket loss (ETS retained)
    * `{:hassock_cache, cache, {:auth_failed, reason}}` — HA rejected the
      token; the connection has stopped retrying

  The initial load sends only `:ready`; read the table then.

  Use `controlling_process/2` to hand cache events to a different pid. To
  override the initial controller (e.g. when starting under a supervisor),
  pass `:controlling_pid` in the options.

  Read API (`get/2`, `get_all/1`, `get_domain/2`) reads ETS directly with no
  GenServer roundtrip, for a cache given by pid or registered name.

  Requires Home Assistant >= 2022.4 (when `subscribe_entities` was added).
  """

  use GenServer
  require Logger

  alias Hassock.{Connection, EntityState, Protocol, TableRef}

  defmodule State do
    @moduledoc false
    defstruct [
      :table,
      :connection,
      :controlling_pid,
      :controlling_monitor,
      :subscription_id,
      :retry_timer,
      retry: 5_000,
      acquired: false,
      # ready: the table matches HA; loaded: it has matched HA at least once,
      # so the next snapshot is a resync to diff, not the initial load
      ready: false,
      loaded: false
    ]
  end

  # -- Public API --

  @doc """
  Start a state cache wired to a `Connection`.

  Options:

    * `:connection` — pid or registered name of a `Hassock.Connection` (required)
    * `:controlling_pid` — pid that should receive cache events (default: caller)
    * `:name` — register the cache under this name (optional)
    * `:table_name` — explicit ETS table name (optional)
    * `:retry` — ms between attempts to re-subscribe after a failed
      `subscribe_entities` (default `5_000`)

  The caller must currently own the connection. Ownership is transferred to
  the new cache as part of `start_link/1`.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    conn = Keyword.fetch!(opts, :connection)
    gen_opts = Keyword.take(opts, [:name])
    init_opts = Keyword.put_new(opts, :controlling_pid, self())

    case GenServer.start_link(__MODULE__, init_opts, gen_opts) do
      {:ok, cache} = ok ->
        case Connection.controlling_process(conn, cache) do
          :ok ->
            GenServer.cast(cache, :connection_acquired)
            ok

          {:error, reason} ->
            GenServer.stop(cache)
            {:error, {:cannot_take_connection, reason}}
        end

      other ->
        other
    end
  end

  @doc "Transfer cache ownership. Only the current controller may transfer."
  @spec controlling_process(GenServer.server(), pid) ::
          :ok | {:error, :not_owner | :not_alive}
  def controlling_process(cache, new_pid) when is_pid(new_pid) do
    GenServer.call(cache, {:set_controlling, self(), new_pid})
  end

  @doc "Look up an entity by id. Returns `nil` if not cached."
  @spec get(GenServer.server(), String.t()) :: EntityState.t() | nil
  def get(cache, entity_id) do
    with table when table != nil <- TableRef.lookup(__MODULE__, cache),
         [{^entity_id, state}] <- :ets.lookup(table, entity_id) do
      state
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "All cached entities."
  @spec get_all(GenServer.server()) :: [EntityState.t()]
  def get_all(cache) do
    case TableRef.lookup(__MODULE__, cache) do
      nil -> []
      table -> :ets.select(table, [{{:_, :"$1"}, [], [:"$1"]}])
    end
  rescue
    ArgumentError -> []
  end

  @doc "All cached entities whose `entity_id` starts with `\"<domain>.\"`."
  @spec get_domain(GenServer.server(), String.t()) :: [EntityState.t()]
  def get_domain(cache, domain) do
    prefix = domain <> "."
    Enum.filter(get_all(cache), &String.starts_with?(&1.entity_id, prefix))
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    connection = resolve_connection(Keyword.fetch!(opts, :connection))
    name = Keyword.get(opts, :name)
    controlling_pid = Keyword.fetch!(opts, :controlling_pid)

    table_name =
      Keyword.get(
        opts,
        :table_name,
        :"hassock_cache_#{:erlang.unique_integer([:positive])}"
      )

    table = :ets.new(table_name, [:set, :public, read_concurrency: true])
    TableRef.register(__MODULE__, table, name)
    monitor = Process.monitor(controlling_pid)

    state = %State{
      table: table,
      retry: Keyword.get(opts, :retry, 5_000),
      connection: connection,
      controlling_pid: controlling_pid,
      controlling_monitor: monitor
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:table, _from, state), do: {:reply, state.table, state}

  def handle_call({:set_controlling, caller, new_pid}, _from, state) do
    cond do
      state.controlling_pid not in [nil, caller] ->
        {:reply, {:error, :not_owner}, state}

      not Process.alive?(new_pid) ->
        {:reply, {:error, :not_alive}, state}

      true ->
        if state.controlling_monitor,
          do: Process.demonitor(state.controlling_monitor, [:flush])

        monitor = Process.monitor(new_pid)
        {:reply, :ok, %{state | controlling_pid: new_pid, controlling_monitor: monitor}}
    end
  end

  @impl true
  def handle_cast(:connection_acquired, state) do
    state = %{state | acquired: true}

    if Connection.connected?(state.connection),
      do: {:noreply, ensure_subscription(state)},
      else: {:noreply, state}
  end

  # The connection restores the subscription after a reconnect, so this only
  # subscribes when no subscription exists yet (or the last attempt failed).
  @impl true
  def handle_info({:hassock, conn, :connected}, %State{connection: conn, acquired: true} = state) do
    {:noreply, ensure_subscription(state)}
  end

  def handle_info(
        {:hassock, conn, {:event, {:entities, payload}}},
        %State{connection: conn} = state
      ) do
    {:noreply, handle_entities(payload, state)}
  end

  def handle_info({:hassock, conn, {:disconnected, _reason}}, %State{connection: conn} = state) do
    notify(state, :disconnected)
    {:noreply, %{state | ready: false}}
  end

  def handle_info({:hassock, conn, {:auth_failed, reason}}, %State{connection: conn} = state) do
    notify(state, {:auth_failed, reason})
    {:noreply, state}
  end

  # The connection couldn't restore the subscription after a reconnect.
  def handle_info(
        {:hassock, conn, {:subscription_lost, sub_id, _error}},
        %State{connection: conn, subscription_id: sub_id} = state
      ) do
    {:noreply, ensure_subscription(%{state | subscription_id: nil, ready: false})}
  end

  def handle_info({:hassock, _conn, _payload}, state), do: {:noreply, state}

  def handle_info(:resubscribe, %State{subscription_id: nil} = state) do
    state = %{state | retry_timer: nil}

    if Connection.connected?(state.connection),
      do: {:noreply, ensure_subscription(state)},
      else: {:noreply, state}
  end

  def handle_info(:resubscribe, state), do: {:noreply, %{state | retry_timer: nil}}

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %State{controlling_monitor: ref} = state
      ) do
    Logger.warning("Hassock.Cache: controller died; cache events dropped until new owner set")

    {:noreply, %{state | controlling_pid: nil, controlling_monitor: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Internals --

  defp resolve_connection(pid) when is_pid(pid), do: pid

  defp resolve_connection(name) when is_atom(name) do
    Process.whereis(name) || raise ArgumentError, "#{inspect(name)} is not a registered process"
  end

  defp ensure_subscription(%State{subscription_id: nil} = state) do
    # Bound to this process, so the subscription ends with the cache even
    # when the connection outlives it.
    case Connection.subscribe_entities(state.connection, nil, to: self()) do
      {:ok, sub_id} ->
        %{state | subscription_id: sub_id, ready: false}

      {:error, reason} ->
        # A later :connected also retries; this covers an HA-side error.
        Logger.error("Hassock.Cache: subscribe_entities failed: #{inspect(reason)}")
        schedule_resubscribe(state)
    end
  end

  defp ensure_subscription(state), do: %{state | ready: false}

  defp schedule_resubscribe(%State{retry_timer: nil} = state),
    do: %{state | retry_timer: Process.send_after(self(), :resubscribe, state.retry)}

  defp schedule_resubscribe(state), do: state

  # The first event of a (re)subscription is a full snapshot in `added`.
  defp handle_entities(%{added: added} = payload, %State{ready: false, loaded: false} = state) do
    :ets.insert(state.table, Enum.to_list(added))
    Logger.info("Hassock.Cache: loaded #{map_size(added)} entities")
    notify(state, :ready)

    handle_entities(%{payload | added: %{}}, %{state | ready: true, loaded: true})
  end

  defp handle_entities(%{added: snapshot} = payload, %State{ready: false} = state) do
    changes = resync(state.table, snapshot)
    Logger.info("Hassock.Cache: resynced #{map_size(snapshot)} entities")

    if changes.added != [] or changes.changed != [] or changes.removed != [] do
      notify(state, {:changes, changes})
    end

    notify(state, :ready)
    handle_entities(%{payload | added: %{}}, %{state | ready: true})
  end

  defp handle_entities(payload, state) do
    %{added: added, changed: changed, removed: removed} = payload

    new_added =
      Enum.map(added, fn {entity_id, %EntityState{} = es} ->
        :ets.insert(state.table, {entity_id, es})
        {entity_id, es}
      end)

    changed_results =
      changed
      |> Enum.map(fn {entity_id, diff} -> apply_change(state.table, entity_id, diff) end)
      |> Enum.reject(&is_nil/1)

    Enum.each(removed, fn entity_id -> :ets.delete(state.table, entity_id) end)

    if new_added != [] or changed_results != [] or removed != [] do
      notify(state, {:changes, %{added: new_added, changed: changed_results, removed: removed}})
    end

    state
  end

  # Replace the table's contents with a snapshot and report the difference.
  # `last_updated`-only churn doesn't count as a change.
  defp resync(table, snapshot) do
    {added, changed} =
      Enum.reduce(snapshot, {[], []}, fn {entity_id, new}, acc ->
        classify(:ets.lookup(table, entity_id), entity_id, new, acc)
      end)

    removed =
      for [entity_id] <- :ets.match(table, {:"$1", :_}),
          not Map.has_key?(snapshot, entity_id),
          do: entity_id

    :ets.insert(table, Enum.to_list(snapshot))
    Enum.each(removed, &:ets.delete(table, &1))
    %{added: added, changed: changed, removed: removed}
  end

  defp classify([], entity_id, new, {added, changed}), do: {[{entity_id, new} | added], changed}

  defp classify([{_id, old}], entity_id, new, {added, changed} = acc) do
    if Protocol.state_changed?(old, new),
      do: {added, [{entity_id, new, old} | changed]},
      else: acc
  end

  defp apply_change(table, entity_id, %{added: added_keys, removed: removed_keys}) do
    case :ets.lookup(table, entity_id) do
      [] ->
        nil

      [{^entity_id, %EntityState{} = current}] ->
        attrs = current.attributes
        attrs = drop_attrs(attrs, removed_keys)
        attrs = Map.merge(attrs, Map.get(added_keys, :attributes, %{}))

        new_state = %EntityState{
          entity_id: entity_id,
          state: Map.get(added_keys, :state, current.state),
          attributes: attrs,
          last_changed: Map.get(added_keys, :last_changed, current.last_changed),
          last_updated: Map.get(added_keys, :last_updated, current.last_updated)
        }

        :ets.insert(table, {entity_id, new_state})
        {entity_id, new_state, current}
    end
  end

  defp drop_attrs(attrs, %{attributes: keys}) when is_list(keys), do: Map.drop(attrs, keys)
  defp drop_attrs(attrs, _), do: attrs

  defp notify(%State{controlling_pid: nil}, _payload), do: :ok

  defp notify(%State{controlling_pid: pid}, payload) do
    send(pid, {:hassock_cache, self(), payload})
  end
end
