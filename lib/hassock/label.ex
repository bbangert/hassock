defmodule Hassock.Label do
  @moduledoc """
  A label from Home Assistant's label registry (`config/label_registry/list`).
  """

  @type t :: %__MODULE__{
          label_id: String.t(),
          name: String.t(),
          color: String.t() | nil,
          icon: String.t() | nil,
          description: String.t() | nil
        }

  defstruct [:label_id, :name, :color, :icon, :description]

  @doc "Build from an HA registry map. Unknown keys are ignored, missing keys are `nil`."
  @spec from_map(map) :: t
  def from_map(%{} = map) do
    %__MODULE__{
      label_id: map["label_id"],
      name: map["name"],
      color: map["color"],
      icon: map["icon"],
      description: map["description"]
    }
  end
end
