# Learner Chat — `kino_qx` half

**Status:** brainstorm complete, ready for `/phx:plan .claude/plans/learner-chat/interview.md`
**Slug:** `learner-chat`
**Cross-repo sibling:** `qxportal/.claude/plans/learner-chat/interview.md` (server, API, RAG, logging)
**Date:** 2026-06-16

## Problem & goal

Learners working through qxquantum.com tutorials in Livebook need an
in-notebook chat to ask clarifying questions. This plan covers the
**Livebook half**: a new `Kino.Qx.Chat` smart cell that talks to the
chat API exposed by `qxportal`. The server, RAG, and question log are
in the qxportal sibling plan.

This work is a downstream consumer of the qxportal API. Per the
workspace cross-repo rules, during development this depends on the
local qxportal API via plain HTTP to `http://localhost:4000` (or a
configured base URL). No `path:` dep is involved because kino_qx
already talks to qxportal over HTTP via `Kino.Qx.Client`.

## Locked decisions

### New smart cell — `Kino.Qx.Chat`

- Lives at `lib/kino/qx/chat_cell.ex`, registered as a Kino smart
  cell with kind `"qx_chat"` and human name `"Qx — Tutor Chat"`.
- Modeled on the existing `Kino.Qx.SmartCell` (`run.ex`) and
  `CredentialsCell` patterns. Re-uses `Kino.Qx.Client` for the HTTP
  call.
- Cell UI: a scrollable conversation pane + a single-line input +
  send button. Renders Markdown for assistant turns (Qx code blocks
  syntax-highlighted if cheap, plain otherwise).
- Cell attributes persisted in `.livemd` source:
  - `tutorial_id` (string, set when pre-baked into a tutorial,
    empty when the learner inserts the cell themselves)
  - `api_base_url` (defaults to the `Kino.Qx.Client` default)
- Conversation history is **in-memory cell state**, not persisted to
  the `.livemd` source. Closing the notebook loses the history — by
  design (matches the stateless API decision).

### Auth — re-use the credentials cell

- The chat cell does not handle credentials directly. It reads the
  same API token the existing `Kino.Qx.CredentialsCell` produces (the
  cell asks the learner to add a credentials cell above it if one
  isn't present, same UX as `Kino.Qx.Run`).
- All API calls add `Authorization: Bearer <token>`.

### Per-turn request shape

POST `<api_base_url>/api/v1/chat` with body:

```json
{
  "tutorial_id": "quantum_state_and_qubit",
  "messages": [
    {"role": "user", "content": "..."},
    {"role": "assistant", "content": "..."},
    {"role": "user", "content": "the new question"}
  ]
}
```

- Cell sends the last 10 turns (server also caps at 10, oldest
  dropped first).
- Response: `{"reply": "...", "model": "claude-haiku-4-5",
  "rag_sources": ["qx/lib/qx/measurement.ex", ...]}`. Sources
  rendered as a small footer under the reply.

### Error handling in the cell

- `HTTP 401` → "Please add a Qx credentials cell above this one."
- `HTTP 429 {retry_after_seconds}` → friendly inline message
  ("You're asking quickly — come back in N seconds"), send button
  disabled with a countdown.
- `HTTP 503 {reason: "daily_budget_exceeded"}` → "The tutor is
  resting for the day, try again tomorrow."
- Network / 5xx → "Something went wrong, try again." + log the
  error to the Livebook output (not silently swallowed).

### Streaming

- **No streaming in v1.** Cell shows a "thinking…" spinner, swaps in
  the full reply when it arrives. Streaming is deferred to a later
  ticket because it requires server-sent events on the qxportal side
  too.

## Pre-baked into tutorials

The actual `.livemd` files live in `qxportal/priv/static/tutorials/`,
so the edit lives in the qxportal plan. From kino_qx's side, the
contract is: **the smart cell must work both when pre-baked
(`tutorial_id` set) and when a learner inserts it themselves in their
own notebook (`tutorial_id` empty)**.

## Files & contexts touched (rough)

New:
- `lib/kino/qx/chat_cell.ex` (smart cell)
- `test/kino/qx/chat_cell_test.exs`
- Possibly `lib/kino/qx/client_chat.ex` if the chat call doesn't fit
  cleanly into `Kino.Qx.Client`; otherwise extend `client.ex`.

Changed:
- `lib/kino_qx/application.ex` — register the new smart cell on
  application start (same pattern as the existing `Run` cell).
- `mix.exs` — bump `@version` for the next release; no new deps
  expected (uses existing `req` via `Kino.Qx.Client`).
- `CHANGELOG.md`
- `README.md` if the cell list is documented there

## Open questions intentionally deferred

- Markdown rendering library choice in the cell — likely re-use
  whatever Kino exposes; if nothing, plain text is acceptable for v1.
- Whether the cell should show the `rag_sources` inline or behind a
  disclosure — UX call during `/phx:plan`.
- Persisting history into the `.livemd` source as base64 — deferred;
  privacy implications.

## Out of scope for v1

- Streaming token-by-token assistant replies
- Per-cell "ask about this output" widget
- Storing chat history on the Livebook side
- Any work on `qxportal` (covered in the sibling plan)
