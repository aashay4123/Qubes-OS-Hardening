# README — sys-vpn (VPN Service Qube) in Qubes OS 4.2.4

## 1. Purpose

`sys-vpn` is a **dedicated service qube** that creates and maintains a VPN tunnel (OpenVPN or WireGuard) between your Qubes system and your VPN provider.
Its job is simple:

- Accept network traffic from your system,
- Send it securely through the tunnel,
- Drop or block anything that would otherwise leak outside.

This ensures **all internet-facing traffic** from your personal and work VMs leaves via your VPN provider, while still preserving Qubes’ modular security.

---

## 2. Template

- **Base template**: You currently have `fedora-41-xfce`.
- We will clone this into a **minimal VPN template** (e.g., `fedora-41-vpn-min`) and remove non-essential packages (XFCE UI, desktop apps).
- We’ll add only what’s needed:

  - `NetworkManager` (already included in Fedora XFCE)
  - VPN plugins: `NetworkManager-openvpn` or `NetworkManager-wireguard` (depending on your provider)
  - `openvpn` / `wireguard-tools` CLI clients
  - `nftables` for firewall (killswitch)
  - Logging tools: `tcpdump`, `iproute2`, and journal logging

This makes `sys-vpn` lightweight, secure, and auditable.

---

## 3. Network Topology

Your new chain will look like this:

```
AppVMs (personal, work, anon, etc.)
   ↓
sys-firewall
   ↓
sys-dns (with DNSCrypt)
   ↓
sys-vpn (with VPN tunnel)
   ↓
sys-net (physical uplink to ISP)
```

- **sys-firewall**: enforces Qubes firewall rules per VM.
- **sys-dns**: ensures all DNS is encrypted via DNSCrypt and routed inside the tunnel.
- **sys-vpn**: encrypts _all_ traffic with VPN, and prevents leaks if tunnel drops.
- **sys-net**: only talks to your ISP/uplink.

---

## 4. Logging & Monitoring

- **System logs**:

  - `journalctl -u NetworkManager` shows VPN session logs.
  - `nmcli connection show --active` shows active VPN.

- **Firewall logs**: nftables rules can log dropped packets (for debugging leaks).
- **Network captures**: `tcpdump -ni any port 53` → should show **no DNS leaks** outside `tun0`.

All logs remain in `sys-vpn` (not exposed to AppVMs), which is the correct Qubes security model.

---

## 5. VPN Configuration

- VPN config files (`.ovpn` for OpenVPN, `.conf` for WireGuard) live in `/rw/config/vpn/`.
- We will import them with `nmcli` or place them in `/etc/NetworkManager/system-connections/`.
- **Autostart**: mark the VPN connection with `connection.autoconnect yes`.
- **Secrets** (username/password, keys): stored in `/rw/config/vpn/credentials/` with restrictive permissions.

At boot, `sys-vpn` will automatically:

1. Start NetworkManager.
2. Bring up the VPN connection.
3. Apply nftables killswitch rules (allow only VPN server’s IP/port until tunnel is up).

---

## 6. Killswitch (No-Leak Guarantee)

- **Before tunnel up**: only allow outbound traffic to the VPN provider’s server IP/port.
- **After tunnel up**: allow everything, but force it into tun0.
- If tunnel drops: traffic is dropped, nothing leaks via `sys-net`.

This ensures that **even if VPN fails**, your real IP never leaks.

---

## 7. VM Connections

- **Personal VM**: connects via `sys-firewall → sys-dns → sys-vpn`. All personal browsing, work, and comms are inside VPN.
- **Work VM**: same chain; ensures developer tools and updates leave through VPN.
- **Anon/Untrusted**: optional. You may wire these through sys-vpn for added anonymity, or keep them direct → sys-firewall → sys-dns → sys-net if you want them outside VPN.
- **Whonix VMs**: should **not** use sys-vpn, because Tor handles anonymity. Leave their NetVM as Whonix-gateway.

This way you get **split networking**:

- Some VMs through VPN,
- Some through Tor,
- Some directly (if you want).

---

## 8. Day-to-Day Usage

- To verify VPN:

  ```bash
  qvm-run -p sys-vpn 'curl ifconfig.me'
  ```

  Should show your VPN provider’s IP.

- To check from a client VM:

  ```bash
  qvm-run -p personal 'curl ifconfig.me'
  ```

  Should show the **same VPN IP**.

- To disconnect:

  ```bash
  qvm-run sys-vpn 'nmcli connection down myvpn'
  ```

- To reconnect:

  ```bash
  qvm-run sys-vpn 'nmcli connection up myvpn'
  ```

---

## 9. Security Posture

- VPN keys and configs are isolated in `sys-vpn`.
- AppVMs never see VPN credentials.
- If VPN tunnel breaks, nftables blocks all traffic (no leaks).
- DNSCrypt still runs **inside tunnel**, preventing ISP or VPN from seeing plaintext DNS queries.
- Logs are contained in `sys-vpn` and can be rotated automatically.

---

## 10. Reconfiguration

- To **change VPN provider**: replace the `.ovpn` or `.conf` in `/rw/config/vpn/` and update autoconnect.
- To **add another VPN profile**: import new config via `nmcli` or `nm-connection-editor`.
- To **add/remove VMs from VPN**:

  - To use VPN: set their NetVM → `sys-firewall`. (They’re already chained to `sys-vpn`).
  - To bypass VPN: create another firewall qube wired to `sys-net` directly, assign those VMs there.

---

## 11. Why this is best practice in 2025

- Qubes **4.2 service-qube model** explicitly recommends: “put VPN in its own NetVM, don’t mix with firewall.”
- Fedora template: stable, well-maintained VPN plugins, minimal manual setup.
- nftables killswitch: modern, robust, leak-proof.
- Separation of DNSCrypt (`sys-dns`) and VPN (`sys-vpn`): each layer has a single job.
- Flexibility: you can route some VMs through Tor, some through VPN, some directly — without interfering with each other.

---

✅ With this plan, you’ll have:

- A minimal Fedora-based `sys-vpn`,
- DNSCrypt inside the tunnel,
- Killswitch to prevent leaks,
- Clean logging and easy reconfiguration,
- A reproducible Salt state to deploy it all.
  Got it — I did a fresh pass over current Qubes 4.2.4 docs and recent forum guidance, then compared that with what we’ve built for **sys-dns** and what you want for **sys-vpn**. Here’s what actually matters (with sources), plus the two deliverables you asked for:

---

# What’s off in our current design (and why)

1. **Where nft rules live & when they apply.**
   Qubes 4.2 uses **nftables** and explicitly tells you where to put _local_ rules so they’re applied early and survive restarts:

- In VMs **supplying networking** (e.g., `sys-dns`, `sys-vpn`, `sys-firewall`), put commands in **`/rw/config/qubes-firewall-user-script`** (this runs when the NetVM starts). Qubes warns not to rely on `rc.local` to prevent leaks because it runs _after_ the network is up. We should move our DNAT and killswitch logic there. ([Qubes OS][1])

2. **Service qubes should not be the firewall; and ideally sit between two firewalls.**
   Qubes advises a “**network service qube**” model: do **not** tinker with rules in the firewall qube and, for maximum isolation, place service qubes **between two firewall qubes** (a “firewall → service → firewall” sandwich). Our chain works, but adding a second firewall after services is considered more robust. ([Qubes OS][1])

3. **NAT hook: there’s no official `custom-nat` hook yet.**
   In 4.2, there are **`custom-input`/`custom-forward`** hooks for filter rules. For NAT, the project has an **open issue** discussing a future custom-nat chain. Until then, you either add rules in Qubes’ `qubes` table (e.g., a small **custom DNAT chain** attached to `prerouting`) or use a small auxiliary NAT table. We’ll switch to Qubes’ own `qubes` table and a **custom DNAT chain** created from `qubes-firewall-user-script` (cleaner, closer to docs). ([GitHub][2], [Qubes OS][1])

4. **DNSCrypt bootstrap ordering.**
   Several users hit a snag if DNAT to `127.0.0.1:53` blocks the **first resolver list download**. Fix is to ensure **dnscrypt-proxy starts before DNAT**, _or_ allow bootstrap; using `qubes-firewall-user-script` (runs early) plus a service that starts dnscrypt first solves this reliably. We’ll codify that ordering. ([Qubes OS Forum][3])

5. **VPN killswitch placement & semantics.**
   In 4.2, killswitches should use nft in the **service qube** (`sys-vpn`) and be applied early. Minimal, robust pattern:

- Allow **only** traffic to the VPN endpoints on the physical uplink **before** tunnel is up.
- Allow all outbound/forward **only via `tun0`** once connected.
- Drop everything else.
  Accepted practice in community guides & vendor write-ups (WireGuard/OpenVPN on Qubes). ([Qubes OS Forum][4], [Mullvad VPN][5])

---

# README — **resolvefix.md** (for sys-dns)

> Save this text as `/srv/salt/qubes/network/docs/resolvefix.md` (or wherever you track docs).

## Goal

Make `sys-dns` (Debian 12 hard-min) leak-proof, reproducible, and compliant with Qubes 4.2.4 nft guidance.

## Fix Summary

- **Move DNS DNAT rules** into **`/rw/config/qubes-firewall-user-script`** (in `sys-dns`).
- Use a **custom DNAT chain** inside the Qubes `qubes` table (no direct edits to Qubes’ internal chains).
- Ensure **dnscrypt-proxy** is up **before** DNAT is applied (bootstrap-safe).
- Keep `/etc/resolv.conf` in `sys-dns` pointing to `127.0.0.1` with `options trust-ad`.
- Keep `sys-firewall → sys-dns → sys-net` (or adopt the sandwich model if you add a second firewall). ([Qubes OS][1])

## Exact steps to conform

1. **Inside `sys-dns`: enable dnscrypt-proxy first**

```bash
sudo systemctl enable --now dnscrypt-proxy
sudo systemctl is-active dnscrypt-proxy
```

(If resolver lists are missing, this ensures the first fetch succeeds before DNAT.) ([Qubes OS Forum][3])

2. **`/etc/dnscrypt-proxy/dnscrypt-proxy.toml` sanity**

- `listen_addresses = ["127.0.0.1:53"]`
- `server_names` set to your preferred resolvers
- (Optional) `forwarding_rules` for internal zones
  DNSCrypt TOML & public-resolvers minisign key are as per upstream docs.

3. **Pin VM’s resolver**

```bash
printf "nameserver 127.0.0.1\noptions trust-ad\n" | sudo tee /etc/resolv.conf
```

4. **Create / update `qubes-firewall-user-script` in `sys-dns`**

```bash
sudo -i
cat > /rw/config/qubes-firewall-user-script <<'EOF'
#!/bin/sh
# Create or reuse a DNAT chain for DNS in the Qubes table (prerouting NAT).
# This attaches early at NetVM start, before clients use sys-dns.

# Ensure DNAT chain exists
nft list chain ip qubes custom-dnat-dns >/dev/null 2>&1 || \
  nft add chain ip qubes custom-dnat-dns '{ type nat hook prerouting priority dstnat + 5 ; policy accept ; }'

# Idempotent add of DNAT rules to 127.0.0.1:53
RULES="$(nft list chain ip qubes custom-dnat-dns 2>/dev/null || true)"
echo "$RULES" | grep -q 'udp dport 53 .* dnat to 127.0.0.1' || \
  nft add rule ip qubes custom-dnat-dns udp dport 53 dnat to 127.0.0.1

echo "$RULES" | grep -q 'tcp dport 53 .* dnat to 127.0.0.1' || \
  nft add rule ip qubes custom-dnat-dns tcp dport 53 dnat to 127.0.0.1
EOF
chmod +x /rw/config/qubes-firewall-user-script
systemctl restart qubes-firewall
```

This aligns with the Qubes 4.2 “where to put rules” guidance, avoids `rc.local`, and avoids fiddling with internal chains directly. ([Qubes OS][1])

5. **Wire order**

- `sys-firewall` NetVM → `sys-dns`
- `sys-dns` NetVM → `sys-net`
  (If you adopt the **service-sandwich**, insert a second firewall after services per doc.) ([Qubes OS][1])

### How to provide your **endpoint IPs** and **.ovpn**

- Copy your provider’s **numeric IP(s)** to `sys-vpn:/rw/config/vpn/endpoints.txt`, one per line.
  (Numeric IPs avoid DNS before the tunnel is up. Most providers document the IPs or you can resolve once and pin them.) ([Mullvad VPN][5])
- Place your `myvpn.ovpn` in `sys-vpn:/rw/config/vpn/` (or drop it in `/srv/salt/files/vpn/myvpn.ovpn` and we’ll move it in a later iteration).

### Why these choices

- **`qubes-firewall-user-script`** is the place Qubes 4.2 expects local rules for NetVMs, and it runs early enough to avoid leak windows. ([Qubes OS][1])
- The killswitch uses **custom-output/custom-forward** chains and a dedicated **endpoints set**, which is the pattern community guides have converged on for 4.2. ([Qubes OS Forum][4])
- Rewiring `sys-dns → sys-vpn` keeps **DNSCrypt inside the tunnel**. Qubes’ network-service-qube model explicitly supports composing services this way (and, if you want to go further, placing a second firewall on the client side). ([Qubes OS][1])

---

## Run it

```bash
# Build sys-vpn and wire DNS through it
sudo qubesctl state.show_sls qubes.network.sys-vpn
sudo qubesctl --show-output state.sls qubes.network.sys-vpn
```

**After** you add your endpoint IPs and `.ovpn`, bring the connection up:

```bash
qvm-run -p sys-vpn 'nmcli connection up "$(nmcli -t -f NAME,TYPE connection show | awk -F: '\''$2=="vpn"{print $1;exit}'\'')"'
```

Check your public IP from a client (e.g., `personal`):

```bash
qvm-run -p personal 'curl -4 ifconfig.co/ip'
```

It should match your VPN egress IP.

---

## Sources I used (fresh 2025 check)

- **Qubes 4.2 Firewall doc** — nftables, network service qubes, where to put rules (`qubes-firewall-user-script`), and leak warning for `rc.local`. ([Qubes OS][1])
- **DNSCrypt on Qubes**—community guidance to move it to a separate `sys-dns`, and bootstrap caveat/order. ([Qubes OS Forum][6])
- **No official custom-nat hook** yet—community issue; we attach a small DNAT chain in the Qubes table instead. ([GitHub][2])
- **VPN on Qubes 4.2**—forum instructions for 4.2, and WireGuard/OpenVPN practices incl. killswitch reasoning. ([Qubes OS Forum][7], [Mullvad VPN][5])

awesome — here’s exactly what you asked for:

- a tight **README (sysvpn-improvements.md)** with common bugs, fixes, and small improvements you can apply
- a **test.sh** you run from **dom0** that verifies your VPN stack end-to-end (no DNS leaks, killswitch works, egress IP = VPN, and it restores state at the end)

both are written for Qubes 4.2.4, assuming your chain is:

```
AppVMs → sys-firewall → sys-dns → sys-vpn → sys-net
```

and `sys-vpn` uses **NetworkManager** (OpenVPN or WireGuard), with an **nftables killswitch** in `/rw/config/qubes-firewall-user-script` and your **dnscrypt-proxy** in `sys-dns`.

# sysvpn-improvements.md

## Quick checklist

- `sys-vpn` is **ProxyVM** (AppVM class, `provides-network=true`), **NetVM=sys-net**
- `sys-dns` **NetVM=sys-vpn** (so DNSCrypt rides inside the tunnel)
- `sys-firewall` **NetVM=sys-dns**
- VPN profile imported into `sys-vpn` via NetworkManager and set `connection.autoconnect yes`
- Killswitch lives in `sys-vpn:/rw/config/qubes-firewall-user-script` (not rc.local)
- `sys-vpn:/rw/config/vpn/endpoints.txt` contains **numeric VPN endpoint IPs** (one per line)
- `dnscrypt-proxy` in `sys-dns` listens on `127.0.0.1:53`, and **DNAT 53→127.0.0.1** is applied by `qubes-firewall-user-script` in `sys-dns`

## Small but important improvements

1. **Early application of rules**
   Put all local nftables changes in `/rw/config/qubes-firewall-user-script` (in each NetVM). It executes early with the Qubes firewall stack and survives restarts.

2. **Bootstrap order**
   Start services **before** you enforce captures:

   - In `sys-dns`: enable `dnscrypt-proxy` before DNAT rules to avoid blocking the initial resolver list fetch.
   - In `sys-vpn`: import the VPN connection and set autoconnect, then apply the killswitch that only allows traffic to the endpoints and via `tun0`.

3. **Endpoint pinning**
   Prefer **numeric IPs** for the VPN server in both your `.ovpn` and `endpoints.txt` to avoid DNS use before the tunnel is established.

4. **Minimal template**
   Keep `fedora-41-vpn-min` lean. Only: NetworkManager, VPN plugin(s), nftables, iproute2, tcpdump, curl. Disable/disable-remove desktop bits you don’t need.

5. **Logging you’ll actually use**

   - `sys-vpn`: `journalctl -u NetworkManager`, `nmcli -t -f NAME,TYPE,DEVICE connection show --active`
   - `sys-dns`: `journalctl -u dnscrypt-proxy`, `ss -tupon | egrep 'dnscrypt|:853|:443'`
   - Targeted captures: `tcpdump -ni any port 53` in `sys-dns`, and `tcpdump -ni any not '(oif tun0)'` in `sys-vpn` when debugging leaks

## Common bugs & quick fixes

- **VPN connects but traffic still leaks outside tun0**
  Your killswitch likely isn’t in `qubes-firewall-user-script`, or rules don’t reference `oif "tun0" accept` + final `drop`. Move rules to the script, restart `qubes-firewall`.

- **VPN won’t come up on boot**
  Connection wasn’t imported or not set to autoconnect. In `sys-vpn`:
  `nmcli connection import …` then `nmcli connection modify <name> connection.autoconnect yes`.

- **DNS leak (plain :53 seen leaving sys-dns)**
  DNAT is missing or applied too late. Put DNAT rules for tcp/udp 53 → 127.0.0.1 in `sys-dns:/rw/config/qubes-firewall-user-script`, restart `qubes-firewall`, verify with tcpdump.

- **DNS breaks at boot**
  DNAT to 127.0.0.1 is active before `dnscrypt-proxy` is ready. Ensure `dnscrypt-proxy` is enabled and healthy first, or keep DNAT in the firewall user script (runs when Qubes firewall comes up, post-service).

- **Some VMs shouldn’t use VPN**
  Add a parallel chain: `sys-firewall-novpn → sys-net`. Point those VMs to that firewall instead of the default one.

# test.sh (run from **dom0**)

What it does:

- Confirms chain wiring
- Detects active VPN profile (OpenVPN or WireGuard) in `sys-vpn`
- Captures traffic to prove:

  - **No plaintext DNS** egress from `sys-dns`
  - **All egress goes via VPN** (public IP matches VPN)

- **Killswitch test**: drops the VPN and confirms traffic is blocked, then **restores** the previous state

> Save as `/home/user/test_sysvpn.sh`, `chmod +x` and run from dom0.

### What the script covers

- **Wiring** correctness
- **Active VPN** presence
- **Egress IP** behavior (VPN vs sys-net)
- **DNS leak** (none should leave `sys-dns`)
- **Killswitch** (egress should fail with VPN down)
- **State restore** (VPN brought back up)

---

If you want, I can also package this as a Salt **test SLS** (similar to what we did for sys-dns) so you can run:

```bash
sudo qubesctl --show-output state.sls qubes.tests.sys-vpn
```

But the `test.sh` above is quick to run and prints loud, actionable failures.

# "References"

[1]: https://www.qubes-os.org/doc/firewall/ "
    
      Firewall | Qubes OS
    
  "
[2]: https://github.com/QubesOS/qubes-issues/issues/8629?utm_source=chatgpt.com "Add a custom-nat chain in the firewall · Issue #8629"
[3]: https://forum.qubes-os.org/t/guide-how-to-setup-a-sys-dns-qube/13749?page=5&utm_source=chatgpt.com "[guide] how-to setup a sys-dns qube - Page 5"
[4]: https://forum.qubes-os.org/t/wireguard-vpn-setup/19141?utm_source=chatgpt.com "Wireguard VPN setup - Community Guides"
[5]: https://mullvad.net/en/help/wireguard-on-qubes-os?utm_source=chatgpt.com "WireGuard on Qubes OS"
[6]: https://forum.qubes-os.org/t/guide-how-to-setup-a-sys-dns-qube/13749?page=2&utm_source=chatgpt.com "[guide] how-to setup a sys-dns qube - Page 2"
[7]: https://forum.qubes-os.org/t/vpn-instructions-for-4-2/20738?utm_source=chatgpt.com "VPN instructions for 4.2 - User Support"
