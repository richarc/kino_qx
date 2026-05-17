# Scratchpad: smart-cell-reeval

## Locked decisions (user interview, 2026-05-17)

- **D1 Rebind:** enable Kino reevaluation. **CORRECTION:** the option
  is `:reevaluate_on_change` (a `use Kino.SmartCell` option), NOT
  `reevaluate_automatically` (the name in the original ask). Verified
  via `mix usage_rules.docs Kino.SmartCell` against pinned kino 0.19.0.
  No kino version bump needed. See
  `research/kino-smartcell-reevaluate-report.md`.
- **D2 Unset backend:** `to_source/1` emits a `raise` with an
  actionable message when `last_backend_name` blank — never
  `backend: ""`.
- **D3 Gating:** in-cell only. No cross-cell coupling to
  `Kino.Qx.run!` / Qx Snippet cell (Kino cells are independent;
  cross-cell signalling is fragile — explicitly rejected).
- **D4 Redesign:** full guided single sequence (Secrets → Portal &
  Region + Connect → Job Defaults), stepwise enablement.

## Why reevaluate_on_change is safe here (key reasoning)

`reevaluate_on_change` re-evals only when `to_source/1` output changes
= when a persisted attr changes. Connect sets only transient assigns
(`connected/connecting/identity/backends_list/error`), excluded from
`to_attrs/1`, so it does NOT change source → NOT re-trigger connect.
Side-effecting network call stays behind the explicit Connect button;
`to_source/1` pure. No re-eval loop.

## Dead-ends / rejected

- **Cross-cell gating** of the Qx Snippet/run path (D3): rejected —
  Kino smart cells are independent; no clean shared mechanism, fragile.
- **`reevaluate_automatically`**: not a real Kino option — wrong name;
  correct option is `:reevaluate_on_change`.
- Returning `""`/no-op from `to_source/1` for the not-ready state:
  Kino has no sanctioned "skip eval" return; idiomatic fail-fast is an
  emitted `raise` (→ D2).

## Implementation decisions (work session 2026-05-17)

- **Existing test rewrite APPROVED by user (2026-05-17).** The
  pre-existing test `"falls back to safe defaults when attrs are
  sparse"` (credentials_cell_test.exs:157) asserts `to_source(%{})`
  emits `backend: ""` in a `%Qx.Hardware.Config{}` — this contradicts
  D2. User explicitly chose **"Rewrite it for the new contract"**:
  sparse/blank-backend attrs now assert a `raise` + no `Config{}`;
  the other default-fallback checks (portal_url/region/opt/shots)
  move into the backend-set test. This is the documented human
  approval required by the TDD "don't modify existing tests" rule.
- **Plan P1-T1(c) wording interpretation.** Plan says "both branches
  contain `System.fetch_env!`". A pure `raise` guard branch cannot and
  need not contain `System.fetch_env!` (raise short-circuits; emitting
  fetch_env there is non-idiomatic and pointless). The binding
  invariant is the **privacy** one: *neither* branch contains a token
  literal or a real secret value. Tests therefore assert: struct
  branch → the three `System.fetch_env!("LB_…")` refs present + no
  token literal; raise branch → no `Config{}`, no token literal. The
  "both branches contain System.fetch_env!" phrase is treated as plan
  imprecision, resolved in favour of D2 + P1-T1(a). No user block —
  intent (no-leak in both branches) is unambiguous.
- **P1-T1(d) already covered.** `to_attrs/1` "exactly 5 keys / no
  token keys" is already asserted by existing tests
  (`"exactly the documented keys"` :79, `"NEVER includes any
  token-shaped field"` :44). Not duplicated — a duplicate wouldn't
  "fail first" and adds noise.

## RESOLVED testing question (P1-T3, 2026-05-17)

Verified against kino 0.19.0 source: `reevaluate_on_change` is **not
introspectable without the Kino runtime**. `use Kino.SmartCell` stores
it in compile-time `@smart_opts` (deps/kino/.../smart_cell.ex:332);
the only public module fn `__smart_definition__/0`
(smart_cell.ex:364) exposes just kind/module/name. The flag is read
at runtime in `Kino.SmartCell.Server.init/1`
(smart_cell/server.ex:77) from `init_opts` — needs a booted server.

**Chosen approach (plan-sanctioned fallback):** assert the behavioural
*premise* the option keys off — `to_source/1` output changes when a
persisted attr changes (backend pick: guard→struct; shots change) —
and cover the actual live rebind in the P4-T2 manual smoke. These
tests can't "fail-first" on the flag (the flag has no unit-observable
effect; the plan explicitly anticipates this). Not a TDD-judgment
violation — it's the path P1-T3 itself prescribes.

## P4-T2 manual Livebook smoke checklist (USER step — JS not unit-testable)

1. Fresh Qx Credentials cell, before choosing a backend → cell output
   is the actionable raise message (not a bad `qx`).
2. Fill secrets → set Portal URL/region → Connect → Job Defaults
   becomes enabled.
3. Pick a backend → cell auto-re-evaluates; `qx` is bound with the
   chosen `backend:`; a downstream `Kino.Qx.run!`/`Qx.Hardware` run
   works WITHOUT manually regenerating the cell.
4. Change `shots` → re-eval happens on blur/commit, NOT per keystroke.
5. Save + reopen the `.livemd` (persisted `last_backend_name`): cell
   auto-emits a valid `qx` on load without reconnect.
6. Secrets never appear in the generated source or saved `.livemd`.

## Discovered / out-of-scope (NOT fixed here)

- Reopened notebook may carry a persisted `last_backend_name` that no
  longer exists / is offline on reconnect → emits a valid-looking
  struct that 404s/errs at run time. Pre-existing; out of scope for
  this plan. Candidate future `fix/`: re-validate the saved backend
  against the refreshed `backends_list` post-Connect and warn.
- The portal-side `connect`/discovery error mapping in
  `credentials_cell.ex` (`connect_error_message/1` + `redact_reason/1`)
  collapses every `Qx.Hardware` `{:error, {stage, reason}}` to
  "unexpected error" (diagnosability bug found 2026-05-16 while
  investigating the original connect failure). Separate `fix/` in
  kino_qx — NOT in this plan's scope (this plan is the UX/rebind
  redesign only).

## Review session (2026-05-17)

- [WARN] Review subagents cannot Write into kino_qx (harness allows
  qx/ + qxportal/ only, not kino_qx/). Findings extracted from each
  agent's completion message per the /phx:review missing-file
  fallback; consolidated review written by the main agent (which can
  Edit kino_qx). All such sections marked "EXTRACTED FROM AGENT MSG".
