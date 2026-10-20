defmodule Hassock.TableRef do
  @moduledoc false
  # Lets readers find a process's public ETS table without a GenServer call.
  # The owner registers the table in :persistent_term under its pid and, when
  # it has one, its registered name; it unregisters in terminate/2. Writes
  # to :persistent_term are expensive, but happen only at start and stop.

  @spec register(module, :ets.table(), atom | nil) :: :ok
  def register(owner, table, name) do
    :persistent_term.put({owner, self()}, table)
    if is_atom(name) and name != nil, do: :persistent_term.put({owner, name}, table)
    :ok
  end

  @spec unregister(module, atom | nil) :: :ok
  def unregister(owner, name) do
    :persistent_term.erase({owner, self()})
    if is_atom(name) and name != nil, do: :persistent_term.erase({owner, name})
    :ok
  end

  # nil when the process isn't running. Servers named {:global, _} or
  # {:via, _, _} aren't keyed, so they fall back to asking the process.
  @spec lookup(module, GenServer.server()) :: :ets.table() | nil
  def lookup(owner, server) when is_pid(server) or is_atom(server) do
    :persistent_term.get({owner, server}, nil)
  end

  def lookup(_owner, server) do
    GenServer.call(server, :table)
  catch
    :exit, _ -> nil
  end
end
