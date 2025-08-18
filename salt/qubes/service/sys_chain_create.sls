# /srv/salt/qubes/services/create.sls

# /srv/salt/qubes/services/net_chain_create.sls
{% set deb_min = 'deb_harden_min' %}

sys-net:
  qvm.vm:
    - template: {{ deb_min }}
    - label: red
    - properties: { provides_network: True }
    - prefs: { netvm: none }

sys-firewall:
  qvm.vm:
    - template: {{ deb_min }}
    - label: green
    - prefs: { netvm: sys-net }

sys-dns:
  qvm.vm:
    - template: {{ deb_min }}
    - label: blue
    - prefs: { netvm: sys-firewall }

sys-net-hardening:
  qvm.run:
    - name: sys-net
    - user: root
    - cmd: |
        set -e
        cat >/etc/sysctl.d/99-qubes-ipv6-off.conf <<'EOF'
        net.ipv6.conf.all.disable_ipv6=1
        net.ipv6.conf.default.disable_ipv6=1
        EOF
        sysctl --system || true
        mkdir -p /etc/NetworkManager/conf.d
        cat >/etc/NetworkManager/conf.d/00-macrandomize.conf <<'EOF'
        [connection]
        wifi.mac-address-randomization=1
        ethernet.cloned-mac-address=random
        wifi.cloned-mac-address=random
        [device]
        wifi.scan-rand-mac-address=yes
        EOF
        systemctl restart NetworkManager || true

        cat >/etc/nftables.conf <<'EOF'
        table inet filter {
          chain input { type filter hook input priority 0; policy drop;
            ct state {established,related} accept; iif lo accept; ip protocol icmp accept; }
          chain forward { type filter hook forward priority 0; policy drop; }
          chain output  { type filter hook output priority 0; policy accept; }
        }
        EOF
        systemctl enable nftables
        systemctl restart nftables


# Whonix gateway
sys-whonix:
  qvm.vm:
    - template: whonix-workstation-17
    - label: green
    - prefs:
        netvm: sys-firewall


# Create a Whonix-Gateway that rides over a VPN NetVM (default: sys-vpn-ru)
# You can change upstream later with: qvm-prefs sys-vpn-tor netvm sys-vpn-nl
# Result: sys-vpn-tor provides_network=True, NetVM=sys-vpn-ru (default), Tor runs inside it as usual—only now over your VPN.
# Ensure base Whonix GW template exists

whonix-gw-template-present:
  cmd.run:
    - name: qvm-ls --raw-list | grep -qx whonix-gateway-17 || qvm-template install whonix-gateway-17

# Create sys-vpn-tor if missing
sys-vpn-tor-create:
  cmd.run:
    - name: |
        set -e
        if ! qvm-ls --raw-list | grep -qx sys-vpn-tor; then
          qvm-create --class AppVM --template whonix-gateway-17 --label blue sys-vpn-tor
          qvm-prefs sys-vpn-tor provides_network True
          qvm-prefs sys-vpn-tor netvm sys-vpn-ru
        fi
sys-usb:
  qvm.vm:
    - template: deb12-net-min
    - label: red
    - prefs:
        netvm: none
    - features:
        usbvm: True

sys-audio:
  qvm.vm:
    - template: deb12-net-min
    - label: blue
    - prefs:
        netvm: none
