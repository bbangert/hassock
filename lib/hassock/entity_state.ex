defmodule Hassock.EntityState do
  @moduledoc """
  A snapshot of a Home Assistant entity's state.
  """

  @type t :: %__MODULE__{
          entity_id: String.t(),
          state: String.t(),
          attributes: map(),
          last_changed: String.t() | nil,
          last_updated: String.t() | nil
        }

  @enforce_keys [:entity_id, :state]
  defstruct [:entity_id, :state, :last_changed, :last_updated, attributes: %{}]

  @doc """
  Apply a `subscribe_entities` diff (an entry of the `changed` map in
  `t:Hassock.Protocol.entities_payload/0`) to the entity's current state.

  Removed attribute keys are dropped first, then added or changed
  attributes are merged in; `state`, `last_changed`, and `last_updated`
  are replaced when the diff carries them.
  """
  @spec apply_diff(t(), Hassock.Protocol.entity_diff()) :: t()
  def apply_diff(%__MODULE__{} = current, %{added: added} = diff) do
    attributes =
      current.attributes
      |> Map.drop(removed_attributes(diff))
      |> Map.merge(Map.get(added, :attributes, %{}))

    %{
      current
      | state: Map.get(added, :state, current.state),
        attributes: attributes,
        last_changed: Map.get(added, :last_changed, current.last_changed),
        last_updated: Map.get(added, :last_updated, current.last_updated)
    }
  end

  defp removed_attributes(%{removed: %{attributes: keys}}) when is_list(keys), do: keys
  defp removed_attributes(_diff), do: []
end
