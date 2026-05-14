# Progress: kino-qx-circuit-pipeline

**Started**: 2026-05-14
**Driver**: /phx:full
**Plan**: .claude/plans/kino-qx-circuit-pipeline/plan.md

## State

| Phase | Status | Notes |
|---|---|---|
| 0 — Pre-flight | COMPLETED | branch `feat/credentials-cell`; Qx.Hardware surface verified (7 fns); downstream handoff read |
| 1 — Deps & deletions | COMPLETED | mix.exs :qx path dep added; ibm_client + transpile_pipeline + their tests + client_transpile_test deleted; stub_clients IBM half stripped; 4 expected warnings in transpile_cell.ex (rewritten Phase 3) |
| 2 — Thin Client | COMPLETED | transpile/2 + POST internals + transpile-only error mappings removed; @known_keys trimmed; 9 client_test cases all green |
| 3 — CredentialsCell | COMPLETED | TranspileCell deleted; CredentialsCell written (kino_db secrets pattern — tokens via LB_* env vars, never in cell state, never in source); 18/18 cell tests green; full suite 41/41 green (4 expected warnings in ibm_live_test → Phase 6.2) |
| 4 — Kino.Qx.run/run! | COMPLETED | Kino.Qx.{Run, RunError, Interrupted} + Kino.Qx.{run, run!}/2,3 delegates; cancel watcher (unlinked spawn + Process.monitor) + frame status panel; `:_hardware_mod` test seam; 9 run_test cases green; full suite 50/50 |
| 5 — Demo notebook | COMPLETED | `notebooks/hardware_demo.livemd` — circuit-pipeline walkthrough with Livebook secrets setup; legacy transpile_demo deleted |
| 6 — Integration tests | COMPLETED | `ibm_live_test.exs` rewritten around `Qx.Hardware.connect/2` + `Kino.Qx.run!/2`; `portal_live_test.exs` trimmed to snippet endpoints only |
| 7 — Docs / CHANGELOG | COMPLETED | README rewritten for new pipeline + secrets model; CHANGELOG 0.2.0 entry replaced with BREAKING reset notes; `Kino.Qx` moduledoc refreshed |
| 8 — Local verify | COMPLETED | `mix format --check-formatted` clean; `mix compile --warnings-as-errors` clean; `mix test` 1 doctest + 48 tests + 0 failures + 4 excluded; `mix credo --strict` 0 warnings (2 design suggestions, style only) |
| 9 — Release prep | BLOCKED | gated on qx 0.7.0 on Hex (path dep until then); dialyzer + manual smoke are USER STEPs |

## Log

- 2026-05-14 — /phx:full started. Path-dep mode confirmed (per scratchpad).
- 2026-05-14 — Phase 0 completed (branch + verification, no destructive changes). Handed off to a fresh session before Phase 1 to keep context clean for the ~58 remaining tasks.
- 2026-05-14 — Phases 1–8 executed end-to-end. Mid-Phase-3 design pivot: the cell does NOT collect tokens (the plan's literal sketch would leak via the persisted .livemd source); adopted kino_db's Livebook-secrets pattern instead (`LB_PORTAL_TOKEN`, `LB_IBM_API_KEY`, `LB_IBM_CRN`). Recorded in scratchpad. Phase 9 blocked on qx 0.7.0 reaching Hex.
