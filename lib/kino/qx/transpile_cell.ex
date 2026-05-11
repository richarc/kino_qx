defmodule Kino.Qx.TranspileCell do
  @moduledoc """
  Livebook Smart Cell that transpiles an OpenQASM 3.0 circuit via
  the Qx Portal and submits the result to IBM Quantum, rendering the
  measurement counts inline in the notebook.

  Registered automatically when `:kino_qx` is loaded — appears in
  Livebook's "+ Smart" menu as **"Qx Transpile + Submit"** alongside
  the existing **"Qx Snippet"** cell.

  ## Privacy invariant

  Three credentials live ONLY in the cell's transient state and are
  NEVER written into `to_attrs/1`:

    * Portal API token (`qx_live_…`)
    * IBM Cloud API key
    * IBM Service-CRN

  This means the `.livemd` file never persists secrets, so sharing a
  notebook does not leak any of them. The qxportal token never
  reaches IBM; the IBM token never reaches qxportal. Two separate
  HTTP clients, two separate auth flows.

  ## Persisted attrs

  Written into the `.livemd` file:

    * `portal_base_url`     — qxportal URL (default `https://test.qxquantum.com`)
    * `ibm_region`          — `"us-south"` or `"eu-de"`
    * `last_backend_name`   — IBM backend chosen
    * `qasm_paste`          — the textarea body (only saved when "save with notebook" is ON)
    * `save_qasm`           — boolean, default false; gates `qasm_paste` persistence
    * `optimization_level`  — 0..3, default 1
    * `shots`               — 1..100_000, default 4096 (Sampler measurement count)
    * `last_job_id`         — for re-attach awareness (display only)
    * `last_counts`         — last successful counts so a reopened notebook shows them

  ## Iron Law compliance

    * **#7** — IBM job statuses come off the wire as binaries; matched
      against an allowlist in `Kino.Qx.IbmClient` (never `String.to_atom/1`).
    * **#8** — every `handle_event` clause validates input shape:
      non-empty tokens; region in `["us-south", "eu-de"]`;
      optimization_level integer in 0..3; backend name appears in the
      cached `backends_list` (pre-connect the only valid value is
      empty); `portal_base_url` matches the host allowlist.
    * **#10** — the polling Task IS a runtime resource: a long-lived
      HTTP loop owned by the cell process. The cell process traps
      exits and surfaces an error if the Task crashes; `:normal`
      exits are ignored. Cancel kills the Task and best-effort closes
      the IBM session via the `session_id` the pipeline emits in its
      `on_status` stream.
  """
  use Kino.JS
  use Kino.JS.Live
  # `reevaluate_on_change: true` — when the pipeline completes and stores
  # `last_counts` + `last_job_id`, `to_attrs/1` returns a new value;
  # Livebook then re-runs `to_source/1` and re-evaluates the cell, which
  # renders the DataTable inline. Without this, the user would have to
  # click ▶ on the cell after every submit to see the result.
  #
  # Safe because `to_source/1` only varies with `last_counts` / `last_job_id`
  # — neither of those change during the polling loop, so we don't
  # re-evaluate repeatedly while a job is in flight.
  use Kino.SmartCell, name: "Qx Transpile + Submit", reevaluate_on_change: true

  alias Kino.Qx.TranspilePipeline

  @default_portal_base_url "https://test.qxquantum.com"
  @valid_regions ~w(us-south eu-de)
  @region_atoms %{"us-south" => :us_south, "eu-de" => :eu_de}

  # Allowed hosts for the qxportal URL. A persisted `.livemd` carries
  # `portal_base_url`; a malicious shared notebook could otherwise
  # redirect the user's qx_live_… bearer to attacker infrastructure.
  # https://test.qxquantum.com is the v1 default; https://www.qxquantum.com
  # is the planned production host. localhost is permitted for local
  # development against a self-hosted portal.
  @portal_host_allowlist ~w(qxquantum.com www.qxquantum.com test.qxquantum.com localhost 127.0.0.1)
  @portal_https_required_suffix ".qxquantum.com"

  @impl true
  def init(attrs, ctx) do
    # Trap exits so a crashed polling Task surfaces as an error rather
    # than silently killing the cell process. Iron Law #10: the Task is
    # link-spawned (cell teardown reaps it) AND we own its EXIT signals.
    Process.flag(:trap_exit, true)

    ctx =
      assign(ctx,
        # Persisted (echoed in to_attrs/1)
        portal_base_url:
          validate_portal_url(attrs["portal_base_url"]) || @default_portal_base_url,
        ibm_region: attrs["ibm_region"] || "us-south",
        last_backend_name: attrs["last_backend_name"] || "",
        qasm_paste: attrs["qasm_paste"] || "",
        save_qasm: attrs["save_qasm"] || false,
        optimization_level: attrs["optimization_level"] || 1,
        shots: attrs["shots"] || 4096,
        last_job_id: attrs["last_job_id"],
        last_counts: attrs["last_counts"],
        # Transient (NEVER in to_attrs/1)
        portal_token: "",
        ibm_api_key: "",
        ibm_crn: "",
        backends_list: [],
        connected: false,
        identity: nil,
        current_status: "idle",
        current_status_detail: nil,
        current_job_id: nil,
        polling_task_pid: nil,
        error: nil
      )

    {:ok, ctx}
  end

  @impl true
  def handle_connect(ctx), do: {:ok, client_payload(ctx), ctx}

  ## --------------------------------------------------------------
  ## Field updates — Iron Law #8: validate every event payload.
  ## --------------------------------------------------------------

  @impl true
  def handle_event("update_portal_base_url", %{"value" => value}, ctx)
      when is_binary(value) do
    case validate_portal_url(value) do
      nil ->
        {:noreply,
         set_error(
           ctx,
           "Portal URL must be https://*.qxquantum.com (or http://localhost for dev)."
         )}

      validated ->
        {:noreply, assign(ctx, portal_base_url: validated)}
    end
  end

  def handle_event("update_portal_token", %{"value" => value}, ctx) when is_binary(value) do
    {:noreply, assign(ctx, portal_token: value)}
  end

  def handle_event("update_ibm_api_key", %{"value" => value}, ctx) when is_binary(value) do
    {:noreply, assign(ctx, ibm_api_key: value)}
  end

  def handle_event("update_ibm_crn", %{"value" => value}, ctx) when is_binary(value) do
    {:noreply, assign(ctx, ibm_crn: value)}
  end

  def handle_event("update_ibm_region", %{"value" => value}, ctx)
      when value in @valid_regions do
    {:noreply, assign(ctx, ibm_region: value)}
  end

  def handle_event("update_backend", %{"value" => value}, ctx) when is_binary(value) do
    if backend_known?(ctx, value) do
      {:noreply, assign(ctx, last_backend_name: value)}
    else
      {:noreply, set_error(ctx, "Backend not in available list — Connect first.")}
    end
  end

  def handle_event("update_qasm_paste", %{"value" => value}, ctx) when is_binary(value) do
    {:noreply, assign(ctx, qasm_paste: value)}
  end

  def handle_event("update_save_qasm", %{"value" => value}, ctx) when is_boolean(value) do
    {:noreply, assign(ctx, save_qasm: value)}
  end

  def handle_event("update_optimization_level", %{"value" => value}, ctx) do
    case parse_optimization_level(value) do
      {:ok, level} -> {:noreply, assign(ctx, optimization_level: level)}
      :error -> {:noreply, set_error(ctx, "Optimization level must be 0..3.")}
    end
  end

  def handle_event("update_shots", %{"value" => value}, ctx) do
    case parse_shots(value) do
      {:ok, shots} -> {:noreply, assign(ctx, shots: shots)}
      :error -> {:noreply, set_error(ctx, "Shots must be a positive integer (1..100000).")}
    end
  end

  ## --------------------------------------------------------------
  ## Connect — IAM exchange + portal /me + list_backends
  ## --------------------------------------------------------------

  def handle_event("connect", _params, ctx) do
    with :ok <- require_non_empty(ctx.assigns.portal_token, "portal token"),
         :ok <- require_non_empty(ctx.assigns.ibm_api_key, "IBM API key"),
         :ok <- require_non_empty(ctx.assigns.ibm_crn, "IBM Service-CRN") do
      parent = self()

      Task.start_link(fn ->
        send(parent, {:connect_result, do_connect(ctx)})
      end)

      ctx =
        assign(ctx,
          current_status: "connecting",
          error: nil
        )

      broadcast_event(ctx, "update", client_payload(ctx))
      {:noreply, ctx}
    else
      {:error, msg} -> {:noreply, set_error(ctx, msg)}
    end
  end

  ## --------------------------------------------------------------
  ## Submit — TranspilePipeline.run/1 in a linked Task
  ## --------------------------------------------------------------

  def handle_event("submit", _params, ctx) do
    with :ok <- require_connected(ctx),
         :ok <- require_non_empty(ctx.assigns.last_backend_name, "backend"),
         :ok <- require_non_empty(ctx.assigns.qasm_paste, "QASM source"),
         :ok <- require_optimization_level(ctx.assigns.optimization_level),
         :ok <- require_shots(ctx.assigns.shots) do
      input = build_pipeline_input(ctx)
      parent = self()

      {:ok, task_pid} =
        Task.start_link(fn ->
          result = TranspilePipeline.run(input)
          send(parent, {:pipeline_done, result})
        end)

      ctx =
        assign(ctx,
          polling_task_pid: task_pid,
          current_status: "submitting",
          current_status_detail: nil,
          current_job_id: nil,
          error: nil
        )

      broadcast_event(ctx, "update", client_payload(ctx))
      {:noreply, ctx}
    else
      {:error, msg} -> {:noreply, set_error(ctx, msg)}
    end
  end

  ## --------------------------------------------------------------
  ## Cancel — kill the polling Task and cancel the IBM job.
  ## --------------------------------------------------------------

  def handle_event("cancel", _params, ctx) do
    if ctx.assigns.polling_task_pid && Process.alive?(ctx.assigns.polling_task_pid) do
      Process.exit(ctx.assigns.polling_task_pid, :kill)
    end

    # Best-effort cancel — fire from a fresh Task so we don't block the
    # cell process on a 30s HTTP timeout. cancel_job/2 tolerates 404
    # (job already terminal). Safe to skip if we never observed
    # `:job_started` (e.g., cancel during transpile or auth).
    if job_id = ctx.assigns.current_job_id do
      ibm_cfg = ibm_config(ctx)
      Task.start(fn -> Kino.Qx.IbmClient.cancel_job(ibm_cfg, job_id) end)
    end

    ctx =
      assign(ctx,
        polling_task_pid: nil,
        current_job_id: nil,
        current_status: "cancelled",
        current_status_detail: nil
      )

    broadcast_event(ctx, "update", client_payload(ctx))
    {:noreply, ctx}
  end

  ## --------------------------------------------------------------
  ## Async results from the connect / submit Tasks
  ## --------------------------------------------------------------

  @impl true
  def handle_info({:connect_result, {:ok, %{identity: identity, backends: backends}}}, ctx) do
    ctx =
      assign(ctx,
        connected: true,
        identity: identity,
        backends_list: backends,
        current_status: "connected",
        error: nil
      )

    broadcast_event(ctx, "update", client_payload(ctx))
    {:noreply, ctx}
  end

  def handle_info({:connect_result, {:error, stage, reason}}, ctx) do
    ctx =
      ctx
      |> assign(connected: false, current_status: "error")
      |> set_error(connect_error_message(stage, reason))

    {:noreply, ctx}
  end

  def handle_info({:status, event}, ctx) do
    {:noreply, apply_pipeline_status(ctx, event)}
  end

  def handle_info({:pipeline_done, {:ok, result}}, ctx) do
    ctx =
      assign(ctx,
        polling_task_pid: nil,
        current_status: "done",
        current_status_detail: nil,
        current_job_id: result.job_id,
        last_job_id: result.job_id,
        last_counts: result.counts,
        error: nil
      )

    broadcast_event(ctx, "update", client_payload(ctx))
    {:noreply, ctx}
  end

  def handle_info({:pipeline_done, {:error, stage, reason}}, ctx) do
    ctx =
      ctx
      |> assign(polling_task_pid: nil, current_status: "error")
      |> set_error(pipeline_error_message(stage, reason))

    {:noreply, ctx}
  end

  # Linked Tasks (connect / submit pipeline) — `:normal` exits are
  # ignored; abnormal exits surface as a cell error so the user sees
  # something happened. Without this a crash mid-poll would silently
  # leave the cell in "polling" state forever.
  def handle_info({:EXIT, pid, reason}, ctx) do
    cond do
      reason == :normal ->
        {:noreply, ctx}

      pid == ctx.assigns.polling_task_pid ->
        ctx =
          ctx
          |> assign(polling_task_pid: nil, current_status: "error")
          |> set_error("Pipeline crashed: #{inspect(reason)}")

        {:noreply, ctx}

      true ->
        {:noreply, ctx}
    end
  end

  ## --------------------------------------------------------------
  ## Persistence
  ## --------------------------------------------------------------

  @impl true
  def to_attrs(ctx) do
    # CRITICAL: any token-shaped value (portal_token, ibm_api_key,
    # ibm_crn) MUST NOT appear here. Persisted attrs end up in the
    # .livemd file and travel with shared notebooks.
    %{
      "portal_base_url" => ctx.assigns.portal_base_url,
      "ibm_region" => ctx.assigns.ibm_region,
      "last_backend_name" => ctx.assigns.last_backend_name,
      "save_qasm" => ctx.assigns.save_qasm,
      # Only persist QASM if the user opted in.
      "qasm_paste" => if(ctx.assigns.save_qasm, do: ctx.assigns.qasm_paste, else: ""),
      "optimization_level" => ctx.assigns.optimization_level,
      "shots" => ctx.assigns.shots,
      "last_job_id" => ctx.assigns.last_job_id,
      "last_counts" => ctx.assigns.last_counts
    }
  end

  ## --------------------------------------------------------------
  ## Generated source — runs in the notebook on each cell evaluation.
  ## Phase 5: counts as a Kino.DataTable + optional VegaLite chart +
  ## metadata markdown.
  ## --------------------------------------------------------------

  @impl true
  def to_source(attrs) do
    case Map.get(attrs, "last_counts") do
      counts when is_map(counts) and map_size(counts) > 0 ->
        render_counts_source(counts, Map.get(attrs, "last_job_id"))

      _ ->
        "# No results yet. Click \"Submit\" in the cell above."
    end
  end

  defp render_counts_source(counts, job_id) do
    # Pre-sort here so the generated code is deterministic; the table
    # itself just renders the list. We keep keys as binaries — Kino
    # bitstrings come straight from the IBM wire.
    sorted =
      counts
      |> Enum.sort_by(fn {_bits, n} -> -n end)
      |> Enum.map(fn {bits, n} -> %{bitstring: bits, count: n} end)

    rows_literal = inspect(sorted, limit: :infinity, printable_limit: :infinity)
    job_label = job_id || "—"

    """
    # Generated by Kino.Qx.TranspileCell — counts for IBM Quantum job #{job_label}.
    rows = #{rows_literal}

    counts_table = Kino.DataTable.new(rows, name: "Counts (job #{job_label})")

    chart =
      if Code.ensure_loaded?(Kino.VegaLite) and Code.ensure_loaded?(VegaLite) do
        Kino.VegaLite.new(
          VegaLite.new(width: 400, height: 240)
          |> VegaLite.data_from_values(rows)
          |> VegaLite.mark(:bar)
          |> VegaLite.encode_field(:x, "bitstring", type: :nominal, sort: "-y")
          |> VegaLite.encode_field(:y, "count", type: :quantitative)
        )
      else
        nil
      end

    if chart do
      Kino.Layout.grid([counts_table, chart], boxed: true)
    else
      counts_table
    end
    """
  end

  ## --------------------------------------------------------------
  ## Internals
  ## --------------------------------------------------------------

  defp do_connect(ctx) do
    portal_config = portal_config(ctx)
    ibm_config = ibm_config(ctx)

    with {:ok, identity} <- Kino.Qx.Client.me(portal_config),
         {:ok, ibm_cfg} <- Kino.Qx.IbmClient.iam_exchange(ibm_config),
         {:ok, backends} <- Kino.Qx.IbmClient.list_backends(ibm_cfg) do
      {:ok, %{identity: identity, backends: backends}}
    else
      {:error, reason} -> {:error, :connect, reason}
    end
  end

  defp build_pipeline_input(ctx) do
    parent = self()

    %{
      portal_config: portal_config(ctx),
      ibm_config: ibm_config(ctx),
      qasm: ctx.assigns.qasm_paste,
      backend: ctx.assigns.last_backend_name,
      optimization_level: ctx.assigns.optimization_level,
      shots: ctx.assigns.shots,
      on_status: &send(parent, {:status, &1})
    }
  end

  defp portal_config(ctx) do
    %{
      token: ctx.assigns.portal_token,
      base_url: ctx.assigns.portal_base_url
    }
  end

  defp ibm_config(ctx) do
    %{
      api_key: ctx.assigns.ibm_api_key,
      crn: ctx.assigns.ibm_crn,
      region: Map.fetch!(@region_atoms, ctx.assigns.ibm_region)
    }
  end

  defp apply_pipeline_status(ctx, {:ibm, :job_started, job_id})
       when is_binary(job_id) do
    # Pipeline tells us the IBM job id so cancel can call cancel_job/2.
    # Without this we have no way to stop the job once submitted.
    ctx = assign(ctx, current_job_id: job_id)
    broadcast_event(ctx, "update", client_payload(ctx))
    ctx
  end

  defp apply_pipeline_status(ctx, {:ibm, :polling, status}) do
    ctx =
      assign(ctx,
        current_status: "polling",
        current_status_detail: String.downcase(status)
      )

    broadcast_event(ctx, "update", client_payload(ctx))
    ctx
  end

  defp apply_pipeline_status(ctx, event) do
    label =
      case event do
        {:ibm, :authenticating} -> "authenticating with IBM"
        {:ibm, :fetching_backend} -> "fetching backend properties"
        {:portal, :transpiling} -> "transpiling at qxportal"
        {:ibm, :submitting} -> "submitting job"
        {:ibm, :fetching_results} -> "fetching results"
        other -> inspect(other)
      end

    ctx = assign(ctx, current_status: "running", current_status_detail: label)
    broadcast_event(ctx, "update", client_payload(ctx))
    ctx
  end

  # Iron Law #8: backend names are user input. Validate against the
  # cached `backends_list`. Pre-connect (empty list) the only valid
  # value is the empty string — any other binary is rejected so
  # `last_backend_name` cannot be stuffed before Connect populates the
  # list. (Submit also gates on `require_connected/1`; this is the
  # earlier defence-in-depth.)
  defp backend_known?(_ctx, ""), do: true

  defp backend_known?(%{assigns: %{backends_list: []}}, _name), do: false

  defp backend_known?(%{assigns: %{backends_list: list}}, name) do
    Enum.any?(list, fn b -> b.name == name end)
  end

  defp parse_optimization_level(value) when is_integer(value) and value in 0..3,
    do: {:ok, value}

  defp parse_optimization_level(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n in 0..3 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_optimization_level(_), do: :error

  defp parse_shots(value) when is_integer(value) and value in 1..100_000, do: {:ok, value}

  defp parse_shots(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n in 1..100_000 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_shots(_), do: :error

  defp require_non_empty(value, label) do
    if is_binary(value) and String.trim(value) != "" do
      :ok
    else
      {:error, "#{label} is required"}
    end
  end

  defp require_optimization_level(level) when is_integer(level) and level in 0..3, do: :ok
  defp require_optimization_level(_), do: {:error, "Optimization level must be 0..3"}

  defp require_shots(shots) when is_integer(shots) and shots in 1..100_000, do: :ok
  defp require_shots(_), do: {:error, "Shots must be a positive integer (1..100000)"}

  defp require_connected(%{assigns: %{connected: true}}), do: :ok
  defp require_connected(_), do: {:error, "Connect first to verify credentials and load backends"}

  defp set_error(ctx, msg) do
    ctx
    |> assign(error: msg)
    |> tap(&broadcast_event(&1, "update", client_payload(&1)))
  end

  defp connect_error_message(:connect, :unauthorized),
    do: "Auth rejected (401). Check your portal token and IBM API key."

  defp connect_error_message(:connect, {:rate_limited, secs}) when is_integer(secs),
    do: "Rate limited. Try again in #{secs}s."

  defp connect_error_message(:connect, {:network, _reason}),
    do: "Network error reaching the portal or IBM Cloud."

  defp connect_error_message(:connect, reason),
    do: "Connect failed: #{redact_reason(reason)}."

  defp pipeline_error_message(:ibm_auth, :unauthorized),
    do: "IBM auth failed (401). Check API key and Service-CRN."

  defp pipeline_error_message(:portal_transpile, :invalid_qasm),
    do: "Portal rejected the QASM (422). Fix syntax and resubmit."

  defp pipeline_error_message(:portal_transpile, {:invalid_qasm, detail}) when is_binary(detail),
    do: "Portal rejected the QASM (422): #{detail}"

  defp pipeline_error_message(:portal_transpile, {:invalid_qasm, _}),
    do: "Portal rejected the QASM (422). Fix syntax and resubmit."

  defp pipeline_error_message(:portal_transpile, :transpile_failed),
    do: "Portal transpile failed (502). The transpiler errored on this circuit/backend pair."

  defp pipeline_error_message(:portal_transpile, :transpile_timeout),
    do: "Portal transpile timed out (504). Try a smaller circuit or simpler backend."

  defp pipeline_error_message(:ibm_polling_timeout, _),
    do: "IBM job did not finish within the configured timeout."

  defp pipeline_error_message(:ibm_job_failed, %{status: status, reason: reason}),
    do: "IBM job ended with #{status}: #{reason || "no reason given"}."

  defp pipeline_error_message(stage, reason), do: "Failed at #{stage}: #{redact_reason(reason)}."

  # SSRF defence. A persisted `.livemd` carries `portal_base_url`; a
  # malicious shared notebook could otherwise redirect the user's
  # `qx_live_…` bearer to attacker infrastructure. We allow:
  #
  #   * `https://` + host in `@portal_host_allowlist` or ending in
  #     `.qxquantum.com` (covers `test.`, `www.`, `qxquantum.com`, plus
  #     any future subdomain qxquantum.com itself stands up)
  #   * `http://localhost` and `http://127.0.0.1` for local development
  #
  # Returns the trimmed URL on success, `nil` on rejection. Callers
  # treat `nil` as "fall back to default" (init) or "show error event"
  # (update_portal_base_url).
  @doc false
  # Public for testability; not part of the cell's user-facing API.
  @spec validate_portal_url(any()) :: String.t() | nil
  def validate_portal_url(nil), do: nil

  def validate_portal_url(value) when is_binary(value) do
    trimmed = String.trim(value)

    case URI.parse(trimmed) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        if portal_host_allowed?(host), do: trimmed, else: nil

      %URI{scheme: "http", host: host} when host in ["localhost", "127.0.0.1"] ->
        trimmed

      _ ->
        nil
    end
  end

  def validate_portal_url(_), do: nil

  defp portal_host_allowed?(host) do
    host in @portal_host_allowlist or
      String.ends_with?(host, @portal_https_required_suffix)
  end

  # Don't echo arbitrary HTTP bodies into the cell error UI — IBM IAM
  # 4xx bodies have echoed apikeys before, and Req exception messages
  # can carry full URLs (with credentials). Strip to a safe summary.
  defp redact_reason(:unauthorized), do: "unauthorized"
  defp redact_reason(:not_found), do: "not found"
  defp redact_reason(:invalid_qasm), do: "invalid QASM"

  defp redact_reason({:invalid_qasm, detail}) when is_binary(detail),
    do: "invalid QASM: #{detail}"

  defp redact_reason({:invalid_qasm, _}), do: "invalid QASM"
  defp redact_reason(:transpile_failed), do: "portal transpile failed"
  defp redact_reason(:transpile_timeout), do: "portal transpile timed out"
  defp redact_reason(:transpile_unavailable), do: "portal transpile unavailable"
  defp redact_reason(:unsupported_result), do: "unsupported result shape"
  defp redact_reason({:rate_limited, secs}) when is_integer(secs), do: "rate limited (#{secs}s)"
  defp redact_reason({:http, status, _body}), do: "HTTP #{status}"
  defp redact_reason({:network, _reason}), do: "network failure"
  defp redact_reason({:unknown_status, _raw}), do: "unknown IBM job status"
  defp redact_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp redact_reason(_), do: "unexpected error"

  # Payload sent to the JS side. Tokens are NEVER included.
  defp client_payload(ctx) do
    %{
      portal_base_url: ctx.assigns.portal_base_url,
      ibm_region: ctx.assigns.ibm_region,
      last_backend_name: ctx.assigns.last_backend_name,
      qasm_paste: ctx.assigns.qasm_paste,
      save_qasm: ctx.assigns.save_qasm,
      optimization_level: ctx.assigns.optimization_level,
      shots: ctx.assigns.shots,
      backends_list: Enum.map(ctx.assigns.backends_list, &%{name: &1.name, status: &1.status}),
      connected: ctx.assigns.connected,
      identity_email: ctx.assigns.identity && ctx.assigns.identity[:email],
      current_status: ctx.assigns.current_status,
      current_status_detail: ctx.assigns.current_status_detail,
      current_job_id: ctx.assigns.current_job_id,
      last_job_id: ctx.assigns.last_job_id,
      has_results: is_map(ctx.assigns.last_counts) and map_size(ctx.assigns.last_counts) > 0,
      error: ctx.assigns.error
    }
  end

  asset "main.js" do
    """
    export function init(ctx, payload) {
      ctx.importCSS("main.css");

      ctx.root.innerHTML = `
        <div class="qx-cell">
          <fieldset class="qx-section">
            <legend>Credentials (transient — never saved to notebook)</legend>
            <div class="qx-row">
              <label>Portal URL</label>
              <input id="qx-portal-url" type="text" />
            </div>
            <div class="qx-row">
              <label>Portal token</label>
              <input id="qx-portal-token" type="password" placeholder="qx_live_..." autocomplete="off" />
            </div>
            <div class="qx-row">
              <label>IBM API key</label>
              <input id="qx-ibm-key" type="password" autocomplete="off" />
            </div>
            <div class="qx-row">
              <label>Service-CRN</label>
              <input id="qx-ibm-crn" type="text" placeholder="crn:v1:bluemix:public:quantum:..." autocomplete="off" />
            </div>
            <div class="qx-row">
              <label>Region</label>
              <select id="qx-ibm-region">
                <option value="us-south">us-south</option>
                <option value="eu-de">eu-de</option>
              </select>
            </div>
            <div class="qx-row qx-actions">
              <button id="qx-connect">Connect</button>
              <span id="qx-conn-status"></span>
            </div>
          </fieldset>

          <fieldset class="qx-section qx-hidden" id="qx-job-section">
            <legend>Job</legend>
            <div class="qx-row">
              <label>Backend</label>
              <select id="qx-backend">
                <option value="">— pick one —</option>
              </select>
            </div>
            <div class="qx-row">
              <label>Optimization</label>
              <select id="qx-opt">
                <option value="0">0</option>
                <option value="1">1</option>
                <option value="2">2</option>
                <option value="3">3</option>
              </select>
            </div>
            <div class="qx-row">
              <label>Shots</label>
              <input id="qx-shots" type="number" min="1" max="100000" step="1" />
            </div>
            <div class="qx-row qx-col-row">
              <label>QASM</label>
              <textarea id="qx-qasm" rows="6" placeholder="OPENQASM 3.0;\\nqubit[2] q;\\nh q[0];\\ncx q[0], q[1];\\nmeasure q;"></textarea>
            </div>
            <div class="qx-row">
              <label></label>
              <label class="qx-inline"><input id="qx-save" type="checkbox" /> Save QASM with notebook (off by default — circuits may be sensitive)</label>
            </div>
            <div class="qx-row qx-actions">
              <button id="qx-submit">Submit</button>
              <button id="qx-cancel" class="qx-secondary">Cancel</button>
              <span id="qx-job-status"></span>
            </div>
          </fieldset>

          <div id="qx-error" class="qx-error qx-hidden"></div>
        </div>
      `;

      const $ = sel => ctx.root.querySelector(sel);

      function applyPayload(p) {
        $("#qx-portal-url").value = p.portal_base_url || "";
        $("#qx-ibm-region").value = p.ibm_region || "us-south";
        $("#qx-opt").value = String(p.optimization_level ?? 1);
        $("#qx-shots").value = String(p.shots ?? 4096);
        $("#qx-qasm").value = p.qasm_paste || "";
        $("#qx-save").checked = !!p.save_qasm;

        // Backend dropdown
        const backendSel = $("#qx-backend");
        backendSel.innerHTML = '<option value="">— pick one —</option>';
        (p.backends_list || []).forEach(b => {
          const opt = document.createElement("option");
          opt.value = b.name;
          opt.textContent = `${b.name}${b.status ? " (" + b.status + ")" : ""}`;
          if (p.last_backend_name && p.last_backend_name === b.name) opt.selected = true;
          backendSel.appendChild(opt);
        });

        if (p.last_backend_name && (!p.backends_list || p.backends_list.length === 0)) {
          const opt = document.createElement("option");
          opt.value = "__remembered__";
          opt.textContent = `${p.last_backend_name} (saved — connect to refresh)`;
          opt.selected = true;
          opt.disabled = true;
          backendSel.appendChild(opt);
        }

        // Connection status
        const connEl = $("#qx-conn-status");
        if (p.connected && p.identity_email) {
          connEl.textContent = `✓ ${p.identity_email}`;
          connEl.className = "qx-ok";
          $("#qx-job-section").classList.remove("qx-hidden");
        } else if (p.current_status === "connecting") {
          connEl.textContent = "connecting…";
          connEl.className = "qx-pending";
        } else {
          connEl.textContent = "";
          connEl.className = "";
        }

        // Job status
        const jobEl = $("#qx-job-status");
        const detail = p.current_status_detail ? ` — ${p.current_status_detail}` : "";
        switch (p.current_status) {
          case "submitting":
          case "running":
          case "polling":
            jobEl.textContent = `… ${p.current_status}${detail}`;
            jobEl.className = "qx-pending";
            break;
          case "done":
            jobEl.textContent = `✓ done${p.last_job_id ? " (" + p.last_job_id + ")" : ""}`;
            jobEl.className = "qx-ok";
            break;
          case "cancelled":
            jobEl.textContent = "cancelled";
            jobEl.className = "qx-pending";
            break;
          case "error":
            jobEl.textContent = "error";
            jobEl.className = "qx-bad";
            break;
          default:
            jobEl.textContent = "";
            jobEl.className = "";
        }

        // Error panel
        const errEl = $("#qx-error");
        if (p.error) {
          errEl.textContent = p.error;
          errEl.classList.remove("qx-hidden");
        } else {
          errEl.textContent = "";
          errEl.classList.add("qx-hidden");
        }
      }
      applyPayload(payload);

      // ---- inputs --------------------------------------------------
      $("#qx-portal-url").addEventListener("change", e =>
        ctx.pushEvent("update_portal_base_url", { value: e.target.value })
      );
      $("#qx-portal-token").addEventListener("input", e =>
        ctx.pushEvent("update_portal_token", { value: e.target.value })
      );
      $("#qx-ibm-key").addEventListener("input", e =>
        ctx.pushEvent("update_ibm_api_key", { value: e.target.value })
      );
      $("#qx-ibm-crn").addEventListener("input", e =>
        ctx.pushEvent("update_ibm_crn", { value: e.target.value })
      );
      $("#qx-ibm-region").addEventListener("change", e =>
        ctx.pushEvent("update_ibm_region", { value: e.target.value })
      );
      $("#qx-backend").addEventListener("change", e => {
        if (e.target.value && e.target.value !== "__remembered__") {
          ctx.pushEvent("update_backend", { value: e.target.value });
        }
      });
      $("#qx-opt").addEventListener("change", e =>
        ctx.pushEvent("update_optimization_level", { value: e.target.value })
      );
      $("#qx-shots").addEventListener("change", e =>
        ctx.pushEvent("update_shots", { value: e.target.value })
      );
      $("#qx-qasm").addEventListener("change", e =>
        ctx.pushEvent("update_qasm_paste", { value: e.target.value })
      );
      $("#qx-save").addEventListener("change", e =>
        ctx.pushEvent("update_save_qasm", { value: e.target.checked })
      );
      $("#qx-connect").addEventListener("click", () => ctx.pushEvent("connect", {}));
      $("#qx-submit").addEventListener("click", () => ctx.pushEvent("submit", {}));
      $("#qx-cancel").addEventListener("click", () => ctx.pushEvent("cancel", {}));

      ctx.handleEvent("update", payload => applyPayload(payload));

      ctx.handleSync(() => {
        document.activeElement &&
          document.activeElement.dispatchEvent(new Event("change"));
      });
    }
    """
  end

  asset "main.css" do
    """
    .qx-cell {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      font-size: 14px;
      padding: 12px;
      display: flex;
      flex-direction: column;
      gap: 12px;
    }
    .qx-section {
      border: 1px solid #e2e8f0;
      border-radius: 6px;
      padding: 8px 12px;
      display: flex;
      flex-direction: column;
      gap: 6px;
    }
    .qx-section legend {
      padding: 0 6px;
      color: #475569;
      font-size: 12px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    .qx-row {
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .qx-row label {
      width: 110px;
      flex-shrink: 0;
      color: #64748b;
      font-weight: 500;
    }
    .qx-row input[type="text"],
    .qx-row input[type="password"],
    .qx-row select {
      flex: 1;
      min-width: 0;
      padding: 6px 8px;
      border: 1px solid #cbd5e1;
      border-radius: 4px;
      font-size: 13px;
      font-family: inherit;
    }
    .qx-row textarea {
      flex: 1;
      min-width: 0;
      padding: 6px 8px;
      border: 1px solid #cbd5e1;
      border-radius: 4px;
      font-size: 12px;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    }
    .qx-col-row { align-items: flex-start; }
    .qx-inline { width: auto !important; font-weight: 400 !important; }
    .qx-actions { gap: 12px; }
    .qx-actions button {
      padding: 6px 14px;
      border: 1px solid #3b82f6;
      background: #3b82f6;
      color: white;
      border-radius: 4px;
      cursor: pointer;
      font-size: 13px;
    }
    .qx-actions button:hover { background: #2563eb; }
    .qx-actions button.qx-secondary {
      background: white;
      color: #475569;
      border-color: #cbd5e1;
    }
    .qx-actions button.qx-secondary:hover { background: #f1f5f9; }
    .qx-ok { color: #059669; font-size: 13px; }
    .qx-pending { color: #b45309; font-size: 13px; }
    .qx-bad { color: #b91c1c; font-size: 13px; }
    .qx-error {
      color: #b91c1c;
      background: #fef2f2;
      border: 1px solid #fecaca;
      border-radius: 4px;
      padding: 8px 12px;
      font-size: 13px;
    }
    .qx-hidden { display: none; }
    """
  end
end
