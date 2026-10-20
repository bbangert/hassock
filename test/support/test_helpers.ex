defmodule Hassock.TestHelpers do
  @moduledoc "Shared helpers for tests against `Hassock.FakeHA`."

  import ExUnit.Assertions

  alias Hassock.{Connection, FakeHA}

  @doc """
  Wait for the next authenticated socket and the matching `:connected`.
  Also consumes that socket's `:open`, so a later `:open` match can't pick
  up a socket that is already authenticated.
  """
  def await_auth(conn) do
    assert_receive {:fake_ha, sock, :authenticated}, 2_000
    assert_received {:fake_ha, ^sock, :open}
    assert_receive {:hassock, ^conn, :connected}, 2_000
    sock
  end

  @doc """
  Start a FakeHA server (stopped on test exit) and a connected Connection.
  Returns `%{ha:, conn:, sock:}`.
  """
  def connect(overrides \\ [], fake_opts \\ []) do
    ha = FakeHA.start(fake_opts)
    ExUnit.Callbacks.on_exit(fn -> FakeHA.stop(ha) end)
    {:ok, conn} = Connection.start_link(config: FakeHA.config(ha.port, overrides))
    %{ha: ha, conn: conn, sock: await_auth(conn)}
  end

  @doc "Run a subscribe in a task, answer it, return `{subscription_id, message}`."
  def subscribe(conn, sock, fun) do
    task = Task.async(fn -> fun.(conn) end)
    assert_receive {:fake_ha, ^sock, %{"id" => id} = msg}, 1_000
    FakeHA.result(sock, id, nil)
    assert {:ok, ^id} = Task.await(task)
    {id, msg}
  end

  @doc "Poll `fun` every 10 ms until it returns true; fail after `ms`."
  def wait_until(fun, ms \\ 1_000) do
    cond do
      fun.() ->
        :ok

      ms <= 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(10)
        wait_until(fun, ms - 10)
    end
  end

  @doc "How many messages in the caller's mailbox satisfy `pred`."
  def count_messages(pred) do
    {:messages, msgs} = Process.info(self(), :messages)
    Enum.count(msgs, pred)
  end
end
