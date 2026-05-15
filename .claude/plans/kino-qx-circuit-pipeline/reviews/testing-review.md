# Test Review — feat/credentials-cell

⚠️ EXTRACTED FROM AGENT MESSAGE (subagent Write denied; captured by orchestrator)

Privacy-invariant coverage in `credentials_cell_test.exs` is thorough.
`run_test.exs` happy-path + error-tuple paths adequate. The cancel-watcher —
the riskiest path in `run.ex` — has zero unit coverage.

## BLOCKER (orchestrator note: treated as the §4.8 UNMET requirement)
**cancel-watcher `:DOWN` → `cancel/2` path never triggered** (`run.ex:111-115`)
No test exercises: (a) abnormal-exit fires `cancel/2` with last-seen
`job_id`; (b) `:normal` exit does NOT call `cancel/2`; (c) watcher advances
`job_id` when `{:job_id, id}` precedes `:DOWN`. `StubHardware.cancel/2`
`:cancel_to` scaffolding (`run_test.exs:32-34`) is wired but never invoked.
Fix: spawn a caller, block stub `run/3` on a `receive`,
`Process.exit(caller, :shutdown)`, `assert_receive :stub_cancel_called, 500`.

## WARNING
- `run_test.exs:12` `async: false` + process dict: `StubHardware.install/1`
  called in test body (not `setup`); a crash leaves `:stub_hardware_opts`
  dirty for the next test. Add `setup do: StubHardware.install([])`.
- Frame-rendering paths untested: `render_event_line` clause coverage
  (polling map / polling binary / fallback inspect) is zero. Confirm Kino is
  booted in test mode.
- `portal_live_test.exs` `async: true` on a live-network test — safe now
  (read-only), fragile if writes added.
- `ibm_live_test.exs` fragile inline backend-name extraction masks the
  canonical shape.
- SSRF matrix missing IPv6 (`::1`, `[::1]`) and RFC-1918 (`10.x`,
  `192.168.x`, `172.16-31.x`) cases.
- `to_source/1` sparse-attrs test hard-codes default values; breaks silently
  if defaults change.

## SUGGESTION
- `Kino.Qx.Interrupted` is defined + tested but **never raised by `run.ex`** —
  dead code / missing wiring (dup of requirements §4.5).
- Move inline `StubHardware` to `test/support/stub_hardware.ex`.
- `caller_on_status` error-swallowing untested.
- No test through the 2-arity public `Kino.Qx.run/2` / `run!/2`.
