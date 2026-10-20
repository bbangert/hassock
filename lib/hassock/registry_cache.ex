defmodule Hassock.RegistryCache do
  @moduledoc """
  Optional ETS-backed cache of Home Assistant's floor, area, device, entity
  and label registries.

  On every `:connected` (the first and each reconnect) it subscribes to the
  five `*_registry_updated` events (once; the connection restores them after
  a reconnect) and lists all five registries. When an update event arrives it
  re-lists that registry, debounced (default 500 ms) so a burst of updates,
  such as an integration adding fifty entities, costs one list. Failed loads
  and re-lists are retried while connected.

  It doesn't take ownership of the connection (it uses
  `Hassock.Connection.watch/1`), so it runs beside a `Hassock.Cache` or any
  other controller. Lists run in a linked task, so the cache stays
  responsive (and stops promptly) while a large registry loads.

  The controlling process (default: the caller of `start_link/1`) receives:

    * `{:hassock_registry, cache, :ready}` - after all five registries are
      loaded, again after each reconnect
    * `{:hassock_registry, cache, {:changed, kind}}` - after a registry was
      re-listed because it changed

  Reads (`list/2`, `get/3`) go to ETS directly, with no GenServer call.
  Data is kept while disconnected.
  """

  use GenServer
  require Logger

  alias Hassock.{Connection, Protocol, Registries, TableRef}

  defmodule State do
    @moduledoc false
    defstruct [
      :connection,
      :table,
      :controlling_pid,
      :controlling_monitor,
      :debounce,
      :retry,
      # the running list task: {task_ref, :load | {:relist, kind}, generation}
      :task,
      :load_timer,
      # pids of started tasks whose exit signal hasn't arrived yet
      task_pids: MapSet.new(),
      # bumped on every :connected and :disconnected, so a task result from
      # an earlier session can be told apart from a current one
      generation: 0,
      # subscription ids lost while a task was running; its result mustn't
      # add them back
      lost: MapSet.new(),
      connected: false,
      ready: false,
      # a full load is due once the running task finishes
      load_wanted: false,
      # event type => subscription id; the connection restores these on reconnect
      subscribed: %{},
      # kind => timer for its debounced (or retried) re-list
      timers: %{},
      # kinds whose re-list came due while a task was running
      queued: MapSet.new()
    ]
  end

  @default_debounce 500
  @default_retry 5_000

  # -- Public API --

  @doc """
  Start a registry cache for a connection.

  Options:

    * `:connection` - pid or registered name of a `Hassock.Connection` (required)
    * `:controlling_pid` - receiver of registry messages (default: caller)
    * `:name` - register the cache under this name (optional)
    * `:debounce` - ms to wait after an update event before re-listing
      (default #{@default_debounce})
    * `:retry` - ms before retrying a failed load or re-list (default #{@default_retry})
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.put_new(opts, :controlling_pid, self())
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Transfer cache ownership. Only the current controller may transfer, or
  anyone once the controller has exited.
  """
  @spec controlling_process(GenServer.server(), pid) :: :ok | {:error, :not_owner | :not_alive}
  def controlling_process(cache, new_pid) when is_pid(new_pid) do
    GenServer.call(cache, {:set_controlling, self(), new_pid})
  end

  @doc "All cached items of one registry (`Hassock.Registries.kinds/0`), sorted by id."
  @spec list(GenServer.server(), Registries.kind()) :: [struct]
  def list(cache, kind) do
    case TableRef.lookup(__MODULE__, cache) do
      nil -> []
      table -> :ets.select(table, [{{{kind, :_}, :"$1"}, [], [:"$1"]}])
    end
  rescue
    ArgumentError -> []
  end

  @doc "One cached item by kind and id, or `nil`."
  @spec get(GenServer.server(), Registries.kind(), String.t()) :: struct | nil
  def get(cache, kind, id) do
    with table when table != nil <- TableRef.lookup(__MODULE__, cache),
         [{_key, item}] <- :ets.lookup(table, {kind, id}) do
      item
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    # Trap exits so a crashing list task arrives as :DOWN instead of taking
    # the cache down with it (other exits stop the cache; see handle_info/2).
    Process.flag(:trap_exit, true)
    controlling_pid = Keyword.fetch!(opts, :controlling_pid)
    name = Keyword.get(opts, :name)
    table = :ets.new(__MODULE__, [:ordered_set, :public, read_concurrency: true])
    TableRef.register(__MODULE__, table, name)

    state = %State{
      connection: Keyword.fetch!(opts, :connection),
      table: table,
      controlling_pid: controlling_pid,
      controlling_monitor: Process.monitor(controlling_pid),
      debounce: Keyword.get(opts, :debounce, @default_debounce),
      retry: Keyword.get(opts, :retry, @default_retry)
    }

    {:ok, state, {:continue, :watch}}
  end

  @impl true
  def handle_continue(:watch, state) do
    case Connection.watch(state.connection) do
      {:ok, :connected} -> {:noreply, want_load(%{state | connected: true})}
      {:ok, _status} -> {:noreply, state}
      {:error, reason} -> {:stop, {:cannot_watch_connection, reason}, state}
    end
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
        if state.controlling_monitor, do: Process.demonitor(state.controlling_monitor, [:flush])
        monitor = Process.monitor(new_pid)
        {:reply, :ok, %{state | controlling_pid: new_pid, controlling_monitor: monitor}}
    end
  end

  @impl true
  def handle_info({:hassock, _conn, :connected}, state) do
    {:noreply, want_load(%{state | connected: true, generation: state.generation + 1})}
  end

  def handle_info({:hassock, _conn, {:disconnected, _reason}}, state) do
    {:noreply, %{state | connected: false, ready: false, generation: state.generation + 1}}
  end

  def handle_info({:hassock, _conn, {:event, {:registry_updated, kind, _action, _id}}}, state) do
    {:noreply, schedule_relist(state, kind, state.debounce)}
  end

  # The connection couldn't restore a subscription: subscribe again and
  # re-list, since its updates may have been missed.
  def handle_info({:hassock, _conn, {:subscription_lost, sub_id, _error}}, state) do
    subscribed = Map.reject(state.subscribed, fn {_type, id} -> id == sub_id end)
    lost = if state.task, do: MapSet.put(state.lost, sub_id), else: state.lost
    {:noreply, want_load(%{state | subscribed: subscribed, lost: lost, ready: false})}
  end

  def handle_info({:relist, kind}, state) do
    state = %{state | timers: Map.delete(state.timers, kind)}

    cond do
      not state.connected -> {:noreply, state}
      state.task != nil -> {:noreply, %{state | queued: MapSet.put(state.queued, kind)}}
      true -> {:noreply, start_task(state, {:relist, kind})}
    end
  end

  def handle_info(:load, state) do
    state = %{state | load_timer: nil}

    if state.connected and not state.ready,
      do: {:noreply, want_load(state)},
      else: {:noreply, state}
  end

  def handle_info({ref, result}, %State{task: {ref, job, generation}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | task: nil} |> finish(job, generation, result) |> next_task()}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{task: {ref, job, generation}} = state
      ) do
    result = {:error, {:task_crashed, reason}}
    {:noreply, %{state | task: nil} |> finish(job, generation, result) |> next_task()}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{controlling_monitor: ref} = state) do
    Logger.warning(
      "Hassock.RegistryCache: controller died; registry events dropped until new owner set"
    )

    {:noreply, %{state | controlling_pid: nil, controlling_monitor: nil}}
  end

  # Tasks' exits are handled through their monitors. Any other linked
  # process that exits is the Registry partition holding this cache's table
  # registration: without it reads find nothing, so stop and let the
  # supervisor start a cache that registers again.
  def handle_info({:EXIT, pid, reason}, state) do
    if MapSet.member?(state.task_pids, pid),
      do: {:noreply, %{state | task_pids: MapSet.delete(state.task_pids, pid)}},
      else: {:stop, {:linked_exit, reason}, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Tasks --

  defp want_load(%State{task: nil} = state), do: start_task(%{state | load_wanted: false}, :load)
  defp want_load(state), do: %{state | load_wanted: true}

  # A full load means the table isn't known to be current until it
  # finishes, so a failed attempt must still schedule a retry.
  defp start_task(state, :load = job), do: do_start_task(%{state | ready: false}, job)
  defp start_task(state, job), do: do_start_task(state, job)

  defp do_start_task(state, job) do
    conn = state.connection
    parent = self()
    missing = Enum.reject(Protocol.registry_event_types(), &Map.has_key?(state.subscribed, &1))
    task = Task.async(fn -> run(job, conn, parent, missing) end)

    %{
      state
      | task: {task.ref, job, state.generation},
        task_pids: MapSet.put(state.task_pids, task.pid)
    }
  end

  # A full load supersedes queued re-lists.
  defp next_task(%State{load_wanted: true, connected: true} = state),
    do: start_task(%{state | load_wanted: false, queued: MapSet.new()}, :load)

  defp next_task(%State{connected: true} = state) do
    case Enum.take(state.queued, 1) do
      [kind] -> start_task(%{state | queued: MapSet.delete(state.queued, kind)}, {:relist, kind})
      [] -> state
    end
  end

  defp next_task(state), do: %{state | load_wanted: false, queued: MapSet.new()}

  # Runs in the task. Subscribe before listing, so an update between the two
  # isn't missed.
  defp run(:load, conn, parent, missing) do
    {subscribed, result} = subscribe(conn, parent, missing)
    {subscribed, with(:ok <- result, do: list_all(conn))}
  end

  defp run({:relist, kind}, conn, _parent, _missing), do: {%{}, Registries.list(conn, kind)}

  defp list_all(conn) do
    Enum.reduce_while(Registries.kinds(), {:ok, %{}}, fn kind, {:ok, acc} ->
      case Registries.list(conn, kind) do
        {:ok, items} -> {:cont, {:ok, Map.put(acc, kind, items)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp subscribe(conn, parent, types) do
    Enum.reduce_while(types, {%{}, :ok}, fn type, {acc, :ok} ->
      case Connection.subscribe_events(conn, type, to: parent) do
        {:ok, sub_id} -> {:cont, {Map.put(acc, type, sub_id), :ok}}
        {:error, reason} -> {:halt, {acc, {:error, reason}}}
      end
    end)
  end

  # Subscriptions the task made are kept whatever the outcome (minus any
  # lost meanwhile); its data only if the session it read from is current.
  defp finish(state, job, generation, result) do
    {subscribed, result} =
      case result do
        {:error, _} = error -> {%{}, error}
        {subscribed, result} -> {subscribed, result}
      end

    kept = Map.reject(subscribed, fn {_type, id} -> MapSet.member?(state.lost, id) end)
    state = %{state | subscribed: Map.merge(state.subscribed, kept), lost: MapSet.new()}

    if generation == state.generation do
      apply_result(state, job, result)
    else
      Logger.debug("Hassock.RegistryCache: dropping a result from a previous connection")
      state
    end
  end

  defp apply_result(state, :load, {:ok, lists}) do
    Enum.each(lists, fn {kind, items} -> replace(state.table, kind, items) end)
    Logger.info("Hassock.RegistryCache: loaded registries")
    notify(state, :ready)
    %{state | ready: true}
  end

  defp apply_result(state, :load, {:error, reason}) do
    Logger.warning("Hassock.RegistryCache: load failed (#{inspect(reason)}), retrying")
    if state.connected, do: schedule_load(state), else: state
  end

  defp apply_result(state, {:relist, kind}, {:ok, items}) do
    replace(state.table, kind, items)
    notify(state, {:changed, kind})
    state
  end

  defp apply_result(state, {:relist, kind}, {:error, reason}) do
    Logger.warning("Hassock.RegistryCache: re-listing #{kind} failed: #{inspect(reason)}")
    # While disconnected, the full load on :connected covers it.
    if state.connected, do: schedule_relist(state, kind, state.retry), else: state
  end

  defp schedule_load(%State{load_timer: nil} = state),
    do: %{state | load_timer: Process.send_after(self(), :load, state.retry)}

  defp schedule_load(state), do: state

  defp schedule_relist(state, kind, delay) do
    if Map.has_key?(state.timers, kind) do
      state
    else
      timer = Process.send_after(self(), {:relist, kind}, delay)
      %{state | timers: Map.put(state.timers, kind, timer)}
    end
  end

  # -- Internals --

  # Insert the new rows, then delete the ones that are gone, so a reader sees
  # every surviving item throughout.
  defp replace(table, kind, items) do
    rows = Enum.map(items, &{{kind, Registries.id(&1)}, &1})
    :ets.insert(table, rows)
    keep = MapSet.new(rows, &elem(&1, 0))

    for [key] <- :ets.match(table, {{kind, :"$1"}, :_}),
        not MapSet.member?(keep, {kind, key}),
        do: :ets.delete(table, {kind, key})

    :ok
  end

  defp notify(%State{controlling_pid: nil}, _payload), do: :ok

  defp notify(%State{controlling_pid: pid}, payload) do
    send(pid, {:hassock_registry, self(), payload})
  end
end
