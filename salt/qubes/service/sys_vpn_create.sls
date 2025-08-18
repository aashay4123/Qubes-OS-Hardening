{% set vpn_template = 'fedora-42-vpn' %}
{% set upstream_netvm = 'sys-firewall' %}

{% for vm in ['sys-vpn-ru','sys-vpn-nl'] %}

{{ vm }}-create:
  qvm.vm:
    - template: {{ vpn_template }}
    - label: orange
    - prefs: { netvm: {{ upstream }} }

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
        apt-get update -y && apt-get dist-upgrade -y

        # Ensure resolv.conf and services are correct in the VM
        systemctl disable --now systemd-resolved || true
        rm -f /etc/resolv.conf; echo "nameserver 127.0.0.1" > /etc/resolv.conf
        systemctl enable nftables; systemctl restart nftables || true
        systemctl enable --now dnscrypt-proxy || true

{% endfor %}



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
