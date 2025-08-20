{% set dns_template = 'deb_harden_min' %}
{% set upstream = 'sys-firewall' %}

# Tag sys-dns as the only authorized DNS resolver (policy use later if needed)
sys-dns-tag-resolver:
  qvm.tag:
    - name: @tag:dns-resolver
    - vm: [ sys-dns ]

# Harden & enable encrypted DNS in sys-dns
sys-dns-configure:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: |
        set -e
        apt-get update
        apt-get -y install dnscrypt-proxy nftables ca-certificates curl dumb-init || true
        update-ca-certificates || true

        # IPv6 OFF (to avoid dual-stack leaks; enable + mirror rules if you need IPv6)
        cat >/etc/sysctl.d/99-qubes-ipv6-off.conf <<'EOF'
        net.ipv6.conf.all.disable_ipv6=1
        net.ipv6.conf.default.disable_ipv6=1
        EOF
        sysctl --system || true

        # Ensure local stub use
        systemctl disable --now systemd-resolved || true
        mkdir -p /etc/NetworkManager/conf.d
        cat >/etc/NetworkManager/conf.d/00-dns-none.conf <<'EOF'
        [main]
        dns=none
        EOF
        systemctl restart NetworkManager || true
        rm -f /etc/resolv.conf
        echo "nameserver 127.0.0.1" > /etc/resolv.conf

        # Configure dnscrypt-proxy: loopback listener, DNSSEC, cache, no fallback
        sed -i 's/^# *listen_addresses *=.*/listen_addresses = ["127.0.0.1:53"]/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        sed -i 's/^# *server_names *=.*/server_names = ["quad9-dnscrypt","cloudflare","mullvad-adblock-doh"]/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        sed -i 's/^# *require_dnssec *=.*/require_dnssec = true/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        sed -i 's/^# *fallback_resolvers *=.*/fallback_resolvers = []/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        sed -i 's/^# *cache *=.*/cache = true/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        sed -i 's/^# *cache_min_ttl *=.*/cache_min_ttl = 600/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        sed -i 's/^# *cache_max_ttl *=.*/cache_max_ttl = 86400/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true

        # nftables: baseline + includes
        install -m 0644 /dev/null /etc/nftables.conf
        if ! grep -q 'include "/etc/nftables.d/*.nft"' /etc/nftables.conf 2>/dev/null; then
          printf 'include "/etc/nftables.d/*.nft"\n' > /etc/nftables.conf
        fi

        # TODO: requires dns_policy.nft
        # cp /srv/salt/vpn/policies/dns_policy.nft /etc/nftables.conf
        # systemctl enable --now nftables
        mkdir -p /etc/nftables.d

        # Allow only local DNS from this VM (no direct egress :53)
        cat >/etc/nftables.d/60-dnslock-local.nft <<'EOF'
        table inet sysdns_local {
          chain output {
            type filter hook output priority 0; policy accept;
            udp dport 53 ip daddr != 127.0.0.1 drop
            tcp dport 53 ip daddr != 127.0.0.1 drop
          }
          chain input {
            type filter hook input priority 0; policy drop;
            iif lo accept
            ct state established,related accept
            ip protocol icmp accept
            tcp dport 53 iif lo accept
            udp dport 53 iif lo accept
          }
          chain forward { type filter hook forward priority 0; policy drop; }
        }
        EOF
        systemctl enable nftables
        systemctl restart nftables

        systemctl enable --now dnscrypt-proxy || true
