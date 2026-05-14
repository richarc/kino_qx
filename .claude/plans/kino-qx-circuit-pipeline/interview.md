# Interview: Circuit Pipeline + Qx.Hardware Split

**Slug**: `kino-qx-circuit-pipeline`
**Created**: 2026-05-13
**Status**: Interview complete; ready for `/phx:plan`
**Spans repos**: `qx/` (upstream — ships first) and `kino_qx/` (downstream)
**Supersedes**: `kino-qx-transpile-cell` (the IBM/portal/pipeline code carries forward into qx; the cell UI is reworked)

## Summary

Redesign kino_qx so the canonical Livebook flow is:

```elixir
circuit
|> Kino.Qx.run!(qx)
|> Qx.Draw.plot_counts(title: "Bell state")
```

Where `qx` is a `%Qx.Hardware.Config{}` struct emitted by a credentials Smart Cell. The transpile/submit/poll/result-build machinery moves out of kino_qx into a new `Qx.Hardware` namespace in the `qx` library, so non-Livebook callers (CLI, Phoenix, OTP) can run circuits on real hardware without dragging Kino in.

## Coverage

What 2/2 · Why 2/2 · Scope 2/2 · Where 2/2 · How 2/2 · Edge 2/2 — **12/12 sufficient**

## Locked decisions

### Architecture

1. **Hardware-execution core lives in `qx` under `Qx.Hardware`.** kino_qx becomes a thin UX layer. `Qx.Remote` (qx_server-based) is **fully deleted** in the same qx release — only known consumer was kino_qx, which is being rewritten anyway. No `@deprecated` cycle.

2. **qxportal HTTP client moves to qx** as `Qx.Hardware.Portal`. qx owns the hardware-relevant portion of the `/api/v1` contract (`/me`, `/transpile`). The snippet-browsing portion stays in `kino_qx/lib/kino/qx/client.ex` (a thinned-down portal client serving only `Kino.Qx.SmartCell`).

3. **`Qx.Hardware` public surface**:
   - `run/3(circuit, config, opts) :: {:ok, %Qx.SimulationResult{}} | {:error, term}` — full pipeline, blocks until terminal status
   - `run!/3(circuit, config, opts) :: %Qx.SimulationResult{}` — raises on error; pipe-friendly
   - `transpile/3(qasm_or_circuit, config, opts) :: {:ok, transpiled_qasm} | {:error, term}` — portal transpile only
   - `list_backends/1(config) :: {:ok, [backend_meta]} | {:error, term}` — IBM only
   - `submit_qasm/3(qasm, config, opts) :: {:ok, %Qx.SimulationResult{}} | {:error, term}` — skip the circuit→QASM step (advanced)
   - `cancel/2(job_id, config) :: :ok | {:error, term}` — IBM `POST /jobs/:id/cancel`

4. **`%Qx.Hardware.Config{}` fields** (all required unless noted):
   ```
   portal_url            : String.t()      # default "https://test.qxquantum.com"
   portal_token          : String.t()      # qx_live_...  (transient in cell)
   ibm_api_key           : String.t()      # transient in cell
   ibm_crn               : String.t()      # transient in cell
   ibm_region            : String.t()      # "us-south" | "eu-de"
   backend               : String.t()      # validated against backends_list
   optimization_level    : 0..3            # default 1
   shots                 : pos_integer()   # default 4096
   # transient / cached, not @enforce_keys:
   identity              : String.t() | nil   # set after Connect
   backends_list         : [backend_meta]     # cached after Connect
   ```

### API behaviour

5. **Sync block.** `run/3` blocks until job reaches a terminal status (DONE / CANCELLED / ERROR). IBM queue waits can be seconds to hours; that's expected. Caller's pipe continues into `Qx.Draw.plot_counts/1` naturally.

6. **Input shape**: `Qx.Hardware.run!/2` accepts `%Qx.QuantumCircuit{}` only (calls `Qx.Export.OpenQASM.to_qasm/2` internally). Hand-authored QASM goes through `submit_qasm/3`.

7. **Return type**: `{:ok, %Qx.SimulationResult{}}` (built via existing `Qx.ResultBuilder.from_counts/3`). Bang version returns bare struct or raises (`File.read`/`File.read!` convention).

8. **Pre-flight validation** (run-time, raise on failure):
   - **No measurements** → `Qx.Hardware.NoMeasurementsError` with actionable message ("Add `Qx.measure(circuit, qubit, classical_bit)`").
   - **Pre-Connect Config** (no `identity`, empty `backends_list`) → lazy connect (inline IAM exchange + `list_backends`), validate `backend ∈ backends_list`, then proceed. If lazy connect fails → `Qx.Hardware.ConfigError`.
   - **Bad shots/optimization_level/etc.** → `ArgumentError` at struct construction (use `Qx.Hardware.Config.new!/1` for validated construction).

9. **Status callback contract** (carries forward from existing `TranspilePipeline`):
   - `{:portal, :transpiling}` / `{:portal, :transpiled}`
   - `{:ibm, :authenticating}` / `{:ibm, :authenticated, identity}`
   - `{:ibm, :fetching_backend}` / `{:ibm, :backend_fetched, %{name, basis_gates, coupling_map}}`
   - `{:ibm, :submitting}` / `{:ibm, :submitted, job_id}`
   - `{:ibm, :poll, %{status, queue_position, elapsed_ms}}`
   - `{:ibm, :fetching_results}` / `{:ibm, :done, result}`
   - On any error: `{:error, stage_atom, reason}`
   - All allowlisted (Iron Law #7): no `String.to_atom` on response bodies.

### Cancellation

10. **Monitored-Task pattern, NOT `trap_exit`** (per web research, validated against Kino docs). `Kino.Qx.run!/2` spawns the actual polling under a Task linked to the cell process; the cell process `Process.monitor`s the Task. On Livebook cell interrupt the cell process gets `:shutdown`; before propagating, the monitor catches, calls `Qx.Hardware.cancel/2` best-effort, then re-raises. Same logic surfaces in `Qx.Hardware.run/3` for non-Livebook callers via an internal helper — they can wrap their own monitor.

### Kino UX layer

11. **`Kino.Qx.CredentialsCell`** (renamed from `TranspileCell`):
    - UI: Portal URL · Portal token (password) · IBM API key (password) · CRN (text) · Region (dropdown) · `[Connect]` · Backend (dropdown, post-Connect) · Optimization level (dropdown 0..3) · Shots (number input)
    - Removes: QASM textarea, "Save with notebook" checkbox, Submit button, Cancel button, status row, error panel, result-rendering generator
    - Persistable to `.livemd`: `portal_base_url`, `ibm_region`, `last_backend_name`, `optimization_level`, `shots` (plus existing `last_job_id`, `last_counts` for historical display — TBD in plan whether to keep)
    - Transient: `portal_token`, `ibm_api_key`, `ibm_crn`, `backends_list`, `identity`, `connected`
    - `to_source/1` emits a single line: `qx = %Qx.Hardware.Config{...transient creds + persisted prefs...}`

12. **`Kino.Qx.run!/2`** (new module `Kino.Qx.Run`, function `Kino.Qx.run!/2,3`):
    - At entry: `frame = Kino.Frame.new() |> tap(&Kino.render/1)`
    - Spawns monitored Task running `Qx.Hardware.run!/3` with `on_status: fn event -> send(self(), {:status, event}) end`
    - Receive loop translates status events to `Kino.Frame.render(frame, …)` updates (✔ / ⏳ icons, queue position, elapsed)
    - On Task exit `:normal` → returns result; pipe continues into `Qx.Draw.plot_counts/1`
    - On Task exit `:shutdown` or any abnormal → calls `Qx.Hardware.cancel/2` best-effort, re-raises original error
    - Also expose `Kino.Qx.run/2,3` (non-bang) for users who want tuples

### Demo / docs

13. **Demo notebook** rewritten around the new pipeline. Lives in `kino_qx/notebooks/` (or `priv/`). Worked example: Bell pair → run on IBM → `plot_counts`.

## Move map (from research/codebase-scan.md)

### Moves: kino_qx → qx (under `Qx.Hardware`)

| From (kino_qx) | To (qx) |
|---|---|
| `lib/kino/qx/ibm_client.ex` (528 lines) | `lib/qx/hardware/ibm.ex` |
| `lib/kino/qx/transpile_pipeline.ex` | absorbed into `lib/qx/hardware.ex` |
| `lib/kino/qx/client.ex` (hardware-relevant /me + /transpile parts) | `lib/qx/hardware/portal.ex` |
| `test/kino/qx/ibm_client_test.exs` (22 tests) | `test/qx/hardware/ibm_test.exs` |
| `test/kino/qx/transpile_pipeline_test.exs` (13 tests) | `test/qx/hardware_test.exs` |
| `test/kino/qx/client_transpile_test.exs` | `test/qx/hardware/portal_test.exs` |
| `test/support/stub_clients.ex` (IBM portion) | `qx/test/support/` |

### Stays in kino_qx (reworked)

| Module | What changes |
|---|---|
| `lib/kino/qx.ex` | Add `Kino.Qx.run/2,3` and `Kino.Qx.run!/2,3` |
| `lib/kino/qx/transpile_cell.ex` | Rename → `credentials_cell.ex`; strip QASM textarea, Submit/Cancel buttons, polling Task, result rendering; keep Connect flow, Portal URL allowlist, token-transient guards |
| `lib/kino/qx/smart_cell.ex` | Existing snippet cell — untouched |
| `lib/kino/qx/client.ex` | Thinned to snippet endpoints only (`/me`, `/snippets`) — used by `smart_cell.ex` |
| `lib/kino/qx/application.ex` | Register new `CredentialsCell`; deregister old `TranspileCell` |
| `test/kino/qx/transpile_cell_test.exs` (20 tests) | Rewritten as `credentials_cell_test.exs` |
| `test/kino/qx/client_test.exs` | Trimmed to snippet endpoints only |
| `test/kino/qx/integration/*_live_test.exs` | Keep both; `portal_live_test.exs` continues to test the snippet-side portal contract |

### Deletes (qx)

- `lib/qx/remote.ex`, `lib/qx/remote/config.ex`, `test/qx/remote_test.exs` — qx_server retired

### mix.exs delta

- **qx**: add `{:bypass, "~> 2.1", only: :test}`, explicit pin `{:jason, "~> 1.4"}`
- **kino_qx**: add `{:qx, "~> 0.7"}`; drop nothing (req/jason/bypass still needed for snippet client + its tests)

## Example end state

```elixir
# Cell 1 — Kino.Qx.CredentialsCell (Smart Cell)
# UI: Portal URL | portal token | IBM API key | CRN | region | [Connect]
#     → Backend ▾ | Optimization level ▾ | Shots
# Emits:
qx = %Qx.Hardware.Config{
  portal_url: "https://test.qxquantum.com",
  portal_token: "qx_live_...",        # transient
  ibm_api_key: "...",                 # transient
  ibm_crn: "crn:v1:...",              # transient
  ibm_region: "us-east",
  backend: "ibm_brisbane",
  optimization_level: 1,
  shots: 4096,
  identity: "alice@org",              # post-Connect
  backends_list: [...]                # post-Connect
}

# Cell 2 — regular Elixir
circuit =
  Qx.create_circuit(2, 2)
  |> Qx.h(0) |> Qx.cx(0, 1)
  |> Qx.measure(0, 0) |> Qx.measure(1, 1)

circuit
|> Kino.Qx.run!(qx)
|> Qx.Draw.plot_counts(title: "Bell state")

# Cell 3 — works just as well outside Livebook
{:ok, result} = Qx.Hardware.run(circuit, qx)
```

## Release plan

**Order**: qx ships first (workspace rule #4 — land upstream first, separate PRs).

1. **qx 0.6.x → 0.7.0** (breaking minor — Qx.Remote deleted, pre-1.0):
   - Adds `Qx.Hardware.*` + `Qx.Hardware.Config`
   - Deletes `Qx.Remote`, `Qx.Remote.Config`, `test/qx/remote_test.exs`
   - Adds `:bypass` (test), pins `:jason` explicitly
   - CHANGELOG: BREAKING — see migration notes
   - `mix hex.publish`

2. **kino_qx 0.1.x → 0.2.0** (breaking; never published 0.2.0 of the legacy design — clean slate):
   - Bumps `{:qx, "~> 0.7"}`
   - Removes `Kino.Qx.IbmClient`, `Kino.Qx.TranspilePipeline`, and the hardware portion of `Kino.Qx.Client`
   - Renames `Kino.Qx.TranspileCell` → `Kino.Qx.CredentialsCell` (strips QASM/Submit/render)
   - Adds `Kino.Qx.run/2,3` and `Kino.Qx.run!/2,3` (with `Kino.Frame` status panel + monitored-Task cancel)
   - New demo notebook
   - CHANGELOG: BREAKING — single architecture, canonical hardware path
   - `mix hex.publish`

## Two-plan handoff

This interview drives **two separate `/phx:plan` runs**:

1. **`cd ../qx && /phx:plan ../kino_qx/.claude/plans/kino-qx-circuit-pipeline/interview.md`** — produces `qx/.claude/plans/qx-hardware/plan.md`. Scope: Qx.Hardware build-out + Qx.Remote delete + release 0.7.0.

2. **`/phx:plan .claude/plans/kino-qx-circuit-pipeline/interview.md`** (here in kino_qx) — produces `kino_qx/.claude/plans/kino-qx-circuit-pipeline/plan.md`. Scope: credentials cell rebuild + `Kino.Qx.run!/2` + demo notebook + release 0.2.0. **Blocked on qx 0.7.0 hex publish** before final verify/publish gates.

## References

- Research: `.claude/plans/kino-qx-circuit-pipeline/research/codebase-scan.md` (205 lines — module-level move map, mix.exs delta, persistable-keys audit)
- Research: web-researcher inline summary (in this session's history) — kino_explorer/kino_vega_lite pattern, Kino.Frame idiom, monitored-Task cleanup pattern, Ecto deprecation precedent
- Superseded plan: `.claude/plans/kino-qx-transpile-cell/plan.md` (marked SUPERSEDED at top)
- Workspace policy: `/Users/richarc/Development/qxquantum/CLAUDE.md` §4 (cross-repo coordination)
