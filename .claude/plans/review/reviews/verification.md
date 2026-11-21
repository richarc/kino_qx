# Verification Report (chore/qx-0.13.1)

Project tools: compile, format, credo. No dialyzer, sobelow, ex_check, or check aliases in mix.exs.

| Step | Status | Details |
|------|--------|---------|
| deps.get | PASS (exit 0) | Lock satisfied; mix.lock unchanged (git status clean) |
| compile --warnings-as-errors --force | PASS (exit 0) | 8 files, no warnings |
| format --check-formatted | PASS (exit 0) | |
| credo --strict | PASS (exit 0) | 18 files, 168 mods/funs, no issues |
| mix test (default) | PASS (exit 0) | 73 passed (1 doctest, 72 tests), 0 failures, 4 excluded (ibm_live, portal_live, ibm_submit). Matches CHANGELOG. |
| hex.audit | FAIL (exit 1) | Transitive advisories only: cowboy 2.14.2 (1 HIGH, 2 MEDIUM), cowlib 2.16.0 (4 HIGH, 3 MEDIUM, 1 LOW incl. CVE-2026-59248), usage_rules 1.2.6 (LOW), igniter 0.8.2 (LOW). cowboy/cowlib come via plug_cowboy (Bypass, test only). usage_rules/igniter are dev only. Not runtime deps of the published package. |
| deps.unlock --check-unused | FAIL (exit 1) | Unused entry in mix.lock: `:vega_lite` (stale lock entry; likely left by the Kino/qx bump). Not auto-fixed. |
| hex.outdated | info | credo 1.7.18->1.7.19, ex_doc 0.40.1->0.40.5, usage_rules 1.2.6->1.3.1. qx 0.13.1, req 0.7.5, kino 0.19.1, jason 1.4.5 and bypass are current. |
| mix docs (dev) | PASS, 22 warnings | Includes "documentation references module Qx.Hardware.Ibm / Qx.Hardware.Portal but it is hidden" (credentials_cell.ex:62, client.ex:11), plus others in CHANGELOG.md. Informational. |
| hex.build | PASS (exit 0) | No warnings. kino_qx 0.4.0. Deps: kino ~> 0.19, qx_sim ~> 0.13.1 (app: qx), req ~> 0.5, jason ~> 1.4. Tarball deleted. |

Tracked files: git status clean at the end. No changes to restore. The generated tar was removed.

Note: the Hex package version is still 0.4.0; the branch doesn't bump it.

## Overall: PASS on code gates (compile, format, credo, tests, build). Two non-code hygiene findings to decide on: stale `vega_lite` lock entry (`mix deps unlock --unused`) and hex.audit advisories in test/dev-only transitive deps.
