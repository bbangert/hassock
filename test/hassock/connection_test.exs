defmodule Hassock.ConnectionTest do
  use ExUnit.Case, async: true

  alias Hassock.Connection
  alias Hassock.Connection.State

  # handle_connect/2 runs in the connection process; these tests call it
  # directly, so the test process plays the connection and `controller`
  # plays the controlling process.
  setup do
    controller = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(controller, :kill) end)
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

  describe "lovelace results" do
    # Calls handle_frame/2 directly; the pending entry's reply target is an
    # alias of the test process, so the reply lands in its mailbox.
    defp pending_state(kind) do
      ref = :erlang.alias()
      {ref, %State{authenticated: true, pending: %{7 => {ref, kind}}, next_id: 8}}
    end

    defp services_shaped_result(id) do
      Jason.encode!(%{
        type: "result",
        id: id,
        success: true,
        result: %{strategy: %{options: %{areas: %{}}, type: "original-states"}}
      })
    end

    test "a services-shaped dashboard config reaches the caller unchanged" do
      {ref, state} = pending_state(:lovelace_config)

      assert {:ok, %State{pending: pending}} =
               Connection.handle_frame({:text, services_shaped_result(7)}, state)

      assert pending == %{}
      assert_received {:hassock_response, ^ref, {:ok, %{"strategy" => _}}}
    end

    test "get_services keeps its shape detection" do
      {ref, state} = pending_state(:get_services)
      Connection.handle_frame({:text, services_shaped_result(7)}, state)
      assert_received {:hassock_response, ^ref, {:ok, %{"strategy" => ["options", "type"]}}}
    end

    test "a dashboard list is returned as maps" do
      {ref, state} = pending_state(:lovelace_dashboards)

      json =
        Jason.encode!(%{
          type: "result",
          id: 7,
          success: true,
          result: [%{id: "dashboard_energy", url_path: "dashboard-energy", mode: "storage"}]
        })

      Connection.handle_frame({:text, json}, state)

      assert_received {:hassock_response, ^ref,
                       {:ok, [%{"url_path" => "dashboard-energy", "mode" => "storage"}]}}
    end
  end

  describe "template subscriptions" do
    defp frame(map), do: {:text, Jason.encode!(map)}

    defp subscribed_state do
      ref = :erlang.alias()

      state = %State{
        authenticated: true,
        controlling_pid: self(),
        pending: %{4 => {ref, :subscribe_template}},
        next_id: 5
      }

      {:ok, state} =
        Connection.handle_frame(
          frame(%{type: "result", id: 4, success: true, result: nil}),
          state
        )

      assert_received {:hassock_response, ^ref, {:ok, 4}}
      state
    end

    test "a successful subscribe tracks the id and routes its events" do
      state = subscribed_state()
      assert MapSet.member?(state.templates, 4)

      event = frame(%{type: "event", id: 4, event: %{result: "Aan", listeners: %{}}})
      Connection.handle_frame(event, state)

      assert_received {:hassock, _, {:event, {:template, 4, %{result: "Aan"}}}}
    end

    test "an error event before the subscribe result is still a template event" do
      ref = :erlang.alias()

      state = %State{
        authenticated: true,
        controlling_pid: self(),
        pending: %{4 => {ref, :subscribe_template}}
      }

      event = frame(%{type: "event", id: 4, event: %{error: "boom", level: "WARNING"}})
      Connection.handle_frame(event, state)

      assert_received {:hassock, _, {:event, {:template, 4, %{error: "boom", level: "WARNING"}}}}
    end

    test "a failed subscribe is not tracked" do
      ref = :erlang.alias()
      state = %State{authenticated: true, pending: %{4 => {ref, :subscribe_template}}}

      result =
        frame(%{
          type: "result",
          id: 4,
          success: false,
          error: %{code: "template_error", message: "bad"}
        })

      {:ok, state} = Connection.handle_frame(result, state)

      assert MapSet.size(state.templates) == 0
      assert_received {:hassock_response, ^ref, {:error, %{"code" => "template_error"}}}
    end

    test "unsubscribing stops tracking the id" do
      state = subscribed_state()
      ref = :erlang.alias()
      state = %{state | pending: %{5 => {ref, {:unsubscribe, 4}}}}

      {:ok, state} =
        Connection.handle_frame(
          frame(%{type: "result", id: 5, success: true, result: nil}),
          state
        )

      assert_received {:hassock_response, ^ref, :ok}
      refute MapSet.member?(state.templates, 4)
    end

    test "a disconnect forgets template subscriptions" do
      state = subscribed_state()

      assert {:reconnect, %State{templates: templates}} =
               Connection.handle_disconnect(%{reason: :closed}, state)

      assert MapSet.size(templates) == 0
      assert_received {:hassock, _, {:disconnected, :closed}}
    end
  end
end
