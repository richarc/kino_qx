# Scratchpad: kino-qx-circuit-pipeline

## Decisions

- **2026-05-14** — qx dep mode during development: **`{:qx, path: "../qx"}`**.
  Switch to `{:qx, "~> 0.7"}` at Phase 9.2 (after qx 0.7.0 is on Hex).
  Recorded per plan §Phase 0.3.

- **2026-05-16** — §9.2 was front-loaded prematurely (`381d4a2` switched
  to `{:qx, "~> 0.7", hex: :qx_sim}` and PR #1 opened). Then
  `mix test --include ibm_live` exposed an **upstream `Qx.Hardware.connect/2`
  bug**: it rejects a blank `backend`, but the CredentialsCell (and the
  live test) must call connect with no backend yet to discover the
  backends list — so first-time "Connect" is broken for every user.
  **Decision (user):** do NOT cut a qx release per debugging bug.
  Reverted kino_qx to `{:qx, path: "../qx"}` so local qx fixes are
  picked up immediately; iterate freely against the path-linked qx;
  cut a single **qx 0.7.1** (batching this `connect/2` fix + the
  already-filed `qx-o9h` Inspect-redaction) only when integration
  testing is complete and confident. §9.2 (Hex switch) is the LAST
  step before publish, not before debugging is done.

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

## Remediation notes (2026-05-15)

- **Discovered during R7:** `test/kino/qx/credentials_cell_test.exs`
  carried a pre-existing stray **NUL byte** (offset 6274, predates
  this branch — old git blob was already "Bin"). It compiled fine but
  made `git diff` treat the file as binary, which would have hidden
  the R3.3/R5.2 test additions from PR review. Stripped with
  `tr -d '\0'`; re-added the trailing-space `"us-south "` reject case
  that the strip had collapsed to the *valid* `"us-south"`. File is
  now UTF-8 text; full suite green. In-scope (this remediation already
  edits that file) — not filed to bd.
- **R2.1 stub seam change:** `StubHardware` moved off the process
  dictionary to `:persistent_term` because `run/3` now runs the
  hardware call in a worker `Task` (different process). Required for
  the interrupt tests to see the scripted return/events.

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

- 22:48 WARN: requirements-verifier Write to reviews/ was sandbox-denied; orchestrator persisted reviews/requirements-remediation.md from agent message. X1 corrected UNCLEAR→MET (qx-o9h verified via bd show this session). 17 MET / 0 UNMET.
- 22:49 WARN: security-analyzer Write to reviews/ sandbox-denied; orchestrator persisted reviews/security-remediation-review.md from agent message. Verdict PASS WITH WARNINGS — B1/W5 CLOSED, R2 SOUND, no BLOCKER.

## 2026-05-15 — Phase 9 complete; PR open, awaiting human gate

- qx published v0.7.0 → Hex `qx_sim 0.7.0`. Downstream dep bumped to
  `{:qx, "~> 0.7", hex: :qx_sim}` — NOTE the `hex: :qx_sim` is required
  (hex package name ≠ app name; bare `{:qx, "~> 0.7"}` won't resolve).
- Branch `feat/credentials-cell` @ `d3b46d9`, pushed, in sync with origin.
  Gates green: compile/format clean, 65 tests +1 doctest 0 failures,
  credo 167 mods 0 issues.
- **PR #1 open**: https://github.com/richarc/kino_qx/pull/1 — STOP here.
  Human reviews + merges (workflow human gate; agent must not self-merge).
- Remaining after merge (all USER STEPS): §8.4 portal_live, §8.5 ibm_live,
  §8.7 dialyzer, §8.8 Livebook manual smoke, §9.4 `mix hex.publish` (kino_qx 0.2.0).
- Upstream follow-up filed: `qx-o9h` (Config @derive Inspect hardening) in qx's bd.

## 2026-05-16 — Plan COMPLETE & shipped; manual check done. Deferred → kino_qx 0.2.1

Released this cycle: qx **0.7.0** + **0.7.1** (connect/2 discovery fix +
Config Inspect redaction / qx-o9h), kino_qx **0.2.0** (PR #1 merged).
Manual Livebook visual check of `notebooks/hardware_demo.livemd`
performed and **working end-to-end on real IBM hardware**.

The connect failure hit during the manual check was an **environment
issue, not a code bug**: portal returned `{:portal, :unauthorized}`
(401) because the `LB_PORTAL_TOKEN` didn't match the portal being hit
(token/portal-instance mismatch). Resolved by the user; no code change.

bd is deprecated → recording these here per the workflow (discovered
work → scratchpad). **Batch into a single kino_qx 0.2.1 — do NOT
release per-bug.** Verify with the path-dep posture (notebook
`Mix.install` → `{:kino_qx, path: ".."}`) before publishing.

1. **Error masking (significant UX bug, blocks debugging).**
   `Kino.Qx.Run.SafeReason.describe/1` AND `credentials_cell.ex`
   `connect_error_message/1` + `redact_reason/1` only match **bare**
   error atoms/tuples (`:unauthorized`, `{:network,_}`, `{:http,_,_}`).
   `Qx.Hardware` ALWAYS wraps errors as `{stage, reason}` (e.g.
   `{:portal, :unauthorized}`, `{:config, %Qx.Hardware.ConfigError{}}`).
   None of the bare clauses match the stage-wrapped envelope, so every
   real failure collapses to "unexpected error" — made a 401 and a
   "you didn't pick a backend" both undebuggable.
   Fix: decompose `{stage, reason}` first (recurse on `reason`,
   prefix with `stage`), and surface typed
   `Qx.Hardware.{ConfigError,NoMeasurementsError}` `.message`
   (safe — no credential fields). Correct copy often already exists
   (e.g. the `:unauthorized` clause) but is unreachable. Same defect
   in two modules — fix both, keep `%Config{}` redaction + the
   unknown-shape → fixed-string guard intact (security contract).
   Add regression tests for the stage-wrapped shapes.

2. **Notebook bad default.** `notebooks/hardware_demo.livemd` ships
   `portal_base_url: "https://localhost:4000"` (https + localhost
   never works against a normal dev server; misleads local testers).
   Default to the hosted portal (`https://test.qxquantum.com`) or
   document the `http://localhost:PORT` requirement inline.

3. (Minor) Demo `Mix.install` pin: `~> 0.7` vs `~> 0.7.1` — either is
   fine; `~> 0.7.1` guarantees the connect fix. Decide when doing #2.

NOT to be committed: any local working-session state in
`hardware_demo.livemd` (baked-in `http://localhost:4000` / `ibm_fez` /
generated `%Config{}` block / Livebook stamp). Canonical demo keeps an
empty smart cell (`attrs: "e30"`). Revert/stash local notebook edits.
