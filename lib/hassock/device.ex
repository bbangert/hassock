defmodule Hassock.Device do
  @moduledoc """
  A device from Home Assistant's device registry (`config/device_registry/list`).

  `disabled_by` (`"user"`, `"integration"`, `"config_entry"`, ...) and
  `entry_type` (`"service"` for integrations that aren't physical devices)
  are kept as HA's strings.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          name_by_user: String.t() | nil,
          area_id: String.t() | nil,
          manufacturer: String.t() | nil,
          model: String.t() | nil,
          model_id: String.t() | nil,
          sw_version: String.t() | nil,
          hw_version: String.t() | nil,
          via_device_id: String.t() | nil,
          labels: [String.t()],
          disabled_by: String.t() | nil,
          entry_type: String.t() | nil
        }

  defstruct [
    :id,
    :name,
    :name_by_user,
    :area_id,
    :manufacturer,
    :model,
    :model_id,
    :sw_version,
    :hw_version,
    :via_device_id,
    :disabled_by,
    :entry_type,
    labels: []
  ]

  @doc "Build from an HA registry map. Unknown keys are ignored, missing keys are `nil`."
  @spec from_map(map) :: t
  def from_map(%{} = map) do
    %__MODULE__{
      id: map["id"],
      name: map["name"],
      name_by_user: map["name_by_user"],
      area_id: map["area_id"],
      manufacturer: map["manufacturer"],
      model: map["model"],
      model_id: map["model_id"],
      sw_version: map["sw_version"],
      hw_version: map["hw_version"],
      via_device_id: map["via_device_id"],
      labels: map["labels"] || [],
      disabled_by: map["disabled_by"],
      entry_type: map["entry_type"]
    }
  end

  @doc "The name HA shows: the user's name if set, else the integration's."
  @spec display_name(t) :: String.t() | nil
  def display_name(%__MODULE__{name_by_user: nil, name: name}), do: name
  def display_name(%__MODULE__{name_by_user: name}), do: name
end
