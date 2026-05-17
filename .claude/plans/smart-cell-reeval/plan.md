# Plan: Qx Credentials smart cell — guided sequence + live rebind (Option B)

**Type:** feature / UX redesign of an existing smart cell
**Branch:** `fix/smart-cell-reeval` (already created from `main`)
**Complexity:** 7 (deep) — touches `to_source/1` + Smart Cell JS panels
(+3), changes the `Kino.SmartCell` source/attrs behavioural contract
(+3), crosses CredentialsCell↔Run mental boundary (+3), follows
existing Kino patterns (−2). No cross-repo impact: `Qx.Hardware` /
`/api/v1` untouched.

## Problem

`lib/kino/qx/credentials_cell.ex` emits `qx = %Qx.Hardware.Config{…}`
via `to_source/1`. Picking a backend after Connect updates the
generated **code text** but never rebinds the notebook `qx` binding
(`use Kino.SmartCell` has **no** reevaluate option), and `to_source/1`
emits `backend: ""` when unset — so a downstream `Qx.Hardware` run
fails with no actionable message until the user manually re-runs the
cell.

## Locked decisions (from user interview, 2026-05-17)

1. **Rebind:** enable Kino reevaluation so any Job-Defaults change
   re-runs the cell and rebinds `qx`. **API correction (verified, see
   research):** the option is **`:reevaluate_on_change`**, not
   `reevaluate_automatically`. kino 0.19.0 (pinned) supports it — **no
   kino bump**.
2. **Unset backend:** `to_source/1` emits a `raise` with a clear
   actionable message when `last_backend_name` is blank (never
   `backend: ""`).
3. **Gating:** in-cell only — NO cross-cell coupling to the Qx Snippet
   / `Kino.Qx.run!` path.
4. **Redesign extent:** full guided single sequence — Secrets hint →
   Portal & Region + Connect → Job Defaults (enabled only after
   Connect) → emit.

## Why this is safe (research-confirmed)

`reevaluate_on_change` re-evaluates only when `to_source/1` output
changes, i.e. when a **persisted attr** changes
(`portal_base_url, ibm_region, last_backend_name, optimization_level,
shots`). Connect's state (`connected/connecting/identity/backends_list`)
is **transient** (excluded from `to_attrs/1`), so enabling the option
does **not** re-trigger the network connect — no re-eval loop. The JS
already binds inputs on `change` (blur) + `ctx.handleSync`, so it does
**not** re-eval per keystroke on `shots`. Full detail:
`research/kino-smartcell-reevaluate-report.md`.

## Files in scope

| Path | Change | ~LOC |
|---|---|---|
| `lib/kino/qx/credentials_cell.ex` | `use … reevaluate_on_change: true`; guarded `to_source/1`; `ready?/1` helper; `client_payload` step/ready flags; rework inline `main.js`/`main.css` into a guided 3-step sequence with stepwise enablement | ~120 |
| `test/kino/qx/credentials_cell_test.exs` | TDD: guard vs struct, secrets-never-persisted, reopened-notebook, ready logic | ~140 |
| `mix.exs` | `@version "0.2.0"` → `"0.3.0"` | 1 |
| `CHANGELOG.md` | `## [Unreleased]` entry (behavioural contract change) | ~12 |

## Iron Law compliance (kino_qx-tailored)

| Law | How addressed |
|---|---|
| 1 no `String.to_atom` | none added; guard is a string/blank check |
| 2 no new process | none; reuses existing Connect `Task.start` |
| 3 secrets never persisted | `to_attrs/1` still excludes tokens; both `to_source/1` branches (guard + struct) emit only `System.fetch_env!` refs and no token literal — asserted by tests |
| 4 contract change → CHANGELOG + SemVer | Phase 3: minor bump 0.2.0→0.3.0 + CHANGELOG (pre-1.0 policy) |
| 5 typed errors | the `raise` is emitted **into notebook code** (intentional fail-fast UX), not across kino_qx's API boundary — library functions still return tuples / typed errors |

## Phased implementation (TDD — tests fail first)

### Phase 1 — Behavioural core: guarded `to_source/1` + reevaluate
- [x] [P1-T1][testing] Add tests in
      `test/kino/qx/credentials_cell_test.exs`: (a) `to_source/1` with
      blank `last_backend_name` returns code containing a `raise` with
      the actionable message and **no** `%Qx.Hardware.Config{}`;
      (b) with a backend set, returns the struct with `backend:` set;
      (c) both branches contain `System.fetch_env!` and **no**
      `LB_`-prefixed value nor any token literal; (d) `to_attrs/1` map
      has exactly the 5 persisted keys, no token keys. Tests fail first.
      — Done. Rewrote `to_source/1` describe into two: backend-set
      (struct, with default-fallback test rewritten per user approval)
      + blank-backend guard (D2). (c) interpreted as the privacy
      invariant per scratchpad (raise branch has no fetch_env — that's
      correct, not a contradiction). (d) already covered by existing
      `to_attrs/1` tests — not duplicated. TDD red confirmed: 3 new
      guard tests fail, struct tests pass.
- [x] [P1-T2] Add a private `ready?/1` (or `config_ready?/1`) deciding
      blank-backend vs ready from attrs; implement the guarded
      `to_source/1` (blank → `raise "Qx Credentials: select a backend
      (Connect, then choose a backend) before running."`; else current
      struct). Keep `System.fetch_env!` token refs unchanged.
      — Done. `config_ready?/1` = non-blank binary `last_backend_name`
      (nil/""/whitespace/non-binary → false). Guard branch emits a
      single `raise` line; struct branch unchanged (fetch_env refs
      intact).
- [x] [P1-T3] Add `reevaluate_on_change: true` to
      `use Kino.SmartCell, name: "Qx Credentials"`. Add a test
      asserting the option is set (introspect
      `Kino.SmartCell` registration / module metadata; if not
      introspectable, assert behaviour: changing `shots` attr yields a
      changed `to_source/1` string — document the chosen approach in
      scratchpad).
      — Done. Option added. Not introspectable w/o Kino runtime
      (verified vs kino 0.19.0 source) — used the plan's behavioural
      fallback (backend pick & shots change → different `to_source/1`);
      approach recorded in scratchpad "RESOLVED testing question".
- [x] [P1-T4] Verify: `mix compile --warnings-as-errors && mix format
      --check-formatted && mix credo --strict && mix test
      test/kino/qx/credentials_cell_test.exs`.
      — PASS: compile clean, format clean, credo 0 issues, 27 tests
      0 failures (TDD red→green).

### Phase 2 — Guided single-sequence UI (in-cell only)
- [x] [P2-T1][testing] Extend tests for `client_payload/1`: add a
      `ready` (and/or `step`) flag derived from
      connected + backend-chosen; assert it reflects state
      transitions. Tests fail first.
      — Done. Tested the pure `cell_step/2` derivation (matches the
      `valid_ibm_region?/1` `@doc false`-public convention; testing the
      whole `client_payload/1` would expose the runtime payload). 3
      tests, fail-first confirmed (UndefinedFunctionError).
- [x] [P2-T2] Add the `ready`/`step` field to `client_payload/1`
      (transient only — NOT in `to_attrs/1`).
      — Done. `cell_step/2` (`true,backend→%{step:3,ready:
      backend_chosen?}`; else `%{step:2,ready:false}`).
      `config_ready?/1` refactored onto shared `backend_chosen?/1`.
      `client_payload/1` adds `step`/`ready`; `to_attrs/1` untouched
      (existing key-set test still green → invariant held).
- [x] [P2-T3] Rework inline `asset "main.js"` into a guided 3-step
      sequence: Step 1 Secrets hint; Step 2 Portal & Region + Connect
      (Step 3 disabled/greyed until `connected`); Step 3 Job Defaults
      with a visible "pick a backend to finish" affordance until a
      backend is chosen. **Preserve**: `change` (blur) listeners,
      `ctx.handleEvent("update", …)`, `ctx.handleSync` change-flush,
      `__remembered__` saved-backend handling. Update `main.css` for
      step states. No new pushed events beyond existing ones.
      — Done. `<ol class="qx-steps">` 3-step sequence; `setStepState`
      drives active/done/locked from `step`/`ready`; step-3 inputs
      `disabled` + `.qx-step-locked` (pointer-events:none) until
      connected; `#qx-finish-hint` shows the contextual affordance.
      All 6 listeners, `connect` click, `handleEvent("update")`,
      `handleSync`, `__remembered__` preserved verbatim. No new
      pushEvents. CSS: step list/badges/finish states; fixed
      `.qx-hint` indent (no label column now) + conn-status no longer
      inherits the uppercase head.
- [x] [P2-T4] Verify gate (compile/format/credo + cell test file).
      — PASS: compile clean, format clean, credo 0 issues, 30 tests
      0 failures. (Checkbox tick was missed in the work session;
      corrected here — review verifier flagged the bookkeeping gap.)

### Phase 3 — Docs & release prep
- [x] [P3-T1] `mix.exs`: `@version "0.2.0"` → `"0.3.0"`.
      — Done.
- [x] [P3-T2] `CHANGELOG.md` under `## [Unreleased]`: note the
      behavioural change — cell now reevaluates on change and rebinds
      `qx`; emits a raising guard instead of `backend: ""`; guided
      panel sequence. Call out the visible behaviour change (cell
      auto-re-runs on field change; an unconfigured cell now raises a
      clear message instead of silently producing a bad config).
      — Done. Added `### Changed` (reevaluate+rebind, guided 3-step)
      and `### Fixed` (raising guard vs silent bad config) under
      `## [Unreleased]`; visible behaviour change called out.

### Phase 4 — Final verification
- [x] [P4-T1] Full gate: `mix compile --warnings-as-errors && mix
      format --check-formatted && mix credo --strict && mix test`
      (live-network tests `:portal_live`/`:ibm_live` stay excluded —
      USER step, never auto-run).
      — PASS: compile clean, format clean, credo 0 issues, full suite
      1 doctest + 73 tests 0 failures, 4 excluded (`:ibm_live`,
      `:portal_live`, `:ibm_submit`).
- [ ] [P4-T2] Manual Livebook smoke (USER step — JS not Elixir-unit
      testable; checklist in scratchpad): fresh cell raises actionable
      message before backend; Connect → pick backend → `qx` rebinds
      automatically and a downstream run works; reopened `.livemd` with
      saved backend auto-emits a valid `qx`; changing shots re-runs on
      blur (not per keystroke).
      — PENDING USER. Not auto-run (JS is not Elixir-unit-testable);
      6-point checklist in scratchpad "P4-T2 manual Livebook smoke".
      Code/automated gates all green; this is the only remaining item.

### Phase 5 — Post-review hardening (/phx:review PASS WITH WARNINGS, user-approved fix)
- [x] [P5-T1][testing] TDD red: `to_source/1` must not interpolate a
      non-integer `optimization_level`/`shots` from a hostile `.livemd`
      into emitted (auto-reevaluated) source; struct branch must be
      syntactically valid; guard loop must cover non-binary backend
      types; sentinel scan over nil/%{}; shots-change asserts both
      struct. — Done; injection test fails first against raw
      interpolation.
- [x] [P5-T2] WARNING-1 fix: `to_source/1` routes
      `optimization_level`/`shots` through the existing
      `parse_optimization_level/1`/`parse_shots/1` via
      `parsed_or_default/2` (defaults 1 / 4096). Tightened both binary
      clauses `{n, _}` → `{n, ""}` so trailing garbage is rejected
      cleanly (defense-in-depth; JS never sends trailing garbage).
- [x] [P5-T3] Verify: compile/format/credo clean; full suite
      1 doctest + 76 tests, 0 failures, 4 excluded. TDD red→green.
      Review verdict items WARNING-1/2/3 resolved; PRE-EXISTING items
      (`backend_known?(_,"")`, `redact_reason` reachability,
      `connect_error_message` coarse mapping) left as tracked
      out-of-scope (scratchpad) — not regressions of this change.

## Risks / self-check (deep)

1. **Auto-eval + raising guard = visible error mid-setup.** With
   `reevaluate_on_change`, changing region before choosing a backend
   auto-evaluates the raising guard → an error in the cell output.
   *Intended* fail-fast, but must not feel broken: the guided sequence
   disables Job Defaults until connected and the raise message is
   instructional; CHANGELOG documents the new behaviour. Acceptable.
2. **JS guided sequence is not Elixir-unit-testable.** Mitigation:
   keep the JS change minimal and behaviour-preserving (same pushed
   events, same sync hooks); cover Elixir surface by tests; gate UI on
   the P4-T2 manual checklist (user step).
3. **Reopened notebook with a saved backend that no longer exists on
   reconnect** emits a valid-looking struct that may 404 at run-time.
   Pre-existing behaviour, **out of scope** — recorded in scratchpad
   as discovered work, not fixed here.

## Verification (every phase + final)

```
mix compile --warnings-as-errors && mix format --check-formatted && \
  mix credo --strict && mix test
```
Live-network tagged tests are user-run only — never auto-run (IBM bills per shot).

## Next step

Present plan; on approval run `/phx:work
.claude/plans/smart-cell-reeval/plan.md` (recommended fresh session).
