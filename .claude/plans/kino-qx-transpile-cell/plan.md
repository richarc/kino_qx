# Plan: kino_qx Transpile-and-Submit Smart Cell

> ## ⚠️ SUPERSEDED — 2026-05-13
>
> This plan is superseded by **`kino-qx-circuit-pipeline`**
> (`.claude/plans/kino-qx-circuit-pipeline/interview.md`).
>
> **Why**: the all-in-one TranspileCell (QASM textarea + Submit button + creds
> + render bundled in one Smart Cell) is being replaced by a credentials-only
> Smart Cell + a `Kino.Qx.run!/2` pipeline function. The transpile/submit/poll
> machinery moves to a new `Qx.Hardware` namespace in the `qx` library so
> non-Livebook callers (CLI / Phoenix / OTP) can use it without dragging Kino
> in. `Qx.Remote`/`qx_server` are retired in the same release.
>
> **What carries forward** (re-homed in qx): `IbmClient` (22 tests),
> `TranspilePipeline` (13 tests), hardware-relevant portion of portal `Client`,
> token-leak privacy invariant, `@known_statuses` allowlist, decision #6
> (no IBM sessions — direct POST /jobs).
>
> **What is dropped here**: Phase 7 (docs of legacy design) and Phase 8.4–8.8
> (publish 0.2.0 of legacy design). 0.2.0 ships from the new plan instead.
>
> File kept for history. Do not resume `/phx:work` on this plan.

**Slug**: `kino-qx-transpile-cell`
**Repo**: `/Users/richarc/Development/kino_qx` (NOT qxportal)
**Source**: feature description (no interview.md)
**Research**: `research/hex-libraries.md`, `research/ibm-quantum-api.md`
**Depth**: deep
**Created**: 2026-05-10
**Tracks beads**: `qxportal-p4n` (closes when 0.2.0 ships to Hex)

## Summary

Add a SECOND Smart Cell to `kino_qx` (alongside the existing snippet
injector) that takes an OpenQASM 3.0 circuit, asks **qxportal** to
transpile it for a chosen IBM Quantum backend, then submits the
transpiled circuit to **IBM Quantum** directly and renders the result
counts back into the notebook.

Privacy invariant: **qxportal never sees the IBM token**, IBM never
sees the portal token. Two independent HTTP clients, two independent
auth flows, both held in transient cell state.

Ships as `kino_qx 0.2.0` to Hex.

## Decisions locked in this plan

1. **Two cells in one library** — keep the existing `Kino.Qx.SmartCell`
   (snippet injector) unchanged; new cell registered under
   `Kino.Qx.TranspileCell`, name `"Qx Transpile + Submit"`. Same
   library, different concerns.
2. **qxportal client extension** — extend `Kino.Qx.Client` with
   `transpile/2` (POST) rather than create a second portal client.
   Keeps the atom allowlist (Iron Law #7), retry-after parser, and
   error tuple shapes in one place.
3. **IBM client = new module** `Kino.Qx.IbmClient` — wraps Req, no
   new hex deps (per hex-libraries.md). Covers IAM exchange + refresh,
   backend list, backend properties, session open/close, job submit,
   job poll, result fetch.
4. **Token policy** — IBM API key, Service-CRN, IBM region, and
   portal qx_live_… token are ALL transient. Never written into
   `to_attrs/1`, so the `.livemd` notebook file never persists them.
5. **Sampler only in v1** — Estimator results use base64 tensor
   encoding (see research/ibm-quantum-api.md gotcha #7). Sampler
   covers the "submit and get counts" use case. Estimator deferred.
6. **Sessions are OPTIONAL — we do NOT use them.** (Updated 2026-05-10.)
   The original research-doc claim that "direct /jobs POST has been
   deprecated since 2025-03-31" was incorrect. Verified against:
   (a) the production-proven `qx_server` reference at
   `/Users/richarc/Development/qx_server` which successfully runs jobs
   on real IBM hardware without sessions, and (b) IBM's current
   published spec at https://quantum.cloud.ibm.com/docs/api/qiskit-runtime-rest
   which treats sessions as optional. We submit `POST /jobs` directly.
   Cancel is `POST /jobs/{id}/cancel` (per current docs).
7. **Polling pattern** — `Task.start_link` from the cell process,
   1s/2s/4s backoff capped at 30s, hard timeout 24h (configurable).
   Cancelled on cell close or new submit.
8. **Result rendering** — Counts as a Kino-rendered table. Optional
   histogram via `Kino.VegaLite` if present (soft optional dep, not
   added to mix.exs — detect at runtime).
9. **Backend metadata** — fetch from
   `GET /v1/backends/{name}/properties`; pull `coupling_map` and
   `basis_gates` for the qxportal transpile payload. Cache per
   session.
10. **Portal default URL** — `https://test.qxquantum.com` until
    production cuts over to `www.qxquantum.com`. User can override via
    the cell UI.

## Out of scope (explicitly deferred)

- **Estimator primitive** — base64 tensor decoding deserves its own
  iteration.
- **Real-time queue position UI** — surface as text only in v1; a
  fancier progress bar can come later.
- **Multi-circuit batches** — `pubs` accepts an array but v1 submits
  one circuit per cell run.
- **IBM Quantum credit / cost surfacing** — no API for it today.
- **OpenQASM 2.0 support** — qxportal accepts 3.0 only; if user has
  2.0, they convert client-side first.
- **qx_sim native circuit input** — nice-to-have to accept a `Qx.Circuit`
  variable and call `Qx.export_qasm/1` for the user, but not v1. v1
  takes either a notebook variable holding a string OR a textarea
  paste.
- **Auto-refresh portal token** — qxportal tokens are long-lived and
  user-rotated; no refresh flow needed (different from IBM IAM).

## Risks (deep self-check)

1. **IBM API churn (HIGHEST)** — IBM has migrated APIs twice in two
   years (qiskit-ibm-provider → qiskit-ibm-runtime in 2023-24, then
   `/runtime/jobs` → sessions in 2025-03). A 2026 release could drop
   sessions entirely. Mitigation: integration tests tagged `:ibm` run
   against a real account locally; CI uses Bypass-stubbed responses.
   When IBM changes, only the IBM client module needs updating.
2. **IAM token refresh during long polling** — tokens are 1-hour TTL;
   queue waits routinely exceed that. Mitigation: every IbmClient
   call goes through `with_iam_refresh/2` that catches 401, refreshes,
   retries once. Refresh state held in cell ctx alongside the API key.
3. **Service-CRN UX confusion** — IBM splits identity between the API
   key (auth) and the Service-CRN (which instance). Users will paste
   one and forget the other. Mitigation: cell UI labels and a
   "Where do I find these?" link to the IBM Quantum dashboard.
4. **Sampler PUB format quirk** — `pubs` is a list of pairs even for a
   single circuit. Forgetting the wrapping list 400s the request.
   Mitigation: the IbmClient.submit_sampler/3 helper does the
   wrapping; the cell never builds the PUB shape directly.
5. **Iron Law #7 (atom exhaustion)** — IBM's job state values
   (`INITIALIZING`, `QUEUED`, `RUNNING`, `DONE`, `CANCELLED`, `ERROR`)
   come from the wire. Cell must NOT `String.to_atom/1` these — pattern
   match against allowlist or keep as binaries throughout.
6. **Iron Law #10 (no process without runtime reason)** — the polling
   Task IS a runtime resource (a long-lived HTTP loop). Documented in
   moduledoc. The cell already has `Kino.JS.Live` (a process per cell
   instance) — that's the supervisor.
7. **Iron Law #8 (authorize every event)** — Smart Cell `handle_event`
   clauses must validate input shape (non-empty tokens, valid backend
   name from list) before calling out. Important because Smart Cell
   events are user input.
8. **Region lock** — Service-CRN encodes region; requests must hit
   the matching base URL. v1 supports `us-south` and `eu-de` via a
   dropdown.

## Three self-check questions

- **What's most likely to break in production?** IBM API drift. The
  next IBM migration could land mid-week and silently break the cell.
  Mitigation: integration tests against real IBM (locally) before
  every Hex publish; tight feedback loop on user error reports.
- **Hardest decision still floating?** Whether to surface
  `resilience_level` (0..3) in the v1 UI. Each level has trade-offs
  (1 = balanced, 3 = expensive). Decision: ship with `resilience_level: 1`
  hardcoded; add the slider in v2.
- **What would I want to know one month after launch?** Job
  submission success rate; average queue + run time per backend; how
  many cells fail at IBM-auth vs portal-transpile vs job-error.
  Telemetry: emit `[:kino_qx, :transpile, ...]` events the user's
  Livebook can consume with Telemetry.attach if they care; no
  telemetry is shipped to the portal (privacy).

---

## Phase 0 — Pre-work (no code)

- [x] **0.1** Verify the user has an IBM Quantum API key + Service-CRN — user confirmed separately; this is a user-only step.
- [x] **0.2** Confirm `kino` major version on Hex — `mix hex.info kino` reports 0.19.0 latest; existing `~> 0.19` pin is fine, no Smart Cell API churn.
- [x] **0.3** Bumped `@version` in `mix.exs` from `"0.1.0"` to `"0.2.0"`. Description updated to reflect both Smart Cells. CHANGELOG entry written.

## Phase 1 — Portal client extension (low-risk, well-defined)

The portal `/api/v1/transpile` contract is locked (qxportal
`priv/static/api/v1.md`). Add a single POST helper to the existing
client.

- [x] **1.1 [client]** Added private `post/3` mirroring `get/2`; refactored response handling into a shared `handle_response/2` head with verb-aware POST-only clauses (422/502/503/504). `receive_timeout: 30_000` for POST since transpile is slower than reads.
- [x] **1.2 [client]** Added public `transpile/2` POSTing to `/api/v1/transpile` with full error atom map per contract.
- [x] **1.3 [client]** `@known_keys` extended with `:qasm`, `:metadata`, `:depth`, `:size`, `:num_qubits`. Also fixed `atomize/1` to recurse into nested map values (was flat-only) — required for nested `metadata`. Existing flat-response endpoints unaffected.
- [x] **1.4 [test]** Wrote `test/kino/qx/client_transpile_test.exs` using **Bypass** (matches existing `client_test.exs` convention; plan said `Req.Test` but Bypass is the established pattern). 9 cases: 200 happy + auth header + body assertion, 401, 422, 429+retry-after, 502, 503, 504, fall-through 418, network down. All pass; existing 9 tests still pass.

## Phase 2 — IBM Quantum client (HIGH risk)

Brand new module. Mirror `Kino.Qx.Client`'s shape (config map,
typespecs, atom-only error tuples) for consistency.

- [x] **2.1** Created `lib/kino/qx/ibm_client.ex`. Config type adds `:iam_url` and `:base_url` as optional override hooks for test stubbing (Bypass needs both since IAM is a separate origin from the API).
- [x] **2.2** `iam_exchange/1` POSTs form-encoded grant; 200 → merges `:access_token` + `:token_expires_at` into config; 400/401 → `:unauthorized`.
- [x] **2.3** `list_backends/1` tolerates `devices`, `backends`, or bare-list response wrappers; pulls `:name` (from `name` or `backend_name`), `:status`, `:num_qubits`.
- [x] **2.4** `fetch_backend_properties/2` returns `%{coupling_map, basis_gates, num_qubits}`.
- [x] **2.5** `open_session/3` with `max_ttl \\ 3600`, sends `mode: "dedicated"`.
- [x] **2.6** `submit_sampler/4` builds the `pubs: [[qasm, nil]]` wrapping internally; sets `program_id: "sampler"`, `version: 2`, and `resilience_level: 1` (per plan v1 decision).
- [x] **2.7** `poll_job/2` matches `state.status` against `@known_statuses` (~w(INITIALIZING QUEUED RUNNING DONE CANCELLED ERROR)). Unknown values surface as `{:error, {:unknown_status, raw}}` — Iron Law #7. Returns `%{status: binary, reason, queue_position}`.
- [x] **2.8** `fetch_results/2` returns `%{counts, metadata}` for Sampler shape; `data: [%{counts: ...}]` extracted from list. Estimator shape (data without `counts` key) → `{:error, :unsupported_result}`.
- [x] **2.9** `close_session/2` — `:ok` on 204 or 404 (best-effort).
- [x] **2.10** `with_iam_refresh/2` wraps every authed call. On 401: re-runs `iam_exchange/1`, calls fun again with refreshed config, returns result. Refreshed config does not escape (caller's copy may go stale; next 401 will refresh again).
- [x] **2.11** `base_url_for/1` (public so tests can assert): `:us_south` → `quantum.cloud.ibm.com/api/v1`, `:eu_de` → `eu-de.quantum.cloud.ibm.com/api/v1`. Config `:base_url` overrides.
- [x] **2.12 [test]** `test/kino/qx/ibm_client_test.exs` — Bypass-stubbed (consistent with `client_test.exs`). 22 cases covering all functions, all 6 known statuses round-trip, unknown status surfaces loudly, 401-refresh-retry flow exercises both Bypasses. All pass.

## Phase 3 — Submission orchestrator

The glue between Phase 1 (portal transpile) and Phase 2 (IBM submit).
Lives outside the cell so it's testable without Kino.

- [x] **3.1** Created `lib/kino/qx/transpile_pipeline.ex`. Sequence implemented via `with` chain; each stage wrapped by a `stage/2` helper that maps `{:error, reason}` to `{:error, stage_atom, reason}`. Polling uses monotonic-clock deadline + 1s/2s/4s/... backoff capped at 30s. close_session is best-effort (errors swallowed). Module-injection points (`:ibm_client`, `:portal_client`, `:sleep`) avoid pulling in Mox.
      ```elixir
      run(%{
        portal_config:  Kino.Qx.Client.config(),
        ibm_config:     Kino.Qx.IbmClient.config(),
        qasm:           String.t(),
        backend:        String.t(),
        optimization_level: 0..3,
        seed_transpiler: integer() | nil,
        on_status:      (status -> any())     # callback for UI updates
      }) :: {:ok, %{counts, transpiled_qasm, metadata, job_id}} | {:error, stage, reason}
      ```
      Sequence:
      1. `on_status.({:ibm, :authenticating})` → `IbmClient.iam_exchange/1`
      2. `on_status.({:ibm, :fetching_backend})` → `IbmClient.fetch_backend_properties/2`
      3. `on_status.({:portal, :transpiling})` → `Client.transpile/2`
         with the QASM + coupling_map + basis_gates + optimization_level
      4. `on_status.({:ibm, :opening_session})` → `IbmClient.open_session/3`
      5. `on_status.({:ibm, :submitting})` → `IbmClient.submit_sampler/4`
      6. Loop: `IbmClient.poll_job/2` with backoff (1s, 2s, 4s, …,
         capped at 30s); call `on_status.({:ibm, status, queue_position})`
         on each transition. Terminate on `"DONE"` / `"ERROR"` / `"CANCELLED"`.
      7. `on_status.({:ibm, :fetching_results})` → `IbmClient.fetch_results/2`
      8. `IbmClient.close_session/2` (best-effort)
      9. Return `{:ok, %{...}}` to caller.

      Error returns: `{:error, :ibm_auth, reason}`, `{:error, :portal_transpile, reason}`,
      `{:error, :ibm_submit, reason}`, `{:error, :ibm_polling_timeout, reason}`,
      `{:error, :ibm_job_failed, reason}`. Stage is critical for UI.
- [x] **3.2 [test]** `test/kino/qx/transpile_pipeline_test.exs` — 13 cases. Built `test/support/stub_clients.ex` with Recorder Agent + Stub modules (Ibm, Portal) since Mox isn't a dep. Tests cover happy-path full sequence + call ORDER, payload threading (transpile gets coupling_map/basis_gates, submit gets transpiled qasm), error routing for every stage atom, ERROR/CANCELLED terminal status, network polling failure, optional on_status callback, and on_status emission across all polls.

## Phase 4 — Smart Cell

Mirror the existing `Kino.Qx.SmartCell` structure: persisted vs
transient assigns, `to_attrs/1` excludes secrets, JS asset for the UI.

- [x] **4.1 [smart_cell]** Created `lib/kino/qx/transpile_cell.ex` and registered the new cell in `lib/kino/qx/application.ex` (B-1 fix from review — was missed in initial pass).
- [x] **4.2** Persisted attrs implemented: `portal_base_url`, `ibm_region`, `last_backend_name`, `qasm_paste` (gated by `save_qasm` boolean), `save_qasm`, `optimization_level`, `last_job_id`, `last_counts`. **DEFERRED**: `qasm_var_name` (notebook-variable binding) — paste mode only in v1; tracked in Open follow-ups.
- [x] **4.3** Transient assigns: `portal_token`, `ibm_api_key`, `ibm_crn`, `backends_list`, `connected`, `identity`, `current_session_id`, `current_status`, `current_status_detail`, `current_job_id`, `polling_task_pid`, `error`. NB: `ibm_access_token`/`ibm_token_expires_at` are NOT separately tracked — the IBM config is rebuilt from credential assigns and IAM exchange is re-run per submit (token-never-persisted invariant intact; refresh hops are cheap).
- [x] **4.4 [smart_cell]** UI fields implemented: Portal URL (validated against allowlist), Portal token (password), IBM API key (password), Service-CRN (text), Region dropdown, Connect button, Backend dropdown, Optimization-level dropdown 0..3, QASM textarea + "Save with notebook" checkbox (default OFF), Submit + Cancel buttons, status row, error panel. **DEFERRED**: "from variable" radio + CRN "?" help link + dedicated result panel (results render in notebook output cell). Tracked in Open follow-ups.
- [x] **4.5 [smart_cell] [iron-law #8]** Every `handle_event` validates: token non-empty, region in `@valid_regions`, optimization_level integer 0..3, backend_name in cached `backends_list` (B-4 review fix: pre-connect `backends_list` empty → only empty backend name accepted), portal URL matches `@portal_host_allowlist` or `*.qxquantum.com` (W-2 review fix). Errors surface via `set_error/2`, never raise.
- [x] **4.6 [smart_cell]** `handle_event("connect")`: `Task.start_link` running IAM exchange + `Client.me/1` + `IbmClient.list_backends/1`. Cell process now `Process.flag(:trap_exit, true)` so a Task crash surfaces an error rather than silently killing the cell (B-2 review fix).
- [x] **4.7 [smart_cell]** `handle_event("submit")`: `Task.start_link` running `TranspilePipeline.run/1` with `on_status: &send(self(), {:status, &1})`. Status events drive `apply_pipeline_status/2` which broadcasts UI updates.
- [x] **4.8 [smart_cell]** `handle_event("cancel")`: `Process.exit(task, :kill)` AND best-effort `IbmClient.close_session/2` from a fresh Task (B-3 review fix — initial impl missed close_session). Pipeline now emits `{:ibm, :session_opened, session_id}` event so the cell knows the session id; cell stores it in `current_session_id`. Cleared on done/error/cancel.
- [x] **4.9 [smart_cell]** `to_source/1` emits Elixir code that builds `Kino.DataTable.new` of counts (sorted desc) with optional `Kino.VegaLite` histogram (Phase 5.1 + 5.2 folded in here).
- [x] **4.10 [smart_cell]** `to_attrs/1` excludes every transient assign. **TODO**: token-leak introspection test deferred to Phase 6.2 (`transpile_cell_test.exs`).

## Phase 5 — Result rendering

- [x] **5.1** Counts → `Kino.DataTable.new/2` with `:bitstring` + `:count` columns, sorted desc. Emitted by `to_source/1` in TranspileCell.
- [x] **5.2** Optional `Kino.VegaLite` histogram via `Code.ensure_loaded?` runtime check. Soft optional — no mix.exs change.
- [ ] **5.3** Job metadata in a `Kino.Markdown` block — UNMET in initial impl (review finding). Job ID is in the comment + DataTable name only; queue_wait_ms / execution_time_ms not surfaced. **Deferred to Phase 7 (docs/release polish)** since metadata also appears in the cell's `last_job_id` UI status; this is presentation polish.

## Phase 6 — Tests

- [x] **6.1 [test]** `test/test_helper.exs` now excludes `:ibm_live` and `:portal_live` by default. Run-locally instructions in the file header.
- [x] **6.2 [test]** `test/kino/qx/transpile_cell_test.exs` — 20 cases. Token-leak guards for portal_token, IBM API key, IBM CRN, session/task transient state (4 sentinel-string assertions). qasm_paste gating by save_qasm. Persistable key set check. to_source rendering (placeholder, full DataTable + VegaLite, sorted desc, missing job_id). validate_portal_url (default + planned host + arbitrary subdomain + localhost + trim + reject http public + reject homograph + reject 169.254 metadata + reject file://data:javascript: schemes + reject non-binary). **Followed snippet_cell_test.exs convention** (fake ctx map + direct calls). handle_event/3 not driven directly — needs the live Kino runtime; that surface gets exercised via `:portal_live` / `:ibm_live` once those run.
- [x] **6.3 [test]** `test/kino/qx/integration/ibm_live_test.exs` tagged `:ibm_live` — IAM exchange happy path, list_backends, fetch_backend_properties on the first available backend. Full submit path is gated on a SECOND env var `IBM_QUANTUM_SUBMIT=1` so credentials alone don't trigger shot charges. 5-minute poll cap.
- [x] **6.4 [test]** `test/kino/qx/integration/portal_live_test.exs` tagged `:portal_live` — `/api/v1/me` + `/api/v1/transpile` with a Bell pair against `https://test.qxquantum.com` (override via `QXPORTAL_BASE_URL`). Skips when `QXPORTAL_API_KEY` is unset.

**Default `mix test` after Phase 6:** 1 doctest, 89 tests, 0 failures, 6 excluded.

## Phase 7 — Docs + release

- [ ] **7.1 [docs]** Update `README.md` with the new cell: screenshot
      placeholder, the three credentials needed, the privacy
      invariant ("portal never sees IBM tokens").
- [ ] **7.2 [docs]** Update `CHANGELOG.md` for 0.2.0:
      - **Added**: `Kino.Qx.TranspileCell` Smart Cell submitting to IBM Quantum
      - **Added**: `Kino.Qx.IbmClient` (IAM auth + sessions + Sampler jobs)
      - **Added**: `Kino.Qx.Client.transpile/2` for qxportal `/api/v1/transpile`
- [ ] **7.3 [docs]** New module `@moduledoc`s for the four new
      modules (`Client.transpile`, `IbmClient`, `TranspilePipeline`,
      `TranspileCell`). Cite the privacy invariant + Iron Law
      compliance in `IbmClient` and `TranspileCell`.
- [ ] **7.4 [docs]** Demo notebook at
      `notebooks/transpile_demo.livemd` showing the full flow
      (analogous to the existing `qx_smart_cell_demo.livemd` for the
      snippet cell).
- [ ] **7.5** `mix.exs`: bump `@version "0.1.0"` → `"0.2.0"`. Confirm
      `package` block + `description` still accurate; update
      description if "and submit to IBM Quantum" needs adding.
- [ ] **7.6** `mix hex.publish` (manual step, post-verification).

## Phase 8 — Verification

- [x] **8.1** `mix compile --warnings-as-errors` — clean.
- [x] **8.2** `mix format --check-formatted` — clean.
- [x] **8.3** `mix test` — 1 doctest, 89 tests, 0 failures, 6 excluded (`:ibm_live`, `:portal_live`).
- [ ] **8.4** `mix test --include portal_live` — **USER STEP** (needs `QXPORTAL_API_KEY`).
- [ ] **8.5** `mix test --include ibm_live` — **USER STEP** (needs `IBM_QUANTUM_API_KEY`, `IBM_QUANTUM_CRN`; full submit gated additionally on `IBM_QUANTUM_SUBMIT=1`).
- [x] **8.6** `mix credo --strict` — 3 refactoring + 4 design notes, all style. None correctness. New `length/1` warning fixed.
- [ ] **8.7** `mix dialyzer` — **USER STEP** (no PLT exists locally; first build is ~5 min). Run `mix dialyzer --plt` once, then `mix dialyzer`.
- [ ] **8.8** Manual end-to-end smoke — **USER STEP**. THIS is the gate before `mix hex.publish`.

Also verified `mix hex.build` produces a valid `kino_qx-0.2.0.tar` containing the expected files (no test/, no notebooks/, no .claude/). `mix docs` builds clean (one pre-existing warning re: hidden `Kino.Qx.Application` reference in CHANGELOG; unrelated to this change).

## Verification commands

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```

## File map

```
lib/kino/qx/client.ex                       (edit — add transpile/2 + post/3)
lib/kino/qx/ibm_client.ex                   (NEW — Phase 2)
lib/kino/qx/transpile_pipeline.ex           (NEW — Phase 3)
lib/kino/qx/transpile_cell.ex               (NEW — Phase 4)
lib/kino/qx/application.ex                  (edit — register new cell)
notebooks/transpile_demo.livemd             (NEW — Phase 7.4)
test/kino_qx/client_transpile_test.exs      (NEW — Phase 1.4)
test/kino_qx/ibm_client_test.exs            (NEW — Phase 2.12)
test/kino_qx/transpile_pipeline_test.exs    (NEW — Phase 3.2)
test/kino_qx/transpile_cell_test.exs        (NEW — Phase 6.2)
test/kino_qx/integration/portal_live_test.exs  (NEW — Phase 6.4, tagged)
test/kino_qx/integration/ibm_live_test.exs    (NEW — Phase 6.3, tagged)
test/test_helper.exs                        (edit — add tag exclusions)
mix.exs                                     (edit — version 0.2.0; description)
README.md                                   (edit — Phase 7.1)
CHANGELOG.md                                (edit — Phase 7.2)
```

## Iron Law spot-check

- **#4 (no float for money)** — N/A.
- **#5 (pin values with `^`)** — N/A (no Ecto).
- **#7 (no `String.to_atom` on user input)** — IBM job statuses come
  off the wire as binaries; pattern-match against allowlist
  (`"DONE"`, `"QUEUED"`, etc.). Same for portal error codes (already
  mapped via the `@known_keys` allowlist in `Kino.Qx.Client`).
  **Phase 2.7 + 4.5 + 4.10 explicitly verify.**
- **#8 (authorize every handle_event)** — Smart Cell user input
  validated in every clause; **Phase 4.5 task explicitly enforces.**
- **#9 (no `raw/1`)** — N/A (no HTML rendering of user input; all UI
  is pre-built JS).
- **#10 (no process without runtime reason)** — Polling Task owns a
  long-lived HTTP loop; documented in `TranspileCell` moduledoc.
  Cell process itself is `Kino.JS.Live`'s — already justified by
  Kino.

## Test plan summary

| Test file | Type | Tag | Run by default? |
|-----------|------|-----|-----|
| `client_transpile_test.exs` | unit (Req stubs) | none | yes |
| `ibm_client_test.exs` | unit (Req stubs) | none | yes |
| `transpile_pipeline_test.exs` | unit (Mox both clients) | none | yes |
| `transpile_cell_test.exs` | smart-cell integration | none | yes |
| `integration/portal_live_test.exs` | real qxportal | `:portal_live` | no — local only |
| `integration/ibm_live_test.exs` | real IBM Quantum | `:ibm_live` | no — local only |

## Open follow-ups (not in this plan)

- **0.3.0**: Estimator support (base64 tensor decoding).
- **0.3.0**: `qx_sim` `Qx.Circuit` direct input (no manual export).
- **Telemetry**: emit `[:kino_qx, :transpile, :start | :stop | :error]`
  for users with their own dashboards.
- **Resilience-level slider**: ship in v2 once we know what users
  actually want.
- **Multi-circuit batches**: `pubs` array support, requires UI for
  multiple QASM sources.
- **Jupyter / IPython parity** notebook export: nice-to-have,
  not blocking.
