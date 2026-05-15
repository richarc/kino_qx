defmodule Kino.Qx.CredentialsCellTest do
  @moduledoc """
  Behaviour tests for `Kino.Qx.CredentialsCell`.

  The most important assertions are the **token-leak guards** for
  `to_attrs/1` (which is persisted into the `.livemd`) and for
  `to_source/1` (whose output is also persisted as the smart cell's
  source block). Either leak would break the privacy invariant.

  Following the convention of `smart_cell_test.exs`, we build a fake
  `ctx` map and call `to_attrs/1` / `to_source/1` directly — the full
  Kino runtime isn't booted. Pure-helper tests
  (`validate_portal_url/1`) call the function directly.

  `handle_event/3` clauses are not driven directly here; they require
  the live Kino runtime. The Connect flow is exercised in
  `:portal_live` / `:ibm_live` tagged tests.
  """
  use ExUnit.Case, async: true

  alias Kino.Qx.CredentialsCell

  defp ctx_for(assigns) do
    %{assigns: Map.merge(default_assigns(), assigns)}
  end

  defp default_assigns do
    %{
      # Persistable
      portal_base_url: "https://test.qxquantum.com",
      ibm_region: "us-south",
      last_backend_name: "",
      optimization_level: 1,
      shots: 4096,
      # Transient — connect-derived only; cell never holds tokens
      backends_list: [],
      connected: false,
      identity: nil,
      connecting: false,
      error: nil
    }
  end

  describe "to_attrs/1 — security invariant" do
    test "NEVER includes any token-shaped field" do
      attrs = CredentialsCell.to_attrs(ctx_for(%{}))

      for forbidden <- [
            "portal_token",
            "ibm_api_key",
            "ibm_crn",
            :portal_token,
            :ibm_api_key,
            :ibm_crn
          ] do
        refute Map.has_key?(attrs, forbidden),
               "attrs leaked #{inspect(forbidden)}: #{inspect(attrs)}"
      end
    end

    test "NEVER includes connect-derived transient state" do
      ctx =
        ctx_for(%{
          connected: true,
          identity: "alice@example.com",
          backends_list: [%{name: "ibm_brisbane", status: "active"}]
        })

      attrs = CredentialsCell.to_attrs(ctx)

      refute Map.has_key?(attrs, "backends_list")
      refute Map.has_key?(attrs, "identity")
      refute Map.has_key?(attrs, "connected")
      refute Map.has_key?(attrs, "connecting")
      refute Map.has_key?(attrs, "error")
    end
  end

  describe "to_attrs/1 — persistable key set" do
    test "exactly the documented keys" do
      attrs = CredentialsCell.to_attrs(ctx_for(%{}))

      assert MapSet.new(Map.keys(attrs)) ==
               MapSet.new([
                 "portal_base_url",
                 "ibm_region",
                 "last_backend_name",
                 "optimization_level",
                 "shots"
               ])
    end

    test "shots round-trips" do
      assert CredentialsCell.to_attrs(ctx_for(%{shots: 4096}))["shots"] == 4096
      assert CredentialsCell.to_attrs(ctx_for(%{shots: 1024}))["shots"] == 1024
    end
  end

  describe "to_source/1 — privacy invariant" do
    test "emits %Qx.Hardware.Config{} with the expected attrs" do
      attrs = %{
        "portal_base_url" => "https://test.qxquantum.com",
        "ibm_region" => "us-south",
        "last_backend_name" => "ibm_brisbane",
        "optimization_level" => 2,
        "shots" => 4096
      }

      out = CredentialsCell.to_source(attrs)

      assert out =~ "qx = %Qx.Hardware.Config{"
      assert out =~ ~s|portal_url: "https://test.qxquantum.com"|
      assert out =~ ~s|ibm_region: "us-south"|
      assert out =~ ~s|backend: "ibm_brisbane"|
      assert out =~ "optimization_level: 2"
      assert out =~ "shots: 4096"
    end

    test "tokens are emitted as System.fetch_env! references, not literals" do
      attrs = %{
        "portal_base_url" => "https://test.qxquantum.com",
        "ibm_region" => "us-south",
        "last_backend_name" => "ibm_brisbane",
        "optimization_level" => 1,
        "shots" => 4096
      }

      out = CredentialsCell.to_source(attrs)

      assert out =~ ~s|portal_token: System.fetch_env!("LB_PORTAL_TOKEN")|
      assert out =~ ~s|ibm_api_key: System.fetch_env!("LB_IBM_API_KEY")|
      assert out =~ ~s|ibm_crn: System.fetch_env!("LB_IBM_CRN")|
    end

    test "no token literal could possibly appear (sentinel scan)" do
      # Even if attrs were somehow polluted with token-shaped values, the
      # cell pulls from System.fetch_env! — not from attrs.
      attrs = %{
        "portal_base_url" => "https://test.qxquantum.com",
        "ibm_region" => "us-south",
        "last_backend_name" => "ibm_brisbane",
        "optimization_level" => 1,
        "shots" => 4096,
        # The cell IGNORES these keys; they must not leak even if present.
        "portal_token" => "qx_live_SHOULDNT_LEAK",
        "ibm_api_key" => "API_KEY_SHOULDNT_LEAK",
        "ibm_crn" => "CRN_SHOULDNT_LEAK"
      }

      out = CredentialsCell.to_source(attrs)

      refute out =~ "qx_live_"
      refute out =~ "API_KEY_SHOULDNT_LEAK"
      refute out =~ "CRN_SHOULDNT_LEAK"
    end

    test "falls back to safe defaults when attrs are sparse" do
      out = CredentialsCell.to_source(%{})

      assert out =~ ~s|portal_url: "https://test.qxquantum.com"|
      assert out =~ ~s|ibm_region: "us-south"|
      assert out =~ ~s|backend: ""|
      assert out =~ "optimization_level: 1"
      assert out =~ "shots: 4096"
    end
  end

  describe "valid_ibm_region?/1 — region allowlist (W3)" do
    # `handle_event("update_ibm_region", ...)` now branches on this
    # predicate: an allowlisted value assigns the region; anything else
    # routes to `set_error(ctx, "Invalid region.")` instead of raising a
    # FunctionClauseError (Iron Law #8). handle_event/3 needs the live
    # Kino runtime, so we assert the predicate that drives the branch.

    test "accepts the allowlisted regions" do
      assert CredentialsCell.valid_ibm_region?("us-south")
      assert CredentialsCell.valid_ibm_region?("eu-de")
    end

    test "rejects non-allowlisted / malformed region values (error path, not crash)" do
      for bad <- [
            "us-east",
            "eu-es",
            "",
            "US-SOUTH",
            " us-south ",
            "'; DROP TABLE",
            "us-south ",
            nil,
            42,
            %{},
            :us_south
          ] do
        refute CredentialsCell.valid_ibm_region?(bad),
               "expected #{inspect(bad)} to be rejected"
      end
    end
  end

  describe "validate_portal_url/1 — SSRF defence" do
    test "accepts https://test.qxquantum.com (default)" do
      assert CredentialsCell.validate_portal_url("https://test.qxquantum.com") ==
               "https://test.qxquantum.com"
    end

    test "accepts https://www.qxquantum.com (planned production host)" do
      assert CredentialsCell.validate_portal_url("https://www.qxquantum.com") ==
               "https://www.qxquantum.com"
    end

    test "accepts arbitrary subdomains of qxquantum.com" do
      for host <- ["staging.qxquantum.com", "eu.qxquantum.com", "api.qxquantum.com"] do
        url = "https://" <> host
        assert CredentialsCell.validate_portal_url(url) == url
      end
    end

    test "accepts http://localhost / 127.0.0.1 for local development" do
      assert CredentialsCell.validate_portal_url("http://localhost:4000") ==
               "http://localhost:4000"

      assert CredentialsCell.validate_portal_url("http://127.0.0.1:4000") ==
               "http://127.0.0.1:4000"
    end

    test "trims whitespace" do
      assert CredentialsCell.validate_portal_url("  https://test.qxquantum.com  ") ==
               "https://test.qxquantum.com"
    end

    test "rejects http:// to public hosts" do
      assert CredentialsCell.validate_portal_url("http://test.qxquantum.com") == nil
    end

    test "rejects arbitrary attacker hosts" do
      for url <- [
            "https://attacker.example.com",
            "https://qxquantum.com.attacker.example.com",
            "https://attackerqxquantum.com"
          ] do
        assert CredentialsCell.validate_portal_url(url) == nil
      end
    end

    test "rejects link-local IPv4 (cloud metadata service)" do
      assert CredentialsCell.validate_portal_url("http://169.254.169.254") == nil
      assert CredentialsCell.validate_portal_url("https://169.254.169.254") == nil
    end

    test "rejects IPv6 loopback (S5)" do
      for url <- [
            "http://[::1]",
            "https://[::1]",
            "http://[::1]:4000",
            "https://[::1]:4000"
          ] do
        assert CredentialsCell.validate_portal_url(url) == nil,
               "expected #{url} to be rejected"
      end
    end

    test "rejects RFC-1918 private ranges (S5)" do
      for url <- [
            "http://10.0.0.1",
            "https://10.0.0.1",
            "http://192.168.1.1",
            "https://192.168.1.1",
            "http://172.16.0.1",
            "https://172.16.0.1"
          ] do
        assert CredentialsCell.validate_portal_url(url) == nil,
               "expected #{url} to be rejected"
      end
    end

    test "rejects file://, data:, javascript: schemes" do
      for url <- [
            "file:///etc/passwd",
            "data:text/html,<script>",
            "javascript:alert(1)"
          ] do
        assert CredentialsCell.validate_portal_url(url) == nil
      end
    end

    test "rejects empty / nil / non-binary input" do
      assert CredentialsCell.validate_portal_url(nil) == nil
      assert CredentialsCell.validate_portal_url("") == nil
      assert CredentialsCell.validate_portal_url("   ") == nil
      assert CredentialsCell.validate_portal_url(42) == nil
      assert CredentialsCell.validate_portal_url(%{}) == nil
    end
  end
end
