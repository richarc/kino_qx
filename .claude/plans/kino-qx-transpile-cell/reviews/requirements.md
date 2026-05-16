# Requirements Coverage — kino_qx 0.2.0

**Source:** Plan `.claude/plans/kino-qx-transpile-cell/plan.md`

**Phases 1–5 (marked [x]): 24 MET · 7 PARTIAL · 1 UNMET · 3 NOT YET ATTEMPTED (Phases 6/7/8)**

## Critical gaps

### UNMET (1)

- **5.3** — `to_source/1` emits no `Kino.Markdown` block for `queue_wait_ms`/`execution_time_ms` job metadata. Job ID appears in a comment and table name only.

### PARTIAL — blocking issues

- **4.1 / D10** — `application.ex:7` only registers `Kino.Qx.SmartCell`. `TranspileCell` is **never registered**; the cell will not appear in Livebook's "+ Smart" menu at all. **CRITICAL.**
- **4.8** — `handle_event("cancel")` kills the Task via `Process.exit/2` but **never calls `IbmClient.close_session/2`**. Plan §4.8 requires best-effort close on cancel. Session leaks.
- **4.4 / 4.2** — "From variable" QASM radio (binding to a notebook variable) is absent; only textarea paste mode ships. `qasm_var_name` persist attr is also missing from `to_attrs/1`.

### PARTIAL — minor / non-blocking

- **1.4** — `client_transpile_test.exs` has 8 test cases; plan claimed 9. The 9th (body assertion) is folded into the happy-path test — effectively covered but count differs.
- **4.3** — `ibm_access_token` / `ibm_token_expires_at` not tracked as separate assigns (they live inside a locally-built ibm_config per submit). `polling_task_ref` shipped as `polling_task_pid`. Token-never-persisted invariant holds.
- **4.4** — CRN label "?" help link and explicit Result panel in cell UI absent (results render in notebook output cell, not cell UI).

## Decisions locked in plan — all 10 checked
D1 (token isolation) ✓ · D2 (Sampler only) ✓ · D3 (sessions mandatory) ✓ · D4 (PUB wrapping in IbmClient) ✓ · D5 (1s/2s/4s/cap-30s, 24h timeout) ✓ · D6 (transient tokens) ✓ · D7 (resilience_level: 1) ✓ · D8 (backend metadata) ✓ · D9 (test.qxquantum.com default) ✓ · **D10 PARTIAL** (cell name set but **not registered in Application** — see 4.1).

## Out-of-scope items — none snuck in

Estimator, queue-position progress bar, multi-circuit batches, and auto-refresh portal token are all cleanly absent.

## Summary line

**24 MET · 7 PARTIAL · 1 UNMET · 3 NOT YET ATTEMPTED.** Verdict downgrade: the UNMET (5.3) and the **critical PARTIAL 4.1 (cell never registered)** force `REQUIRES CHANGES`.
