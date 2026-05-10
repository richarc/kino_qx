# Changelog

All notable changes to `kino_qx` will be documented in this file. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Every breaking change to the [portal API contract](https://qxportal.dev/api/v1/docs)
is a **minor** bump on this package until v1.0.

## [Unreleased]

## [0.2.0] - 2026-05-10

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
