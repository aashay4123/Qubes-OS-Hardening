
# -------------------------
#  Suricata IDS on sys-firewall (AF_PACKET)
#  ------------------------- #}
sys-firewall-suricata:
  qvm.run:
    - name: sys-firewall
    - user: root
    - cmd: |
        set -e
        apt-get update
        apt-get -y install suricata jq ca-certificates  nftables || true
        update-ca-certificates || true

        # Minimal AF_PACKET IDS config
        install -d -m 0755 /etc/suricata /var/lib/suricata/rules /var/log/suricata
        cat >/etc/suricata/suricata.yaml <<'EOF'
        %YAML 1.1
        ---
        vars:
          address-groups:
            HOME_NET: "[10.0.0.0/8,172.16.0.0/12,192.168.0.0/16]"
        af-packet:
          - interface: any
            cluster-id: 99
            cluster-type: cluster_flow
            defrag: yes
        outputs:
          - eve-log:
              enabled: yes
              filetype: regular
              filename: /var/log/suricata/eve.json
              community-id: true
              types: [ alert, dns, tls, http, ssh, stats ]
        logging:
          default-log-level: notice
        app-layer:
          protocols:
            tls: { enabled: yes }
            http: { enabled: yes }
            dns: { enabled: yes }
        detection:
          profile: medium
          sgh-mpm-context: auto
        default-rule-path: /var/lib/suricata/rules
        rule-files:
          - suricata.rules
        EOF

        # Rules: ET Open (best-effort); continue if offline
        TMP="$(mktemp -d)"
        if curl -fsSL https://rules.emergingthreats.net/open/suricata-7.0/emerging.rules.tar.gz -o "$TMP/et.tar.gz"; then
          tar -xzf "$TMP/et.tar.gz" -C "$TMP"
          cp -f "$TMP"/rules/*.rules /var/lib/suricata/rules/ 2>/dev/null || true
          cat /var/lib/suricata/rules/*.rules > /var/lib/suricata/rules/suricata.rules
        else
          : > /var/lib/suricata/rules/suricata.rules
        fi
        rm -rf "$TMP"

        # Logrotate
        cat >/etc/logrotate.d/suricata <<'EOF'
        /var/log/suricata/*.log /var/log/suricata/*.json {
          rotate 7
          daily
          compress
          missingok
          notifempty
          copytruncate
        }
        EOF

        # Start after network-online
        install -d -m 0755 /etc/systemd/system/suricata.service.d
        cat >/etc/systemd/system/suricata.service.d/override.conf <<'EOF'
        [Unit]
        After=network-online.target
        Wants=network-online.target
        EOF
        systemctl daemon-reload

        # Reduce packet offload surprises for AF_PACKET at boot
        install -m 0755 /rw/config/rc.local /rw/config/rc.local 2>/dev/null || true
        cat >/rw/config/rc.local <<'EOF'
        #!/bin/sh
        for i in $(ls /sys/class/net | grep -E '^(eth|ens|vif)'); do
          ethtool -K "$i" gro off lro off 2>/dev/null || true
        done
        exit 0
        EOF
        chmod +x /rw/config/rc.local /rw/config/rc.local || true

        systemctl enable suricata
        systemctl restart suricata || systemctl status --no-pager suricata || true

# Forward high-severity alerts to sys-alert
sys-firewall-suricata-alert:
  qvm.run:
    - name: sys-firewall
    - user: root
    - cmd: |
        set -e
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


    - require:
      - qvm.run: sys-firewall-packages


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
