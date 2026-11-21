# Iron Law Review: chore/qx-0.13.1 vs main (kino_qx project laws)

Checked 5 of 5 project laws plus the release rule: 0 BLOCKERs, 1 WARNING, 2 SUGGESTIONs.

## WARNING

### Law 4: version bump not yet decided (mix.exs:4, CHANGELOG.md:10)
- mix.exs `@version` is still "0.4.0", and the CHANGELOG entry sits under `[Unreleased]`. That is correct for a branch, but the release commit needs a version.
- The SemVer policy is in CHANGELOG.md:5-8 and CLAUDE.md:166. The header says breaking changes to the *portal API contract* are a minor bump until 1.0. Law 4 says breaking changes to the `Kino.Qx` / `run` / `run!` / smart-cell attrs and `to_source` contract need a minor bump.
- This diff changes none of those surfaces. No `lib/` file changed, and the smart cell's attrs and `to_source` are untouched.
- The qx requirement moves from `~> 0.11` to `~> 0.13.1`. That forces users off qx 0.11/0.12, and under 0.x that is a breaking change in the dependency tree, though not in kino_qx's own API.
- Precedent: 0.4.0 was a qx requirement bump (`~> 0.7.1` to `~> 0.10`). It shipped as a minor release.
- Recommendation: a patch (0.4.1) is defensible under the written policy, because the policy ties minor bumps to API-contract breaks.
  - If a Livebook user who pins qx 0.11/0.12 elsewhere would be broken, prefer 0.5.0 for consistency with the 0.4.0 precedent.
  - The `req` 0.6 to 0.7 move is a transitive change in a dep kino_qx calls directly. That is one more reason to lean minor.
- The CHANGELOG entry is present and adequate. It covers:
  - the requirement change
  - the lock change
  - the transitive bumps (req, mint, finch and others)
  - the `Qx.OptionError` note
  - test counts
- It has no explicit "may be breaking for users on qx < 0.13.1" sentence. Add one if you release as a patch.

## SUGGESTION

### Law 5: SafeReason collapses qx exception structs to "unexpected error" (pre-existing, not introduced here)
- lib/kino/qx/safe_reason.ex:60.
- qx 0.13 `Qx.Hardware.run/3` returns `{:error, ConfigError | NoMeasurementsError}` (deps/qx/lib/qx/hardware.ex:103, 471, 478), `{:config, exception}`, and `{:ibm_job_failed, %{status:, reason:}}`.
- Those shapes reach `describe/1` as structs or maps and hit the catch-all. No leak, but the message is unhelpful.
- Consider `describe(%{__exception__: true} = e)` returning `Exception.message(e)`, but only if the message cannot embed a Config. I could not verify that.
- Not a release blocker.

### Law 5: new qx exception types are not mapped (accepted risk)
- `Qx.OptionError` and the other raising `Qx.*` types are not mapped by kino_qx.
- This is acceptable here. kino_qx's own code only calls `Qx.draw_counts/2` in docs and the generated source, and passes `title:` only (lib/kino/qx.ex:17, 53).
- `Kino.Qx.run/run!` only wraps `Qx.Hardware.run`, which uses tagged tuples.
- A raise inside the worker Task (run.ex:117) surfaces as `exit(reason)` at run.ex:160. That path is pre-existing and unchanged.

## Other checks

- **Law 5, Req 0.7 (client.ex:89-121):** `Req.new(url:, headers:, receive_timeout:, retry: false)` and `Req.get` are still valid options. I found nothing in the deps that changes the `{:error, exception}` shape, so the `{:network, _}` mapping is intact.
  - Not verified: I did not diff the Req 0.6.3 and 0.7.5 changelogs line by line, and I did not run the test suite.
  - Pre-existing: smart_cell.ex:195 and :199 call `inspect(reason)` and `inspect(other)` on Client errors. The Client's reason holds no token, since the token only lives in the request headers.
- **Law 3 (secrets), no weakening:**
  - deps/qx/lib/qx/hardware/config.ex:105 has `@derive {Inspect, except: [:portal_token, :ibm_api_key, :ibm_crn, :access_token]}`. This is an improvement on the upstream side.
  - The struct's new or other fields (`identity`, `backends_list`, `iam_url`, `base_url`, `token_expires_at`) hold no secrets.
  - SafeReason's Config clauses (safe_reason.ex:44-49) still match `%Config{}`, and its catch-all never calls `inspect`.
  - The stale moduledoc at safe_reason.ex:25-27 says the upstream fix is "tracked as a qx bug". It is now shipped, so update the doc, a trivial change.
  - credentials_cell.ex:306-319 builds Config from env vars only, and no literal secrets appear in `lib/`.
- **Law 1 (String.to_atom):** unchanged. `grep String.to_atom lib/` finds nothing. client.ex:142 uses an allowlist.
- **Law 2 (processes):** unchanged. No source change, and the monitored Task and watcher in run.ex are pre-existing and justified.
- **Release rule:** mix.exs has no `path:` dependency (grep count 0). The qx dep is `hex: :qx_sim` with `~> 0.13.1`.
- **Not verified:** I did not read the other changed files (README.md, mix.lock) in full, and I did not run mix compile, credo or test.
