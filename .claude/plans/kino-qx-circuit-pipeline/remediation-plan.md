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

- [x] **R1.1** Add `Kino.Qx.SafeReason` — new module `lib/kino/qx/safe_reason.ex`, public `describe/1`. Redacts `%Config{}` bare / `{:error,%Config{}}` / `{stage,%Config{}}` + recurses `{stage,reason}`; unknown shape → fixed `"unexpected error"` (no inspect); friendly mappings kept (S1 folded).
- [x] **R1.2** Applied at all three sites: `run.ex` `render_terminal/2` error arm + `render_event_line(other,_)` now call `SafeReason.describe/1`; `error_summary/*` cluster deleted; `exceptions.ex` `RunError.message/1` delegates to `SafeReason.describe/1`, private `describe/*` deleted (S1).
- [x] **R1.3 [security]** `run.ex` — added `safe_cancel/3`; abnormal `:DOWN` arm calls it; rescues raise + catches exit/throw, logs a fixed string only (no reason/config). `require Logger` added.
- [x] **R1.4 [test]** `run_test.exs` "B1 — token-leak regression" describe block: sentinel-token `secret_config/0` + `refute_leaks/1`; covers bare/`{stage,_}`/`{:error,_}`/nested + unknown-shape + friendly mappings + a real `{:error,{stage,%Config{}}}` run/3 return. Frame line == `"✖ error: " <> SafeReason.describe` so SafeReason coverage = frame coverage.
- [x] **R1.5** `mix compile --warnings-as-errors` clean; `mix test test/kino/qx/run_test.exs` → 15 tests, 0 failures; `mix format` applied.

## Phase R2 — Interrupt path: raise `Kino.Qx.Interrupted` (W1, W2, W7, W8)

**Approach (user-chosen): wire it to actually raise.** Restructure
`run/3` so the blocking `Qx.Hardware.run/3` executes in a monitored
worker `Task`, while the caller stays in a `receive` loop that also
traps its own exit. On Livebook interrupt the caller (still alive in
the loop) detects the signal, tells the watcher to cancel, and raises
`Kino.Qx.Interrupted` (with `job_id` when known). `:kill` remains
untrappable — document that residual.

- [x] **R2.1 [spike]** Rewrote `Kino.Qx.Run.run/3`: `Process.flag(:trap_exit,true)` w/ `prev_trap` restore in `after`; `Task.async` worker runs `hardware_mod.run/3`; on_status sends `{:status,event}` to caller; new `run_loop/1` handles `{:status,_}` / `{ref,result}` / abnormal `{:DOWN,ref,_}` (propagates via `exit/1`) / `{:EXIT,task_pid,_}` (ignore) / `{:EXIT,_,reason in [:shutdown,:killed]}` → `Task.shutdown(:brutal_kill)` + single guarded `safe_cancel` + `send(watcher,:done)` + `raise Kino.Qx.Interrupted, job_id:`. `run!/3` unchanged (no rescue → Interrupted propagates). Watcher kept as `:kill`-only net via `:done` gating. `build_on_status/3` deleted; `handle_status/2` added.
- [x] **R2.2 [test]** `run_test.exs` "interrupt path" describe: blocking stub (`block: true` via :persistent_term — stub moved off pdict since worker runs in a Task), `spawn` runner + `Process.exit(runner,:shutdown)`, sync on `{:saw,:job_started}`. Covers: cancel fires + `Interrupted{job_id:"job_INT"}` raised; interrupt-before-job → `job_id: nil` + no cancel; normal completion no cancel; exactly-one-cancel (`refute_receive` after); `run!/3` propagates Interrupted not RunError.
- [x] **R2.3** Folded into R2.1 — abnormal `:DOWN` arm calls `Process.demonitor(task_ref,[:flush])` for symmetry with the normal-completion arm (W7).
- [x] **R2.4** `run.ex` `@moduledoc` rewritten: new architecture diagram, `:shutdown` vs `:kill` semantics, "Single-cancel gating" (Erlang message/`:DOWN` ordering), "Residual races" (spurious cancel + untrappable teardown) (W8).
- [x] **R2.5** `exceptions.ex` `Kino.Qx.Interrupted` `@moduledoc` rewritten (raised by run/run! on trappable `:shutdown`, not on `:kill`); `CHANGELOG.md` [Unreleased] Changed+Security blocks added; 0.2.0 Interrupted line de-claimed.
- [x] **R2.6** `mix compile --warnings-as-errors` clean; full `mix test` → 1 doctest, 58 tests, 0 failures, 4 excluded.

## Phase R3 — Cell correctness (W3, W4)

- [x] **R3.1** `credentials_cell.ex` — `update_ibm_region` now `is_binary` guard + `if valid_ibm_region?/1` (assign w/ `error: nil`) `else set_error(ctx, "Invalid region.")`; plus a non-binary `_params` fallback clause → `set_error`. No more FunctionClauseError (Iron Law #8). Added `@doc false valid_ibm_region?/1` predicate (mirrors `validate_portal_url/1` testable convention).
- [x] **R3.2** `credentials_cell.ex` connect handler `Task.start_link/1` → `Task.start/1` (unlinked: a `do_connect/1` raise must not wipe cell state; result via `send/2`). Iron Law #11 moduledoc note updated to match (unlinked, self-terminating).
- [x] **R3.3 [test]** `credentials_cell_test.exs` "valid_ibm_region?/1" describe — asserts allowlisted pass; rejects non-allowlisted/malformed/non-binary (`"us-east"`, `""`, `"US-SOUTH"`, padded, nil, 42, %{}, atom). Drives the predicate behind the error-path branch (handle_event not runtime-drivable, per file convention).
- [x] **R3.4** `mix compile --warnings-as-errors` clean; `mix test test/kino/qx/credentials_cell_test.exs` → 20 tests, 0 failures; `mix format` applied.

## Phase R4 — Polish (W6, W9, S2, S3)

- [x] **R4.1** `run.ex` — `handle_status_event/2` + both `render_terminal/2` clauses prepend `[line | lines]`; `render_frame/1` does `Enum.reverse |> Enum.join` once (W6: O(n²)→O(n)).
- [x] **R4.2** `mix.exs` `description/0` rewritten — Qx Credentials cell (secrets-sourced `%Config{}`) + `Kino.Qx.run!/2` pipeline + Qx Snippet cell; dropped the removed TranspileCell wording (W9).
- [x] **R4.3** `run.ex` `handle_status/2` — `rescue _ -> :ok` → `rescue e -> Logger.warning("... #{inspect(e.__struct__)}")` (logs exception TYPE only, no event/message value leak; S2).
- [x] **R4.4** `run.ex` — verified upstream: `Qx.Hardware` emits `{:ibm,:polling,status}` with `status` a **binary** (`hardware.ex:44`, line 400); poll map is atom-keyed internally, never crosses over. Dropped the `Map.get(poll,"status")`/`"queue_position"` string fallbacks; kept the atom-keyed map clause (test seam) with a contract-pinning comment (S3). No string-key test needed (path can't occur).
- [x] **R4.5** `mix format` + `mix compile --warnings-as-errors` clean; full `mix test` → 1 doctest, 60 tests, 0 failures, 4 excluded.

## Phase R5 — Test hardening (S4, S5, S6)

- [x] **R5.1** Moved nested `Kino.Qx.RunTest.StubHardware` → `test/support/stub_hardware.ex` as `Kino.Qx.StubHardware` (mirrors `StubClients`; @moduledoc documents the :persistent_term/Task rationale + script keys). `run_test.exs` now `alias Kino.Qx.StubHardware` (S4).
- [x] **R5.2** `credentials_cell_test.exs` SSRF describe — added "rejects IPv6 loopback" (`http`/`https://[::1]` ±port) and "rejects RFC-1918 private ranges" (10.x, 192.168.x, 172.16.x ×http/https) → all `nil`. No code change (existing `validate_portal_url/1` allowlist already rejects them; this pins it) (S5).
- [x] **R5.3** `run_test.exs` "public Kino.Qx entrypoint smoke (S6)" describe — drives public `Kino.Qx.run/3` + `run!/3` (qx.ex delegators) with ONLY the `_hardware_mod` seam (no `:on_status` → exercises default no-op callback path): ok-tuple, bare struct, RunError. Comment notes why true 2-arity can't carry the seam (S6).
- [x] **R5.4** `mix format` + `mix compile --warnings-as-errors` clean; full `mix test` → 1 doctest, 65 tests, 0 failures, 4 excluded.

## Phase R6 — Cross-repo (X1)

- [x] **R6.1** Filed **`qx-o9h`** in `qx/`'s bd DB (run from `../qx`, `main`): `type=bug`, `P1`, labels `discovered-from:kino-qx-circuit-pipeline,security`, title "Qx.Hardware.Config leaks secrets via inspect/1 — add @derive Inspect". Body has Problem / Discovered-from / Fix (`@derive {Inspect, except: [...]}`) / Acceptance / cross-repo coordination. No qx code edited from this branch.

## Phase R7 — Verification + re-review

- [x] **R7.1** `mix compile --warnings-as-errors` — clean.
- [x] **R7.2** `mix format --check-formatted` — clean.
- [x] **R7.3** `mix test` — 1 doctest + 65 tests + 0 failures + 4 excluded (was 48; +regression/interrupt/region/SSRF/public-arity).
- [x] **R7.4** `mix credo --strict` — **0 issues** (added aliases in qx.ex/exceptions.ex/run_test.exs; cleared the prior 2+ AliasUsage design suggestions).
- [x] **R7.5** `progress.md` — "Remediation (2026-05-15)" section added with the R1–R7 table; notes B1 closed locally + X1 filed upstream as `qx-o9h`.
- [ ] **R7.6** Commit on `feat/credentials-cell` — **deferred to user** (no auto-commit). Recommend a fresh `/phx:review security` on `run.ex` + `exceptions.ex` to confirm B1/W5 truly closed before PR.

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
