# /srv/salt/qubes/sys-firewall-hardened.sls
# Hardened, idempotent sys-firewall: DNS DNAT -> sys-dns, DoT block, Suricata IDS

# -------------------------
#  Tunables
#  ------------------------- #}
{% set dns_vm         = 'sys-dns' %}        # your DNS proxy VM
{% set tor_gw         = 'sys-vpn-tor' %}    # Whonix-GW / VPN GW (optional; leave as-is if absent)
{% set ipv6_redirect  = False %}            # True to also redirect IPv6 DNS (requires sys-dns v6)
{% set block_quic     = False %}            # True to drop UDP/443 (can break some sites using HTTP/3)

# -------------------------
#  Resolve VM IPs in dom0
#  ------------------------- #}
get-sys-dns-ip:
  cmd.run:
    - name: |
        set -e
        qvm-ls --raw-data --fields NAME,IP | awk -F'|' '$1=="{{ dns_vm }}"{print $2}' | tr -d ' \t' > /var/tmp/sysdns.ip

get-tor-gw-ip:
  cmd.run:
    - name: |
        set -e
        qvm-ls --raw-data --fields NAME,IP | awk -F'|' '$1=="{{ tor_gw }}"{print $2}' | tr -d ' \t' > /var/tmp/sysvpntor.ip || true

# -------------------------
#  Ensure Qubes UpdateVM is sys-firewall (optional but handy)
#  ------------------------- #}
set-updatevm-sys-firewall:
  cmd.run:
    - name: qubes-prefs updatevm sys-firewall
    - unless: qubes-prefs get updatevm | grep -q '^sys-firewall$'

# -------------------------
#  Install base packages needed inside sys-firewall
#  ------------------------- #}
sys-firewall-packages:
  qvm.run:
    - name: sys-firewall
    - user: root
    - cmd: |
        set -e
        apt-get update
        apt-get -y install nftables ethtool ca-certificates curl logrotate || true
        update-ca-certificates || true

# -------------------------
#  Create the persistent firewall user script with embedded IPs
#  ------------------------- #}
install-sys-firewall-user-script:
  cmd.run:
    - name: |
        set -e
        SYSIP="$(cat /var/tmp/sysdns.ip || true)"
        GWIP="$(cat /var/tmp/sysvpntor.ip || true)"
        [ -z "$SYSIP" ] && { echo "{{ dns_vm }} IP not found" >&2; exit 1; }

        qvm-run -u root --pass-io sys-firewall 'cat >/rw/config/qubes-firewall-user-script' <<'EOF'
        #!/bin/sh
        # Qubes firewall user script: runs after core rules.
        # - Redirect all forwarded DNS to sys-dns (v4, optional v6)
        # - Exclude {{ tor_gw }} if present
        # - Block DoT (853) in forward (inet)
        # - Optional: block QUIC (UDP/443)

        set -eu

        SYSIP="{{ "$(cat /var/tmp/sysdns.ip || true)" }}"
        GWIP="{{ "$(cat /var/tmp/sysvpntor.ip || true)" }}"

        # 1) NAT tables (IPv4 and optionally IPv6)
        nft list table ip nat >/dev/null 2>&1 || nft add table ip nat
        nft list chain ip nat prerouting >/dev/null 2>&1 || \
          nft add chain ip nat prerouting { type nat hook prerouting priority -100; policy accept; }

        nft list chain ip nat qubes_dns_preroute >/dev/null 2>&1 || nft add chain ip nat qubes_dns_preroute
        # ensure jump once
        nft list chain ip nat prerouting | grep -q 'jump qubes_dns_preroute' || \
          nft add rule ip nat prerouting jump qubes_dns_preroute
        # rebuild our chain rules idempotently
        nft flush chain ip nat qubes_dns_preroute

        # Optional bypass for {{ tor_gw }} (if IP known)
        if [ -n "${GWIP:-}" ]; then
          nft add rule ip nat qubes_dns_preroute ip saddr $GWIP udp dport 53 accept
          nft add rule ip nat qubes_dns_preroute ip saddr $GWIP tcp dport 53 accept
        fi

        # DNAT all other DNS to {{ dns_vm }} (v4)
        nft add rule ip nat qubes_dns_preroute udp dport 53 dnat to $SYSIP
        nft add rule ip nat qubes_dns_preroute tcp dport 53 dnat to $SYSIP

        {% if ipv6_redirect %}
        # IPv6 NAT (if enabled)
        nft list table ip6 nat >/dev/null 2>&1 || nft add table ip6 nat
        nft list chain ip6 nat prerouting >/dev/null 2>&1 || \
          nft add chain ip6 nat prerouting { type nat hook prerouting priority -100; policy accept; }

        nft list chain ip6 nat qubes_dns_preroute >/dev/null 2>&1 || nft add chain ip6 nat qubes_dns_preroute
        nft list chain ip6 nat prerouting | grep -q 'jump qubes_dns_preroute' || \
          nft add rule ip6 nat prerouting jump qubes_dns_preroute
        nft flush chain ip6 nat qubes_dns_preroute

        # If you have a v6 for {{ tor_gw }}, add accept rules similarly.
        # If {{ dns_vm }} has a v6 (set it here), DNAT to it:
        # SYSIP6="2001:db8::..."; nft add rule ip6 nat qubes_dns_preroute udp dport 53 dnat to $SYSIP6
        # nft add rule ip6 nat qubes_dns_preroute tcp dport 53 dnat to $SYSIP6
        {% endif %}

        # 2) Block DoT (853) in FORWARD using inet table (persists with its own base chain)
        nft list table inet qubes >/dev/null 2>&1 || nft add table inet qubes
        nft list chain inet qubes fwd_dot >/dev/null 2>&1 || \
          nft add chain inet qubes fwd_dot { type filter hook forward priority 90; policy accept; }

        # Ensure these rules exist once
        nft list chain inet qubes fwd_dot | grep -q 'udp dport 853 drop' || \
          nft add rule inet qubes fwd_dot udp dport 853 drop
        nft list chain inet qubes fwd_dot | grep -q 'tcp dport 853 drop' || \
          nft add rule inet qubes fwd_dot tcp dport 853 drop

        {% if block_quic %}
        # (Optional) Block QUIC to reduce stealth DoH surface; may impact some sites.
        nft list chain inet qubes fwd_dot | grep -q 'udp dport 443 drop' || \
          nft add rule inet qubes fwd_dot udp dport 443 drop
        {% endif %}

        exit 0
        EOF

        qvm-run -u root sys-firewall 'chmod +x /rw/config/qubes-firewall-user-script'
        qvm-run -u root sys-firewall '/rw/config/qubes-firewall-user-script'
    - require:
      - cmd: get-sys-dns-ip
      - cmd: get-tor-gw-ip
      - qvm.run: sys-firewall-packages

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
        apt-get -y install suricata jq ca-certificates || true
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
        chmod +x /rw/config/rc.local
        /rw/config/rc.local || true

        systemctl enable suricata
        systemctl restart suricata || systemctl status --no-pager suricata || true
    - require:
      - qvm.run: sys-firewall-packages

# -------------------------
#  Final: run the firewall user script once more (idempotent) to ensure rules are live
#  ------------------------- #}
apply-firewall-user-script:
  qvm.run:
    - name: sys-firewall
    - user: root
    - cmd: /rw/config/qubes-firewall-user-script || true
    - require:
      - cmd: install-sys-firewall-user-script
