defmodule Hassock.Area do
  @moduledoc """
  An area from Home Assistant's area registry (`config/area_registry/list`).
  """

  @type t :: %__MODULE__{
          area_id: String.t(),
          name: String.t(),
          floor_id: String.t() | nil,
          icon: String.t() | nil,
          picture: String.t() | nil,
          aliases: [String.t()],
          labels: [String.t()],
          temperature_entity_id: String.t() | nil,
          humidity_entity_id: String.t() | nil
        }

  defstruct [
    :area_id,
    :name,
    :floor_id,
    :icon,
    :picture,
    :temperature_entity_id,
    :humidity_entity_id,
    aliases: [],
    labels: []
  ]

  @doc "Build from an HA registry map. Unknown keys are ignored, missing keys are `nil`."
  @spec from_map(map) :: t
  def from_map(%{} = map) do
    %__MODULE__{
      area_id: map["area_id"],
      name: map["name"],
      floor_id: map["floor_id"],
      icon: map["icon"],
      picture: map["picture"],
      aliases: map["aliases"] || [],
      labels: map["labels"] || [],
      temperature_entity_id: map["temperature_entity_id"],
      humidity_entity_id: map["humidity_entity_id"]
    }
  end
end
