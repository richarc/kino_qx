defmodule Kino.Qx do
  @moduledoc """
  A Livebook Smart Cell for the [Qx Portal](https://qxportal.dev).

  This is the entrypoint module — most of the real work lives in:

    * `Kino.Qx.SmartCell` — the cell itself (Phase 3, not yet implemented).
    * `Kino.Qx.Client` — Req-based wrapper around the portal API
      (Phase 3, not yet implemented).

  See the [README](readme.html) for installation and usage.
  """

  @doc """
  Returns the version of `:kino_qx` reported in `mix.exs`.

  Useful when filing issues or in CI logs.

      iex> is_binary(Kino.Qx.version())
      true

  """
  @spec version() :: String.t()
  def version do
    Application.spec(:kino_qx, :vsn) |> to_string()
  end
end
