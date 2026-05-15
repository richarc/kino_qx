# Elixir Idioms Review — feat/credentials-cell

⚠️ EXTRACTED FROM AGENT MESSAGE (subagent Write denied; captured by orchestrator)

**Status:** Changes Requested — 4 WARNINGs, 3 SUGGESTIONs, 0 BLOCKERs.

## WARNING — `credentials_cell.ex` connect handler — `Task.start_link` crashes the cell
`handle_event("connect", ...)` uses `Task.start_link/1`, linking the task to
the cell process. If `do_connect/1` raises, the crash propagates and wipes
smart-cell state. Result is delivered via `send/2` (not `Task.await`), so the
link buys nothing. Use `Task.start/1`.

## WARNING — `run.ex:111` — `:DOWN` abnormal arm skips `Process.demonitor`
The `:done` arm calls `Process.demonitor(ref, [:flush])`; the abnormal
`{:DOWN, reason != :normal}` arm does not. Asymmetric. Low risk (process
exits immediately) but add the demonitor for symmetry.

## WARNING — `run.ex:161` — O(n²) list append on every status event
`state.lines ++ [line]` per event, including every poll tick. Long jobs ⇒
O(n²). Use `[line | state.lines]` + reverse once in `render_frame/1`. Same at
`render_terminal/2` (≈213, 217).

## WARNING — `run.ex:83` — spurious cancel race on normal completion (undocumented)
If the caller is killed between `hardware_mod.run/3` returning and
`send(watcher, :done)`, the watcher sees `{:DOWN, :killed}` and cancels an
already-finished job. IBM 404 handles it, but the `@moduledoc` doesn't mention
this race. Document it next to the `:kill` discussion.

## SUGGESTION — `run.ex:141-147` — broad `rescue _ -> :ok` on caller callback
Swallows all `:on_status` callback exceptions; caller bugs fail invisibly.
Narrow to known types or `Logger.warning`.

## SUGGESTION — `run.ex` `error_summary/1` ↔ `exceptions.ex` `describe/1` duplicate
Same error-reason→string mapping in two places; must stay in sync if
`Qx.Hardware` adds error shapes. Extract a shared helper or make
`RunError.describe/1` public and delegate.

## SUGGESTION — `run.ex:188-189` — dual atom/string key fallback on poll map
`Map.get(poll, :status) || Map.get(poll, "status")` implies an uncertain
upstream contract. Pin it (remove fallback if `Qx.Hardware` guarantees atom
keys) or add a test for the string-key path.

## Pre-existing / clean
- `application.ex:9` empty supervisor — correct for a library.
- `client.ex` `@known_keys` allowlist atomization — right pattern.
- `run_test.exs` `async: false` + process-dict stub — correct.
- `credentials_cell_test.exs` token-leak + SSRF coverage — thorough.
