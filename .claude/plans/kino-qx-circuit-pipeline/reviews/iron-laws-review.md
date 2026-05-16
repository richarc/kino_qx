# Iron Law Review — feat/credentials-cell

⚠️ EXTRACTED FROM AGENT MESSAGE (subagent Write was denied; captured by orchestrator per skill fallback)

Files scanned: 6. Laws checked: #7, #8, #11. Violations: 1 WARNING, 1 SUGGESTION, 0 BLOCKERs.

## WARNING — Law #8 — Missing fallback clause on `handle_event("update_ibm_region", ...)`

`lib/kino/qx/credentials_cell.ex:139`

```elixir
def handle_event("update_ibm_region", %{"value" => value}, ctx)
    when value in @valid_regions do
```

The guard `when value in @valid_regions` raises `FunctionClauseError` (crashes
the cell process) if the JS sends a region outside the two allowed values.
Every other `handle_event` clause in the file returns a user-visible error on
bad input; this one is the exception. Fix: add a fallback clause that calls
`set_error(ctx, "Invalid region.")` and returns `{:noreply, ctx}`.

## SUGGESTION — Law #11 — Cancel-watcher `spawn` in `run.ex`

`lib/kino/qx/run.ex:94` — **Verdict: ACCEPTABLE.** Request-scoped (born in
`run/2`, exits on `:done` or `{:DOWN, ...}`), unlinked by design so it can
cancel after caller interrupt, carries no persistent state, not supervised.
Orphan-on-session-teardown risk is documented in `@moduledoc`. #11 not violated.

## PASS — Law #7 — No `String.to_atom` on network/user input

`client.ex` uses `@known_keys` allowlist + `Enum.find` fallback (unknown fields
stay string keys). `credentials_cell.ex` coins no atoms from responses.

## PASS — Law #11 (application.ex) — Supervisor body is `[]`

`application.ex:9` — `Supervisor.start_link([], ...)`, no long-lived children.
