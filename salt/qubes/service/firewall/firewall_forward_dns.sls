# Redirect ALL forwarded DNS to sys-dns, EXCEPT traffic coming from sys-vpn-tor (Whonix-GW)
get-sys-dns-ip:
  cmd.run:
    - name: |
        set -e
        qvm-ls --raw-data --fields NAME,IP | awk -F'|' '$1=="sys-dns"{print $2}' | tr -d ' \t' > /var/tmp/sysdns.ip

get-sys-vpn-tor-ip:
  cmd.run:
    - name: |
        set -e
        qvm-ls --raw-data --fields NAME,IP | awk -F'|' '$1=="sys-vpn-tor"{print $2}' | tr -d ' \t' > /var/tmp/sysvpntor.ip

install-forward-dns-redirect:
  cmd.run:
    - name: |
        set -e
        SYSIP="$(cat /var/tmp/sysdns.ip || true)"
        GWIP="$(cat /var/tmp/sysvpntor.ip || true)"
        [ -z "$SYSIP" ] && { echo "sys-dns IP not found" >&2; exit 1; }
        [ -z "$GWIP" ] && { echo "sys-vpn-tor IP not found" >&2; exit 1; }

        qvm-run -u root --pass-io sys-firewall 'cat >/rw/config/qubes-firewall-user-script' <<EOF
        #!/bin/sh
        # NAT table: DNAT all forwarded DNS to sys-dns ($SYSIP), except from sys-vpn-tor ($GWIP)
        nft list table ip nat >/dev/null 2>&1 || nft add table ip nat
        nft delete chain ip nat prerouting 2>/dev/null || true
        nft add chain ip nat prerouting { type nat hook prerouting priority -100; policy accept; }

        # Exclude packets FROM sys-vpn-tor (Whonix-GW) so Tor handles DNS internally
        nft add rule ip nat prerouting ip saddr $GWIP udp dport 53 accept
        nft add rule ip nat prerouting ip saddr $GWIP tcp dport 53 accept

        # DNAT everything else to sys-dns
        nft add rule ip nat prerouting udp dport 53 dnat to $SYSIP
        nft add rule ip nat prerouting tcp dport 53 dnat to $SYSIP
        exit 0
        EOF

        qvm-run -u root sys-firewall 'chmod +x /rw/config/qubes-firewall-user-script'
        qvm-run -u root sys-firewall '/rw/config/qubes-firewall-user-script'


# Drops TCP/UDP 853 (DNS-over-TLS) in FORWARD on sys-firewall
sys-firewall-block-dot:
  qvm.run:
    - name: sys-firewall
    - user: root
    - cmd: |
        set -e
        nft list table inet qubes >/dev/null 2>&1 || nft add table inet qubes
        # Create a forward chain (if not exists) with policy accept so Qubes rules stand,
        # then add our specific DoT drops at a later priority.
        nft list chain inet qubes fwd_dot >/dev/null 2>&1 || \
          nft add chain inet qubes fwd_dot { type filter hook forward priority 90; policy accept; }
        # Add rules idempotently
        nft list chain inet qubes fwd_dot | grep -q 'udp dport 853 drop' || nft add rule inet qubes fwd_dot udp dport 853 drop
        nft list chain inet qubes fwd_dot | grep -q 'tcp dport 853 drop' || nft add rule inet qubes fwd_dot tcp dport 853 drop

set-updatevm-sys-firewall:
  cmd.run:
    - name: qubes-prefs updatevm sys-firewall
    - unless: qubes-prefs get updatevm | grep -q sys-firewall

