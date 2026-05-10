defmodule Kino.Qx.Client do
  @moduledoc """
  HTTP client for the Qx Portal API at `/api/v1`.

  Wraps [Req](https://hexdocs.pm/req) so the cell never touches HTTP
  details directly. Maps the documented error shapes to plain tuples
  the cell can pattern-match on.

  All functions take a config map:

      %{
        token: "qx_live_...",
        base_url: "https://qxportal.dev"
      }

  ## Error mapping

  Common to GET and POST:

  | HTTP                         | Returned                          |
  |------------------------------|-----------------------------------|
  | 200 OK                       | `{:ok, decoded_data}`             |
  | 401                          | `{:error, :unauthorized}`         |
  | 404                          | `{:error, :not_found}`            |
  | 429 + `retry-after` header   | `{:error, {:rate_limited, secs}}` |
  | Other 4xx/5xx                | `{:error, {:http, status, body}}` |
  | Network / Req exception      | `{:error, {:network, reason}}`    |

  POST-only (`transpile/2`):

  | HTTP | Returned                              |
  |------|---------------------------------------|
  | 422  | `{:error, :invalid_qasm}`             |
  | 502  | `{:error, :transpile_failed}`         |
  | 503  | `{:error, :transpile_unavailable}`    |
  | 504  | `{:error, :transpile_timeout}`        |
  """

  @typedoc "Configuration map for every client call."
  @type config :: %{required(:token) => String.t(), required(:base_url) => String.t()}

  @typedoc "The shape returned by `/api/v1/me`."
  @type identity :: %{
          email: String.t(),
          role: String.t(),
          api_key_name: String.t()
        }

  @typedoc "Single snippet summary as returned by `/api/v1/snippets`."
  @type snippet_summary :: %{
          id: integer(),
          name: String.t(),
          visibility: String.t(),
          share_url: String.t() | nil,
          inserted_at: String.t(),
          updated_at: String.t()
        }

  @typedoc "Full snippet as returned by `/api/v1/snippets/:id`."
  @type snippet :: %{
          id: integer(),
          name: String.t(),
          visibility: String.t(),
          share_url: String.t() | nil,
          qasm_content: String.t(),
          elixir_content: String.t(),
          inserted_at: String.t(),
          updated_at: String.t()
        }

  @doc """
  Confirms a token is valid and returns the authenticated identity.
  """
  @spec me(config()) :: {:ok, identity()} | {:error, term()}
  def me(config), do: get(config, "/api/v1/me")

  @doc """
  Returns the caller's snippets, newest first. List view (no bodies).
  """
  @spec list_snippets(config()) :: {:ok, [snippet_summary()]} | {:error, term()}
  def list_snippets(config), do: get(config, "/api/v1/snippets")

  @doc """
  Returns one snippet with bodies.
  """
  @spec get_snippet(config(), integer() | String.t()) :: {:ok, snippet()} | {:error, term()}
  def get_snippet(config, id), do: get(config, "/api/v1/snippets/#{id}")

  @typedoc "Successful transpile response payload."
  @type transpile_result :: %{
          qasm: String.t(),
          metadata: %{
            depth: non_neg_integer(),
            size: non_neg_integer(),
            num_qubits: non_neg_integer()
          }
        }

  @doc """
  Transpiles an OpenQASM 3.0 circuit for a target backend.

  `payload` is a map matching the qxportal `/api/v1/transpile`
  contract — typically:

      %{
        qasm: "OPENQASM 3.0; ...",
        coupling_map: [[0, 1], [1, 2]],
        basis_gates: ["id", "rz", "sx", "x", "cx"],
        optimization_level: 1,
        seed_transpiler: nil
      }

  Error mapping:

  | HTTP | Returned                              |
  |------|---------------------------------------|
  | 200  | `{:ok, %{qasm, metadata}}`            |
  | 401  | `{:error, :unauthorized}`             |
  | 422  | `{:error, :invalid_qasm}`             |
  | 429  | `{:error, {:rate_limited, secs}}`     |
  | 502  | `{:error, :transpile_failed}`         |
  | 503  | `{:error, :transpile_unavailable}`    |
  | 504  | `{:error, :transpile_timeout}`        |
  | other | `{:error, {:http, status, body}}`    |
  """
  @spec transpile(config(), map()) :: {:ok, transpile_result()} | {:error, term()}
  def transpile(config, payload) when is_map(payload),
    do: post(config, "/api/v1/transpile", payload)

  ## Internals

  defp get(%{token: token, base_url: base_url}, path) do
    url = String.trim_trailing(base_url, "/") <> path

    request =
      Req.new(
        url: url,
        headers: [
          {"authorization", "Bearer " <> token},
          {"accept", "application/json"}
        ],
        receive_timeout: 10_000,
        retry: false
      )

    handle_response(Req.get(request), :get)
  end

  defp post(%{token: token, base_url: base_url}, path, payload) do
    url = String.trim_trailing(base_url, "/") <> path

    request =
      Req.new(
        url: url,
        json: payload,
        headers: [
          {"authorization", "Bearer " <> token},
          {"accept", "application/json"}
        ],
        # Transpile can take longer than the read endpoints.
        receive_timeout: 30_000,
        retry: false
      )

    handle_response(Req.post(request), :post)
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: %{"data" => data}}}, _verb),
    do: {:ok, atomize(data)}

  defp handle_response({:ok, %Req.Response{status: 401}}, _verb),
    do: {:error, :unauthorized}

  defp handle_response({:ok, %Req.Response{status: 404}}, _verb),
    do: {:error, :not_found}

  defp handle_response({:ok, %Req.Response{status: 422}}, :post),
    do: {:error, :invalid_qasm}

  defp handle_response({:ok, %Req.Response{status: 429} = resp}, _verb),
    do: {:error, {:rate_limited, retry_after_seconds(resp)}}

  defp handle_response({:ok, %Req.Response{status: 502}}, :post),
    do: {:error, :transpile_failed}

  defp handle_response({:ok, %Req.Response{status: 503}}, :post),
    do: {:error, :transpile_unavailable}

  defp handle_response({:ok, %Req.Response{status: 504}}, :post),
    do: {:error, :transpile_timeout}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _verb),
    do: {:error, {:http, status, body}}

  defp handle_response({:error, %{reason: reason}}, _verb),
    do: {:error, {:network, reason}}

  defp handle_response({:error, exception}, _verb),
    do: {:error, {:network, Exception.message(exception)}}

  # Allow-list of atoms we know belong to the API contract. Anything
  # outside this set stays a string key — protects against atom
  # exhaustion if the portal ever adds an unexpected field.
  @known_keys ~w(
    id name email role api_key_name visibility share_url
    qasm_content elixir_content inserted_at updated_at
    error detail
    qasm metadata depth size num_qubits
  )a

  defp atomize(data) when is_list(data), do: Enum.map(data, &atomize/1)

  defp atomize(data) when is_map(data) do
    for {k, v} <- data, into: %{} do
      {to_known_atom(k), atomize(v)}
    end
  end

  defp atomize(other), do: other

  defp to_known_atom(key) when is_atom(key), do: key

  defp to_known_atom(key) when is_binary(key) do
    Enum.find(@known_keys, key, fn atom -> Atom.to_string(atom) == key end)
  end

  defp retry_after_seconds(%Req.Response{} = resp) do
    case Req.Response.get_header(resp, "retry-after") do
      [value | _] ->
        case Integer.parse(value) do
          {n, _} -> n
          :error -> nil
        end

      _ ->
        nil
    end
  end
end
