# Kino.Qx

[Livebook](https://livebook.dev) [Smart Cells](https://hexdocs.pm/kino/Kino.SmartCell.html)
for the [Qx Portal](https://qxportal.dev).

Two cells ship in this package:

1. **Qx Snippet** — browse the snippets you've saved on the portal,
   pick one from a dropdown, and inject the OpenQASM 3.0 (or converted
   Elixir/Qx) source straight into a notebook cell.
2. **Qx Transpile + Submit** *(new in 0.2.0)* — paste an OpenQASM 3.0
   circuit, ask the portal to transpile it for a chosen IBM Quantum
   backend, then submit the transpiled circuit directly to IBM Quantum.
   Measurement counts render inline as a `Kino.DataTable` (with an
   optional `Kino.VegaLite` histogram).

## Status

`v0.2.0` adds the second cell. The portal-side JSON API is locked at
`/api/v1` — see the [API reference](https://qxportal.dev/api/v1/docs).
The IBM Quantum REST API is documented at
[quantum.cloud.ibm.com](https://quantum.cloud.ibm.com/docs/en/api/qiskit-runtime-rest).

## Installation

In a Livebook setup cell:

```elixir
Mix.install([
  {:kino_qx, "~> 0.2"}
])
```

Click **+ Smart** at the bottom of any notebook cell. You'll see both
cells in the menu — pick the one you need.

## Cell 1 — Qx Snippet (unchanged from 0.1)

Needs:

1. **A `qx_live_*` portal token.** *Dashboard → API Keys → Generate Key.*
2. **Portal URL** (defaults to `https://qxportal.dev`).

The token is stored only in transient cell state and **never**
serialized into the `.livemd` file.

## Cell 2 — Qx Transpile + Submit

Needs **three** independent credentials, each transient:

| Credential | Where to find it |
|------------|------------------|
| **Portal token** (`qx_live_…`) | Qx Portal → Dashboard → API Keys |
| **IBM Quantum API key** | <https://quantum-computing.ibm.com/> → Account |
| **IBM Service-CRN** | IBM Quantum Dashboard → Instance details (`crn:v1:bluemix:public:quantum:…`) |

Plus:

- **Portal URL** — defaults to `https://test.qxquantum.com`. Validated
  against an allowlist (`*.qxquantum.com` over https; `localhost` /
  `127.0.0.1` over http). A persisted `.livemd` cannot redirect your
  token to a foreign host.
- **IBM region** — `us-south` (default) or `eu-de`. Must match the
  region encoded in your CRN.

### Privacy invariant

The qxportal token reaches the portal **only**. The IBM API key and
CRN reach IBM **only**. None of the three are written to `to_attrs/1`,
so the `.livemd` notebook file never persists secrets — sharing a
notebook does not leak any of them.

The OpenQASM circuit you paste is **not** persisted by default. Tick
"Save QASM with notebook" only if you're comfortable having that
circuit in the `.livemd`.

### Flow

```
[ Connect ] ──► IAM exchange + portal /me + list backends
                          │
                  pick a backend
                          │
[ Submit ] ──► fetch backend properties (coupling_map, basis_gates)
            ──► portal /api/v1/transpile
            ──► IBM open_session
            ──► IBM submit Sampler job
            ──► poll (1s/2s/4s, capped at 30s; default 24h timeout)
            ──► fetch results
            ──► best-effort close session
                          │
            counts render inline as a Kino.DataTable
```

`Cancel` kills the polling Task and best-effort closes the IBM session.

### QASM format

The transpile endpoint takes the **gate-level** circuit only — no
`measure` statements, no classical bit declarations. IBM's Sampler
primitive measures every qubit at submit time and returns the counts.

```qasm
OPENQASM 3.0;
include "stdgates.inc";
qubit[2] q;
h q[0];
cx q[0], q[1];
```

Adding `bit[2] c;` or `c = measure q;` makes qxportal return
`Portal rejected the QASM (422)`. OpenQASM 2.0 input is also
rejected — convert to 3.0 client-side first.

### What's NOT in v1

- Estimator primitive (Sampler only — base64 tensor decoding deserves
  its own iteration).
- Notebook-variable binding for the QASM source — paste mode only.
- `resilience_level` slider — hardcoded to `1` in v1.
- Multi-circuit batches — one circuit per submit.

## Compatibility

| `kino_qx` | Kino    | Elixir   |
|----------:|---------|----------|
| 0.2.x     | ~> 0.19 | >= 1.17  |
| 0.1.x     | ~> 0.19 | >= 1.17  |

## Troubleshooting

### Qx Snippet

| Symptom              | Likely cause                                                  |
|----------------------|---------------------------------------------------------------|
| `unauthorized` (401) | Token is wrong, revoked, or for a different portal            |
| Empty dropdown       | You haven't saved any snippets to the portal yet              |
| `rate_limited` (429) | More than 60 requests per minute on this key — wait + retry   |
| Network timeout      | Wrong portal URL, or the portal is unreachable from this host |

### Qx Transpile + Submit

| Symptom                            | Likely cause |
|------------------------------------|--------------|
| `IBM auth failed (401)`            | Wrong API key, wrong CRN, or the CRN region doesn't match the dropdown |
| `Portal rejected the QASM (422)`   | OpenQASM 2.0 input (only 3.0 is accepted), or syntax error |
| `Portal transpile failed (502)`    | The transpiler errored on this circuit/backend pair (e.g. circuit too wide for the backend) |
| `IBM job ended with ERROR`         | Backend rejected the transpiled circuit — try a different backend |
| Cell stuck on "queued"             | IBM queue can be very long. The cell polls for up to 24h by default |
| `Connect` succeeds but no backends | Your IBM instance has no backends provisioned for this region |
| `Portal URL must be https://…`     | The URL you typed is not on the allowlist (`*.qxquantum.com` only) |

## License

[Apache 2.0](LICENSE).
