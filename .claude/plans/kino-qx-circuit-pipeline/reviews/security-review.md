# Security Review — feat/credentials-cell

⚠️ EXTRACTED FROM AGENT MESSAGE (subagent Write denied; captured by orchestrator)

Privacy invariant **holds** in kino_qx-controlled persistence paths
(`to_attrs/1`, `to_source/1`, `client_payload/1` all clean). SSRF allowlist
and atom-exhaustion clean. **One BLOCKER**: token leak via `inspect/1`
catch-alls.

## BLOCKER — `inspect/1` can dump a plaintext `%Qx.Hardware.Config{}`
Sites:
- `lib/kino/qx/run.ex:231` `error_summary(other) -> inspect(other)`
- `lib/kino/qx/run.ex:204` `render_event_line(other, _) -> "· " <> inspect(other)`
- `lib/kino/qx/exceptions.ex:22` `describe(other) -> inspect(other)`

Root cause: `qx/lib/qx/hardware/config.ex:93-108` `defstruct` holds
`portal_token`, `ibm_api_key`, `ibm_crn`, `access_token` with **no
`@derive {Inspect, except: …}}`**. `inspect(%Config{})` prints all secrets.

Reachable: `Run.run/2` holds/forwards `config`. If any upstream
`{:error, reason}` embeds the struct (e.g. `{:stage, %Config{}}`, an
exception built from the struct, or an unrecognised status tuple), the
catch-all `inspect` writes secrets into the Kino frame Markdown (persisted
to `.livemd` output) and into the raised `RunError` message.

Fix (kino_qx, now): add `safe_reason/1` that pattern-matches
`%Qx.Hardware.Config{}` → `"config (redacted)"` and never `inspect`s
arbitrary upstream reasons; apply at all three sites. Add a regression test:
`inspect`-rendered output and `RunError.message({:x, %Config{}})` must not
contain a token value.

Fix (cross-repo): file a bd issue `discovered-from:kino-qx-circuit-pipeline`
to add `@derive {Inspect, except: [:portal_token, :ibm_api_key, :ibm_crn,
:access_token]}` in `qx/`.

## WARNING — watcher crash-dump exposes `%Config{}`
`lib/kino/qx/run.ex:94-99` spawn closure captures plaintext `config`;
`hardware_mod.cancel(job_id, config)` at `run.ex:115` is unguarded. If it
raises, the watcher crash report `inspect`s the closure env → tokens in the
Livebook log. Fix: `try/rescue` around the cancel (mirror the guard at
`run.ex:142-146`).

## Clean (no action)
`to_attrs`/`to_source` (literals from module attrs, not from `attrs` — an
adversarial `attrs["portal_token"]` cannot interpolate); `client_payload`
(only `secret_names`, never values); `validate_portal_url/1`
(scheme+host allowlist; rejects file:/data:/javascript:/link-local/metadata/
homograph); `redact_reason/1` (drops HTTP bodies — IBM apikey echo blocked);
no `String.to_atom`; `client.ex` `to_known_atom` allowlist; no token logging.

## Recommended manual checks
`mix sobelow --exit medium`, `mix deps.audit`, `mix hex.audit`.
