defmodule Hassock.Fixtures do
  @moduledoc """
  Registry responses recorded from Home Assistant 2026.10 (names and ids
  scrubbed), in `test/fixtures/registries/`.
  """

  @dir Path.expand("../fixtures/registries", __DIR__)

  @doc "The raw `config/<kind>_registry/list` result for a registry kind."
  def registry(kind) do
    @dir |> Path.join("#{kind}_registry_list.json") |> File.read!() |> Jason.decode!()
  end
end
