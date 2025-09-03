# README — `leakcheck.sls` (15+ routing/privacy leak tests)

## What it does

Runs a **one-shot battery** of lightweight tests across your VMs and writes:

```
dom0: /var/lib/qubes/leakcheck/YYYY-MM-DD/summary.txt
dom0: /var/lib/qubes/leakcheck/YYYY-MM-DD/results.csv   # PASS/FAIL table
```

The tests **do not** change your routing; they just observe. They check for the most common leak classes people care about on Qubes 4.2.x / Whonix, including DNS, IPv6, VPN routing, Tor egress, STUN/WebRTC surface, NTP/mDNS noise, RFC1918 reachability from untrusted, nftables presence, etc. ([Qubes OS][7], [Whonix][8])

## How to run

```bash
sudo qubesctl --show-output state.sls qubes.audit.leakcheck
cat /var/lib/qubes/leakcheck/$(date -I)/summary.txt
column -s, -t </var/lib/qubes/leakcheck/$(date -I)/results.csv | less -S
```

## Key checks included (examples)

- **DNS pathing**: App qubes use Qubes stub resolver; **no plaintext UDP/53** leaving `sys-dns`. ([Qubes OS][7])
- **IPv6**: No default v6 route from `personal` (or, if present, not usable). ([Whonix][8])
- **VPN**: `sys-vpn` default route via `tun*`; nft killswitch rules mention the tun device.
- **Tor**: `anon-whonix` returns `IsTor=true` via Tor Project API. ([Whonix][8])
- **STUN/WebRTC surface** (advisory): passive capture for UDP/3478 bursts (browser-level hardening still recommended). ([Whonix Forum][9])
- **NTP/mDNS**: unexpected chatter from app VMs.
- **RFC1918 reachability**: `untrusted` to LAN blocked.
- **Qubes 4.2 nftables sanity**: `table inet qubes` present. ([Qubes OS][7])

## Reading the results

- `results.csv` columns: `id,name,vm,result,detail` → easy to ingest in Grafana/Prometheus later.
- `PASS` = looks good; `FAIL` = likely misconfiguration; `NOTE` = advisory or skipped due to missing tool.

## Common fixes (if you see FAIL/NOTE)

- **DNS FAIL**: ensure your **sys-dns** (DNSCrypt) chain is used by all app VMs; block direct `udp/53` in firewall. ([Qubes OS][7])
- **IPv6 leak**: disable v6 where unsupported, or fully support it end-to-end (VPN/Firewall/Resolver). ([Whonix][8])
- **VPN route**: verify default route and nft killswitch (deny non-tun egress).
- **STUN/WebRTC**: harden browser (about\:config/uBlock settings) or run browser in a **disposable**. ([Whonix Forum][9])
- **LAN reachable from untrusted**: tighten `sys-firewall` rules (drop RFC1918).

## Add 10–20 extra “second-tier” leak tests (ideas you can enable)

These are popular with power users and align with Qubes/Whonix guidance. ([Whonix][8])

1. **DoT/DoH bypass attempt** from an app qube (curl to `https://cloudflare-dns.com/dns-query`) — make sure policy permits / you intend it.
2. **Plain HTTP leak**: detect accidental clear-text posts to port 80 (pcap count spike in `sys-vpn`/`sys-firewall`).
3. **SNI collection** rate: count TLS ClientHello with SNI from a specific app VM (requires pcap in logging qube).
4. **ICMP egress**: ping external host should **respect** your intended path (e.g., blocked when VPN down).
5. **IPv6 RA** detection\*\* in `sys-net`: detect rogue router advertisements (nft log or `rdisc6`).
6. **LLMNR** chatter\*\*: ensure `udp/5355` isn’t used by app VMs (Windows-interop leaks on mixed networks).
7. **UPnP/SSDP**: confirm no `udp/1900` traffic leaves `sys-firewall`.
8. **Captive portal bleed**: when VPN is up, ensure you can’t reach known captive probes (e.g., `connectivity-check.*`).
9. **NTP hard lock**: enforce only your chosen servers via nft; test with a fake pool hostname.
10. **Browser WebRTC ICE candidates**: run a headless WebRTC test page in a disposable and capture ICE candidate types (host/srflx/relay).
11. **DNS over TCP fallback**: attempt `dig +tcp @1.1.1.1` from app qube; should fail unless explicitly allowed.
12. **Split-tunnel sanity**: if you have direct + VPN chains, verify a labeled “non-sensitive” VM never egresses via VPN (and vice-versa).
13. **Tor isolation** (Whonix): ensure non-Tor apps cannot reach clearnet from the workstation.
14. **Reverse DNS leaks**: ensure `sys-dns` doesn’t emit PTR lookups for local RFC1918 ranges.
15. **SMTP block**: app VMs shouldn’t be able to connect to port 25/587 directly unless intended.
16. **Geo egress validation**: compare IP geolocation of VPN exit against expected ASN/region.
17. **Non-standard DNS ports**: block/observe 5353, 853, 5355 attempts from app VMs (except intended).
18. **DoH bootstrap leak**: block known DoH bootstrap IPs from app VMs if you want resolver centralization.
19. **Multicast/broadcast silence**: ensure no 224.0.0.0/4 or 255.255.255.255 frames leave `sys-firewall` from app VMs.
20. **Hidden v6 fallback** behind VPN: temporarily disable VPN and confirm **no v6 egress** appears.

> Many of these overlap with Whonix’s “Protocol Leak & Fingerprinting Protection” playbook; adapt what’s relevant. ([Whonix][8])

## Customization knobs

- **Which VMs** to test: edit names in the state.
- **Depth vs. noise**: turn passive pcap-based checks on/off (requires `tcpdump`/`capinfos` in the relevant service qube).
- **Output**: `results.csv` is designed so you can ingest it later (Grafana table/Prometheus textfile exporter).

## Safety notes

- Tests are read-only/observational where possible.
- Anything “active” (like `curl` probes) is time-bounded and should respect your routing; still, run when it won’t disrupt critical sessions.

---

## References (core)

- Qubes **firewall/nftables** docs (4.2). ([Qubes OS][7])
- Qrexec framework & **Admin API** (why we use policies, not cross-VM SSH). ([Qubes OS][10])
- Qubes 4.2 **policy format** in release notes. ([Qubes OS][11])
- **dom0** software caution (keep dom0 minimal). ([Qubes OS][2])
- Debian **debsums**; RPM verification (`rpm -Va`). ([Debian Manpages][3], [Red Hat Docs][4])
- Whonix **leak tests** & protocol leak protection. ([Whonix][12])

---
