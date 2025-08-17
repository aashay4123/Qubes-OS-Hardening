# Compute sys-dns IP in dom0 and inject a forward-DNS filter into sys-firewall
get-sys-dns-ip:
  cmd.run:
    - name: |
        set -e
        qvm-ls --raw-data --fields NAME,IP \
          | awk -F'|' '$1=="sys-dns"{print $2}' \
          | tr -d ' \t' > /var/tmp/sysdns.ip

push-dns-forward-filter:
  cmd.run:
    - name: |
        set -e
        SYSIP="$(cat /var/tmp/sysdns.ip || true)"
        [ -z "$SYSIP" ] && { echo "sys-dns IP not found" >&2; exit 1; }
        qvm-run -u root --pass-io sys-firewall 'cat >/rw/config/qubes-firewall-user-script' <<EOF
        #!/bin/sh
        # Drop forwarded DNS from everyone except sys-dns ($SYSIP)
        nft list table inet qubes >/dev/null 2>&1 || nft add table inet qubes
        nft delete chain inet qubes fwd_dns 2>/dev/null || true
        nft add chain inet qubes fwd_dns { type filter hook forward priority 80; policy accept; }
        nft add rule inet qubes fwd_dns ip saddr != $SYSIP udp dport 53 drop
        nft add rule inet qubes fwd_dns ip saddr != $SYSIP tcp dport 53 drop
        exit 0
        EOF
        qvm-run -u root sys-firewall 'chmod +x /rw/config/qubes-firewall-user-script'
        # Apply immediately this run
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
