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
end
