defmodule Kino.Qx.TranspilePipeline do
  @moduledoc """
  Orchestrates the full "transpile + submit + collect counts" flow.

  Lives outside the Smart Cell so the orchestration is testable
  without Kino. The cell wires this up by spawning a `Task` and
  threading status updates through the `:on_status` callback.

  ## Flow

      1. on_status.({:ibm, :authenticating})       → IbmClient.iam_exchange/1
      2. on_status.({:ibm, :fetching_backend})     → IbmClient.fetch_backend_properties/2
      3. on_status.({:portal, :transpiling})       → Client.transpile/2
      4. on_status.({:ibm, :opening_session})      → IbmClient.open_session/3
      5. on_status.({:ibm, :submitting})           → IbmClient.submit_sampler/4
      6. on_status.({:ibm, :polling, status, qp})  → IbmClient.poll_job/2 (loop)
      7. on_status.({:ibm, :fetching_results})     → IbmClient.fetch_results/2
      8. (best-effort)                             → IbmClient.close_session/2

  ## Error returns

  All failures normalised to `{:error, stage, reason}` so the cell
  UI can route messaging by stage:

    * `:ibm_auth` — IAM exchange or backend fetch failed
    * `:portal_transpile` — qxportal `/api/v1/transpile` failed
    * `:ibm_submit` — open_session or submit_sampler failed
    * `:ibm_polling` — a poll request itself failed (network, etc.)
    * `:ibm_polling_timeout` — `:timeout_ms` exceeded
    * `:ibm_job_failed` — IBM returned terminal status `ERROR` or `CANCELLED`
    * `:ibm_results` — results fetch failed

  ## Privacy invariant

  The qxportal token never reaches `IbmClient`; the IBM API key
  never reaches `Client`. Two configs in, two configs stay separate.
  """

  alias Kino.Qx.Client
  alias Kino.Qx.IbmClient

  @poll_first_interval_ms 1_000
  @poll_max_interval_ms 30_000
  # 24 hours — IBM queues can be very long. Cell can override.
  @default_timeout_ms 24 * 60 * 60 * 1000
  @terminal_failure_statuses ~w(ERROR CANCELLED)

  @type input :: %{
          required(:portal_config) => Client.config(),
          required(:ibm_config) => IbmClient.config(),
          required(:qasm) => String.t(),
          required(:backend) => String.t(),
          required(:optimization_level) => 0..3,
          optional(:seed_transpiler) => integer() | nil,
          optional(:on_status) => (any() -> any()),
          optional(:timeout_ms) => pos_integer(),
          optional(:ibm_client) => module(),
          optional(:portal_client) => module(),
          optional(:sleep) => (non_neg_integer() -> any())
        }

  @type result :: %{
          counts: map(),
          transpiled_qasm: String.t(),
          metadata: map(),
          job_id: String.t()
        }

  @spec run(input()) :: {:ok, result()} | {:error, atom(), term()}
  def run(%{ibm_config: _, portal_config: _, qasm: _, backend: _} = opts) do
    ibm = Map.get(opts, :ibm_client, IbmClient)
    portal = Map.get(opts, :portal_client, Client)
    on_status = Map.get(opts, :on_status, fn _ -> :ok end)
    sleep_fn = Map.get(opts, :sleep, &Process.sleep/1)
    timeout_ms = Map.get(opts, :timeout_ms, @default_timeout_ms)

    on_status.({:ibm, :authenticating})

    with {:ok, ibm_cfg} <- stage(:ibm_auth, fn -> ibm.iam_exchange(opts.ibm_config) end),
         _ = on_status.({:ibm, :fetching_backend}),
         {:ok, props} <-
           stage(:ibm_auth, fn -> ibm.fetch_backend_properties(ibm_cfg, opts.backend) end),
         _ = on_status.({:portal, :transpiling}),
         payload = build_transpile_payload(opts, props),
         {:ok, transpile_result} <-
           stage(:portal_transpile, fn -> portal.transpile(opts.portal_config, payload) end),
         _ = on_status.({:ibm, :opening_session}),
         {:ok, session_id} <-
           stage(:ibm_submit, fn -> ibm.open_session(ibm_cfg, opts.backend) end),
         # Emit so the cell can call close_session/2 if the user cancels
         # mid-poll. Without this the session leaks until max_ttl.
         _ = on_status.({:ibm, :session_opened, session_id}),
         _ = on_status.({:ibm, :submitting}),
         {:ok, job_id} <-
           stage(:ibm_submit, fn ->
             ibm.submit_sampler(ibm_cfg, transpile_result.qasm, opts.backend, session_id)
           end),
         {:ok, _final_info} <-
           poll_until_done(ibm, ibm_cfg, job_id, on_status, sleep_fn, timeout_ms),
         _ = on_status.({:ibm, :fetching_results}),
         {:ok, results} <-
           stage(:ibm_results, fn -> ibm.fetch_results(ibm_cfg, job_id) end) do
      # Best-effort cleanup; errors swallowed (session may have
      # auto-closed at TTL or never opened cleanly).
      _ = ibm.close_session(ibm_cfg, session_id)

      {:ok,
       %{
         counts: results.counts,
         transpiled_qasm: transpile_result.qasm,
         metadata: merge_metadata(transpile_result, results),
         job_id: job_id
       }}
    end
  end

  ## --------------------------------------------------------------
  ## Internals
  ## --------------------------------------------------------------

  defp stage(stage_atom, fun) when is_atom(stage_atom) and is_function(fun, 0) do
    case fun.() do
      {:ok, value} -> {:ok, value}
      :ok -> :ok
      {:error, reason} -> {:error, stage_atom, reason}
    end
  end

  defp build_transpile_payload(opts, props) do
    %{
      qasm: opts.qasm,
      coupling_map: props.coupling_map,
      basis_gates: props.basis_gates,
      optimization_level: opts.optimization_level,
      seed_transpiler: Map.get(opts, :seed_transpiler)
    }
  end

  defp merge_metadata(transpile_result, ibm_results) do
    portal_meta = Map.get(transpile_result, :metadata, %{}) || %{}
    ibm_meta = Map.get(ibm_results, :metadata, %{}) || %{}
    Map.merge(portal_meta, ibm_meta)
  end

  defp poll_until_done(ibm, cfg, job_id, on_status, sleep_fn, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll(ibm, cfg, job_id, on_status, sleep_fn, deadline, @poll_first_interval_ms)
  end

  defp do_poll(ibm, cfg, job_id, on_status, sleep_fn, deadline, interval) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :ibm_polling_timeout, :deadline_exceeded}
    else
      case ibm.poll_job(cfg, job_id) do
        {:ok, %{status: status} = info} ->
          on_status.({:ibm, :polling, status, info.queue_position})

          cond do
            status == "DONE" ->
              {:ok, info}

            status in @terminal_failure_statuses ->
              {:error, :ibm_job_failed, %{status: status, reason: info.reason}}

            true ->
              sleep_fn.(interval)
              next_interval = min(interval * 2, @poll_max_interval_ms)
              do_poll(ibm, cfg, job_id, on_status, sleep_fn, deadline, next_interval)
          end

        {:error, reason} ->
          {:error, :ibm_polling, reason}
      end
    end
  end
end
