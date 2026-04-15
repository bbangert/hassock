defmodule Hassock do
  @moduledoc """
  Home Assistant WebSocket client for Elixir.

  Two layers, opt-in:

    * `Hassock.Boundary.Connection` — the WebSocket itself. Always required.
    * `Hassock.Boundary.StateCache` — optional ETS-backed full entity cache,
      kept in sync via HA's `subscribe_entities` command.

  Both follow the controlling-process pattern (à la `:gen_tcp`,
  `Circuits.UART`): the process that calls `start_link/1` is the default
  recipient of async messages. Use `controlling_process/2` to hand off.

  ## Bare connection

      {:ok, conn} =
        Hassock.connect(
          config: %Hassock.Core.Config{url: "http://homeassistant.local:8123", token: "..."}
        )

      receive do
        {:hassock, ^conn, :connected} -> :ok
      end

      {:ok, sub} = Hassock.subscribe_entities(conn, ["light.kitchen"])
      # handle {:hassock, ^conn, {:event, {:entities, _}}} in your handle_info/2

  ## With state cache

      {:ok, conn} = Hassock.connect(config: config)
      {:ok, cache} = Hassock.Boundary.StateCache.start_link(connection: conn)

      receive do
        {:hassock_cache, ^cache, :ready} -> :ok
      end

      Hassock.cached_state(cache, "light.kitchen")
  """

  alias Hassock.Boundary.{Connection, StateCache}

  @doc "Open a WebSocket connection. See `Hassock.Boundary.Connection.start_link/1`."
  defdelegate connect(opts), to: Connection, as: :start_link

  @doc "Transfer connection ownership."
  defdelegate controlling_process(conn, pid), to: Connection

  @doc "Subscribe to entity state updates. Pass `nil` for all entities."
  defdelegate subscribe_entities(conn, entity_ids \\ nil), to: Connection

  @doc "Subscribe to a non-entity HA event type."
  defdelegate subscribe_events(conn, event_type), to: Connection

  @doc "Cancel a subscription."
  defdelegate unsubscribe_events(conn, subscription_id), to: Connection

  @doc "Call a Home Assistant service."
  defdelegate call_service(conn, service_call), to: Connection

  @doc "One-shot fetch of all entity states."
  defdelegate get_states(conn), to: Connection

  @doc "Fetch all available service domains and their services."
  defdelegate get_services(conn), to: Connection

  @doc "True if the connection is authenticated and the socket is open."
  defdelegate connected?(conn), to: Connection

  @doc "Look up a cached entity by id (requires a `Hassock.Boundary.StateCache`)."
  defdelegate cached_state(cache, entity_id), to: StateCache, as: :get

  @doc "All cached entities."
  defdelegate cached_states(cache), to: StateCache, as: :get_all

  @doc "All cached entities under a domain prefix (e.g. `\"light\"`)."
  defdelegate cached_domain(cache, domain), to: StateCache, as: :get_domain
end
