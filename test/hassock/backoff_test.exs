defmodule Hassock.Connection.BackoffTest do
  use ExUnit.Case, async: true

  alias Hassock.Connection.Backoff

  test "doubles from the initial delay up to the cap, with no jitter at rand = 1" do
    one = fn -> 1.0 end
    delays = Enum.map(1..7, &Backoff.delay(&1, 1_000, 30_000, one))
    assert delays == [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000]
  end

  test "jitter keeps each delay between half and all of the base" do
    zero = fn -> 0.0 end

    assert Enum.map(1..6, &Backoff.delay(&1, 1_000, 30_000, zero)) ==
             [500, 1_000, 2_000, 4_000, 8_000, 15_000]

    for attempt <- 1..10, _ <- 1..20 do
      base = min(30_000, 1_000 * Integer.pow(2, attempt - 1))
      delay = Backoff.delay(attempt, 1_000, 30_000)
      assert delay >= div(base, 2) and delay <= base
    end
  end

  test "huge attempt numbers stay at the cap" do
    assert Backoff.delay(10_000, 1_000, 30_000, fn -> 1.0 end) == 30_000
  end
end
