defmodule Hassock.Supervisor do
  @moduledoc """
  Optional convenience supervisor that wires a `Hassock.Connection`,
  (optionally) a `Hassock.Cache` and (optionally) a `Hassock.RegistryCache`
  together under a `one_for_all` strategy — if any crashes, all restart from
  a clean slate.

  Equivalent to writing the pair into your own supervision tree by hand. Use
  this when you don't need finer-grained control.

  ## Options

    * `:config` — `%Hassock.Config{}` (required)
    * `:cache` — when `true`, also start a `Hassock.Cache` (default: `false`)
    * `:registries` — when `true`, also start a `Hassock.RegistryCache`
      (default: `false`)
    * `:controller` — pid that should receive events from the topmost layer
      (the cache if present, else the connection) and from the registry
      cache. Default: caller of `start_link/1`.
    * `:name` — register the supervisor under this name (optional)
    * `:connection_name` — register the connection under this name (default: `Hassock.Connection`)
    * `:cache_name` — register the cache under this name (default: `Hassock.Cache`)
    * `:registry_cache_name` — register the registry cache under this name
      (default: `Hassock.RegistryCache`)

  ## Example

      {:ok, _sup} = Hassock.Supervisor.start_link(
        config: %Hassock.Config{url: "...", token: "..."},
        cache: true,
        controller: self()
      )
      receive do
        {:hassock_cache, _cache, :ready} -> :ok
      end
  """

  use Supervisor

  alias Hassock.{Cache, Connection, RegistryCache}

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
    cache_name = Keyword.get(opts, :cache_name, Hassock.Cache)

    # With a cache, the connection starts without a controller (events are
    # dropped, not sent to this supervisor) until the cache claims it.
    conn_opts = [
      config: config,
      name: conn_name,
      controlling_pid: if(use_cache, do: nil, else: controller)
    ]

    registry_name = Keyword.get(opts, :registry_cache_name, Hassock.RegistryCache)

    children =
      [{Connection, conn_opts}] ++
        if(use_cache,
          do: [{Cache, [connection: conn_name, name: cache_name, controlling_pid: controller]}],
          else: []
        ) ++
        if(Keyword.get(opts, :registries, false),
          do: [
            {RegistryCache,
             [connection: conn_name, name: registry_name, controlling_pid: controller]}
          ],
          else: []
        )

    Supervisor.init(children, strategy: :one_for_all)
  end
end
