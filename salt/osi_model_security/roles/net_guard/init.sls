{% from "osi_model_security/map.jinja" import cfg with context %}
{% set topo   = cfg.net_topology %}
{% set guard  = topo.guard %}
{% set chain  = topo.chains.get(topo.active, {}).get('order', []) %}
{% set has   = lambda name: name in topo.vms %}

{# Helper: script to ensure nftables is installed, /etc/nftables.d exists, and /etc/nftables.conf includes it #}
{% macro ensure_nft(vm) -%}
{{ vm }}-nft-setup:
  module.run:
    - name: qvm.run
    - vm: {{ vm }}
    - args:
      - |
        sh -lc '
          if command -v dnf >/dev/null; then
            dnf -y install nftables || true
          elif command -v apt-get >/dev/null; then
            apt-get update && apt-get -y install nftables || true
          fi
          mkdir -p /etc/nftables.d
          # Ensure /etc/nftables.conf includes directory
          if [ ! -f /etc/nftables.conf ]; then
            echo "include \"/etc/nftables.d/*.nft\"" >/etc/nftables.conf
          elif ! grep -q "/etc/nftables.d/" /etc/nftables.conf; then
            echo "include \"/etc/nftables.d/*.nft\"" >>/etc/nftables.conf
          fi
          systemctl enable nftables || true
        '
{%- endmacro %}

{# Helper: disable IPv6 if requested #}
{% macro disable_ipv6(vm) -%}
{% if guard.ipv6_disable %}
{{ vm }}-disable-ipv6:
  module.run:
    - name: qvm.run
    - vm: {{ vm }}
    - args:
      - |
        sh -lc '
          cat >/etc/sysctl.d/99-disable-ipv6.conf <<EOF
          net.ipv6.conf.all.disable_ipv6 = 1
          net.ipv6.conf.default.disable_ipv6 = 1
          EOF
          sysctl --system || true
        '
{% endif %}
{%- endmacro %}

{# ---------- sys-firewall: block DNS/DoT/QUIC forwarding leaks from app VMs ---------- #}
{% if has('sys-firewall') %}
{{ ensure_nft('sys-firewall') }}
{{ disable_ipv6('sys-firewall') }}

sys-firewall-guard-nft:
  module.run:
    - name: qvm.run
    - vm: sys-firewall
    - args:
      - |
        sh -lc '
          cat >/etc/nftables.d/30-guard-firewall.nft << "EOF"
          table inet guard_fw {
            chain forward {
              type filter hook forward priority 0;
              ct state established,related accept
              # Block direct DNS from downstream VMs (they must use local dnsmasq)
              udp dport 53 drop
              tcp dport 53 drop
              {% if guard.block_dot %}tcp dport 853 drop{% endif %}
              {% if guard.block_quic %}udp dport 443 drop{% endif %}
              accept
            }
          }
          EOF
          nft -f /etc/nftables.conf || true
          systemctl restart nftables || true
        '
  require:
    - module: sys-firewall-nft-setup
{% endif %}

{# ---------- sys-dns: ONLY DNS (and optional NTP) may egress; everything else drops ---------- #}
{% if has('sys-dns') %}
{{ ensure_nft('sys-dns') }}
{{ disable_ipv6('sys-dns') }}

sys-dns-guard-nft:
  module.run:
    - name: qvm.run
    - vm: sys-dns
    - args:
      - |
        sh -lc '
          # Build optional IP allowlist set for resolvers (tightest mode)
          ALLOW_IPS="{% for ip in guard.sys_dns_allow_ips %}{{ ip }} {% endfor %}"
          cat >/etc/nftables.d/30-guard-dns.nft <<EOF
          table inet guard_dns {
            set dns_allow {
              type ipv4_addr;
              flags interval;
              elements = { ${ALLOW_IPS} }
            }
            chain output {
              type filter hook output priority 0;
              # Always allow loopback
              oifname "lo" accept
              ct state established,related accept
              {% if guard.allow_ntp %}udp dport 123 accept{% endif %}
              # Allow DNS recursion or DoT depending on toggle
              {% if guard.enforce_dns_out_only %}
              {% if guard.sys_dns_dot %}
                tcp dport 853 {% if guard.sys_dns_allow_ips|length > 0 %} ip daddr @dns_allow {% endif %} accept
              {% endif %}
                udp dport 53  {% if guard.sys_dns_allow_ips|length > 0 %} ip daddr @dns_allow {% endif %} accept
                tcp dport 53  {% if guard.sys_dns_allow_ips|length > 0 %} ip daddr @dns_allow {% endif %} accept
                counter drop
              {% else %}
                accept
              {% endif %}
            }
          }
          EOF
          nft -f /etc/nftables.conf || true
          systemctl restart nftables || true
        '
  require:
    - module: sys-dns-nft-setup
{% endif %}

{# ---------- sys-vpn: hard killswitch (only tun/wg out; allow endpoints on eth0) ---------- #}
{% if has('sys-vpn') and guard.vpn.killswitch %}
{{ ensure_nft('sys-vpn') }}
{{ disable_ipv6('sys-vpn') }}

sys-vpn-guard-nft:
  module.run:
    - name: qvm.run
    - vm: sys-vpn
    - args:
      - |
        sh -lc '
          # Build VPN endpoint set from pillar
          # Expect entries like: { ip: 203.0.113.10, port: 51820, proto: udp }
          cat >/etc/nftables.d/30-guard-vpn.nft << "EOF"
          table inet guard_vpn {
            set vpn_hosts {
              type ipv4_addr;
              elements = { {% for ep in guard.vpn.endpoints %}{{ ep.ip }}{% if not loop.last %}, {% endif %}{% endfor %} }
            }
            chain output {
              type filter hook output priority 0;
              # Always allow loopback
              oifname "lo" accept
              ct state established,related accept
              # Allow DHCP/NM to get upstream IP
              udp sport 68 udp dport 67 accept

              # Allow out via tunnel interfaces (WireGuard/OpenVPN)
              oifname "wg0" accept
              oifname "tun0" accept

              # Allow contacting VPN servers on eth0 only (endpoints from pillar)
              {% set ovpn_ports = [1194, 443] %}
              {% set wg_port = 51820 %}
              {% for ep in guard.vpn.endpoints %}
                {% if ep.proto == 'udp' %}
                  ip daddr {{ ep.ip }} udp dport {{ ep.port|default(wg_port) }} oifname "eth0" accept
                {% else %}
                  ip daddr {{ ep.ip }} tcp dport {{ ep.port|default(ovpn_ports[0]) }} oifname "eth0" accept
                {% endif %}
              {% endfor %}

              # Drop anything else going out on the physical uplink
              oifname "eth0" counter drop
              # Let other mgmt/local traffic through (e.g., vif* to vif*) — safe
              accept
            }

            chain forward {
              type filter hook forward priority 0;
              ct state established,related accept
              # Only forward downstream → tunnel (no raw eth0 forwarding)
              iifname "vif+" oifname "wg0" accept
              iifname "vif+" oifname "tun0" accept
              # Inbound from tunnel to downstream
              iifname "wg0" oifname "vif+" accept
              iifname "tun0" oifname "vif+" accept
              # Never forward via eth0 (prevents raw leaks)
              oifname "eth0" counter drop
              accept
            }
          }
          EOF
          nft -f /etc/nftables.conf || true
          systemctl restart nftables || true
        '
  require:
    - module: sys-vpn-nft-setup
{% endif %}
