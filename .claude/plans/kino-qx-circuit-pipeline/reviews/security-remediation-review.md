# Security Remediation Review — kino-qx-circuit-pipeline

**Date:** 2026-05-15 · Branch: `feat/credentials-cell` · Scope: uncommitted
remediation diff on top of HEAD `1e89c5a`.
Agents: `security-analyzer` (focused), `requirements-verifier`.

> ⚠️ EXTRACTED FROM AGENT MESSAGES — both agents' Write to `reviews/`
> was sandbox-denied; orchestrator persisted their output here per the
> review skill's missing-file fallback (logged in scratchpad).

## Verdict: **PASS WITH WARNINGS**

- **B1/W5 token-leak blocker: CLOSED.** No `inspect/1` / interpolation
  path can reach `Qx.Hardware.Config` secrets. Verified adversarially
  (Config nested in tuples / 3-tuples / unknown shapes all collapse to
  fixed strings; upstream `qx` never embeds `%Config{}` in reasons).
- **R2 interrupt path: SOUND.** Single-cancel guarantee holds (Erlang
  same-sender ordering of `:done` before the caller `:DOWN`); no
  double/missed cancel; clause ordering race-free; `run!/3` propagates
  `Kino.Qx.Interrupted` unwrapped; `trap_exit` restore cannot be
  skipped; `:kill` orphan honestly documented.
- **No BLOCKER.** Requirements coverage **17/17 MET** (see
  `requirements-remediation.md`).

## Requirements Coverage

17 MET · 0 PARTIAL · 0 UNMET. B1,S1,W1–W9,S2–S6 verified in code/tests;
X1 = `qx-o9h` filed + `bd show`-verified in `../qx` (type=bug, P1,
`discovered-from:kino-qx-circuit-pipeline,security`).

## Findings (post anti-noise filter)

### WARNING

- **W-1 (pre-existing, upstream): `Qx.Hardware.cancel/3` is synchronous
  and unbounded.** On the interrupt path, a hung IBM IAM exchange
  inside `safe_cancel/3` delays the `Kino.Qx.Interrupted` raise.
  Impact: interrupt latency / UX only — **no leak** (the `safe_cancel`
  log is a fixed string). Not introduced by this remediation; cancel
  was always synchronous. Out of remediation scope — candidate bd
  `task` if interrupt responsiveness becomes a concern.

### SUGGESTION

- **S-1: `SafeReason.describe/1` has no clause for upstream exception
  structs.** `Qx.Hardware.run/3` can return `{:error, %ConfigError{}}`
  / `%NoMeasurementsError{}` / `%ExecutionError{}` un-wrapped. These
  hit the catch-all → `"unexpected error"`. **Safe** (the agent
  confirmed none carry a `Config`), but the user loses actionable
  error text. Consider explicit `describe(%ConfigError{} = e)` →
  `Exception.message(e)` clauses.
- **S-2: `credentials_cell.ex` `redact_reason/1` duplicates the
  SafeReason mapping.** S1's dedup spirit — delegate `redact_reason/1`
  to `Kino.Qx.SafeReason.describe/1` so there is one audited
  reason→string sink.
- **S-3 (cosmetic): `run.ex` `handle_status/2` logs
  `inspect(e.__struct__)`.** Safe (atom module name, no value).
  `Atom.to_string/1` would read marginally cleaner. Borderline noise —
  optional.

## Recommended regression gates (already green this session)

`mix test test/kino/qx/run_test.exs` · `mix compile
--warnings-as-errors` · `mix credo --strict`. Agent also suggested
`mix sobelow --exit medium` and `mix deps.audit` if available
(neither is currently a project dep).

## Bottom line

The remediation does what it claims. The original BLOCKER (B1) and its
security WARNINGs (W5) are genuinely closed with defence-in-depth, and
the risky R2 interrupt-path spike is sound. The three SUGGESTIONs are
optional polish; none gate the PR. The single WARNING is pre-existing
upstream behaviour, not a regression.
