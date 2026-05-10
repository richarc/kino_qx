defmodule Kino.Qx.Integration.IbmLiveTest do
  @moduledoc """
  Hits **real** IBM Quantum Cloud and verifies the IAM exchange,
  backend listing, and (optionally) a tiny Bell pair submit on the
  cheapest available backend.

  Excluded from the default `mix test` run via the `:ibm_live` tag.
  Run locally before each Hex publish:

      IBM_QUANTUM_API_KEY=... \\
      IBM_QUANTUM_CRN=crn:v1:bluemix:public:quantum:us-south:a/...:... \\
      mix test --include ibm_live

  Submission requires `IBM_QUANTUM_SUBMIT=1` to be set as well — IBM
  charges per shot on most backends, so we never auto-submit. Without
  it, only the read-only IAM + list_backends path is exercised.

  A failure here usually means IBM has migrated the API again
  (history: 2023-24 provider→runtime, 2025-03 jobs→sessions). Update
  `lib/kino/qx/ibm_client.ex` accordingly.
  """
  use ExUnit.Case, async: true

  alias Kino.Qx.IbmClient

  @moduletag :ibm_live

  setup do
    api_key = System.get_env("IBM_QUANTUM_API_KEY")
    crn = System.get_env("IBM_QUANTUM_CRN")
    region_str = System.get_env("IBM_QUANTUM_REGION", "us-south")

    region =
      case region_str do
        "us-south" -> :us_south
        "eu-de" -> :eu_de
        _ -> :us_south
      end

    cond do
      is_nil(api_key) or api_key == "" ->
        {:skip, "IBM_QUANTUM_API_KEY not set"}

      is_nil(crn) or crn == "" ->
        {:skip, "IBM_QUANTUM_CRN not set"}

      true ->
        {:ok, config: %{api_key: api_key, crn: crn, region: region}}
    end
  end

  test "IAM exchange returns a usable access_token", %{config: config} do
    assert {:ok, refreshed} = IbmClient.iam_exchange(config)
    assert is_binary(refreshed.access_token)
    assert byte_size(refreshed.access_token) > 50
    assert %DateTime{} = refreshed.token_expires_at
    assert DateTime.compare(refreshed.token_expires_at, DateTime.utc_now()) == :gt
  end

  test "list_backends returns at least one backend", %{config: config} do
    assert {:ok, refreshed} = IbmClient.iam_exchange(config)
    assert {:ok, backends} = IbmClient.list_backends(refreshed)
    assert is_list(backends)
    assert backends != []

    first = List.first(backends)
    assert is_binary(first.name)
  end

  test "fetch_backend_properties on first backend yields coupling_map + basis_gates",
       %{config: config} do
    {:ok, refreshed} = IbmClient.iam_exchange(config)
    {:ok, [backend | _]} = IbmClient.list_backends(refreshed)

    assert {:ok, props} = IbmClient.fetch_backend_properties(refreshed, backend.name)
    assert is_list(props.coupling_map)
    assert is_list(props.basis_gates)
    assert is_integer(props.num_qubits)
  end

  describe "full submit (IBM_QUANTUM_SUBMIT=1)" do
    @describetag :ibm_live_submit

    setup %{config: config} do
      if System.get_env("IBM_QUANTUM_SUBMIT") != "1" do
        {:skip, "IBM_QUANTUM_SUBMIT not set — skipping shot-charging submit"}
      else
        {:ok, config: config}
      end
    end

    test "Bell pair: submit_sampler → poll → fetch_results (no sessions)",
         %{config: config} do
      {:ok, refreshed} = IbmClient.iam_exchange(config)
      {:ok, [backend | _]} = IbmClient.list_backends(refreshed)

      # Gate-level only — measurement is added by IBM's Sampler at
      # submit time. This matches qxportal's transpile contract.
      qasm = """
      OPENQASM 3.0;
      include "stdgates.inc";
      qubit[2] q;
      h q[0];
      cx q[0], q[1];
      """

      # No session open — direct POST /jobs (qx_server-proven path).
      shots = 100

      assert {:ok, job_id} =
               IbmClient.submit_sampler(refreshed, qasm, backend.name, shots)

      assert is_binary(job_id)

      # Poll until terminal — bounded loop. Real IBM queue waits can
      # be long; we cap at 5 minutes for the live test.
      deadline = System.monotonic_time(:millisecond) + 5 * 60 * 1000
      final = poll_until_done(refreshed, job_id, deadline)

      assert match?({:ok, %{status: "Completed"}}, final),
             "expected Completed, got #{inspect(final)}"

      assert {:ok, %{counts: counts}} = IbmClient.fetch_results(refreshed, job_id)
      assert is_map(counts)
      assert map_size(counts) > 0
    end
  end

  defp poll_until_done(config, job_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      case IbmClient.poll_job(config, job_id) do
        {:ok, %{status: status}} = ok
        when status in ["Completed", "Failed", "Cancelled", "Cancelled - Ran too long"] ->
          ok

        {:ok, _} ->
          Process.sleep(2_000)
          poll_until_done(config, job_id, deadline)

        {:error, _} = error ->
          error
      end
    end
  end
end
