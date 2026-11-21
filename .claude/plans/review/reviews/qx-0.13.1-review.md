# Review: chore/qx-0.13.1 (qx 0.11.0 -> 0.13.1)

- **Date:** 2026-11-21
- **Scope:** `git diff main...chore/qx-0.13.1` — one commit (3241d23), 4 files: `CHANGELOG.md`, `README.md`, `mix.exs`, `mix.lock`. No source or test changes.
- **Panel:** elixir-reviewer, testing-reviewer, iron-law-judge, verification-runner; compressed by context-supervisor (`../summaries/review-consolidated.md`).
- **Verdict:** **PASS WITH WARNINGS** — 0 blockers, 2 warnings on the diff, 1 release decision, 4 pre-existing items.

## Requirements Coverage

**NOT AVAILABLE** — no task ID or requirements source for this change.

Sources tried:
- `$ARGUMENTS`: free-text scope, not an ID or path
- Branch `chore/qx-0.13.1`: the `qx-0` regex hit is a version number, not an issue ID
- Commits since main: no issue reference
- `.claude/plans/`: existing plans (circuit-pipeline, transpile-cell, smart-cell-reeval, learner-chat) are unrelated to this dependency bump

## Verification (verification-runner, on the branch)

| Check | Result |
|---|---|
| `mix deps.get` | exit 0, lock unchanged |
| `mix compile --warnings-as-errors --force` | pass, 8 files, no warnings |
| `mix format --check-formatted` | pass |
| `mix credo --strict` | pass, no issues |
| `mix test` (default tags only) | 73 passed (72 tests + 1 doctest), 0 failures, 4 excluded |
| `mix hex.build` | exit 0, no warnings; kino_qx 0.4.0, deps kino ~> 0.19, qx_sim ~> 0.13.1, req ~> 0.5, jason ~> 1.4 |
| `mix hex.audit` | **exit 1** — cowboy 2.14.2, cowlib 2.16.0 (test-only via Bypass/plug_cowboy); usage_rules 1.2.6, igniter 0.8.2 (dev-only). No runtime dep of the published package is affected |
| `mix deps.unlock --check-unused` | **exit 1** — stale `:vega_lite` entry in `mix.lock` (also present on `main`; pre-existing) |
| `mix docs` | 22 warnings, including hidden-module references to `Qx.Hardware.Ibm` / `Qx.Hardware.Portal` (informational) |

Live-network tests (`:portal_live`, `:ibm_live`, `:ibm_submit`) were not run; they are user steps.

## Compatibility evidence

- **qx surface.** Executable qx calls in `lib/` are `Qx.Hardware.run/3`, `connect/2`, `cancel/3` and `%Qx.Hardware.Config{}`. `Qx.draw_counts/2` appears only in docs, with `:title`, which 0.13 accepts.
- **Hardware API diff (orchestrator check, published packages qx_sim 0.11.0 vs 0.13.1).** `lib/qx/hardware.ex` is byte-identical. `lib/qx/hardware/` differs by one line: an unused `:delete -> Req.delete(request)` branch removed from `ibm.ex` (`cancel_job` uses `:post`). The hardware call surface, Config struct and status events are therefore unchanged from what `main` already runs against. This covers the gap the testing and elixir reviewers could not verify.
- **Req 0.7.5.** Only use is `lib/kino/qx/client.ex:89-99` (`Req.new` with url/headers/`receive_timeout`/`retry: false`, `Req.get`, `%Req.Response{}`, `Response.get_header/2`). None of the 0.7.0 breaking changes touch it. `client_test.exs` goes through real Req over Bypass.
- **Iron Laws.** No violations. Law 3 not weakened (qx `Config` derives `Inspect` excluding the secret fields; `SafeReason` never inspects). No `path:` dep in `mix.exs`.

## Findings

### Warnings — in this diff

- **W1. `README.md:148-151` — Compatibility table is stale and now contradicts the install snippet.** The table stops at `0.2.x | ~> 0.7`; the snippet edited in this commit says `{:kino_qx, "~> 0.4"}` with qx `~> 0.13.1`. The README is the Hex package front page.
- **W2. `CHANGELOG.md:16` — unsupported claim.** "The requirement is now three-segment, as qx asks of its dependents below 1.0". Nothing in `deps/qx` asks this; qx's README recommends `~> 0.13.0`. The requirement itself (`~> 0.13.1`) is sensible; only the stated reason is unsupported.

### Release decision (not a defect)

- **D1. Version number: 0.4.1 or 0.5.0.** `mix.exs:4` is still `0.4.0` and the changelog entry is under `[Unreleased]`. The written policy ties minor bumps to API-contract breaks, so a patch is defensible. Precedent goes the other way: 0.4.0 was itself a qx-requirement bump shipped as a minor, and this one drops qx 0.11/0.12 for users and moves req 0.6 -> 0.7. iron-law-judge leans 0.5.0.

### Pre-existing (unchanged files)

- **P1.** `notebooks/hardware_demo.livemd:5-7` — pins `{:qx, "~> 0.7"}` and a machine-specific `path:` for kino_qx.
- **P2.** Default tests always stub `Qx.Hardware.run/3` / `cancel/3` (`run_test.exs`) and never call `Hardware.connect/2` (`credentials_cell.ex:321`). Mitigated for this change by the hardware API diff above.
- **P3.** `mix.lock` — stale `:vega_lite` entry (fails `deps.unlock --check-unused`).
- **P4.** `lib/kino/qx/smart_cell.ex:7` — stale `{:kino_qx, "~> 0.1"}`; `lib/kino/qx/safe_reason.ex:25-27` — moduledoc still calls the upstream Inspect fix a tracked bug.

### Suggestions

- `mix.exs:47` — `{:req, "~> 0.5"}` permits 0.5-0.7 but only 0.7.5 is tested; consider `~> 0.7`.
- If released as a patch, add a changelog sentence that users on qx below 0.13.1 must upgrade qx.
- `hex.audit` advisories are test/dev-only; clear them with a `mix deps.update` of bypass/plug_cowboy/usage_rules when convenient.

## Not verified

- Live IBM / portal paths (`:ibm_live`, `:ibm_submit`, `:portal_live`) — user steps, billed.
- Whether `notebooks/` ships in the Hex package (affects how much P1 matters).
