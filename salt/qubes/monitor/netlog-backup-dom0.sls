# dom0: create a daily systemd timer to pull pcaps from sys-dns/sys-vpn into secrets-vault

# --- ensure secrets-vault exists
check-secrets-vault:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx secrets-vault'"

# --- install script
install-netlogs-backup-script:
  cmd.run:
    - name: |
        /bin/sh -c '
        install -d -m 0755 /usr/local/sbin
        cat > /usr/local/sbin/qubes-netlogs-backup << "EOF"
        #!/bin/sh
        set -eu
        VAULT="secrets-vault"
        SRCS="sys-dns sys-vpn"
        DATE="$(date -I)"
        for VM in $SRCS; do
          # ensure dir exists in vault
          qvm-run --pass-io "$VAULT" "mkdir -p -m 0750 ~/NetLogs" >/dev/null
          # stream tar.gz from source to vault
          qvm-run --pass-io "$VM" "tar -C /var/log -cz netpcap" \
            | qvm-run --pass-io "$VAULT" "cat > ~/NetLogs/${VM}-${DATE}.tgz"
          # prune source logs older than 2 days
          qvm-run "$VM" "/bin/sh -c 'find /var/log/netpcap -type f -mtime +2 -delete'"
        done
        EOF
        chmod 0755 /usr/local/sbin/qubes-netlogs-backup
        '

# --- systemd unit + timer
install-netlogs-backup-unit:
  cmd.run:
    - name: |
        /bin/sh -c '
        cat > /etc/systemd/system/qubes-netlogs-backup.service << "EOF"
        [Unit]
        Description=Pull NetVM pcaps into secrets-vault

        [Service]
        Type=oneshot
        ExecStart=/usr/local/sbin/qubes-netlogs-backup
        EOF

        cat > /etc/systemd/system/qubes-netlogs-backup.timer << "EOF"
        [Unit]
        Description=Daily NetVM pcap backup

        [Timer]
        OnCalendar=*-*-* 03:30:00
        Persistent=true

        [Install]
        WantedBy=timers.target
        EOF

        systemctl daemon-reload
        systemctl enable --now qubes-netlogs-backup.timer
        '
    - require:
        - cmd: install-netlogs-backup-script
        - cmd: check-secrets-vault

# --- summary
backup-summary:
  cmd.run:
    - name: |
        /bin/sh -c '
        systemctl list-timers qubes-netlogs-backup.timer --no-pager
        echo "Vault listing:"
        qvm-run -p secrets-vault "ls -ld ~/NetLogs || true"
        '
    - require:
        - cmd: install-netlogs-backup-unit
