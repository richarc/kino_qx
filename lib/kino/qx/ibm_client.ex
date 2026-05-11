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

  ## Sessions are optional — we don't use them

  IBM's current spec (2026-05) treats sessions as optional and
  supports direct `POST /jobs`. Empirically verified against a
  production-proven reference (`qx_server`, last working 2026-02 and
  no relevant IBM API changes since per the changelog). Dropping
  sessions removes a request, an error path, and a leakage class.

  ## Iron Law #7

  IBM job-status values arrive as binaries from the wire (Pascal-Case
  per the documented enum: `"Queued"`, `"Running"`, `"Completed"`,
  `"Cancelled"`, `"Cancelled - Ran too long"`, `"Failed"`). They are
  matched against `@known_statuses` and returned as binaries — never
  `String.to_atom/1`-ed. Same posture as `Kino.Qx.Client`'s
  `@known_keys` allowlist.

  ## Privacy invariant

  This module never sees the qxportal token, and `Kino.Qx.Client`
  never sees the IBM API key or CRN. Two independent clients, two
  independent auth flows.
  """

  @iam_url_default "https://iam.cloud.ibm.com/identity/token"
  @api_version "2026-03-15"
  # IBM-documented JobStatus enum, Pascal-Case. Polled binaries are
  # matched against this set; any drift surfaces as a loud error.
  @known_statuses [
    "Queued",
    "Running",
    "Completed",
    "Cancelled",
    "Cancelled - Ran too long",
    "Failed"
  ]
  @terminal_success ["Completed"]
  @terminal_failure ["Failed", "Cancelled", "Cancelled - Ran too long"]
  @default_shots 4096

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

  IBM serves this static device shape from
  `GET /v1/backends/{name}/configuration` (NOT `/properties`, which
  returns time-varying per-gate / per-qubit calibration data).
  IBM names the qubit count `n_qubits` on the wire; we expose it as
  `:num_qubits` to match the rest of our API surface.
  """
  @spec fetch_backend_configuration(config(), String.t()) ::
          {:ok,
           %{
             coupling_map: list(list(non_neg_integer())),
             basis_gates: list(String.t()),
             num_qubits: non_neg_integer()
           }}
          | {:error, term()}
  def fetch_backend_configuration(config, name) when is_binary(name) do
    with_iam_refresh(config, fn cfg ->
      case authed_request(:get, cfg, "/backends/#{name}/configuration", nil) do
        {:ok, %{} = body} ->
          {:ok,
           %{
             coupling_map: body["coupling_map"],
             basis_gates: body["basis_gates"],
             num_qubits: body["n_qubits"] || body["num_qubits"]
           }}

        error ->
          error
      end
    end)
  end

  ## --------------------------------------------------------------
  ## Jobs
  ## --------------------------------------------------------------

  @doc """
  Submits a Sampler job. The PUB-format wrapping
  (`pubs: [[qasm, nil, shots]]`) is done here so callers never build
  the raw shape — forgetting the outer list is a 400. The 3-element
  PUB carries qasm + null observable + shot count (matches the
  production-proven `qx_server` wire format).

  No session is opened; IBM's spec treats sessions as optional and
  direct `POST /jobs` is fully supported.
  """
  @spec submit_sampler(config(), String.t(), String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def submit_sampler(config, qasm, backend, shots \\ @default_shots)
      when is_binary(qasm) and is_binary(backend) and is_integer(shots) and shots > 0 do
    body = %{
      "program_id" => "sampler",
      "backend" => backend,
      "params" => %{
        "version" => 2,
        "pubs" => [[qasm, nil, shots]]
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
  Returns the current job status as a binary.

  IBM's `GET /jobs/{id}` returns BOTH a top-level `status` and a
  nested `state.status` (which is the schema-required path). We read
  `state.status` and fall back to top-level — handles both old and
  new shapes.

  Status is matched against `@known_statuses`; an unknown value
  becomes `{:error, {:unknown_status, raw}}` so a future API drift
  surfaces loudly rather than silently being misclassified.
  """
  @spec poll_job(config(), String.t()) ::
          {:ok, %{status: String.t(), reason: String.t() | nil}}
          | {:error, term()}
  def poll_job(config, job_id) when is_binary(job_id) do
    with_iam_refresh(config, fn cfg ->
      case authed_request(:get, cfg, "/jobs/#{job_id}", nil) do
        {:ok, body} when is_map(body) ->
          parse_job_response(body)

        error ->
          error
      end
    end)
  end

  defp parse_job_response(body) do
    status = get_in(body, ["state", "status"]) || body["status"]
    reason = get_in(body, ["state", "reason"]) || body["reason"]

    cond do
      not is_binary(status) ->
        {:error, :unexpected_response}

      status in @known_statuses ->
        {:ok, %{status: status, reason: reason}}

      true ->
        {:error, {:unknown_status, status}}
    end
  end

  @doc """
  Cancels a running job. Returns `:ok` on 200/204 (including the
  "already terminal" idempotent path) and on 404 (job already gone).

  Uses `POST /jobs/{id}/cancel` per IBM's current spec.
  """
  @spec cancel_job(config(), String.t()) :: :ok | {:error, term()}
  def cancel_job(config, job_id) when is_binary(job_id) do
    case with_iam_refresh(config, fn cfg ->
           authed_request(:post, cfg, "/jobs/#{job_id}/cancel", %{})
         end) do
      :ok -> :ok
      {:ok, _body} -> :ok
      {:error, :not_found} -> :ok
      error -> error
    end
  end

  @doc false
  def terminal_success?(status), do: status in @terminal_success

  @doc false
  def terminal_failure?(status), do: status in @terminal_failure

  @doc """
  Fetches the result of a finished Sampler job and aggregates the
  individual shot samples into a counts map.

  IBM's Sampler V2 response shape (verified live 2026-05):

      {
        "results": [{
          "data": {
            "<classical_register_name>": {
              "samples": ["0x0", "0x3", "0x3", ...],
              "num_bits": 2
            }
          },
          "metadata": {...}
        }],
        "metadata": {...}
      }

  IBM does NOT pre-aggregate counts — each shot is returned as a
  hex bitstring under `data.<reg>.samples`. We aggregate ourselves:
  hex → integer → fixed-width binary → frequency map.

  Returns the IBM-side merged metadata for downstream display.

  Errors:
    * `:unexpected_response` — body doesn't have `results: [_ | _]`
    * `:unsupported_result` — first result has no recognizable data
      shape (e.g. Estimator tensor format)
  """
  @spec fetch_results(config(), String.t()) ::
          {:ok, %{counts: map(), metadata: map()}} | {:error, term()}
  def fetch_results(config, job_id) when is_binary(job_id) do
    with_iam_refresh(config, fn cfg ->
      case authed_request(:get, cfg, "/jobs/#{job_id}/results", nil) do
        {:ok, body} when is_map(body) -> parse_sampler_results(body)
        {:error, _} = error -> error
        _ -> {:error, :unexpected_response}
      end
    end)
  end

  defp parse_sampler_results(%{"results" => [first | _]} = body) when is_map(first) do
    data = first["data"] || %{}
    metadata = merge_result_metadata(body, first)

    # The result data is keyed by classical register name(s) used in
    # the circuit (typically `"c"` from `bit[2] c;` in the QASM). v1
    # of this client supports one register's samples; multi-register
    # results are deferred (would need a UI for picking which to
    # render).
    case find_register_samples(data) do
      {:ok, samples, num_bits} ->
        {:ok, %{counts: samples_to_counts(samples, num_bits), metadata: metadata}}

      :error ->
        {:error, :unsupported_result}
    end
  end

  defp parse_sampler_results(_), do: {:error, :unexpected_response}

  defp find_register_samples(data) when is_map(data) and map_size(data) > 0 do
    Enum.find_value(data, :error, fn
      {_name, %{"samples" => samples, "num_bits" => num_bits}}
      when is_list(samples) and is_integer(num_bits) ->
        {:ok, samples, num_bits}

      _ ->
        false
    end)
  end

  defp find_register_samples(_), do: :error

  # Convert a list of `"0x3"`-style hex samples into a frequency map
  # keyed by fixed-width binary strings (`"11"` for 2 bits, etc.) to
  # match qiskit's standard counts representation.
  defp samples_to_counts(samples, num_bits) do
    Enum.frequencies_by(samples, &hex_sample_to_bitstring(&1, num_bits))
  end

  defp hex_sample_to_bitstring("0x" <> hex, num_bits) when is_integer(num_bits) do
    case Integer.parse(hex, 16) do
      {n, ""} when n >= 0 ->
        n |> Integer.to_string(2) |> String.pad_leading(num_bits, "0")

      _ ->
        # Pass through unparseable values rather than crashing; they
        # surface as their own count bucket and signal a wire-format
        # regression.
        "0x" <> hex
    end
  end

  defp hex_sample_to_bitstring(other, _num_bits), do: inspect(other)

  defp merge_result_metadata(body, first_result) do
    job_meta = Map.get(body, "metadata", %{}) || %{}
    pub_meta = Map.get(first_result, "metadata", %{}) || %{}
    Map.merge(job_meta, pub_meta)
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

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}), do: {:ok, decode(body)}
  defp handle_response({:ok, %Req.Response{status: 201, body: body}}), do: {:ok, decode(body)}
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

  # Req's auto-decode keys off content-type. IBM's `/jobs/{id}/results`
  # is returned without `content-type: application/json` (verified
  # 2026-05 against the live API), so we fall back to Jason for any
  # binary body that's actually JSON. If decode fails we pass the
  # binary through unchanged.
  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp decode(body), do: body

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
