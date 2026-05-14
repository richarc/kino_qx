# Plan: kino_qx Credentials Cell + `Kino.Qx.run!/2` pipeline (0.2.0)

**Slug**: `kino-qx-circuit-pipeline`
**Repo**: `/Users/richarc/Development/qxquantum/kino_qx` (downstream — qx ships first)
**Input**: `.claude/plans/kino-qx-circuit-pipeline/interview.md` (Status: COMPLETE)
**Research**: `.claude/plans/kino-qx-circuit-pipeline/research/codebase-scan.md` (already integrated)
**Created**: 2026-05-14
**Depth**: deep
**Branch (to create before `/phx:work`)**: `feat/credentials-cell`
**Target version**: `0.2.0` (mix.exs already at 0.2.0; legacy design never shipped — this becomes the actual 0.2.0)
**Supersedes**: `.claude/plans/kino-qx-transpile-cell/plan.md` (marked SUPERSEDED 2026-05-13)
**Upstream**: depends on `qx ~> 0.7` (upstream plan `../qx/.claude/plans/qx-hardware/plan.md` — already complete; verify Hex publish before §Phase 9)

## Summary

Replace the all-in-one `Kino.Qx.TranspileCell` with a credentials-only `Kino.Qx.CredentialsCell` that emits a `%Qx.Hardware.Config{}` struct, plus a new `Kino.Qx.run!/2,3` (and tuple-returning `Kino.Qx.run/2,3`) that wraps `Qx.Hardware.run/3` with a live-updating `Kino.Frame` status panel and a monitored-Task cancel pattern for Livebook interrupts. Delete the modules that moved upstream (`IbmClient`, `TranspilePipeline`, hardware-relevant slice of portal `Client`); thin the remaining portal client to snippet-only endpoints; rewrite the demo notebook.

End-state pipeline:

```elixir
circuit
|> Kino.Qx.run!(qx)
|> Qx.Draw.plot_counts(title: "Bell state")
```

## Goals & non-goals

**Goals**
- One Smart Cell (`Kino.Qx.CredentialsCell`) that emits a notebook-visible `%Qx.Hardware.Config{}` variable. Tokens transient (never persisted to `.livemd`).
- `Kino.Qx.run!/2,3` blocks until terminal status, returns `%Qx.SimulationResult{}`, raises on error; pipe-friendly into `Qx.Draw.plot_counts/2`.
- Live `Kino.Frame` status panel above the result (per web research idiom: `Kino.Frame.new() |> tap(&Kino.render/1)` then `Kino.Frame.render/2` on each `on_status` event).
- Livebook cell-interrupt cleanly cancels the in-flight IBM job via `Qx.Hardware.cancel/3` (monitored-Task pattern, NOT `trap_exit`).
- Existing snippet Smart Cell (`Kino.Qx.SmartCell`) keeps working — only the portal client it depends on is thinned.

**Non-goals**
- Async/Kino.Frame-only API (decision locked: sync block).
- Implicit registered-process credentials handoff (decision locked: explicit variable).
- Raw-QASM paste UI (delegated to `Qx.Hardware.submit_qasm/3` at the library layer for advanced users).
- Estimator primitive — Sampler only, same scope as legacy plan.
- Multi-circuit batches.
- 0.2.0 Hex publish until qx 0.7.0 is on Hex (§Phase 9 gated).

## Architecture

### Module map after this plan

| Module | State |
|---|---|
| `lib/kino/qx.ex` | Extended with `Kino.Qx.run/2,3` + `Kino.Qx.run!/2,3` (thin wrappers over `Qx.Hardware.run/3` and `run!/3` with `Kino.Frame` status callback) |
| `lib/kino/qx/application.ex` | Register `Kino.Qx.CredentialsCell` instead of `Kino.Qx.TranspileCell`; existing `Kino.Qx.SmartCell` registration unchanged |
| `lib/kino/qx/credentials_cell.ex` | **NEW** — Smart Cell. Fields: Portal URL · portal token · IBM API key · CRN · region · `[Connect]` → backend ▾ · optimization level ▾ · shots. `to_source/1` emits a single binding: `qx = %Qx.Hardware.Config{...}`. Connect uses `Qx.Hardware.connect/2` (returns updated `Config` carrying `:identity` + `:backends_list`). |
| `lib/kino/qx/transpile_cell.ex` | **DELETED** |
| `lib/kino/qx/smart_cell.ex` | Updated only where it calls portal client (snippet listing) — keeps existing UX |
| `lib/kino/qx/client.ex` | **THINNED** to `/me` + `/snippets` only — `/transpile` removed (now `Qx.Hardware.Portal.transpile/3`) |
| `lib/kino/qx/ibm_client.ex` | **DELETED** (moved to `Qx.Hardware.IBM` in qx) |
| `lib/kino/qx/transpile_pipeline.ex` | **DELETED** (moved to `Qx.Hardware` in qx) |
| `lib/kino/qx/run.ex` (or fold into `kino/qx.ex`) | **NEW** — implements `run/2,3` + `run!/2,3` with `Kino.Frame` status panel and monitored-Task cancel pattern |

### `Kino.Qx.run!/2,3` data flow

```text
caller cell process
  │
  ├── Kino.Frame.new() |> tap(&Kino.render/1)           [status panel rendered]
  │
  ├── parent = self()
  │   {:ok, task_pid} = Task.start_link(fn ->
  │     result = Qx.Hardware.run!(circuit, config,
  │       on_status: fn ev -> send(parent, {:status, ev}) end)
  │     send(parent, {:result, result})
  │   end)
  │   ref = Process.monitor(task_pid)
  │
  ├── receive loop (status events update frame; result returns; monitor catches interrupt)
  │     {:status, event}                 → Kino.Frame.render(frame, render_event(event))
  │     {:result, result}                → return result
  │     {:DOWN, ^ref, :process, _, reason} when reason in [:shutdown, :killed, …]
  │                                       → Qx.Hardware.cancel(job_id, config) best-effort
  │                                         re-raise as Kino.Qx.Interrupted
  │     {:DOWN, ^ref, :process, _, {error_struct, _stack}}
  │                                       → re-raise error_struct
  │
  └── frame stays as a record of what happened
```

`run/2,3` (non-bang) wraps the same flow but catches `Qx.Hardware.*Error` exceptions and returns `{:error, reason}`. Same `Kino.Frame` panel either way.

### Status event → Kino.Frame rendering

Per upstream `Qx.Hardware` (verified at `../qx/lib/qx/hardware.ex`):

| Event | Frame line |
|---|---|
| `{:portal, :connecting}` | `⏳ connecting to portal…` |
| `{:portal, :listing_backends}` | `⏳ listing backends…` |
| `{:ibm, :authenticating}` | `⏳ authenticating with IBM…` |
| `{:ibm, :fetching_backend}` | `⏳ fetching backend properties…` |
| `{:portal, :transpiling}` | `⏳ transpiling via qxportal…` |
| `{:ibm, :submitting}` | `⏳ submitting to IBM…` |
| `{:ibm, :job_started, job_id}` | `✔ submitted: <job_id>` |
| `{:ibm, :polling, %{status, queue_position, …}}` | `⏳ <status> (queue: <pos>, <elapsed>)` |
| `{:ibm, :fetching_results}` | `⏳ fetching results…` |
| terminal (return) | `✔ done in <elapsed>` |

Frame keeps the history of lines (not `:temporary`) so users can see the full trace.

## Iron Law compliance

| Iron Law (project convention) | Compliance | Notes |
|---|---|---|
| #7 — no `String.to_atom` on user input | inherited | All status-event atoms come from upstream `Qx.Hardware` (allowlisted there). Cell never coins atoms from HTTP payloads. |
| #8 — validate user input against allowlist | direct | Backend dropdown validates against `config.backends_list` (populated by Connect). Portal URL passes through `validate_portal_url/1` host allowlist (existing `transpile_cell.ex:484` carries over). Region uses upstream `@ibm_region_allowlist`. |
| #11 — library, no long-lived processes | direct | `application.ex` supervisor stays `[]`. The `Task.start_link` inside `run/2` is short-lived and linked to the calling cell process. No GenServer/Agent introduced. |
| Privacy invariant — tokens never persisted | direct | `to_attrs/1` strictly excludes `portal_token`, `ibm_api_key`, `ibm_crn`. Sentinel-string test gates from `transpile_cell_test.exs` carry forward into `credentials_cell_test.exs`. |

## Phases

### Phase 0 — Pre-flight (no code changes)

- [ ] **0.1** Branch from `main`: `git checkout -b feat/credentials-cell`.
- [ ] **0.2** Verify upstream qx state: `../qx/lib/qx/hardware.ex` exposes `run/3`, `run!/3`, `submit_qasm/3`, `transpile/3`, `list_backends/2`, `cancel/3`, `connect/2`; `../qx/lib/qx/hardware/config.ex` defines `%Config{}` with the 6 `@enforce_keys` we plan to bind from the cell.
- [ ] **0.3** Decide qx dep mode for development (see Open Questions #1). Recommended: path dep during impl, switch to `~> 0.7` at the §Phase 9 publish gate. Record the decision in `scratchpad.md`.
- [ ] **0.4** Read the upstream qx plan's Downstream handoff section (`../qx/.claude/plans/qx-hardware/plan.md`) and confirm no last-mile surface changes since interview was written.

### Phase 1 — Dependencies & deletions

- [ ] **1.1** `mix.exs`: add `{:qx, path: "../qx"}` (or `{:qx, "~> 0.7"}` if already on Hex per 0.3) to `deps/0`. Keep `:kino`, `:req`, `:jason`, `:bypass`, `:ex_doc`, `:credo` unchanged.
- [ ] **1.2** `mix deps.get && mix compile`. Expect compile errors from `lib/kino/qx/{ibm_client,transpile_pipeline,transpile_cell,client}.ex` referencing about-to-be-removed code — fine, we delete next.
- [ ] **1.3** Delete `lib/kino/qx/ibm_client.ex` (528 lines) and `test/kino/qx/ibm_client_test.exs` (455 lines).
- [ ] **1.4** Delete `lib/kino/qx/transpile_pipeline.ex` (174 lines) and `test/kino/qx/transpile_pipeline_test.exs` (300 lines).
- [ ] **1.5** Delete `test/support/stub_clients.ex` IBM-side stub (the Recorder Agent + Stub Ibm modules). Portal-side stub temporarily stays — re-evaluated in §Phase 4 once the new `run.ex` test surface is settled.
- [ ] **1.6** `mix compile` — expect remaining errors only inside `transpile_cell.ex` and `client.ex` callers. Capture the error list as a checklist for §Phase 2–3.

### Phase 2 — Thin `Kino.Qx.Client` to snippet-only

- [ ] **2.1** Open `lib/kino/qx/client.ex` (245 lines today). Identify the three call sites: `me/1`, `list_snippets/1`, `transpile/2`. Delete `transpile/2` (now `Qx.Hardware.Portal.transpile/3`).
- [ ] **2.2** Trim `lib/kino/qx/client.ex` module doc to reflect snippet-only scope. Keep `validate_portal_url/1` and base-url-building helpers (still needed for `/me`/`/snippets`).
- [ ] **2.3** **[test]** Delete `test/kino/qx/client_transpile_test.exs` (133 lines — covered by `qx/test/qx/hardware/portal_test.exs` upstream).
- [ ] **2.4** **[test]** Open `test/kino/qx/client_test.exs` (158 lines) and remove any cases that exercised `transpile/2`. Keep `me/1` and `list_snippets/1` cases. Run `mix test test/kino/qx/client_test.exs` — pass.
- [ ] **2.5** Audit `lib/kino/qx/smart_cell.ex` for any remaining references to `Kino.Qx.Client.transpile` — none expected (snippet cell never transpiled) but verify. Grep: `grep -rn "Kino.Qx.Client.transpile\|Client.transpile" lib/`.
- [ ] **2.6** `mix compile --warnings-as-errors`. Snippet cell should compile clean.

### Phase 3 — `Kino.Qx.CredentialsCell` (Smart Cell rewrite)

The existing `lib/kino/qx/transpile_cell.ex` (1001 lines) is **renamed and stripped**, not deleted-and-rewritten — its Connect flow, Portal URL allowlist, backend dropdown, optimization-level dropdown, region dropdown, and token-transient guards all survive. What is **removed**: QASM textarea, Save-with-notebook checkbox, Submit button, Cancel button, status row, error panel, polling Task lifecycle, `apply_pipeline_status/2`, `to_source/1` result-rendering, `last_counts`/`last_job_id`/`last_backend_name` persistence (the cell no longer "knows" about jobs).

- [ ] **3.1** Move `lib/kino/qx/transpile_cell.ex` → `lib/kino/qx/credentials_cell.ex`. Rename module `Kino.Qx.TranspileCell` → `Kino.Qx.CredentialsCell`. Update `@moduledoc`. Update smart-cell name attribute from `"Qx Transpile + Submit"` → `"Qx Credentials"` (verify with /phx:liveview-patterns conventions — this is the user-visible label in Livebook's smart-cell picker).
- [ ] **3.2 [smart_cell]** Strip UI fields from `init/2` assigns and `to_attrs/1` persistable keys:
  - **Remove from persistable keys**: `qasm_paste`, `save_qasm`, `last_job_id`, `last_counts`. (Backend selection, opt level, shots, portal_base_url, region — all stay.)
  - **Remove from transient assigns**: `current_status`, `current_status_detail`, `current_job_id`, `polling_task_pid`, `error`. (Connect-related transient stays.)
  - **Add to persistable + transient**: `shots` (was in legacy plan but verify it's already in `to_attrs/1`).
- [ ] **3.3 [smart_cell]** Strip handlers from `handle_event/3`: delete `"submit"`, `"cancel"`, `"update_qasm_paste"`, `"update_save_qasm"`. Keep `"connect"`, `"update_backend"`, `"update_optimization_level"`, `"update_portal_base_url"`, `"update_region"`, plus credential updaters. Add `"update_shots"` if not already present.
- [ ] **3.4 [smart_cell]** Strip `handle_info/2`: delete `{:status, _}`, `{:pipeline_result, _}`, `{:pipeline_error, _}`. Keep `{:connect_result, _}`.
- [ ] **3.5 [smart_cell]** Replace the Connect implementation. Currently it calls `IbmClient.iam_exchange/1` + `Client.me/1` + `IbmClient.list_backends/1` inline. Replace with a single `Qx.Hardware.connect/2` call (which performs portal `/me` + IBM IAM exchange + `list_backends` and returns `{:ok, %Config{}}` with `:identity`, `:backends_list`, `:access_token`, `:token_expires_at`, `:iam_url`, `:base_url` populated). Cell assigns now derive directly from this Config.
- [ ] **3.6 [smart_cell]** Rewrite `to_source/1` to emit a single binding:
  ```elixir
  qx = %Qx.Hardware.Config{
    portal_url: <portal_base_url>,
    portal_token: <portal_token>,        # transient
    ibm_api_key: <ibm_api_key>,          # transient
    ibm_crn: <ibm_crn>,                  # transient
    ibm_region: <ibm_region>,
    backend: <last_backend_name>,
    optimization_level: <optimization_level>,
    shots: <shots>
    # :identity, :backends_list, :access_token etc. intentionally not set
    # — Qx.Hardware.run/3 will lazy-connect on demand.
  }
  ```
  Decision: do NOT persist Connect-derived fields (`identity`, `backends_list`, `access_token`) into source. The cell uses them at config time (backend dropdown) but the emitted struct is fresh — run-time validates by calling `Qx.Hardware.connect/2` (or its lazy equivalent) if needed.
- [ ] **3.7 [smart_cell]** Rip out the bespoke VegaLite generation from the old `to_source/1` (legacy plan §4.9). The new cell never renders results — that's `Kino.Qx.run!/2`'s job.
- [ ] **3.8 [smart_cell]** Update the JS template (`assets/app.js` or inline `Kino.SmartCell.JS`): remove QASM textarea, Submit/Cancel buttons, status row, error panel, result panel. Add Shots number input. Keep Connect button, backend dropdown, optimization-level dropdown, region dropdown, identity row.
- [ ] **3.9** Update `lib/kino/qx/application.ex`: replace `Kino.SmartCell.register(Kino.Qx.TranspileCell)` with `Kino.SmartCell.register(Kino.Qx.CredentialsCell)`. Snippet-cell registration unchanged.
- [ ] **3.10 [test]** Move `test/kino/qx/transpile_cell_test.exs` (247 lines) → `test/kino/qx/credentials_cell_test.exs`. Carry forward:
  - All 4 token-leak sentinel-string assertions (portal_token, IBM API key, CRN, transient state).
  - `validate_portal_url/1` allowlist tests (default + planned host + arbitrary subdomain + localhost + trim + reject http public + reject homograph + reject 169.254 + reject file:/data:/javascript: + reject non-binary).
  - Persistable-key set check (UPDATED — exclude `qasm_paste`, `save_qasm`, `last_job_id`, `last_counts`; include `shots`).
  - `to_source/1` rendering tests (UPDATED — assert exactly the `%Qx.Hardware.Config{...}` binding shape, no DataTable, no VegaLite).
  - Connect-flow test (UPDATED — assert it delegates to `Qx.Hardware.connect/2`; stub via injected fn or use `Mox`-free stub module same as legacy plan).
  - Discard: `qasm_paste`-gated-by-`save_qasm` test, submit/cancel handlers (gone).
- [ ] **3.11** `mix compile --warnings-as-errors` clean. `mix test test/kino/qx/credentials_cell_test.exs` — all green.

### Phase 4 — `Kino.Qx.run/2,3` + `Kino.Qx.run!/2,3`

- [ ] **4.1** Create `lib/kino/qx/run.ex` defining `Kino.Qx.Run` (private impl module). `Kino.Qx.run/2,3` and `Kino.Qx.run!/2,3` are exposed as delegates from `lib/kino/qx.ex` for the canonical `Kino.Qx.run!` public name.
- [ ] **4.2** **Signatures**:
  ```elixir
  @spec run!(Qx.QuantumCircuit.t(), Qx.Hardware.Config.t(), keyword()) ::
          Qx.SimulationResult.t()
  def run!(circuit, %Qx.Hardware.Config{} = config, opts \\ [])

  @spec run(Qx.QuantumCircuit.t(), Qx.Hardware.Config.t(), keyword()) ::
          {:ok, Qx.SimulationResult.t()} | {:error, term()}
  def run(circuit, %Qx.Hardware.Config{} = config, opts \\ [])
  ```
  Opts forwarded to `Qx.Hardware.run/3`: `:shots`, `:on_status` (intercepted — see 4.3), plus any future Qx.Hardware opts.
- [ ] **4.3 [smart_cell]** Status-panel implementation:
  ```elixir
  frame = Kino.Frame.new() |> tap(&Kino.render/1)
  state = %{frame: frame, lines: [], started_at: System.monotonic_time(:millisecond)}
  on_status = fn event -> send(self(), {:status, event}) end
  ```
  Maintain `lines :: [iodata()]` so each `Kino.Frame.render/2` writes the cumulative history (not a single replacing line). Render via `Kino.Markdown.new(Enum.join(lines, "\n"))`. Caller-supplied `:on_status` is composed (chain through to caller and to our frame).
- [ ] **4.4 [smart_cell]** Monitored-Task pattern for cancel (per web research):
  ```elixir
  parent = self()
  {:ok, task_pid} =
    Task.start_link(fn ->
      try do
        result = Qx.Hardware.run!(circuit, config, Keyword.put(opts, :on_status, on_status))
        send(parent, {:run_ok, result})
      rescue
        e -> send(parent, {:run_error, e, __STACKTRACE__})
      end
    end)
  ref = Process.monitor(task_pid)
  receive_loop(state, ref, task_pid, current_job_id: nil)
  ```
  The receive loop tracks `current_job_id` (set when `{:ibm, :job_started, job_id}` arrives) so a `:DOWN` can cancel by ID.
- [ ] **4.5 [smart_cell]** Cancel handling. On `{:DOWN, ^ref, :process, _, reason}`:
  - If `reason == :normal` AND `{:run_ok, result}` was received: return result (run!) or `{:ok, result}` (run).
  - If `reason in [:shutdown, :killed]` (Livebook interrupt) AND `current_job_id != nil`: best-effort `Qx.Hardware.cancel(job_id, config)`, then raise `Kino.Qx.Interrupted` (new exception) for run!, or return `{:error, :interrupted}` for run.
  - If `{:run_error, e, stack}` was received: re-raise (run!) or return `{:error, e}` (run).
- [ ] **4.6** Define `Kino.Qx.Interrupted` exception in `lib/kino/qx/exceptions.ex` (or co-locate in `run.ex`). Message includes job ID if known.
- [ ] **4.7** Update `lib/kino/qx.ex`: add `defdelegate run!(circuit, config, opts \\ []), to: Kino.Qx.Run` and `defdelegate run(circuit, config, opts \\ []), to: Kino.Qx.Run`. Keep `version/0`.
- [ ] **4.8 [test]** New `test/kino/qx/run_test.exs`. Stub `Qx.Hardware` via a test-mode injection (or via `Mox`-free stub-module per the existing convention — see legacy `test/support/stub_clients.ex` portal half). Cases:
  - Happy-path: stub emits the full status sequence, returns a `%SimulationResult{}` — assert frame contains all expected lines, `run!/3` returns the result.
  - Tuple-return on error: `run/3` returns `{:error, _}` when stub raises.
  - Re-raise on error: `run!/3` propagates `Qx.Hardware.IbmError` (or whatever upstream raises).
  - Interrupt: simulate task `:shutdown` after `{:ibm, :job_started, _}` — assert `Qx.Hardware.cancel/3` was invoked with the correct job_id and that `Kino.Qx.Interrupted` is raised.
  - Caller `:on_status` is also invoked (composition test).
- [ ] **4.9** `mix compile --warnings-as-errors` + `mix test test/kino/qx/run_test.exs` — green.

### Phase 5 — Demo notebook

- [ ] **5.1** Rewrite `notebooks/transpile_demo.livemd` → `notebooks/hardware_demo.livemd`. New flow:
  1. Setup cell: `Mix.install([{:kino_qx, "~> 0.2"}, {:qx, "~> 0.7"}])`.
  2. Smart Cell (`Kino.Qx.CredentialsCell`) — user fills creds, clicks Connect, picks backend.
  3. Code cell:
     ```elixir
     circuit =
       Qx.create_circuit(2, 2)
       |> Qx.h(0) |> Qx.cx(0, 1)
       |> Qx.measure(0, 0) |> Qx.measure(1, 1)

     circuit
     |> Kino.Qx.run!(qx)
     |> Qx.Draw.plot_counts(title: "Bell state on real hardware")
     ```
  4. Brief markdown explaining that `qx` is the `%Qx.Hardware.Config{}` variable emitted by the Smart Cell above.
- [ ] **5.2** Delete old `notebooks/transpile_demo.livemd`.
- [ ] **5.3** Update README "Quick start" section to show the new pipeline.

### Phase 6 — Integration tests

- [ ] **6.1 [test]** Keep `test/test_helper.exs` excluding `:ibm_live` and `:portal_live` (already does — `test_helper.exs:8`).
- [ ] **6.2 [test]** Rewrite `test/kino/qx/integration/ibm_live_test.exs` to exercise `Kino.Qx.run!/2` end-to-end against a real IBM backend (gated additionally on `IBM_QUANTUM_SUBMIT=1` per legacy convention). Assertions: status frame contains terminal `:done` line; returned `%SimulationResult{}` has non-empty `:counts`.
- [ ] **6.3 [test]** `test/kino/qx/integration/portal_live_test.exs` continues to exercise the **snippet** portal endpoints (`/me`, `/snippets`) since `/transpile` lives upstream and is tested in qx. Trim transpile cases from this file.

### Phase 7 — Docs, CHANGELOG, version

- [ ] **7.1 [docs]** Update `README.md`: replace the legacy TranspileCell screenshot/walkthrough with the credentials-cell + pipeline walkthrough. Three sections to update: top blurb ("What is kino_qx?"), Quick start, Architecture diagram (if present).
- [ ] **7.2 [docs]** Update `CHANGELOG.md` for 0.2.0:
  - BREAKING: replaced `Kino.Qx.TranspileCell` ("Qx Transpile + Submit") with `Kino.Qx.CredentialsCell` ("Qx Credentials"); execution moved to `Kino.Qx.run!/2,3` + `Qx.Hardware.run/3` in qx.
  - BREAKING: minimum `:qx` version is `~> 0.7` (which retires `Qx.Remote`).
  - Added: `Kino.Qx.run/2,3` and `Kino.Qx.run!/2,3` with `Kino.Frame` live status.
  - Added: monitored-Task interrupt → `Qx.Hardware.cancel/3` best-effort cleanup.
  - Removed: in-cell QASM textarea, Submit button, polling Task, bespoke VegaLite result rendering (use `Qx.Draw.plot_counts/2`).
  - Migration note pointing at the demo notebook.
- [ ] **7.3 [docs]** New module `@moduledoc`s for `Kino.Qx.CredentialsCell`, `Kino.Qx.Run`, `Kino.Qx.Interrupted`. Refresh `Kino.Qx`'s top-level `@moduledoc` (stale references to "Phase 3 not yet implemented" — see codebase-scan §1).
- [ ] **7.4** `mix.exs`: confirm `@version "0.2.0"` (already set). Update `description/0` if needed. Update `package/0` `:links` if changed.

### Phase 8 — Local verification

- [ ] **8.1** `mix compile --warnings-as-errors` — clean.
- [ ] **8.2** `mix format --check-formatted` — clean.
- [ ] **8.3** `mix test` — all green; default exclusions `:ibm_live`/`:portal_live` honored. Expected new total: legacy 89 minus moved (22+13=35) minus deleted client_transpile (~10) minus old transpile_cell (~20) plus new credentials_cell (~20) plus run_test (~8) ≈ **~37–45 tests**.
- [ ] **8.4** `mix test --include portal_live` — **USER STEP** (needs `QXPORTAL_API_KEY`). Asserts thinned snippet client still works.
- [ ] **8.5** `mix test --include ibm_live` — **USER STEP** (needs `IBM_QUANTUM_API_KEY`, `IBM_QUANTUM_CRN`; full submit gated on `IBM_QUANTUM_SUBMIT=1`). Exercises `Kino.Qx.run!/2` end-to-end via qx.
- [ ] **8.6** `mix credo --strict` — address any new findings; style-only findings are acceptable per legacy plan precedent.
- [ ] **8.7** `mix dialyzer` — **USER STEP** (no PLT exists locally; first build ~5 min).
- [ ] **8.8** Manual smoke in Livebook — **USER STEP**. Open `notebooks/hardware_demo.livemd`, fill creds, click Connect, run the pipeline cell, confirm frame updates and `plot_counts` renders.

### Phase 9 — Release prep (gated on qx 0.7.0 on Hex)

- [ ] **9.1** Confirm `qx 0.7.0` is on Hex (`mix hex.info qx` or `https://hex.pm/packages/qx`).
- [ ] **9.2** Switch `mix.exs` dep from `{:qx, path: "../qx"}` to `{:qx, "~> 0.7"}`. `mix deps.unlock --all && mix deps.get`. Re-run §8.1–8.3.
- [ ] **9.3** Push branch; open PR via `/pr` (or manually). PR title: `feat: credentials cell + Kino.Qx.run! pipeline (0.2.0)`.
- [ ] **9.4** Post-merge: `mix hex.publish` — **USER STEP**.

## Files touched

**Added**
- `lib/kino/qx/credentials_cell.ex` (renamed from `transpile_cell.ex`; ~600 lines after stripping)
- `lib/kino/qx/run.ex` (~200 lines)
- `lib/kino/qx/exceptions.ex` (~30 lines — only `Kino.Qx.Interrupted`)
- `test/kino/qx/credentials_cell_test.exs` (renamed from `transpile_cell_test.exs`; ~200 lines)
- `test/kino/qx/run_test.exs` (~150 lines)
- `notebooks/hardware_demo.livemd`

**Deleted**
- `lib/kino/qx/ibm_client.ex` (moved upstream)
- `lib/kino/qx/transpile_pipeline.ex` (moved upstream)
- `lib/kino/qx/transpile_cell.ex` (renamed)
- `test/kino/qx/ibm_client_test.exs` (moved upstream)
- `test/kino/qx/transpile_pipeline_test.exs` (moved upstream)
- `test/kino/qx/client_transpile_test.exs` (moved upstream)
- `test/kino/qx/transpile_cell_test.exs` (renamed)
- `notebooks/transpile_demo.livemd`
- IBM-side bits of `test/support/stub_clients.ex`

**Modified**
- `lib/kino/qx.ex` (add `run/run!` delegates; refresh `@moduledoc`)
- `lib/kino/qx/application.ex` (re-register cell)
- `lib/kino/qx/client.ex` (drop `transpile/2`; snippet-only)
- `lib/kino/qx/smart_cell.ex` (verify no transpile refs)
- `test/kino/qx/client_test.exs` (drop transpile cases)
- `test/kino/qx/integration/ibm_live_test.exs` (rewrite around `Kino.Qx.run!/2`)
- `test/kino/qx/integration/portal_live_test.exs` (snippet-only)
- `mix.exs` (add `:qx` dep)
- `README.md`, `CHANGELOG.md`

## Risks & open questions

1. **qx dep mode during dev (path vs Hex)** — recommended path dep during impl, switch at §9.2. Record final choice in scratchpad.
2. **`Kino.Frame` updates from a Task** — web research confirms `Kino.render/1` works from the cell process; we need it to work when the Task sends events back to the parent cell process which then calls `Kino.Frame.render/2`. This is the validated pattern. Prototype in §4.3 if anything looks off.
3. **`Kino.SmartCell` JS template changes** — the existing JS likely lives inline in `transpile_cell.ex`. Stripping QASM textarea / Submit / status panel / result panel is mechanical but needs careful re-wiring of event names. Risk: JS-side field IDs drift from Elixir-side handler atoms. Mitigation: run §3.11 and manually exercise in Livebook.
4. **Snippet cell portal-client coupling** — `Kino.Qx.SmartCell` (snippet browser) uses the same `Client` module we're thinning. After §2 it should be unchanged externally, but verify with `mix test test/kino/qx/smart_cell_test.exs`.
5. **`@version "0.2.0"` is already in mix.exs** but the legacy design never published — confirm Hex shows no `0.2.0` for `kino_qx` before §9.4 to avoid a version-conflict surprise.
6. **`Kino.Qx.Interrupted` raising from inside a Task** — Livebook will display the exception in the cell's output. Confirm the UX matches expectations (clean message, no scary stacktrace dump on normal interrupt). May want `Process.exit(self(), {:shutdown, :interrupted})` rather than raising.

### Self-check (deep depth)

- **What could go wrong silently?** The biggest silent failure mode is a leaked IBM job: user interrupts the cell, our cancel call hits a transient network error, the job runs to completion and burns shots quietly. Mitigation: `Qx.Hardware.cancel/3` already retries on 5xx per upstream; we log on failure (Logger.warning) but don't surface to the user — fine for v0.2 but worth a follow-up.
- **What did I assume that I shouldn't have?** I assumed `Qx.Hardware.connect/2` returns a `Config` with backends populated. Verified at `../qx/lib/qx/hardware.ex:256` — `@spec connect(Config.t(), opts()) :: {:ok, Config.t()} | error()`. Good.
- **What's the riskiest task?** §4.4 (monitored-Task cancel) — interaction between Livebook's interrupt mechanism, our Task supervision, and IBM's cancel endpoint. Prototype this first if §Phase 4 stalls; write the test in §4.8 before the impl works as a forcing function.

## Verification gates

Run sequentially before each commit, all of these before §Phase 9:

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
```

User-driven gates before publish:

```bash
mix test --include portal_live      # needs QXPORTAL_API_KEY
mix test --include ibm_live         # needs IBM_QUANTUM_API_KEY + IBM_QUANTUM_CRN
mix dialyzer                        # ~5min first run
# Manual: open notebooks/hardware_demo.livemd in Livebook, run end-to-end
```

## References

- Interview: `.claude/plans/kino-qx-circuit-pipeline/interview.md` (decisions D1–D14)
- Codebase scan: `.claude/plans/kino-qx-circuit-pipeline/research/codebase-scan.md`
- Upstream plan: `../qx/.claude/plans/qx-hardware/plan.md` (complete)
- Superseded plan: `.claude/plans/kino-qx-transpile-cell/plan.md`
- Workspace policy: `../CLAUDE.md` §4 (cross-repo coordination — land upstream first, separate PRs)
