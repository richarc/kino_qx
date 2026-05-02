# Changelog

All notable changes to `kino_qx` will be documented in this file. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Every breaking change to the [portal API contract](https://qxportal.dev/api/v1/docs)
is a **minor** bump on this package until v1.0.

## [Unreleased]

### Added

- Project scaffold (Apache-2.0).
- Initial decisions captured in iter-4 plan of the portal repo:
  - Package name `kino_qx` (livebook-dev convention).
  - Module: `Kino.Qx`. Smart cell: `Kino.Qx.SmartCell`.
  - Pinned `{:kino, "~> 0.19"}`, `{:req, "~> 0.5"}`, `{:jason, "~> 1.4"}`.
  - Default portal URL `https://qxportal.dev`.
  - Minimum Elixir `~> 1.17`.

[Unreleased]: https://github.com/richarc/kino_qx/compare/HEAD..HEAD
