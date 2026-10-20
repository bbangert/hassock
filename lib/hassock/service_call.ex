defmodule Hassock.ServiceCall do
  @moduledoc """
  A request to call a Home Assistant service.

  Set `return_response: true` for services that return data (for example
  `weather.get_forecasts` or `calendar.get_events`). The result map then
  carries it under `"response"`. HA rejects `return_response` for services
  that don't support it, and requires it for services that only return data.
  """

  @type t :: %__MODULE__{
          domain: String.t(),
          service: String.t(),
          target: map() | nil,
          service_data: map(),
          return_response: boolean()
        }

  @enforce_keys [:domain, :service]
  defstruct [:domain, :service, :target, service_data: %{}, return_response: false]
end
