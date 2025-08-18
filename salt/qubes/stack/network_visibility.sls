# ============================
# NETWORK VISIBILITY & CONTROLS
# - sys-dns: dnscrypt-proxy hardened (DNSSEC, localhost-only)
# - sys-firewall: Suricata AF_PACKET + rule updates + forward high-sev alerts
# - QUIC block (udp/443) + optional DoH IP set
# - DNS DNAT -> sys-dns + DoT(853) block (+ Whonix exclusion hook point)
# - Per-VM egress allow-lists (nft sets)
# - Light shaping (DNS bursts / eg TCP rate)
# ============================

# ---------- sys-dns hardening ---------- #}
sys-dns-dnscrypt:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: |
        set -e
        apt-get update -y || true
        apt-get install -y --no-install-recommends dnscrypt-proxy nftables ca-certificates || true
        update-ca-certificates || true
        CONF=/etc/dnscrypt-proxy/dnscrypt-proxy.toml
        [ -f "$CONF" ] || exit 0
        sed -i 's/^#\? *listen_addresses.*/listen_addresses = ["127.0.0.1:53"]/' "$CONF"
        sed -i 's/^#\? *require_dnssec.*/require_dnssec = true/' "$CONF"
        sed -i 's/^#\? *cache.*/cache = true/' "$CONF"
        sed -i 's/^#\? *block_unqualified.*/block_unqualified = true/' "$CONF"
        sed -i 's/^#\? *block_undelegated.*/block_undelegated = true/' "$CONF"
        systemctl enable --now dnscrypt-proxy
        # lock DNS egress to localhost
        mkdir -p /etc/nftables.d
        cat >/etc/nftables.d/60-dnslock.nft <<'EOF'
        table inet dnslock {
          chain output { type filter hook output priority 0; policy accept;
            udp dport 53 ip daddr != 127.0.0.1 drop
            tcp dport 53 ip daddr != 127.0.0.1 drop
          }
        }
        EOF
        echo 'include "/etc/nftables.d/*.nft"' >/etc/nftables.conf
        systemctl enable nftables
        systemctl restart nftables

# ---------- sys-firewall: Suricata + rules + alert forward ---------- #}
sys-fw-suricata-install:
  qvm.run:
    - name: sys-firewall
    - user: root
    - cmd: |
        set -e
        apt-get update -y || true
        apt-get install -y --no-install-recommends suricata suricata-update jq nftables || true
        systemctl enable --now suricata-update.timer || true
        # minimal config
        cat >/etc/suricata/suricata.yaml <<'EOF'
        af-packet:
          - interface: any
            cluster-id: 99
            cluster-type: cluster_flow
            defrag: yes
            use-mmap: yes
        outputs:
          - eve-log:
              enabled: yes
              filetype: regular
              filename: /var/log/suricata/eve.json
              types:
                - alert:
                    tagged-packets: no
        EOF
        systemctl restart suricata
        # forward high-severity alerts to sys-alert
        cat >/usr/local/sbin/suricata-to-alert <<'EOF'
        #!/bin/sh
        set -eu
        TAIL="/var/log/suricata/eve.json"
        [ -f "$TAIL" ] || exit 0
        tail -Fn0 "$TAIL" | \
        jq -rc 'try select(.event_type=="alert" and (.alert.severity|tonumber) <= 2)
                 | {ts:.timestamp,src:.src_ip,dst:.dest_ip,sport:.src_port,dport:.dest_port,
                    sig:.alert.signature,severity:.alert.severity} catch empty' \
        | while read -r line; do
            printf "%s\n" "$line" | qrexec-client-vm sys-alert my.alert.Send || true
          done
        EOF
        chmod +x /usr/local/sbin/suricata-to-alert
        cat >/etc/systemd/system/suricata-alert.service <<'EOF'
        [Unit]
        Description=Forward Suricata high-severity alerts to sys-alert
        After=suricata.service
        [Service]
        ExecStart=/usr/local/sbin/suricata-to-alert
        Restart=always
        [Install]
        WantedBy=multi-user.target
        EOF
        systemctl daemon-reload
        systemctl enable --now suricata-alert.service

sys-fw-suricata-rules:
  qvm.run:
    - name: sys-firewall
    - user: root
    - cmd: |
        set -e
        suricata-update enable-source oisf/et/open || true
        suricata-update enable-source oisf/trafficid || true
        suricata-update || true
        systemctl restart suricata || true

# ---------- QUIC block + optional DoH set ---------- #}
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

# Optional DoH IP set (supply IPs in /rw/config/doh-block.list)
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
        SYS_DNS_IP="$(qvm-ls --raw-data --fields NAME,IP | awk -F'|' '$1=="sys-dns"{gsub(/ /,"",$2);print $2}')"
        [ -n "$SYS_DNS_IP" ] || exit 1
        nft list table ip nat >/dev/null 2>&1 || nft add table ip nat
        nft list chain ip nat prerouting >/dev/null 2>&1 || nft add chain ip nat prerouting { type nat hook prerouting priority -100; }
        # DNAT DNS to sys-dns
        nft list chain ip nat prerouting | grep -q "dport 53.*dnat to ${SYS_DNS_IP}" || \
          nft add rule ip nat prerouting udp dport 53 dnat to ${SYS_DNS_IP}
        nft list chain ip nat prerouting | grep -q "dport 53.*dnat to ${SYS_DNS_IP}" || \
          nft add rule ip nat prerouting tcp dport 53 dnat to ${SYS_DNS_IP}
        # DoT block (853) in forward
        nft list table inet qubes >/dev/null 2>&1 || nft add table inet qubes
        nft list chain inet qubes fwd_dot >/dev/null 2>&1 || \
          nft add chain inet qubes fwd_dot { type filter hook forward priority 90; policy accept; }
        nft list chain inet qubes fwd_dot | grep -q 'dport 853.*drop' || \
          { nft add rule inet qubes fwd_dot tcp dport 853 drop; nft add rule inet qubes fwd_dot udp dport 853 drop; }
        # Light shaping
        nft list chain inet qubes fwd_shape >/dev/null 2>&1 || \
          nft add chain inet qubes fwd_shape { type filter hook forward priority 80; policy accept; }
        nft list chain inet qubes fwd_shape | grep -q 'udp dport 53 limit rate over 200/second drop' || \
          nft add rule inet qubes fwd_shape udp dport 53 limit rate over 200/second drop

# ---------- Per-VM egress allow-lists ---------- #}
sys-fw-egress-setup:
  qvm.run:
    - name: sys-firewall
    - user: root
    - cmd: |
        set -e
        mkdir -p /rw/config/egress
        cat >/usr/local/sbin/egress-apply <<'EOF'
        #!/bin/sh
        set -eu
        MAP="/rw/config/egress/ips.map"
        [ -f "$MAP" ] || { echo "No ips.map"; exit 0; }
        nft list table inet qubes >/dev/null 2>&1 || nft add table inet qubes
        nft list chain inet qubes fwd_egress >/dev/null 2>&1 || \
          nft add chain inet qubes fwd_egress { type filter hook forward priority 94; policy accept; }
        while read -r VM IP; do
          [ -z "$VM" ] && continue
          [ -z "$IP" ] && continue
          L="/rw/config/egress/${VM}.list"
          SET="eg_${VM}"
          if ! nft list set inet qubes "$SET" >/dev/null 2>&1; then
            nft add set inet qubes "$SET" { type ipv4_addr; flags interval; }
          else
            nft flush set inet qubes "$SET" || true
          fi
          if [ -f "$L" ]; then
            while read -r CIDR; do
              [ -z "$CIDR" ] && continue
              nft add element inet qubes "$SET" { $CIDR } || true
            done < "$L"
          fi
          RULE="ip saddr $IP ip daddr != @$SET drop"
          nft list chain inet qubes fwd_egress | grep -Fq "$RULE" || nft add rule inet qubes fwd_egress $RULE
        done < "$MAP"
        EOF
        chmod +x /usr/local/sbin/egress-apply

sys-fw-egress-map:
  cmd.run:
    - name: |
        set -e
        qvm-ls --raw-data --fields NAME,IP | awk -F'|' 'NR>1{gsub(/ /,"",$1);gsub(/ /,"",$2); if($2!="") print $1" "$2}' > /var/tmp/ips.map
        cat /var/tmp/ips.map | qvm-run -u root --pass-io sys-firewall 'cat > /rw/config/egress/ips.map'
        qvm-run -u root sys-firewall /usr/local/sbin/egress-apply
