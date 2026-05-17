# Research: Kino.SmartCell reevaluate + source lifecycle

> Source: hex-library-researcher ended early (turn limit) after the key
> correction; findings below VERIFIED directly via
> `mix usage_rules.docs Kino.SmartCell` / `usage_rules.search_docs -p kino`
> against the pinned kino 0.19.0.

## 1. The option name (CRITICAL correction)

The option is **`:reevaluate_on_change`**, NOT `reevaluate_automatically`
(the name used in the locked decision). HexDocs `Kino.SmartCell` →
"Other options":

> `:reevaluate_on_change` — if the cell should be reevaluated whenever
> the generated source code changes. ... Defaults to `false`.

Passed as a `use` option:
`use Kino.SmartCell, name: "Qx Credentials", reevaluate_on_change: true`.

## 2. Version

`mix.exs`: `{:kino, "~> 0.19"}`; `mix.lock`: kino **0.19.0**. The
option is present in 0.19.0 docs → **no kino version bump needed**.

## 3. Lifecycle (what triggers re-eval)

- `reevaluate_on_change: true` ⇒ Kino re-evaluates the cell whenever the
  **generated source** (`to_source/1` output) changes.
- `to_source/1` is recomputed from `to_attrs/1`. So a re-eval fires
  exactly when a **persisted attr** changes:
  `portal_base_url, ibm_region, last_backend_name, optimization_level,
  shots` (the `to_attrs/1` map).
- Transient assigns (`connected, connecting, identity, backends_list,
  error`) are NOT in `to_attrs/1` ⇒ they do **not** change `to_source`
  ⇒ they do **not** trigger a re-eval.

## 4. Connect is safe under reevaluate_on_change (key finding)

The network side-effect (`Qx.Hardware.connect/2`) runs in
`handle_event("connect", …)` via `Task.start`, and its result lands in
`handle_info({:connect_result, …})` which sets only **transient**
assigns. Because none of that is in `to_attrs/1`, enabling
`reevaluate_on_change` will **not** re-run connect, and there is no
re-eval loop. The side-effecting call is correctly behind the explicit
Connect button; `to_source/1` stays pure. ✅ The chosen approach is
sound.

## 5. The per-keystroke pitfall is already mitigated

`asset "main.js"` binds every input via `addEventListener("change", …)`
(blur/commit), not `"input"`. `#qx-shots` is `<input type="number">`
with a `change` listener, and `ctx.handleSync` dispatches a `change` on
the focused element before evaluation. So `reevaluate_on_change` fires
on blur/commit, NOT per keystroke. No debounce work required; preserve
these `change` listeners + `handleSync` in the redesign.

## 6. "Not ready" source pattern

Kino has no sanctioned "skip evaluation" return from `to_source/1`; the
idiomatic fail-fast is to emit code that **raises** with a clear
message. That matches locked decision (2): emit a guarded `raise` when
`last_backend_name` is empty, instead of `backend: ""`.

## Implications for the plan

1. Locked decision (1) wording corrected: use `:reevaluate_on_change:
   true`.
2. Guard in `to_source/1`: when `last_backend_name` blank → emit a
   `raise "...Select a backend in the Qx Credentials cell..."`; else
   the normal struct. Under `reevaluate_on_change`, picking a backend
   flips source guard→struct and Kino auto-rebinds `qx`.
3. Reopened `.livemd`: `last_backend_name` is a persisted attr loaded in
   `init/2`; with `reevaluate_on_change` a saved notebook auto-emits a
   valid `qx` on load (UX win) — must be covered by a test.
4. No new deps, no kino bump. Contract change to `to_source` ⇒
   CHANGELOG + SemVer **minor** bump (0.2.0 → 0.3.0) per Iron Law #4 +
   CHANGELOG policy.
