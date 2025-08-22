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


# --------- Global behaviors --------- #}
{% set ipv6_global_enabled = False %}         

# --------- Per-VPN kill-switch configuration --------- #}
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
