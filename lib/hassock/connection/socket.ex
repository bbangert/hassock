defmodule Hassock.Connection.Socket do
  @moduledoc false
  # One WebSocket connection attempt, owned by a `Hassock.Connection`.
  #
  # It parses frames and forwards them to the owner, sends what the owner
  # casts, and exits when the socket closes. It never reconnects: websockex
  # runs reconnects inside its own receive loop, where a backoff delay would
  # stall every caller. The owner schedules the next attempt instead.
  #
  # Messages to the owner, all `{:hassock_socket, socket_pid, payload}`:
  #
  #   * `:open` - the WebSocket handshake completed
  #   * `{:frame, Hassock.Protocol.parsed()}` - one inbound text frame
  #   * `{:closed, reason}` - the attempt failed or the socket closed; the
  #     process exits right after

  use WebSockex

  alias Hassock.Protocol

  @spec start_link(String.t(), pid, keyword) :: {:ok, pid} | {:error, term}
  def start_link(url, owner, ws_opts) do
    opts = [async: true, handle_initial_conn_failure: true] ++ ws_opts
    WebSockex.start_link(url, __MODULE__, owner, opts)
  end

  @spec send_text(pid, String.t()) :: :ok
  def send_text(socket, text), do: WebSockex.cast(socket, {:send, text})

  @impl true
  def handle_connect(_conn, owner) do
    send(owner, {:hassock_socket, self(), :open})
    {:ok, owner}
  end

  @impl true
  def handle_frame({:text, json}, owner) do
    send(owner, {:hassock_socket, self(), {:frame, Protocol.parse(json)}})
    {:ok, owner}
  end

  def handle_frame(_frame, owner), do: {:ok, owner}

  @impl true
  def handle_cast({:send, text}, owner), do: {:reply, {:text, text}, owner}

  @impl true
  def handle_disconnect(%{reason: reason}, owner) do
    send(owner, {:hassock_socket, self(), {:closed, reason}})
    {:ok, owner}
  end
end
