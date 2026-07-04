# Changelog

All notable changes to `kino_qx` will be documented in this file. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Every breaking change to the [portal API contract](https://qxportal.dev/api/v1/docs)
is a **minor** bump on this package until v1.0.

## [Unreleased]

## [0.4.0] - 2026-07-04

### Dependencies

- Bumped `qx` to `{:qx, "~> 0.10", hex: :qx_sim}` (from `~> 0.7.1`).
  No code changes needed: the smart cell's generated source and the
  run surface are untouched by qx 0.10's draw rework. Doc examples and
  the demo notebook now use `Qx.draw_counts/2`, the 0.10 facade name
  for the renamed `Qx.Draw.plot_counts/2`.
- Added `{:usage_rules, "~> 1.2", only: :dev, runtime: false}` and the
  `usage_rules` config block; `mix usage_rules.sync` now manages the
  `<!-- usage-rules-start -->` block in `CLAUDE.md`. The `override:
  true` it initially needed is gone: qx 0.10 ships `usage_rules` as a
  dev-only dep, closing the follow-up recorded here.

## [0.3.0] - 2026-05-17

### Changed

- **`Kino.Qx.CredentialsCell` now reevaluates on change and rebinds
  `qx` automatically.** The cell is registered with
  `reevaluate_on_change: true`, so changing any persisted field
  (portal URL, region, **backend**, optimization level, shots)
  re-runs the cell and rebinds the notebook `qx` binding. Previously,
  picking a backend after Connect updated the generated code text but
  did **not** rebind `qx` until the user manually re-ran the cell —
  a downstream `Kino.Qx.run!/2` would use a stale config. **Visible
  behaviour change:** editing a field now auto-re-runs the cell (on
  blur/commit, not per keystroke).
- **The Smart Cell is now a guided 3-step sequence** — (1) Livebook
  secrets, (2) Portal & region + Connect, (3) Job defaults. Step 3 is
  locked until Connect succeeds and shows a "pick a backend to finish"
  affordance until a backend is chosen. Pushed events, the
  `__remembered__` saved-backend handling, and the privacy invariant
  (tokens never in cell state / `.livemd`) are unchanged.

### Fixed

- **An unconfigured cell no longer silently emits a broken config.**
  With no backend chosen, `to_source/1` previously emitted
  `%Qx.Hardware.Config{… backend: "" …}`, which failed downstream with
  no actionable message. It now emits a `raise` with a clear
  instruction ("select a backend …"). Combined with
  `reevaluate_on_change`, picking a backend flips the cell from this
  guard to a valid `qx` automatically.

### Security

- **`to_source/1` re-validates `optimization_level`/`shots` before
  emitting them.** A shared `.livemd` is plain text; a hand-crafted
  non-integer value would previously be interpolated verbatim into the
  generated cell source (which, with `reevaluate_on_change`, now
  auto-evaluates). Both fields are now routed through the existing
  validators with a safe fallback to the documented defaults, and the
  integer parsers reject trailing garbage.

## [0.2.0] - 2026-05-16

**Breaking architectural reset.** A previously-drafted 0.2.0 design
(all-in-one TranspileCell with embedded QASM + Submit button) never
reached Hex. This release replaces it with a credentials Smart Cell +
a `Kino.Qx.run!/2` pipeline function. The transpile / submit / poll /
result-build core moved upstream into `Qx.Hardware` in the `:qx`
library (0.7.0); `kino_qx` is now a thin UX layer.

### Added

- **`Kino.Qx.CredentialsCell`** — new Smart Cell registered as **"Qx Credentials"**. Collects portal URL, region, backend, optimization level, and shots; emits a `qx = %Qx.Hardware.Config{...}` binding for downstream cells. Tokens come from Livebook secrets (`LB_PORTAL_TOKEN`, `LB_IBM_API_KEY`, `LB_IBM_CRN`) — never asked for in the cell UI, never present in cell state, never written to the `.livemd`.
- **`Kino.Qx.run/2,3`** and **`Kino.Qx.run!/2,3`** — pipeline functions that wrap `Qx.Hardware.run/3` with a live `Kino.Frame` status panel (✔ / ⏳ icons, queue position, elapsed seconds) and a best-effort cancel watcher. The watcher is an unlinked process that monitors the caller; if Livebook's "Stop" button fires during a run, the watcher calls `Qx.Hardware.cancel/3` for the in-flight IBM job.
- **`Kino.Qx.RunError`** — raised by `run!/2,3` when `Qx.Hardware.run/3` returns `{:error, _}`. Carries the original reason; `Exception.message/1` describes it humanly.
- **`Kino.Qx.Interrupted`** — exception type for caller interruption during a run; includes the job_id when known. (Wired to actually raise in [Unreleased] — see above.)
- Required dep on `{:qx, "~> 0.7"}` (resolves to `qx_sim 0.7.1`, which
  carries the `Qx.Hardware.connect/2` discovery fix + `Config` Inspect
  secret redaction this cell depends on).

### Changed

- **Interrupt contract is now real.** On Livebook's trappable "Stop"
  (`:shutdown`), `Kino.Qx.run/2,3` / `run!/2,3` now traps the exit,
  runs the in-flight `Qx.Hardware.cancel/3` exactly once, and
  **raises `Kino.Qx.Interrupted`** (with the last-seen `job_id`).
  Previously the exception type existed but was never raised — the
  caller just died and only the watcher cancelled. The unlinked
  watcher is retained solely as the `:kill` (untrappable) safety net.

### Removed (BREAKING)

- `Kino.Qx.TranspileCell` — superseded by `Kino.Qx.CredentialsCell` + `Kino.Qx.run!/2`.
- `Kino.Qx.IbmClient` — moved upstream to `Qx.Hardware.Ibm`.
- `Kino.Qx.TranspilePipeline` — absorbed into `Qx.Hardware.run/3`.
- `Kino.Qx.Client.transpile/2` — moved upstream to `Qx.Hardware.Portal.transpile/3`. `Kino.Qx.Client` is now snippet-only (`/me`, `/snippets`, `/snippets/:id`) and serves the existing `Kino.Qx.SmartCell`.
- Inline `Kino.DataTable` / `Kino.VegaLite` rendering inside the cell. Use `Qx.Draw.plot_counts/2` at the end of the `run!` pipeline instead.

### Privacy invariant

- Tokens are not held in cell state. `to_source/1` emits `System.fetch_env!("LB_PORTAL_TOKEN")` (and equivalents) as references, never string literals. The `.livemd` carries no secret bytes.

### Security

- `Qx.Hardware.Config` (which holds the portal token, IBM API key,
  IBM CRN, and IAM access token) is no longer reachable by
  `inspect/1` in any error/status path. A new `Kino.Qx.SafeReason`
  redacts an embedded `%Config{}` at any common nesting depth and
  collapses unknown reasons to a fixed string instead of inspecting
  them. The cancel watcher's `Qx.Hardware.cancel/3` is wrapped so a
  raised error can no longer crash-dump the closure env (tokens) to
  the Livebook log. The upstream root-cause fix — `@derive Inspect`
  on `Qx.Hardware.Config` — shipped in `qx_sim 0.7.1`.

### Notes

- `kino` dependency stays at `~> 0.19` (latest on Hex; no Smart Cell API churn since 0.1.0).
- Non-Livebook callers (CLI / Phoenix / OTP) can use `Qx.Hardware.run/3` directly from `:qx` with no `:kino` dep.

## [0.2.0-pre] (unpublished — superseded)

### Added

- `Kino.Qx.TranspileCell` — second Smart Cell registered as **"Qx Transpile + Submit"**. Takes an OpenQASM 3.0 circuit, asks the Qx Portal to transpile it for a chosen IBM Quantum backend, then submits the transpiled circuit to IBM Quantum directly and renders the result counts inline as a `Kino.DataTable` (with optional `Kino.VegaLite` histogram if available).
- `Kino.Qx.IbmClient` — Req-based wrapper for IBM Cloud IAM + the Qiskit Runtime REST API. Covers `iam_exchange/1`, `list_backends/1`, `fetch_backend_properties/2`, `submit_sampler/4` (3-element PUB `[qasm, nil, shots]`, no session), `poll_job/2` (Pascal-Case status enum: `"Queued"`, `"Running"`, `"Completed"`, `"Cancelled"`, `"Cancelled - Ran too long"`, `"Failed"`), `fetch_results/2`, `cancel_job/2` (`POST /jobs/:id/cancel`). 401-refresh-retry-once via `with_iam_refresh/2`. Sampler primitive only (Estimator deferred). Wire format verified against `qx_server` (production-proven against real IBM hardware) and IBM's published spec.
- `Kino.Qx.Client.transpile/2` — POST `/api/v1/transpile` with the qxportal contract. Maps 422 → `:invalid_qasm`, 502 → `:transpile_failed`, 503 → `:transpile_unavailable`, 504 → `:transpile_timeout`. Adds `:qasm`, `:metadata`, `:depth`, `:size`, `:num_qubits` to the response-key allowlist.
- `Kino.Qx.TranspilePipeline` — testable orchestrator (no Kino runtime needed). Sequences IAM auth → backend properties → portal transpile → submit → poll-with-backoff (1s/2s/4s capped at 30s, hard timeout 24h configurable) → fetch results. Emits `{:ibm, :job_started, job_id}` so the cell can track the job for cancel. `on_status` callback for live UI updates. Errors normalised to `{:error, stage, reason}` for stage-routed messaging.
- Live integration tests tagged `:ibm_live` and `:portal_live`, excluded from default `mix test`. Run locally before each Hex publish.
- SSRF defence on `portal_base_url`: persisted URLs validated against an allowlist (`*.qxquantum.com` over https; `localhost`/`127.0.0.1` over http for dev). Blocks malicious shared-notebook URL redirection.
- Error UI uses a `redact_reason/1` collapser so HTTP 4xx bodies (which can echo the IAM apikey) never reach the cell error panel.

### Privacy invariant

- Three independent secrets (qxportal token, IBM API key, IBM Service-CRN) live ONLY in transient cell state. None are written to `to_attrs/1`. Notebook circuits (`qasm_paste`) are persisted only when the user opts in via a "save with notebook" checkbox (default OFF).

### Notes

- `kino` dependency stays at `~> 0.19` (latest on Hex; no Smart Cell API churn since 0.1.0).

## [0.1.0] - 2026-05-03

### Added

- First Hex.pm release.
- Project scaffold (Apache-2.0).
- `Kino.Qx.Client` — Req-based wrapper around portal `/api/v1` endpoints
  (`me/1`, `list_snippets/1`, `get_snippet/2`). Maps 401/404/429 to
  `:unauthorized`, `:not_found`, `{:rate_limited, retry_after}`; network
  errors to `{:network, reason}`. JSON keys converted to atoms via an
  allow-list (no atom exhaustion).
- `Kino.Qx.SmartCell` — Livebook Smart Cell registered as "Qx Snippet".
  Inline JS + CSS (no external bundler). Token textbox, portal URL
  textbox, Connect button, snippet dropdown, source-kind toggle.
  **Security invariant:** `to_attrs/1` excludes the token AND identity;
  only the persistable subset (base_url, snippet_name, source_kind,
  source, selected_id) is written to the .livemd file. Tested.
- `Kino.Qx.Application` — registers the Smart Cell on app start.
- Initial decisions captured in iter-4 plan of the portal repo:
  - Package name `kino_qx` (livebook-dev convention).
  - Module: `Kino.Qx`. Smart cell: `Kino.Qx.SmartCell`.
  - Pinned `{:kino, "~> 0.19"}`, `{:req, "~> 0.5"}`, `{:jason, "~> 1.4"}`.
  - Default portal URL `https://qxportal.dev`.
  - Minimum Elixir `~> 1.17`.

[Unreleased]: https://github.com/richarc/kino_qx/compare/v0.2.0..HEAD
[0.2.0]: https://github.com/richarc/kino_qx/releases/tag/v0.2.0
[0.1.0]: https://github.com/richarc/kino_qx/releases/tag/v0.1.0
