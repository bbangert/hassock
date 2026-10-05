defmodule Hassock.ConnectionTest do
  use ExUnit.Case, async: true

  alias Hassock.Connection
  alias Hassock.Connection.State

  # handle_connect/2 runs in the connection process; these tests call it
  # directly, so the test process plays the connection and `controller`
  # plays the controlling process.
  setup do
    controller = spawn_link(fn -> Process.sleep(:infinity) end)
    %{controller: controller}
  end

  defp monitors_of(pid) do
    {:monitors, monitors} = Process.info(self(), :monitors)
    Enum.count(monitors, &match?({:process, ^pid}, &1))
  end

  describe "handle_connect/2" do
    test "monitors the controlling process on first connect", %{controller: controller} do
      state = %State{controlling_pid: controller}

      assert {:ok, %State{controlling_monitor: ref}} = Connection.handle_connect(nil, state)
      assert is_reference(ref)
      assert monitors_of(controller) == 1
    end

    test "keeps the existing monitor on reconnect instead of stacking another",
         %{controller: controller} do
      {:ok, state} = Connection.handle_connect(nil, %State{controlling_pid: controller})

      assert {:ok, ^state} = Connection.handle_connect(nil, state)
      assert {:ok, ^state} = Connection.handle_connect(nil, state)
      assert monitors_of(controller) == 1
    end
  end
end
