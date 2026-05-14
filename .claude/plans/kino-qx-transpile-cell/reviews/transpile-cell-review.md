# Review — kino_qx 0.2.0 TranspileCell (Phases 1–5)

**Verdict: REQUIRES CHANGES**

Triggered by:
- Requirements: 1 UNMET + 1 critical PARTIAL (cell never registered in Application — won't appear in Livebook).
- Code review: 2 BLOCKERs (Task.start_link supervision; pre-connect backend validation bypass).
- Test review: 1 BLOCKER (`:ibm_results` error stage untested).

Counts across 6 agents: **5 BLOCKER · 7 WARNING · 8 SUGGESTION** + verification clean (compile/format/61 tests all green; credo 6 style nits).

---

## Requirements Coverage

**Source:** Plan `.claude/plans/kino-qx-transpile-cell/plan.md`. Phases 1–5: **24 MET · 7 PARTIAL · 1 UNMET**. Phases 6/7/8 not yet attempted.

### UNMET
- **5.3** — `to_source/1` emits no `Kino.Markdown` block for job metadata (queue_wait_ms, execution_time_ms). Job ID only in comment + table name.

### PARTIAL — blocking
- **4.1 / D10 — TranspileCell NEVER registered in Application.** `lib/kino/qx/application.ex:7` only registers `Kino.Qx.SmartCell`. **The new cell will not appear in Livebook's "+ Smart" menu. Ship-blocker.**
- **4.8** — `handle_event("cancel")` kills the Task but never calls `IbmClient.close_session/2`. Session leaks until `max_ttl` (3600s).
- **4.4 / 4.2** — "From variable" QASM radio (notebook-variable binding) not implemented; paste mode only. `qasm_var_name` attr missing from `to_attrs/1`.

### PARTIAL — minor
- **1.4** test count off by one (8 vs claimed 9; coverage equivalent).
- **4.3** — `ibm_access_token` not held in cell state (rebuilt per submit). `polling_task_ref` named `polling_task_pid`. Token-never-persisted invariant holds.
- **4.4** — CRN "?" help link + explicit Result panel in cell UI absent (results render in notebook output cell).

### Decisions D1–D10 — 9/10 hold
**D10 PARTIAL** (cell name set but not registered → see 4.1). Out-of-scope items all cleanly absent.

---

## BLOCKERs (5)

### B-1 — TranspileCell not registered in Application _(requirements-verifier, plan §4.1)_

`lib/kino/qx/application.ex` line 7 only calls `Kino.SmartCell.register(Kino.Qx.SmartCell)`. Add `Kino.SmartCell.register(Kino.Qx.TranspileCell)`.

### B-2 — `Task.start_link` from cell process is unsound _(elixir-reviewer, iron-law-judge)_

`transpile_cell.ex:154` (connect) and `:184` (submit). Linked but not under a `Task.Supervisor`. If `do_connect/1` or `TranspilePipeline.run/1` raises, exit propagates; the `handle_info({:EXIT, _, _}, ctx)` clause at `:284` swallows silently → dead cell with no user-visible error during a 24h queue wait.

**Fix:** either (a) `Task.start/1` (unlinked; result still flows via `send/2`) and have the EXIT clause surface error state, or (b) add `Task.Supervisor` to the application tree and use `Task.Supervisor.start_child/2`.

### B-3 — Cancel does not close the IBM session _(requirements-verifier, plan §4.8)_

`transpile_cell.ex` `handle_event("cancel")` only does `Process.exit(task, :kill)`. Plan §4.8 mandates best-effort `IbmClient.close_session/2`. Cell state doesn't currently track `current_session_id` (the assign exists but is never set during a submit run — the session id lives only inside the pipeline closure). Pipeline must surface `session_id` to the cell via an `on_status` event so cancel can use it.

### B-4 — `backend_known?/2` validation bypass when `backends_list` is empty _(elixir-reviewer, iron-law-judge — Iron Law #8)_

`transpile_cell.ex:443–449`. Pre-connect, `backends_list == []` and `backend_known?` returns `true` for any name. Stated invariant ("backend appears in cached list") is false pre-connect. Submit's `require_connected/1` does prevent unsanctioned IBM calls — so impact is documentation-vs-implementation drift, not exploitable. Still flagged BLOCKER because Iron Law #8 enforcement is one of the reviewer's hard gates.

**Fix:** empty-list branch → `false` (and Connect is gated separately), or restructure to set `last_backend_name = ""` until backends loaded.

### B-5 — `:ibm_results` error stage has zero test coverage _(testing-reviewer)_

`transpile_pipeline.ex:98–99` wraps `fetch_results/2` in stage `:ibm_results`. No test scripts a failing `fetch_results` — the Estimator-shape `:unsupported_result` path never hits the orchestrator's error handling.

**Fix:** add a `transpile_pipeline_test.exs` case scripting `fetch_results` to return `{:error, :unsupported_result}` after a DONE poll; assert `{:error, :ibm_results, :unsupported_result}`.

---

## WARNINGs (7)

### W-1 — Credential echo via `inspect(reason)` in error UI _(security)_

`transpile_cell.ex:491,494,514` uses `"... #{inspect(reason)}"`. Reasons can be `{:http, status, body}` (see `ibm_client.ex:415`). IAM 4xx/5xx bodies could echo the apikey back into the cell's `:error` assign and onto the JS side.

**Fix:** add `redact_reason/1` collapsing `{:http, status, _}` → `"HTTP #{status}"`, `{:network, _}` → `"network failure"`. In `iam_exchange/1` return `{:error, {:iam_http, status}}` (drop body).

### W-2 — SSRF via `portal_base_url` _(security)_

`transpile_cell.ex:99-102` accepts any string, persisted to `.livemd`, used as Req URL with the `qx_live_…` bearer. A malicious shared notebook can redirect the token to attacker host or `169.254.169.254`.

**Fix:** validate `https` scheme + non-empty host on every change event; ideally allowlist `*.qxquantum.com`. (IBM base URL is region-atom-allowlisted — not vulnerable.)

### W-3 — Single-condition `cond` _(elixir-reviewer + credo)_

`ibm_client.ex:389`. Replace with `if`.

### W-4 — Access-bracket on atom-keyed map _(elixir-reviewer)_

`transpile_cell.ex:527` `ctx.assigns.identity[:email]` should be `ctx.assigns.identity.email` (`Client.atomize/1` returns atom keys).

### W-5 — Stub modules have no `@behaviour` contract _(testing-reviewer)_

`StubClients.Ibm`/`Portal` can silently drift from real client signatures. Especially risky for `open_session/3` default arg.

**Fix:** define `@callback` declarations in `IbmClient`/`Client`; declare `@behaviour` in stubs.

### W-6 — `open_session` failure path untested _(testing-reviewer)_

`script_happy_path/2` always returns success for `open_session`, so the `:ibm_submit` error tag only exercises `submit_sampler` failure.

### W-7 — Latent `:ok` clause in `stage/2` _(elixir-reviewer)_

`transpile_pipeline.ex:121`. Bare `:ok` won't match `with`'s `{:ok, value} <-`. Latent today; remove or comment.

---

## SUGGESTIONs (8)

- Thread refreshed config out of `with_iam_refresh/2` to avoid repeated IAM round-trips over 24h jobs (security).
- Clear `qasm_paste` from live assigns when user toggles `save_qasm` off (security defense-in-depth).
- Make TLS verify explicit in Req config (security).
- Add regression test asserting sentinel tokens never appear in `inspect(to_attrs(ctx))` / `client_payload(ctx)` (security).
- Extract `portal_cfg`/`ibm_cfg` before connect Task closure (don't capture full `ctx`) — symmetry with submit's `build_pipeline_input/1` (elixir-reviewer, iron-law-judge).
- Document `__recorder__` key in stub config typespec (elixir-reviewer).
- Move `json_resp/3` to `test/support/bypass_helpers.ex` (testing).
- Tighten metadata key assertion at `transpile_pipeline_test.exs:96-97`; document deliberate `:ibm_auth` conflation at `:162` (testing).
- Credo: aliases for `Kino.Qx.{Client, IbmClient}` at top of `transpile_cell.ex`; lift nested `cond`s in `do_poll`, `poll_job` (verification).

---

## Verification — PASS

- `mix compile --warnings-as-errors` ✅ clean
- `mix format --check-formatted` ✅ clean
- `mix test` ✅ 1 doctest, 61 tests, 0 failures
- `mix credo --strict` ⚠️ 6 style/refactor suggestions in NEW code (3 nesting depth, 1 single-`cond`, 3 alias hints) — none correctness
- `mix dialyzer` ⏭️ skipped (no PLT — plan §8.7 schedules first build)

---

## Pre-existing in client.ex

- `client.ex:195` — `{:error, %{reason: reason}}` matches any error-shaped map; map-match may shadow future Req struct changes. (Pre-existing, not introduced in this diff.)
