# kino_qx — Livebook Smart Cells for Qx

> **Workspace context.** This repo lives inside the [`qxquantum`](../CLAUDE.md)
> multi-root workspace alongside [`qx/`](../qx/CLAUDE.md) (the core library)
> and [`qxportal/`](../qxportal/CLAUDE.md) (the Phoenix web app). Each repo
> is independent — its own git remote, branches, PRs, releases (Hex), and
> CI. Cross-repo changes ship as separate PRs: land in `qx/` or `qxportal/`
> first, then bump the dependency here. See `../CLAUDE.md` for the shared
> development model.
>
> **Stack:** Elixir library exposing two `Kino.SmartCell` components for
> [Livebook](https://livebook.dev) — "Qx Snippet" and "Qx Transpile +
> Submit". It is the bridge between a Livebook notebook, the `qxportal`
> JSON API (`/api/v1`), and cloud quantum simulators (IBM Quantum REST
> API). Runtime deps: `:kino`, `:req`, `:jason`.
>
> Lifecycle is driven by the `/elixir-phoenix` plugin (`/phx:*` skills) —
> the same plugin is used despite this not being a Phoenix app; only the
> non-web `/phx:*` commands apply (no LiveView, no Ecto, no Oban).
>
> Issues are tracked in `bd` for **bugs and deferred work only** — features
> live in `.claude/plans/<slug>/plan.md`, not in `bd`.

For the "what goes where" matrix (features → plan file, bugs/discovered/tech-debt → bd), see [`../CLAUDE.md`](../CLAUDE.md#2-beads-bd--bugs-and-deferred-work-only). A "new smart cell" counts as a feature and goes through `/plan`.

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
bd ready              # Find available bug / task work
bd show <id>          # View issue details
bd close <id>         # Complete work

mix compile --warnings-as-errors
mix format --check-formatted
mix test
```

## Rules

- Use `bd` for **bugs, deferred items, and discovered work** — NOT for feature planning
- Do NOT use TodoWrite, TaskCreate, or markdown TODO lists for ongoing work
- Features go through `/plan` → `/phx:work` → `/phx:verify` → `/phx:review` → `/pr`
- Cross-repo changes: ship upstream first, then bump the dep here in a separate PR
