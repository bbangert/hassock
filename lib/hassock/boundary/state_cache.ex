defmodule Hassock.Boundary.StateCache do
  @moduledoc """
  Optional ETS-backed cache of all Home Assistant entity states.

  Subscribes the underlying `Connection` to every entity using HA's
  `subscribe_entities` command. The first event payload contains the full
  initial snapshot; later payloads ship compressed `a`/`c`/`r` deltas
  including newly created and deleted entities. ETS is kept in sync.

  ## Ownership

  Starting a `StateCache` for a `Connection` **transfers ownership of that
  connection to the cache** (`Hassock.Boundary.Connection.controlling_process/2`).
  The transfer is performed inside `start_link/1` itself — so the process
  that calls `start_link/1` must currently own the connection.

  The same caller becomes the cache's own controlling process and receives:

    * `{:hassock_cache, cache, :ready}` — once, after the initial snapshot loads
    * `{:hassock_cache, cache, {:changes, %{added: _, changed: _, removed: _}}}`
       — after each delta event
    * `{:hassock_cache, cache, :disconnected}` — on socket loss (ETS retained)

  Use `controlling_process/2` to hand cache events to a different pid. To
  override the initial controller (e.g. when starting under a supervisor),
  pass `:controlling_pid` in the options.

  Read API (`get/2`, `get_all/1`, `get_domain/2`) reads ETS directly with no
  GenServer roundtrip.

  Requires Home Assistant >= 2022.4 (when `subscribe_entities` was added).
  """

  use GenServer
  require Logger

  alias Hassock.Boundary.Connection
  alias Hassock.Core.EntityState

  defmodule State do
    @moduledoc false
    defstruct [
      :table,
      :connection,
      :controlling_pid,
      :controlling_monitor,
      :subscription_id,
      acquired: false,
      ready: false
    ]
  end

  # -- Public API --

  @doc """
  Start a state cache wired to a `Connection`.

  Options:

    * `:connection` — pid or registered name of a `Hassock.Boundary.Connection` (required)
    * `:controlling_pid` — pid that should receive cache events (default: caller)
    * `:name` — register the cache under this name (optional)
    * `:table_name` — explicit ETS table name (optional)

  The caller must currently own the connection. Ownership is transferred to
  the new cache as part of `start_link/1`.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    conn = Keyword.fetch!(opts, :connection)
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    init_opts = Keyword.put_new(init_opts, :controlling_pid, self())

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
    table = table_name(cache)

    case :ets.lookup(table, entity_id) do
      [{^entity_id, state}] -> state
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "All cached entities."
  @spec get_all(GenServer.server()) :: [EntityState.t()]
  def get_all(cache) do
    cache
    |> table_name()
    |> :ets.tab2list()
    |> Enum.map(fn {_id, state} -> state end)
  rescue
    ArgumentError -> []
  end

  @doc "All cached entities whose `entity_id` starts with `\"<domain>.\"`."
  @spec get_domain(GenServer.server(), String.t()) :: [EntityState.t()]
  def get_domain(cache, domain) do
    prefix = domain <> "."
    Enum.filter(get_all(cache), &String.starts_with?(&1.entity_id, prefix))
  end

  defp table_name(cache), do: GenServer.call(cache, :table)

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    connection = Keyword.fetch!(opts, :connection)
    controlling_pid = Keyword.fetch!(opts, :controlling_pid)

    table_name =
      Keyword.get(
        opts,
        :table_name,
        :"hassock_cache_#{:erlang.unique_integer([:positive])}"
      )

    table = :ets.new(table_name, [:set, :public, read_concurrency: true])
    monitor = Process.monitor(controlling_pid)

    state = %State{
      table: table,
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
      state.controlling_pid != caller ->
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

    if Connection.connected?(state.connection) do
      case start_subscription(state) do
        {:ok, new_state} -> {:noreply, new_state}
        :error -> {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:hassock, conn, :connected}, %State{connection: conn, acquired: true} = state) do
    case start_subscription(state) do
      {:ok, new_state} -> {:noreply, new_state}
      :error -> {:noreply, state}
    end
  end

  def handle_info(
        {:hassock, conn, {:event, {:entities, payload}}},
        %State{connection: conn} = state
      ) do
    {:noreply, handle_entities(payload, state)}
  end

  def handle_info({:hassock, conn, {:disconnected, _reason}}, %State{connection: conn} = state) do
    notify(state, :disconnected)
    {:noreply, %{state | ready: false, subscription_id: nil}}
  end

  def handle_info({:hassock, _conn, _payload}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %State{controlling_monitor: ref} = state
      ) do
    Logger.warning(
      "Hassock.StateCache: controller died; cache events dropped until new owner set"
    )

    {:noreply, %{state | controlling_pid: nil, controlling_monitor: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Internals --

  defp start_subscription(state) do
    case Connection.subscribe_entities(state.connection, nil) do
      {:ok, sub_id} ->
        {:ok, %{state | subscription_id: sub_id, ready: false}}

      {:error, reason} ->
        Logger.error("Hassock.StateCache: subscribe_entities failed: #{inspect(reason)}")
        :error
    end
  end

  defp handle_entities(%{added: added} = payload, %State{ready: false} = state) do
    Enum.each(added, fn {entity_id, %EntityState{} = es} ->
      :ets.insert(state.table, {entity_id, es})
    end)

    Logger.info("Hassock.StateCache: loaded #{map_size(added)} entities")
    notify(state, :ready)

    rest = %{payload | added: %{}}
    handle_entities(rest, %{state | ready: true})
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
