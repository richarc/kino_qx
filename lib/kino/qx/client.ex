defmodule Kino.Qx.Client do
  @moduledoc """
  HTTP client for the snippet-browsing slice of the Qx Portal API
  at `/api/v1`.

  Wraps [Req](https://hexdocs.pm/req) so the snippet Smart Cell never
  touches HTTP details directly. Maps the documented error shapes to
  plain tuples the cell can pattern-match on.

  Hardware-execution endpoints (`/api/v1/transpile`) live in
  `Qx.Hardware.Portal` upstream — kino_qx delegates through
  `Kino.Qx.run!/2` rather than calling them directly.

  All functions take a config map:

      %{
        token: "qx_live_...",
        base_url: "https://qxportal.dev"
      }

  ## Error mapping

  | HTTP                         | Returned                          |
  |------------------------------|-----------------------------------|
  | 200 OK                       | `{:ok, decoded_data}`             |
  | 401                          | `{:error, :unauthorized}`         |
  | 404                          | `{:error, :not_found}`            |
  | 429 + `retry-after` header   | `{:error, {:rate_limited, secs}}` |
  | Other 4xx/5xx                | `{:error, {:http, status, body}}` |
  | Network / Req exception      | `{:error, {:network, reason}}`    |
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

    handle_response(Req.get(request))
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: %{"data" => data}}}),
    do: {:ok, atomize(data)}

  defp handle_response({:ok, %Req.Response{status: 401}}),
    do: {:error, :unauthorized}

  defp handle_response({:ok, %Req.Response{status: 404}}),
    do: {:error, :not_found}

  defp handle_response({:ok, %Req.Response{status: 429} = resp}),
    do: {:error, {:rate_limited, retry_after_seconds(resp)}}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:http, status, body}}

  defp handle_response({:error, %{reason: reason}}),
    do: {:error, {:network, reason}}

  defp handle_response({:error, exception}),
    do: {:error, {:network, Exception.message(exception)}}

  # Allow-list of atoms we know belong to the snippet API contract.
  # Anything outside this set stays a string key — protects against
  # atom exhaustion if the portal ever adds an unexpected field.
  @known_keys ~w(
    id name email role api_key_name visibility share_url
    qasm_content elixir_content inserted_at updated_at
    error
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
