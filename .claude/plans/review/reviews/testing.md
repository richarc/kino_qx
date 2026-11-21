# Test coverage review: chore/qx-0.13.1 (dep bump only)

## Verdict
No BLOCKER. A green default `mix test` is partial evidence only: real Req is covered via Bypass; real qx is barely exercised.

## Findings

### Q1 qx surface
- WARNING lib/kino/qx/run.ex:93,117 / test/support/stub_hardware.ex — `Qx.Hardware.run/3` and `cancel/3` are ALWAYS replaced by `_hardware_mod: StubHardware` in run_test.exs (lines 62-363). No default-run test calls real Qx.Hardware.run/cancel. Only live tests (excluded) do. Signature/return-shape drift in 0.13 would not be caught.
- WARNING lib/kino/qx/credentials_cell.ex:321 — `Hardware.connect/2` (real qx) has no default-run test. credentials_cell_test.exs only checks emitted source strings and state flags. Only covered by excluded :ibm_live (ibm_live_test.exs:78).
- Q1 answer on `Qx.draw_counts/2`: NOT called at runtime anywhere in lib/. It appears only in moduledoc/doc text (lib/kino/qx.ex:17,53; credentials_cell.ex:30) and in the generated-source docs. No test calls it, with or without mocks. Qx.OptionError risk is limited to users' own cells, and the doc example uses `title:`. SUGGESTION: confirm `title:` is still a valid draw_counts option in deps/qx 0.13 (I did not verify), since the docs/README advertise it. lib/kino/qx.ex:65 has `iex> is_binary(Kino.Qx.version())`. I did not check whether a doctest runs it.
- Real qx structs ARE exercised: run_test.exs builds `%Qx.Hardware.Config{}` (@enforce_keys: portal_url, portal_token, ibm_api_key, ibm_crn, ibm_region, backend) and `%Qx.SimulationResult{}` (stub_hardware.ex:58). Compile-time/struct-key breaks in 0.13 would fail the run. This is the one real qx coupling covered.

### Q2 Req
- Features used (lib/kino/qx/client.ex:89-99,149): `Req.new(url:, headers:, receive_timeout:, retry: false)`, `Req.get/1`, JSON auto-decode of body, `%Req.Response{}` pattern matching, `Req.Response.get_header/2` (list return), `{:error, exception}` with `%{reason: _}`.
- Tests use Bypass (real HTTP through real Req, client_test.exs:15). Not Req.Test, nothing bypassed. Covered: 200 + auto-decode, 401, 429 + retry-after (line 55, exercises get_header list shape, the key 0.7 risk), network down (line 68), authorization header. Good coverage for the 0.6 -> 0.7 jump.
- SUGGESTION: I did not read the req 0.7.x CHANGELOG, so I can't confirm no behaviour change affects the above. Note the retry-after path asserts `37`, which would catch a get_header shape change. Not verified whether 404, other-status (`{:http,...}`), and non-JSON bodies are tested (I read only the first 70 lines of client_test.exs).

### Q3 Output shape
- No VegaLite/SVG/draw_* assertions exist in lib/ or test/ (grep for VegaLite|svg|Draw: 0 matches). Nothing can pass vacuously, but the 0.13 rendering change is entirely untested here. kino_qx does not render qx output itself.

### Q4 Version pins
- None. test/kino/qx_test.exs:7 asserts only `~r/^\d+\.\d+\.\d+/`. Not stale. README.md:46 and mix.exs:46 already say ~> 0.13.1 (consistent).

### Pre-existing / unrelated
- test/test_helper.exs:12 — live tags excluded by default (intended); the release gate depends on running `--include portal_live`/`ibm_live` manually, which is the only real-qx coverage.

## Recommendation
Before the Hex release, run the excluded live tests (per test_helper.exs header) or at least a one-off check that `Qx.Hardware.run/3`, `cancel/3`, `connect/2` arities/returns match deps/qx 0.13. Consider adding a default-run test that calls the real `Qx.Hardware.connect/2` against a Bypass-backed portal, or a `function_exported?(Qx.Hardware, :run, 3)` contract test.

## Not verified
Tests were not run (no mix). qx and req 0.7 changelogs not read. Rest of client_test.exs, smart_cell_test.exs, credentials_cell_test.exs not read in full.
