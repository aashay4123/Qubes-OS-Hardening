# OSI model security — Qubes layout (at a glance)

This document provides an overview of the OSI model security stack in Qubes, detailing the roles, controls, telemetry, and quick checks for each layer. It also includes a file tree structure for the Salt states and a brief runbook for common tasks.

## File tree (dom0)

```

/srv/
├─ pillar/
│ ├─ top.sls
│ ├─ osi_model_security.sls # VM map + global toggles
│ └─ roles/
│ ├─ dns.sls # DNS tuning knobs
│ ├─ usb.sls # USB policy knobs
│ └─ transport.sls # Transport crypto knobs
└─ salt/
├─ top.sls
└─ osi_model_security/
├─ init.sls # orchestrator (ensures VMs; includes roles)
├─ map.jinja # shared config & defaults
└─ roles/
├─ usb/init.sls
├─ net/init.sls
├─ dns/init.sls
├─ firewall/init.sls
├─ ids/init.sls
├─ transport/init.sls
└─ app/init.sls

```

## OSI model security stack (at a glance)

```
[ USB devices ] ──► dom0 policy (device+usb, device+block, Input* )
                      │
                      ▼
                  sys-usb (usbguard default-deny; audit)
                      │
                ───── Net/traffic ─────────────────────────────────────────────────────────────
                      │
     App VMs  ──►  sys-firewall  ──►  sys-dns  ──►  sys-ids  ──►  sys-net  ──► Internet
     (firejail/        (per-VM         (Unbound      (Suricata     (NIC +
      AppArmor,         dnsmasq          recursive     AF_PACKET     L2/L3
      default-drop      logs, default    resolver      inline        hardening)
      firewall)         drop)            + logs)       + EVE logs)
                      │            │
       per-VM DNS logs┘            └── Validated DNS w/ query+reply logs (and optional DNSTAP)
```

**Trust boundaries**

- **dom0** (policy only; no network)
- **service VMs** (sys-usb/sys-net/sys-ids/sys-dns/sys-firewall)
- **app VMs** (least privilege, per-VM firewall)

Traffic path (default): `app → sys-firewall → sys-dns → sys-ids → sys-net → Internet`.

---

# Layer-by-layer: role, controls, telemetry, quick checks

| Layer                      | VM(s)                     | Primary role                                       | Key controls in this setup                                                                                                              | Telemetry you get                                | Fast checks (you already have a script)                                            |
| -------------------------- | ------------------------- | -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ | ---------------------------------------------------------------------------------- |
| **Physical (USB)**         | dom0 policy + `sys-usb`   | Contain/mediate USB keyboards, mice, storage       | dom0 **device policies** route all USB to `sys-usb`; **tag-gated** block-attach; `usbguard` **default-deny** w/ allowlist               | `/var/log/usbguard/audit.log` in `sys-usb`       | Input requires `ask`; only tagged VMs can receive block devices; `usbguard` active |
| **Link (L2/L3 hygiene)**   | `sys-net`                 | NIC access & kernel guards                         | NetworkManager **MAC randomization**; sysctl: `rp_filter=1`, **no redirects**, syncookies                                               | `journalctl` for NM; `/proc/sys` values          | MAC randomization config present; sysctl file applied                              |
| **Routing/egress policy**  | `sys-firewall`            | Per-VM firewall; DNS hop with attribution          | Qubes **default-drop** per-VM rules; `dnsmasq` with **log-queries** (optionally ECS/MAC)                                                | `/var/log/dnsmasq.log`                           | dnsmasq installed & logging; default drop visible in `qvm-firewall`                |
| **Name resolution**        | `sys-dns`                 | Validating recursive resolver (no opaque upstream) | **Unbound** with DNSSEC, qname-minimisation, root.hints; **query & reply logging**; optional **DNSTAP**                                 | `/var/log/unbound/unbound.log` (+ DNSTAP socket) | `unbound-checkconf` clean; logs non-empty                                          |
| **Inspection / detection** | `sys-ids`                 | Inline visibility; protocol anomalies, C2 patterns | **Suricata** AF_PACKET; **EVE DNS/flow** outputs                                                                                        | `/var/log/suricata/eve.json`                     | Suricata active; eve.json growing on traffic                                       |
| **Transport & time**       | Templates (Debian+Fedora) | TLS/SSH policy; authenticated time                 | Debian: OpenSSL **SECLEVEL≥2/3**, GnuTLS overrides; Fedora: **crypto-policies** (DEFAULT/FUTURE); **Chrony + NTS**; hardened SSH client | System logs; `update-crypto-policies --show`     | TLS min version enforced; Chrony/chronyd active with `nts`                         |
| **Application**            | App VMs                   | Sandbox + least-privilege network                  | **firejail + AppArmor** (Debian) / firejail (Fedora), **per-VM default-drop** allowlist (https,dns,ntp…)                                | App logs + upstream dnsmasq/Unbound              | `qvm-firewall` shows default drop; only allowed ports open                         |

---

# Common vulnerabilities & how this model mitigates them

> The quick summaries below pair the usual failure modes with the specific countermeasures you’ve put in place (or optional knobs you can turn on).

## 1) Physical / USB

**Threats**

- BadUSB / HID injection (fake keyboard/mouse), rubber-ducky style payloads
- Auto-mount of malicious storage; firmware backdoors on USB hubs

**Mitigations**

- **dom0 device policies**: `qubes.Input*` require **ask** and only from `sys-usb`; storage attaches **only** to VMs with the right **tag** (`usb_storage_ok`)
- **usbguard** in `sys-usb` with **default-deny** and explicit allowlist, plus **audit log**
- (Optional) Treat storage as **read-only** ingestion VM and copy files through qrexec to scanning VM

**Residual risk / tips**

- Human approval fatigue → keep “ask” meaningful; restrict tags to a tiny set
- Consider a **disposable ingest qube** for unknown drives; mount `nodev,nosuid,noexec`

---

## 2) Link / sys-net

**Threats**

- Layer-2 tracking via static MAC addresses
- Redirect/ARP spoofing local shenanigans; SYN floods

**Mitigations**

- **Randomized MAC** for Wi-Fi/Ethernet; sysctl: **no redirects**, **rp_filter=1**, **syncookies=1**
- (Optional) Disable unused protocols (e.g., IPv6) if your environment doesn’t need them

**Residual risk / tips**

- Public Wi-Fi still hostile → prefer VPN from an **app VM** or a dedicated **sys-vpn** between firewall and ids

---

## 3) Routing & egress policy / sys-firewall

**Threats**

- Silent egress to unexpected destinations (exfil), DNS tunneling
- DNS attribution loss (you don’t know which VM asked)

**Mitigations**

- **Per-VM default-drop** allowlists by service (e.g., only 443/53/123)
- **dnsmasq logging** provides **per-VM** view of DNS queries; optional **ECS/MAC** tagging for even stronger attribution

**Residual risk / tips**

- Application layer can still tunnel over allowed ports (e.g., 443). That’s what **Suricata** is for downstream.

---

## 4) DNS / sys-dns

**Threats**

- DNS spoofing/poisoning; privacy leakage to third-party upstreams; opaque DoH upstreams

**Mitigations**

- **Recursive** Unbound with **DNSSEC** and **qname-minimisation** (no opaque resolver trust)
- **Query & reply** logging + optional **DNSTAP** for forensics
- (Optional) **DoT** to a trusted upstream if you prefer privacy over transparency; or keep recursion to root for full validation

**Residual risk / tips**

- Pure recursion exposes patterns to the root/TLD ecosystem (not a “third-party” but still observable). Choose recursion vs DoT based on your **privacy vs transparency** preference.

---

## 5) IDS / sys-ids

**Threats**

- C2 callbacks over DNS/HTTPS; data exfil; protocol anomalies

**Mitigations**

- **Suricata** inline with **EVE** logs (`dns`, `flow`, `anomaly`) to detect tunneling and known indicators
- (Optional) Curate rule sets, add **ET Open / ET Pro** signatures; forward EVE to a **sys-log** sink

**Residual risk / tips**

- Encrypted traffic hides payloads; rely on **flow-based** and **DNS** indicators + policy (restrict destinations where possible)

---

## 6) Transport crypto / templates

**Threats**

- Weak TLS ciphers; downgraded protocol versions; clock skew breaking TLS/OCSP

**Mitigations**

- Debian: system OpenSSL **SECLEVEL** and GnuTLS overrides; Fedora: **crypto-policies**
- SSH client hardened (no password auth; modern KEX/Ciphers/MACs)
- **Chrony + NTS** for authenticated time

**Residual risk / tips**

- **Strict** policies can break legacy apps; use **per-template overrides** sparingly if needed

---

## 7) Application layer

**Threats**

- Browser or tool RCE, lateral movement, noisy background traffic

**Mitigations**

- **firejail + AppArmor** (Debian)/firejail (Fedora) sandboxing; network **default-drop** with minimal allows
- Split roles across **separate app VMs**; use **disposables** for high-risk browsing

**Residual risk / tips**

- Keep templates updated; restrict file exchange paths; consider **Split-GPG / Split-SSH** for keys

## DisposableVMs Helper (Qubes OS)

**Why disposables?**  
Disposable VMs (DispVMs) are short-lived sandboxes that launch from a clean template and are destroyed when closed. They’re perfect for opening untrusted links/files, viewing docs securely, and keeping state out of your main AppVMs.

### What this role does

- Creates one or more **named Disposable Templates** (e.g., `debian-12-dvm`, `fedora-40-dvm`) by setting `template_for_dispvms=True`.
- Sets the **system default** DispVM (`qubes-prefs default_dispvm`).
- Optionally sets **per-VM default** DispVMs (`qvm-prefs <vm> default_dispvm`).
- Installs **qrexec policy** so tagged VMs open URLs/files **in a DispVM** automatically:
  - `qubes.OpenURL` → `@dispvm:<name>`
  - `qubes.OpenInVM` → `@dispvm:<name>`

### Configure (pillar)

Edit `/srv/pillar/roles/dispvm.sls`:

```yaml
disposables:
  default_dispvm: debian-12-dvm
  create:
    debian-12-dvm:
      { template: debian-12-minimal, label: gray, netvm: sys-firewall }
    fedora-40-dvm:
      { template: fedora-40-minimal, label: gray, netvm: sys-firewall }
  per_vm_default:
    work-web: debian-12-dvm
    dev: fedora-40-dvm
  force_policies:
    openurl_tags: [mail, chat, work]
    openinvm_tags: [untrusted, work]
  fallback:
    openurl: ask
    openinvm: ask
```

## Usage examples (dom0):

# simple run

sudo ~/osi-security-healthcheck.sh

# assert specific disposables + defaults and actually spawn them

sudo ~/osi-security-healthcheck.sh --dvm "debian-12-dvm fedora-40-dvm" \
 --default-dispvm "debian-12-dvm" \
 --per-vm-default "work-web:debian-12-dvm dev:fedora-40-dvm" \
 --spawn-test

---

# Cross-cutting improvements (optional but recommended)

- **Central log sink** (`sys-log`): ship Unbound, dnsmasq, Suricata, usbguard logs via syslog/qrexec; rotate in service VMs, retain in log qube
- **Policy assertions**: nftables rule in `sys-firewall` to **drop all DNS not destined to `sys-dns`** (prevents bypass)
- **VPN egress**: insert `sys-vpn` between `sys-ids` and `sys-net`; enforce via policy & health check
- **Update cadence**: schedule template and service-VM updates; quarterly crypto policy review
- **Backups & recovery**: document how to rebuild `sys-dns`/`sys-ids` quickly (template packages + state apply)

---

# What “good” looks like (signals/KPIs)

- `dnsmasq.log` in `sys-firewall` shows **only** expected app VMs and domains
- `unbound.log` shows **validated** answers; **SERVFAIL** correlates with DNSSEC failures (good!)
- `eve.json` regularly contains **dns** and **flow** records; anomalies are alerting to you (even if just via grep + cron)
- Healthcheck script: **0 critical failures**, warnings only for truly optional items

---

# Tiny runbook (1-minute)

- Suspect DNS exfil? → `tail -f /var/log/dnsmasq.log` (sys-firewall) and `jq '.dns' /var/log/suricata/eve.json` (sys-ids)
- Unexpected domain? → confirm in `sys-dns:/var/log/unbound/unbound.log` (query+reply), then block per-VM in `qvm-firewall`
- USB incident? → `sys-usb:/var/log/usbguard/audit.log`; **remove rule** or **block device**; re-attach via disposable ingest

```

```

## Quick tests

In a work-tagged AppVM:

# Password lookup should route to vault-pass automatically

qpass github.com/you/repo

Split-GPG sign (work/dev/prod tag):

echo "test" | qgpg --clearsign | cat

Split-SSH agent availability (work/dev tag):

# Should prompt/allow via policy to vault-ssh

SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-} ssh -T git@github.com || true

Try from a VM without an allowed tag → expect ask/deny as per your fallback.
