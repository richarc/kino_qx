defmodule Kino.Qx.SmartCell do
  @moduledoc """
  Livebook Smart Cell that browses a user's Qx Portal snippets and
  injects the chosen one's source into the notebook.

  Registered automatically when `:kino_qx` is loaded — no setup beyond
  `Mix.install([{:kino_qx, "~> 0.1"}])` is required.

  ## Security invariant

  The API token lives ONLY in the cell's transient state. It is never
  written to `to_attrs/1`, which means it is never persisted into the
  `.livemd` file. Sharing a notebook does NOT leak the token.

  Persisted across notebook reopens:

    * `base_url`        — portal URL (default `https://qxportal.dev`)
    * `snippet_name`    — display name of the most recently selected snippet
    * `source_kind`     — `"qasm"` or `"elixir"`
    * `source`          — the chosen snippet's body (so the notebook is
                          self-contained on next open, no token needed)

  The token is required only to browse the snippet list and refresh
  the body of the selected snippet.
  """
  use Kino.JS
  use Kino.JS.Live
  use Kino.SmartCell, name: "Qx Snippet"

  alias Kino.Qx.Client

  @default_base_url "https://qxportal.dev"

  @impl true
  def init(attrs, ctx) do
    ctx =
      assign(ctx,
        # Persisted (also seeded into to_attrs)
        base_url: attrs["base_url"] || @default_base_url,
        snippet_name: attrs["snippet_name"] || "",
        source_kind: attrs["source_kind"] || "qasm",
        source: attrs["source"] || "",
        # Transient (NEVER in to_attrs)
        token: "",
        status: "disconnected",
        identity: nil,
        snippets: [],
        selected_id: attrs["selected_id"],
        error: nil
      )

    {:ok, ctx}
  end

  @impl true
  def handle_connect(ctx) do
    {:ok, client_payload(ctx), ctx}
  end

  @impl true
  def handle_event("update_token", %{"value" => token}, ctx) do
    {:noreply, assign(ctx, token: token)}
  end

  def handle_event("update_base_url", %{"value" => base_url}, ctx) do
    ctx = assign(ctx, base_url: base_url)
    broadcast_event(ctx, "update", client_payload(ctx))
    {:noreply, ctx}
  end

  def handle_event("update_source_kind", %{"value" => kind}, ctx)
      when kind in ["qasm", "elixir"] do
    ctx = assign(ctx, source_kind: kind) |> reapply_source()
    broadcast_event(ctx, "update", client_payload(ctx))
    {:noreply, ctx}
  end

  def handle_event("connect", _params, ctx) do
    config = %{token: ctx.assigns.token, base_url: ctx.assigns.base_url}

    case Client.me(config) do
      {:ok, identity} ->
        case Client.list_snippets(config) do
          {:ok, snippets} ->
            ctx =
              assign(ctx,
                status: "connected",
                identity: identity,
                snippets: Enum.map(snippets, &Map.take(&1, [:id, :name, :visibility])),
                error: nil
              )

            broadcast_event(ctx, "update", client_payload(ctx))
            {:noreply, ctx}

          {:error, reason} ->
            {:noreply, set_error(ctx, reason)}
        end

      {:error, reason} ->
        {:noreply, set_error(ctx, reason)}
    end
  end

  def handle_event("select_snippet", %{"id" => id}, ctx) do
    config = %{token: ctx.assigns.token, base_url: ctx.assigns.base_url}

    case Client.get_snippet(config, id) do
      {:ok, snippet} ->
        ctx =
          assign(ctx,
            selected_id: snippet.id,
            snippet_name: snippet.name,
            # Persist BOTH bodies; source_kind picks which one gets emitted
            qasm_content: snippet.qasm_content,
            elixir_content: snippet.elixir_content
          )
          |> reapply_source()

        broadcast_event(ctx, "update", client_payload(ctx))
        {:noreply, ctx}

      {:error, reason} ->
        {:noreply, set_error(ctx, reason)}
    end
  end

  @impl true
  def to_attrs(ctx) do
    # CRITICAL: token must NEVER appear here. Persisted attrs end up in
    # the .livemd file and travel with shared notebooks.
    %{
      "base_url" => ctx.assigns.base_url,
      "snippet_name" => ctx.assigns.snippet_name,
      "source_kind" => ctx.assigns.source_kind,
      "source" => ctx.assigns.source,
      "selected_id" => ctx.assigns.selected_id
    }
  end

  @impl true
  def to_source(attrs) do
    case Map.get(attrs, "source") do
      nil -> ""
      "" -> "# No snippet selected. Use the Qx Snippet cell above to pick one."
      source -> wrap_source(source, attrs["source_kind"], attrs["snippet_name"])
    end
  end

  ## Helpers

  defp wrap_source(source, "elixir", _name), do: source

  defp wrap_source(source, "qasm", name) do
    label = if is_binary(name) and name != "", do: name, else: "snippet"

    """
    # OpenQASM source from "#{label}" — Qx Portal
    qasm = \"\"\"
    #{source}\"\"\"
    """
  end

  defp wrap_source(source, _, _), do: source

  defp reapply_source(ctx) do
    body =
      case ctx.assigns.source_kind do
        "elixir" -> ctx.assigns[:elixir_content] || ctx.assigns.source
        _ -> ctx.assigns[:qasm_content] || ctx.assigns.source
      end

    assign(ctx, source: body || "")
  end

  defp set_error(ctx, reason) do
    msg = error_message(reason)

    ctx
    |> assign(status: "error", error: msg)
    |> tap(fn ctx -> broadcast_event(ctx, "update", client_payload(ctx)) end)
  end

  defp error_message(:unauthorized),
    do: "Token rejected (401). Check your qx_live_* key, or generate a new one in the dashboard."

  defp error_message(:not_found), do: "Snippet not found (404). It may have been deleted."

  defp error_message({:rate_limited, secs}) when is_integer(secs),
    do: "Rate limited (429). Try again in #{secs}s."

  defp error_message({:rate_limited, _}), do: "Rate limited (429). Try again shortly."

  defp error_message({:network, reason}),
    do: "Network error: #{inspect(reason)}. Check the portal URL is reachable."

  defp error_message({:http, status, _body}), do: "Unexpected HTTP #{status} from the portal."

  defp error_message(other), do: "Unexpected error: #{inspect(other)}"

  # Payload sent to the client. Token is NOT included — the JS side
  # holds it locally only when the user types it into the textbox.
  defp client_payload(ctx) do
    %{
      base_url: ctx.assigns.base_url,
      status: ctx.assigns.status,
      identity: ctx.assigns.identity,
      snippets: ctx.assigns.snippets,
      selected_id: ctx.assigns.selected_id,
      snippet_name: ctx.assigns.snippet_name,
      source_kind: ctx.assigns.source_kind,
      error: ctx.assigns.error
    }
  end

  asset "main.js" do
    """
    export function init(ctx, payload) {
      ctx.importCSS("main.css");

      ctx.root.innerHTML = `
        <div class="qx-cell">
          <div class="qx-row">
            <label>Token</label>
            <input id="qx-token" type="password" placeholder="qx_live_..." autocomplete="off" />
          </div>
          <div class="qx-row">
            <label>Portal URL</label>
            <input id="qx-base-url" type="text" />
          </div>
          <div class="qx-row qx-actions">
            <button id="qx-connect">Connect</button>
            <span id="qx-status"></span>
          </div>
          <div id="qx-connected" class="qx-hidden">
            <div class="qx-row">
              <label>Snippet</label>
              <select id="qx-snippet">
                <option value="">— pick one —</option>
              </select>
            </div>
            <div class="qx-row">
              <label>Source</label>
              <select id="qx-kind">
                <option value="qasm">OpenQASM</option>
                <option value="elixir">Elixir</option>
              </select>
            </div>
          </div>
          <div id="qx-error" class="qx-error qx-hidden"></div>
        </div>
      `;

      const tokenInput = ctx.root.querySelector("#qx-token");
      const baseUrlInput = ctx.root.querySelector("#qx-base-url");
      const connectBtn = ctx.root.querySelector("#qx-connect");
      const statusEl = ctx.root.querySelector("#qx-status");
      const connectedSection = ctx.root.querySelector("#qx-connected");
      const snippetSelect = ctx.root.querySelector("#qx-snippet");
      const kindSelect = ctx.root.querySelector("#qx-kind");
      const errorEl = ctx.root.querySelector("#qx-error");

      // ---- Hydrate from server payload ----------------------------
      function applyPayload(p) {
        baseUrlInput.value = p.base_url || "";
        kindSelect.value = p.source_kind || "qasm";

        // Rebuild snippet dropdown
        snippetSelect.innerHTML = '<option value="">— pick one —</option>';
        (p.snippets || []).forEach(s => {
          const opt = document.createElement("option");
          opt.value = s.id;
          opt.textContent = `${s.name} (${s.visibility})`;
          if (p.selected_id && String(p.selected_id) === String(s.id)) {
            opt.selected = true;
          }
          snippetSelect.appendChild(opt);
        });

        // If we have a name but no in-list selection (e.g. notebook
        // reopened without auth), show it disabled so the user knows
        // the cell remembers their last choice.
        if (p.snippet_name && (!p.snippets || p.snippets.length === 0)) {
          const opt = document.createElement("option");
          opt.value = "__remembered__";
          opt.textContent = `${p.snippet_name} (saved — connect to refresh)`;
          opt.selected = true;
          opt.disabled = true;
          snippetSelect.appendChild(opt);
        }

        // Status
        if (p.status === "connected" && p.identity) {
          statusEl.textContent = `✓ ${p.identity.email} (${p.identity.role})`;
          statusEl.className = "qx-ok";
          connectedSection.classList.remove("qx-hidden");
        } else if (p.status === "error") {
          statusEl.textContent = "";
          connectedSection.classList.add("qx-hidden");
        } else {
          statusEl.textContent = "";
          connectedSection.classList.add("qx-hidden");
        }

        // Error
        if (p.error) {
          errorEl.textContent = p.error;
          errorEl.classList.remove("qx-hidden");
        } else {
          errorEl.textContent = "";
          errorEl.classList.add("qx-hidden");
        }
      }
      applyPayload(payload);

      // ---- User → server ------------------------------------------
      // Token: typed locally; pushed only when the user explicitly clicks Connect.
      tokenInput.addEventListener("input", e => {
        ctx.pushEvent("update_token", { value: e.target.value });
      });
      baseUrlInput.addEventListener("change", e => {
        ctx.pushEvent("update_base_url", { value: e.target.value });
      });
      connectBtn.addEventListener("click", () => {
        ctx.pushEvent("connect", {});
      });
      snippetSelect.addEventListener("change", e => {
        if (e.target.value && e.target.value !== "__remembered__") {
          ctx.pushEvent("select_snippet", { id: e.target.value });
        }
      });
      kindSelect.addEventListener("change", e => {
        ctx.pushEvent("update_source_kind", { value: e.target.value });
      });

      // ---- Server → user ------------------------------------------
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
      gap: 8px;
    }
    .qx-row {
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .qx-row label {
      width: 96px;
      flex-shrink: 0;
      color: #64748b;
      font-weight: 500;
    }
    .qx-row input,
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
