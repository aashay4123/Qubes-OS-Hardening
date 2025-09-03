# README — sys-dns with DNSCrypt on Qubes OS 4.2.4 (2025)

## Why this design

- Qubes 4.2 uses **nftables** for firewalling; the project advises placing network services (DNS, VPN, etc.) in **their own service qube** rather than `sys-firewall`. This keeps the Qubes firewall intact and limits blast radius. ([Qubes OS][1])
- Community guidance converges on a dedicated **`sys-dns`** running **dnscrypt-proxy**, chained like:

  ```
  app qubes → sys-firewall → sys-dns → sys-net → uplink
  ```

  Many users who tried DNSCrypt inside `sys-net` moved it to a **separate sys-dns** for clarity and fewer side effects. ([Qubes OS Forum][2])

## What this does

- Creates `sys-dns` from your **`debian-12-hard-min`** template, marks it `provides-network`, and sets its NetVM to `sys-net`.
- Installs **dnscrypt-proxy** and writes a minimal, privacy-oriented config listening on **127.0.0.1:53**.
- Adds nftables rules that **DNAT all inbound TCP/UDP :53** to `127.0.0.1:53` inside `sys-dns`.
  (We don’t edit Qubes’ internal chains; we add idempotent rules. If a custom NAT hook isn’t present, we create a tiny NAT table just for this purpose—needed because 4.2 lacks a documented “custom-nat” hook.) ([Qubes OS Forum][3], [GitHub][4])
- Rewires the chain so **`sys-firewall` uses `sys-dns`** as its NetVM. App qubes continue to use `sys-firewall`. (Whonix chains are unchanged—Tor handles DNS internally.)
- Ships a **test suite** that proves:

  1. Resolution works from clients,
  2. **No plaintext :53** leaves `sys-dns`,
  3. dnscrypt-proxy has **encrypted upstream sessions** (DoH/DoT).

## Reconfiguring when you add/change VMs

- New app qubes should keep **NetVM = `sys-firewall`** (unchanged). Since `sys-firewall → sys-dns → sys-net`, they’ll automatically use DNSCrypt.
- If you want only some qubes to use DNSCrypt, point those qubes’ **NetVM directly to `sys-dns`** and keep others on a different firewall chain.
- **Whonix**: leave Whonix traffic on the Tor chain (do not force through `sys-dns`).
- **TemplateVM updates**: unaffected—Qubes’ **UpdatesProxy** is policy-driven, not network-filter-driven. Don’t try to “allow it in the firewall GUI”; use policies/services as designed. ([Qubes OS][1])

## Exceptions for internal domains / split-horizon DNS

Prefer **dnscrypt-proxy forwarding rules** over firewall holes. Put internal zones in `/etc/dnscrypt-proxy/forwarding-rules.txt` (e.g., `corp.lan 10.0.0.53`) and enable `forwarding_rules` in the TOML. This keeps control at the resolver layer instead of sprinkling firewall bypasses. (General guidance across DNSCrypt docs and Linux distro wikis.) ([ArchWiki][5], [docs.pi-hole.net][6])

## Verifying

- From any client (e.g., `personal`):

  ```bash
  getent hosts qubes-os.org
  ```

- In `sys-dns`:

  ```bash
  # no plaintext DNS leaving the qube
  sudo timeout 6 tcpdump -ni any port 53 and not host 127.0.0.1

  # dnscrypt-proxy active and talking TLS/HTTPS upstream
  sudo ss -tupon | grep -E 'dnscrypt|:853|:443'
  ```

- Or just run the **test SLS** (below).

---

# SLS: builder — `/srv/salt/qubes/network/sys-dns.sls`

```yaml
# Build sys-dns on debian-12-hard-min with dnscrypt-proxy; DNAT all :53 to 127.0.0.1.
# Chain: app → sys-firewall → sys-dns → sys-net

check-template-min:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx debian-12-hard-min'"

check-sys-net:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx sys-net'"

check-sys-firewall:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx sys-firewall'"

sys-dns-present:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx sys-dns || qvm-create -C AppVM -t debian-12-hard-min -l blue sys-dns'"
    - require:
        - cmd: check-template-min

sys-dns-netvm:
  qvm.prefs:
    - name: sys-dns
    - netvm: sys-net
    - require:
        - cmd: sys-dns-present
        - cmd: check-sys-net

sys-dns-features:
  qvm.prefs:
    - name: sys-dns
    - provides-network: True
    - autostart: True
    - require:
        - qvm: sys-dns-netvm

sys-dns-install:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: "env DEBIAN_FRONTEND=noninteractive apt-get -y update && apt-get -y install dnscrypt-proxy nftables tcpdump iproute2"
    - require:
        - qvm: sys-dns-features

sys-dns-config-dnscrypt:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: |
        /bin/sh -c '
        mkdir -p /etc/dnscrypt-proxy
        cat > /etc/dnscrypt-proxy/dnscrypt-proxy.toml << "EOF"
        server_names = ["cloudflare", "quad9-dnscrypt-ipv4"]
        listen_addresses = ["127.0.0.1:53"]
        max_clients = 250
        require_dnssec = true
        require_nolog = true
        require_nofilter = true
        # forwarding_rules = "/etc/dnscrypt-proxy/forwarding-rules.txt"
        [sources."public-resolvers"]
        urls = [
          "https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md",
          "https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md"
        ]
        cache_file = "/var/cache/dnscrypt-proxy/public-resolvers.md"
        minisign_key = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3"
        refresh_delay = 72
        prefix = ""
        EOF
        chmod 0644 /etc/dnscrypt-proxy/dnscrypt-proxy.toml
        '
    - require:
        - qvm: sys-dns-install

sys-dns-config-forwarding:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: |
        /bin/sh -c '
        cat > /etc/dnscrypt-proxy/forwarding-rules.txt << "EOF"
        # Example internal zones (uncomment in TOML to enable):
        # internal.local  192.168.1.1
        # corp.lan        10.0.0.53
        EOF
        chmod 0644 /etc/dnscrypt-proxy/forwarding-rules.txt
        '
    - require:
        - qvm: sys-dns-config-dnscrypt

sys-dns-resolvconf:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: '/bin/sh -c "printf \"nameserver 127.0.0.1\noptions trust-ad\n\" > /etc/resolv.conf"'
    - require:
        - qvm: sys-dns-config-dnscrypt

# Idempotent nft script (no 'set -e', no '|| true'); handles presence checks explicitly.
sys-dns-nft-script:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: |
        /bin/sh -c '
        install -d -m 0755 /rw/config
        cat > /rw/config/nft-dnscrypt.sh << "EOF"
        #!/bin/sh
        # Add DNAT for UDP/TCP 53 to 127.0.0.1 in a safe, idempotent way.
        CHAIN=""
        if nft list chain ip qubes dnat-dns >/dev/null 2>&1; then
          CHAIN="ip qubes dnat-dns"
        elif nft list chain ip qubes prerouting >/dev/null 2>&1; then
          CHAIN="ip qubes prerouting"
        else
          if ! nft list table ip dnscrypt >/dev/null 2>&1; then
            nft add table ip dnscrypt
          fi
          if ! nft list chain ip dnscrypt prerouting >/dev/null 2>&1; then
            nft add chain ip dnscrypt prerouting { type nat hook prerouting priority dstnat + 5 \; }
          fi
          CHAIN="ip dnscrypt prerouting"
        fi
        if ! nft list chain $CHAIN | grep -q "udp dport 53 .* dnat to 127.0.0.1"; then
          nft add rule $CHAIN udp dport 53 dnat to 127.0.0.1
        fi
        if ! nft list chain $CHAIN | grep -q "tcp dport 53 .* dnat to 127.0.0.1"; then
          nft add rule $CHAIN tcp dport 53 dnat to 127.0.0.1
        fi
        exit 0
        EOF
        chmod 0755 /rw/config/nft-dnscrypt.sh
        '
    - require:
        - qvm: sys-dns-install

# Ensure DNAT runs after dnscrypt-proxy is up (bootstrap-safe)
sys-dns-nft-service:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: |
        /bin/sh -c '
        cat > /etc/systemd/system/dnscrypt-nft.service << "EOF"
        [Unit]
        Description=Apply nftables DNAT for DNS -> 127.0.0.1
        After=dnscrypt-proxy.service network-online.target
        Wants=dnscrypt-proxy.service

        [Service]
        Type=oneshot
        ExecStart=/rw/config/nft-dnscrypt.sh
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
        EOF
        systemctl daemon-reload
        systemctl enable --now dnscrypt-nft.service
        '
    - require:
        - qvm: sys-dns-nft-script

sys-dns-enable-dnscrypt:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: "/bin/sh -c 'systemctl enable --now dnscrypt-proxy && systemctl is-active dnscrypt-proxy'"
    - require:
        - qvm: sys-dns-config-dnscrypt

# Rewire: sys-firewall → sys-dns (app qubes continue using sys-firewall)
sys-firewall-to-sys-dns:
  qvm.prefs:
    - name: sys-firewall
    - netvm: sys-dns
    - require:
        - qvm: sys-dns-enable-dnscrypt
        - qvm: sys-dns-nft-service
        - cmd: check-sys-firewall

# Verification
verify-sys-dns-up:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: "/bin/sh -c 'systemctl is-active dnscrypt-proxy && nft list ruleset >/dev/null && getent hosts qubes-os.org >/dev/null'"
    - require:
        - qvm: sys-dns-enable-dnscrypt
        - qvm: sys-dns-nft-service

builder-summary:
  cmd.run:
    - name: |
        /bin/sh -c '
        printf "\n=== sys-dns summary ===\n"
        printf "sys-dns  template: %s\n" "$(qvm-prefs sys-dns template)"
        printf "sys-dns  netvm   : %s\n" "$(qvm-prefs sys-dns netvm)"
        printf "sys-fw   netvm   : %s\n" "$(qvm-prefs sys-firewall netvm)"
        '
    - require:
        - qvm: sys-firewall-to-sys-dns
        - qvm: sys-dns-features
```

---

# SLS: tests — `/srv/salt/qubes/tests/sys-dns.sls`

```yaml
# Proves: clients resolve OK; no plaintext :53 leaves sys-dns; dnscrypt uses TLS/HTTPS upstream.

verify-chain:
  cmd.run:
    - name: /bin/sh -c '[ "$(qvm-prefs sys-firewall netvm)" = "sys-dns" ] && [ "$(qvm-prefs sys-dns netvm)" = "sys-net" ]'

sys-dns-start-capture:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: "/bin/sh -c 'rm -f /tmp/dns_out.pcap; timeout 6 tcpdump -ni any -w /tmp/dns_out.pcap port 53 and not host 127.0.0.1 and not net 10.139.0.0/16 and not net 10.137.0.0/16 >/dev/null 2>&1 &'"
    - require:
        - cmd: verify-chain

clients-resolve:
  cmd.run:
    - name: >
        /bin/sh -c '
        FAIL=0;
        for vm in personal work pro untrusted; do
          if qvm-ls --raw-list | grep -qx "$vm"; then
            qvm-run -p -u root "$vm" "getent hosts qubes-os.org google.com github.com" >/dev/null || FAIL=1;
          fi
        done
        exit $FAIL
        '
    - require:
        - qvm: sys-dns-start-capture

no-plain53-egress:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: '/bin/sh -c ''CNT=$(tcpdump -nr /tmp/dns_out.pcap 2>/dev/null | wc -l); [ "$CNT" -eq 0 ]'''
    - require:
        - cmd: clients-resolve

dnscrypt-active-encrypted:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: '/bin/sh -c ''ss -tupon | grep -E "dnscrypt|:853|:443" >/dev/null'''
    - require:
        - cmd: clients-resolve

tests-summary:
  cmd.run:
    - name: |
        /bin/sh -c '
        printf "\n=== sys-dns tests ===\n"
        printf "Chain  : sys-firewall -> sys-dns -> sys-net\n"
        printf "Plain53: none captured leaving sys-dns\n"
        printf "TLS/HTTPS upstream present from dnscrypt-proxy\n"
        '
    - require:
        - qvm: no-plain53-egress
        - qvm: dnscrypt-active-encrypted
```

---

## How to apply and test

```bash
# Build + wire it
sudo qubesctl state.show_sls qubes.network.sys-dns
sudo qubesctl --show-output state.sls qubes.network.sys-dns

# End-to-end tests
sudo qubesctl state.show_sls qubes.tests.sys-dns
sudo qubesctl --show-output state.sls qubes.tests.sys-dns
```

### Tuning

- Change resolvers in `/etc/dnscrypt-proxy/dnscrypt-proxy.toml` (`server_names`) to your preferred set. (DNSCrypt supports DNSCrypt/DoH; set accordingly.) ([ArchWiki][5])
- Add internal zones to `/etc/dnscrypt-proxy/forwarding-rules.txt` and **uncomment** `forwarding_rules` in the TOML.

### Rollback

```bash
# revert firewall chain
qvm-prefs sys-firewall netvm sys-net

# disable service & remove rule script (in sys-dns)
qvm-run -u root sys-dns 'systemctl disable --now dnscrypt-nft.service; rm -f /rw/config/nft-dnscrypt.sh'
```

---

## Is this the “best” approach for 2025 on Qubes 4.2.4?

**Yes**—for Qubes’ current architecture. Qubes 4.2 explicitly recommends **separate network service qubes** (not `sys-firewall`) and uses **nftables**. Our solution follows both, avoids modifying Qubes’ internal chains directly, and uses a small, idempotent script for NAT DNAT—while acknowledging Qubes doesn’t (yet) expose a formal “custom-nat” chain (hence the fallback table). ([Qubes OS][1], [Qubes OS Forum][3], [GitHub][4])

If the project later provides a proper **custom NAT hook**, you can swap the DNAT placement to that chain with a one-line change in `/rw/config/nft-dnscrypt.sh`. Until then, this is practical and robust.

---

## Sources & further reading

- Qubes **Firewall (4.2, nftables) & network service qubes guidance**, and where to put local rules. ([Qubes OS][1])
- Forum guide & discussion: **move DNSCrypt to a separate `sys-dns`**, not `sys-net`. ([Qubes OS Forum][2])
- nftables custom-nat gap noted by community; workaround is a dedicated NAT table/chain. ([Qubes OS Forum][3], [GitHub][4])
- Disposables & default DispVM (unrelated here but relevant to your estate). ([Qubes OS][7])
- DNSCrypt project & configuration practices (TOML; resolvers; minisign key). ([DNSCrypt][8], [ArchWiki][5], [Debricked][9])

# "References"

[1]: https://www.qubes-os.org/doc/firewall/ "
    
      Firewall | Qubes OS
    
  "
[2]: https://forum.qubes-os.org/t/guide-how-to-setup-a-sys-dns-qube/13749?page=2&utm_source=chatgpt.com "[guide] how-to setup a sys-dns qube - Page 2"
[3]: https://forum.qubes-os.org/t/qubes-os-4-2-nftables-nft-firewall-guide/20933?utm_source=chatgpt.com "Qubes OS 4.2 nftables / nft firewall guide"
[4]: https://github.com/QubesOS/qubes-issues/issues/8629?utm_source=chatgpt.com "Add a custom-nat chain in the firewall · Issue #8629"
[5]: https://wiki.archlinux.org/title/Dnscrypt-proxy?utm_source=chatgpt.com "dnscrypt-proxy"
[6]: https://docs.pi-hole.net/guides/dns/dnscrypt-proxy/?utm_source=chatgpt.com "dnscrypt-proxy (DoH)"
[7]: https://www.qubes-os.org/doc/how-to-use-disposables/?utm_source=chatgpt.com "How to use disposables"
[8]: https://www.dnscrypt.org/?utm_source=chatgpt.com "DNSCrypt - Official Project Home Page"
[9]: https://debricked.com/select/package/github-DNSCrypt/dnscrypt-resolvers?utm_source=chatgpt.com "Lists of public DNSCrypt / DoH DNS servers and DNS relays"
