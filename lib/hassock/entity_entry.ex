defmodule Hassock.EntityEntry do
  @moduledoc """
  An entry from Home Assistant's entity registry (`config/entity_registry/list`).

  This is registry metadata, not state: use `Hassock.EntityState` for the
  current value. HA's list doesn't include `device_class`; read it from the
  entity state's `"device_class"` attribute.

  An entity's effective area is its own `area_id`, or its device's when that
  is `nil`. `hidden_by`, `disabled_by` and `entity_category` (`"config"`,
  `"diagnostic"`) are what HA's auto-generated dashboards filter on; they are
  kept as HA's strings.
  """

  @type t :: %__MODULE__{
          entity_id: String.t(),
          id: String.t() | nil,
          name: String.t() | nil,
          original_name: String.t() | nil,
          has_entity_name: boolean,
          device_id: String.t() | nil,
          area_id: String.t() | nil,
          platform: String.t() | nil,
          config_entry_id: String.t() | nil,
          entity_category: String.t() | nil,
          hidden_by: String.t() | nil,
          disabled_by: String.t() | nil,
          icon: String.t() | nil,
          labels: [String.t()],
          categories: %{String.t() => String.t()},
          translation_key: String.t() | nil
        }

  defstruct [
    :entity_id,
    :id,
    :name,
    :original_name,
    :device_id,
    :area_id,
    :platform,
    :config_entry_id,
    :entity_category,
    :hidden_by,
    :disabled_by,
    :icon,
    :translation_key,
    has_entity_name: false,
    labels: [],
    categories: %{}
  ]

  @doc "Build from an HA registry map. Unknown keys are ignored, missing keys are `nil`."
  @spec from_map(map) :: t
  def from_map(%{} = map) do
    %__MODULE__{
      entity_id: map["entity_id"],
      id: map["id"],
      name: map["name"],
      original_name: map["original_name"],
      has_entity_name: map["has_entity_name"] == true,
      device_id: map["device_id"],
      area_id: map["area_id"],
      platform: map["platform"],
      config_entry_id: map["config_entry_id"],
      entity_category: map["entity_category"],
      hidden_by: map["hidden_by"],
      disabled_by: map["disabled_by"],
      icon: map["icon"],
      labels: map["labels"] || [],
      categories: map["categories"] || %{},
      translation_key: map["translation_key"]
    }
  end
end
