# Remediation Plan: kino-qx-circuit-pipeline review fixes

**Slug**: `kino-qx-circuit-pipeline` (remediation)
**Repo**: `/Users/richarc/Development/qxquantum/kino_qx`
**Branch**: `feat/credentials-cell` (continue on the same branch)
**Input**: `.claude/plans/kino-qx-circuit-pipeline/reviews/kino-qx-circuit-pipeline-triage.md`
**Source**: review findings (Iron Law #7 — no research; findings ARE the research)
**Created**: 2026-05-15
**Depth**: deep (security BLOCKER + W1 reopens the Phase 4 interrupt spike + cross-repo)

## Summary

Resolve the 16 triaged review findings (B1, W1–W9, S1–S6) plus the
cross-repo X1. The work clusters into: a token-leak security fix, a
spike-level rewrite of the interrupt path so `Kino.Qx.Interrupted` is
actually raised, and a tail of polish + test hardening. No new
behaviour — this is review remediation only.

## Completeness check (every finding has a task)

B1→R1.1 · S1→R1.1 · W5→R1.3 · W1→R2.1 · W2→R2.2 · W7→R2.3 ·
W8→R2.4 · W3→R3.1 · W4→R3.2 · W6→R4.1 · W9→R4.2 · S2→R4.3 ·
S3→R4.4 · S4→R5.1 · S5→R5.2 · S6→R5.3 · X1→R6.1. None deferred.

## Phase R1 — Security blocker: token-leak via `inspect/1` (B1, S1, W5)

- [ ] **R1.1** Add `Kino.Qx.SafeReason` (or a private `safe_reason/1` shared
  by `run.ex` + `exceptions.ex`) — the single error-reason→string mapper
  (folds S1). It MUST:
  - pattern-match `%Qx.Hardware.Config{}` (at any nesting depth in common
    shapes: bare, `{stage, %Config{}}`, `{:error, %Config{}}`) → emit
    `"config (redacted)"`
  - never call `inspect/1` on an arbitrary/unknown reason; for unknown
    shapes emit a fixed `"unexpected error"` (no value interpolation)
  - keep the existing friendly mappings (`:unauthorized`, `{:http, s, _}`,
    `{:rate_limited, n}`, `{:network, _}`, `{stage, reason}` recursion)
- [ ] **R1.2** Apply at all three sites: `run.ex:231` (`error_summary/1`),
  `run.ex:204` (`render_event_line(other, _)`), `exceptions.ex:22`
  (`RunError.describe/1`). Delete the now-duplicate logic (S1).
- [ ] **R1.3 [security]** `run.ex:115` — wrap the watcher `cancel/3` in
  `try/rescue` so a raise can't surface a crash report that `inspect`s the
  closure env (which captures `config` with tokens). Log a fixed string on
  failure, never the reason/config.
- [ ] **R1.4 [test]** Regression test in `run_test.exs`: assert
  `Kino.Qx.RunError` message for `{:some_stage, %Qx.Hardware.Config{...}}`
  and for a bare `%Config{}` contains neither the portal token nor the IBM
  key sentinel; assert the same for the frame-rendered terminal/error line.
- [ ] **R1.5** `mix compile --warnings-as-errors` + `mix test test/kino/qx/run_test.exs`.

## Phase R2 — Interrupt path: raise `Kino.Qx.Interrupted` (W1, W2, W7, W8)

**Approach (user-chosen): wire it to actually raise.** Restructure
`run/3` so the blocking `Qx.Hardware.run/3` executes in a monitored
worker `Task`, while the caller stays in a `receive` loop that also
traps its own exit. On Livebook interrupt the caller (still alive in
the loop) detects the signal, tells the watcher to cancel, and raises
`Kino.Qx.Interrupted` (with `job_id` when known). `:kill` remains
untrappable — document that residual.

- [ ] **R2.1 [spike]** Rewrite `Kino.Qx.Run.run/3`:
  - `Process.flag(:trap_exit, true)` (save/restore prior value in `after`)
  - worker `Task` runs `hardware_mod.run/3`; caller `receive`s `{:status,_}`,
    `{task_ref, result}`, `{:DOWN, task_ref, ...}`, and `{:EXIT, _, reason}`
  - on `{:EXIT, _, reason}` with `reason in [:shutdown, :killed]`: signal
    the watcher (or directly call `cancel/3` once, guarded), then
    `raise Kino.Qx.Interrupted, job_id: current_job_id`
  - keep the unlinked watcher ONLY as the `:kill` safety net (untrappable
    path); on the trappable path the caller handles cancel+raise so we
    don't double-cancel — gate the watcher on a `:done`/`:interrupted`
    signal so exactly one cancel fires.
  - `run!/3` lets `Kino.Qx.Interrupted` propagate (do NOT wrap it in
    `RunError`).
- [ ] **R2.2 [test]** `run_test.exs` interrupt cases (clears §4.8 UNMET):
  - block stub `run/3` on a `receive`; `Process.exit(caller, :shutdown)`;
    `assert_receive :stub_cancel_called`; assert `Kino.Qx.Interrupted` is
    raised with the expected `job_id`
  - assert a `:normal` completion does NOT call `cancel`
  - assert exactly ONE cancel fires (no double-cancel between caller and
    watcher)
  - assert `job_id` is threaded when `{:ibm, :job_started, id}` precedes
    the interrupt
- [ ] **R2.3** `run.ex` add `Process.demonitor(ref, [:flush])` on the
  abnormal `:DOWN` arm for symmetry (W7).
- [ ] **R2.4** `run.ex` `@moduledoc`: document the spurious-cancel race and
  the single-cancel gating; update the interrupt-semantics section to state
  `Kino.Qx.Interrupted` IS raised on the trappable path, `:kill` is the
  residual orphan case (W8).
- [ ] **R2.5** Update `exceptions.ex` `Kino.Qx.Interrupted` `@moduledoc`
  and `CHANGELOG.md` so the contract matches reality (it now raises).
- [ ] **R2.6** `mix compile --warnings-as-errors` + full `mix test`.

## Phase R3 — Cell correctness (W3, W4)

- [ ] **R3.1** `credentials_cell.ex:139` — add `update_ibm_region` fallback
  clause: non-allowlisted value → `set_error(ctx, "Invalid region.")`,
  `{:noreply, ctx}` (Iron Law #8).
- [ ] **R3.2** `credentials_cell.ex` connect handler — `Task.start_link/1`
  → `Task.start/1` (a `do_connect/1` raise must not wipe cell state; result
  is delivered via `send/2` so the link is pointless).
- [ ] **R3.3 [test]** `credentials_cell_test.exs` — add a case asserting an
  invalid region is rejected via the error path, not a crash. (handle_event
  needs the live Kino runtime; if not directly drivable, assert the guard +
  fallback shape per the file's existing convention.)
- [ ] **R3.4** `mix test test/kino/qx/credentials_cell_test.exs`.

## Phase R4 — Polish (W6, W9, S2, S3)

- [ ] **R4.1** `run.ex` — accumulate status lines with `[line | lines]`,
  reverse once in `render_frame/1`; fix `render_terminal/2` likewise (W6).
- [ ] **R4.2** `mix.exs:53-57` — rewrite `description/0` for the new
  credentials-cell + `Kino.Qx.run!` pipeline (W9).
- [ ] **R4.3** `run.ex:141-147` — narrow the caller `on_status` `rescue`
  to `rescue e -> Logger.warning(...)` (no value leak) instead of bare
  `rescue _ -> :ok` (S2).
- [ ] **R4.4** `run.ex:188-189` — pin the poll-key contract. Check upstream
  `Qx.Hardware` poll-status key type; if atom-keyed, drop the string
  fallback; else add a stub test exercising the string-key path (S3).
- [ ] **R4.5** `mix compile --warnings-as-errors` + `mix format` + `mix test`.

## Phase R5 — Test hardening (S4, S5, S6)

- [ ] **R5.1** Move inline `StubHardware` → `test/support/stub_hardware.ex`
  (mirror `StubClients` placement); update `run_test.exs` to alias it (S4).
- [ ] **R5.2** `credentials_cell_test.exs` — extend the SSRF matrix:
  IPv6 (`http://[::1]`, `https://[::1]`), RFC-1918
  (`http://10.0.0.1`, `http://192.168.1.1`, `http://172.16.0.1`),
  asserting each → `nil` (S5).
- [ ] **R5.3** `run_test.exs` — add a smoke test through the public
  2-arity `Kino.Qx.run/2` and `Kino.Qx.run!/2` (no opts), via the
  `:_hardware_mod` seam (S6).
- [ ] **R5.4** Full `mix test`.

## Phase R6 — Cross-repo (X1)

- [ ] **R6.1** File a bd issue in `qx/` (run from `../qx`, that repo's bd
  DB): `type=bug`, label `discovered-from:kino-qx-circuit-pipeline`,
  title "Qx.Hardware.Config leaks secrets via inspect/1 — add @derive
  Inspect". Body: add
  `@derive {Inspect, except: [:portal_token, :ibm_api_key, :ibm_crn,
  :access_token]}` to `Qx.Hardware.Config`; note kino_qx ships
  `safe_reason/1` as the local defence (R1) but the upstream `@derive` is
  the root-cause fix. **Do not edit qx code from this branch** (workspace
  rule: never edit two repos in one branch).

## Phase R7 — Verification + re-review

- [ ] **R7.1** `mix compile --warnings-as-errors` — clean.
- [ ] **R7.2** `mix format --check-formatted` — clean.
- [ ] **R7.3** `mix test` — green; expect new total ≈ 55–60 (added
  regression + interrupt + SSRF + public-arity tests).
- [ ] **R7.4** `mix credo --strict` — 0 warnings.
- [ ] **R7.5** Update `progress.md`: add a "Remediation" section; note B1
  closed locally + X1 filed upstream.
- [ ] **R7.6** Commit on `feat/credentials-cell`. Recommend a fresh
  `/phx:review security` pass focused on `run.ex` + `exceptions.ex` to
  confirm B1/W5 are truly closed before the branch is opened for PR.

## Risks & open questions

1. **R2.1 is the spike.** Mixing `trap_exit` + a monitored worker Task +
   the existing unlinked watcher risks double-cancel or a missed cancel.
   Mitigation: single-cancel gating signal; write R2.2 tests BEFORE R2.1
   lands (test-first forces the message protocol).
2. **`:kill` is still untrappable.** Wiring `Interrupted` only covers the
   `:shutdown` path. Livebook's actual interrupt signal type is not
   verified here — if it sends `:kill`, `Interrupted` won't raise and the
   watcher remains the only safety net. R2.4 must document this honestly;
   do not over-claim in the CHANGELOG.
3. **B1 depth.** `safe_reason/1` must redact `%Config{}` even when nested
   in tuples/exceptions. A shallow match leaves the leak open. R1.4 tests
   the nested shapes explicitly.

### Self-check (deep)

- *What could go wrong silently?* A `safe_reason/1` that misses a nesting
  shape → token still leaks but tests pass. Mitigation: R1.4 enumerates
  bare + `{stage, _}` + `{:error, _}` shapes.
- *What did I assume?* That Livebook interrupt is trappable `:shutdown`.
  Unverified — R2 keeps the watcher as the `:kill` fallback rather than
  replacing it.
- *Riskiest task?* R2.1. Test-first via R2.2; keep the watcher as a
  belt-and-braces net so a bug in the new trap path can't regress the
  cancel guarantee.

## Verification gates

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
```

Plus a focused `/phx:review security` on `run.ex` + `exceptions.ex`
after R7 before PR.
