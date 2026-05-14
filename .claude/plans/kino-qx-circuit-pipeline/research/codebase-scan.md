# Codebase scan — kino_qx ↔ qx split refactor

Scope: identify what stays in `kino_qx`, what moves to `qx`, what is deleted,
and where the proposed `Qx.Hardware` API lands relative to the existing
`Qx.Remote`. Paths are absolute. Line numbers reference the state at scan
time.

## 1. `kino_qx/lib/` inventory

| Path | Disposition | Purpose |
|---|---|---|
| `/Users/richarc/Development/qxquantum/kino_qx/lib/kino/qx.ex` | **stays** | Top-level `Kino.Qx` module — `version/0` only; docstring still references "Phase 3 not yet implemented" (stale, harmless). |
| `/Users/richarc/Development/qxquantum/kino_qx/lib/kino/qx/application.ex` | **stays** | `Application.start/2`. Registers both smart cells; supervisor is empty (`[]`). No long-lived processes — correct per Iron Law #11 (library, host owns runtime). |
| `/Users/richarc/Development/qxquantum/kino_qx/lib/kino/qx/smart_cell.ex` | **stays** | "Qx Snippet" smart cell — portal snippet browser. Pure UI; calls `Kino.Qx.Client` for `/me`, `/snippets`. Unaffected by the split. |
| `/Users/richarc/Development/qxquantum/kino_qx/lib/kino/qx/transpile_cell.ex` | **stays** | "Qx Transpile + Submit" smart cell. UI + persistence + Task lifecycle. Will switch from direct `IbmClient`/`TranspilePipeline` calls to `Qx.Hardware.run/3` (single entry). |
| `/Users/richarc/Development/qxquantum/kino_qx/lib/kino/qx/client.ex` | **stays** (portal-only) | qxportal HTTP client — `/api/v1/me`, `/api/v1/snippets`, `/api/v1/transpile`. **Portal contract is kino_qx's concern**, not qx's — qx never talks to qxportal directly. |
| `/Users/richarc/Development/qxquantum/kino_qx/lib/kino/qx/ibm_client.ex` | **MOVES to qx** | IBM Quantum REST client — IAM exchange, list_backends, fetch_backend_configuration, submit_sampler, poll_job, fetch_results, cancel_job. This is hardware-vendor logic. Proposed new home: `/Users/richarc/Development/qxquantum/qx/lib/qx/hardware/ibm_client.ex` (or `qx/hardware/ibm.ex`). 528 lines; fully Bypass-tested. |
| `/Users/richarc/Development/qxquantum/kino_qx/lib/kino/qx/transpile_pipeline.ex` | **MOVES to qx** | Orchestrator: ibm.iam → ibm.fetch_backend_config → portal.transpile → ibm.submit → poll → fetch_results. Currently aliases both `Kino.Qx.Client` (portal) AND `Kino.Qx.IbmClient`. **Tension:** moving it to qx forces qx to depend on portal indirectly OR the pipeline needs a portal-client-shaped behaviour (likely a protocol/injection point — pipeline gets a `transpile_fn` lambda or `portal_client` module). |

Two test-support items also live in `kino_qx`:

- `/Users/richarc/Development/qxquantum/kino_qx/test/support/stub_clients.ex` — stubs for `IbmClient` and `Client` used by `TranspilePipelineTest`. Half moves to qx alongside the pipeline, half stays.

## 2. `qx/lib/qx/` inventory — relevant pieces

| Module | Disposition | Notes |
|---|---|---|
| `Qx.Remote` (`qx/lib/qx/remote.ex`) | **retired / renamed** to `Qx.Hardware` | Public surface today: `run/3`, `submit/3`, `await/3`, `status/3`, `cancel/3`, `list_backends/2`. Talks to **qx_server** (NOT IBM directly) via `/api/v1/jobs`, `/api/v1/backends`, `/api/v1/jobs/:id/results`. **This is the orphaned bit:** the new model is direct-to-IBM (via the moved-in `IbmClient`), so the qx_server detour disappears. |
| `Qx.Remote.Config` (`qx/lib/qx/remote/config.ex`) | **retired** | `%Config{url, api_key, timeout}` — qx_server-shaped. Replaced by IBM-shaped config (`%{api_key, crn, region, ...}`). |
| `Qx.Export.OpenQASM.to_qasm/2` (`qx/lib/qx/export/openqasm.ex:156`) | **stays in qx** | Signature: `to_qasm(%QuantumCircuit{}, options \\ [])`, `:version` default 3, `:include_comments` default false. Already used by `Qx.Remote.submit/3:77` — the new `Qx.Hardware` uses it the same way. |
| `Qx.Draw.plot_counts/2` (`qx/lib/qx/draw.ex:126`) | **stays in qx** | Signature: `plot_counts(result, options \\ [])`, options: `:format` (`:vega_lite` default, `:svg`), `:title`, `:width`, `:height`. Already documented to accept "both local simulation and `Qx.Remote` hardware results" (line 21) — once `Qx.Hardware.run!/3` returns a `Qx.SimulationResult`, the cell can call `Qx.Draw.plot_counts(result)` instead of generating its own VegaLite spec. |
| `Qx.SimulationResult` (`qx/lib/qx/simulation_result.ex`) | **stays in qx** | Struct: `%{probabilities, classical_bits, state, shots, counts}`, all `@enforce_keys`. Helpers: `most_frequent/1`, `filter_by_probability/2`, `outcomes/1`, `probability/2`, `to_map/1`. **This is what `Qx.Hardware.run!/3` must return.** |
| `Qx.ResultBuilder.from_counts/3` (`qx/lib/qx/result_builder.ex:40`) | **stays in qx** | `@spec from_counts(map(), pos_integer(), pos_integer()) :: Qx.SimulationResult.t()` — exactly the right shape for converting IBM's aggregated counts into a `SimulationResult`. Already used by `Qx.Remote:fetch_results:251`. |

## 3. Test files to move

Three kino_qx test files map cleanly onto qx once their target modules move:

| Current path | Proposed new path |
|---|---|
| `/Users/richarc/Development/qxquantum/kino_qx/test/kino/qx/ibm_client_test.exs` | `/Users/richarc/Development/qxquantum/qx/test/qx/hardware/ibm_client_test.exs` |
| `/Users/richarc/Development/qxquantum/kino_qx/test/kino/qx/transpile_pipeline_test.exs` | `/Users/richarc/Development/qxquantum/qx/test/qx/hardware/pipeline_test.exs` (or similar — depends on the new module name) |
| `/Users/richarc/Development/qxquantum/kino_qx/test/support/stub_clients.ex` | Split: IBM stub → `qx/test/support/`; portal stub stays in `kino_qx/test/support/` (pipeline test still needs to stub the portal-transpile injection point) |

Stays in kino_qx: `qx_test.exs`, `client_test.exs`, `transpile_cell_test.exs`,
`smart_cell_test.exs`, `client_transpile_test.exs`, both
`integration/*_live_test.exs`.

The existing `/Users/richarc/Development/qxquantum/qx/test/qx/remote_test.exs`
gets **deleted** along with `Qx.Remote` (or rewritten as the new
`Qx.Hardware` happy-path test). It uses `Plug.Conn` + `Req.Test.stub` — qx
already has `:plug, only: :test` in deps. Bypass is NOT in qx today.

## 4. `mix.exs` delta

### `qx/mix.exs` today (`/Users/richarc/Development/qxquantum/qx/mix.exs:40-57`)

Has: `nx`, `vega_lite`, `complex`, `nimble_parsec`, `req ~> 0.5`,
`usage_rules`, dev/test: `ex_doc`, `benchee`, `benchee_html`, `credo`,
`excoveralls`, `plug ~> 1.0` (only: :test).

**Missing for the move:** `bypass` (only: :test) — needed by the moved
`ibm_client_test.exs` and `pipeline_test.exs`. `jason` — needed by
`IbmClient.decode/1` at line 507-512 of `ibm_client.ex` (IBM serves results
without `content-type: application/json`, so Req's auto-decode is bypassed
and the client falls back to `Jason.decode/1`). Jason currently arrives in
qx transitively via Req/Plug; pin it explicitly in qx to match the same
defensive posture kino_qx's mix.exs comments call out.

### `kino_qx/mix.exs` today (`/Users/richarc/Development/qxquantum/kino_qx/mix.exs:33-47`)

Has: `kino ~> 0.19`, `req ~> 0.5`, `jason ~> 1.4`, dev/test: `bypass ~> 2.1`,
`ex_doc`, `credo`. Plus a new dep: `{:qx, ...}` (path during dev, hex in
release).

**Can drop after move** if and only if `Kino.Qx.Client` (the portal client)
is the sole remaining direct HTTP caller:

- `req` — STAYS. `client.ex` still uses `Req.new/Req.get/Req.post`
  (`client.ex:135-166`).
- `jason` — STAYS. Portal client uses `Jason` transitively but the explicit
  pin still applies for the same reason (defensive against Kino drift).
- `bypass` — STAYS in kino_qx test deps. `client_test.exs` and
  `client_transpile_test.exs` (and `integration/portal_live_test.exs`)
  continue to use Bypass against the portal API.

**Net:** kino_qx drops nothing from its mix.exs; qx **adds** `bypass`
(test) and **pins** `jason` explicitly.

### Cross-repo dep

`kino_qx/mix.exs` needs `{:qx, "~> 0.7"}` (or path during dev). qx must
publish a new minor (likely 0.7.0) introducing `Qx.Hardware` + dropping
`Qx.Remote`; per workspace policy
(`/Users/richarc/Development/qxquantum/CLAUDE.md` §4) that lands first,
then kino_qx bumps in a separate PR.

## 5. `Qx.Remote` vs proposed `Qx.Hardware` map

Proposal in the prompt: `run/3, run!/3, transpile/3, list_backends/1,
submit_qasm/3`.

| Proposed `Qx.Hardware.*` | Maps from | Notes |
|---|---|---|
| `run/3(circuit, config, opts)` | `Qx.Remote.run/3` (semantically) + the entire `Kino.Qx.TranspilePipeline.run/1` (mechanically) | Old `Qx.Remote.run` was qx_server-shaped: one HTTP POST. New `run/3` is the full IBM pipeline: IAM → fetch backend config → portal-transpile → IBM submit → poll → fetch results. `circuit` arg → calls `Qx.Export.OpenQASM.to_qasm/2` internally, then routes to `submit_qasm/3`. Return: `{:ok, %Qx.SimulationResult{}}` (the IBM counts go through `Qx.ResultBuilder.from_counts/3`). |
| `run!/3(circuit, config, opts)` | new bang variant | Raises on error. Critical for the cell because `TranspileCell.to_source/1` consumes `last_counts` from cell state, but if a notebook author writes a script-style cell `result = Qx.Hardware.run!(circuit, cfg, ...)` then `Qx.Draw.plot_counts(result)`, this is the friction-free path. |
| `transpile/3(qasm_or_circuit, config, opts)` | `Kino.Qx.Client.transpile/2` (`kino_qx/lib/kino/qx/client.ex:127`) | **Architectural question.** The qxportal contract belongs to kino_qx today. If `Qx.Hardware.transpile/3` is a public qx API, qx must call qxportal — which means qx becomes coupled to qxportal. Two options: (a) `transpile/3` is a thin wrapper that accepts a `portal_config` map and a target backend, qx owns the contract; or (b) `Qx.Hardware.run/3` accepts an injected `:transpile_fn` and `transpile/3` is NOT public on `Qx.Hardware` — kino_qx supplies the lambda. **Open decision for the plan.** |
| `list_backends/1(config)` | `Kino.Qx.IbmClient.list_backends/1` (`kino_qx/lib/kino/qx/ibm_client.ex:149`) | Direct mapping. Old `Qx.Remote.list_backends/2` queried qx_server `/api/v1/backends?provider=` and is **orphaned**. |
| `submit_qasm/3(qasm, config, opts)` | new — combines `Kino.Qx.IbmClient.submit_sampler/4` + `poll_job` + `fetch_results` | Lower-level entry: caller already has QASM (e.g. from the snippet cell or an external transpiler). Cell's main path goes through `run/3`; `submit_qasm/3` is the QASM-in entry point. |

**Orphaned from old `Qx.Remote` (deleted, not mapped):**

- `Qx.Remote.submit/3` — non-blocking submit. New design folds submit into
  `run/3`'s pipeline. If "fire and forget" is still wanted, the cell can
  use `submit_qasm/3` and skip the polling, but no separate non-blocking
  primitive is proposed.
- `Qx.Remote.await/3`, `Qx.Remote.status/3` — qx_server polling. Replaced
  by IBM's `poll_job` inside the pipeline; not exposed as public surface.
- `Qx.Remote.cancel/3` — qx_server cancel. **Needs a counterpart** —
  `Kino.Qx.IbmClient.cancel_job/2` (`ibm_client.ex:292`) is used by the
  cell on user-cancel (`transpile_cell.ex:265`). Should be public on
  `Qx.Hardware` as `cancel/2` or `cancel_job/2` — the prompt's proposed
  surface omits it but the cell needs it.
- `Qx.Remote.Config` — replaced by IBM-shaped config struct (new
  `Qx.Hardware.Config` or `Qx.Hardware.IbmConfig`).

## 6. `TranspileCell` persistable keys

From `to_attrs/1` at
`/Users/richarc/Development/qxquantum/kino_qx/lib/kino/qx/transpile_cell.ex:366-382`:

```
"portal_base_url"     # qxportal URL (host-allowlisted in validate_portal_url/1)
"ibm_region"          # "us-south" | "eu-de"
"last_backend_name"   # string from backends_list (validated on update)
"save_qasm"           # boolean, default false
"qasm_paste"          # "" unless save_qasm is true (gated, line 376)
"optimization_level"  # 0..3, default 1
"shots"               # 1..100_000, default 4096
"last_job_id"         # for display
"last_counts"         # to re-render after notebook reopen
```

Transient (assigns only, never persisted), per the `init/2` block at lines
103-115 and the module's "Privacy invariant" docstring (lines 12-23):

- `portal_token` (`qx_live_…`)
- `ibm_api_key`
- `ibm_crn`
- `backends_list`, `connected`, `identity`, `current_status`,
  `current_status_detail`, `current_job_id`, `polling_task_pid`, `error`

**Confirmed:** all three secrets (portal token, IBM API key, CRN) are
strictly transient. The privacy invariant survives the refactor as long as
`Qx.Hardware`'s API takes the credentials *by parameter* and never asks
the cell to persist them.

## 7. Cross-repo coupling

`grep -rn "Qxportal\|Kino" /Users/richarc/Development/qxquantum/qx/lib/`
finds **no references to `Qxportal` or `Kino.*` modules** in qx — only
incidental matches in docstrings ("Kino support", "LiveBook/Kino")
inside `qx/lib/qx/draw/tables.ex` (lines 8, 11, 34, 165, 167, 173, 177,
195, 197) and `qx/lib/qx/draw.ex:40`. `Qx.Draw.Tables` uses
`Code.ensure_loaded?(Kino)` + `apply(Kino.Markdown, :new, [...])` (lines
195-197, 165-167, 173-177) — **runtime-optional Kino integration**,
exactly the pattern `Qx.Hardware` should follow if it ever wants to emit
Kino output (it shouldn't — it should return a plain `%SimulationResult{}`
and let the cell or `Qx.Draw` handle rendering).

`qx_server` is mentioned in `Qx.Remote`'s docstrings only; no code
dependency. Removing `Qx.Remote` removes the last trace of qx_server from
qx.

## Plan-material findings

1. **`Qx.Remote` is fully orphaned by the new design** — qx_server is no
   longer in the loop. Delete `Qx.Remote`, `Qx.Remote.Config`, and
   `qx/test/qx/remote_test.exs`. Bump qx to a minor (0.7.0) — this is a
   breaking change for any qx_server-using caller, but kino_qx is the
   only known consumer.

2. **`Qx.Hardware.transpile/3` is the one architectural question** — qx
   has never talked to qxportal. Either qx owns the portal contract
   (couples qx → qxportal) or `Qx.Hardware.run/3` takes an injected
   transpile fn and kino_qx keeps owning `Kino.Qx.Client.transpile/2`.
   The injected-fn route is consistent with how `TranspilePipeline.run/1`
   already accepts `:portal_client` (`transpile_pipeline.ex:62`) for
   tests.

3. **Add `cancel/2` to the proposed surface.** The cell already calls
   `IbmClient.cancel_job/2` on user-cancel (`transpile_cell.ex:267`); a
   `Qx.Hardware.cancel/2` is the natural public name.

4. **qx needs `bypass` (test) and an explicit `jason` pin** when
   `IbmClient` moves over. Everything else qx needs is already present
   (`req ~> 0.5`, `plug ~> 1.0` test-only, `nx`, `vega_lite`).

5. **kino_qx drops nothing** — `req`, `jason`, `bypass` all stay because
   the portal client and its tests remain in kino_qx.

6. **`Qx.Draw.plot_counts/2` is already designed for hardware results.**
   The cell's bespoke VegaLite generation in `to_source/1` (lines
   401-438) can be replaced by `Qx.Draw.plot_counts(result)` once
   `Qx.Hardware.run!/3` returns a `%Qx.SimulationResult{}`.
