defmodule Hassock.Connection.Backoff do
  @moduledoc """
  Reconnect delays: exponential backoff with "equal jitter".

  Attempt `n` (1-based) waits a random time between half and all of
  `min(max, initial * 2^(n - 1))`, so a fleet of clients that lost Home
  Assistant at the same moment doesn't reconnect in lockstep.
  """

  @doc """
  Delay in milliseconds before reconnect attempt `attempt`.

  `rand` returns a float in `[0, 1)`; pass a fixed function for
  deterministic results.
  """
  @spec delay(pos_integer, pos_integer, pos_integer, (-> float)) :: non_neg_integer
  def delay(attempt, initial, max, rand \\ &:rand.uniform/0)
      when is_integer(attempt) and attempt >= 1 do
    # Cap the exponent too: past 2^20 the product only overflows into bignums.
    base = min(max, initial * Integer.pow(2, min(attempt - 1, 20)))
    half = div(base, 2)
    half + trunc(rand.() * (base - half))
  end
end
