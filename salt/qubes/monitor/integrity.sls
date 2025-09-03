# Daily integrity checks for TemplateVMs and dom0.
# - Creates 'sys-integrity' (offline AppVM) to collect reports from templates.
# - Installs a qrexec handler in templates: qubes.Integrity.Get
# - Minimal dom0 timer runs rpm -Va + hashes and sends result to sys-integrity.
# Qubes 4.2.x

# -------- sys-integrity VM --------
sys-integrity-present:
  cmd.run:
    - name: /bin/sh -c 'qvm-ls --raw-list | grep -qx sys-integrity || qvm-create --class=AppVM --template=debian-12-hard-min --label=orange sys-integrity'

sys-integrity-prefs:
  qvm.prefs:
    - name: sys-integrity
    - autostart: true
    - netvm: ""
    - memory: 300
    - maxmem: 600
    - vcpus: 1
  require:
    - cmd: sys-integrity-present

# -------- qrexec policy (4.2 format) --------
integrity-policy:
  file.managed:
    - name: /etc/qubes/policy.d/31-integrity.policy
    - mode: '0644'
    - contents: |
        # sys-integrity may list/start/stop templates it needs to inspect:
        admin.vm.List      *  sys-integrity  dom0   allow
        admin.vm.Start     *  sys-integrity  dom0   ask
        admin.vm.Shutdown  *  sys-integrity  dom0   allow
        # pull integrity data from any VM via handler:
        qubes.Integrity.Get  *  sys-integrity  @anyvm  allow
        # dom0 will copy its daily report to sys-integrity:
        qubes.Filecopy     *  dom0           sys-integrity  allow

policy-reload-integrity:
  cmd.run:
    - name: /bin/sh -c 'systemctl reload qubes-qrexec-policy-daemon || systemctl restart qubes-qrexec-policy-daemon'
  require:
    - file: integrity-policy

# -------- Handler for Debian templates (debian-12-hard & -hard-min & -work) --------
integrity-handler-debian-12-hard:
  qvm.run:
    - name: debian-12-hard
    - user: root
    - cmd: |
        /bin/sh -c '
        install -d -m 0755 /etc/qubes-rpc
        cat > /etc/qubes-rpc/qubes.Integrity.Get << "EOF"
        #!/bin/sh
        set -eu
        # Emit simple text blocks so the collector can save them.
        echo "time=$(date -Is || date)"
        echo "vm=$(hostname)"

        # 1) Package file verification (debian): debsums summaries (only failures)
        if command -v debsums >/dev/null 2>&1; then
          echo "BEGIN debsums -s"
          debsums -s || true
          echo "END debsums -s"
        else
          echo "INFO: debsums not installed"
        fi

        # 2) Hash sensitive configs (lightweight)
        echo "BEGIN sha256 /etc /etc/qubes"
        find /etc /etc/qubes -xdev -type f 2>/dev/null | LC_ALL=C sort | xargs -r sha256sum
        echo "END sha256 /etc /etc/qubes"
        EOF
        chmod 0755 /etc/qubes-rpc/qubes.Integrity.Get
        '

integrity-handler-debian-12-hard-min:
  qvm.run:
    - name: debian-12-hard-min
    - user: root
    - cmd: /bin/sh -c 'install -d -m 0755 /etc/qubes-rpc; cp -f /etc/qubes-rpc/qubes.Integrity.Get /etc/qubes-rpc/qubes.Integrity.Get 2>/dev/null || exit 0'
  require:
    - qvm.run: integrity-handler-debian-12-hard

integrity-handler-debian-12-work:
  qvm.run:
    - name: debian-12-work
    - user: root
    - cmd: /bin/sh -c 'install -d -m 0755 /etc/qubes-rpc; cp -f /etc/qubes-rpc/qubes.Integrity.Get /etc/qubes-rpc/qubes.Integrity.Get 2>/dev/null || exit 0'
  require:
    - qvm.run: integrity-handler-debian-12-hard

# -------- Handler for Fedora templates (e.g., fedora-41-vpn-min) --------
integrity-handler-fedora-41-vpn-min:
  qvm.run:
    - name: fedora-41-vpn-min
    - user: root
    - cmd: |
        /bin/sh -c '
        install -d -m 0755 /etc/qubes-rpc
        cat > /etc/qubes-rpc/qubes.Integrity.Get << "EOF"
        #!/bin/sh
        set -eu
        echo "time=$(date -Is || date)"
        echo "vm=$(hostname)"

        # 1) Fedora package verify (rpm -Va)
        echo "BEGIN rpm -Va"
        rpm -Va || true
        echo "END rpm -Va"

        # 2) Hash sensitive configs
        echo "BEGIN sha256 /etc /etc/qubes"
        find /etc /etc/qubes -xdev -type f 2>/dev/null | LC_ALL=C sort | xargs -r sha256sum
        echo "END sha256 /etc /etc/qubes"
        EOF
        chmod 0755 /etc/qubes-rpc/qubes.Integrity.Get
        '

# -------- Collector & timers inside sys-integrity --------
sys-integrity-install:
  qvm.run:
    - name: sys-integrity
    - user: root
    - cmd: |
        /bin/sh -c '
        install -d -m 0755 /usr/local/bin /etc/systemd/system
        cat > /usr/local/bin/integrity-collect.sh << "EOF"
        #!/bin/bash
        set -euo pipefail
        BASE="${HOME}/Integrity"; DAY="$(date -I)"; OUT="${BASE}/${DAY}"
        mkdir -p "${OUT}"
        # get template list via Admin API
        mapfile -t L < <(qrexec-client-vm dom0 admin.vm.List 2>/dev/null || true)
        TEMPLATES=()
        for ln in "${L[@]}"; do
          vm="${ln%% *}"
          case "$ln" in *"class=TemplateVM"*) TEMPLATES+=("$vm");; esac
        done
        for vm in "${TEMPLATES[@]}"; do
          # Autostart allowed by policy (ask once)
          qrexec-client-vm dom0 "admin.vm.Start" <<< "$vm" >/dev/null 2>&1 || true
          if OUTTXT="$(qrexec-client-vm "$vm" qubes.Integrity.Get 2>/dev/null)"; then
            echo "$OUTTXT" > "${OUT}/${vm}.txt"
          else
            echo "time=$(date -Is)" > "${OUT}/${vm}.txt"; echo "vm=${vm}" >> "${OUT}/${vm}.txt"; echo "ERROR: no output" >> "${OUT}/${vm}.txt"
          fi
          qrexec-client-vm dom0 "admin.vm.Shutdown" <<< "$vm" >/dev/null 2>&1 || true
        done
        EOF
        chmod 0755 /usr/local/bin/integrity-collect.sh

        cat > /etc/systemd/system/integrity-collect.service << "EOF"
        [Unit]
        Description=Collect integrity reports from TemplateVMs
        After=qubes-qrexec-agent.service
        [Service]
        Type=oneshot
        ExecStart=/usr/local/bin/integrity-collect.sh
        EOF

        cat > /etc/systemd/system/integrity-collect.timer << "EOF"
        [Unit]
        Description=Daily TemplateVM integrity collection (03:10)
        [Timer]
        OnCalendar=*-*-* 03:10:00
        Persistent=true
        Unit=integrity-collect.service
        [Install]
        WantedBy=timers.target
        EOF

        systemctl enable --now integrity-collect.timer
        '
  require:
    - qvm.prefs: sys-integrity-prefs
    - cmd: policy-reload-integrity

# -------- dom0 daily: rpm -Va + hashes; send to sys-integrity --------
dom0-integrity-script:
  file.managed:
    - name: /usr/local/sbin/dom0-integrity-report
    - mode: '0755'
    - contents: |
        #!/bin/sh
        set -eu
        DAY="$(date -I)"; TMP="/var/tmp/dom0-int-$DAY"
        mkdir -p "$TMP"
        # 1) rpm -Va (verify files)
        rpm -Va > "$TMP/rpm-verify.txt" 2>&1 || true
        # 2) hashes of /etc and /etc/qubes and /boot
        (find /etc /etc/qubes -xdev -type f 2>/dev/null | LC_ALL=C sort | xargs -r sha256sum) > "$TMP/sha256-etc.txt"
        (find /boot -xdev -type f 2>/dev/null | LC_ALL=C sort | xargs -r sha256sum) > "$TMP/sha256-boot.txt"
        tar -C "$TMP" -czf "/var/tmp/dom0-integrity-$DAY.tgz" .
        # copy to sys-integrity
        cat "/var/tmp/dom0-integrity-$DAY.tgz" | qvm-run --pass-io sys-integrity "cat > ~/Integrity/$DAY/dom0.tgz"

dom0-integrity-timer:
  file.managed:
    - name: /etc/systemd/system/dom0-integrity.timer
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Daily dom0 integrity to sys-integrity (03:05)
        [Timer]
        OnCalendar=*-*-* 03:05:00
        Persistent=true
        Unit=dom0-integrity.service
        [Install]
        WantedBy=timers.target

dom0-integrity-service:
  file.managed:
    - name: /etc/systemd/system/dom0-integrity.service
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Generate dom0 integrity report
        [Service]
        Type=oneshot
        ExecStart=/usr/local/sbin/dom0-integrity-report

dom0-integrity-enable:
  cmd.run:
    - name: /bin/sh -c 'systemctl daemon-reload; systemctl enable --now dom0-integrity.timer'
  require:
    - file: dom0-integrity-timer
    - file: dom0-integrity-service
    - file: dom0-integrity-script
