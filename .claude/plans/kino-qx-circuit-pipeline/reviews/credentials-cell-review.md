# Review: kino_qx 0.2.0 — credentials cell + Kino.Qx.run! pipeline

**Branch:** `feat/credentials-cell` · **Verdict: REQUIRES CHANGES**
**Date:** 2026-05-15 · 5 agents (elixir, security, testing, iron-laws, requirements)

> Note: all 5 subagents were Write-denied this session; findings were
> captured by the orchestrator from agent return messages (per the skill's
> missing-file fallback). Per-agent files in this directory are marked
> `⚠️ EXTRACTED`.

## Verdict rationale

- **1 BLOCKER** (security: token leak via `inspect/1` catch-alls)
- **1 UNMET requirement** (§4.8 interrupt test) → escalates to REQUIRES CHANGES
- Code compiles, formats, and tests green (48 tests) — not BLOCKED, but the
  BLOCKER must be fixed before merge given this is a credentials library.

## Requirements Coverage

30 MET · 3 PARTIAL · 1 UNMET · 9 NOT-APPLICABLE-YET (Phase 9 gated on qx
0.7.0 Hex). Scratchpad's Livebook-secrets deviation verified MET. See
`requirements.md`.

## Findings (deduplicated, severity-ordered)

### BLOCKER

**B1 — `inspect/1` can write plaintext tokens into the `.livemd` and exception messages.**
`run.ex:231` (`error_summary(other)`), `run.ex:204`
(`render_event_line(other,_)`), `exceptions.ex:22` (`describe(other)`) all
fall back to `inspect(other)`. If any upstream `{:error, reason}` embeds a
`%Qx.Hardware.Config{}` (which carries `portal_token`/`ibm_api_key`/
`ibm_crn`/`access_token` and has no `@derive Inspect`), the catch-all dumps
secrets into the Kino frame Markdown (persisted to `.livemd`) and into the
raised `RunError`. This breaks the privacy invariant that is the entire
point of the 0.2.0 design.
*Fix (here):* a `safe_reason/1` that matches `%Qx.Hardware.Config{}` →
`"config (redacted)"` and never `inspect`s arbitrary upstream reasons; apply
at all three sites; add a regression test.
*Fix (cross-repo):* file a bd issue for `@derive {Inspect, except: [...]}`
on `Qx.Hardware.Config` in `qx/`.

### WARNING

- **W1 — Interrupt path is half-built.** `Kino.Qx.Interrupted` is defined +
  unit-tested but **never raised** in production: the watcher cancels then
  exits silently; the caller is already dead. Either wire caller-side
  interrupt detection that raises it, or demote it to advisory and stop
  documenting it as a raised error. (§4.5; flagged by testing + requirements.)
- **W2 — cancel-watcher has zero unit coverage** (the §4.8 UNMET item, and
  the riskiest code per plan §Risks). `StubHardware.cancel/2`'s `:cancel_to`
  hook is wired but nothing drives it. Add: block stub `run/3`,
  `Process.exit(caller, :shutdown)`, `assert_receive :stub_cancel_called`.
- **W3 — `update_ibm_region` missing fallback clause** (`credentials_cell.ex:139`,
  Iron Law #8). Bad region from JS → `FunctionClauseError` crashes the cell.
  Add a `set_error/2` fallback like every other handler.
- **W4 — connect handler `Task.start_link`** (`credentials_cell.ex`): a raise
  in `do_connect/1` propagates and wipes cell state. Result is delivered via
  `send/2`, so the link buys nothing — use `Task.start/1`.
- **W5 — unguarded `cancel/3` in watcher** (`run.ex:115`): if it raises, the
  watcher crash report `inspect`s the closure env (incl. `config`) → tokens
  in the Livebook log. Wrap in `try/rescue`.
- **W6 — O(n²) status-line append** (`run.ex:161`, `213`, `217`):
  `lines ++ [line]` per poll tick. Use `[line | lines]` + reverse in
  `render_frame/1`.
- **W7 — `:DOWN` abnormal arm skips `Process.demonitor`** (`run.ex:111`):
  asymmetric with the `:done` arm.
- **W8 — spurious-cancel race undocumented** (`run.ex:83`): caller killed
  between `run/3` return and `send(watcher, :done)` → cancel on a finished
  job. Harmless (IBM 404) but document next to the `:kill` discussion.
- **W9 — `mix.exs:53-57` description stale** — still describes the old
  TranspileCell pipeline (§7.4).

### SUGGESTION

- S1 — `error_summary/1` (run.ex) and `describe/1` (exceptions.ex) duplicate
  the reason→string mapping; extract a shared helper (folds into the B1 fix).
- S2 — narrow the broad `rescue _ -> :ok` on the caller `on_status` callback
  (`run.ex:141-147`) or `Logger.warning`.
- S3 — pin the dual atom/string poll-key fallback (`run.ex:188-189`) or test
  the string-key path.
- S4 — move inline `StubHardware` to `test/support/stub_hardware.ex`.
- S5 — extend the SSRF test matrix with IPv6 + RFC-1918 ranges.
- S6 — add a smoke test through the public 2-arity `Kino.Qx.run/2` / `run!/2`.

## Theme

Every BLOCKER/WARNING except W3/W9 clusters in `run.ex`'s error and interrupt
handling — exactly the Phase 4 spike the plan flagged as riskiest. The happy
path, the privacy of `to_attrs`/`to_source`, the SSRF allowlist, and Iron Law
#7 are all solid.
