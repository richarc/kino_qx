defmodule Kino.Qx.SmartCellTest do
  @moduledoc """
  Behaviour tests for the smart cell. The most important assertion in
  this file is the **token leak guard** — `to_attrs/1` must never
  include the token, because attrs are persisted into the `.livemd`
  file and travel with shared notebooks.

  See also `client_test.exs` for the HTTP layer.
  """
  use ExUnit.Case, async: true

  alias Kino.Qx.SmartCell

  defp ctx_for(assigns) do
    # Build a fake Kino.JS.Live ctx with just enough shape for the
    # callbacks we want to exercise. The real ctx struct is internal
    # to Kino so we use a struct-shaped map.
    %{assigns: Map.merge(default_assigns(), assigns)}
  end

  defp default_assigns do
    %{
      base_url: "https://qxportal.dev",
      snippet_name: "",
      source_kind: "qasm",
      source: "",
      token: "qx_live_SECRET_TOKEN_DO_NOT_LEAK",
      status: "disconnected",
      identity: nil,
      snippets: [],
      selected_id: nil,
      error: nil,
      qasm_content: nil,
      elixir_content: nil
    }
  end

  describe "to_attrs/1 — security invariant" do
    test "NEVER includes the token" do
      ctx = ctx_for(%{token: "qx_live_SECRET_TOKEN_DO_NOT_LEAK"})
      attrs = SmartCell.to_attrs(ctx)

      refute Map.has_key?(attrs, "token")
      refute Map.has_key?(attrs, :token)
      refute attrs |> Jason.encode!() |> String.contains?("SECRET")
    end

    test "NEVER includes the identity (which contains email)" do
      ctx =
        ctx_for(%{
          identity: %{email: "you@example.com", role: "user", api_key_name: "Lap"}
        })

      attrs = SmartCell.to_attrs(ctx)

      refute Map.has_key?(attrs, "identity")
      refute attrs |> Jason.encode!() |> String.contains?("you@example.com")
    end

    test "includes only the documented persistable keys" do
      ctx = ctx_for(%{snippet_name: "Bell", source_kind: "qasm", source: "x", selected_id: 7})
      attrs = SmartCell.to_attrs(ctx)

      assert MapSet.new(Map.keys(attrs)) ==
               MapSet.new(["base_url", "snippet_name", "source_kind", "source", "selected_id"])
    end
  end

  describe "to_source/1" do
    test "empty source → comment placeholder" do
      assert SmartCell.to_source(%{}) == ""
      assert SmartCell.to_source(%{"source" => ""}) =~ "No snippet selected"
    end

    test "elixir source emits verbatim" do
      attrs = %{"source" => "1 + 1", "source_kind" => "elixir", "snippet_name" => "Test"}
      assert SmartCell.to_source(attrs) == "1 + 1"
    end

    test "qasm source is wrapped with a leading comment + qasm assignment" do
      attrs = %{
        "source" => "OPENQASM 3.0;\nqubit[2] q;\n",
        "source_kind" => "qasm",
        "snippet_name" => "Bell pair"
      }

      out = SmartCell.to_source(attrs)
      assert out =~ ~s|"Bell pair" — Qx Portal|
      assert out =~ ~s|qasm = """|
      assert out =~ "OPENQASM 3.0;"
    end

    test "qasm with no name still wraps cleanly" do
      attrs = %{
        "source" => "OPENQASM 3.0;\n",
        "source_kind" => "qasm",
        "snippet_name" => ""
      }

      out = SmartCell.to_source(attrs)
      assert out =~ "snippet"
      assert out =~ "qasm = "
    end
  end
end
