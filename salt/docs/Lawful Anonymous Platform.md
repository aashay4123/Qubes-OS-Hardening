# Lawful Anonymous Platform: High‑Security System Design (2025)

## Goals

- Anonymous access (no IP reliance), minimal metadata.
- Strong isolation between **public submission** and **private review**.
- Easy rotation/rebuild if anything looks compromised.

## High‑level topology

```
 [Users over Tor/I2P]
        |
   +----+--------------------------+
   |  Access Frontends (read-only) |
   |  - onion v3  (+ optional I2P) |
   |  - static mirrors             |
   +----+--------------------------+
        |
        v
 [Write Gateway (rate-limited, PoW/CAPTCHA)]
        |
        v
 [Ingress API] --(append-only)-> [Intake Queue (WORM)]
        |                                   |
        |                           (pull-only, one-way)
        v                                   v
 [Sanitizer Workers (disposable VMs)] --> [Sanitized Object Store (enc, TTL)]
        |                                   |
        +---------------+-------------------+
                        |
                        v
              [Review Station (isolated)]
                        |
               (optional air-gapped analysis)
```

## Core components (what & why)

- **Access frontends (read‑only mirrors)**
  Static content only; no accounts/logins; multiple onion/I2P endpoints to resist blocking.
  _Why:_ Availability without exposing write paths.

- **Write gateway**
  Separate onion for posting/uploading. Enforce **proof‑of‑work or CAPTCHA**, token buckets, and application‑level rate limits.
  _Why:_ Defends against floods/abuse without IP addresses.

- **Ingress API → Intake queue (append‑only/WORM)**
  Minimal, schema‑validated JSON; files chunked. Queue is append‑only with integrity tags.
  _Why:_ Prevents tampering and limits blast radius.

- **Sanitizer workers (DisposableVMs/containers)**
  One‑shot workers run `mat2/exiftool/qpdf/gs` pipelines. Produce: **sanitized artifact + manifest** (hashes, tool versions).
  _Why:_ Kill metadata and embedded active content; isolate risky files.

- **Sanitized object store (encrypted + lifecycle TTL)**
  Short‑lived storage (e.g., 24–72h). Keys in memory‑only KMS; automatic purge.
  _Why:_ Data minimization and fast burn‑down.

- **Review station**
  Pull‑only from intake via one‑way channel (qrexec‑like RPC or sneaker‑net for highest assurance). Optional **air‑gapped** analysis.
  _Why:_ Prevents pivot from public plane into private plane.

- **Auth & keys**

  - Public submission keys published; private keys on hardware tokens.
  - Build‑signing keys ≠ runtime service keys (separation of duties).
    _Why:_ Compromise of one role doesn’t leak another.

- **Build & deploy**
  Reproducible builds (pinned, signed). **Immutable** deployments (blue/green).
  _Why:_ Fast rotation; verifiable provenance.

- **Observability without surveillance**
  Health checks (synthetic probes), saturation metrics (CPU/mem/queue depth), integrity canaries (hash/manifest checks).
  _Why:_ Know it’s alive without collecting user telemetry.

## Security controls that matter

- **No third‑party assets** (no CDNs/analytics). Strict CSP/HSTS.
- **Message‑level encryption** (PGP in browser if appropriate).
- **Uniform responses** (constant‑time errors; no unique error text).
- **Minimal logging** (rolling counters, not request logs).
- **Secrets rotation & short‑lived tokens**.
- **Warrant canary / transparency note** (for lawful orgs).

## Operations playbook (condensed)

- **Rotation:** New frontends (onion/I2P) monthly or on suspicion; deprecate old via signed notices.
- **Backups:** Encrypted, versioned backups of configs/manifests only; **no raw submissions** beyond TTL.
- **Patching:** Rebuild from source, verify sigs, deploy immutably.
- **Incident response:** Global kill‑switch to purge object store & rotate keys; swap to cold spare images.

## Trade‑offs

- **Pros:** Very low data exhaust, strong isolation, fast to rebuild/rotate.
- **Cons:** Higher latency, careful UX needed for non‑technical users, more operational discipline.

---

\

## End‑to‑End Simulation: “Anonymous Source submits a PDF + message”

**Date:** 2025‑08‑19 (UTC)
**Actors:**

- **Source** (Tor Browser)
- **Ingress Onion** (write‑only gateway)
- **Intake Queue** (append‑only)
- **Sanitizer Worker** (Disposable VM)
- **Sanitized Object Store** (encrypted, TTL=48h)
- **Review Station** (pull‑only)
- **Publisher** (edits & releases a redacted PDF)

**Topology recap:**

```
Source(Tor) → [Write Onion] → Intake Queue (WORM)
                               ↓ (pull)
                           Sanitizer (DVM) → Object Store (enc, TTL)
                                              ↓ (pull)
                                       Review Station → Publish
```

---

## 1) Source uploads (Tor)

The **Write Onion** demands a small Proof‑of‑Work (PoW) + optional in‑browser PGP.

### 1.1 Get a PoW challenge

```http
POST /v1/pow HTTP/1.1
Host: abcde12345.onion
Content-Type: application/json

{"difficulty": 20}
```

**Response**

```json
{
  "challenge_id": "ch_7yQ2v",
  "prefix": "bafc4f30a1",
  "difficulty": 20,
  "expires_at": "2025-08-19T12:01:00Z"
}
```

### 1.2 Solve PoW locally (in browser/JS)

Source submits the nonce and a short message + file.

```http
POST /v1/submit HTTP/1.1
Host: abcde12345.onion
Content-Type: multipart/form-data; boundary=BOUND
X-PoW-Challenge: ch_7yQ2v
X-PoW-Nonce: 43892017
X-Client-Version: "web-2025.08.19"

--BOUND
Content-Disposition: form-data; name="note"
Content-Type: text/plain; charset=utf-8

This shows systematic wrongdoing. Please contact via PGP only.
--BOUND
Content-Disposition: form-data; name="pgp"; filename="note.asc"
Content-Type: application/pgp-encrypted

-----BEGIN PGP MESSAGE-----
... (optional; if provided, server stores as blob without reading) ...
-----END PGP MESSAGE-----
--BOUND
Content-Disposition: form-data; name="file"; filename="doc.pdf"
Content-Type: application/pdf

%PDF-1.7 ... (binary)
--BOUND--
```

**Response (immediate, uniform timing & size):**

```json
{
  "submission_id": "sub_4Jm2qJmG",
  "retrieval_code": "R-9Z2P-7X1T",
  "est_sanitize_time_sec": 120
}
```

> The gateway _doesn’t_ log IPs, user agents, or referers. Only rolling counters + synthetic health.

---

## 2) Intake Queue (append‑only)

Write Onion drops a **manifest** + **blobs** into an append‑only queue (WORM). Example manifest:

```json
{
  "submission_id": "sub_4Jm2qJmG",
  "received_at": "2025-08-19T12:00:22Z",
  "files": [
    { "name": "doc.pdf", "blob_id": "blob_fPq7", "sha256": "e8d1...ae77" }
  ],
  "note_present": true,
  "pgp_present": true,
  "client_version": "web-2025.08.19"
}
```

- Queue item is immutable (filesystem chattr/i or WORM queue).
- No user metadata beyond what’s required for integrity & routing.

---

## 3) Sanitization (Disposable Worker VM)

A worker VM (spawned fresh) pulls `sub_4Jm2qJmG`, runs tools (`mat2`, `exiftool`, `qpdf`, `ghostscript`), and emits a sanitized artifact + a **sanitization manifest**.

### 3.1 Processing log (internal, kept in tmpfs)

```
2025-08-19T12:00:45Z start sub_4Jm2qJmG
- fetched blob_fPq7 (doc.pdf) sha256=e8d1...ae77
- qpdf --check: OK
- exiftool -all= : removed 12 metadata fields
- ghostscript re-render → PDF/A-1b
- re-hash sanitized.pdf sha256=39f1...9c22
- mat2 summary: OK, no active content
```

### 3.2 Sanitization manifest (stored with the sanitized file)

```json
{
  "submission_id": "sub_4Jm2qJmG",
  "sanitized": [
    {
      "source_blob": "blob_fPq7",
      "source_sha256": "e8d1...ae77",
      "artifact_blob": "art_b1Z0",
      "artifact_sha256": "39f1...9c22",
      "tools": {
        "qpdf": "11.9.0",
        "exiftool": "12.97",
        "ghostscript": "10.03.1",
        "mat2": "0.14.0"
      }
    }
  ],
  "notes": {
    "pgp_attached": true,
    "plaintext_note_present": true
  },
  "completed_at": "2025-08-19T12:02:08Z"
}
```

- Worker VM **self‑destructs** after upload (disposable).
- Only sanitized artifact + manifest proceed to the object store.

---

## 4) Sanitized Object Store (enc + TTL=48h)

The sanitized artifact `art_b1Z0` and its manifest are stored encrypted, with lifecycle rules:

```
Bucket: sanitized/
  sub_4Jm2qJmG/
    artifact.pdf       (enc-at-rest, object lock: 48h)
    manifest.json
    retrieval.txt      (contains retrieval code & status)
```

- Keys are in memory‑only KMS; no long‑lived disk secrets.
- After 48h, objects auto‑purge unless the reviewer pins them.

---

## 5) Review Station (pull‑only)

A reviewer (inside an isolated Review VM) checks the queue of completed items and pulls:

```bash
# (dom0) Trigger a pull from Review VM via qrexec policy (pull-only)
qvm-run review-station 'reviewctl fetch --id sub_4Jm2qJmG'
```

**reviewctl** shows:

```
Submission: sub_4Jm2qJmG
Files: 1 sanitized artifact (PDF)
Hashes: 39f1...9c22
PGP: user-provided encrypted note present
```

Reviewer opens the sanitized PDF locally (no network), and, if needed, moves to an **air‑gapped analysis VM** for deeper inspection or redaction.

> If the PGP blob was included, the reviewer decrypts with an offline key **inside air‑gap** only.

---

## 6) Editorial Redaction & Publish

- Redactions are applied (e.g., masking names/faces).
- Final **publishable PDF** is generated in an offline VM, then pushed to the **Publish VM** (no raw source leaves the review plane).

**Audit trail (minimal, internal):**

```json
{
  "submission_id": "sub_4Jm2qJmG",
  "final_sha256": "0b77...3a10",
  "redactions": ["face_blur", "name_mask"],
  "approved_by": "ed_02",
  "published_at": "2025-08-19T14:20:10Z"
}
```

---

## 7) Notifications & Transparency

- **Source retrieval code** (`R-9Z2P-7X1T`) can be used (optionally) to check status on a **read‑only onion**:

```http
GET /v1/status/R-9Z2P-7X1T
→ {"status":"processed","window":"36h"}
```

- Public **warrant canary** updates daily:

  - “No compelled keys, no backdoors, last updated 2025‑08‑19.”

---

## 8) What gets stored / what is discarded?

- **Stored (short‑lived):** sanitized artifact, sanitization manifest, minimal audit (hashes, tool versions), retrieval code.
- **Never stored:** IPs, user agents, exact timestamps beyond coarse buckets, plaintext of any PGP note.
- **Auto‑purge:** all sanitized objects after TTL unless explicitly pinned by editor.
- **Worker logs:** exist only in tmpfs; vanish when the Disposable VM exits.

---

## 9) Failure / Edge Cases (and outcomes)

- **PoW expired:** submission returns uniform error; no queue entry created.
- **Malicious PDF (JS/launch action):** sanitizer strips; if cannot, the item is quarantined and the worker VM self‑destructs. Reviewer sees “quarantine” status only.
- **Descriptor flood (DDoS):** write onion increases PoW difficulty and enforces token‑bucket limits; read‑only mirrors remain available.
- **Compromise suspicion:** global kill switch purges object store, rotates KMS keys, and publishes signed notice; frontends switch (blue/green).

---

## 10) Quick Operator Verifications (privacy‑preserving)

- **No IP logs:** Confirm log config files; search for `remote_addr` or `$proxy_add_x_forwarded_for` → not present.
- **Sanitizer provable:** Spot‑check manifests: hashes differ from originals; tools are pinned & recorded.
- **TTL purge working:** Verify S3/Object store lifecycle events removed older artifacts.
- **One‑way flow enforced:** Review station has _no_ network route back to Write Onion plane (check routes/nftables).
- **Warrant canary signed:** Verify detached signature with public key.

---

## 11) Tiny “tabletop” rehearsal (operator scriptlets)

- **Simulate a submission** (operator test harness):

```bash
torify curl -s -X POST https://abcde12345.onion/v1/pow -d '{"difficulty":18}' | jq .
# locally solve → submit a tiny test file
```

- **Check sanitizer outputs**:

```bash
qvm-run sanitizer-dvm 'ls /work/artifacts && cat /work/manifest.json | jq .'
```

- **Review pull**:

```bash
qvm-run review-station 'reviewctl list --since 2h'
```

- **Purge check** (after TTL):

```bash
ossctl ls sanitized/sub_4Jm2qJmG/   # should be empty after 48h
```

---
