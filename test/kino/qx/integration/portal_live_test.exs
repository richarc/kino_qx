defmodule Kino.Qx.Integration.PortalLiveTest do
  @moduledoc """
  Hits the **real** qxportal at `https://test.qxquantum.com` (or
  whatever `QXPORTAL_BASE_URL` env var overrides) and verifies the
  snippet-side contract end-to-end.

  The `/transpile` contract is now owned by `Qx.Hardware.Portal`
  upstream and tested in `qx/test/qx/hardware/portal_test.exs`. This
  file only covers what `kino_qx` itself still talks to the portal
  for: snippet browsing in `Kino.Qx.SmartCell`.

  Excluded from the default `mix test` run via the `:portal_live` tag
  in `test/test_helper.exs`. Run locally before each Hex publish:

      QXPORTAL_API_KEY=qx_live_... mix test --include portal_live
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

  test "GET /api/v1/snippets returns a list", %{config: config} do
    assert {:ok, snippets} = Client.list_snippets(config)
    assert is_list(snippets)
  end
end
