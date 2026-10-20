defmodule Hassock.TableRef do
  @moduledoc false
  # Lets readers find a process's public ETS table without a GenServer call.
  # The owner registers the table in the Hassock.TableRef registry (started
  # by Hassock.Application) under its pid and, when it has one, its
  # registered name. The registry drops the entries when the owner exits,
  # however it exits, so nothing leaks when an owner is killed.

  @registry __MODULE__

  @doc false
  def child_spec(_opts), do: Registry.child_spec(keys: :unique, name: @registry)

  @spec register(module, :ets.table(), atom | nil) :: :ok
  def register(owner, table, name) do
    {:ok, _} = Registry.register(@registry, {owner, self()}, table)

    if is_atom(name) and name != nil,
      do: {:ok, _} = Registry.register(@registry, {owner, name}, table)

    :ok
  end

  # nil when the process isn't running. Servers named {:global, _} or
  # {:via, _, _} aren't keyed, so they fall back to asking the process.
  @spec lookup(module, GenServer.server()) :: :ets.table() | nil
  def lookup(owner, server) when is_pid(server) or is_atom(server) do
    case Registry.lookup(@registry, {owner, server}) do
      [{_pid, table}] -> table
      [] -> nil
    end
  end

  def lookup(_owner, server) do
    GenServer.call(server, :table)
  catch
    :exit, _ -> nil
  end
end
