## ✅ What you already have

- **Base templates**

  - `debian-12-hard` (hardened, security baseline)
  - `debian-12-hard-min` (lean, sys-net/sys-firewall/sys-usb)
  - `debian-12-work` (dev stack with VS Code, Postman, Mongo Compass, Docker, etc.)
  - `fedora-41-xfce` → derived into `fedora-41-vpn-min` for sys-vpn

- **Core service qubes**

  - `sys-net` → physical NIC driver only
  - `sys-firewall` → nftables firewall rules + per-packet logging
  - `sys-usb` → USB isolation
  - `sys-dns` → DNSCrypt-proxy enforcing encrypted DNS
  - `sys-vpn` → VPN (OpenVPN/WireGuard via NetworkManager, killswitch)

- **Security qubes**

  - `vault` (offline, no NetVM, for storage of secrets/files)
  - `secrets-vault` (split-GPG & split-SSH endpoint, no NetVM)

- **User qubes**

  - `personal` (daily driver, hardened template)
  - `work` (development stack template)
  - `untrusted` (browser/quarantine VM)
  - `anon-whonix` (for Tor traffic, via Whonix)

- **Disposables**

  - `DefaultDVM` (based on debian-12-hard, global disposable)
  - `anon-disposable` (Whonix workstation DVM)

- **Policies**

  - Split-GPG + Split-SSH wired via qrexec
  - Vault accessible only via RPC policies

- **Monitoring**

  - Rotating pcaps in `sys-dns` + `sys-vpn`
  - nft logging in `sys-firewall` + `sys-net`
  - Nightly backup of logs into `secrets-vault`
  - Viewer + pull script in `work` for Wireshark review

---

## ❓ What’s still missing / optional to complete the picture

1. **Update proxying & repo hygiene**

   - Decide if you want to run updates through `sys-vpn` (hides metadata from your ISP).
   - Or keep updates through `sys-firewall/sys-net` directly (faster, standard Qubes).
   - Some folks also run a caching proxy like `apt-cacher-ng` or `dnf-automatic` in a service qube.

2. **Qrexec policies audit**

   - Right now, policies are mostly defaults + split-GPG/SSH.
   - A best practice is to explicitly deny everything by default, then whitelist per-service (`qubes.Filecopy`, `qubes.OpenInVM`, etc.).
   - E.g., `work → vault : qubes.Filecopy = ask` but deny from `untrusted`.

3. **USB security refinement**

   - You have `sys-usb`, but you might want:

     - **U2F proxy** → so USB keys work only via sys-usb with qrexec forwarding.
     - **Block storage devices** from auto-attaching unless explicitly allowed.
     - Enable **usbguard** rules inside `sys-usb`.

4. **Networking extras**

   - You have DNSCrypt + VPN. Some people also add:

     - **Tor gateway chaining**: app qubes → sys-firewall → sys-dns → sys-vpn → sys-whonix → sys-net.
     - **Split-tunnel**: one sys-vpn for work, one direct chain for non-sensitive traffic.

   - You might also want **bandwidth monitoring** in `sys-net` (lightweight tools like `vnstat` or `iftop`).

5. **System health monitoring**

   - Right now you’re logging traffic. Next step:

     - Add a minimal qube for **metrics & alerts** (collectd, or `monit`) that pulls system load, disk usage, VM health, and forwards summaries to vault.
     - Helps to spot runaway processes or storage exhaustion early.

6. **Template hardening polish**

   - You already pruned GUI packages in min templates. Additional common tweaks:

     - AppArmor profiles (enabled in Debian by default but can be tuned).
     - Disable unneeded systemd services (`cups`, `avahi`, etc. — likely already removed).
     - Ensure `needrestart` and `unattended-upgrades` are active.

7. **Disposable workflows**

   - Global `DefaultDVM` is in place. Next:

     - Configure `work` and `personal` to open **attachments/browsers in disposables** by default.
     - Configure “Open in DisposableVM” policies for PDFs, Office docs, and downloads.

8. **Backups**

   - You have log archiving to vault. Still need a **formal Qubes backup routine** (via `qvm-backup`).
   - Best practice: run weekly backups into an **offline external disk** attached via `sys-usb`.

9. **Qubes updates + dom0 security**

   - Ensure dom0 updates are configured to use `sys-firewall` as UpdateVM.
   - Harden dom0: no extra software, minimal qrexec exposure.

10. helper scripts for common tasks

    - Network Topology change per vm
    - Qrexec policy audit
    - List installed packages per template
    - List running services per template
    - List enabled systemd units per template
    - List open ports per template
    - List usb devices allowed in sys-usb
    - List firewall rules per netvm
    - List cron jobs per template
    - List AppArmor profiles per template
    - system leak check (dns, mac, ipv6, tor leaks)
    - dom0 integrity check (check for modified files in /etc, /usr, /lib)
    - template integrity check (check for modified files in /etc, /usr, /lib)
    - add core health assertion

---

## TL;DR: Remaining pieces to “world-class” Qubes setup

- 🔒 Tighten **qrexec policies** (deny all, allow only needed flows)
- 🔑 Add **USB hardening** (u2f-proxy, usbguard rules)
- 📡 Optionally add **metrics/alerts qube** for host health
- 📊 Add **bandwidth monitoring** in `sys-net`
- 📦 Ensure **regular Qubes backups** configured & tested
- 📑 Expand **disposable defaults** (open risky docs/browsers only in DVMs)
