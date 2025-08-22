# ============================
# Firewall  CONTROLS
# - QUIC block (udp/443) + optional DoH IP set
# - DNS DNAT -> sys-dns + DoT(853) block (+ Whonix exclusion hook point)
# - Light shaping (DNS bursts / eg TCP rate)
# ============================

# ---------- QUIC block  ---------- #}
sys-fw-quic-block:
  qvm.run:
    - name: sys-firewall
    - user: root
    - cmd: |
        set -e
        nft list table inet qubes >/dev/null 2>&1 || nft add table inet qubes
        nft list chain inet qubes fwd_quic >/dev/null 2>&1 || \
          nft add chain inet qubes fwd_quic { type filter hook forward priority 96; policy accept; }
        nft list chain inet qubes fwd_quic | grep -q 'udp dport 443 drop' || \
          nft add rule inet qubes fwd_quic udp dport 443 drop

#  DoH IP set (supply IPs in /rw/config/doh-block.list)
sys-fw-doh-toggle:
  qvm.run:
    - name: sys-firewall
    - user: root
    - cmd: |
        set -e
        nft list table inet qubes >/dev/null 2>&1 || nft add table inet qubes
        nft list set inet qubes doh_ips >/dev/null 2>&1 || nft add set inet qubes doh_ips { type ipv4_addr; flags dynamic; }
        nft list chain inet qubes fwd_doh >/dev/null 2>&1 || nft add chain inet qubes fwd_doh { type filter hook forward priority 95; policy accept; }
        nft list chain inet qubes fwd_doh | grep -q 'ip daddr @doh_ips tcp dport 443 drop' || \
          nft add rule inet qubes fwd_doh ip daddr @doh_ips tcp dport 443 drop
        cat >/usr/local/sbin/doh-block-reload <<'EOF'
        #!/bin/sh
        set -eu
        LIST="/rw/config/doh-block.list"
        nft flush set inet qubes doh_ips || true
        [ -f "$LIST" ] || exit 0
        while read -r ip; do
          [ -z "$ip" ] && continue
          nft add element inet qubes doh_ips { $ip } || true
        done < "$LIST"
        EOF
        chmod +x /usr/local/sbin/doh-block-reload
        /usr/local/sbin/doh-block-reload || true

# ---------- DNS DNAT to sys-dns; DoT(853) block; shaping ---------- #}
sys-fw-core-nat-shape:
  qvm.run:
    - name: sys-firewall
    - user: root
    - cmd: |
        set -e
        # Light shaping
        nft list chain inet qubes fwd_shape >/dev/null 2>&1 || \
          nft add chain inet qubes fwd_shape { type filter hook forward priority 80; policy accept; }
        nft list chain inet qubes fwd_shape | grep -q 'udp dport 53 limit rate over 200/second drop' || \
          nft add rule inet qubes fwd_shape udp dport 53 limit rate over 200/second drop
