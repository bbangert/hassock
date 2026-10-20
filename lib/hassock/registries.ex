defmodule Hassock.Registries do
  @moduledoc """
  Fetch Home Assistant's floor, area, device, entity and label registries.

  Each function sends the matching `config/*_registry/list` command through
  `Hassock.Connection.command/4` and decodes the items into structs.
  Options: `:timeout` in ms (default 30 s; the entity registry of a large
  install is several MB).

  `list_entities/2` uses `config/entity_registry/list`, which returns full
  entries including `hidden_by` and `disabled_by`. HA's frontend uses the
  compact `config/entity_registry/list_for_display` instead: it abbreviates
  keys and leaves out disabled entities and some fields. Call it with
  `Hassock.command/4` if you need it.

  To keep the registries current, subscribe to their update events
  (`Hassock.Protocol.registry_event_types/0`) or use `Hassock.RegistryCache`.
  """

  alias Hassock.{Area, Connection, Device, EntityEntry, Floor, Label}

  @type kind :: :floor | :area | :device | :entity | :label

  @kinds [:floor, :area, :device, :entity, :label]
  @default_timeout 30_000

  @doc "The registry kinds, in dependency order (floors before areas, ...)."
  @spec kinds() :: [kind]
  def kinds, do: @kinds

  @doc "List all floors."
  @spec list_floors(GenServer.server(), keyword) ::
          {:ok, [Floor.t()]} | {:error, Connection.command_error()}
  def list_floors(conn, opts \\ []), do: list(conn, :floor, opts)

  @doc "List all areas."
  @spec list_areas(GenServer.server(), keyword) ::
          {:ok, [Area.t()]} | {:error, Connection.command_error()}
  def list_areas(conn, opts \\ []), do: list(conn, :area, opts)

  @doc "List all devices."
  @spec list_devices(GenServer.server(), keyword) ::
          {:ok, [Device.t()]} | {:error, Connection.command_error()}
  def list_devices(conn, opts \\ []), do: list(conn, :device, opts)

  @doc "List all entity registry entries."
  @spec list_entities(GenServer.server(), keyword) ::
          {:ok, [EntityEntry.t()]} | {:error, Connection.command_error()}
  def list_entities(conn, opts \\ []), do: list(conn, :entity, opts)

  @doc "List all labels."
  @spec list_labels(GenServer.server(), keyword) ::
          {:ok, [Label.t()]} | {:error, Connection.command_error()}
  def list_labels(conn, opts \\ []), do: list(conn, :label, opts)

  @doc "List one registry by kind."
  @spec list(GenServer.server(), kind, keyword) ::
          {:ok, [struct]} | {:error, Connection.command_error() | {:unexpected_result, term}}
  def list(conn, kind, opts \\ []) when kind in @kinds do
    opts = Keyword.put_new(opts, :timeout, @default_timeout)

    case Connection.command(conn, "config/#{kind}_registry/list", %{}, opts) do
      {:ok, items} when is_list(items) -> {:ok, Enum.map(items, &decode(kind, &1))}
      {:ok, other} -> {:error, {:unexpected_result, other}}
      {:error, _} = error -> error
    end
  end

  @doc "Decode one registry item of `kind` into its struct."
  @spec decode(kind, map) :: struct
  def decode(:floor, map), do: Floor.from_map(map)
  def decode(:area, map), do: Area.from_map(map)
  def decode(:device, map), do: Device.from_map(map)
  def decode(:entity, map), do: EntityEntry.from_map(map)
  def decode(:label, map), do: Label.from_map(map)

  @doc "The key that identifies an item of `kind`."
  @spec id(struct) :: String.t()
  def id(%Floor{floor_id: id}), do: id
  def id(%Area{area_id: id}), do: id
  def id(%Device{id: id}), do: id
  def id(%EntityEntry{entity_id: id}), do: id
  def id(%Label{label_id: id}), do: id
end
