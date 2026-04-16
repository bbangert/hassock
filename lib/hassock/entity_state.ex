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
end
