defmodule Hassock.Floor do
  @moduledoc """
  A floor from Home Assistant's floor registry (`config/floor_registry/list`).
  `level` orders floors (it may be `nil`).
  """

  @type t :: %__MODULE__{
          floor_id: String.t(),
          name: String.t(),
          level: integer | nil,
          icon: String.t() | nil,
          aliases: [String.t()]
        }

  defstruct [:floor_id, :name, :level, :icon, aliases: []]

  @doc "Build from an HA registry map. Unknown keys are ignored, missing keys are `nil`."
  @spec from_map(map) :: t
  def from_map(%{} = map) do
    %__MODULE__{
      floor_id: map["floor_id"],
      name: map["name"],
      level: map["level"],
      icon: map["icon"],
      aliases: map["aliases"] || []
    }
  end
end
