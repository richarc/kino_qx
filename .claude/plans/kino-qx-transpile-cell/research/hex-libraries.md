# Hex IBM-Quantum / quantum library scan

## Summary

No Elixir library on hex.pm covers IBM Quantum REST API access; **build it
ourselves** using the already-present `Req` dependency, wrapping it behind a
project-owned `KinoQx.IBMQuantum` facade module per the Iron Law on third-party
wrapping.

---

## Candidate libraries

| Package | Version | Last release | Downloads (all-time) | Quantum-relevant? | Notes |
|---|---|---|---|---|---|
| `qx_sim` | 0.6.0 | 2026-05-04 | 437 | Simulator only | Already a dep. Local statevector sim + OpenQASM import/export. Has `Qx.Remote` but targets custom QxServer, not IBM Quantum. No IAM auth, no job submission, no result polling. |
| `nx_quantum` | 0.11.0 | 2026-03-29 | 139 | Simulator only | Nx-powered statevector sim + QML primitives. No hardware backend, no IBM integration. Low download count, single maintainer. |
| `quantex` | 0.1.0 | 2018-12-24 | 1,178 | No | Last touched 7 years ago. Pre-Qiskit-IBM-Runtime era. Abandoned. |
| `ibmcloud` | 0.0.1 | 2020-01-14 | 1,230 | No | Generic IBM Cloud thin wrapper, not quantum. Abandoned (6 years old). Doesn't cover Quantum Platform APIs. |
| `ueberauth_ibmid` | 0.1.2 | 2024-06-11 | 12,174 | Marginal | OAuth user-login strategy for IBM ID. IBM Quantum API uses IAM API-key -> token exchange (`POST /identity/token`), a server-to-server flow. This library is scoped to user-facing OAuth and does not help. |
| `ibm_speech_to_text` | 0.3.0 | (old) | low | No | IBM Watson STT only. Unrelated. |
| `ibm_push` | 0.1.1 | old | low | No | IBM Bluemix push notifications. Unrelated. |
| `ibm_watson_assistant` | 1.1.0 | old | low | No | Watson chatbot API. Unrelated. |
| `pqclean` / `ex_oqs` / `ex_falcon` / `ntrukem` | various | recent | low | No | Post-quantum *cryptography* (PQC) — not quantum computing hardware. |
| `qrandom` | 0.1.1 | old | low | No | ANU quantum random number client. Unrelated to IBM Quantum. |

Searches performed: `quantum`, `ibm`, `ibm_quantum`, `openqasm`, `qiskit`,
`ibm_runtime`, `quantum_circuit`, `qpu`, `quantum_job` — all returned no hits
for IBM Quantum or OpenQASM 3.0 submission.

---

## Recommendation

**Build it ourselves.** No hex package covers any of the required IBM Quantum
surface area: IAM token acquisition, backend listing, OpenQASM 3.0 job
submission, job status polling, or result fetching.

Implement a thin `KinoQx.IBMQuantum` module (wrapping `Req`) covering:

1. `authenticate/1` — POST to `https://iam.cloud.ibm.com/identity/token` with
   API key, cache bearer token with expiry
2. `list_backends/1` — GET `/v1/backends` (IBM Quantum Platform REST API)
3. `submit_job/3` — POST `/v1/jobs` with `{"program_id": "sampler", "backend":
   ..., "params": {"circuits": [openqasm_string]}}`
4. `poll_job/2` — GET `/v1/jobs/{job_id}` with exponential backoff until
   `status` is `"Completed"` or terminal
5. `fetch_results/2` — GET `/v1/jobs/{job_id}/results`

`Req` (already in deps at `~> 0.5`) handles retries, JSON decode, and headers
cleanly. No new hex dependency needed.

`qx_sim` is confirmed as a local simulator — keep it for circuit construction
and OpenQASM export, feed that output to the IBM Quantum client.

---

## Risks if we build it ourselves

- **IBM API churn**: IBM rotated from `qiskit-ibm-provider` to
  `qiskit-ibm-runtime` in 2023-2024, and the REST endpoints changed. We need
  to track IBM Quantum Platform REST API releases and integration test against
  a live backend (or mock with Bypass).
- **Auth token lifetime**: IAM tokens expire after 1 hour; the client must
  refresh proactively or handle 401 and retry once.
- **OpenQASM 3.0 validation**: IBM Quantum accepts OQ3 but rejects certain
  gate sets not in their basis. We may need a validation pass before submission
  (qx_sim's export should be close but may need transpilation).
- **Rate limits / job queue depth**: IBM Quantum enforces per-plan job limits.
  Polling must use exponential backoff to avoid 429s.
- **Premium access gates**: Some backends require paid IBM Quantum plans. The
  client should surface clear errors when 403 is returned.

---

## Compatibility Notes

- Elixir version requirement: `~> 1.17` (matches kino_qx)
- No new hex deps required — `Req ~> 0.5` and `Jason ~> 1.4` already present
- `qx_sim ~> 0.6` already present for circuit construction + OQ3 export
- Known conflicts: none
