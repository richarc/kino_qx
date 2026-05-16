# kino_qx — Livebook Smart Cells for Qx

> **Workspace context.** This repo lives inside the [`qxquantum`](../CLAUDE.md)
> multi-root workspace alongside [`qx/`](../qx/CLAUDE.md) (the core library)
> and [`qxportal/`](../qxportal/CLAUDE.md) (the Phoenix web app). Each repo
> is independent — its own git remote, branches, and releases (Hex). No
> pull requests (one developer/reviewer). Cross-repo changes are
> separate per-repo commits: land + publish upstream (`qx`/`qxportal`)
> first, then flip the path dep → the published hex version here. See
> `../CLAUDE.md` for the shared development model.
>
> **Stack:** Elixir library exposing two `Kino.SmartCell` components for
> [Livebook](https://livebook.dev) — "Qx Snippet" and "Qx Credentials" —
> plus `Kino.Qx.run!/2,3`. It is the bridge between a Livebook notebook,
> the `qxportal` JSON API (`/api/v1`), and IBM Quantum hardware (via
> `Qx.Hardware` in the `:qx` library). Runtime deps: `:kino`, `:qx`,
> `:req`, `:jason`.
>
> Lifecycle is driven by the `/elixir-phoenix` plugin (`/phx:*` skills) —
> the same plugin is used despite this not being a Phoenix app; only the
> non-web `/phx:*` commands apply (no LiveView, no Ecto, no Oban).
>
> **`bd` (beads) is deprecated.** The existing `.beads/` database is
> retained for later extraction; do not create new `bd` issues, run
> `bd dolt push`, or rely on `bd` for tracking. All work — features
> and bug fixes alike — lives in `.claude/plans/<slug>/plan.md`.

The `/elixir-phoenix` plugin (`/phx:*` skills) is the **only** development
workflow — there is no other path, and the Iron Laws below are
non-negotiable (see the **Elixir Plugin — Mandatory Procedures** block at
the end of this file). All work is plan-file driven (see
[`../CLAUDE.md`](../CLAUDE.md) §2 for the workspace-wide rule). A "new
smart cell" counts as a feature and goes through `/phx:plan`; bugs and
discovered work are noted in the active plan's `scratchpad.md` or
`ROADMAP.md` and addressed on a `feat/<slug>` or `fix/<slug>` branch via
the normal `/phx:*` workflow.

## Project-specific notes

- This is a **library** (not an application server). Don't introduce a
  `GenServer`/`Supervisor` tree without a runtime reason; the host
  Livebook owns the runtime.
- The portal-side JSON API is locked at `/api/v1`. Treat changes to that
  contract as cross-repo work coordinated with `qxportal/`.
- HTTP is `:req` only. Do not add `:httpoison`, `:tesla`, `:finch`
  directly, or `:httpc`.
- Smart cell behaviour relies on stable JSON encode/decode; `:jason` is
  pinned explicitly even though it arrives transitively via `:kino`.
- Tests that talk to the portal or IBM Quantum must be tagged and
  excluded from the default `mix test` run; opt in explicitly when
  running them locally.

## Quick reference

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix test
```

## Rules

- `bd` (beads) is **deprecated** — do not create new `bd` issues or run `bd dolt push`; `.beads/` is retained read-only for later extraction
- Track work in `.claude/plans/<slug>/plan.md`; record bugs / discovered work / tech debt in the active plan's `scratchpad.md` or `ROADMAP.md`
- Do NOT use TodoWrite, TaskCreate, or markdown TODO lists for ongoing work
- **No pull requests** (one human developer/reviewer). All work: `git checkout -b feat/<slug>` (or `fix/<slug>`) → `/phx:plan` → `/phx:work` → `/phx:verify` → `/phx:review`. The `/plan`, `/implement`, `/pr` commands are retired — `/phx:*` only.
- **`/phx:review` is the merge gate** (replaces the PR review): code merges to `main` only after the verdict is PASS, or every finding is triaged (`/phx:triage`) and resolved. The human authorizes the merge; the agent runs the review, reports, and stops — it does not merge unreviewed work. Merge locally: `git merge --squash` + commit (tick the ROADMAP item in it), then `git push origin main`, `git branch -d`.
- **Push is backup only** — push branches and `main` freely; pushing **never** publishes. Releases are deliberate and tag-gated only.
- **Release** (only when a ROADMAP `## v0.X` section is fully checked): bump version + CHANGELOG; **flip `{:qx, path: "../qx"}` → `{:qx, "~> 0.7", hex: :qx_sim}` and re-run `/phx:verify`** (a path dep must never reach a published package); then `mix hex.publish` + tag `vX.Y.Z`. This is the single publish action.
- The `/phx:*` plugin is the only workflow; the Iron Laws in the Mandatory Procedures block below are non-negotiable.
- Cross-repo: ship upstream (`qx`/`qxportal`) first and publish it, then flip + bump the dep here (separate repo, separate commit).

<!-- ELIXIR-PHOENIX-PLUGIN:START -->
<!-- Tailored for kino_qx (pure Elixir library — Kino smart cells + HTTP; no Phoenix/Ecto/LiveView/Oban/Nx). Edit this block manually before re-running /phx:init --update or it will be overwritten with the full Phoenix-flavoured version. -->

# Elixir Plugin — Mandatory Procedures (kino_qx-tailored)

## SKILL EXECUTION ENFORCEMENT

These rules govern ALL `/phx:*` command execution. Violations invalidate the session output.

1. Skills are PROCEDURES, not suggestions. Every numbered step MUST execute.
2. Agent spawning is MANDATORY when a skill says "spawn" or "always run". Zero agents spawned when required = skill failure.
3. Every skill MUST produce its required artifact file (`.claude/plans/{slug}/`, etc.). Chat-only output without the artifact = skill failure.
4. "Already implemented" is a FINDING, not an exit. Document it in the artifact; do not bail out of the workflow.
5. Read SKILL.md BEFORE executing. Do not improvise a different workflow.
6. No unauthorized judgment calls. If the skill defines no early-exit, there is no early exit.
7. Agent output MUST be saved to `.claude/plans/{slug}/research/{agent-name}-report.md` before synthesis.

## EXECUTE BEFORE EVERY RESPONSE

### STEP 1: CLASSIFY
- Bug fix → score 0–2, skip to STEP 5
- Review/analysis → skip to response
- Feature (new/changed smart cell, `run!` pipeline, portal/IBM client) → continue

### STEP 2: COMPLEXITY SCORE

| Factor | Points |
|--------|--------|
| Single file change | 0 |
| 2–3 files | +2 |
| 4+ files or crosses module boundaries (CredentialsCell / SmartCell / Client / Run / exceptions) | +3 |
| New domain concept (new smart cell, new pipeline entry point) | +3 |
| Follows existing pattern | -2 |
| Touches the Smart Cell JS template or `to_source/1` | +3 |
| Changes public API of `Kino.Qx`, `Kino.Qx.run/run!`, or a `Kino.SmartCell` attrs/`to_source` contract | +3 |
| Changes the `qxportal` `/api/v1` contract or the `Qx.Hardware` call surface | +3 |
| External API or new dependency | +2 |

Show the calculation: `Complexity: {score} ({factors}) → {level}`.

### STEP 3: ROUTE

| Score | Action |
|-------|--------|
| ≤ 2 | Proceed directly, or offer `/phx:quick` |
| 3–6 | Ask 1–2 questions, then `/phx:plan` |
| 7–10 | Ask 2–4 questions, recommend `/phx:plan --detail comprehensive` |
| > 10 | Strongly recommend `/phx:full` |

### STEP 4: INTERVIEW (if score ≥ 3)

| Task type | Questions |
|-----------|-----------|
| New / changed smart cell | "What's in scope? Does `to_source/1` change? Any new persisted attrs?" |
| Public API change (`Kino.Qx.run/run!`) | "Breaking change? CHANGELOG entry? Major/minor bump (SemVer)?" |
| Portal `/api/v1` or `Qx.Hardware` surface | "Cross-repo? Does `qx`/`qxportal` need to ship first?" |

### STEP 5: LOAD references silently

| Pattern | Load |
|---------|------|
| `*_test.exs`, `test/support/` | testing, exunit-patterns |
| `lib/kino/qx/*smart_cell*.ex`, `*credentials_cell*.ex` | liveview-patterns (Kino SmartCell idioms), elixir-idioms |
| Any other `.ex` | elixir-idioms |

### STEP 6: SPAWN agents

| Trigger | Agent | When |
|---------|-------|------|
| `/phx:plan` invoked | hex-library-researcher | ALWAYS (evaluate hex deps before adding) |
| `/phx:review` invoked | elixir-reviewer, testing-reviewer, iron-law-judge | ALWAYS (parallel) |

(`phoenix-patterns-analyst`, `ecto-schema-designer`, `oban-specialist`, `liveview-architect`, `security-analyzer` for web auth — skipped: not a Phoenix app.)

### STEP 7: PROCEED

Respond. Honour the verification rules below.

---

## IRON LAWS — STOP if violated

If code would violate ANY of these:
1. STOP. 2. Show the problematic code. 3. Show the correct pattern. 4. Ask permission to apply the fix.

**Elixir / OTP**
1. NO `String.to_atom/1` on caller- or wire-supplied strings — atom-table exhaustion. kino_qx parses qxportal / IBM JSON; decode against an allowlist or keep strings. Use `String.to_existing_atom/1` only on a fixed known set.
2. NO process (GenServer / Agent / Task started under a supervisor) without a runtime reason. kino_qx is a *library*; the host Livebook owns the runtime. The `Kino.Qx.Run` monitored Task is justified (interrupt → cancel); a new long-lived process is not.

**Secrets / privacy invariant**
3. Credentials (portal token, IBM API key/CRN, IAM token) MUST NOT be persisted to the `.livemd`. Smart-cell `to_attrs/1` excludes them; `to_source/1` emits `System.fetch_env!` references, never literals. Error/status paths must not `inspect/1` a `%Qx.Hardware.Config{}` (route through `Kino.Qx.SafeReason`).

**Public API surface**
4. Breaking changes to `Kino.Qx`, `Kino.Qx.run/2,3`, `Kino.Qx.run!/2,3`, or a `Kino.SmartCell` attrs/`to_source` contract REQUIRE a CHANGELOG entry and a SemVer bump (minor pre-1.0 per this package's policy).
5. Public functions return `{:ok, _}` / `{:error, _}` or raise typed `Kino.Qx.*` exceptions (`Kino.Qx.RunError`, `Kino.Qx.Interrupted`) on misuse. Do not let raw `Req` / `Jason` / `Qx.Hardware` errors leak across the API boundary unmapped.

## VERIFICATION — MANDATORY after code changes

After ANY code change, before presenting results:

```
mix compile --warnings-as-errors && mix format --check-formatted && mix credo --strict
```

Offer `mix test` after meaningful changes. Live-network tests
(`:portal_live`, `:ibm_live`, `:ibm_submit`) are excluded by default and
are USER STEPS — never auto-run them (IBM bills per shot).

Do NOT present code as complete until verification passes.
<!-- ELIXIR-PHOENIX-PLUGIN:END -->
