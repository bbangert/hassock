defmodule Hassock.Config do
  @moduledoc """
  Configuration for connecting to a Home Assistant instance.
  """

  @type t :: %__MODULE__{
          url: String.t(),
          token: String.t()
        }

  @enforce_keys [:url, :token]
  defstruct [:url, :token]

  @doc """
  Build the WebSocket URL from a base HA URL.

  Converts `http://` to `ws://` and `https://` to `wss://`,
  and appends `/api/websocket`.
  """
  @spec websocket_url(t()) :: String.t()
  def websocket_url(%__MODULE__{url: url}) do
    url
    |> String.replace_leading("http://", "ws://")
    |> String.replace_leading("https://", "wss://")
    |> String.trim_trailing("/")
    |> Kernel.<>("/api/websocket")
  end
end
