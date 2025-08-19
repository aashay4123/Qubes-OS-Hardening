# 2) Qubes Topology (Clean, Fail-Closed)

[ sys-net ] → [ sys-firewall ] → [ sys-dns ] → [ sys-vpn-* (optional) ] → [ sys-tor-gw ] → [ Windows Tor DVMs ]
↘ (non-Tor personas) → [ work/dev/personal via sys-firewall or sys-vpn-* ]

- **sys-net**: talks to hardware NIC. OUI helper applied; Bluetooth/mDNS off.
- **sys-firewall**: egress guardian; **TTL=128** + **QUIC drop**; nft counters; Suricata (optional).
- **sys-dns**: dnscrypt-proxy + DNSSEC; deny all other DNS egress.
- **sys-vpn-ru/sys-vpn-nl**: (Fedora 42 VPN template) DNS locked to local stub; optional, for non-Tor personas.
- **sys-tor-gw**: Debian minimal, Tor transparent proxy; **fail-closed nftables** (no leaks if Tor dies).
- **Windows-11 Tor DVMs**: Disposable VMs; Tor Browser only; no persistence.
- **Vaults**: `vault-secrets` (Split-GPG/SSH); `vault-dn-secrets` (Whonix/Tor keys if used); backup offline.
- **DispVMs**: default for opening untrusted links/files.

**Policies**

- Clipboard/Filecopy denied across trust boundaries by default; timed bypass available.
- `@tag:persona-*` blocks cross-persona flows.
- Device attach allow-list (keyboard/mouse only; USB NICs to sys-net; unknown USB → Disposable).

**Salt alignment**

- `normaliza.sls`: TTL/QUIC, journald volatile, tmpfs logs, hostname random, OUI helper.
- Spoofing profiles: Windows-like personas (UA, locale, resolution) — but **Tor Browser stays default** inside Windows unless you know what you’re doing.
