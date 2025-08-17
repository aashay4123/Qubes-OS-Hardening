{% set dns_template = 'deb_harden_min' %}
{% set upstream = 'sys-firewall' %}

# Tag as the only authorized DNS resolver
sys-dns-tag-resolver:
  qvm.tag:
    - name: @tag:dns-resolver
    - vm: [ sys-dns ]

# Harden & enable encrypted DNS
sys-dns-configure:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: |
        set -e
        apt-get update
        apt-get -y install dnscrypt-proxy nftables ca-certificates || true
        update-ca-certificates || true

        # IPv6 OFF
        cat >/etc/sysctl.d/99-qubes-ipv6-off.conf <<'EOF'
        net.ipv6.conf.all.disable_ipv6=1
        net.ipv6.conf.default.disable_ipv6=1
        EOF
        sysctl --system || true

        # NetworkManager must not manage resolv.conf (harmless if NM absent)
        mkdir -p /etc/NetworkManager/conf.d
        cat >/etc/NetworkManager/conf.d/00-dns-none.conf <<'EOF'
        [main]
        dns=none
        EOF
        systemctl restart NetworkManager || true

        # Pin to local stub
        systemctl disable --now systemd-resolved || true
        rm -f /etc/resolv.conf
        echo "nameserver 127.0.0.1" > /etc/resolv.conf

        # dnscrypt: listen on 127.0.0.1:53 and use vetted resolvers
        sed -i 's/^# *listen_addresses *=.*/listen_addresses = ["127.0.0.1:53"]/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        sed -i 's/^# *server_names *=.*/server_names = ["quad9-dnscrypt","cloudflare","mullvad-adblock-doh"]/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        systemctl enable --now dnscrypt-proxy || true

        # Local DNS egress lock (only allow DNS to 127.0.0.1 from this VM)
        mkdir -p /etc/nftables.d
        cat >/etc/nftables.d/60-dnslock-local.nft <<'EOF'
        table inet sysdns_local {
          chain output {
            type filter hook output priority 0; policy accept;
            udp dport 53 ip daddr != 127.0.0.1 drop
            tcp dport 53 ip daddr != 127.0.0.1 drop
          }
        }
        EOF
        if ! grep -q 'include "/etc/nftables.d/\*\.nft"' /etc/nftables.conf 2>/dev/null; then
          echo 'include "/etc/nftables.d/*.nft"' > /etc/nftables.conf
        fi
        systemctl enable nftables
        systemctl restart nftables
