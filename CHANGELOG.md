# Changelog

All notable changes to `kino_qx` will be documented in this file. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Every breaking change to the [portal API contract](https://qxportal.dev/api/v1/docs)
is a **minor** bump on this package until v1.0.

## [Unreleased]

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

[Unreleased]: https://github.com/richarc/kino_qx/compare/v0.1.0..HEAD
[0.1.0]: https://github.com/richarc/kino_qx/releases/tag/v0.1.0
