# Build a dedicated sys-dns using your debian-12-hard-min template.
# It runs dnscrypt-proxy, DNATs all :53 to 127.0.0.1, and rewires:
#   AppVMs -> sys-firewall -> sys-dns -> sys-net

# ---------- Preconditions ----------
check-template-min:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx debian-12-hard-min'"

check-sys-net:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx sys-net'"

check-sys-firewall:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx sys-firewall'"

# ---------- Create sys-dns (service qube) ----------
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

# ---------- Install dnscrypt-proxy & tools inside sys-dns ----------
sys-dns-install:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: "env DEBIAN_FRONTEND=noninteractive apt-get -y update && apt-get -y install dnscrypt-proxy nftables tcpdump iproute2"
    - require:
      - qvm: sys-dns-features

# ---------- Minimal dnscrypt-proxy config ----------
# Listen on loopback, pick a couple of safe public resolvers (edit to taste).
sys-dns-config-dnscrypt:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: |
        /bin/sh -e -c '
        mkdir -p /etc/dnscrypt-proxy
        cat > /etc/dnscrypt-proxy/dnscrypt-proxy.toml << "EOF"
        server_names = ["cloudflare", "quad9-dnscrypt-ipv4"]
        listen_addresses = ["127.0.0.1:53"]
        max_clients = 250
        # Require encrypted resolvers; do NOT fall back to plain DNS
        require_dnssec = true
        require_nolog = true
        require_nofilter = true
        # Uncomment to forward specific internal zones without DNSCrypt:
        # forwarding_rules = "/etc/dnscrypt-proxy/forwarding-rules.txt"
        [sources."public-resolvers"]
        urls = ["https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md", "https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md"]
        cache_file = "/var/cache/dnscrypt-proxy/public-resolvers.md"
        minisign_key = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3"
        refresh_delay = 72
        prefix = ""
        EOF
        chmod 0644 /etc/dnscrypt-proxy/dnscrypt-proxy.toml
        '
    - require:
      - qvm: sys-dns-install

# Optionally define local/internal forwarding exceptions (edit as needed)
sys-dns-config-forwarding:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: |
        /bin/sh -e -c '
        cat > /etc/dnscrypt-proxy/forwarding-rules.txt << "EOF"
        # Example internal domains bypass (uncomment dnscrypt.toml forwarding_rules to use)
        # internal.local  192.168.1.1
        # corp.lan        10.0.0.53
        EOF
        chmod 0644 /etc/dnscrypt-proxy/forwarding-rules.txt
        '
    - require:
      - qvm: sys-dns-config-dnscrypt

# Ensure local resolver for the VM itself
sys-dns-resolvconf:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: '/bin/sh -c "printf \"nameserver 127.0.0.1\noptions trust-ad\n\" > /etc/resolv.conf"'
    - require:
      - qvm: sys-dns-config-dnscrypt

# ---------- nft rules: DNAT all inbound :53 to 127.0.0.1 ----------
# We try to append to an existing Qubes nat hook chain if present; else create a tiny dedicated table.
sys-dns-nft-script:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: |
        /bin/sh -e -c '
        install -d -m 0755 /rw/config
        cat > /rw/config/nft-dnscrypt.sh << "EOF"
        #!/bin/sh
        set -eu
        # Prefer Qubes nat chain if available
        CHAIN=""
        if nft list chain ip qubes dnat-dns >/dev/null 2>&1; then
          CHAIN="ip qubes dnat-dns"
        elif nft list chain ip qubes prerouting >/dev/null 2>&1; then
          CHAIN="ip qubes prerouting"
        else
          # Fallback: create our own lightweight nat table
          nft list table ip dnscrypt >/dev/null 2>&1 || nft add table ip dnscrypt
          nft list chain ip dnscrypt prerouting >/dev/null 2>&1 || nft add chain ip dnscrypt prerouting { type nat hook prerouting priority dstnat + 5 \; }
          CHAIN="ip dnscrypt prerouting"
        fi
        RS="$(nft -a list chain $CHAIN || true)"
        echo "$RS" | grep -q "udp dport 53.*dnat to 127.0.0.1" || nft add rule $CHAIN udp dport 53 dnat to 127.0.0.1
        RS="$(nft -a list chain $CHAIN || true)"
        echo "$RS" | grep -q "tcp dport 53.*dnat to 127.0.0.1" || nft add rule $CHAIN tcp dport 53 dnat to 127.0.0.1
        exit 0
        EOF
        chmod 0755 /rw/config/nft-dnscrypt.sh
        '
    - require:
      - qvm: sys-dns-install

sys-dns-nft-service:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: |
        /bin/sh -e -c '
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
      - qvm: sys-dns-config-dnscrypt

# Start/enable dnscrypt-proxy last (ensures resolver list fetch before DNAT kicks in)
sys-dns-enable-dnscrypt:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: "/bin/sh -c 'systemctl enable --now dnscrypt-proxy && systemctl is-active dnscrypt-proxy'"
    - require:
      - qvm: sys-dns-config-dnscrypt

# ---------- Rewire chain: sys-firewall -> sys-dns ----------
sys-firewall-to-sys-dns:
  qvm.prefs:
    - name: sys-firewall
    - netvm: sys-dns
    - require:
      - qvm: sys-dns-enable-dnscrypt
      - cmd: check-sys-firewall

# ---------- Verification ----------
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
