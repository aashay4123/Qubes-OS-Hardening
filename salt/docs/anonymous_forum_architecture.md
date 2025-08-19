# Privacy‑Preserving Anonymous Forum — System Architecture (2025)

## 1) High‑level view

```
[Tor/I2P Users]
     |
  +--+------------------+
  |  Access Frontends   |  (read-only mirrors for posts)
  |  - Tor onion v3     |
  |  - optional I2P     |
  +--+------------------+
     |
     v
 [Write Gateway] --- PoW/CAPTCHA, token buckets, CSRF-less stateless tokens
     |
     v
 [App API (stateless)]  <-->  [Auth Broker (PGP/Passkeys, anon sessions)]
     |                              |
     |                              +--> [Role/Permissions (RBAC)]
     |
     +--> [Moderation Queue]  <->  [Moderator Console (separate onion)]
     |
     +--> [Post Store]  (append-only event log)   --> [Materialized Views]
     |                                                 (threads/subthreads, timelines)
     +--> [Attachment Sanitizer Workers (DVMs)]  --> [Sanitized Object Store (enc, TTL)]
     |
     +--> [Search Index] (privacy-hardened full-text)
     |
     +--> [Notification Bus]  (asynchronous alerts to mods/users; no push IDs)
```

**Design tenets**

- **Read‑mostly mirrors** for scale and resilience.
- **Write path isolated** and aggressively rate‑limited.
- **Append‑only event log** (immutable posts/edits/deletes as events) → _privacy‑friendly auditability_.
- **No third‑party assets**; strict CSP, HSTS, COOP/COEP.

---

## 2) Frontends & Access

- **Read Mirrors (static-ish):**

  - Multiple onion/I2P frontends serving **pre‑rendered thread pages** from materialized views.
  - Mirrors are **read‑only**: no login, no posting → high availability under load.
  - Updated via **signed snapshots** from the App API (pull).

- **Write Gateway:**

  - Separate onion used only for posting, edits, reports.
  - **Proof‑of‑Work (PoW)** or CAPTCHA, plus **token buckets** per session to resist floods.
  - **Uniform responses** (constant size/timing) to reduce fingerprinting.

---

## 3) Identity & Sessions (Anon‑friendly)

- **Anonymous sessions by default:**

  - Short‑lived, rotating tokens; no IPs, no user‑agents stored.

- **Optional pseudonymous identities:**

  - **PGP‑bound accounts** (public key only) or **passkeys** registered through Tor.
  - **Role‑based access control (RBAC)**: `user`, `trusted`, `moderator`, `admin`.

- **Reputation without doxxing:**

  - Local, in‑forum reputation number (non‑portable).
  - Decays over time; never exportable as “global identity”.

---

## 4) Data model (event-sourced)

**Event log (append‑only):**

- `PostCreated`, `PostEdited`, `PostDeleted` (tombstone), `ThreadCreated`, `ThreadMoved`,
  `ReportFiled`, `UserSuspended`, `UserRoleChanged`, `AttachmentUploaded`, `AttachmentSanitized`, `ModAction`.

**Materialized views:**

- `threads` (root posts, metadata),
- `posts_by_thread` (paginated; supports nested subthreads),
- `user_profiles` (public fields only),
- `mod_inbox`, `abuse_stats`, `reported_items`.

**Why event‑sourcing?**

- Immutability → integrity; easy rebuild of views; selective retention.
- Lets you expire **views** quickly while retaining minimal, blinded events if needed for abuse defense.

---

## 5) Posting & Attachments

- **Posting flow:**

  1. Write Gateway validates PoW, schema, and content size.
  2. App API writes `PostCreated` event (no PII).
  3. Materialized views update; mirrors pull new snapshots.

- **Attachments flow (images/PDFs):**

  - Uploaded to **sanitizer workers** (DisposableVMs/containers): `mat2`, `exiftool`, `qpdf`, `ghostscript`.
  - Output saved to **Sanitized Object Store** (encrypted at rest, TTL e.g. 30 days for attachments; shorter for sensitive boards).
  - Only sanitized artifacts referenced in posts.
  - Optional: **thumbnailing** done in a separate disposable worker.

---

## 6) Moderation

- **Moderator Console** served from a **separate onion** (different secret, RBAC‑gated).
- **Moderation Queue** (asynchronous):

  - Sources: user reports, automated heuristics (spam, malware flag, link blacklist), rate‑limit violations.

- **Actions:** hide, lock, move, warn, suspend, nuke (with reason codes).
- **Transparency:** each mod action generates a `ModAction` event; a **public modlog** view (redacted) is available to users.
- **Evidence handling:** flagged attachments retained longer (configurable) with **hash manifests**; everything else follows TTL.

---

## 7) Search (privacy‑hardened)

- **Full‑text index** built from pre‑sanitized text only (no user IDs/metadata in index).
- **Per‑query rate limits** and low‑resolution analytics (counts only).
- **No third‑party search providers**; all in‑house.

---

## 8) Notifications (no push IDs)

- **Asynchronous bus** publishes events: replies to your post, mod decisions, thread locks.
- Users **pull** notifications during visits (no background push channels).
- Optional **PGP‑encrypted digest** retrievable from a separate endpoint (pull only).

---

## 9) Anti‑abuse & Safety

- **PoW** difficulty adjusts during floods.
- **Token bucket** limits on create/edit/report endpoints.
- **Word/URL classifiers** (in‑process; models stored locally).
- **DoH/QUIC** irrelevant inside Tor, but block proxy bypass attempts if you later add clearnet.
- **Uniform error handling** to avoid oracle side channels.
- **No analytics/trackers**; only **synthetic health checks** and saturation metrics (CPU/mem/queue depth).

---

## 10) Storage & Retention

- **Posts:** keep event log minimal; views can have **TTL** (e.g., auto‑expire deleted content quickly).
- **Attachments:** strict TTL; purge via lifecycle rules; logs record **hashes only**.
- **Backups:** configs, schemas, and signed snapshots; avoid backing up raw attachments unless legally required.

---

## 11) DevSecOps & Supply Chain

- **Reproducible builds** (pinned dependencies); **signed artifacts** only.
- **Immutable deploys** (blue/green); rotate on suspicion rather than patch in place.
- **Key separation:** build‑signing ≠ runtime service; HSMs/smartcards for mod/admin auth if feasible.
- **Monitoring sans surveillance:** uptime, request success ratios, queue depths, sanitizer pass/fail counts—**not** user telemetry.

---

## 12) Availability & DDoS resilience

- **Mirrors**: many read‑only mirrors; users verify via **PGP‑signed onion list**.
- **Write throttling**: posting onion can raise PoW and narrow rate window under attack.
- **Failover**: keep cold spare frontends; rotate onions; publish signed change notices.
- **No single bottleneck**: app API is stateless; scale horizontally.

---

## 13) Roles & Permissions (RBAC)

- `user`: create posts, reply, report.
- `trusted`: bypass initial PoW level, create long posts/attachments.
- `moderator`: access mod console; take actions with reason codes.
- `admin`: manage roles, system keys, snapshots; cannot read more user data (because there isn’t any).

**Principle:** **least privilege**. Moderator tools don’t expose user metadata you never collected.

---

## 14) Threat model & mitigations (quick map)

| Threat                     | Mitigation                                                      |
| -------------------------- | --------------------------------------------------------------- |
| Bot floods                 | PoW, token buckets, moderator bulk actions                      |
| Malware/stego in files     | Disposable sanitizer workers; strict MIME; TTL; manifest hashes |
| Stylometry deanonymization | Optional paraphrasing aids; style guidance; allow anon posting  |
| LE/hostile hosting         | Multiple mirrors; immutable builds; fast rotation; minimal logs |
| Supply‑chain backdoors     | Reproducible builds, signed releases, dependency pinning        |
| Moderator compromise       | Separate onion, hardware tokens, mod‑action public log          |

---

## 15) Minimal data schema (illustrative)

- `events(id, ts, type, payload_hash, payload_enc)`
- `threads(thread_id, title_hash, created_ts, last_activity_ts, status)`
- `posts(post_id, thread_id, parent_post_id, created_ts, status, content_ptr)`
- `attachments(attach_id, post_id, artifact_sha256, ttl_expires_at)`
- `mod_actions(action_id, ts, actor_role, target_type, reason_code)`
- `rep_counts(post_id, window, count)` (privacy‑safe report counters)

_Note:_ where possible store hashes/pointers, not raw contents (except in short‑lived stores).

---

## 16) Moderator workflow (end‑to‑end)

1. User files a report → `ReportFiled` event.
2. Heuristics bump priority (spam score, link blacklist).
3. Moderator console shows queue; mod views **sanitized** attachment if present.
4. Mod chooses action (hide/lock/move/ban) → `ModAction` event.
5. Public **modlog** updates (redacted).
6. Affected thread pages re‑render; mirrors pull new snapshot.

---

## 17) What never happens (by design)

- No IP logging.
- No third‑party analytics.
- No persistent device cookies.
- No cross‑service beacons.
- No admin “god view” of PII—because none is collected.

---
