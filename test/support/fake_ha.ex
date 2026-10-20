defmodule Hassock.FakeHA do
  @moduledoc """
  A scriptable Home Assistant WebSocket server for tests.

  Each client socket sends `auth_required`, accepts the token `"good"`
  (`auth_ok`) and rejects any other (`auth_invalid`), and answers `ping` with
  `pong` unless told not to. Everything else the client sends is forwarded to
  the test process as `{:fake_ha, socket, decoded_message}`; the test answers
  with `result/3`, `error/4`, `event/3` or `push/2`.

  The test process also receives:

    * `{:fake_ha, socket, :open}` when a client connects
    * `{:fake_ha, socket, :authenticated}` after `auth_ok` is sent

  With `hold_auth: true`, sockets wait for `release_auth/1` before sending
  `auth_required`, which keeps a client in its authenticating phase.

  Tests that need a port nothing listens on (`free_port/0`) must run in a
  module with `async: false`, or another test's server may take the port.
  """

  alias Hassock.Config

  @token "good"

  @doc """
  Start a server. Options: `:port` (default 0, any free port),
  `:hold_auth` (default false).
  """
  def start(opts \\ []) do
    test = self()
    port = Keyword.get(opts, :port, 0)
    hold_auth = Keyword.get(opts, :hold_auth, false)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.Endpoint, %{test: test, hold_auth: hold_auth}},
        ip: :loopback,
        port: port,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{server: server, port: port}
  end

  @doc "Stop a server and drop its client sockets."
  def stop(%{server: server}) do
    Process.unlink(server)
    ref = Process.monitor(server)
    Process.exit(server, :shutdown)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      5_000 ->
        Process.demonitor(ref, [:flush])
        raise "FakeHA server didn't stop"
    end
  end

  @doc "A port nothing listens on (for server-down tests)."
  def free_port do
    {:ok, listen} = :gen_tcp.listen(0, ip: :loopback)
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end

  @doc "A config for this server, with fast backoff and pings off."
  def config(port, overrides \\ []) do
    struct!(
      %Config{
        url: "http://127.0.0.1:#{port}",
        token: @token,
        ping_interval: nil,
        backoff_initial: 20,
        backoff_max: 100
      },
      overrides
    )
  end

  def push(socket, map), do: send(socket, {:push, map})
  def push_raw(socket, text), do: send(socket, {:push_raw, text})
  def close(socket), do: send(socket, :close)
  def auto_pong(socket, on?), do: send(socket, {:auto_pong, on?})
  def release_auth(socket), do: send(socket, :release_auth)

  def result(socket, id, result),
    do: push(socket, %{id: id, type: "result", success: true, result: result})

  def error(socket, id, code, message),
    do:
      push(socket, %{
        id: id,
        type: "result",
        success: false,
        error: %{code: code, message: message}
      })

  def event(socket, id, event), do: push(socket, %{id: id, type: "event", event: event})

  defmodule Endpoint do
    @moduledoc false
    @behaviour Plug

    alias Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      conn
      |> WebSockAdapter.upgrade(Hassock.FakeHA.Socket, opts, timeout: 60_000)
      |> Conn.halt()
    end
  end

  defmodule Socket do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(opts) do
      send(opts.test, {:fake_ha, self(), :open})
      state = Map.put(opts, :auto_pong, true)
      if opts.hold_auth, do: {:ok, state}, else: auth_required(state)
    end

    defp auth_required(state),
      do:
        {:push, {:text, Jason.encode!(%{type: "auth_required", ha_version: "2026.10.0"})}, state}

    @impl true
    def handle_in({text, [opcode: :text]}, state) do
      handle_message(Jason.decode!(text), state)
    end

    def handle_in(_frame, state), do: {:ok, state}

    defp handle_message(%{"type" => "auth", "access_token" => "good"}, state) do
      send(state.test, {:fake_ha, self(), :authenticated})
      {:push, {:text, Jason.encode!(%{type: "auth_ok", ha_version: "2026.10.0"})}, state}
    end

    defp handle_message(%{"type" => "auth"}, state) do
      {:push, {:text, Jason.encode!(%{type: "auth_invalid", message: "Invalid access token"})},
       state}
    end

    defp handle_message(%{"type" => "ping", "id" => id} = msg, %{auto_pong: true} = state) do
      send(state.test, {:fake_ha, self(), msg})
      {:push, {:text, Jason.encode!(%{id: id, type: "pong"})}, state}
    end

    defp handle_message(msg, state) do
      send(state.test, {:fake_ha, self(), msg})
      {:ok, state}
    end

    @impl true
    def handle_info({:push, map}, state), do: {:push, {:text, Jason.encode!(map)}, state}
    def handle_info({:push_raw, text}, state), do: {:push, {:text, text}, state}
    def handle_info({:auto_pong, on?}, state), do: {:ok, %{state | auto_pong: on?}}
    def handle_info(:close, state), do: {:stop, :normal, state}
    def handle_info(:release_auth, state), do: auth_required(state)
  end
end
