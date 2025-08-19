# 3) Personas: Design, Rules, Discipline

## 3.1 Identity wall

- Each persona = separate VM/DVM set, its own accounts, its own time patterns.
- Never cross-login or copy/paste between personas.
- Tag VMs: `persona-research`, `persona-forums`, `persona-work`, etc.
- Assign a **single network path** per persona (Tor or VPN), never mix.

## 3.2 Baseline profile (for Windows Tor persona)

- OS: Windows 11 DVM (disposable).
- Browser: Tor Browser (default config).
- Locale: en-US; Timezone: UTC; Resolution: 1920×1080.
- No add-ons, no custom fonts, no devtools open on sites that matter.

## 3.3 Scheduling hygiene

- Randomize activity windows (±15–45 min).
- Avoid repetitive post times (e.g., always :17 past).
- Keep session lengths plausible (do not exceed hours typical for a human).

## 3.4 Account lifecycle

- Bootstrap accounts from the **correct network** (Tor for Tor personas).
- Unique recovery methods per persona; never share phone/email between personas.
- Passwords live in **Split-GPG/SSH + qubes-pass**; never store in browser.
- Rotate credentials on compromise suspicion or after critical publications.

## 3.5 Data boundaries

- Public material only leaves DVMs through **publish-sanitize** flow.
- Never move raw drafts/photos directly to a publishing VM.
- Treat PDFs/Office docs as hostile (macros, tracking pixels).

## 3.6 Human factors

- Keep writing style distinct per persona (voice, punctuation, vocab).
- Don’t reuse idioms or catchphrases across personas.
- Avoid language/keyboard switching mid-persona (leaks region).

# 4) Spoofing Baselines (Small, Safe, Consistent)

**Goal:** You look like a common Windows user on the wire; no mixed signals.

## 4.1 Network

- **TTL=128** at sys-firewall (Windows-like).
- **QUIC blocked** (force HTTPS/TCP).
- **MAC OUI** set to Intel/Realtek; stable suffix per boot.
- DHCP hints (if used) emulate Windows (done in earlier Salt for Linux personas).

## 4.2 Browser

- **Windows Tor persona**: use Tor Browser defaults; do not alter UA/fonts.
- Non-Tor personas: use chrome-like UA only if consistent across all such VMs.

## 4.3 VM identity

- Random Windows-like hostname (`DESKTOP-XXXXXXX`).
- Locale/timezone unified (en-US, UTC).
- Resolution fixed (1920×1080). Avoid fullscreen toggling and exotic sizes.

## 4.4 What we do NOT spoof (by design)

- SMBIOS/DMI, GPU, disk serials: not exposed to websites; changing them risks dom0 integrity or isolation.
- TCP/IP fine-grain fingerprint: mostly hidden via Tor exit; for clearnet, the TTL/QUIC measures are enough.

# 5) Content Sanitization & Publishing

**Pipeline:** Source VM → `qsanitize` (publish DVM) → sanitized output → upload from persona VM.

## 5.1 Tools (publish template)

- `mat2`, `exiftool`, `qpdf`, `ghostscript`, `ocrmypdf`, `imagemagick` (policy-hardened), `pandoc`.

## 5.2 Rules

- Strip EXIF/metadata on **every** image/audio/video.
- For PDFs: re-render via `gs` + strip XMP, producer/creator.
- For office docs: convert to PDF via `pandoc` (or export) then sanitize PDF.
- Thumbnails/history caches cleared (tmpfs logs).
- Never upload originals; keep them in encrypted vault only.

## 5.3 Operational checklist

- [ ] Run `qsanitize VM:/path/to/file` and use only the produced artifact.
- [ ] Review with a hex viewer for stray strings (optional).
- [ ] If screenshots, avoid unique UI themes or peripheral info (clock, custom icons).

# 6) Communications Discipline

## 6.1 Email

- Persona-specific accounts; PGP via Split-GPG.
- View attachments in **DisposableVMs**.
- Avoid auto-loading remote content; disable HTML where possible.

## 6.2 Messaging

- Prefer end-to-end (Signal/OMEMO).
- Treat bridges as hostile; never reuse phone numbers across personas.
- Avoid syncing to other devices; if you must, keep a persona-dedicated handset.

## 6.3 File transfer

- OnionShare or equivalent over Tor when possible.
- Otherwise, only sanitized artifacts via persona browser.
- Never exfil from vaults directly to net-connected VMs.

## 6.4 Voice/Video (avoid)

- If required, run through dedicated **sys-audio** and a persona VM.
- Keep calls short; disable camera by default.

# 7) Monitoring & Detection (Know when you’re burned)

## 7.1 Network (sys-firewall)

- Suricata (EVE JSON) → sys-alert; watch for:

  - DNS to unexpected resolvers (bypass attempts).
  - QUIC attempts (should be dropped).
  - Tor bypass patterns (direct 80/443 from Tor persona VM).

- nftables counters:
  - Track per-VM bytes/packets; alert on spikes or traffic in “quiet” VMs.

## 7.2 Integrity canaries

- **Kernel module drift** checker (daily + boot).
- **Template hashing** (daily): SHA256 of templates; compare to stored baseline in vault.
- **TPM measurements** (if Heads/TrenchBoot): verify PCRs daily; alert on mismatch.

## 7.3 Host signals

- Unexplained CPU load, fans, network bursts → investigate.
- New systemd units or autostarts in service VMs.
- Any “permission denied” or policy popups you didn’t expect → review policies.

## 7.4 Reporting loop

- Daily condensed report into `sys-alert`:
  - Top contacted IPs/domains per VM (aggregate).
  - “Empty-baseline alert”: if a vault or dormant VM generated traffic, page yourself.

# 8) Travel & Mobile OPSEC

## 8.1 Before travel

- Bring a **travel laptop** (clean image, minimal data).
- Fresh personas; no link to home identities.
- Pre-arranged comms plans; avoid SIMs tied to you.

## 8.2 At borders

- Assume device may be imaged.
- Power off fully; no hibernate (RAM image).
- If compelled to unlock, have decoy persona; real material is offline and encrypted.

## 8.3 On the road

- Prefer Ethernet or tether via a **burner hotspot**.
- Randomize MAC; expect captive portals (use Disposable).
- Don’t publish from hotel Wi-Fi you also sleep in.

## 8.4 After travel

- Consider reimage; rotate all credentials used.
- Compare template hashes; review network logs for anomalies.

# 9) Incident Response (IR)

## 9.1 Triage (first 10 minutes)

- Disconnect network (kill sys-net).
- Snapshot logs from sys-firewall/sys-dns before they rotate.
- Identify _which persona/VM_ showed the anomaly.

## 9.2 Contain

- Force shutdown compromised VMs (`qvm-shutdown --force`).
- Suspend all clipboard/filecopy policies (tighten, not loosen).
- Invalidate tokens/keys used by that persona (Split-GPG revoke if necessary).

## 9.3 Eradicate

- Rebuild affected personas from golden templates.
- Rotate passwords + 2FA seeds (use vault to mint new).

## 9.4 Recover

- Restore sanitized content/workflow.
- Re-enable comms from a fresh VM only after you’re sure the channel is clean.

## 9.5 Post-mortem

- What signal did we miss? Add a detector or policy.
- Update this book and Salt states accordingly.

# 11) Policies Quick-Ref (Essentials)

## Clipboard/Filecopy

- Deny across trust boundaries; use timed bypass tool for 300s only.
- Example:
  - `qubes.ClipboardPaste   @tag:persona-*  @tag:persona-*  ask,timeout=30`
  - `qubes.Filecopy         @tag:persona-*  @tag:persona-*  deny notify=yes`
  - Harden vault rules: deny everything inbound/outbound except explicit RPCs.

## DNS

- Only `sys-dns` may resolve; drop 53 to anywhere else.
- DoH/DoT blocked (QUIC drop, curated 443 blocklist optional).

## USB

- Unknown USB ⇒ Disposable mediator; only whitelisted VID:PID go to sys-net.
- Keyboard/mouse to sys-usb only; no direct attaches to AppVMs.

## Audio/Camera

- Attach only to `sys-audio`/`sys-camera` when needed; policy deny elsewhere.

## Tor Path

- Windows Tor DVMs → **must** use `sys-tor-gw`.
- Fail-closed rules in gateway (no direct egress if Tor down).

> Keep policies short, explicit, and **deny-by-default**.

# 12) Limits & Risks (Know what cannot be hidden)

- **Traffic correlation**: A global adversary can correlate timing/volume even over Tor; mitigate with schedule jitter and cover traffic (limited).
- **Exit node visibility**: Tor exits see plaintext destinations (not content with HTTPS); never authenticate real identities over Tor persona.
- **Human error**: Most deanonymizations are behavioral (wrong VM, reused handle, metadata slip).
- **Device fingerprints**: We normalize low-risk layers (TTL, MAC OUI, locale/resolution). We intentionally do not spoof deep hardware (SMBIOS/GPU) in Qubes — doing so risks isolation and gives no web anonymity benefit.
- **Remote zero-days**: Keep browsers up to date; prefer Disposables; don’t keep long-lived tabs open.
