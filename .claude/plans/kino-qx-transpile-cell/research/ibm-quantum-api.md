# IBM Quantum REST API (as of 2026-05)

## Summary

IBM Quantum runs on IBM Cloud now (old `quantum.ibm.com` platform was
sunset 2025-07). REST API submits OpenQASM 3.0 via Qiskit Runtime
primitives (Sampler / Estimator). Auth = IAM bearer (1-hour TTL) +
mandatory Service-CRN header. Sessions endpoint is REQUIRED for job
submission (direct `/jobs` deprecated 2025-03-31). Base URL:
`https://quantum.cloud.ibm.com/api/v1/` (or `eu-de.quantum.cloud.ibm.com/api/v1/`).

---

## Auth

### Token exchange (the cell does this once per connect)

User generates an API key at <https://quantum-computing.ibm.com/> →
exchange it for a short-lived bearer token:

```
POST https://iam.cloud.ibm.com/identity/token
Content-Type: application/x-www-form-urlencoded

grant_type=urn:ibm:params:oauth:grant-type:apikey
apikey=<API_KEY>
response_type=cloud_iam
```

Response carries `access_token` (3600s TTL) + `refresh_token` for silent
refresh.

### Per-request headers

```
Authorization: Bearer <ACCESS_TOKEN>
Service-CRN: crn:v1:bluemix:public:quantum:<region>:a/...
IBM-API-Version: 2026-03-15
Content-Type: application/json
Accept: application/json
```

`Service-CRN` is the user's **instance** identifier — they paste it
from the IBM Quantum dashboard. NOT derivable from the API key.

### Implications for the cell

- Need **three** things from the user, not just one: API key,
  Service-CRN, region.
- Must refresh on 401 (token expired) — long-running jobs (>1h queue)
  will hit this.
- IAM token exchange is the FIRST call after the user clicks Connect.

---

## Backend selection

Three GET endpoints, one per concern:

| Endpoint | Returns |
|---|---|
| `GET /v1/backends` | list of backend names + status |
| `GET /v1/backends/{name}/configuration` | gate set, qubit count |
| `GET /v1/backends/{name}/properties` | **`coupling_map`, `basis_gates`, `num_qubits`** |
| `GET /v1/backends/{name}/status` | `operational`, `status_msg` |

For the qxportal `/api/v1/transpile` payload we need
**`/properties`** specifically — it carries `coupling_map` (list of
`[q0, q1]` edges) and `basis_gates` (e.g. `["id", "rz", "sx", "x", "cx"]`).

---

## Job submission (sessions required as of 2025-03)

### Step A — open a session

```
POST /v1/sessions
{
  "backend": "ibm_brisbane",
  "mode": "dedicated",
  "max_ttl": 3600
}
```

Returns `id` (session_id). Session auto-cancels pending jobs when TTL
expires; running jobs complete.

### Step B — submit a job

```
POST /v1/jobs
{
  "program_id": "sampler",
  "backend": "ibm_brisbane",
  "session_id": "<session_id>",
  "params": {
    "pubs": [
      ["OPENQASM 3.0; qubit[2] q; h q[0]; cx q[0], q[1]; measure q;", null]
    ],
    "version": 2,
    "options": { "dynamical_decoupling": { "enable": false } }
  }
}
```

Response:

```json
{ "id": "job_abc123...", "backend": "ibm_brisbane" }
```

PUB format = `[circuit_qasm_string, observable_or_null]`. `null` on
the second element means "Sampler mode" (just measure). For
Estimator pass a Pauli string (`"Z"`, `"Z Z"`, `"X Y Z"`).

### Step C (optional) — close session

```
DELETE /v1/sessions/{session_id}
```

Cancels pending jobs in the session; running jobs complete.

---

## Job polling + results

### Status

```
GET /v1/jobs/{job_id}
```

```json
{
  "id": "job_abc...",
  "state": { "status": "DONE", "reason": null },
  "queue_position": 0,
  "estimated_start_time": null,
  "started_at": "...",
  "ended_at": "..."
}
```

Status enum: `INITIALIZING | QUEUED | RUNNING | DONE | CANCELLED | ERROR`.

### Results (only when status DONE)

```
GET /v1/jobs/{job_id}/results
```

Sampler result:

```json
{
  "data": [{ "counts": { "00": 512, "11": 512 } }],
  "metadata": { "execution_time_ms": 1234, "queue_wait_time_ms": 456 }
}
```

Estimator result is tensor-encoded base64 — defer; Sampler is the
v1 target.

### Polling strategy

- 1s interval first 5 polls, then back off to 5s, cap at 30s.
- Hard timeout 24h (configurable; queues can be long).
- 429 → exponential backoff.
- 401 → IAM refresh + retry once.

---

## Reference links

- Qiskit Runtime REST API: <https://quantum.cloud.ibm.com/docs/en/api/qiskit-runtime-rest>
- Cloud setup (REST flow): <https://quantum.cloud.ibm.com/docs/en/guides/cloud-setup-rest-api>
- Primitives via REST: <https://docs.quantum.ibm.com/guides/primitives-rest-api>
- Execution modes (REST): <https://quantum.cloud.ibm.com/docs/en/guides/execution-modes-rest-api>
- Python reference (canonical): <https://github.com/Qiskit/qiskit-ibm-runtime>

---

## Gotchas + risks

1. **1-hour IAM token TTL** — long queue waits will outlive a single
   exchange. Cell must refresh on 401 transparently.
2. **Sessions are mandatory** — direct `/jobs` POST without session
   has been deprecated since 2025-03-31. Plan must open a session
   before the first submit.
3. **Service-CRN required** — separate from API key; must collect
   from user, can't auto-discover.
4. **Region lock** — CRN encodes region; requests must hit the
   matching base URL. Bake region into the config object.
5. **Platform sunset** — old `/runtime/jobs` endpoints (pre-2025) are
   gone. Don't trust any pre-2025 blog post or library example.
6. **Resilience level trade-off** — `params.options.resilience_level`
   0..3, default 1. Higher = more error suppression, slower. v1: just
   pass through whatever default the user picks; default 1.
7. **Result tensor encoding** for Estimator — base64-packed numpy
   arrays. Out of scope for v1; Sampler-only first ship.
8. **Sampler PUB format quirk** — `pubs` is a list of pairs, NOT a
   single circuit string. Even a single-circuit submit needs to wrap.
9. **Backend status not a guarantee** — `operational: true` doesn't
   mean "you'll get scheduled soon". Surface `queue_position` to user
   so they're not staring at a frozen UI.
10. **No published rate limits** — assume standard IBM Cloud throttle
    (≈ 100 req/min); honour Retry-After when a 429 lands.

## Notes for Req-based Elixir client

- Use a single `Req` request struct with the IAM bearer + CRN headers
  baked in via `Req.new(headers: ...)`.
- Token refresh = a separate `Req` call to `iam.cloud.ibm.com`. Wrap
  request execution in a `with_iam_refresh/2` helper that catches 401
  once.
- For polling, `Task.start_link` with a sleep loop is fine — Smart
  Cell process owns the Task and tears it down on cell close.
- Use `Req.Response.get_header/2` for `retry-after`; same pattern as
  the existing `Kino.Qx.Client` rate-limit handler.
