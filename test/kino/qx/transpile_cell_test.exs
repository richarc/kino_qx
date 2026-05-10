defmodule Kino.Qx.TranspileCellTest do
  @moduledoc """
  Behaviour tests for `Kino.Qx.TranspileCell`.

  The most important assertions are the **token-leak guards** for
  `to_attrs/1` (which is persisted into the `.livemd` file) and for
  `client_payload/1` (which is sent to the JS side). Either leak
  would break the privacy invariant.

  Following the convention of `smart_cell_test.exs`, we build a fake
  `ctx` map and call `to_attrs/1` / `to_source/1` directly — the
  full Kino runtime isn't booted. Pure-helper tests
  (`validate_portal_url/1`) call the function directly.

  `handle_event/3` clauses are not driven directly here; they
  require the live Kino runtime. The handle_event input-validation
  surface (Iron Law #8) is exercised in `:portal_live` / `:ibm_live`
  tagged tests when those land.
  """
  use ExUnit.Case, async: true

  alias Kino.Qx.TranspileCell

  defp ctx_for(assigns) do
    %{assigns: Map.merge(default_assigns(), assigns)}
  end

  defp default_assigns do
    %{
      # Persistable
      portal_base_url: "https://test.qxquantum.com",
      ibm_region: "us-south",
      last_backend_name: "",
      qasm_paste: "",
      save_qasm: false,
      optimization_level: 1,
      last_job_id: nil,
      last_counts: nil,
      # Transient — these are the secrets we must NOT leak
      portal_token: "qx_live_PORTAL_SENTINEL",
      ibm_api_key: "ibm_API_KEY_SENTINEL",
      ibm_crn: "crn:v1:bluemix:public:quantum:CRN_SENTINEL",
      backends_list: [],
      connected: false,
      identity: nil,
      current_session_id: nil,
      current_status: "idle",
      current_status_detail: nil,
      current_job_id: nil,
      polling_task_pid: nil,
      error: nil
    }
  end

  describe "to_attrs/1 — security invariant" do
    test "NEVER includes the portal token" do
      attrs = TranspileCell.to_attrs(ctx_for(%{}))

      refute Map.has_key?(attrs, "portal_token")
      refute Map.has_key?(attrs, :portal_token)
      refute attrs |> Jason.encode!() |> String.contains?("PORTAL_SENTINEL")
    end

    test "NEVER includes the IBM API key" do
      attrs = TranspileCell.to_attrs(ctx_for(%{}))

      refute Map.has_key?(attrs, "ibm_api_key")
      refute attrs |> Jason.encode!() |> String.contains?("API_KEY_SENTINEL")
    end

    test "NEVER includes the IBM Service-CRN" do
      attrs = TranspileCell.to_attrs(ctx_for(%{}))

      refute Map.has_key?(attrs, "ibm_crn")
      refute attrs |> Jason.encode!() |> String.contains?("CRN_SENTINEL")
    end

    test "NEVER includes session/job-task transient state" do
      ctx =
        ctx_for(%{
          current_session_id: "sess_abc",
          polling_task_pid: self(),
          backends_list: [%{name: "ibm_brisbane", status: "active", num_qubits: 127}]
        })

      attrs = TranspileCell.to_attrs(ctx)

      refute Map.has_key?(attrs, "current_session_id")
      refute Map.has_key?(attrs, "polling_task_pid")
      refute Map.has_key?(attrs, "backends_list")
      refute attrs |> Jason.encode!() |> String.contains?("sess_abc")
    end
  end

  describe "to_attrs/1 — qasm_paste gating" do
    test "qasm_paste is empty string in attrs when save_qasm is false (default)" do
      ctx = ctx_for(%{qasm_paste: "OPENQASM 3.0; SECRET_CIRCUIT", save_qasm: false})
      attrs = TranspileCell.to_attrs(ctx)

      assert attrs["qasm_paste"] == ""
      refute attrs |> Jason.encode!() |> String.contains?("SECRET_CIRCUIT")
    end

    test "qasm_paste is persisted when save_qasm is true (opt-in)" do
      ctx = ctx_for(%{qasm_paste: "OPENQASM 3.0; my_circuit;", save_qasm: true})
      attrs = TranspileCell.to_attrs(ctx)

      assert attrs["qasm_paste"] == "OPENQASM 3.0; my_circuit;"
      assert attrs["save_qasm"] == true
    end
  end

  describe "to_attrs/1 — persistable key set" do
    test "exactly the documented keys" do
      attrs = TranspileCell.to_attrs(ctx_for(%{}))

      assert MapSet.new(Map.keys(attrs)) ==
               MapSet.new([
                 "portal_base_url",
                 "ibm_region",
                 "last_backend_name",
                 "save_qasm",
                 "qasm_paste",
                 "optimization_level",
                 "last_job_id",
                 "last_counts"
               ])
    end
  end

  describe "to_source/1" do
    test "no counts → placeholder comment" do
      assert TranspileCell.to_source(%{}) =~ "No results yet"
      assert TranspileCell.to_source(%{"last_counts" => %{}}) =~ "No results yet"
      assert TranspileCell.to_source(%{"last_counts" => nil}) =~ "No results yet"
    end

    test "counts → DataTable + optional VegaLite block + sorted rows" do
      attrs = %{
        "last_counts" => %{"00" => 100, "11" => 412, "01" => 5},
        "last_job_id" => "job_abc"
      }

      out = TranspileCell.to_source(attrs)

      assert out =~ "Kino.Qx.TranspileCell"
      assert out =~ "job_abc"
      assert out =~ "Kino.DataTable.new"
      assert out =~ "Kino.VegaLite"
      assert out =~ "Code.ensure_loaded?"

      # Rows are sorted desc by count: 412, 100, 5
      assert {row_412, _} = :binary.match(out, ~s|count: 412|)
      assert {row_100, _} = :binary.match(out, ~s|count: 100|)
      assert {row_5, _} = :binary.match(out, ~s|count: 5|)
      assert row_412 < row_100
      assert row_100 < row_5
    end

    test "missing job_id → em-dash placeholder" do
      attrs = %{"last_counts" => %{"00" => 1}, "last_job_id" => nil}
      out = TranspileCell.to_source(attrs)

      assert out =~ "job —"
    end
  end

  describe "validate_portal_url/1 — SSRF defence" do
    test "accepts https://test.qxquantum.com (default)" do
      assert TranspileCell.validate_portal_url("https://test.qxquantum.com") ==
               "https://test.qxquantum.com"
    end

    test "accepts https://www.qxquantum.com (planned production host)" do
      assert TranspileCell.validate_portal_url("https://www.qxquantum.com") ==
               "https://www.qxquantum.com"
    end

    test "accepts arbitrary subdomains of qxquantum.com" do
      for host <- ["staging.qxquantum.com", "eu.qxquantum.com", "api.qxquantum.com"] do
        url = "https://" <> host
        assert TranspileCell.validate_portal_url(url) == url
      end
    end

    test "accepts http://localhost / 127.0.0.1 for local development" do
      assert TranspileCell.validate_portal_url("http://localhost:4000") ==
               "http://localhost:4000"

      assert TranspileCell.validate_portal_url("http://127.0.0.1:4000") ==
               "http://127.0.0.1:4000"
    end

    test "trims whitespace" do
      assert TranspileCell.validate_portal_url("  https://test.qxquantum.com  ") ==
               "https://test.qxquantum.com"
    end

    test "rejects http:// to public hosts" do
      assert TranspileCell.validate_portal_url("http://test.qxquantum.com") == nil
    end

    test "rejects arbitrary attacker hosts" do
      for url <- [
            "https://attacker.example.com",
            "https://qxquantum.com.attacker.example.com",
            "https://attackerqxquantum.com"
          ] do
        assert TranspileCell.validate_portal_url(url) == nil
      end
    end

    test "rejects link-local IPv4 (cloud metadata service)" do
      assert TranspileCell.validate_portal_url("http://169.254.169.254") == nil
      assert TranspileCell.validate_portal_url("https://169.254.169.254") == nil
    end

    test "rejects file://, data:, javascript: schemes" do
      for url <- [
            "file:///etc/passwd",
            "data:text/html,<script>",
            "javascript:alert(1)"
          ] do
        assert TranspileCell.validate_portal_url(url) == nil
      end
    end

    test "rejects empty / nil / non-binary input" do
      assert TranspileCell.validate_portal_url(nil) == nil
      assert TranspileCell.validate_portal_url("") == nil
      assert TranspileCell.validate_portal_url("   ") == nil
      assert TranspileCell.validate_portal_url(42) == nil
      assert TranspileCell.validate_portal_url(%{}) == nil
    end
  end
end
