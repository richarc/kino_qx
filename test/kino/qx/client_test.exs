defmodule Kino.Qx.ClientTest do
  @moduledoc """
  Verifies the client correctly maps every documented response shape
  from the portal API contract at <https://qxportal.dev/api/v1/docs>.

  The bodies below are golden fixtures — they MUST stay in sync with
  the portal's `test/qxportal_web/api/contract_test.exs`. A diff there
  is a wire-format change here.
  """
  use ExUnit.Case, async: true

  alias Kino.Qx.Client

  setup do
    bypass = Bypass.open()
    config = %{token: "qx_live_test_token", base_url: "http://localhost:#{bypass.port}"}
    %{bypass: bypass, config: config}
  end

  # Mirror the portal's actual response shape: JSON content-type so Req
  # auto-decodes the body, plus a Jason-encoded payload.
  defp json_resp(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(payload))
  end

  describe "me/1" do
    test "returns identity on 200", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/api/v1/me", fn conn ->
        assert ["Bearer qx_live_test_token"] = Plug.Conn.get_req_header(conn, "authorization")

        json_resp(conn, 200, %{
          data: %{email: "you@example.com", role: "user", api_key_name: "Livebook on laptop"}
        })
      end)

      assert {:ok, identity} = Client.me(config)

      assert identity == %{
               email: "you@example.com",
               role: "user",
               api_key_name: "Livebook on laptop"
             }
    end

    test "401 maps to :unauthorized", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/api/v1/me", fn conn ->
        json_resp(conn, 401, %{error: "unauthorized", detail: "Missing or invalid API key."})
      end)

      assert Client.me(config) == {:error, :unauthorized}
    end

    test "429 with retry-after maps to {:rate_limited, seconds}", %{
      bypass: bypass,
      config: config
    } do
      Bypass.expect_once(bypass, "GET", "/api/v1/me", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "37")
        |> json_resp(429, %{error: "rate_limited", detail: "..."})
      end)

      assert Client.me(config) == {:error, {:rate_limited, 37}}
    end

    test "network error maps to {:network, reason}", %{bypass: bypass, config: config} do
      Bypass.down(bypass)
      assert {:error, {:network, _}} = Client.me(config)
    end
  end

  describe "list_snippets/1" do
    test "returns parsed list on 200", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/api/v1/snippets", fn conn ->
        json_resp(conn, 200, %{
          data: [
            %{
              id: 1,
              name: "Bell pair",
              visibility: "public",
              share_url: "https://qxportal.dev/s/abcd1234",
              inserted_at: "2026-05-02T12:00:00Z",
              updated_at: "2026-05-02T12:00:00Z"
            },
            %{
              id: 2,
              name: "Private one",
              visibility: "private",
              share_url: nil,
              inserted_at: "2026-05-02T13:00:00Z",
              updated_at: "2026-05-02T13:00:00Z"
            }
          ]
        })
      end)

      assert {:ok, [first, second]} = Client.list_snippets(config)
      assert first.name == "Bell pair"
      assert first.share_url == "https://qxportal.dev/s/abcd1234"
      assert second.visibility == "private"
      assert second.share_url == nil
    end

    test "empty list on 200", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/api/v1/snippets", fn conn ->
        json_resp(conn, 200, %{data: []})
      end)

      assert Client.list_snippets(config) == {:ok, []}
    end
  end

  describe "get_snippet/2" do
    test "returns parsed snippet with bodies", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/api/v1/snippets/42", fn conn ->
        json_resp(conn, 200, %{
          data: %{
            id: 42,
            name: "Bell",
            visibility: "public",
            share_url: "https://qxportal.dev/s/xyz",
            qasm_content: "OPENQASM 3.0;\nqubit[2] q;\n",
            elixir_content: "",
            inserted_at: "2026-05-02T12:00:00Z",
            updated_at: "2026-05-02T12:00:00Z"
          }
        })
      end)

      assert {:ok, snippet} = Client.get_snippet(config, 42)
      assert snippet.id == 42
      assert snippet.qasm_content =~ "OPENQASM 3.0;"
      assert snippet.elixir_content == ""
    end

    test "404 maps to :not_found", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/api/v1/snippets/999", fn conn ->
        json_resp(conn, 404, %{error: "not_found", detail: "Resource not found."})
      end)

      assert Client.get_snippet(config, 999) == {:error, :not_found}
    end
  end

  describe "config handling" do
    test "trims trailing slash on base_url", %{bypass: bypass} do
      config = %{token: "x", base_url: "http://localhost:#{bypass.port}/"}

      Bypass.expect_once(bypass, "GET", "/api/v1/me", fn conn ->
        json_resp(conn, 200, %{data: %{}})
      end)

      assert {:ok, %{}} = Client.me(config)
    end
  end
end
