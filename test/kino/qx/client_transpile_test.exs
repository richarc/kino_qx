defmodule Kino.Qx.ClientTranspileTest do
  @moduledoc """
  Verifies `Kino.Qx.Client.transpile/2` against the qxportal
  `/api/v1/transpile` contract.

  Uses Bypass to match the existing client test convention. A drift
  here from qxportal's contract test means the wire format has
  changed.
  """
  use ExUnit.Case, async: true

  alias Kino.Qx.Client

  setup do
    bypass = Bypass.open()
    config = %{token: "qx_live_test_token", base_url: "http://localhost:#{bypass.port}"}
    %{bypass: bypass, config: config}
  end

  defp json_resp(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(payload))
  end

  defp sample_payload do
    %{
      qasm: "OPENQASM 3.0;\nqubit[2] q;\nh q[0];\ncx q[0], q[1];\nmeasure q;",
      coupling_map: [[0, 1], [1, 2]],
      basis_gates: ["id", "rz", "sx", "x", "cx"],
      optimization_level: 1,
      seed_transpiler: nil
    }
  end

  describe "transpile/2 happy path" do
    test "returns parsed transpile result on 200", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/api/v1/transpile", fn conn ->
        assert ["Bearer qx_live_test_token"] = Plug.Conn.get_req_header(conn, "authorization")
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert {:ok, %{"qasm" => qasm}} = Jason.decode(body)
        assert qasm =~ "OPENQASM 3.0;"

        json_resp(conn, 200, %{
          data: %{
            qasm: "OPENQASM 3.0;\n// transpiled\n",
            metadata: %{depth: 5, size: 8, num_qubits: 2}
          }
        })
      end)

      assert {:ok, result} = Client.transpile(config, sample_payload())
      assert result.qasm =~ "transpiled"
      assert result.metadata == %{depth: 5, size: 8, num_qubits: 2}
    end
  end

  describe "transpile/2 error mapping" do
    test "401 maps to :unauthorized", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/api/v1/transpile", fn conn ->
        json_resp(conn, 401, %{error: "unauthorized"})
      end)

      assert Client.transpile(config, sample_payload()) == {:error, :unauthorized}
    end

    test "422 maps to {:invalid_qasm, detail}", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/api/v1/transpile", fn conn ->
        json_resp(conn, 422, %{error: "invalid_qasm", detail: "Parse error at line 1"})
      end)

      assert Client.transpile(config, sample_payload()) ==
               {:error, {:invalid_qasm, "Parse error at line 1"}}
    end

    test "422 falls back to error code when detail missing", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/api/v1/transpile", fn conn ->
        json_resp(conn, 422, %{error: "invalid_qasm"})
      end)

      assert Client.transpile(config, sample_payload()) ==
               {:error, {:invalid_qasm, "invalid_qasm"}}
    end

    test "429 with retry-after maps to {:rate_limited, secs}", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/api/v1/transpile", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "12")
        |> json_resp(429, %{error: "rate_limited"})
      end)

      assert Client.transpile(config, sample_payload()) == {:error, {:rate_limited, 12}}
    end

    test "502 maps to :transpile_failed", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/api/v1/transpile", fn conn ->
        json_resp(conn, 502, %{error: "transpile_failed"})
      end)

      assert Client.transpile(config, sample_payload()) == {:error, :transpile_failed}
    end

    test "503 maps to :transpile_unavailable", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/api/v1/transpile", fn conn ->
        json_resp(conn, 503, %{error: "transpile_unavailable"})
      end)

      assert Client.transpile(config, sample_payload()) == {:error, :transpile_unavailable}
    end

    test "504 maps to :transpile_timeout", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/api/v1/transpile", fn conn ->
        json_resp(conn, 504, %{error: "transpile_timeout"})
      end)

      assert Client.transpile(config, sample_payload()) == {:error, :transpile_timeout}
    end

    test "other status falls through to {:http, status, body}", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/api/v1/transpile", fn conn ->
        json_resp(conn, 418, %{error: "teapot"})
      end)

      assert {:error, {:http, 418, %{"error" => "teapot"}}} =
               Client.transpile(config, sample_payload())
    end

    test "network failure maps to {:network, reason}", %{bypass: bypass, config: config} do
      Bypass.down(bypass)
      assert {:error, {:network, _}} = Client.transpile(config, sample_payload())
    end
  end
end
