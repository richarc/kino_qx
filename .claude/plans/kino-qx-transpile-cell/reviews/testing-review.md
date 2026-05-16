# Test Review: kino_qx 0.2.0 — New Test Files

## Summary

Three new test files. All use `async: true` correctly. The Bypass + StubClients approach is internally consistent. Two issues need attention before merge: a missing error-stage test (`:ibm_results`) and an undocumented intentional conflation of `fetch_backend_properties` failures under `:ibm_auth`.

## Iron Law Violations

None. No `Process.sleep`, no global Mox mode, no database, `async: true` throughout.

## Issues

### BLOCKER

**Missing `:ibm_results` error-stage test** (`transpile_pipeline_test.exs`, `describe "error routing"`)

The pipeline documents 7 error stage atoms. Six are tested. The `:ibm_results` stage — wrapping `fetch_results/2` at line 98–99 of `transpile_pipeline.ex` — is never exercised with a failure. A bad result (e.g., Estimator shape returning `:unsupported_result`) falls through with zero test coverage.

**Fix:** add a test scripting `fetch_results` to return `{:error, :unsupported_result}` after a DONE poll, asserting `{:error, :ibm_results, :unsupported_result}`.

### WARNING

**No behaviour contracts backing StubClients** (`test/support/stub_clients.ex`)

`StubClients.Ibm` and `StubClients.Portal` mirror real client surfaces, but neither `Kino.Qx.IbmClient` nor `Kino.Qx.Client` define `@callback` behaviours. Stub signatures can silently drift from the real modules with no compile-time detection. Especially risky for `open_session/3` (default arg) — the stub only handles arity 3.

**Fix:** define `@callback` behaviours in the real client modules; add `@behaviour` declarations in the stub modules so the compiler flags any future arity/name drift.

**`open_session` failure path for `:ibm_submit` untested** — the `submit_sampler failure` test uses `script_happy_path/2` which scripts a successful `open_session`. The `:ibm_submit` tag covers both functions; the `open_session` failure branch has no dedicated test.

**`json_resp/3` duplicated** across `client_transpile_test.exs:20` and `ibm_client_test.exs:27`. Move to `test/support/bypass_helpers.ex`.

**`drain_statuses/0` uses `after 0`** — safe today because `run/1` is synchronous via in-process Agent stubs. If `run/1` is ever made async (Task-spawned), this becomes a race. Add a comment asserting the synchrony assumption, or use `after 10`.

### SUGGESTION

**`fetch_backend_properties` failure asserts `:ibm_auth` tag** (`transpile_pipeline_test.exs:162`). Intentional but undocumented — add a comment making the deliberate conflation explicit.

**Metadata key assertion is hedged** (`transpile_pipeline_test.exs:96–97`): `result.metadata[:execution_time_ms] == 42 or result.metadata["execution_time_ms"] == 42`. Since stubs return atom-keyed maps, assert directly on the atom key.

**`transpile_cell_test.exs` does not exist** — tracked gap (plan task 6.2), not a blocker, but any `handle_event` callbacks in `TranspileCell` are currently uncovered public surface.
