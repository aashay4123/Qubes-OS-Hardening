# 🛡 OPSEC README – High-Threat Environment

This document is a **living operational checklist** for using Qubes OS with spoofed personas and hardened network stack.
It combines:

- 🖥 System normalizations (from `normaliza.sls`)
- 👤 Persona isolation
- 🔒 Personal/behavioral OPSEC
- 🧾 Practical Do/Don’t rules

---

## 1. System-Level OPSEC (Baseline enforced via SLS)

These measures **apply to all personas by default**.

- **Network Normalization**

  - ✅ Enforce `TTL=128` (Windows-like default) on all egress.
  - ✅ Drop **QUIC/UDP 443** globally (force HTTPS over TCP).
  - ✅ Apply small TCP/IP hygiene: timestamps on, window scaling, sane buffers.

- **MAC Address Spoofing**

  - ✅ Realistic OUI vendor prefix (Intel/Realtek).
  - ✅ Random suffix per boot → ensures plausibility without being exotic.
  - ✅ Each persona can rotate independently (don’t reuse across personas).

- **Daemon Hygiene**

  - ✅ Disable Avahi/mDNS.
  - ✅ Disable Bluetooth in sys-net.
  - ✅ Journald set to **volatile storage only** (no persistent logs).
  - ✅ `/tmp`, `/var/tmp`, `/var/log` mounted as tmpfs → traces evaporate at shutdown.
  - ✅ Core dumps disabled.

- **VM Identity Shaping**

  - ✅ Random Windows-like hostname at each boot: `DESKTOP-XXXXXXX`.
  - ✅ Timezone forced to UTC (never leak local).
  - ✅ Locale fixed to `en_US.UTF-8` (don’t leak native language settings).
  - ✅ Screen resolution locked (letterboxed to common 1920x1080).

- **Integrity & Drift Monitoring**

  - ✅ Kernel module drift checker in sys-firewall (alerts via sys-alert if unexpected).
  - ✅ Pause/resume tool lets you temporarily disable normalizations for compatibility, but auto-restores.

---

## 2. Persona Management (5 Spoofed Personas)

Each persona = **dedicated AppVM + disposable stack**.

- **No cross-use** of apps, logins, or files.
- **No data transfer** between personas except via an explicitly sanitized channel (e.g., copy/paste scrubber).
- **Dedicated Tor circuits** per persona if possible (separate socksports / qvm-tor split).

### Example Persona Sheet (fill one per identity)

**Persona-1 (e.g., Corporate researcher)**

- Browser fingerprint: Windows 10/11, Chrome stable, 1920x1080.
- Timezone: UTC.
- Language: en-US only.
- Login cluster: Gmail, LinkedIn, Slack (all dedicated).
- Never: check real personal accounts from here.

**Persona-2 (e.g., Activist)**

- Browser: Tor Browser hardened (no plugins, safest mode).
- Timezone: UTC.
- Login cluster: Protonmail, Mastodon.
- Never: use from non-Tor network.

**Persona-3 (e.g., Casual social)**

- Browser: Firefox ESR.
- Login cluster: Twitter (burner), Reddit.
- Don’t: leak metadata like photo EXIF.

**Persona-4 (e.g., OSINT / research)**

- Browser: Chromium portable.
- All logins → disposable accounts only.
- Don’t: install persistent extensions.

**Persona-5 (e.g., Testing)**

- Rotating environment, nuked weekly.
- No long-term accounts.
- Sandbox only.

---

## 3. Behavioral OPSEC – Do’s & Don’ts

### Do’s ✅

- **Always isolate** personas in separate AppVMs (or full qubes if needed).
- **Use Tor for everything** unless you have a _specific reason_ to do otherwise.
- **Rotate personas** on separate Tor circuits (don’t let them share the same exit relay).
- **Keep a hard wall**: if persona A “knows” X, persona B must _not_ know X.
- **Randomize activity times** (don’t always login at 9am sharp).
- **Script cleanups**: always close and restart disposable browsers between sensitive sessions.
- **Cover metadata**: strip EXIF from images before upload.

### Don’ts ❌

- Don’t ever **cross-login** (e.g., check personal Gmail from persona AppVM).
- Don’t **reuse handles, avatars, or usernames** across personas.
- Don’t install **odd/rare browser plugins** that could fingerprint you.
- Don’t connect from your **home IP** without Tor/VPN layers.
- Don’t mix **languages** (if persona-2 is English-only, don’t suddenly type in Hindi).
- Don’t leak **hardware quirks** (microphone, camera, GPU acceleration all off).
- Don’t trust **“private mode”** in browsers → always assume fingerprintable.

---

## 4. Persona-Specific OPSEC Checklist

Each persona should have a **daily checklist** before going live:

- [ ] VM launched from **clean template**.
- [ ] MAC randomized + confirmed via `cat /rw/config/current_mac`.
- [ ] Hostname randomized (`hostname` shows `DESKTOP-*`).
- [ ] Browser fingerprint verified (use `https://coveryourtracks.eff.org`).
- [ ] Tor circuit isolated (`newnym` forced).
- [ ] No accidental file leaks in `/home/user/`.
- [ ] Locale & timezone confirm: `locale`, `date`.
- [ ] Resolution confirm: screenshot shows 1920x1080.

---

## 5. Emergency Actions

- **If you suspect compromise**:

  - Immediately `qvm-shutdown --force <persona-vm>`.
  - Rotate persona completely (new VM + new accounts).
  - Review logs from sys-alert.

- **If you need to safely pause normalizations** (rare):

  ```bash
  qvm-run -u root sys-firewall pause-normalize 300
  ```

  → auto-restores after 5 minutes.

---

⚠️ **Final Reminder**:
Your system-level hardening makes you blend in with **normal Windows+Tor users**.
But **behavioral discipline** (no leaks across personas, no reuse of metadata) is where most people slip.
