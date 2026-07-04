# Kino.Qx

[Livebook](https://livebook.dev) Smart Cells + pipeline functions for
running quantum circuits on real IBM hardware via the
[Qx Portal](https://qxportal.dev).

Two cells ship in this package:

1. **Qx Snippet** — browse the snippets you've saved on the portal,
   pick one from a dropdown, and inject the OpenQASM 3.0 (or converted
   Elixir/Qx) source straight into a notebook cell.
2. **Qx Credentials** *(new in 0.2.0)* — collects portal URL, region,
   backend, optimization level, and shots; emits a
   `%Qx.Hardware.Config{}` binding (`qx`) that downstream cells pipe
   circuits through `Kino.Qx.run!/2`.

End-to-end pipeline:

```elixir
circuit
|> Kino.Qx.run!(qx)
|> Qx.draw_counts(title: "Bell state")
```

## Status

`v0.2.0` is a **breaking architectural reset**. The previous
`Kino.Qx.TranspileCell` (paste-QASM + Submit button + inline result
rendering) is replaced by `Kino.Qx.CredentialsCell` + a `Kino.Qx.run!/2`
pipeline function. The transpile / submit / poll core moved upstream
into `Qx.Hardware` in the `:qx` library (0.7.0); `kino_qx` becomes a
thin UX layer that adds a live `Kino.Frame` status panel.

The portal-side JSON API is locked at `/api/v1` — see the
[API reference](https://qxportal.dev/api/v1/docs). The IBM Quantum
REST API is documented at
[quantum.cloud.ibm.com](https://quantum.cloud.ibm.com/docs/en/api/qiskit-runtime-rest).

## Installation

In a Livebook setup cell:

```elixir
Mix.install([
  {:kino_qx, "~> 0.2"},
  {:qx, "~> 0.7"}
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

## Cell 2 — Qx Credentials + `Kino.Qx.run!/2`

### Livebook secrets (one-time per notebook)

The cell **never asks for tokens directly**. It reads three Livebook
secrets at Connect / run time:

| Secret name        | What it is                                                                 |
|--------------------|----------------------------------------------------------------------------|
| `LB_PORTAL_TOKEN`  | qxportal `qx_live_…` bearer (Dashboard → API Keys → Generate Key)          |
| `LB_IBM_API_KEY`   | IBM Cloud API key (<https://quantum-computing.ibm.com/> → Account)         |
| `LB_IBM_CRN`       | IBM Service-CRN (`crn:v1:bluemix:public:quantum:…`)                        |

Add each via the lock icon in Livebook's left sidebar before clicking
Connect. The `.livemd` file never carries any token — sharing a
notebook leaks nothing.

### Cell UI

* **Portal URL** — defaults to `https://test.qxquantum.com`. Validated
  against a host allowlist (`*.qxquantum.com` over https;
  `localhost`/`127.0.0.1` over http for dev) so a malicious shared
  notebook cannot redirect your token.
* **Region** — `us-south` (default) or `eu-de`. Must match the region
  encoded in your CRN.
* **Connect** — reads the three secrets, validates auth, populates the
  backend dropdown.
* **Backend / Optimization / Shots** — chosen per cell run.

### Pipeline

```elixir
circuit =
  Qx.create_circuit(2, 2)
  |> Qx.h(0)
  |> Qx.cx(0, 1)
  |> Qx.measure(0, 0)
  |> Qx.measure(1, 1)

circuit
|> Kino.Qx.run!(qx)
|> Qx.draw_counts(title: "Bell state")
```

A live `Kino.Frame` status panel renders above the result while the
job moves through transpile → submit → queued → running → done. If
you click Livebook's "Stop" button mid-run, a best-effort
`Qx.Hardware.cancel/3` fires for the in-flight job.

`Kino.Qx.run!/2` raises `Kino.Qx.RunError` on failure (pipe-friendly).
The tuple-returning `Kino.Qx.run/2,3` is also available for
production-style `with` chains.

### Outside Livebook

The hardware-execution core lives in `Qx.Hardware`. CLI scripts,
Phoenix apps, and OTP services can run circuits without a Livebook
runtime:

```elixir
config = %Qx.Hardware.Config{
  portal_url: "https://test.qxquantum.com",
  portal_token: System.fetch_env!("PORTAL_TOKEN"),
  ibm_api_key: System.fetch_env!("IBM_API_KEY"),
  ibm_crn: System.fetch_env!("IBM_CRN"),
  ibm_region: "us-south",
  backend: "ibm_brisbane"
}

{:ok, result} = Qx.Hardware.run(circuit, config)
```

`Kino.Qx.run/2,3` adds the status frame and cancel watcher around the
same `Qx.Hardware.run/3` call.

### What's NOT in v1

* **Estimator primitive** — Sampler only (Estimator deferred; base64
  tensor decoding deserves its own iteration).
* **Multi-circuit batches** — one circuit per `run!/2` call.
* **OpenQASM 2.0 input** — qxportal accepts 3.0 only; convert
  client-side first.

## Compatibility

| `kino_qx` | `qx`    | Kino    | Elixir   |
|----------:|---------|---------|----------|
| 0.2.x     | ~> 0.7  | ~> 0.19 | >= 1.17  |
| 0.1.x     | n/a     | ~> 0.19 | >= 1.17  |

## Troubleshooting

### Qx Snippet

| Symptom              | Likely cause                                                  |
|----------------------|---------------------------------------------------------------|
| `unauthorized` (401) | Token is wrong, revoked, or for a different portal            |
| Empty dropdown       | You haven't saved any snippets to the portal yet              |
| `rate_limited` (429) | More than 60 requests per minute on this key — wait + retry   |
| Network timeout      | Wrong portal URL, or the portal is unreachable from this host |

### Qx Credentials + `Kino.Qx.run!`

| Symptom                                          | Likely cause |
|--------------------------------------------------|--------------|
| `Missing Livebook secret LB_PORTAL_TOKEN`        | Add the secret via the lock icon in Livebook's sidebar |
| `Auth rejected (401)` from Connect               | Secret values wrong, or IBM region doesn't match the CRN |
| `Qx.Hardware.NoMeasurementsError`                | Circuit has no `Qx.measure/3` calls — Sampler V2 requires them |
| `Portal rejected the QASM (422)`                 | OpenQASM 2.0 input or syntax error; convert to 3.0 |
| `Portal transpile failed (502)`                  | Circuit too wide for the backend; try a smaller backend or `optimization_level: 0` |
| `Kino.Qx.Interrupted`                            | You clicked Livebook's Stop button mid-run; cancel was issued |
| Cell stuck on "queued"                           | IBM queue can be very long; the pipeline polls until terminal status |
| `Connect` succeeds but no backends               | Your IBM instance has no backends provisioned for this region |
| `Portal URL must be https://…`                   | The URL is not on the allowlist (`*.qxquantum.com` over https) |

## License

[Apache 2.0](LICENSE).
