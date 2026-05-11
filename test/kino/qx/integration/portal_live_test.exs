defmodule Kino.Qx.Integration.PortalLiveTest do
  @moduledoc """
  Hits the **real** qxportal at `https://test.qxquantum.com` (or
  whatever `QXPORTAL_BASE_URL` env var overrides) and verifies the
  transpile contract end-to-end.

  Excluded from the default `mix test` run via the `:portal_live` tag
  in `test/test_helper.exs`. Run locally before each Hex publish:

      QXPORTAL_API_KEY=qx_live_... mix test --include portal_live

  A failure here means the portal contract has changed — update the
  client in `lib/kino/qx/client.ex`.
  """
  use ExUnit.Case, async: true

  alias Kino.Qx.Client

  @moduletag :portal_live

  setup do
    api_key = System.get_env("QXPORTAL_API_KEY")
    base_url = System.get_env("QXPORTAL_BASE_URL", "https://test.qxquantum.com")

    if is_nil(api_key) or api_key == "" do
      {:skip, "QXPORTAL_API_KEY not set"}
    else
      {:ok, config: %{token: api_key, base_url: base_url}}
    end
  end

  test "GET /api/v1/me returns the authenticated identity", %{config: config} do
    assert {:ok, identity} = Client.me(config)
    assert is_map(identity)
    assert is_binary(identity.email)
  end

  test "POST /api/v1/transpile transpiles a Bell pair", %{config: config} do
    # Match qxportal's documented example exactly — measurement is NOT
    # accepted here (qiskit.qasm3.loads is strict). The IBM Sampler
    # primitive adds measurement at submit time.
    qasm = """
    OPENQASM 3.0;
    include "stdgates.inc";
    qubit[2] q;
    h q[0];
    cx q[0], q[1];
    """

    payload = %{
      qasm: qasm,
      coupling_map: [[0, 1], [1, 0]],
      basis_gates: ["id", "rz", "sx", "x", "cx"],
      optimization_level: 1,
      seed_transpiler: 42
    }

    case Client.transpile(config, payload) do
      {:ok, result} ->
        assert is_binary(result.qasm)
        assert result.qasm =~ "OPENQASM"
        assert is_map(result.metadata)
        assert is_integer(result.metadata.depth) or is_nil(result.metadata.depth)

      {:error, {:invalid_qasm, detail}} ->
        flunk("Portal rejected the QASM with detail: #{detail}")

      other ->
        flunk("Unexpected response: #{inspect(other)}")
    end
  end
end
