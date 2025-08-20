# /srv/salt/qubes/services/vpn_chain.sls
# Create two VPN NetVMs (Fedora-based), an optional Tor NetVM (Whonix-GW),
# and provide a helper to switch between three topologies:
#  1) firewall -> dns -> vpn -> net
#  2) firewall -> dns -> tor -> vpn -> net
#  3) firewall -> dns -> vpn -> tor -> net
#
# Assumes the following already exist: sys-firewall, sys-dns, sys-net.
# Works alongside your hardened sys-firewall state (DNS DNAT stays in sys-firewall).

# -------------------------
#  Tunables (edit these)
#  ------------------------- 
{% set vpn_template   = 'fedora-42-vpn' %}
{% set upstream_netvm = 'sys-firewall' %}
{% set selected_vpn   = 'sys-vpn-ru' %}       # choose: sys-vpn-ru or sys-vpn-nl
{% set topology_mode  = 'dns-vpn' %}          # choose: dns-vpn | dns-tor-vpn | dns-vpn-tor

# -------------------------
#  Sanity macro
# ------------------------- 
{% macro set_netvm(vm, netvm) %}
{{ vm }}-netvm:
  cmd.run:
    - name: qvm-prefs {{ vm }} netvm {{ netvm }}
{% endmacro %}


# -------------------------
#  Create Fedora-based VPN NetVMs
#  ------------------------- #}
{% for vm in ['sys-vpn-ru','sys-vpn-nl'] %}

{{ vm }}-create:
  qvm.vm:
    - template: {{ vpn_template }}
    - label: orange
    - properties:
        provides_network: True
    - prefs:
        netvm: {{ upstream_netvm }}

{{ vm }}-tag:
  qvm.tag:
    - name: @tag:vpn-tor-vm
    - vm: [ {{ vm }} ]

{{ vm }}-finalize:
  qvm.run:
    - name: {{ vm }}
    - user: root
    - cmd: |
        set -e
        # Fedora userspace (dnf). Keep these VMs minimal.
        dnf -y update || true
        dnf -y install nftables iproute iputils ca-certificates || true
        update-ca-trust || true

        # Ensure nftables ready; Fedora doesn't use systemd-resolved by default.
        systemctl enable nftables || true
        systemctl restart nftables || true

        # Prevent local resolver surprises; let upstream (sys-dns) handle DNS.
        # NetworkManager default is fine; just point resolv.conf at upstream.
        rm -f /etc/resolv.conf
        echo "nameserver 10.139.1.1" > /etc/resolv.conf || true
        # ^ Qubes internal DNS forwarder; sys-firewall will DNAT to sys-dns anyway.

{% endfor %}

# -------------------------
#  Create Tor gateway 
#  ------------------------- #}
sys-vpn-tor-create:
  cmd.run:
    - name: |
        set -e
        if ! qvm-ls --raw-list | grep -qx sys-vpn-tor; then
          qvm-create --class AppVM --template whonix-gateway-17 --label blue sys-vpn-tor
          qvm-prefs sys-vpn-tor provides_network True
          # default upstream for Tor will be adjusted by the topology switcher below
          qvm-prefs sys-vpn-tor netvm {{ selected_vpn }}
        fi

sys-vpn-tor-tag:
  qvm.tag:
    - name: @tag:vpn-tor-vm
    - vm: [ sys-vpn-tor ]
