defmodule Kino.Qx.IbmClient do
  @moduledoc """
  HTTP client for IBM Quantum (Qiskit Runtime REST API).

  Wraps [Req](https://hexdocs.pm/req); the cell never touches HTTP
  details directly.

  ## Auth

  IBM Cloud splits identity into:

    * **API key** — exchanged at `iam.cloud.ibm.com/identity/token`
      for a 1-hour bearer token (`access_token`).
    * **Service-CRN** — sent on every API request to identify which
      Quantum *instance* the request is for. Cannot be derived from
      the API key.
    * **Region** — encoded into the CRN; the API base URL must match.

  Tokens are 1-hour TTL; long queue waits routinely outlive them.
  Every authed call is wrapped in `with_iam_refresh/2`, which catches
  401, runs a fresh IAM exchange once, and retries.

  ## Sessions are required

  Direct `POST /jobs` (without a session) was deprecated 2025-03-31.
  Callers must `open_session/3` first and pass the returned id into
  `submit_sampler/4`.

  ## Iron Law #7

  IBM job-state values arrive as binaries from the wire
  (`"INITIALIZING"`, `"QUEUED"`, `"RUNNING"`, `"DONE"`, `"CANCELLED"`,
  `"ERROR"`). They are matched against `@known_statuses` and returned
  as binaries — never `String.to_atom/1`-ed. Same posture as
  `Kino.Qx.Client`'s `@known_keys` allowlist.

  ## Privacy invariant

  This module never sees the qxportal token, and `Kino.Qx.Client`
  never sees the IBM API key or CRN. Two independent clients, two
  independent auth flows.
  """

  @iam_url_default "https://iam.cloud.ibm.com/identity/token"
  @api_version "2026-03-15"
  @known_statuses ~w(INITIALIZING QUEUED RUNNING DONE CANCELLED ERROR)
  @default_max_ttl 3600

  @typedoc "Region — encoded into the Service-CRN by IBM."
  @type region :: :us_south | :eu_de

  @typedoc """
  Configuration map.

  `:access_token` and `:token_expires_at` are populated by
  `iam_exchange/1`. `:iam_url` and `:base_url` are test/override
  hooks; production callers omit them.
  """
  @type config :: %{
          required(:api_key) => String.t(),
          required(:crn) => String.t(),
          required(:region) => region(),
          optional(:access_token) => String.t() | nil,
          optional(:token_expires_at) => DateTime.t() | nil,
          optional(:iam_url) => String.t(),
          optional(:base_url) => String.t()
        }

  ## --------------------------------------------------------------
  ## IAM
  ## --------------------------------------------------------------

  @doc """
  Exchanges the user's API key for a 1-hour IAM bearer token.

  Returns the input config with `:access_token` and
  `:token_expires_at` populated.
  """
  @spec iam_exchange(config()) :: {:ok, config()} | {:error, term()}
  def iam_exchange(%{api_key: api_key} = config) do
    url = Map.get(config, :iam_url, @iam_url_default)

    body =
      URI.encode_query(%{
        "grant_type" => "urn:ibm:params:oauth:grant-type:apikey",
        "apikey" => api_key,
        "response_type" => "cloud_iam"
      })

    request =
      Req.new(
        url: url,
        headers: [
          {"content-type", "application/x-www-form-urlencoded"},
          {"accept", "application/json"}
        ],
        body: body,
        receive_timeout: 10_000,
        retry: false
      )

    case Req.post(request) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token} = resp_body}} ->
        secs = resp_body["expires_in"] || 3600
        expires_at = DateTime.add(DateTime.utc_now(), secs, :second)
        {:ok, Map.merge(config, %{access_token: token, token_expires_at: expires_at})}

      {:ok, %Req.Response{status: status}} when status in [400, 401] ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, %{reason: reason}} ->
        {:error, {:network, reason}}

      {:error, exception} ->
        {:error, {:network, Exception.message(exception)}}
    end
  end

  ## --------------------------------------------------------------
  ## Backends
  ## --------------------------------------------------------------

  @doc """
  Lists backends available on the user's instance.

  Decodes only `:name`, `:status`, `:num_qubits` from each entry —
  the cell only displays these.
  """
  @spec list_backends(config()) ::
          {:ok, [%{name: String.t(), status: String.t() | nil, num_qubits: integer() | nil}]}
          | {:error, term()}
  def list_backends(config) do
    with_iam_refresh(config, fn cfg ->
      case authed_request(:get, cfg, "/backends", nil) do
        {:ok, %{"devices" => list}} when is_list(list) ->
          {:ok, Enum.map(list, &take_backend_summary/1)}

        {:ok, %{"backends" => list}} when is_list(list) ->
          {:ok, Enum.map(list, &take_backend_summary/1)}

        {:ok, list} when is_list(list) ->
          {:ok, Enum.map(list, &take_backend_summary/1)}

        {:ok, _other} ->
          {:error, :unexpected_response}

        error ->
          error
      end
    end)
  end

  @doc """
  Returns the `coupling_map`, `basis_gates`, and `num_qubits` for a
  backend. These are the fields qxportal's `/api/v1/transpile`
  payload requires.
  """
  @spec fetch_backend_properties(config(), String.t()) ::
          {:ok,
           %{
             coupling_map: list(list(non_neg_integer())),
             basis_gates: list(String.t()),
             num_qubits: non_neg_integer()
           }}
          | {:error, term()}
  def fetch_backend_properties(config, name) when is_binary(name) do
    with_iam_refresh(config, fn cfg ->
      case authed_request(:get, cfg, "/backends/#{name}/properties", nil) do
        {:ok, %{} = body} ->
          {:ok,
           %{
             coupling_map: body["coupling_map"],
             basis_gates: body["basis_gates"],
             num_qubits: body["num_qubits"]
           }}

        error ->
          error
      end
    end)
  end

  ## --------------------------------------------------------------
  ## Sessions
  ## --------------------------------------------------------------

  @doc """
  Opens a runtime session on the chosen backend.

  Sessions are mandatory: direct `/jobs` POST without a session has
  been deprecated since 2025-03-31. `max_ttl` defaults to 3600s
  (the IBM default); session auto-cancels pending jobs at expiry,
  running jobs complete.
  """
  @spec open_session(config(), String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def open_session(config, backend, max_ttl \\ @default_max_ttl)
      when is_binary(backend) and is_integer(max_ttl) and max_ttl > 0 do
    body = %{"backend" => backend, "mode" => "dedicated", "max_ttl" => max_ttl}

    with_iam_refresh(config, fn cfg ->
      case authed_request(:post, cfg, "/sessions", body) do
        {:ok, %{"id" => id}} when is_binary(id) -> {:ok, id}
        {:ok, _} -> {:error, :unexpected_response}
        error -> error
      end
    end)
  end

  @doc """
  Closes a session — best-effort. Returns `:ok` even on 404 since
  the cell calls this in cleanup paths where the session may already
  have expired.
  """
  @spec close_session(config(), String.t()) :: :ok | {:error, term()}
  def close_session(config, session_id) when is_binary(session_id) do
    case with_iam_refresh(config, fn cfg ->
           authed_request(:delete, cfg, "/sessions/#{session_id}", nil)
         end) do
      :ok -> :ok
      {:ok, _body} -> :ok
      {:error, :not_found} -> :ok
      error -> error
    end
  end

  ## --------------------------------------------------------------
  ## Jobs
  ## --------------------------------------------------------------

  @doc """
  Submits a Sampler job. The PUB-format wrapping (`pubs: [[qasm, nil]]`)
  is done here so callers never build the raw shape — forgetting the
  outer list is a 400.
  """
  @spec submit_sampler(config(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def submit_sampler(config, qasm, backend, session_id)
      when is_binary(qasm) and is_binary(backend) and is_binary(session_id) do
    body = %{
      "program_id" => "sampler",
      "backend" => backend,
      "session_id" => session_id,
      "params" => %{
        "pubs" => [[qasm, nil]],
        "version" => 2,
        "options" => %{"resilience_level" => 1}
      }
    }

    with_iam_refresh(config, fn cfg ->
      case authed_request(:post, cfg, "/jobs", body) do
        {:ok, %{"id" => id}} when is_binary(id) -> {:ok, id}
        {:ok, _} -> {:error, :unexpected_response}
        error -> error
      end
    end)
  end

  @doc """
  Returns the current job status as a binary, plus optional
  `queue_position` and `reason`.

  Status is matched against `@known_statuses`; an unknown value
  becomes `{:error, {:unknown_status, raw}}` so a future API
  drift surfaces loudly rather than silently being misclassified.
  """
  @spec poll_job(config(), String.t()) ::
          {:ok,
           %{
             status: String.t(),
             reason: String.t() | nil,
             queue_position: integer() | nil
           }}
          | {:error, term()}
  def poll_job(config, job_id) when is_binary(job_id) do
    with_iam_refresh(config, fn cfg ->
      case authed_request(:get, cfg, "/jobs/#{job_id}", nil) do
        {:ok, %{"state" => %{"status" => status} = state} = body} when is_binary(status) ->
          if status in @known_statuses do
            {:ok,
             %{
               status: status,
               reason: state["reason"],
               queue_position: body["queue_position"]
             }}
          else
            {:error, {:unknown_status, status}}
          end

        {:ok, _} ->
          {:error, :unexpected_response}

        error ->
          error
      end
    end)
  end

  @doc """
  Fetches the result of a finished job (Sampler shape only).

  Estimator results are tensor-encoded base64 — out of scope for
  this version; signalled as `{:error, :unsupported_result}`.
  """
  @spec fetch_results(config(), String.t()) ::
          {:ok, %{counts: map(), metadata: map()}} | {:error, term()}
  def fetch_results(config, job_id) when is_binary(job_id) do
    with_iam_refresh(config, fn cfg ->
      case authed_request(:get, cfg, "/jobs/#{job_id}/results", nil) do
        {:ok, %{"data" => [%{"counts" => counts} | _], "metadata" => metadata}} ->
          {:ok, %{counts: counts, metadata: metadata}}

        {:ok, %{"data" => [%{"counts" => counts} | _]}} ->
          {:ok, %{counts: counts, metadata: %{}}}

        {:ok, %{"data" => _}} ->
          # Data present but no `counts` key — Estimator/tensor shape.
          {:error, :unsupported_result}

        {:ok, _} ->
          {:error, :unexpected_response}

        error ->
          error
      end
    end)
  end

  ## --------------------------------------------------------------
  ## Internals
  ## --------------------------------------------------------------

  @doc false
  @spec base_url_for(region()) :: String.t()
  def base_url_for(:us_south), do: "https://quantum.cloud.ibm.com/api/v1"
  def base_url_for(:eu_de), do: "https://eu-de.quantum.cloud.ibm.com/api/v1"

  defp api_base_url(%{base_url: url}) when is_binary(url), do: String.trim_trailing(url, "/")
  defp api_base_url(%{region: region}), do: base_url_for(region)

  defp take_backend_summary(d) when is_map(d) do
    %{
      name: d["name"] || d["backend_name"],
      status: d["status"],
      num_qubits: d["num_qubits"]
    }
  end

  # Wraps an HTTP call in 401-refresh-retry-once. The fun receives
  # config and may receive a refreshed copy on retry. Result of fun
  # is returned to the caller; the refreshed config does not escape
  # this scope (the cell holds the canonical copy and re-exchanges
  # if a later call 401s again).
  defp with_iam_refresh(config, fun) when is_function(fun, 1) do
    case fun.(config) do
      {:error, :unauthorized} ->
        case iam_exchange(config) do
          {:ok, refreshed} -> fun.(refreshed)
          error -> error
        end

      other ->
        other
    end
  end

  defp authed_request(method, config, path, body) do
    url = api_base_url(config) <> path

    headers = [
      {"authorization", "Bearer " <> (config[:access_token] || "")},
      {"service-crn", config.crn},
      {"ibm-api-version", @api_version},
      {"accept", "application/json"}
    ]

    base_options = [
      url: url,
      headers: headers,
      receive_timeout: 30_000,
      retry: false
    ]

    options =
      cond do
        body != nil -> Keyword.put(base_options, :json, body)
        true -> base_options
      end

    request = Req.new(options)

    result =
      case method do
        :get -> Req.get(request)
        :post -> Req.post(request)
        :delete -> Req.delete(request)
      end

    handle_response(result)
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}), do: {:ok, body}
  defp handle_response({:ok, %Req.Response{status: 201, body: body}}), do: {:ok, body}
  defp handle_response({:ok, %Req.Response{status: 204}}), do: :ok
  defp handle_response({:ok, %Req.Response{status: 401}}), do: {:error, :unauthorized}
  defp handle_response({:ok, %Req.Response{status: 404}}), do: {:error, :not_found}

  defp handle_response({:ok, %Req.Response{status: 429} = resp}),
    do: {:error, {:rate_limited, retry_after_seconds(resp)}}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:http, status, body}}

  defp handle_response({:error, %{reason: reason}}), do: {:error, {:network, reason}}

  defp handle_response({:error, exception}),
    do: {:error, {:network, Exception.message(exception)}}

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
