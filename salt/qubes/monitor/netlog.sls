
# Full network logging bundle:
# - sys-dns + sys-vpn: rotating pcaps (tcpdump)
# - sys-firewall + sys-net: nft per-packet logging (kernel journal) with clear prefixes
# - dom0: nightly backup of pcaps/logs into secrets-vault

# ---------- Presence checks ----------
check-sys-dns:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx sys-dns'"

check-sys-vpn:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx sys-vpn'"

check-sys-fw:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx sys-firewall'"

check-sys-net:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx sys-net'"

check-secrets-vault:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx secrets-vault'"

# ---------- sys-dns (Debian): tcpdump + rotation ----------
sys-dns-netlog-install:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: "/bin/sh -c 'apt-get -y update && apt-get -y install tcpdump && install -d -m 0750 /var/log/netpcap'"
    - require:
      - cmd: check-sys-dns

sys-dns-netpcap-service:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: |
        /bin/sh -c '
        cat > /etc/systemd/system/netpcap.service << "EOF"
        [Unit]
        Description=Rotating packet capture (sys-dns)
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        ExecStart=/usr/sbin/tcpdump -i any -s 96 -nn -tttt -w /var/log/netpcap/pcap-%Y%m%d%H%M%S.pcap -G 3600 -W 48
        Restart=always
        RestartSec=5s
        Nice=10
        IOSchedulingClass=best-effort
        IOSchedulingPriority=7

        [Install]
        WantedBy=multi-user.target
        EOF
        systemctl daemon-reload
        systemctl enable --now netpcap.service
        '
    - require:
      - qvm: sys-dns-netlog-install

# ---------- sys-vpn (Fedora): tcpdump + rotation ----------
sys-vpn-netlog-install:
  qvm.run:
    - name: sys-vpn
    - user: root
    - cmd: "/bin/sh -c 'dnf -y install tcpdump && install -d -m 0750 /var/log/netpcap'"
    - require:
      - cmd: check-sys-vpn

sys-vpn-netpcap-service:
  qvm.run:
    - name: sys-vpn
    - user: root
    - cmd: |
        /bin/sh -c '
        cat > /etc/systemd/system/netpcap.service << "EOF"
        [Unit]
        Description=Rotating packet capture (sys-vpn)
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        ExecStart=/usr/sbin/tcpdump -i any -s 96 -nn -tttt -w /var/log/netpcap/pcap-%Y%m%d%H%M%S.pcap -G 3600 -W 48
        Restart=always
        RestartSec=5s
        Nice=10
        IOSchedulingClass=best-effort
        IOSchedulingPriority=7

        [Install]
        WantedBy=multi-user.target
        EOF
        systemctl daemon-reload
        systemctl enable --now netpcap.service
        '
    - require:
      - qvm: sys-vpn-netlog-install

# ---------- sys-firewall: nft per-packet logging ----------
sys-fw-nft-logger:
  qvm.run:
    - name: sys-firewall
    - user: root
    - cmd: |
        /bin/sh -c '
        install -d -m 0755 /rw/config
        cat > /rw/config/qubes-firewall-user-script << "EOF"
        #!/bin/sh
        # Add logging rules into Qubes custom chains (filter) with stable prefixes.
        nft list table ip qubes >/dev/null 2>&1 || exit 0

        have_rule() { nft list chain ip qubes "$1" 2>/dev/null | grep -Fq -- "$2"; }

        # Log NEW forwards (connection starts) from client VMs
        have_rule custom-forward 'ct state new log prefix "SYSFW:new " counter' || \
          nft add rule ip qubes custom-forward ct state new log prefix "SYSFW:new " counter

        # Log ALL DNS (can be noisy; useful for auditing)
        have_rule custom-forward 'udp dport 53 log prefix "SYSFW:dns " counter' || \
          nft add rule ip qubes custom-forward udp dport 53 log prefix "SYSFW:dns " counter

        # Optionally log TCP DNS too (rarely used)
        have_rule custom-forward 'tcp dport 53 log prefix "SYSFW:dns " counter' || \
          nft add rule ip qubes custom-forward tcp dport 53 log prefix "SYSFW:dns " counter
        EOF
        chmod +x /rw/config/qubes-firewall-user-script
        systemctl restart qubes-firewall
        '
    - require:
      - cmd: check-sys-fw

# ---------- sys-net: nft per-packet logging ----------
sys-net-nft-logger:
  qvm.run:
    - name: sys-net
    - user: root
    - cmd: |
        /bin/sh -c '
        install -d -m 0755 /rw/config
        cat > /rw/config/qubes-firewall-user-script << "EOF"
        #!/bin/sh
        nft list table ip qubes >/dev/null 2>&1 || exit 0

        have_rule() { nft list chain ip qubes "$1" 2>/dev/null | grep -Fq -- "$2"; }

        # Log NEW egress from this NetVM (post-NAT uplink)
        have_rule custom-output 'ct state new log prefix "SYSNET:new " counter' || \
          nft add rule ip qubes custom-output ct state new log prefix "SYSNET:new " counter

        # Log DNS passing this node
        have_rule custom-output 'udp dport 53 log prefix "SYSNET:dns " counter' || \
          nft add rule ip qubes custom-output udp dport 53 log prefix "SYSNET:dns " counter

        have_rule custom-output 'tcp dport 53 log prefix "SYSNET:dns " counter' || \
          nft add rule ip qubes custom-output tcp dport 53 log prefix "SYSNET:dns " counter
        EOF
        chmod +x /rw/config/qubes-firewall-user-script
        systemctl restart qubes-firewall
        '
    - require:
      - cmd: check-sys-net

# ---------- dom0: nightly backup into secrets-vault ----------
install-backup-script:
  cmd.run:
    - name: |
        /bin/sh -c '
        install -d -m 0755 /usr/local/sbin
        cat > /usr/local/sbin/qubes-netlogs-backup << "EOF"
        #!/bin/sh
        set -eu

        VAULT="secrets-vault"
        DATE="$(date -I)"         # YYYY-MM-DD
        HOURAGO="$(date -Iseconds -d 'yesterday')"

        # Ensure vault target dir exists
        qvm-run --pass-io "$VAULT" "mkdir -p -m 0750 ~/NetLogs" >/dev/null

        # 1) pcaps from sys-dns / sys-vpn (tar.gz streamed)
        for VM in sys-dns sys-vpn; do
          if qvm-ls --raw-list | grep -qx "$VM"; then
            target="~/NetLogs/${VM}/${DATE}"
            qvm-run --pass-io "$VAULT" "mkdir -p -m 0750 ${target}" >/dev/null
            if qvm-run --pass-io "$VM" "test -d /var/log/netpcap && tar -C /var/log -cz netpcap" \
              | qvm-run --pass-io "$VAULT" "cat > ${target}/pcaps-${DATE}.tgz" ; then
              # prune older than 2 days on source
              qvm-run "$VM" "/bin/sh -c 'find /var/log/netpcap -type f -mtime +2 -delete'"
            fi
          fi
        done

        # 2) nft logs from sys-firewall / sys-net (journal slice to text.gz)
        #    We grep kernel transport for our prefixes to keep files compact.
        #    Adjust --since if you prefer midnight rollups.
        if qvm-ls --raw-list | grep -qx sys-firewall; then
          target="~/NetLogs/sys-firewall/${DATE}"
          qvm-run --pass-io "$VAULT" "mkdir -p -m 0750 ${target}" >/dev/null
          qvm-run --pass-io sys-firewall "journalctl -k --since 'yesterday' -o short-iso | grep 'SYSFW:' | gzip -c" \
            | qvm-run --pass-io "$VAULT" "cat > ${target}/nft-${DATE}.log.gz"
        fi

        if qvm-ls --raw-list | grep -qx sys-net; then
          target="~/NetLogs/sys-net/${DATE}"
          qvm-run --pass-io "$VAULT" "mkdir -p -m 0750 ${target}" >/dev/null
          qvm-run --pass-io sys-net "journalctl -k --since 'yesterday' -o short-iso | grep 'SYSNET:' | gzip -c" \
            | qvm-run --pass-io "$VAULT" "cat > ${target}/nft-${DATE}.log.gz"
        fi

        exit 0
        EOF
        chmod 0755 /usr/local/sbin/qubes-netlogs-backup
        '
    - require:
      - cmd: check-secrets-vault

install-backup-timer:
  cmd.run:
    - name: |
        /bin/sh -c '
        cat > /etc/systemd/system/qubes-netlogs-backup.service << "EOF"
        [Unit]
        Description=Daily pull of NetVM pcaps and nft logs into secrets-vault

        [Service]
        Type=oneshot
        ExecStart=/usr/local/sbin/qubes-netlogs-backup
        EOF

        cat > /etc/systemd/system/qubes-netlogs-backup.timer << "EOF"
        [Unit]
        Description=Nightly NetVM logs backup

        [Timer]
        OnCalendar=*-*-* 03:35:00
        Persistent=true

        [Install]
        WantedBy=timers.target
        EOF

        systemctl daemon-reload
        systemctl enable --now qubes-netlogs-backup.timer
        '
    - require:
      - cmd: install-backup-script
      - cmd: check-secrets-vault

# ---------- Summary ----------
full-netlog-summary:
  cmd.run:
    - name: |
        /bin/sh -c '
        printf "\n=== netlog bundle ===\n"
        printf "sys-dns  netpcap: %s\n" "$(qvm-run -p sys-dns  'systemctl is-active netpcap.service' 2>/dev/null || echo N/A)"
        printf "sys-vpn  netpcap: %s\n" "$(qvm-run -p sys-vpn  'systemctl is-active netpcap.service' 2>/dev/null || echo N/A)"
        printf "sys-fw   nftlog : %s\n" "$(qvm-run -p sys-firewall 'test -f /rw/config/qubes-firewall-user-script && echo enabled || echo missing' 2>/dev/null || echo N/A)"
        printf "sys-net  nftlog : %s\n" "$(qvm-run -p sys-net      'test -f /rw/config/qubes-firewall-user-script && echo enabled || echo missing' 2>/dev/null || echo N/A)"
        systemctl list-timers qubes-netlogs-backup.timer --no-pager
        '
    - require:
      - qvm: sys-dns-netpcap-service
      - qvm: sys-vpn-netpcap-service
      - qvm: sys-fw-nft-logger
      - qvm: sys-net-nft-logger
      - cmd: install-backup-timer
