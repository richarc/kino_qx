defmodule Kino.Qx.Integration.IbmLiveTest do
  @moduledoc """
  Hits **real** IBM Quantum Cloud + qxportal via `Kino.Qx.run!/2`,
  end-to-end. Verifies the new pipeline (credentials cell → run!
  wrapper → `Qx.Hardware.run/3`) against a tiny Bell pair on the
  cheapest available backend.

  Excluded from the default `mix test` run via the `:ibm_live` tag.
  Run locally before each Hex publish:

      QXPORTAL_API_KEY=qx_live_... \\
      IBM_QUANTUM_API_KEY=... \\
      IBM_QUANTUM_CRN=crn:v1:bluemix:public:quantum:us-south:a/...:... \\
      mix test --include ibm_live

  Submission requires `IBM_QUANTUM_SUBMIT=1` to be set as well — IBM
  charges per shot on most backends, so we never auto-submit. Without
  it, only the auth + list_backends path is exercised via
  `Qx.Hardware.connect/2`.

  A failure here usually means either:
    * IBM has migrated the API again (update `Qx.Hardware.Ibm` upstream)
    * qxportal's `/transpile` contract changed (update `Qx.Hardware.Portal`)
  """
  use ExUnit.Case, async: false

  @moduletag :ibm_live

  # ExUnit decides `:skip` from TAGS, evaluated *before* `setup` runs —
  # a setup-returned `:skip` is ignored (the test still runs). The only
  # correct way to gate on runtime env is a compile-time `@tag skip:`.
  # This module is compiled when `mix test` loads it, so `System.get_env`
  # here reflects the invocation's environment.
  @missing_creds (cond do
                    System.get_env("QXPORTAL_API_KEY") in [nil, ""] ->
                      "QXPORTAL_API_KEY not set"

                    System.get_env("IBM_QUANTUM_API_KEY") in [nil, ""] ->
                      "IBM_QUANTUM_API_KEY not set"

                    System.get_env("IBM_QUANTUM_CRN") in [nil, ""] ->
                      "IBM_QUANTUM_CRN not set"

                    true ->
                      false
                  end)

  @submit_gate if System.get_env("IBM_QUANTUM_SUBMIT") == "1",
                 do: false,
                 else: "IBM_QUANTUM_SUBMIT != 1 (real submission gated)"

  # Missing creds → skip every test in the module with a clear reason.
  if @missing_creds, do: @moduletag(skip: @missing_creds)

  setup do
    portal_token = System.get_env("QXPORTAL_API_KEY")
    portal_url = System.get_env("QXPORTAL_BASE_URL", "https://test.qxquantum.com")
    ibm_api_key = System.get_env("IBM_QUANTUM_API_KEY")
    ibm_crn = System.get_env("IBM_QUANTUM_CRN")
    ibm_region = System.get_env("IBM_QUANTUM_REGION", "us-south")

    {:ok, base_config: base_config(portal_url, portal_token, ibm_api_key, ibm_crn, ibm_region)}
  end

  defp base_config(portal_url, portal_token, ibm_api_key, ibm_crn, ibm_region) do
    %Qx.Hardware.Config{
      portal_url: portal_url,
      portal_token: portal_token,
      ibm_api_key: ibm_api_key,
      ibm_crn: ibm_crn,
      ibm_region: ibm_region,
      backend: "",
      optimization_level: 1,
      shots: 1024
    }
  end

  test "Qx.Hardware.connect/2 validates auth and lists backends", %{base_config: cfg} do
    assert {:ok, %Qx.Hardware.Config{} = connected} = Qx.Hardware.connect(cfg)
    assert is_binary(connected.identity)
    assert is_list(connected.backends_list)
    refute connected.backends_list == []
  end

  # Default-excluded via test_helper (`:ibm_submit`). Even when the user
  # explicitly `--include ibm_submit`s, the compile-time @submit_gate
  # still skips unless IBM_QUANTUM_SUBMIT=1 — an accidental include must
  # not bill the account.
  @tag :ibm_submit
  if @submit_gate, do: @tag(skip: @submit_gate)

  test "Kino.Qx.run!/2 end-to-end Bell pair (requires IBM_QUANTUM_SUBMIT=1)", %{
    base_config: cfg
  } do
    {:ok, connected} = Qx.Hardware.connect(cfg)
    [first_backend | _] = connected.backends_list
    backend_name = if is_binary(first_backend), do: first_backend, else: first_backend.name
    cfg = %{connected | backend: backend_name}

    circuit =
      Qx.create_circuit(2, 2)
      |> Qx.h(0)
      |> Qx.cx(0, 1)
      |> Qx.measure(0, 0)
      |> Qx.measure(1, 1)

    result = Kino.Qx.run!(circuit, cfg)

    assert %Qx.SimulationResult{} = result
    assert map_size(result.counts) >= 1
    total = Enum.reduce(result.counts, 0, fn {_b, n}, acc -> acc + n end)
    assert total == cfg.shots
  end
end
