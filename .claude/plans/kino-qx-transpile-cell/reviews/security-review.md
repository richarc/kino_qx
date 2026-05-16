# Security Review — kino_qx 0.2.0 TranspileCell

**Verdict:** No BLOCKERs. Privacy invariant holds. 2 WARNINGs, 4 SUGGESTIONs.

## Privacy invariant cross-check (all OK)
- `to_attrs/1` (`transpile_cell.ex:291-306`) lists only persistable keys; portal_token / ibm_api_key / ibm_crn / access_token absent.
- `client_payload/1` (`:517-535`) same — no token fields shipped to JS.
- `TranspilePipeline.run/1`: `portal.transpile/2` only at `:86`; all `ibm.*` calls use `ibm_cfg`. **Configs never cross.**
- `build_transpile_payload/2`: only qasm + coupling_map + basis_gates + optimization_level + seed.
- JS: token inputs `type="password" autocomplete="off"`, one-way push only.

## WARNING

### W-1 — Credential echo via `inspect(reason)`
`transpile_cell.ex:491,494,514` shows `"... #{inspect(reason)}"` for connect/pipeline errors. Reason can be `{:http, status, body}` from `ibm_client.ex:415` or `{:network, Exception.message(exception)}` (`:117`). IAM 4xx/5xx bodies are the highest-risk channel for apikey echo; that string lands in `:error` assign and ships to JS.

**Fix:** add `redact_reason/1` that collapses `{:http, status, _body}` → `"HTTP #{status}"` and `{:network, _}` → `"network failure"`. Specifically for `iam_exchange/1` return `{:error, {:iam_http, status}}` (drop body).

### W-2 — SSRF via `portal_base_url`
`transpile_cell.ex:99-102` accepts any string, persisted to `.livemd`, used as Req URL with the user's `qx_live_...` bearer (`client.ex:139,157`). A malicious shared notebook can redirect the token to attacker host or `169.254.169.254`.

**Fix:** validate scheme `https` + non-empty host, ideally allowlist `*.qxquantum.com`. IBM base URL is from a region-atom allowlist — not vulnerable.

## SUGGESTIONS

- Add regression test asserting distinctive sentinel tokens never appear in `inspect(TranspileCell.to_attrs(ctx))` or `client_payload(ctx)`.
- `with_iam_refresh/2` (`ibm_client.ex:358`) doesn't propagate refreshed token to next pipeline stage — causes repeated apikey IAM round-trips over 24h jobs. Thread refreshed cfg through `run/1`.
- `qasm_paste`: when user flips `save_qasm` false, also clear the live assign.
- Make TLS verify explicit: `connect_options: [transport_opts: [verify: :verify_peer]]`.

Iron Laws #7 (atom exhaustion: status + key allowlists) and #10 (Task supervision) verified clean. Recommend running `mix sobelow --exit medium`, `mix deps.audit`, `mix hex.audit` locally.
