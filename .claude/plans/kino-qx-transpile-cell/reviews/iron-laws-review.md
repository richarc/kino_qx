# Iron Law Violations Report — kino_qx 0.2.0

**Files scanned**: `client.ex`, `ibm_client.ex`, `transpile_pipeline.ex`, `transpile_cell.ex`
**Iron Laws checked**: 15 of 15 applicable
**Violations**: 3 (0 BLOCKER, 2 WARNING, 1 SUGGESTION)

## BLOCKER

None.

## WARNING

### [Iron Law #10] `Task.start_link` without a supervisor

- **File**: `lib/kino/qx/transpile_cell.ex:154` (connect task) and `:184` (submit task)
- **Code**: `Task.start_link(fn -> send(parent, {:connect_result, do_connect(ctx)}) end)`
- **Detail**: `Task.start_link/1` links to the caller but is NOT registered under any OTP supervisor. The moduledoc claims the Kino cell process acts as supervisor, but linking alone is not OTP supervision — a crashed cell cannot selectively restart a linked Task. Line 284 silently swallows `{:EXIT, _, _}`, so a crash in the Task during a long IBM queue wait drops the result without user feedback.
- **Fix**: Use `Task.Supervisor.start_child(Kino.Qx.TaskSupervisor, fun)` with a named supervisor in the application tree. At minimum, document why bare `Task.start_link` is sufficient and confirm trap_exit behavior under all exit scenarios.

### [Iron Law #8] `update_backend` allowlist silently bypassed when `backends_list` is empty

- **File**: `lib/kino/qx/transpile_cell.ex:443–449`
- **Detail**: `backend_known?/2` returns `true` unconditionally when `backends_list == []`. Any arbitrary backend string can be stored in `last_backend_name` before Connect. The moduledoc claims Iron Law #8 is satisfied with "backend name appears in cached backends_list" — only true post-connect. Submit gates on `require_connected/1`, so no unsanctioned IBM call can be made; pre-connect bypass is a documentation inconsistency and weak validation surface.
- **Fix**: Either return `{:error, "Connect first to load backends"}` when list is empty and name is non-empty, or update the moduledoc to clarify that backend validation is deferred to submit-time `require_connected`.

## SUGGESTION

### [LiveView idiom] Full `ctx` struct captured in connect Task closure

- **File**: `lib/kino/qx/transpile_cell.ex:154`
- **Detail**: The connect-task closure copies the entire `ctx` struct including all credential assigns. The submit task at line 184 already follows the better pattern via `build_pipeline_input(ctx)`. Extract `portal_cfg`/`ibm_cfg` before the closure and pass to a two-arg `do_connect/2`.

## Specifically Audited Concerns (per plan.md)

- **#7 (atom exhaustion) — PASS (DEFINITE).** `IbmClient.poll_job/2` matches status as binary against `@known_statuses ~w(INITIALIZING QUEUED RUNNING DONE CANCELLED ERROR)`; never atomized. Unknown values return `{:error, {:unknown_status, status}}`. `Client.atomize/1` uses `to_known_atom/1` allowlist scan; no `String.to_atom/1` anywhere. New keys (`:qasm`, `:metadata`, `:depth`, `:size`, `:num_qubits`) confirmed at `client.ex:121-126`.
- **#8 (handle_event validation) — MOSTLY PASS.** All other clauses validate input correctly. Only the `update_backend` empty-list bypass is a concern (above).
- **#10 (process justification) — CONDITIONALLY PASS.** Runtime reason for Tasks is documented and valid (long-running HTTP I/O must not block the cell). Supervision form is the concern (above).
- **Allowlist atom-conversion in `Client` — PASS.** No new `String.to_atom`. All five new keys present in `@known_keys`.

**Total: 0 BLOCKERs, 2 WARNINGs, 1 SUGGESTION.**
