# Scratchpad: kino-qx-circuit-pipeline

## Decisions

- **2026-05-14** — qx dep mode during development: **`{:qx, path: "../qx"}`**.
  Switch to `{:qx, "~> 0.7"}` at Phase 9.2 (after qx 0.7.0 is on Hex).
  Recorded per plan §Phase 0.3.

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
