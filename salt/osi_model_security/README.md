# OSI Model Security for Qubes OS — Paranoid Edition

This repository of Salt states and policies turns a stock Qubes OS system into a layered, leak‑resistant "OSI model" security stack with integrity verification and alerting. It is designed for high‑threat environments.

> **Scope**
>
> - Multi‑hop NetVM topologies (basic, VPN, VPN→Tor) with strict **nftables** guards
> - Per‑VM DNS transparency and control
> - Device hardening for **USB**, input (kbd/mouse), and **microphone** consent
> - Secrets workflow: **split‑GPG**, **split‑SSH**, **qubes‑pass**, tag‑based policies, admin time‑boxed tag
> - OPSEC hygiene across templates and service VMs
> - Vault air‑gaps; xen mitigations; TPM attestation
> - Signed‑only Salt deployments + daily integrity checks
> - End‑to‑end health checks and alerting via `sys-alert`

---

## TL;DR (Quick Start)

1. **Review & edit Pillars**:

   - `/srv/pillar/roles/net_topology.sls` — choose templates, set `active: basic`
   - `/srv/pillar/roles/hardening.sls` — enable kill‑switch, DNS, app default‑drop
   - `/srv/pillar/roles/secrets.sls` — set your vault VM names and allowed tags
   - `/srv/pillar/roles/opsec.sls` — list Debian templates to harden
   - `/srv/pillar/roles/integrity_alerts.sls` — set `vault_vm`, templates list, timers

2. **Apply everything** from dom0:

   ```bash
   sudo qubesctl --all state.apply osi_model_security
   ```

3. **Initialize integrity baselines** (first run):

   ```bash
   sudo systemctl start template-hash-verify.service
   sudo systemctl start policy-verify.service
   sudo systemctl start dom0-boot-verify.service
   sudo systemctl start tpm-attest-verify.service  # if TPM enabled
   ```

4. **Run the all‑in‑one check**:

   ```bash
   sudo /usr/local/sbin/osi-all-healthcheck
   ```

---

## Repository Layout (dom0)

```
/srv/salt/osi_model_security/
  init.sls                          # Orchestrator; includes roles below
  roles/
    topology/                       # NetVM creation & chain wiring
      init.sls
    net_guard/                      # nftables leak‑proofing for net VMs
      init.sls
    devices/                        # Device hardening (USB/input/mic) + verifier
      strict-devices.sls
    secrets/                        # Split‑GPG/SSH/pass basic policies & bootstrap
      init.sls
    secrets_advanced/               # Per‑op GPG, maintenance tag, logging, wrappers
      init.sls
    opsec/                          # Journald volatile, no coredumps, UTC, hostname rand
      init.sls
    hardening/                      # 100× systemic hardening (sysctl, VPN kill‑switch, etc.)
      init.sls
    integrity_alerts/               # Signed deploy, baselines, TPM, sys‑alert
      init.sls
    healthcheck_all/                # All‑in‑one healthcheck (CLI + timer)
      init.sls
```

**Pillars** under `/srv/pillar/roles/` mirror the roles above.

Pillar top:

```yaml
base:
  dom0:
    - roles.net_topology
    - roles.hardening
    - roles.secrets
    - roles.opsec
    - roles.integrity_alerts
```

---

## Network Topologies & Wiring

**Pillar**: `/srv/pillar/roles/net_topology.sls`

- Templates (as used): Fedora **42 minimal** for net VMs; Whonix‑GW for Tor
- Chains are ordered **from AppVM side → … → sys‑net**

```yaml
net_topology:
  templates:
    net: fedora-42-minimal
    whonix_gw: whonix-gateway-17

  vms:
    sys-net: { template: fedora-42-minimal, label: red, provides_network: true }
    sys-firewall:
      { template: fedora-42-minimal, label: orange, provides_network: true }
    sys-dns:
      { template: fedora-42-minimal, label: yellow, provides_network: true }
    sys-vpn:
      { template: fedora-42-minimal, label: black, provides_network: true }
    sys-whonix:
      { template: whonix-gateway-17, label: black, provides_network: true }

  chains:
    basic: { order: [sys-firewall, sys-dns] }
    vpn_after_dns: { order: [sys-firewall, sys-dns, sys-vpn] }
    vpn_then_tor: { order: [sys-vpn, sys-whonix] }

  active: basic
```

**Wiring** (state: `roles/topology`):

- Applies `netvm` pointers hop‑by‑hop ending at `sys-net`
- Tags hops with `topology_<active>`
- Points AppVMs to the **first hop**

### Switching the active chain

1. Edit `net_topology:active` (e.g., `vpn_after_dns`)
2. `sudo qubesctl --all state.apply osi_model_security`

---

## Net Guard (nftables kill‑switches & leak prevention)

**State**: `roles/net_guard`

- **sys-firewall**: drop forwarded `:53/tcp,udp`, `:853/tcp (DoT)`, and `:443/udp (QUIC)`
- **sys-dns**: only DNS (and optional NTP) may egress; optional **resolver allowlist** and DoT toggle
- **sys-vpn**: hard **kill‑switch** — permit tunnel interfaces (`wg0`/`tun0`) and specific VPN endpoints on `eth0`; drop all else
- **IPv6**: optional global disable in NetVMs to avoid v6 leaks

Configure via pillar knobs under `net_topology.guard` or the `hardening` role (below).

---

## 100× Hardening (systemic)

**Pillar**: `/srv/pillar/roles/hardening.sls`

- Vault air‑gapping (`netvm: none`)
- Common **sysctl** across service VMs (kptr/dmesg restrictions, rp_filter, no redirects, `fs.suid_dumpable=0`, optional IPv6 disable)
- **sys-net**: block LLMNR/mDNS/NetBIOS; strict forward policy
- **sys-firewall**: enforce no direct DNS / DoT / QUIC
- **sys-dns**: Unbound hardening + DNS‑only egress
- **sys-vpn**: strict kill‑switch (endpoints from pillar)
- **sys-ids**: logrotate & optional drop‑on‑anomaly wiring
- **AppVMs**: `qvm-firewall … set default drop` (allow rules come from your app pillar)
- OPSEC basics (volatile journals, no coredumps, minimal shell history) per service VM
- dom0: mask sleep/hibernate

Apply with the orchestrator; knobs are in the pillar file.

---

## Device Hardening (USB, Input, Microphone)

**State**: `roles/devices/strict-devices.sls`

- Creates/ensures **`sys-audio`** (networkless) and sets as `default_audiovm`
- Removes audio output from infra qubes (sys‑net, sys‑firewall, sys‑dns, sys‑vpn, sys‑ids, sys‑whonix)
- **Policy** `/etc/qubes/policy.d/30-device-hardening.policy`:

  - `qubes.USBAttach`: **ask**; restrict transport to `sys-usb`
  - `qubes.InputKeyboard/Mouse`: **ask** and only from `sys-usb → dom0`
  - `qubes.AudioInputEnable`: **ask** routed via `sys-audio`; disable is always allowed

- Verifier: `/usr/local/sbin/verify_device_hardening`

**Run**:

```bash
sudo /usr/local/sbin/verify_device_hardening
```

**Optional**: tag‑based allowlists (`@tag:usb-ok`) — uncomment sample rules in the policy file.

---

## Secrets: split‑GPG, split‑SSH, qubes‑pass (Multi‑vault)

**Pillar**: `/srv/pillar/roles/secrets.sls`

- Map vault VMs: `{ gpg: vault-gpg, ssh: vault-ssh, pass: vault-pass }`
- Tag‑based access control per service; **fallback** `ask|deny`
- Optional client helpers (`qpass`, `qgpg`, `qssh-add`) and `QUBES_*` env

**Advanced** (`roles/secrets_advanced`):

- **Per‑operation Split‑GPG services**: `gpg.Sign`, `gpg.Decrypt`, `gpg.Encrypt`, `gpg.Verify`
- **Maintenance tag** (default: `gpg_admin_30m`) with **auto‑expiry** tool:

  - CLI: `/usr/local/sbin/qubes-secrets-maint add <vm> [minutes]` | `del <vm>`

- **qrexec audit logging** → `/var/log/qubes/audit-secrets.log`

**Healthcheck**:

```bash
sudo /usr/local/sbin/osi-secrets-opsec-check.sh
```

---

## OPSEC OS Extras

**Pillar**: `/srv/pillar/roles/opsec.sls`

- Debian template list: `deb_harden`, `deb_harden_min`, `deb_work`, `deb_hack`
- journald **Storage=volatile**, no coredumps, **no shell history**
- UTC timezone + neutral locale
- Randomized hostname per boot (systemd unit) for AppVMs from those templates
- sys‑net Wi‑Fi hygiene (no autoconnect, MAC rand scanning), Bluetooth disabled
- dom0 sleep/hibernate masked

---

## Integrity & Alerts Stack

**State**: `roles/integrity_alerts`

- **`sys-alert`** (networkless) with service `my.alert.Send`; sender allowlist from pillar
- **Signed‑only Salt**: `/usr/local/sbin/signed-highstate` → verify sig → stage → backup → deploy → baseline update → highstate
- **Baselines + daily verify**:

  - `/srv/salt` tree hash → vault
  - Templates full‑FS hash → vault
  - `/etc/qubes/policy.d` pack hash → vault
  - dom0 `/boot` + `/usr/lib/xen` hash → vault
  - **TPM** PCR(0,2,5,7) JSON baseline (if enabled) → vault

- **Conservative Xen mitigations** (configurable cmdline)

**Verifiers**:

```bash
sudo /usr/local/sbin/verify_security_integrity
# or component scripts:
sudo /usr/local/sbin/salt-tree-verify.sh
sudo /usr/local/sbin/qubes-template-hash-verify.sh
sudo /usr/local/sbin/qubes-policy-verify.sh
sudo /usr/local/sbin/dom0-boot-verify.sh
sudo /usr/local/sbin/qubes-tpm-pcr-verify.sh
```

**Timers** (daily by default):

- `template-hash-verify.timer`, `policy-verify.timer`, `salt-tree-verify.timer`, `dom0-boot-verify.timer`, `tpm-attest-verify.timer`

---

## All‑in‑one Healthcheck

**State**: `roles/healthcheck_all`

- **CLI**: `/usr/local/sbin/osi-all-healthcheck`

  - Topology wiring and hop verification
  - nftables guard presence (sys‑firewall/sys‑dns/sys‑vpn/sys‑net)
  - Device policies (via `verify_device_hardening`)
  - Secrets/OPSEC (`osi-secrets-opsec-check.sh`)
  - Integrity (`verify_security_integrity`)

- **Timer**: `osi-all-healthcheck.timer` (defaults hourly; configurable in pillar `integrity_alerts.timers.all_in_one`)
- On failure, short alert is sent to **`sys-alert`** and full logs are saved in `/var/log/osi/health/`

---

## VPN & DNS: Customization

- **VPN endpoints** (WireGuard/OpenVPN) are configured via pillar (`hardening.vpn.endpoints` or `net_topology.guard.vpn.endpoints`). Example:

```yaml
hardening:
  vpn:
    killswitch: true
    type: wireguard
    endpoints:
      - { ip: 203.0.113.10, port: 51820, proto: udp }
      - { ip: 198.51.100.20, port: 51820, proto: udp }
```

- **DNS resolver allowlist** (tight egress from `sys-dns`):

```yaml
hardening:
  dns:
    only_dns_out: true
    dot_upstream: false
    resolver_allowlist: ["9.9.9.9", "149.112.112.112"]
```

---

## Operational Runbook

- **Switch topology**: edit pillar → apply → verify via `osi-all-healthcheck`
- **Grant temporary GPG admin**: `sudo qubes-secrets-maint add <vm> 30m`; import/export keys via `qgpg-import` / `qgpg-export`; tag auto‑removes
- **Rotate integrity baselines** (after intentional changes):

  - Salt: `signed-highstate` (auto updates salt baseline)
  - Policy pack: run `policy-baseline` state or re‑emit hash to vault
  - Templates/dom0 boot: re‑baseline scripts exist; or re‑initialize by re‑running `*-baseline` portions as needed

- **Respond to alerts**: open `sys-alert` → inspect `/var/log/sys-alert.log` and dom0 `/var/log/qubes/audit-secrets.log`

---

## Logs & Files Cheat Sheet

- Alerts sink: **`sys-alert:/var/log/sys-alert.log`**
- qrexec audit mirror: **`/var/log/qubes/audit-secrets.log`** (dom0)
- All‑in‑one reports: **`/var/log/osi/health/`** (dom0)
- Integrity baselines in vault: **`/home/user/.template-hashes/*.sha256`**, **`/home/user/.policy-hashes/qubes-policy.sha256`**, **`/var/lib/qubes/salt-hashes/*`** (as configured)
- Device policy: **`/etc/qubes/policy.d/30-device-hardening.policy`**

---

## Security Model & Assumptions

- Policies are **default‑deny or ask** for sensitive device actions
- DNS goes through **sys-dns only**; apps cannot DoH/DoT/QUIC‑bypass
- VPN kill‑switch prevents raw uplink leaks if the tunnel drops
- Vaults are **air‑gapped** (no NetVM)
- Integrity checks are **out‑of‑band stored** in a vault and verified daily
- `sys-alert` is **networkless**, receives qrexec alerts only from allowlisted VMs

> **Reboots required** when changing **Xen cmdline mitigations**.

---

## Tags Used

- `topology_<name>` — applied to each hop VM of the active chain
- `layer_app` — (optional) tag your AppVMs for healthcheck discovery
- `usb-ok` — (optional) tag for allowing USBAttach on selected VMs
- `gpg_admin_30m` — temporary tag granting GPG admin RPCs (auto‑expires)

---

## Troubleshooting

- **No DNS from AppVMs**: confirm `sys-firewall` blocks forwarded `:53`, and `sys-dns` is reachable; check `nft list ruleset` in both
- **Traffic leaks when VPN down**: verify `sys-vpn` nftables table exists and endpoints match pillar; run `osi-all-healthcheck`
- **Policy hash mismatch** after edits: re‑baseline policy via `policy-baseline` (or re‑run the baseline step in `roles/integrity_alerts`)
- **TPM verify empty**: ensure `tpm2-tools` installed and PCR baseline exists in vault

---

## Maintenance & Backups

- The signed deploy script creates **compressed backups** of `/srv/salt` under `{{backups_dir}}` before each update
- Keep a secure, offline copy of your **public key** used to sign Salt bundles and of your **vault‑secrets** AppVM

---

## Appendix A — Notable Commands

```bash
# Apply all roles
sudo qubesctl --all state.apply osi_model_security

# Healthchecks
sudo /usr/local/sbin/osi-all-healthcheck
sudo /usr/local/sbin/verify_security_integrity
sudo /usr/local/sbin/verify_device_hardening
sudo /usr/local/sbin/osi-secrets-opsec-check.sh

# Signed highstate
sudo /usr/local/sbin/signed-highstate

# Maintenance tag (temporary GPG admin)
sudo /usr/local/sbin/qubes-secrets-maint add <vm> 30m
sudo /usr/local/sbin/qubes-secrets-maint del <vm>
```

---

## Appendix B — Qrexec Services (custom)

- `my.alert.Send` — dom0/sys‑\* → `sys-alert` notification sink
- `gpg.Sign`, `gpg.Decrypt`, `gpg.Encrypt`, `gpg.Verify` — per‑operation Split‑GPG
- `gpg.AdminImport`, `gpg.AdminExport` — guarded by maintenance tag

(Plus standard Qubes services: `qubes.Gpg`, `qubes.SshAgent`, `qubes.PassLookup`, `qubes.USBAttach`, `qubes.USB`, `qubes.USBDetach`, `qubes.InputKeyboard`, `qubes.InputMouse`, `qubes.AudioInputEnable`, `qubes.AudioInputDisable`.)

---

## License & Disclaimer

These states are provided **as‑is**. They make significant changes to networking and policies in a high‑assurance configuration. Review every file in **dom0** before applying and keep offline backups of your Pillars, policies, and vaults. Use at your own risk.
