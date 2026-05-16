defmodule Kino.Qx.CredentialsCell do
  @moduledoc """
  Livebook Smart Cell that emits a `%Qx.Hardware.Config{}` binding
  (`qx`) for downstream cells to pipe circuits through.

  Registered automatically when `:kino_qx` is loaded — appears in
  Livebook's "+ Smart" menu as **"Qx Credentials"** alongside the
  existing **"Qx Snippet"** cell.

  ## Usage

  In a notebook:

      # Cell 1: this Smart Cell — fill in URL/region/backend, click Connect.
      # It emits:
      qx = %Qx.Hardware.Config{
        portal_url: "https://test.qxquantum.com",
        portal_token: System.fetch_env!("LB_PORTAL_TOKEN"),
        ibm_api_key: System.fetch_env!("LB_IBM_API_KEY"),
        ibm_crn: System.fetch_env!("LB_IBM_CRN"),
        ibm_region: "us-south",
        backend: "ibm_brisbane",
        optimization_level: 1,
        shots: 4096
      }

      # Cell 2: regular Elixir
      circuit
      |> Kino.Qx.run!(qx)
      |> Qx.Draw.plot_counts(title: "Bell state")

  ## Privacy invariant

  This cell **never accepts tokens into its UI**. The three secrets
  live in **Livebook secrets** under these fixed names:

    * `LB_PORTAL_TOKEN`  — qxportal `qx_live_…` bearer
    * `LB_IBM_API_KEY`   — IBM Cloud API key
    * `LB_IBM_CRN`       — IBM Service-CRN

  Connect reads them via `System.fetch_env!/1`; `to_source/1` emits
  code that does the same. Tokens never appear in cell state, never
  enter the `.livemd` file. Sharing a notebook does not leak any
  credential — the recipient must define their own secrets.

  See the Livebook docs for how to add session/hub secrets:
  https://hexdocs.pm/livebook/secrets.html

  ## Persisted attrs

  Written into the `.livemd` file (none are secret):

    * `portal_base_url`    — qxportal URL (default `https://test.qxquantum.com`)
    * `ibm_region`         — `"us-south"` or `"eu-de"`
    * `last_backend_name`  — IBM backend chosen
    * `optimization_level` — 0..3, default 1
    * `shots`              — 1..100_000, default 4096

  ## Iron Law compliance

    * **#7** — IBM job statuses come off the wire upstream in
      `Qx.Hardware.Ibm` and are matched against an allowlist there;
      this cell never coins atoms from network responses.
    * **#8** — every `handle_event/3` clause validates input shape:
      region in `["us-south", "eu-de"]`; optimization_level integer
      in 0..3; shots integer in 1..100_000; backend name appears in
      the cached `backends_list`; `portal_base_url` matches the host
      allowlist.
    * **#11** — no long-lived processes. The Connect task is
      short-lived (auth + list backends, then `send/2` the result and
      exit). It is **unlinked** (`Task.start/1`) so a `do_connect/1`
      raise can't wipe cell state; orphan risk is nil because the
      task self-terminates after one `send/2`.
  """
  use Kino.JS
  use Kino.JS.Live
  use Kino.SmartCell, name: "Qx Credentials"

  alias Qx.Hardware

  @default_portal_base_url "https://test.qxquantum.com"
  @valid_regions ~w(us-south eu-de)

  # Livebook secret names. Hard-coded so they appear identically in
  # the emitted source and in the cell's help text.
  @secret_portal_token "LB_PORTAL_TOKEN"
  @secret_ibm_api_key "LB_IBM_API_KEY"
  @secret_ibm_crn "LB_IBM_CRN"

  # Allowed hosts for the qxportal URL. A persisted `.livemd` carries
  # `portal_base_url`; a malicious shared notebook could otherwise
  # redirect the user's `qx_live_…` bearer to attacker infrastructure.
  @portal_host_allowlist ~w(qxquantum.com www.qxquantum.com test.qxquantum.com localhost 127.0.0.1)
  @portal_https_required_suffix ".qxquantum.com"

  @impl true
  def init(attrs, ctx) do
    ctx =
      assign(ctx,
        # Persisted (echoed in to_attrs/1)
        portal_base_url:
          validate_portal_url(attrs["portal_base_url"]) || @default_portal_base_url,
        ibm_region: attrs["ibm_region"] || "us-south",
        last_backend_name: attrs["last_backend_name"] || "",
        optimization_level: attrs["optimization_level"] || 1,
        shots: attrs["shots"] || 4096,
        # Transient (NEVER in to_attrs/1)
        backends_list: [],
        connected: false,
        identity: nil,
        connecting: false,
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
        {:noreply, assign(ctx, portal_base_url: validated, error: nil)}
    end
  end

  def handle_event("update_ibm_region", %{"value" => value}, ctx)
      when is_binary(value) do
    if valid_ibm_region?(value) do
      {:noreply, assign(ctx, ibm_region: value, error: nil)}
    else
      {:noreply, set_error(ctx, "Invalid region.")}
    end
  end

  def handle_event("update_ibm_region", _params, ctx) do
    {:noreply, set_error(ctx, "Invalid region.")}
  end

  def handle_event("update_backend", %{"value" => value}, ctx) when is_binary(value) do
    if backend_known?(ctx, value) do
      {:noreply, assign(ctx, last_backend_name: value, error: nil)}
    else
      {:noreply, set_error(ctx, "Backend not in available list — Connect first.")}
    end
  end

  def handle_event("update_optimization_level", %{"value" => value}, ctx) do
    case parse_optimization_level(value) do
      {:ok, level} -> {:noreply, assign(ctx, optimization_level: level, error: nil)}
      :error -> {:noreply, set_error(ctx, "Optimization level must be 0..3.")}
    end
  end

  def handle_event("update_shots", %{"value" => value}, ctx) do
    case parse_shots(value) do
      {:ok, shots} -> {:noreply, assign(ctx, shots: shots, error: nil)}
      :error -> {:noreply, set_error(ctx, "Shots must be a positive integer (1..100000).")}
    end
  end

  ## --------------------------------------------------------------
  ## Connect — reads Livebook secrets, calls Qx.Hardware.connect/2
  ## --------------------------------------------------------------

  def handle_event("connect", _params, ctx) do
    parent = self()

    # Unlinked on purpose: a raise inside do_connect/1 must NOT take
    # the cell process down with it (that would wipe cell state). The
    # result is delivered via send/2, so a link buys nothing here.
    Task.start(fn ->
      send(parent, {:connect_result, do_connect(ctx)})
    end)

    ctx = assign(ctx, connecting: true, error: nil)
    broadcast_event(ctx, "update", client_payload(ctx))
    {:noreply, ctx}
  end

  @impl true
  def handle_info({:connect_result, {:ok, %Qx.Hardware.Config{} = connected_cfg}}, ctx) do
    ctx =
      assign(ctx,
        connected: true,
        connecting: false,
        identity: connected_cfg.identity,
        backends_list: connected_cfg.backends_list,
        error: nil
      )

    broadcast_event(ctx, "update", client_payload(ctx))
    {:noreply, ctx}
  end

  def handle_info({:connect_result, {:error, reason}}, ctx) do
    ctx =
      ctx
      |> assign(connected: false, connecting: false)
      |> set_error(connect_error_message(reason))

    {:noreply, ctx}
  end

  ## --------------------------------------------------------------
  ## Persistence — CRITICAL: tokens NEVER appear here.
  ## --------------------------------------------------------------

  @impl true
  def to_attrs(ctx) do
    %{
      "portal_base_url" => ctx.assigns.portal_base_url,
      "ibm_region" => ctx.assigns.ibm_region,
      "last_backend_name" => ctx.assigns.last_backend_name,
      "optimization_level" => ctx.assigns.optimization_level,
      "shots" => ctx.assigns.shots
    }
  end

  ## --------------------------------------------------------------
  ## Generated source — emits qx = %Qx.Hardware.Config{...} with
  ## System.fetch_env! for tokens so the .livemd never carries them.
  ## --------------------------------------------------------------

  @impl true
  def to_source(attrs) do
    portal_url = inspect(attrs["portal_base_url"] || @default_portal_base_url)
    region = inspect(attrs["ibm_region"] || "us-south")
    backend = inspect(attrs["last_backend_name"] || "")
    opt_level = attrs["optimization_level"] || 1
    shots = attrs["shots"] || 4096

    """
    qx = %Qx.Hardware.Config{
      portal_url: #{portal_url},
      portal_token: System.fetch_env!(#{inspect(@secret_portal_token)}),
      ibm_api_key: System.fetch_env!(#{inspect(@secret_ibm_api_key)}),
      ibm_crn: System.fetch_env!(#{inspect(@secret_ibm_crn)}),
      ibm_region: #{region},
      backend: #{backend},
      optimization_level: #{opt_level},
      shots: #{shots}
    }\
    """
  end

  ## --------------------------------------------------------------
  ## Internals
  ## --------------------------------------------------------------

  defp do_connect(ctx) do
    with {:ok, portal_token} <- fetch_secret(@secret_portal_token),
         {:ok, ibm_api_key} <- fetch_secret(@secret_ibm_api_key),
         {:ok, ibm_crn} <- fetch_secret(@secret_ibm_crn) do
      config = %Hardware.Config{
        portal_url: ctx.assigns.portal_base_url,
        portal_token: portal_token,
        ibm_api_key: ibm_api_key,
        ibm_crn: ibm_crn,
        ibm_region: ctx.assigns.ibm_region,
        # `Hardware.Config` requires :backend in @enforce_keys but Connect
        # runs BEFORE the user picks one. Use an empty string sentinel —
        # `Qx.Hardware.connect/2` validates only auth + lists backends; it
        # doesn't dispatch a job, so the empty backend is fine.
        backend: ctx.assigns.last_backend_name,
        optimization_level: ctx.assigns.optimization_level,
        shots: ctx.assigns.shots
      }

      Hardware.connect(config)
    end
  end

  defp fetch_secret(name) do
    case System.fetch_env(name) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error, {:missing_secret, name}}
    end
  end

  defp backend_known?(_ctx, ""), do: true

  defp backend_known?(%{assigns: %{backends_list: []}}, _name), do: false

  defp backend_known?(%{assigns: %{backends_list: list}}, name) when is_list(list) do
    Enum.any?(list, fn
      b when is_binary(b) -> b == name
      %{name: n} -> n == name
      _ -> false
    end)
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

  defp set_error(ctx, msg) do
    ctx
    |> assign(error: msg)
    |> tap(&broadcast_event(&1, "update", client_payload(&1)))
  end

  defp connect_error_message({:missing_secret, name}),
    do:
      "Missing Livebook secret #{name}. Define it under the notebook's Secrets " <>
        "panel and click Connect again."

  defp connect_error_message(:unauthorized),
    do: "Auth rejected (401). Check the values of LB_PORTAL_TOKEN, LB_IBM_API_KEY, LB_IBM_CRN."

  defp connect_error_message({:rate_limited, secs}) when is_integer(secs),
    do: "Rate limited. Try again in #{secs}s."

  defp connect_error_message({:network, _reason}),
    do: "Network error reaching the portal or IBM Cloud."

  defp connect_error_message(reason),
    do: "Connect failed: #{redact_reason(reason)}."

  # SSRF defence. A persisted `.livemd` carries `portal_base_url`; a
  # malicious shared notebook could otherwise redirect the bearer to
  # attacker infrastructure. We allow:
  #
  #   * `https://` + host in `@portal_host_allowlist` or ending in
  #     `.qxquantum.com` (covers `test.`, `www.`, future subdomains)
  #   * `http://localhost` and `http://127.0.0.1` for local development
  #
  # Returns the trimmed URL on success, `nil` on rejection.
  @doc false
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

  # Region allowlist predicate. `@doc false` + public so it is unit
  # testable without the live Kino runtime (same convention as
  # `validate_portal_url/1`); `handle_event/3` isn't drivable here.
  @doc false
  @spec valid_ibm_region?(any()) :: boolean()
  def valid_ibm_region?(region), do: region in @valid_regions

  defp portal_host_allowed?(host) do
    host in @portal_host_allowlist or
      String.ends_with?(host, @portal_https_required_suffix)
  end

  # Don't echo arbitrary HTTP bodies into the cell error UI — IBM IAM
  # 4xx bodies have echoed apikeys before, and Req exception messages
  # can carry full URLs (with credentials).
  defp redact_reason(:unauthorized), do: "unauthorized"
  defp redact_reason(:not_found), do: "not found"
  defp redact_reason({:rate_limited, secs}) when is_integer(secs), do: "rate limited (#{secs}s)"
  defp redact_reason({:http, status, _body}), do: "HTTP #{status}"
  defp redact_reason({:network, _reason}), do: "network failure"
  defp redact_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp redact_reason(_), do: "unexpected error"

  # Payload sent to the JS side. NEVER includes any token-shaped value
  # (the cell doesn't hold tokens anymore, so this is straightforward).
  defp client_payload(ctx) do
    %{
      portal_base_url: ctx.assigns.portal_base_url,
      ibm_region: ctx.assigns.ibm_region,
      last_backend_name: ctx.assigns.last_backend_name,
      optimization_level: ctx.assigns.optimization_level,
      shots: ctx.assigns.shots,
      backends_list: serialize_backends(ctx.assigns.backends_list),
      connected: ctx.assigns.connected,
      connecting: ctx.assigns.connecting,
      identity: ctx.assigns.identity,
      secret_names: %{
        portal_token: @secret_portal_token,
        ibm_api_key: @secret_ibm_api_key,
        ibm_crn: @secret_ibm_crn
      },
      error: ctx.assigns.error
    }
  end

  defp serialize_backends(list) do
    Enum.map(list, fn
      name when is_binary(name) -> %{name: name}
      %{name: _} = b -> Map.take(b, [:name, :status])
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  asset "main.js" do
    """
    export function init(ctx, payload) {
      ctx.importCSS("main.css");

      ctx.root.innerHTML = `
        <div class="qx-cell">
          <fieldset class="qx-section">
            <legend>Portal &amp; Region</legend>
            <div class="qx-row">
              <label>Portal URL</label>
              <input id="qx-portal-url" type="text" />
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
            <div class="qx-hint" id="qx-secret-hint">
              Connect reads Livebook secrets
              <code id="qx-secret-portal"></code>,
              <code id="qx-secret-key"></code>, and
              <code id="qx-secret-crn"></code>.
              Define them under the notebook's Secrets panel.
            </div>
          </fieldset>

          <fieldset class="qx-section qx-hidden" id="qx-job-section">
            <legend>Job defaults</legend>
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

        // Secret-name labels
        $("#qx-secret-portal").textContent = p.secret_names?.portal_token || "";
        $("#qx-secret-key").textContent = p.secret_names?.ibm_api_key || "";
        $("#qx-secret-crn").textContent = p.secret_names?.ibm_crn || "";

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
        if (p.connected && p.identity) {
          connEl.textContent = `✓ ${p.identity}`;
          connEl.className = "qx-ok";
          $("#qx-job-section").classList.remove("qx-hidden");
        } else if (p.connecting) {
          connEl.textContent = "connecting…";
          connEl.className = "qx-pending";
        } else {
          connEl.textContent = "";
          connEl.className = "";
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
      $("#qx-connect").addEventListener("click", () => ctx.pushEvent("connect", {}));

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
    .qx-row input[type="number"],
    .qx-row select {
      flex: 1;
      min-width: 0;
      padding: 6px 8px;
      border: 1px solid #cbd5e1;
      border-radius: 4px;
      font-size: 13px;
      font-family: inherit;
    }
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
    .qx-ok { color: #059669; font-size: 13px; }
    .qx-pending { color: #b45309; font-size: 13px; }
    .qx-bad { color: #b91c1c; font-size: 13px; }
    .qx-hint {
      color: #64748b;
      font-size: 12px;
      padding: 4px 0 0 118px;
      line-height: 1.5;
    }
    .qx-hint code {
      background: #f1f5f9;
      padding: 1px 4px;
      border-radius: 3px;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 11px;
    }
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
