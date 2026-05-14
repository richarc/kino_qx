# Scratchpad: kino-qx-circuit-pipeline

## Decisions

- **2026-05-14** — qx dep mode during development: **`{:qx, path: "../qx"}`**.
  Switch to `{:qx, "~> 0.7"}` at Phase 9.2 (after qx 0.7.0 is on Hex).
  Recorded per plan §Phase 0.3.

- **2026-05-14 (Phase 3 mid-flight)** — Credentials cell **does NOT collect
  tokens in its UI**. The plan's literal sketch ("emits qx struct with
  transient tokens inline") is a privacy leak: Livebook persists the
  smart-cell-generated source into the `.livemd` file, so any token in
  `to_source/1` output would leak. Adopting the **kino_db pattern**
  instead — cell UI collects only persistable fields (portal URL,
  region, backend, opt level, shots); tokens come from Livebook
  secrets (`LB_PORTAL_TOKEN`, `LB_IBM_API_KEY`, `LB_IBM_CRN`). Connect
  reads them via `System.fetch_env!`; `to_source/1` emits code that
  also calls `System.fetch_env!`. Tokens never live in cell state, never
  enter the .livemd. Plan §Phase 3.6 amended below.

## Dead Ends (DO NOT RETRY)

(none yet)

## Open Questions

- Hex publish state of qx 0.7.0 — check at Phase 9.1 (`mix hex.info qx`).
- Confirm Hex shows no existing `kino_qx 0.2.0` before §9.4 (legacy plan never
  published, but the mix.exs has been at 0.2.0 — verify no accidental publish).

## Handoff

- Branch: `main` (create `feat/credentials-cell` at Phase 0.1)
- Plan: `.claude/plans/kino-qx-circuit-pipeline/plan.md`
- Interview: `.claude/plans/kino-qx-circuit-pipeline/interview.md` (Status: COMPLETE)
- Codebase scan: `.claude/plans/kino-qx-circuit-pipeline/research/codebase-scan.md`
- Upstream: `../qx/.claude/plans/qx-hardware/plan.md` (complete; `Qx.Hardware` shipped locally at 0.7.0)
- Next: open fresh session, run `/phx:work .claude/plans/kino-qx-circuit-pipeline/plan.md`
