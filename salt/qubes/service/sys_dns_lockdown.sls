# /srv/salt/qubes/services/sys_dns_lockdown.sls
# Harden sys-dns: dnscrypt-proxy, strict egress allowlist for DNS upstreams.

# -------------------------
#  Tunables (edit these)
#  ------------------------- #}
{% set DNSCRYPT_SERVER_NAMES = ['quad9-dnscrypt','cloudflare'] %}
# ^ Use names that exist in your dnscrypt public-resolvers list. Avoid DoH unless you also allowlist its IPs:443.

{% set ALLOWLIST_V4 = [
  # --- EXAMPLES (replace to fit your setup) ---
  # '9.9.9.9:853', '149.112.112.112:853',   # Quad9 DoT
  # '1.1.1.1:853','1.0.0.1:853',            # Cloudflare DoT
  # '9.9.9.9:53','149.112.112.112:53'       # If using DNSCrypt on :53 to fixed IPs (rare; confirm!)
] %}

{% set ALLOWLIST_V6 = [
  # '2620:fe::9:853', '2620:fe::fe:853',    # (example) Quad9 v6 DoT (confirm!)
  # '2606:4700:4700::1111:853', '2606:4700:4700::1001:853'  # Cloudflare v6 DoT (confirm!)
] %}

{% set RESTRICT_DOH = False %}       # True => Only allow TCP/443 to listed DoH IPs; add them below.
{% set DOH_ALLOWLIST_V4 = [
  # '194.242.2.2:443',  # (example) If you use a DoH resolver with a stable IP
] %}
{% set DOH_ALLOWLIST_V6 = [
  # '2a07:e340::2:443',
] %}

{% set DISABLE_IPV6 = True %}        # Keep False only if you actually configure v6 + allowlists.

# -------------------------
#  Install & harden dnscrypt-proxy
#  ------------------------- #}
sys-dns-packages:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: |
        set -e
        apt-get update
        apt-get -y install dnscrypt-proxy nftables ca-certificates curl jq || true
        update-ca-certificates || true

        # Disable IPv6 (optional)
        {% if DISABLE_IPV6 %}
        cat >/etc/sysctl.d/99-qubes-ipv6-off.conf <<'EOF'
        net.ipv6.conf.all.disable_ipv6=1
        net.ipv6.conf.default.disable_ipv6=1
        EOF
        sysctl --system || true
        {% endif %}

        # Keep NetworkManager from touching DNS
        mkdir -p /etc/NetworkManager/conf.d
        cat >/etc/NetworkManager/conf.d/00-dns-none.conf <<'EOF'
        [main]
        dns=none
        EOF
        systemctl restart NetworkManager || true

        # Local stub only
        systemctl disable --now systemd-resolved || true
        rm -f /etc/resolv.conf
        echo "nameserver 127.0.0.1" > /etc/resolv.conf

        # dnscrypt-proxy: listen locally; require DNSSEC; cache; NO FALLBACK
        sed -i 's/^# *listen_addresses *=.*/listen_addresses = ["127.0.0.1:53"]/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        sed -i 's/^# *require_dnssec *=.*/require_dnssec = true/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        sed -i 's/^# *cache *=.*/cache = true/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        sed -i 's/^# *cache_min_ttl *=.*/cache_min_ttl = 600/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        sed -i 's/^# *cache_max_ttl *=.*/cache_max_ttl = 86400/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        # Clear fallback resolvers
        if grep -q '^fallback_resolvers' /etc/dnscrypt-proxy/dnscrypt-proxy.toml; then
          sed -i 's/^fallback_resolvers.*/fallback_resolvers = []/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml
        else
          echo 'fallback_resolvers = []' >> /etc/dnscrypt-proxy/dnscrypt-proxy.toml
        fi

        # Set server_names from Salt
        sed -i '/^server_names/d' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        printf 'server_names = [%s]\n' "$(printf '"%s",' {% for n in DNSCRYPT_SERVER_NAMES %}{{ n }}{% if not loop.last %} {% endif %}{% endfor %} | sed 's/,$//')" >> /etc/dnscrypt-proxy/dnscrypt-proxy.toml

        # Systemd hardening (tighten sandbox; service user already set by package)
        install -d -m 0755 /etc/systemd/system/dnscrypt-proxy.service.d
        cat >/etc/systemd/system/dnscrypt-proxy.service.d/override.conf <<'EOF'
        [Service]
        NoNewPrivileges=yes
        PrivateTmp=yes
        ProtectSystem=strict
        ProtectHome=yes
        ProtectKernelTunables=yes
        ProtectKernelModules=yes
        ProtectControlGroups=yes
        RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
        RestrictNamespaces=yes
        RestrictRealtime=yes
        LockPersonality=yes
        MemoryDenyWriteExecute=yes
        SystemCallArchitectures=native
        EOF

        systemctl daemon-reload
        systemctl enable --now dnscrypt-proxy || true

# -------------------------
#  nftables egress lock for sys-dns
#  ------------------------- #}
sys-dns-nftables:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: |
        set -e
        mkdir -p /etc/nftables.d

        # Build allowlist sets from Salt variables
        cat >/etc/nftables.d/60-sysdns-egress.nft <<'EOF'
        define dns_upstreams_v4 = { {% for e in ALLOWLIST_V4 %} {{ e.split(':')[0] }} {% if not loop.last %}, {% endif %}{% endfor %} }
        define dns_upstream_ports = { {% set ports = ALLOWLIST_V4 | map('split',':') | map(attribute=1) | list %}
                                      {% set uniq = ports | unique | list %}
                                      {% for p in uniq %} {{ p|int }} {% if not loop.last %}, {% endif %}{% endfor %} }

        {% if not DISABLE_IPV6 %}
        define dns_upstreams_v6 = { {% for e in ALLOWLIST_V6 %} {{ e.split(':')[0] }} {% if not loop.last %}, {% endif %}{% endfor %} }
        define dns_upstream_ports_v6 = { {% set ports6 = ALLOWLIST_V6 | map('split',':') | map(attribute=1) | list %}
                                         {% set uniq6 = ports6 | unique | list %}
                                         {% for p in uniq6 %} {{ p|int }} {% if not loop.last %}, {% endif %}{% endfor %} }
        {% endif %}

        {% if RESTRICT_DOH %}
        define doh_upstreams_v4 = { {% for e in DOH_ALLOWLIST_V4 %} {{ e.split(':')[0] }} {% if not loop.last %}, {% endif %}{% endfor %} }
        {% if not DISABLE_IPV6 %}
        define doh_upstreams_v6 = { {% for e in DOH_ALLOWLIST_V6 %} {{ e.split(':')[0] }} {% if not loop.last %}, {% endif %}{% endfor %} }
        {% endif %}
        {% endif %}

        table inet sysdns_egress {
          chain output {
            type filter hook output priority 0; policy accept;

            # Local stub only for :53
            udp dport 53 ip daddr != 127.0.0.1 drop
            tcp dport 53 ip daddr != 127.0.0.1 drop

            # Block any external :53/:853 unless in allowlist (v4)
            {% if ALLOWLIST_V4|length > 0 %}
            ip daddr != $dns_upstreams_v4 udp dport $dns_upstream_ports drop
            ip daddr != $dns_upstreams_v4 tcp dport $dns_upstream_ports drop
            {% else %}
            # No upstream v4 allowlist provided -> drop all external :53/:853
            udp dport {53,853} ip daddr != 127.0.0.1 drop
            tcp dport {53,853} ip daddr != 127.0.0.1 drop
            {% endif %}

            {% if not DISABLE_IPV6 %}
            # v6: block :53/:853 unless in allowlist
            {% if ALLOWLIST_V6|length > 0 %}
            ip6 daddr != $dns_upstreams_v6 udp dport $dns_upstream_ports_v6 drop
            ip6 daddr != $dns_upstreams_v6 tcp dport $dns_upstream_ports_v6 drop
            {% else %}
            udp dport {53,853} drop
            tcp dport {53,853} drop
            {% endif %}
            {% endif %}

            {% if RESTRICT_DOH %}
            # Optional: restrict 443 egress to DoH IPs only (may affect updates)
            {% if DOH_ALLOWLIST_V4|length > 0 %}
            ip daddr != $doh_upstreams_v4 tcp dport 443 drop
            {% else %}
            tcp dport 443 drop
            {% endif %}
            {% if not DISABLE_IPV6 %}
            {% if DOH_ALLOWLIST_V6|length > 0 %}
            ip6 daddr != $doh_upstreams_v6 tcp dport 443 drop
            {% else %}
            tcp dport 443 drop
            {% endif %}
            {% endif %}
            {% endif %}
          }

          # Tight input (loopback + established)
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

        # Ensure main includes
        if ! grep -q 'include "/etc/nftables.d/*.nft"' /etc/nftables.conf 2>/dev/null; then
          echo 'include "/etc/nftables.d/*.nft"' > /etc/nftables.conf
        fi

        systemctl enable nftables
        systemctl restart nftables
    - require:
      - qvm.run: sys-dns-packages
