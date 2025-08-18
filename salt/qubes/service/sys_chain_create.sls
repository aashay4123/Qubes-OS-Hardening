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
        mkdir -p /etc/NetworkManager/conf.d



# Create a Whonix-Gateway that rides over a VPN NetVM (default: sys-vpn-ru)
# You can change upstream later with: qvm-prefs sys-vpn-tor netvm sys-vpn-nl
# Result: sys-vpn-tor provides_network=True, NetVM=sys-vpn-ru (default), Tor runs inside it as usual—only now over your VPN.
# Ensure base Whonix GW template exists

whonix-gw-template-present:
  cmd.run:
    - name: qvm-ls --raw-list | grep -qx whonix-gateway-17 || qvm-template install whonix-gateway-17

# Whonix gateway
sys-whonix:
  qvm.vm:
    - template: whonix-gateway-17
    - label: green
    - prefs:
        netvm: sys-firewall



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


