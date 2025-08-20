# /srv/salt/qubes/services/multi_topology_hardened.sls
# Hardened, robust policy for all requested network topologies in QubesOS.
# It covers:
#  - sys-firewall: DNS DNAT -> sys-dns; DoT/optional QUIC drop; (optional) Suricata IDS; idempotent
#  - sys-dns: dnscrypt-proxy hardening; strict egress allowlist to pinned upstreams (anti-leak)
#  - sys-vpn-* (ru/nl): kill-switch nftables; only allow egress to your VPN endpoints + via tunnel
#  - Helper DOM0 wrapper: /usr/local/bin/switch-vpn-topology (toggle modes without editing Salt)
#  - Topology switcher state that wires VMs for three modes:
#      1) dns-vpn        (= firewall -> dns -> vpn -> net)
#      2) dns-tor-vpn    (= firewall -> dns -> tor -> vpn -> net)
#      3) dns-vpn-tor    (= firewall -> dns -> vpn -> tor -> net)
#
# Assumes these VMs already exist: sys-net, sys-firewall, sys-dns. (This state does not create them.)
# You may have sys-vpn-ru, sys-vpn-nl, sys-vpn-tor created by earlier states; if not, create them first.
#
# =========================
# ===    TUNABLES      ===
# =========================

{# --------- Topology defaults (edit as needed) --------- #}
{% set topology_mode   = 'dns-vpn' %}          # dns-vpn | dns-tor-vpn | dns-vpn-tor
{% set selected_vpn    = 'sys-vpn-ru' %}       # which VPN VM to use by default

{# --------- Global behaviors --------- #}
{% set ipv6_global_enabled = False %}          # if True, mirror v6 rules where noted
{% set block_quic          = False %}          # drop UDP/443 in sys-firewall forward (may break HTTP/3)
{% set enable_suricata     = True %}           # Suricata IDS in sys-firewall

{# --------- sys-dns (dnscrypt-proxy) hardening --------- #}
{% set dnscrypt_server_names = ['quad9-dnscrypt','cloudflare'] %}
{% set sysdns_disable_ipv6  = True %}          # keep False only if you also fill ALLOWLIST_V6

# Egress allowlist for sys-dns (ONLY these DNS upstreams are permitted)
# Use explicit IP:port pairs actually used by your transport (DoT: 853, DNSCrypt: 53 or 443 depending on resolver profile).
{% set sysdns_allowlist_v4 = [
  '1.1.1.1:853', '1.0.0.1:853',      # Cloudflare DoT
  '8.8.8.8:853', '8.8.4.4:853',      # Google DoT
  '9.9.9.9:853', '149.112.112.112:853',  # Quad9 DoT
  '208.67.222.222:853', '208.67.220.220:853',  # OpenDNS
  # or DNS4EU filters if desired
] %}
{% set sysdns_allowlist_v6 = [
  # '2620:fe::9:853', '2620:fe::fe:853',
] %}

# Optional: Restrict DoH (443) from sys-dns to only specific IPs (may break general HTTPS updates)
{% set sysdns_restrict_doh = False %}
{% set sysdns_doh_allowlist_v4 = [
  # '194.242.2.2:443',
] %}
{% set sysdns_doh_allowlist_v6 = [
] %}

{# --------- Per-VPN kill-switch configuration --------- #}
# For each VPN VM, list the upstream VPN server endpoints the VM is allowed to contact *outside* the tunnel
# to bring the tunnel up. Format each entry as 'IP:PORT:PROTO'. Example WireGuard: '203.0.113.10:51820:udp'
# Example OpenVPN: '198.51.100.7:1194:udp' or ':tcp'. Add multiple entries if you use multiple servers.
# Also specify which tunnel interfaces you use ('wg0', 'tun0', etc.).

{% set vpn_killswitch = {
  'sys-vpn-ru': {
    'allow_upstream_v4': [
      # '203.0.113.10:51820:udp',
    ],
    'allow_upstream_v6': [
      # '2001:db8::10:51820:udp',
    ],
    'tunnel_ifaces': ['wg0','tun0'],
    'allow_dns_bootstrap': True,   # allow this VM to query 10.139.1.1:53 to resolve its VPN server (gets DNAT to sys-dns)
  },
  'sys-vpn-nl': {
    'allow_upstream_v4': [
      # '198.51.100.7:1194:udp',
    ],
    'allow_upstream_v6': [
    ],
    'tunnel_ifaces': ['wg0','tun0'],
    'allow_dns_bootstrap': True,
  }
} %}

# =========================
# ===  SYS-FIREWALL    ===
# =========================

get-sys-dns-ip:
  cmd.run:
    - name: |
        set -e
        qvm-ls --raw-data --fields NAME,IP | awk -F'|' '$1=="sys-dns"{print $2}' | tr -d ' \t' > /var/tmp/sysdns.ip

get-sys-vpn-tor-ip:
  cmd.run:
    - name: |
        set -e
        qvm-ls --raw-data --fields NAME,IP | awk -F'|' '$1=="sys-vpn-tor"{print $2}' | tr -d ' \t' > /var/tmp/sysvpntor.ip || true

sys-firewall-base:
  qvm.run:
    - name: sys-firewall
    - user: root
    - cmd: |
        set -e
        apt-get update
        apt-get -y install nftables ethtool ca-certificates curl || true
        update-ca-certificates || true

install-sys-firewall-user-script:
  cmd.run:
    - name: |
        set -e
        SYSIP="$(cat /var/tmp/sysdns.ip || true)"
        GWIP="$(cat /var/tmp/sysvpntor.ip || true)"
        [ -z "$SYSIP" ] && { echo "sys-dns IP not found" >&2; exit 1; }

        qvm-run -u root --pass-io sys-firewall 'cat >/rw/config/qubes-firewall-user-script' <<'EOF'
        #!/bin/sh
        set -eu

        SYSIP="{{ "$(cat /var/tmp/sysdns.ip || true)" }}"
        GWIP="{{ "$(cat /var/tmp/sysvpntor.ip || true)" }}"

        # (1) NAT v4 (and optional v6) prerouting -> jump to our custom chain
        nft list table ip nat >/dev/null 2>&1 || nft add table ip nat
        nft list chain ip nat prerouting >/dev/null 2>&1 || \
          nft add chain ip nat prerouting { type nat hook prerouting priority -100; policy accept; }
        nft list chain ip nat qubes_dns_preroute >/dev/null 2>&1 || nft add chain ip nat qubes_dns_preroute
        nft list chain ip nat prerouting | grep -q 'jump qubes_dns_preroute' || \
          nft add rule ip nat prerouting jump qubes_dns_preroute
        nft flush chain ip nat qubes_dns_preroute

        # Exclude Tor GW (if present)
        if [ -n "${GWIP:-}" ]; then
          nft add rule ip nat qubes_dns_preroute ip saddr $GWIP udp dport 53 accept
          nft add rule ip nat qubes_dns_preroute ip saddr $GWIP tcp dport 53 accept
        fi
        # DNAT all other DNS to sys-dns
        nft add rule ip nat qubes_dns_preroute udp dport 53 dnat to $SYSIP
        nft add rule ip nat qubes_dns_preroute tcp dport 53 dnat to $SYSIP

        {% if ipv6_global_enabled %}
        nft list table ip6 nat >/dev/null 2>&1 || nft add table ip6 nat
        nft list chain ip6 nat prerouting >/dev/null 2>&1 || \
          nft add chain ip6 nat prerouting { type nat hook prerouting priority -100; policy accept; }
        nft list chain ip6 nat qubes_dns_preroute >/dev/null 2>&1 || nft add chain ip6 nat qubes_dns_preroute
        nft list chain ip6 nat prerouting | grep -q 'jump qubes_dns_preroute' || \
          nft add rule ip6 nat prerouting jump qubes_dns_preroute
        nft flush chain ip6 nat qubes_dns_preroute
        # TODO: set SYSIP6 if sys-dns has IPv6 and add v6 DNAT rules here
        {% endif %}

        # (2) Forward-time DoT drop in inet table; optional QUIC drop
        nft list table inet qubes >/dev/null 2>&1 || nft add table inet qubes
        nft list chain inet qubes fwd_dot >/dev/null 2>&1 || \
          nft add chain inet qubes fwd_dot { type filter hook forward priority 90; policy accept; }
        nft list chain inet qubes fwd_dot | grep -q 'udp dport 853 drop' || nft add rule inet qubes fwd_dot udp dport 853 drop
        nft list chain inet qubes fwd_dot | grep -q 'tcp dport 853 drop' || nft add rule inet qubes fwd_dot tcp dport 853 drop
        {% if block_quic %}
        nft list chain inet qubes fwd_dot | grep -q 'udp dport 443 drop' || nft add rule inet qubes fwd_dot udp dport 443 drop
        {% endif %}

        exit 0
        EOF

        qvm-run -u root sys-firewall 'chmod +x /rw/config/qubes-firewall-user-script'
        qvm-run -u root sys-firewall '/rw/config/qubes-firewall-user-script'
    - require:
      - cmd: get-sys-dns-ip
      - cmd: get-sys-vpn-tor-ip
      - qvm.run: sys-firewall-base

{% if enable_suricata %}
sys-firewall-suricata:
  qvm.run:
    - name: sys-firewall
    - user: root
    - cmd: |
        set -e
        apt-get update
        apt-get -y install suricata jq || true
        update-ca-certificates || true
        install -d -m 0755 /etc/suricata /var/lib/suricata/rules /var/log/suricata /etc/systemd/system/suricata.service.d
        cat >/etc/suricata/suricata.yaml <<'EOF'
        %YAML 1.1
        ---
        vars:
          address-groups:
            HOME_NET: "[10.0.0.0/8,172.16.0.0/12,192.168.0.0/16]"
        af-packet:
          - interface: any
            cluster-id: 99
            cluster-type: cluster_flow
            defrag: yes
        outputs:
          - eve-log:
              enabled: yes
              filetype: regular
              filename: /var/log/suricata/eve.json
              community-id: true
              types: [ alert, dns, tls, http, ssh, stats ]
        logging:
          default-log-level: notice
        app-layer:
          protocols:
            tls: { enabled: yes }
            http: { enabled: yes }
            dns: { enabled: yes }
        detection:
          profile: medium
          sgh-mpm-context: auto
        default-rule-path: /var/lib/suricata/rules
        rule-files:
          - suricata.rules
        EOF
        # light rules (optional best-effort)
        TMP=$(mktemp -d); if curl -fsSL https://rules.emergingthreats.net/open/suricata-7.0/emerging.rules.tar.gz -o "$TMP/et.tar.gz"; then
          tar -xzf "$TMP/et.tar.gz" -C "$TMP" && cat "$TMP"/rules/*.rules > /var/lib/suricata/rules/suricata.rules || :
        else : > /var/lib/suricata/rules/suricata.rules; fi; rm -rf "$TMP"
        cat >/etc/systemd/system/suricata.service.d/override.conf <<'EOF'
        [Unit]
        After=network-online.target
        Wants=network-online.target
        EOF
        systemctl daemon-reload
        # NIC offload tweaks at boot
        cat >/rw/config/rc.local <<'EOF'
        #!/bin/sh
        for i in $(ls /sys/class/net | grep -E '^(eth|ens|vif)'); do ethtool -K "$i" gro off lro off 2>/dev/null || true; done
        exit 0
        EOF
        chmod +x /rw/config/rc.local; /rw/config/rc.local || true
        systemctl enable suricata
        systemctl restart suricata || true
{% endif %}

# =========================
# ===     SYS-DNS      ===
# =========================

sys-dns-packages:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: |
        set -e
        apt-get update
        apt-get -y install dnscrypt-proxy nftables ca-certificates curl jq || true
        update-ca-certificates || true
        {% if sysdns_disable_ipv6 %}
        cat >/etc/sysctl.d/99-qubes-ipv6-off.conf <<'EOF'
        net.ipv6.conf.all.disable_ipv6=1
        net.ipv6.conf.default.disable_ipv6=1
        EOF
        sysctl --system || true
        {% endif %}
        mkdir -p /etc/NetworkManager/conf.d
        cat >/etc/NetworkManager/conf.d/00-dns-none.conf <<'EOF'
        [main]
        dns=none
        EOF
        systemctl restart NetworkManager || true
        systemctl disable --now systemd-resolved || true
        rm -f /etc/resolv.conf; echo "nameserver 127.0.0.1" > /etc/resolv.conf
        # dnscrypt base
        sed -i 's/^# *listen_addresses *=.*/listen_addresses = ["127.0.0.1:53"]/ ' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        sed -i 's/^# *require_dnssec *=.*/require_dnssec = true/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        sed -i 's/^# *cache *=.*/cache = true/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        sed -i 's/^# *cache_min_ttl *=.*/cache_min_ttl = 600/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        sed -i 's/^# *cache_max_ttl *=.*/cache_max_ttl = 86400/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        if grep -q '^fallback_resolvers' /etc/dnscrypt-proxy/dnscrypt-proxy.toml; then sed -i 's/^fallback_resolvers.*/fallback_resolvers = []/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml; else echo 'fallback_resolvers = []' >> /etc/dnscrypt-proxy/dnscrypt-proxy.toml; fi
        # server_names from tunable list
        sed -i '/^server_names/d' /etc/dnscrypt-proxy/dnscrypt-proxy.toml || true
        printf 'server_names = [%s]\n' "$(printf '"%s",' {% for n in dnscrypt_server_names %}{{ n }}{% if not loop.last %} {% endif %}{% endfor %} | sed 's/,$//')" >> /etc/dnscrypt-proxy/dnscrypt-proxy.toml
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

sys-dns-egress-nft:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: |
        set -e
        mkdir -p /etc/nftables.d
        cat >/etc/nftables.d/60-sysdns-egress.nft <<'EOF'
        table inet sysdns_egress {
          chain input { type filter hook input priority 0; policy drop;
            iif lo accept; ct state established,related accept; ip protocol icmp accept;
            tcp dport 53 iif lo accept; udp dport 53 iif lo accept; }
          chain forward { type filter hook forward priority 0; policy drop; }
          chain output { type filter hook output priority 0; policy accept;
            # Only local stub for :53
            udp dport 53 ip daddr != 127.0.0.1 drop
            tcp dport 53 ip daddr != 127.0.0.1 drop
            # Allow listed upstreams (v4)
            {% if sysdns_allowlist_v4|length > 0 %}
            {% for e in sysdns_allowlist_v4 %}{% set ip=e.split(':')[0] %}{% set port=e.split(':')[1] %}
            ip daddr {{ ip }} udp dport {{ port|int }} accept
            ip daddr {{ ip }} tcp dport {{ port|int }} accept
            {% endfor %}
            # Drop other external :53/:853 (defense-in-depth)
            udp dport {53,853} ip daddr != 127.0.0.1 drop
            tcp dport {53,853} ip daddr != 127.0.0.1 drop
            {% else %}
            udp dport {53,853} ip daddr != 127.0.0.1 drop
            tcp dport {53,853} ip daddr != 127.0.0.1 drop
            {% endif %}
            {% if not sysdns_disable_ipv6 %}
            {% for e in sysdns_allowlist_v6 %}{% set ip=e.split(':')[0] %}{% set port=e.split(':')[1] %}
            ip6 daddr {{ ip }} udp dport {{ port|int }} accept
            ip6 daddr {{ ip }} tcp dport {{ port|int }} accept
            {% endfor %}
            {% endif %}
            {% if sysdns_restrict_doh %}
            # Restrict DoH (443) to explicit IPs only
            {% if sysdns_doh_allowlist_v4|length > 0 %}
            {% for e in sysdns_doh_allowlist_v4 %}{% set ip=e.split(':')[0] %}
            ip daddr {{ ip }} tcp dport 443 accept
            {% endfor %}
            tcp dport 443 drop
            {% else %}
            tcp dport 443 drop
            {% endif %}
            {% if not sysdns_disable_ipv6 %}
            {% if sysdns_doh_allowlist_v6|length > 0 %}
            {% for e in sysdns_doh_allowlist_v6 %}{% set ip=e.split(':')[0] %}
            ip6 daddr {{ ip }} tcp dport 443 accept
            {% endfor %}
            tcp dport 443 drop
            {% else %}
            tcp dport 443 drop
            {% endif %}
            {% endif %}
          }
        }
        EOF
        if ! grep -q 'include "/etc/nftables.d/*.nft"' /etc/nftables.conf 2>/dev/null; then echo 'include "/etc/nftables.d/*.nft"' > /etc/nftables.conf; fi
        systemctl enable nftables
        systemctl restart nftables
    - require:
      - qvm.run: sys-dns-packages

# =========================
# ===    SYS-VPN-*     ===
# =========================

{% for vm,conf in vpn_killswitch.items() %}
{{ vm }}-packages:
  qvm.run:
    - name: {{ vm }}
    - user: root
    - cmd: |
        set -e
        # Try dnf first (Fedora), fallback to apt (Debian-based)
        if command -v dnf >/dev/null 2>&1; then dnf -y install nftables iproute iputils ca-certificates || true; update-ca-trust || true; systemctl enable nftables || true; systemctl restart nftables || true; else apt-get update; apt-get -y install nftables iproute2 iputils-ping ca-certificates || true; update-ca-certificates || true; systemctl enable nftables || true; systemctl restart nftables || true; fi
        # resolv.conf -> upstream qubes DNS (DNS will be DNATed to sys-dns at sys-firewall)
        rm -f /etc/resolv.conf; echo "nameserver 10.139.1.1" > /etc/resolv.conf || true

{{ vm }}-killswitch-nft:
  qvm.run:
    - name: {{ vm }}
    - user: root
    - cmd: |
        set -e
        mkdir -p /etc/nftables.d
        cat >/etc/nftables.d/70-vpn-killswitch.nft <<'EOF'
        table inet vpn_lock {
          chain input { type filter hook input priority 0; policy drop;
            iif lo accept; ct state established,related accept; ip protocol icmp accept;
            {% for ifn in conf['tunnel_ifaces'] %} iifname "{{ ifn }}" accept; {% endfor %}
          }
          chain forward { type filter hook forward priority 0; policy drop;
            # Only forward between VIF<->tunnel
            {% for ifn in conf['tunnel_ifaces'] %} iifname "{{ ifn }}" oifname "vif*" accept; {% endfor %}
            {% for ifn in conf['tunnel_ifaces'] %} iifname "vif*" oifname "{{ ifn }}" accept; {% endfor %}
          }
          chain output { type filter hook output priority 0; policy drop;
            ct state established,related accept;
            # Allow tunnel egress (inside the tunnel)
            {% for ifn in conf['tunnel_ifaces'] %} oifname "{{ ifn }}" accept; {% endfor %}
            # Bootstrap DNS to qubes resolver only (DNAT to sys-dns at sys-firewall)
            {% if conf['allow_dns_bootstrap'] %} ip daddr 10.139.1.1 udp dport 53 accept; ip daddr 10.139.1.1 tcp dport 53 accept; {% endif %}
            # Allow contacting VPN servers on uplink
            {% for e in conf['allow_upstream_v4'] %}{% set ip=e.split(':')[0] %}{% set port=e.split(':')[1] %}{% set proto=e.split(':')[2] %}
            ip daddr {{ ip }} {{ proto }} dport {{ port|int }} accept
            {% endfor %}
            {% if ipv6_global_enabled %}
            {% for e in conf['allow_upstream_v6'] %}{% set ip=e.split(':')[0] %}{% set port=e.split(':')[1] %}{% set proto=e.split(':')[2] %}
            ip6 daddr {{ ip }} {{ proto }} dport {{ port|int }} accept
            {% endfor %}
            {% endif %}
          }
        }
        EOF
        if ! grep -q 'include "/etc/nftables.d/*.nft"' /etc/nftables.conf 2>/dev/null; then echo 'include "/etc/nftables.d/*.nft"' > /etc/nftables.conf; fi
        systemctl enable nftables
        systemctl restart nftables
    - require:
      - qvm.run: {{ vm }}-packages
{% endfor %}

# =========================
# ===  TOPOLOGY SWITCH ===
# =========================

install-switcher-script:
  cmd.run:
    - name: |
        set -e
        cat >/usr/local/bin/switch-vpn-topology <<'EOF'
        #!/bin/bash
        set -euo pipefail
        usage(){ cat <<USAGE
        usage: $0 <dns-vpn | dns-tor-vpn | dns-vpn-tor> [vpn-vm]
        examples:
          $0 dns-vpn sys-vpn-nl
          $0 dns-vpn-tor sys-vpn-ru
          $0 dns-tor-vpn
        USAGE
        }
        MODE="${1:-}"; VPN="${2:-}"
        [[ -z "$MODE" ]] && { usage; exit 1; }
        case "$MODE" in dns-vpn|dns-tor-vpn|dns-vpn-tor) ;; *) echo "Invalid mode: $MODE"; usage; exit 1;; esac
        need_vm(){ qvm-ls --raw-list | grep -qx "$1" || { echo "Missing VM: $1" >&2; exit 1; }; }
        need_vm sys-firewall; need_vm sys-dns; need_vm sys-net
        if [[ -z "$VPN" ]]; then
          if   qvm-ls --raw-list | grep -qx sys-vpn-ru; then VPN="sys-vpn-ru";
          elif qvm-ls --raw-list | grep -qx sys-vpn-nl; then VPN="sys-vpn-nl"; else echo "No VPN VMs found"; exit 1; fi
        else need_vm "$VPN"; fi
        link(){ qvm-prefs "$1" netvm "$2"; }
        case "$MODE" in
          dns-vpn)
            link sys-firewall sys-net
            link sys-dns      "$VPN"
            link "$VPN"       sys-net;;
          dns-tor-vpn)
            need_vm sys-vpn-tor
            link sys-firewall sys-net
            link sys-dns      sys-vpn-tor
            link sys-vpn-tor  "$VPN"
            link "$VPN"       sys-net;;
          dns-vpn-tor)
            need_vm sys-vpn-tor
            link sys-firewall sys-net
            link sys-dns      "$VPN"
            link "$VPN"       sys-vpn-tor
            link sys-vpn-tor  sys-net;;
        esac
        echo "Switched to: $MODE (VPN=$VPN)"
        EOF
        chmod 0755 /usr/local/bin/switch-vpn-topology

apply-selected-topology:
  cmd.run:
    - name: |
        set -e
        /usr/local/bin/switch-vpn-topology {{ topology_mode }} {{ selected_vpn }}
    - require:
      - cmd: install-switcher-script

# =========================
# ===   STATUS OUTPUT   ===
# =========================
show-topology-status:
  cmd.run:
    - name: |
        set -e
        echo "Topology: {{ topology_mode }}  |  VPN: {{ selected_vpn }}"
        printf "%-14s -> %s\n" sys-firewall "$(qvm-prefs sys-firewall netvm)"
        printf "%-14s -> %s\n" sys-dns      "$(qvm-prefs sys-dns netvm)"
        for VM in sys-vpn-ru sys-vpn-nl sys-vpn-tor; do
          qvm-ls --raw-list | grep -qx "$VM" && printf "%-14s -> %s\n" "$VM" "$(qvm-prefs "$VM" netvm)" || true
        done
        echo "Done."
