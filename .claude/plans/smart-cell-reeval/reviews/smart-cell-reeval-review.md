# Review — smart-cell-reeval (kino_qx, branch `fix/smart-cell-reeval`)

Date: 2026-05-17 · Reviewer: /phx:review (6 parallel specialist agents)
Scope (diff vs `main`, uncommitted): `lib/kino/qx/credentials_cell.ex`,
`test/kino/qx/credentials_cell_test.exs`, `mix.exs`, `CHANGELOG.md`.

> Subagents could not Write into `kino_qx/` (harness allows `qx/` +
> `qxportal/` only). All sections below are **EXTRACTED FROM AGENT
> MESSAGES** per the /phx:review missing-file fallback; consolidated by
> the main agent. Logged in scratchpad.

## VERDICT: PASS WITH WARNINGS

No Iron Law violation, no UNMET requirement, no security defect in new
code, all automated gates green. Two WARNING-class items worth a
conscious decision before merge (one security-hardening, amplified by
this change; the rest test-strengthening). The two agent-labelled
"BLOCKER"s were triaged down (one pre-existing & mitigated by this very
change; one is correct-behaviour-but-under-tested).

## Requirements Coverage (verifier — plan.md)

18 MET · 0 PARTIAL · 0 UNMET · 1 UNCLEAR · 1 NOT-VERIFIABLE (user step)

- All D1–D4, P1/P2/P3 tasks, preservation constraints (6 listeners,
  `handleEvent`/`handleSync`, `__remembered__`, exactly 6 pushEvents),
  and Iron-Law table items: **MET** with `file:line` evidence.
- UNCLEAR: P2-T4 verify-gate checkbox not ticked — **bookkeeping only**;
  P4-T1 (full suite, 0 failures) supersedes it. → fixed in plan.
- NOT VERIFIABLE: P4-T2 manual Livebook smoke (USER step).

## Gate (verification-runner) — PASS

compile `--warnings-as-errors` clean · `format --check-formatted` clean
· `credo --strict` 0 issues · `mix test` 1 doctest + 73 tests, 0
failures, 4 excluded (`:ibm_live`/`:portal_live`/`:ibm_submit` — correct).

## Iron Laws (iron-law-judge) — PASS 5/5

No `String.to_atom`; no new process; secrets never persisted (both
`to_source/1` branches emit only `System.fetch_env!` *names*;
`step`/`ready` transient, not in `to_attrs/1`); contract change →
0.2.0→0.3.0 + CHANGELOG; the emitted `raise` is notebook-source text,
not raised across kino_qx's API (library fns still return tuples).

## Security (security-analyzer) — PASS (new code)

Guard branch is a constant sigil (no interpolation). Struct branch
`inspect/1`s `portal_url`/`region`/`backend` → hostile `.livemd`
strings materialise as inert data, cannot break the literal even under
`reevaluate_on_change`. JS: `innerHTML` only on static templates;
payload-derived values use `.textContent`/`createElement` — no XSS
sink. SSRF allowlist unchanged.

## Findings (triaged)

### WARNING-1 — `to_source/1` interpolates `optimization_level`/`shots` un-revalidated (`credentials_cell.ex:245-246`)
`opt_level = attrs["optimization_level"] || 1` then `#{opt_level}` —
**not** `inspect/1`'d, **not** re-validated. `init/2` and `to_source/1`
do not re-check these (only `handle_event` does). A hand-crafted
`.livemd` with `"optimization_level" => "0\n  System.cmd(...)"` injects
verbatim into emitted notebook code. **Pre-existing** interpolation,
but this change adds `reevaluate_on_change: true`, which amplifies the
blast radius (field edits auto-re-evaluate the emitted source). Cheap
fix: route through the existing `parse_optimization_level/1` /
`parse_shots/1` with a safe fallback. (security-analyzer assumed these
were range-checked — inaccurate for the persisted-attr path;
elixir-reviewer's read is the careful one.)

### WARNING-2 — struct branch of `to_source/1` never asserted parseable (`credentials_cell_test.exs:108-118`)
Guard branch is `Code.eval_string`'d; the more complex struct branch
(heredoc + multiple `inspect/1`) has no syntax assertion. A broken
heredoc/`inspect` would only fail at Livebook-eval time. Add
`assert {:ok, _} = Code.string_to_quoted(out)` for the struct branch.

### WARNING-3 — guard/sentinel test type-coverage gaps (`credentials_cell_test.exs:164-187`)
`to_source/1` guard loop covers `""`/`"   "`/`nil`/`%{}` but not
non-binary (`42`/`:atom`/`[]`) — though `cell_step/2` tests *do* cover
`42`, and `backend_chosen?(_) -> false` is correct. Sentinel
`refute … "System.fetch_env!"` only checks `""`, not `nil`/`%{}`.
Shots-change test asserts `a != b` but not that both are the struct
branch. All are **test-strengthening on correct behaviour**, not
defects (this is why testing-reviewer's "BLOCKER" was triaged to
WARNING).

### PRE-EXISTING (not introduced by this diff; informational)
- `credentials_cell.ex` `backend_known?(_ctx, "")` returns `true`
  (elixir-reviewer "BLOCKER"). Unchanged code; the new D2 guard +
  `config_ready?/1` now *mitigate* the downstream harm (blank → raise,
  never a bad `qx`). Optional hardening: make blank a no-op in
  `update_backend`.
- `Integer.parse/1` accepts trailing garbage (`{n, _}`); ties into
  WARNING-1 defense-in-depth.
- `redact_reason(:unauthorized)` unreachable via the
  `connect_error_message/1` catch-all — cosmetic, dropped as noise.
- `connect_error_message/1`/`redact_reason/1` coarse error collapse —
  already tracked in scratchpad as a separate `fix/`.

## SUGGESTIONS (low priority)
`cell_step/2` nil+blank combo; comment that the literal portal URL ==
`@default_portal_base_url`; lock `http://localhost` (no port) in
`validate_portal_url/1` tests.

## Disposition
Planned scope is fully implemented, verified, and Iron-Law-clean.
WARNING-1 is the only item that interacts with *this* change's risk
surface (reevaluate amplifies a pre-existing latent injection). It is
small and self-contained — fix-now or track as a follow-up `fix/` is a
human decision; it does not invalidate the planned UX/rebind work.
WARNING-2/3 are test hardening.
