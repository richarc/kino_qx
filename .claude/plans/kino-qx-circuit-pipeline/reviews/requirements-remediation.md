# Requirements Coverage — remediation-plan kino-qx-circuit-pipeline

> ⚠️ EXTRACTED FROM AGENT MESSAGE (requirements-verifier Write was
> sandbox-denied to `reviews/`; persisted here by the orchestrator per
> the review skill's missing-file fallback). X1 status corrected from
> UNCLEAR → MET by the orchestrator (the agent's sandbox could not read
> `../qx/.beads`; `qx-o9h` was created + `bd show`-verified earlier in
> this session: type=bug, P1, labels `discovered-from:kino-qx-circuit-pipeline,security`).

Source findings: B1, W1–W9, S1–S6, X1.

| Finding | R-task | Status | Evidence |
|---------|--------|--------|----------|
| B1 — Token leak via `inspect/1` | R1.1 | MET | `lib/kino/qx/safe_reason.ex` (new); `run.ex` `SafeReason.describe/1` at event-line fallback + render_terminal error arm; old `error_summary/*` deleted |
| S1 — Dedup error→string helper | R1.1 | MET | `exceptions.ex` private `describe/*` deleted; `RunError.message/1` delegates to `SafeReason.describe/1` |
| W5 — Watcher cancel crash-dumps tokens | R1.3 | MET | `run.ex` `safe_cancel/3` wraps `cancel/3` with `rescue`/`catch` → fixed-string `Logger.warning` |
| W1 — `Kino.Qx.Interrupted` actually raised | R2.1 | MET | `run_loop/1` `{:EXIT,_,reason in [:shutdown,:killed]}` → shutdown + safe_cancel + `:done` + `raise Kino.Qx.Interrupted, job_id:` |
| W2 — Interrupt test | R2.2 | MET | `run_test.exs` interrupt describe: 4 tests (raises w/ job_id, exactly-one-cancel, no-job, run!/3 propagates) |
| W7 — `demonitor` in abnormal DOWN arm | R2.3 | MET | `run.ex` `Process.demonitor(task_ref,[:flush])` in normal + abnormal arms |
| W8 — moduledoc spurious-cancel race | R2.4 | MET | `run.ex` @moduledoc: architecture diagram, Single-cancel gating, Residual races |
| W3 — `update_ibm_region` fallback | R3.1 | MET | `credentials_cell.ex` non-binary fallback clause + `valid_ibm_region?/1`; cell test describe |
| W4 — `Task.start_link`→`Task.start` | R3.2 | MET | `credentials_cell.ex` connect handler `Task.start/1` |
| W6 — O(n²) line accumulation | R4.1 | MET | `run.ex` `[line|lines]` prepend + `render_frame/1` reverse-once |
| W9 — Stale mix.exs description | R4.2 | MET | `mix.exs` description rewritten; TranspileCell wording removed |
| S2 — Broad `rescue _ -> :ok` | R4.3 | MET | `run.ex` `rescue e -> Logger.warning(... inspect(e.__struct__))` (type only) |
| S3 — Dual atom/string poll-key | R4.4 | MET | `run.ex` string fallbacks removed; atom-keyed `Map.get(poll,:status,"polling")` + comment |
| S4 — Move StubHardware | R5.1 | MET | `test/support/stub_hardware.ex` (`:persistent_term`); `run_test.exs` aliased |
| S5 — SSRF IPv6 + RFC-1918 | R5.2 | MET | `credentials_cell_test.exs` IPv6 loopback + RFC-1918 describes |
| S6 — Public-arity smoke | R5.3 | MET | `run_test.exs` "public Kino.Qx entrypoint smoke (S6)" describe |
| X1 — File qx bd bug | R6.1 | MET | `qx-o9h` in `../qx` bd DB — type=bug, P1, `discovered-from:kino-qx-circuit-pipeline,security` (orchestrator-verified via `bd show qx-o9h`) |

**Summary: 17 MET · 0 PARTIAL · 0 UNMET.**
