defmodule Hassock.Config do
  @moduledoc """
  Configuration for connecting to a Home Assistant instance.

    * `:url` - base URL, e.g. `"http://homeassistant.local:8123"` (required)
    * `:token` - a long-lived access token (required)
    * `:ssl_options` - `:ssl` client options for `https://` URLs, used
      instead of the defaults. When `nil` (the default), the server
      certificate is verified against the system CA store
      (`:public_key.cacerts_get/0`); if the system has no store (common on
      Nerves), a warning is logged and the certificate is **not** verified.
      To verify without a system store, pass CAs yourself, e.g.
      `[verify: :verify_peer, cacertfile: CAStore.file_path()]` with the
      `castore` package, or `[verify: :verify_peer, cacertfile:
      "/data/ha-ca.pem"]` for a self-signed certificate. These replace the
      defaults; add `customize_hostname_check: [match_fun:
      :public_key.pkix_verify_hostname_match_fun(:https)]` for wildcard
      certificates. Pass `[verify: :verify_none]` to skip
      verification explicitly. Plain `http://` sends the token unencrypted.
    * `:ping_interval` - ms between keepalive pings while connected
      (default `30_000`); `nil` disables pings
    * `:ping_timeout` - ms to wait for the pong before the connection is
      treated as dead and re-established (default `10_000`)
    * `:backoff_initial` / `:backoff_max` - reconnect delay bounds in ms
      (default `1_000` / `30_000`); see `Hassock.Connection.Backoff`
    * `:connect_timeout` - ms from the start of a connection attempt to
      `auth_ok` before the attempt is abandoned, and ms HA gets to answer
      each subscription restore before the connection is re-made
      (default `15_000`)

  `inspect/1` leaves out `:token` and `:ssl_options`, so they don't end up
  in logs or crash reports.
  """

  require Logger

  @type t :: %__MODULE__{
          url: String.t(),
          token: String.t(),
          ssl_options: [:ssl.tls_client_option()] | nil,
          ping_interval: pos_integer | nil,
          ping_timeout: pos_integer,
          backoff_initial: pos_integer,
          backoff_max: pos_integer,
          connect_timeout: pos_integer
        }

  @derive {Inspect, except: [:token, :ssl_options]}
  @enforce_keys [:url, :token]
  defstruct [
    :url,
    :token,
    ssl_options: nil,
    ping_interval: 30_000,
    ping_timeout: 10_000,
    backoff_initial: 1_000,
    backoff_max: 30_000,
    connect_timeout: 15_000
  ]

  @doc """
  Build the WebSocket URL from a base HA URL.

  Converts `http://` to `ws://` and `https://` to `wss://` (in any letter
  case), and appends `/api/websocket`.
  """
  @spec websocket_url(t()) :: String.t()
  def websocket_url(%__MODULE__{url: url}) do
    url =
      case String.split(url, "://", parts: 2) do
        [scheme, rest] -> ws_scheme(String.downcase(scheme)) <> "://" <> rest
        [_no_scheme] -> url
      end

    String.trim_trailing(url, "/") <> "/api/websocket"
  end

  defp ws_scheme("http"), do: "ws"
  defp ws_scheme("https"), do: "wss"
  defp ws_scheme(scheme), do: scheme

  @doc """
  WebSockex connection options for this config: TLS settings for `wss://`,
  nothing for `ws://`.
  """
  @spec websocket_options(t()) :: keyword
  def websocket_options(%__MODULE__{} = config) do
    if URI.parse(websocket_url(config)).scheme == "wss" do
      [ssl_options: config.ssl_options || default_ssl_options()]
    else
      []
    end
  end

  defp default_ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  rescue
    error ->
      Logger.warning(
        "Hassock: no system CA certificates (#{Exception.message(error)}); " <>
          "the server certificate will NOT be verified. Set ssl_options in Hassock.Config."
      )

      [verify: :verify_none]
  end
end
