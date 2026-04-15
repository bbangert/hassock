defmodule Hassock.Core.ServiceCall do
  @moduledoc """
  A request to call a Home Assistant service.
  """

  @type t :: %__MODULE__{
          domain: String.t(),
          service: String.t(),
          target: map() | nil,
          service_data: map()
        }

  @enforce_keys [:domain, :service]
  defstruct [:domain, :service, :target, service_data: %{}]
end
