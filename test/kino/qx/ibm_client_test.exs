defmodule Kino.Qx.IbmClientTest do
  @moduledoc """
  Verifies the IBM Quantum client via Bypass-stubbed responses.
  Real-IBM integration coverage lives in `test/kino/qx/integration/`
  tagged `:ibm_live`.
  """
  use ExUnit.Case, async: true

  alias Kino.Qx.IbmClient

  setup do
    api = Bypass.open()
    iam = Bypass.open()

    config = %{
      api_key: "test_api_key",
      crn: "crn:v1:bluemix:public:quantum:us-south:a/...:test::",
      region: :us_south,
      iam_url: "http://localhost:#{iam.port}/identity/token",
      base_url: "http://localhost:#{api.port}"
    }

    %{api: api, iam: iam, config: config}
  end

  defp json_resp(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(payload))
  end

  defp expect_iam(iam, opts) do
    expires_in = Keyword.get(opts, :expires_in, 3600)
    token = Keyword.get(opts, :token, "iam_token_v1")

    Bypass.expect_once(iam, "POST", "/identity/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "apikey=test_api_key"
      assert body =~ "grant_type="

      json_resp(conn, 200, %{
        access_token: token,
        expires_in: expires_in,
        refresh_token: "refresh_xyz",
        token_type: "Bearer"
      })
    end)
  end

  defp authed_config(config, token \\ "iam_token_v1") do
    Map.merge(config, %{
      access_token: token,
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    })
  end

  describe "iam_exchange/1" do
    test "returns config with access_token + token_expires_at on 200", %{iam: iam, config: config} do
      expect_iam(iam, token: "fresh_token", expires_in: 3600)

      assert {:ok, refreshed} = IbmClient.iam_exchange(config)
      assert refreshed.access_token == "fresh_token"
      assert %DateTime{} = refreshed.token_expires_at
      # Original config keys preserved
      assert refreshed.api_key == "test_api_key"
      assert refreshed.region == :us_south
    end

    test "401 maps to :unauthorized", %{iam: iam, config: config} do
      Bypass.expect_once(iam, "POST", "/identity/token", fn conn ->
        json_resp(conn, 401, %{errorMessage: "BXNIM0415E: Provided API key could not be found."})
      end)

      assert IbmClient.iam_exchange(config) == {:error, :unauthorized}
    end

    test "400 (bad grant) maps to :unauthorized", %{iam: iam, config: config} do
      Bypass.expect_once(iam, "POST", "/identity/token", fn conn ->
        json_resp(conn, 400, %{errorMessage: "Bad grant"})
      end)

      assert IbmClient.iam_exchange(config) == {:error, :unauthorized}
    end

    test "network failure maps to {:network, reason}", %{iam: iam, config: config} do
      Bypass.down(iam)
      assert {:error, {:network, _}} = IbmClient.iam_exchange(config)
    end
  end

  describe "list_backends/1" do
    test "decodes :name, :status, :num_qubits from devices wrapper", %{api: api, config: config} do
      Bypass.expect_once(api, "GET", "/backends", fn conn ->
        assert ["Bearer iam_token_v1"] = Plug.Conn.get_req_header(conn, "authorization")
        assert [_crn] = Plug.Conn.get_req_header(conn, "service-crn")
        assert ["2026-03-15"] = Plug.Conn.get_req_header(conn, "ibm-api-version")

        json_resp(conn, 200, %{
          devices: [
            %{name: "ibm_brisbane", status: "active", num_qubits: 127},
            %{name: "ibm_kyoto", status: "maintenance", num_qubits: 127}
          ]
        })
      end)

      assert {:ok, [first, second]} = IbmClient.list_backends(authed_config(config))
      assert first == %{name: "ibm_brisbane", status: "active", num_qubits: 127}
      assert second.name == "ibm_kyoto"
    end

    test "tolerates `backends` wrapper", %{api: api, config: config} do
      Bypass.expect_once(api, "GET", "/backends", fn conn ->
        json_resp(conn, 200, %{
          backends: [%{backend_name: "ibmq_qasm_simulator", status: "active", num_qubits: 32}]
        })
      end)

      assert {:ok, [%{name: "ibmq_qasm_simulator"}]} =
               IbmClient.list_backends(authed_config(config))
    end

    test "401 triggers IAM refresh and one retry", %{api: api, iam: iam, config: config} do
      # First call: 401
      Bypass.expect(api, "GET", "/backends", fn conn ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          ["Bearer stale_token"] ->
            json_resp(conn, 401, %{error: "expired"})

          ["Bearer fresh_token"] ->
            json_resp(conn, 200, %{
              devices: [%{name: "ibm_brisbane", status: "active", num_qubits: 127}]
            })
        end
      end)

      expect_iam(iam, token: "fresh_token")

      stale = authed_config(config, "stale_token")
      assert {:ok, [%{name: "ibm_brisbane"}]} = IbmClient.list_backends(stale)
    end
  end

  describe "fetch_backend_properties/2" do
    test "extracts coupling_map, basis_gates, num_qubits", %{api: api, config: config} do
      Bypass.expect_once(api, "GET", "/backends/ibm_brisbane/properties", fn conn ->
        json_resp(conn, 200, %{
          coupling_map: [[0, 1], [1, 2]],
          basis_gates: ["id", "rz", "sx", "x", "cx"],
          num_qubits: 127,
          # Other fields should be ignored
          last_update_date: "2026-05-10T00:00:00Z"
        })
      end)

      assert {:ok, props} =
               IbmClient.fetch_backend_properties(authed_config(config), "ibm_brisbane")

      assert props.coupling_map == [[0, 1], [1, 2]]
      assert props.basis_gates == ["id", "rz", "sx", "x", "cx"]
      assert props.num_qubits == 127
    end
  end

  describe "open_session/3" do
    test "POSTs backend + max_ttl, returns id", %{api: api, config: config} do
      Bypass.expect_once(api, "POST", "/sessions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert {:ok, decoded} = Jason.decode(body)
        assert decoded["backend"] == "ibm_brisbane"
        assert decoded["max_ttl"] == 3600
        assert decoded["mode"] == "dedicated"

        json_resp(conn, 200, %{id: "session_abc123"})
      end)

      assert {:ok, "session_abc123"} =
               IbmClient.open_session(authed_config(config), "ibm_brisbane")
    end

    test "honours custom max_ttl", %{api: api, config: config} do
      Bypass.expect_once(api, "POST", "/sessions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert {:ok, %{"max_ttl" => 60}} = Jason.decode(body)
        json_resp(conn, 200, %{id: "session_x"})
      end)

      assert {:ok, "session_x"} =
               IbmClient.open_session(authed_config(config), "ibm_brisbane", 60)
    end
  end

  describe "submit_sampler/4" do
    test "wraps qasm into pubs: [[qasm, nil]]", %{api: api, config: config} do
      qasm = "OPENQASM 3.0; qubit[2] q; h q[0]; cx q[0], q[1]; measure q;"

      Bypass.expect_once(api, "POST", "/jobs", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert {:ok, decoded} = Jason.decode(body)

        assert decoded["program_id"] == "sampler"
        assert decoded["backend"] == "ibm_brisbane"
        assert decoded["session_id"] == "session_abc"
        # PUB shape: list of pairs, even for one circuit. Forgetting
        # the outer list 400s the request.
        assert [[^qasm, nil]] = decoded["params"]["pubs"]
        assert decoded["params"]["version"] == 2

        json_resp(conn, 200, %{id: "job_xyz789", backend: "ibm_brisbane"})
      end)

      assert {:ok, "job_xyz789"} =
               IbmClient.submit_sampler(
                 authed_config(config),
                 qasm,
                 "ibm_brisbane",
                 "session_abc"
               )
    end
  end

  describe "poll_job/2" do
    test "returns DONE status with reason + queue_position", %{api: api, config: config} do
      Bypass.expect_once(api, "GET", "/jobs/job_xyz", fn conn ->
        json_resp(conn, 200, %{
          id: "job_xyz",
          state: %{status: "DONE", reason: nil},
          queue_position: 0
        })
      end)

      assert {:ok, %{status: "DONE", reason: nil, queue_position: 0}} =
               IbmClient.poll_job(authed_config(config), "job_xyz")
    end

    test "returns QUEUED with queue_position", %{api: api, config: config} do
      Bypass.expect_once(api, "GET", "/jobs/job_q", fn conn ->
        json_resp(conn, 200, %{
          id: "job_q",
          state: %{status: "QUEUED", reason: nil},
          queue_position: 17
        })
      end)

      assert {:ok, %{status: "QUEUED", queue_position: 17}} =
               IbmClient.poll_job(authed_config(config), "job_q")
    end

    test "returns ERROR with reason", %{api: api, config: config} do
      Bypass.expect_once(api, "GET", "/jobs/job_e", fn conn ->
        json_resp(conn, 200, %{
          id: "job_e",
          state: %{status: "ERROR", reason: "circuit too large"},
          queue_position: nil
        })
      end)

      assert {:ok, %{status: "ERROR", reason: "circuit too large"}} =
               IbmClient.poll_job(authed_config(config), "job_e")
    end

    test "all known statuses round-trip without atom conversion", %{api: api, config: config} do
      for status <- ~w(INITIALIZING QUEUED RUNNING DONE CANCELLED ERROR) do
        Bypass.expect_once(api, "GET", "/jobs/poll_#{status}", fn conn ->
          json_resp(conn, 200, %{state: %{status: status, reason: nil}, queue_position: 0})
        end)

        assert {:ok, %{status: ^status}} =
                 IbmClient.poll_job(authed_config(config), "poll_#{status}")
      end
    end

    test "unknown status surfaces loudly (no String.to_atom)", %{api: api, config: config} do
      Bypass.expect_once(api, "GET", "/jobs/job_drift", fn conn ->
        json_resp(conn, 200, %{state: %{status: "WAT_NEW_STATE", reason: nil}, queue_position: 0})
      end)

      assert {:error, {:unknown_status, "WAT_NEW_STATE"}} =
               IbmClient.poll_job(authed_config(config), "job_drift")
    end
  end

  describe "fetch_results/2" do
    test "Sampler shape returns counts + metadata", %{api: api, config: config} do
      Bypass.expect_once(api, "GET", "/jobs/job_done/results", fn conn ->
        json_resp(conn, 200, %{
          data: [%{counts: %{"00" => 512, "11" => 512}}],
          metadata: %{execution_time_ms: 1234, queue_wait_time_ms: 456}
        })
      end)

      assert {:ok, %{counts: counts, metadata: meta}} =
               IbmClient.fetch_results(authed_config(config), "job_done")

      assert counts == %{"00" => 512, "11" => 512}
      assert meta["execution_time_ms"] == 1234
    end

    test "Estimator shape (no counts) → :unsupported_result", %{api: api, config: config} do
      Bypass.expect_once(api, "GET", "/jobs/job_estim/results", fn conn ->
        json_resp(conn, 200, %{
          data: [%{values: "base64=="}],
          metadata: %{execution_time_ms: 100}
        })
      end)

      assert {:error, :unsupported_result} =
               IbmClient.fetch_results(authed_config(config), "job_estim")
    end
  end

  describe "close_session/2" do
    test "204 → :ok", %{api: api, config: config} do
      Bypass.expect_once(api, "DELETE", "/sessions/sess_x", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = IbmClient.close_session(authed_config(config), "sess_x")
    end

    test "404 → :ok (best-effort)", %{api: api, config: config} do
      Bypass.expect_once(api, "DELETE", "/sessions/gone", fn conn ->
        json_resp(conn, 404, %{error: "not_found"})
      end)

      assert :ok = IbmClient.close_session(authed_config(config), "gone")
    end
  end

  describe "base_url_for/1" do
    test "us_south points at quantum.cloud.ibm.com" do
      assert IbmClient.base_url_for(:us_south) == "https://quantum.cloud.ibm.com/api/v1"
    end

    test "eu_de points at eu-de host" do
      assert IbmClient.base_url_for(:eu_de) == "https://eu-de.quantum.cloud.ibm.com/api/v1"
    end
  end
end
