defmodule Hassock.Lifecycle.Supervisor do
  @moduledoc """
  Optional convenience supervisor that wires a `Connection` and (optionally)
  a `StateCache` together under a `rest_for_one` strategy.

  Equivalent to writing the pair into your own supervision tree by hand. Use
  this when you don't need finer-grained control.

  ## Options

    * `:config` — `%Hassock.Core.Config{}` (required)
    * `:cache` — when `true`, also start a `StateCache` (default: `false`)
    * `:controller` — pid that should receive events from the topmost layer
      (the cache if present, else the connection). Default: caller of
      `start_link/1`.
    * `:name` — register the supervisor under this name (optional)
    * `:connection_name` — register the connection under this name (default: `Hassock.Connection`)
    * `:cache_name` — register the cache under this name (default: `Hassock.StateCache`)

  ## Example

      {:ok, _sup} = Hassock.Lifecycle.Supervisor.start_link(
        config: %Hassock.Core.Config{url: "...", token: "..."},
        cache: true,
        controller: self()
      )
      receive do
        {:hassock_cache, _cache, :ready} -> :ok
      end
  """

  use Supervisor

  alias Hassock.Boundary.{Connection, StateCache}

  def start_link(opts) do
    sup_opts = Keyword.take(opts, [:name])
    init_opts = Keyword.put_new(opts, :controller, self())
    Supervisor.start_link(__MODULE__, init_opts, sup_opts)
  end

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    use_cache = Keyword.get(opts, :cache, false)
    controller = Keyword.fetch!(opts, :controller)
    conn_name = Keyword.get(opts, :connection_name, Hassock.Connection)
    cache_name = Keyword.get(opts, :cache_name, Hassock.StateCache)

    conn_opts =
      [config: config, name: conn_name]
      |> maybe_put(:controlling_pid, if(use_cache, do: nil, else: controller))

    children =
      [{Connection, conn_opts}] ++
        if use_cache do
          [
            {StateCache, [connection: conn_name, name: cache_name, controlling_pid: controller]}
          ]
        else
          []
        end

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
