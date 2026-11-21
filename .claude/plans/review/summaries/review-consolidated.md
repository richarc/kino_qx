# Consolidated Review Summary: chore/qx-0.13.1 vs main

**Strategy**: Index (inputs ~5k tokens; kept near-complete because all BLOCKER/WARNING items must be preserved)
**Input**: 4 files (elixir.md, testing.md, iron-laws.md, verification.md)
**Scope**: qx 0.11.0 -> 0.13.1 dependency bump, no lib/ changes. Diff files: CHANGELOG.md, README.md, mix.exs, mix.lock. Merge gate before a Hex release.
**Tags**: NEW = in the diff files. PRE-EXISTING = unchanged files (some are triggered by the bump).

## Verdict
- BLOCKERs: none from any agent.
- Elixir: "Approved with warnings". Testing: "No BLOCKER", green default `mix test` is partial evidence only. Iron-laws: 0 BLOCKER, 1 WARNING, 2 SUGGESTION. Verification: PASS on code gates, 2 hygiene findings.

## BLOCKERs
None.

## WARNINGs

### W1. Version bump and release heading undecided (NEW: mix.exs:4, CHANGELOG.md:10)
Reported by iron-law-judge (Law 4; kept per deconfliction) and elixir-reviewer (same code). Verification also notes the package is still 0.4.0.
- Evidence: mix.exs `@version` is "0.4.0". The CHANGELOG entry is under `[Unreleased]`. The SemVer policy is at CHANGELOG.md:5-8 and CLAUDE.md:166.
- Iron-laws: this diff changes no Kino.Qx / run / run! / smart-cell attrs / to_source surface and no lib/ file. The qx requirement moves `~> 0.11` to `~> 0.13.1`, which forces users off qx 0.11/0.12 (a breaking change in the dependency tree under 0.x). Precedent: 0.4.0 was a qx requirement bump (`~> 0.7.1` to `~> 0.10`) and shipped as a minor. The req 0.6 -> 0.7 move is transitive but kino_qx calls req directly.
- DISAGREEMENT / positions:
  - iron-law-judge: 0.4.1 (patch) is defensible under the written policy, because the policy ties minors to API-contract breaks. It prefers 0.5.0 if a user pinning qx 0.11/0.12 elsewhere would break, for consistency with the 0.4.0 precedent, and leans minor because of req. If released as a patch, add an explicit "may be breaking for users on qx < 0.13.1" sentence to the CHANGELOG (absent now).
  - elixir-reviewer: a dependency range change normally goes with a version bump (0.4.1 or 0.5.0). The version and date bump and the move of [Unreleased] into a release heading are pending. It does not choose between them.
- The CHANGELOG entry is otherwise adequate (iron-laws) and accurate (elixir): it covers the requirement, lock, transitive bumps, OptionError note and test counts.

### W2. README Compatibility table stale (NEW: README.md:148-151)
Elixir-reviewer. The table lists only 0.2.x (`~> 0.7`) and 0.1.x, with no 0.4.x row (qx `~> 0.13.1`). The install snippet at README.md:45-46 disagrees with the table. README.md:46 and the CHANGELOG state the same requirement (consistent). Testing also confirms README.md:46 and mix.exs:46 say `~> 0.13.1`.

### W3. notebooks/hardware_demo.livemd:7 still pins `{:qx, "~> 0.7", hex: :qx_sim}` (PRE-EXISTING file, made stale by the bump)
Elixir-reviewer. It has no `~> 0.13.1` pin. Its draw_counts call (line 76) is valid under 0.13. Update it to match the README.

### W4. Real `Qx.Hardware.run/3` and `cancel/3` never run in default tests (PRE-EXISTING: lib/kino/qx/run.ex:93,117, test/support/stub_hardware.ex)
Testing-reviewer. `_hardware_mod: StubHardware` replaces them in every run_test.exs test (lines 62-363). Only excluded live tests call the real functions, so signature or return-shape drift in 0.13 would not be caught.
- Elixir-reviewer partly covers this: it verified in deps/qx/lib/qx/hardware.ex that `run/3` (line 134), `cancel/3` (241), `connect/2` (273) and the `:on_status` / `:timeout_ms` opts (108-110) exist. This is an existence/arity check, not a runtime one.

### W5. Real `Hardware.connect/2` has no default-run test (PRE-EXISTING: lib/kino/qx/credentials_cell.ex:321)
Testing-reviewer. credentials_cell_test.exs checks only emitted source strings and state flags. Only the excluded :ibm_live test (ibm_live_test.exs:78) covers it. Elixir-reviewer verified that `connect/2` exists (hardware.ex:273).

## SUGGESTIONs (grouped)

**Requirement and dependency wording**
- (NEW, mix.exs:47) `{:req, "~> 0.5"}` now resolves 0.5.x to 0.7.5, but only 0.7.5 is tested. Consider `~> 0.7`. (elixir-reviewer; testing-reviewer's note that the Bypass tests cover the 0.6 -> 0.7 jump supports the current tested state.)
- (NEW, CHANGELOG.md) The wording "as qx asks of its dependents below 1.0" was not found in deps/qx. qx's README uses `~> 0.13.0`. Reword or drop the attribution. (elixir-reviewer) `~> 0.13.1` itself is judged sensible; it excludes 0.13.0 and blocks 0.14.
- (NEW, mix.lock) Hygiene: the stale `:vega_lite` entry is listed under Verification below.

**Stale docs (PRE-EXISTING)**
- lib/kino/qx/smart_cell.ex:7 `{:kino_qx, "~> 0.1"}` is a stale pin. (elixir-reviewer)
- lib/kino/qx/safe_reason.ex:25-27 moduledoc says the upstream Config-inspect fix is "tracked as a qx bug"; it has shipped (deps/qx/lib/qx/hardware/config.ex:105 `@derive {Inspect, except: [...]}`). Trivial doc update. (iron-law-judge)
- .claude/plans/** and CLAUDE.md:69 mention `~> 0.7`; historical, ignorable. (elixir-reviewer)

**Error mapping (PRE-EXISTING)**
- lib/kino/qx/safe_reason.ex:60: qx 0.13 `Qx.Hardware.run/3` returns `{:error, ConfigError | NoMeasurementsError}` (hardware.ex:103, 471, 478), `{:config, exception}` and `{:ibm_job_failed, %{status:, reason:}}`. These hit the catch-all as "unexpected error". There is no leak, but the message is unhelpful. Consider `describe(%{__exception__: true} = e)` using `Exception.message(e)`, but only if the message cannot embed a Config. (iron-law-judge)
- New `Qx.OptionError` and other raising `Qx.*` types are not mapped. Accepted risk: lib/ only mentions `Qx.draw_counts/2` in docs, and `run`/`run!` wrap `Qx.Hardware.run` (tagged tuples). A raise in the worker Task (run.ex:117) surfaces as `exit(reason)` at run.ex:160, unchanged. (iron-law-judge; elixir-reviewer and testing-reviewer agree draw_counts is docs-only: lib/kino/qx.ex:17,53; credentials_cell.ex:30)

**Test coverage (PRE-EXISTING)**
- The 0.13 chart/SVG/Vega-Lite output change is entirely untested here. No VegaLite/svg/Draw matches in lib/ or test/. Nothing passes vacuously, and kino_qx does not render qx output. Elixir-reviewer independently confirmed that nothing in lib/ inspects chart specs. (testing-reviewer)
- Recommended before release: run the excluded live tests (`--include portal_live` / `ibm_live`, per the test_helper.exs header at line 12), or do a one-off arity/return check. Consider a default-run Bypass-backed test of real `Qx.Hardware.connect/2`, or a `function_exported?(Qx.Hardware, :run, 3)` contract test. (testing-reviewer)

**Positive findings**
- Req 0.7 usage is safe: only `Req.new(url:, headers:, receive_timeout:, retry: false)` and `Req.get/1` (client.ex:89-99), `%Req.Response{}` matching and `Req.Response.get_header/2` (line 149). None of the 0.7.0 breaking changes are used. Bypass tests exercise real Req (200 + decode, 401, 429 + retry-after asserting 37 which would catch a get_header shape change, network down, authorization header). (elixir, testing, iron-laws agree)
- Secrets (Law 3) not weakened. Upstream Config now derives Inspect with secrets excluded. SafeReason still matches `%Config{}` (safe_reason.ex:44-49). No literal secrets in lib/ (credentials_cell.ex:306-319 uses env vars). Laws 1 (no String.to_atom; client.ex:142 allowlist) and 2 (processes unchanged) are clean. Release rule met: no `path:` dep in mix.exs, qx is `hex: :qx_sim ~> 0.13.1`. (iron-law-judge)
- Real qx structs `%Qx.Hardware.Config{}` and `%Qx.SimulationResult{}` are built in run_test.exs / stub_hardware.ex:58, so struct-key breaks would fail the run. This is the one real qx coupling covered. (testing-reviewer)
- test/kino/qx_test.exs:7 asserts only a version regex, so there are no stale version pins. (testing-reviewer)
- Pre-existing, no token leak: smart_cell.ex:195,199 call `inspect(reason)` / `inspect(other)` on Client errors; the token lives only in request headers. (iron-law-judge)

## Verification results (verification agent; exact)
Tools in project: compile, format, credo. No dialyzer, sobelow, ex_check or check aliases.

| Step | Result |
|---|---|
| deps.get | PASS, exit 0. Lock satisfied; mix.lock unchanged (git status clean) |
| compile --warnings-as-errors --force | PASS, exit 0. 8 files, no warnings |
| format --check-formatted | PASS, exit 0 |
| credo --strict | PASS, exit 0. 18 files, 168 mods/funs, no issues |
| mix test (default) | PASS, exit 0. 73 passed (1 doctest, 72 tests), 0 failures, 4 excluded (ibm_live, portal_live, ibm_submit). Matches CHANGELOG |
| hex.audit | FAIL, exit 1 (see below) |
| deps.unlock --check-unused | FAIL, exit 1 (see below) |
| hex.outdated | info: credo 1.7.18->1.7.19, ex_doc 0.40.1->0.40.5, usage_rules 1.2.6->1.3.1. qx 0.13.1, req 0.7.5, kino 0.19.1, jason 1.4.5 and bypass are current |
| mix docs (dev) | PASS with 22 warnings (informational), incl. "documentation references module Qx.Hardware.Ibm / Qx.Hardware.Portal but it is hidden" (credentials_cell.ex:62, client.ex:11) and others in CHANGELOG.md |
| hex.build | PASS, exit 0, no warnings. kino_qx 0.4.0. Deps: kino ~> 0.19, qx_sim ~> 0.13.1 (app: qx), req ~> 0.5, jason ~> 1.4. Tarball deleted |

- **NEW (mix.lock), stale lock entry**: `deps.unlock --check-unused` exit 1: unused entry `:vega_lite` in mix.lock, likely left by the Kino/qx bump. Not auto-fixed. Fix: `mix deps.unlock --unused`. (Not raised by elixir-reviewer or iron-law-judge, who did not read mix.lock fully.)
- **hex.audit advisories (exit 1)**, all transitive: cowboy 2.14.2 (1 HIGH, 2 MEDIUM); cowlib 2.16.0 (4 HIGH, 3 MEDIUM, 1 LOW, incl. CVE-2026-59248); usage_rules 1.2.6 (LOW); igniter 0.8.2 (LOW). cowboy/cowlib come via plug_cowboy (Bypass, test only). usage_rules/igniter are dev only. The agent says these are not runtime deps of the published package. Whether this diff changed those lock versions is not stated, so NEW vs PRE-EXISTING is undetermined.
- The git working tree was clean at the end; nothing to restore.
- Overall (agent): PASS on code gates; two non-code hygiene items to decide on.

## Not verified (by agent, with cross-coverage)
| Agent | Not verified | Covered elsewhere? |
|---|---|---|
| elixir-reviewer | Did not run deps.get, compile or tests (no Bash); the "73 tests" claim came from the CHANGELOG only | Yes: verification ran them (73 passed, exit 0) |
| elixir-reviewer | Did not read mix.lock line by line | Partly: verification ran deps.get (lock unchanged) and found the stale `:vega_lite` entry. No agent reviewed the lock diff line by line |
| elixir-reviewer | `%Hardware.Config{}` field list and `:on_status` event shapes (`{:ibm, :polling, ...}`, run.ex:309-317) not diffed against 0.13.1 | Partly: testing-reviewer says run_test.exs builds the real Config struct (enforce_keys listed) and tests pass; iron-law-judge listed new Config fields (identity, backends_list, iam_url, base_url, token_expires_at). `:on_status` shapes: no one covers them |
| elixir-reviewer | CHANGELOG "as qx asks of its dependents below 1.0" wording not found in deps/qx | No |
| testing-reviewer | Tests not run | Yes: verification |
| testing-reviewer | Whether `title:` is still a valid draw_counts option in qx 0.13 | Yes: elixir-reviewer verified against deps/qx/CHANGELOG.md 0.13.0 (`:title` accepted; must be string or nil; unknown options raise `Qx.OptionError`) |
| testing-reviewer | Whether a doctest runs `is_binary(Kino.Qx.version())` (lib/kino/qx.ex:65) | Partly: verification reports 1 doctest passed; which one it is is not stated |
| testing-reviewer | qx and req 0.7 changelogs not read | Yes: elixir-reviewer read both (qx 0.13.0 notes, req 0.7.0 breaking changes) |
| testing-reviewer | Whether 404, other-status (`{:http, ...}`) and non-JSON bodies are tested; only the first 70 lines of client_test.exs read; smart_cell_test.exs and credentials_cell_test.exs not read in full | No |
| iron-law-judge | Did not diff the req 0.6.3 vs 0.7.5 changelogs line by line; did not run the suite | Yes: elixir-reviewer (changelog) and verification (suite) |
| iron-law-judge | Did not read README.md and mix.lock in full; did not run compile, credo or test | Partly: elixir-reviewer read README; verification ran compile/credo/test and covered the lock |
| iron-law-judge | Whether `Exception.message/1` of qx exceptions could embed a Config (SafeReason suggestion) | No |

## Disagreements and differences recorded
- Version bump size: see W1 (iron-law-judge leans patch-defensible/minor-preferred; elixir-reviewer says 0.4.1 or 0.5.0, undecided).
- Severity of the stale `:vega_lite` and hex.audit items: verification calls them non-code hygiene findings to decide on; elixir and iron-laws did not raise them.
- Confidence in qx coverage: elixir-reviewer finds "nothing in lib/ uses a removed or renamed function" (static read); testing-reviewer says a green `mix test` is only partial evidence because real qx calls are stubbed (W4/W5). These are compatible, but the combined assurance is static-only for run/cancel/connect.

## Coverage
| File | Represented | Key items |
|---|---|---|
| elixir.md | Yes | 3 WARNINGs (W1 shared, W2, W3), 3 suggestions, positives, 4 not-verified |
| testing.md | Yes | 2 WARNINGs (W4, W5), 2 suggestions, positives, 4 not-verified |
| iron-laws.md | Yes | 1 WARNING (W1, kept per deconfliction), 2 suggestions, positives/checks, 3 not-verified |
| verification.md | Yes | 9 command results, 2 failing gates (hex.audit, stale vega_lite), 1 docs warning group |

## Coverage Gaps
None.
