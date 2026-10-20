defmodule Hassock.ConfigTest do
  use ExUnit.Case, async: true

  alias Hassock.Config

  describe "websocket_url/1" do
    test "converts http to ws" do
      config = %Config{url: "http://homeassistant.local:8123", token: "t"}
      assert Config.websocket_url(config) == "ws://homeassistant.local:8123/api/websocket"
    end

    test "converts https to wss" do
      config = %Config{url: "https://ha.example.com", token: "t"}
      assert Config.websocket_url(config) == "wss://ha.example.com/api/websocket"
    end

    test "strips trailing slash" do
      config = %Config{url: "http://localhost:8123/", token: "t"}
      assert Config.websocket_url(config) == "ws://localhost:8123/api/websocket"
    end
  end

  describe "websocket_options/1" do
    test "plain http needs no TLS options" do
      assert Config.websocket_options(%Config{url: "http://ha:8123", token: "t"}) == []
    end

    test "https verifies the peer against the system CA store when there is one" do
      opts = Config.websocket_options(%Config{url: "https://ha.example", token: "t"})
      ssl = Keyword.fetch!(opts, :ssl_options)

      if system_cacerts?() do
        assert ssl[:verify] == :verify_peer
        assert [_ | _] = ssl[:cacerts]
        assert ssl[:customize_hostname_check][:match_fun]
      else
        assert ssl == [verify: :verify_none]
      end
    end

    test "the scheme is matched in any letter case" do
      config = %Config{url: "HTTPS://ha.example", token: "t"}
      assert Config.websocket_url(config) == "wss://ha.example/api/websocket"
      assert Keyword.has_key?(Config.websocket_options(config), :ssl_options)
    end

    defp system_cacerts? do
      _ = :public_key.cacerts_get()
      true
    rescue
      _ -> false
    end

    test "explicit ssl_options are passed through unchanged" do
      config = %Config{url: "https://ha.local", token: "t", ssl_options: [verify: :verify_none]}
      assert Config.websocket_options(config) == [ssl_options: [verify: :verify_none]]
    end

    test "robustness defaults" do
      config = %Config{url: "http://ha", token: "t"}
      assert {config.ping_interval, config.ping_timeout} == {30_000, 10_000}
      assert {config.backoff_initial, config.backoff_max} == {1_000, 30_000}
    end
  end

  test "inspect hides the token and TLS options" do
    config = %Config{url: "http://ha", token: "secret-token", ssl_options: [password: ~c"pw"]}
    output = inspect(config)
    refute output =~ "secret-token"
    refute output =~ "pw"
    assert output =~ "http://ha"
  end
end
