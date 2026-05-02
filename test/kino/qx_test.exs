defmodule Kino.QxTest do
  use ExUnit.Case, async: true

  doctest Kino.Qx

  test "version/0 returns the mix.exs version string" do
    assert Kino.Qx.version() =~ ~r/^\d+\.\d+\.\d+/
  end
end
