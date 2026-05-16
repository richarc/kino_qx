# Triage — kino-qx-circuit-pipeline review

**Date:** 2026-05-15 · Source: `reviews/credentials-cell-review.md`
**Decision:** fix everything (16 findings) + 1 cross-repo bd issue.

## Fix Queue

### BLOCKER
- [ ] **B1** — Token leak via `inspect/1` catch-alls. Add `safe_reason/1`
  that matches `%Qx.Hardware.Config{}` → `"config (redacted)"` and never
  `inspect`s arbitrary upstream reasons. Apply at `run.ex:231`,
  `run.ex:204`, `exceptions.ex:22`. Add a regression test:
  `inspect`-rendered output and `RunError.message({:x, %Config{}})` must not
  contain a token value. **Folds in S1** (shared error→string helper).

### WARNING — correctness/security
- [ ] **W1** — Wire `Kino.Qx.Interrupted` to actually raise.
  **Approach (user-chosen):** `run/2` monitors a worker Task (or traps the
  caller exit) so on interrupt it issues the cancel AND raises
  `Kino.Qx.Interrupted` in the caller. Update docstring + CHANGELOG to match
  the now-true contract.
- [ ] **W2** — Add the §4.8 interrupt test to `run_test.exs` (clears the
  UNMET requirement): block stub `run/3`, `Process.exit(caller, :shutdown)`,
  `assert_receive :stub_cancel_called`; assert `:normal` exit does NOT
  cancel; assert `job_id` advances when `{:job_id, _}` precedes `:DOWN`.
- [ ] **W3** — `credentials_cell.ex:139` add `update_ibm_region` fallback
  clause → `set_error(ctx, "Invalid region.")` (Iron Law #8; auto-approved).
- [ ] **W5** — `run.ex:115` wrap watcher `cancel/3` in `try/rescue` so a
  raise can't crash-dump `config` (tokens) to the Livebook log.

### WARNING — polish
- [ ] **W4** — `credentials_cell.ex` connect handler `Task.start_link` →
  `Task.start/1` (raise must not wipe cell state).
- [ ] **W6** — `run.ex:161/213/217` prepend + reverse instead of `++ [line]`
  per poll tick (O(n²) → O(n)).
- [ ] **W7** — `run.ex:111` add `Process.demonitor(ref, [:flush])` in the
  abnormal `:DOWN` arm for symmetry with `:done`.
- [ ] **W8** — `run.ex` `@moduledoc` document the spurious-cancel race
  (caller killed between `run/3` return and `send(watcher, :done)`).
- [ ] **W9** — `mix.exs:53-57` rewrite the stale description (still
  describes the old TranspileCell pipeline).

### SUGGESTION
- [ ] **S1** — Dedupe `error_summary/1` (run.ex) ↔ `describe/1`
  (exceptions.ex) into one shared helper. (Folded into B1.)
- [ ] **S2** — Narrow the broad `rescue _ -> :ok` on the caller
  `on_status` callback (`run.ex:141-147`) or `Logger.warning`.
- [ ] **S3** — Pin the dual atom/string poll-key fallback
  (`run.ex:188-189`) or add a test for the string-key path.
- [ ] **S4** — Move inline `StubHardware` → `test/support/stub_hardware.ex`.
- [ ] **S5** — Extend SSRF test matrix: IPv6 (`::1`, `[::1]`) + RFC-1918
  (`10.x`, `192.168.x`, `172.16-31.x`).
- [ ] **S6** — Add a smoke test through the public 2-arity
  `Kino.Qx.run/2` / `run!/2`.

### Cross-repo (bd issue, not fixed here)
- [ ] **X1** — File a bd issue in `qx/` (`type=bug`,
  `discovered-from:kino-qx-circuit-pipeline`): add
  `@derive {Inspect, except: [:portal_token, :ibm_api_key, :ibm_crn,
  :access_token]}` to `Qx.Hardware.Config`. kino_qx's `safe_reason/1` (B1)
  is the local defence; the upstream `@derive` is the root-cause fix.

## Skipped
(none — user selected all findings)

## Deferred
(none)

## Notes
- All 5 review subagents were Write-denied this session; per-agent files in
  this directory carry `⚠️ EXTRACTED` headers.
- Phase 9 (Hex publish) remains BLOCKED on qx 0.7.0 — out of scope for this
  fix pass.
