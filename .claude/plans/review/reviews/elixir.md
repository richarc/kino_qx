# Review: chore/qx-0.13.1 (qx 0.11 -> 0.13.1 bump)

Status: Approved with warnings. No BLOCKERs.

## 1. qx call sites (verified)
- lib/ makes no executable `Qx.draw_*` calls. `Qx.draw_counts(title: ...)` appears only in docs (lib/kino/qx.ex:17,53; credentials_cell.ex:30). `:title` is accepted in 0.13.
  Verified against deps/qx/CHANGELOG.md 0.13.0: unknown draw options raise `Qx.OptionError`, and `:title` must be a string or nil. The CHANGELOG claim holds.
- Executable qx calls are only `Qx.Hardware.run/3` (run.ex:117, via `hardware_mod`), `Hardware.connect/1` (credentials_cell.ex:321), `cancel/3`, and the `%Qx.Hardware.Config{}` struct. All exist in deps/qx/lib/qx/hardware.ex:
  - `run/3` at line 134
  - `cancel/3` at line 241
  - `connect/2` at line 273
  - `:on_status` and `:timeout_ms` opts at lines 108-110
- Not verified: the `%Hardware.Config{}` field list and the `:on_status` event shapes (`{:ibm, :polling, ...}`, run.ex:309-317) were not diffed against 0.13.1. The qx changelog shows no Hardware API break, only internal changes (result tensors, mint bump).
- Nothing in lib/ uses a removed or renamed function.

## 2. Req 0.6.3 -> 0.7.5 (verified)
- The only Req use is lib/kino/qx/client.ex:89-99: `Req.new(url:, headers:, receive_timeout:, retry: false)` followed by `Req.get(request)`. It matches on `%Req.Response{status, body}` and `Req.Response.get_header/2` (line 149), and falls back to `{:error, exception}` for transport errors.
- The 0.7.0 breaking changes are:
  - `current_request_steps` removed.
  - `run_finch`, `put_plug` and `run_plug` replaced by adapter modules.
  - GET-to-POST on body (reverted in 0.7.3).
  - `put_params` overwrite.
  - `follow_redirects` and `output` steps removed.
  - None of these are used.
- JSON-only default decoding arrived in 0.6.0. The portal returns JSON (client_test.exs:20 notes the content-type), so `%{"data" => ...}` still decodes.
- Tests use Bypass, with no `Req.Test`, `plug:` or `adapter:`. No stub breakage.
- `Req.Response.get_header/2` returning a list is unchanged.

SUGGESTION: mix.exs:47 `{:req, "~> 0.5"}` now resolves anywhere from 0.5.x to 0.7.5, but only 0.7.5 is tested. Consider `~> 0.7` if you want the requirement to match what is tested. Not required.

## 3. README / CHANGELOG / mix.exs
- WARNING, README.md:148-151: the Compatibility table is stale. It lists only 0.2.x (`~> 0.7`) and 0.1.x, with no 0.4.x row (qx `~> 0.13.1`). The install snippet on lines 45-46 now disagrees with the table.
- WARNING, notebooks/hardware_demo.livemd:7: still has `{:qx, "~> 0.7", hex: :qx_sim}`. It has no `~> 0.13.1` pin, and its draw_counts call (line 76) is valid under 0.13. Update it to match the README.
- `~> 0.13.1` is sensible. qx's own README uses `~> 0.13.0`. The three-segment form excludes 0.13.0, which is acceptable, and 0.14 is blocked.
  - The CHANGELOG says "as qx asks of its dependents below 1.0". I did not find that wording in deps/qx. The README uses `~> 0.13.0`, which is itself three-segment. Reword or drop the attribution (SUGGESTION). Not verified.
- CHANGELOG.md:14-31 is accurate against mix.exs and what I read. mix.exs `@version` is 0.4.0, and the [Unreleased] heading is correct for a not-yet-bumped version. README `~> 0.4` is consistent with that.
- WARNING (release): since this is the Hex release gate, the version and date bump and the move of [Unreleased] into a release heading are still pending. Dependency range changes normally go with a version bump (0.4.1 or 0.5.0).
- README.md:46 and the CHANGELOG both state the same requirement, so they are consistent.

## 4. Docs
- No other stale qx requirement in lib/ docs. lib/kino/qx/smart_cell.ex:7 `{:kino_qx, "~> 0.1"}` is a pre-existing stale kino_qx pin (SUGGESTION).
- .claude/plans/** and CLAUDE.md:69 mention `~> 0.7`. These are historical or plan files and can be ignored.
- CHANGELOG.md:21 "Charts ... have the 0.13 look" is accurate. qx 0.13 changed the SVG and Vega-Lite spec content, and lib/ does not parse it. I confirmed nothing in lib/ inspects chart specs.

## Not verified
- I did not run mix deps.get, compile or tests (no Bash). The "73 tests" claim comes from the CHANGELOG only.
- I did not read mix.lock line by line.
