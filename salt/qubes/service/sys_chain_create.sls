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
        # MAC randomization (only matters in sys-net)
        cat >/etc/NetworkManager/conf.d/00-macrandomize.conf <<'EOF'
        [connection]
        ethernet.cloned-mac-address=random
        wifi.cloned-mac-address=random
        wifi.mac-address-randomization=1
        [device]
        wifi.scan-rand-mac-address=yes
        EOF
        systemctl restart NetworkManager || true

# Fetch IPs we’ll need for redirect rules (sys-dns required; sys-vpn-tor optional)
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

install-forward-dns-redirect:
  cmd.run:
    - name: |
        set -e
        SYSIP="$(cat /var/tmp/sysdns.ip || true)"
        GWIP="$(cat /var/tmp/sysvpntor.ip || true)"
        [ -z "$SYSIP" ] && { echo "sys-dns IP not found" >&2; exit 1; }

        qvm-run -u root --pass-io sys-firewall 'cat >/rw/config/qubes-firewall-user-script' <<'EOF'
        #!/bin/sh
        set -e
        # Ensure NAT table exists
        nft list table ip nat >/dev/null 2>&1 || nft add table ip nat
        nft list chain ip nat prerouting >/dev/null 2>&1 || \
          nft add chain ip nat prerouting { type nat hook prerouting priority -100; policy accept; }

        # Clean previous rules (idempotent)
        nft list chain ip nat prerouting | grep -q 'dport 53' && \
          nft flush chain ip nat prerouting || true

        # If sys-vpn-tor IP is known, exclude its DNS (Tor handles its own)
        GWIP="$(cat /var/tmp/sysvpntor.ip 2>/dev/null || true)"
        if [ -n "$GWIP" ]; then
          nft add rule ip nat prerouting ip saddr $GWIP udp dport 53 accept
          nft add rule ip nat prerouting ip saddr $GWIP tcp dport 53 accept
        fi

        # DNAT all other forwarded DNS traffic to sys-dns
        SYSIP="$(cat /var/tmp/sysdns.ip)"
        nft add rule ip nat prerouting udp dport 53 dnat to $SYSIP
        nft add rule ip nat prerouting tcp dport 53 dnat to $SYSIP
        exit 0
        EOF

        qvm-run -u root sys-firewall 'chmod +x /rw/config/qubes-firewall-user-script'
        qvm-run -u root sys-firewall '/rw/config/qubes-firewall-user-script'

# Block DoT (853) in FORWARD on sys-firewall (DoH on 443 can’t be reliably blocked)
sys-firewall-block-dot:
  qvm.run:
    - name: sys-firewall
    - user: root
    - cmd: |
        set -e
        nft list table inet qubes >/dev/null 2>&1 || nft add table inet qubes
        nft list chain inet qubes fwd_dot >/dev/null 2>&1 || \
          nft add chain inet qubes fwd_dot { type filter hook forward priority 90; policy accept; }
        nft list chain inet qubes fwd_dot | grep -q 'udp dport 853 drop' || nft add rule inet qubes fwd_dot udp dport 853 drop
        nft list chain inet qubes fwd_dot | grep -q 'tcp dport 853 drop' || nft add rule inet qubes fwd_dot tcp dport 853 drop

set-updatevm-sys-firewall:
  cmd.run:
    - name: qubes-prefs updatevm sys-firewall
    - unless: qubes-prefs get updatevm | grep -q sys-firewall


# Create a Whonix-Gateway that rides over a VPN NetVM (default: sys-vpn)
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


