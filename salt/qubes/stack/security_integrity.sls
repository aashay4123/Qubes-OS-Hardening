# ============================
# SECURITY & INTEGRITY LAYER
# - sys-alert VM + qrexec
# - Template full FS hashing (baseline -> vault-secrets, verify daily)
# - Policy pack hashing (baseline -> vault-secrets, verify daily)
# - TPM PCR (0/2/5/7) baseline + daily verify (alerts on mismatch)
# - Conservative Xen cmdline mitigations (SMT off, xpti/spec-ctrl)
# ============================

# ---------- ALERT SINK ---------- #}
create-sys-alert:
  cmd.run:
    - name: |
        set -e
        if ! qvm-ls --raw-list | grep -qx sys-alert; then
          qvm-create --class AppVM --template deb_harden_min --label red sys-alert
          qvm-prefs sys-alert netvm none
        fi

sys-alert-qrexec:
  qvm.run:
    - name: sys-alert
    - user: root
    - cmd: |
        set -e
        apt-get update -y || true
        apt-get install -y --no-install-recommends libnotify-bin jq || true
        install -d -m 755 /etc/qubes-rpc
        cat >/etc/qubes-rpc/my.alert.Send <<'EOF'
        #!/bin/sh
        set -eu
        LOG=/var/log/sys-alert.log
        mkdir -p "$(dirname "$LOG")"
        TS="$(date -Is)"
        MSG="$(cat - || true)"
        echo "$TS $QREXEC_SERVICE_FROM_DOMAIN $MSG" >> "$LOG"
        command -v notify-send >/dev/null && notify-send "Qubes Alert: $QREXEC_SERVICE_FROM_DOMAIN" "$MSG" || true
        EOF
        chmod 0755 /etc/qubes-rpc/my.alert.Send

/etc/qubes/policy.d/20-alert.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        my.alert.Send  dom0         sys-alert   allow
        my.alert.Send  sys-firewall sys-alert   allow
        my.alert.Send  sys-dns      sys-alert   allow
        my.alert.Send +allow-all-names          +allow-all-names          deny  notify=yes

alert-cli:
  file.managed:
    - name: /usr/local/bin/alert
    - mode: '0755'
    - contents: |
        #!/bin/bash
        set -euo pipefail
        MSG="${*:-no message}"
        printf "%s" "$MSG" | qrexec-client-vm sys-alert my.alert.Send

# ---------- TEMPLATE HASHING ---------- #}
tmpl-hash-tools:
  file.managed:
    - name: /usr/local/sbin/qubes-template-hash.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      T="${1:-}"; [ -n "$T" ] || { echo "usage: $0 <template>"; exit 2; }
      qvm-run -q -u root --pass-io "$T" \
        "tar --posix --numeric-owner --one-file-system \
             --sort=name --mtime=@0 \
             -C / -cpf - \
             --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run \
             --exclude=/tmp --exclude=/var/tmp --exclude=/rw --exclude=/home/user/.cache ." \
      | sha256sum | awk '{print $1}'

tmpl-hash-verify:
  file.managed:
    - name: /usr/local/sbin/qubes-template-hash-verify.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      LIST="deb_harden deb_harden_min deb_dev deb_work deb_personal fedora-42-vpn whonix-gateway-17 whonix-workstation-17"
      FAIL=0
      for t in $LIST; do
        qvm-ls --raw-list | grep -qx "$t" || continue
        CUR=$(/usr/local/sbin/qubes-template-hash.sh "$t")
        BASE="$(qvm-run -q --pass-io vault-secrets "cat /home/user/.template-hashes/${t}.sha256" 2>/dev/null || true)"
        if [ -z "$BASE" ]; then
          /usr/local/bin/alert "TEMPLATE HASH: missing baseline for $t"
          FAIL=1; continue
        fi
        if [ "$CUR" != "$BASE" ]; then
          /usr/local/bin/alert "TEMPLATE HASH MISMATCH: $t cur=$CUR base=$BASE"
          FAIL=1
        fi
      done
      exit $FAIL

tmpl-hash-baseline:
  cmd.run:
    - name: |
        set -e
        LIST="deb_harden deb_harden_min deb_dev deb_work deb_personal fedora-42-vpn whonix-gateway-17 whonix-workstation-17"
        qvm-run -q --pass-io vault-secrets 'mkdir -p /home/user/.template-hashes'
        mkdir -p /var/lib/qubes/template-hashes
        for t in $LIST; do
          qvm-ls --raw-list | grep -qx "$t" || continue
          OUT="/var/lib/qubes/template-hashes/${t}.sha256"
          if [ ! -s "$OUT" ]; then
            H=$(/usr/local/sbin/qubes-template-hash.sh "$t")
            echo "$H" > "$OUT"
            printf "%s\n" "$H" | qvm-run -q --pass-io vault-secrets "cat > /home/user/.template-hashes/${t}.sha256"
          fi
        done

tmpl-hash-timer:
  file.managed:
    - name: /etc/systemd/system/template-hash-verify.service
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Verify template hashes vs baseline in vault
        [Service]
        Type=oneshot
        ExecStart=/usr/local/sbin/qubes-template-hash-verify.sh

  file.managed:
    - name: /etc/systemd/system/template-hash-verify.timer
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Daily template hash verify
        [Timer]
        OnCalendar=daily
        Persistent=true
        [Install]
        WantedBy=timers.target

tmpl-hash-enable:
  cmd.run:
    - name: |
        systemctl daemon-reload
        systemctl enable --now template-hash-verify.timer

# ---------- POLICY HASHING ---------- #}
policy-hash-tools:
  file.managed:
    - name: /usr/local/sbin/qubes-policy-hash.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      find /etc/qubes/policy.d -maxdepth 1 -type f -name "*.policy" -print0 \
      | xargs -0 cat | sed 's/[ \t]\+/ /g' | sed 's/#.*$//' | grep -v '^[[:space:]]*$' \
      | sha256sum | awk '{print $1}'

policy-hash-verify:
  file.managed:
    - name: /usr/local/sbin/qubes-policy-verify.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      CUR="$(/usr/local/sbin/qubes-policy-hash.sh)"
      BASE="$(qvm-run -q --pass-io vault-secrets "cat /home/user/.policy-hashes/qubes-policy.sha256" 2>/dev/null || true)"
      if [ -z "$BASE" ]; then
        /usr/local/bin/alert "POLICY HASH: no baseline in vault"
        exit 1
      fi
      if [ "$CUR" != "$BASE" ]; then
        /usr/local/bin/alert "POLICY HASH MISMATCH cur=$CUR base=$BASE"
        exit 1
      fi

policy-hash-baseline:
  cmd.run:
    - name: |
        set -e
        H="$(/usr/local/sbin/qubes-policy-hash.sh)"
        mkdir -p /var/lib/qubes
        printf "%s\n" "$H" > /var/lib/qubes/policy.sha256
        qvm-run -q --pass-io vault-secrets 'mkdir -p /home/user/.policy-hashes'
        printf "%s\n" "$H" | qvm-run -q --pass-io vault-secrets 'cat > /home/user/.policy-hashes/qubes-policy.sha256'

policy-hash-timer:
  file.managed:
    - name: /etc/systemd/system/policy-verify.service
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Verify /etc/qubes/policy.d against baseline
        [Service]
        Type=oneshot
        ExecStart=/usr/local/sbin/qubes-policy-verify.sh

  file.managed:
    - name: /etc/systemd/system/policy-verify.timer
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Daily policy verify
        [Timer]
        OnCalendar=daily
        Persistent=true
        [Install]
        WantedBy=timers.target

policy-hash-enable:
  cmd.run:
    - name: |
        systemctl daemon-reload
        systemctl enable --now policy-verify.timer

# ---------- TPM PCR ATTESTATION ---------- #}
tpm2-tools:
  cmd.run:
    - name: sudo qubes-dom0-update -y tpm2-tools || true

tpm-scripts:
  file.managed:
    - name: /usr/local/sbin/qubes-tpm-pcr-baseline.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      OUT="${1:-/tmp/pcr-baseline.json}"
      tpm2_pcrread sha256:0,2,5,7 -Q > /tmp/pcr.txt
      # Simple JSON summarizer
      printf '{ "sha256": {' > "$OUT"
      SEP=""
      awk '/^sha256/ { split($0,a,/[(): ]+/); idx=a[2]; val=a[4]; printf "%s\"%s\":\"%s\"", "'"$SEP"'", idx, val; SEP="," }' /tmp/pcr.txt >> "$OUT"
      printf '}, "meta": { "date": "%s" } }\n' "$(date -Is)" >> "$OUT"
      cat "$OUT"

  file.managed:
    - name: /usr/local/sbin/qubes-tpm-pcr-verify.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      TMP="/tmp/pcr-cur.json"
      /usr/local/sbin/qubes-tpm-pcr-baseline.sh "$TMP" >/dev/null
      BASE="$(qvm-run -q --pass-io vault-secrets 'cat /home/user/.attest/pcr-baseline.json' 2>/dev/null || true)"
      if [ -z "$BASE" ]; then
        /usr/local/bin/alert "TPM VERIFY: no baseline in vault"
        exit 1
      fi
      if ! diff -u <(echo "$BASE" | tr -d ' \t\n\r') <(tr -d ' \t\n\r' < "$TMP") >/dev/null; then
        /usr/local/bin/alert "TPM PCR MISMATCH"
        exit 1
      fi

tpm-baseline:
  cmd.run:
    - name: |
        set -e
        qvm-run -q --pass-io vault-secrets 'mkdir -p /home/user/.attest'
        if ! qvm-run -q --pass-io vault-secrets 'test -s /home/user/.attest/pcr-baseline.json'; then
          /usr/local/sbin/qubes-tpm-pcr-baseline.sh /tmp/pcr.json >/dev/null
          cat /tmp/pcr.json | qvm-run -q --pass-io vault-secrets 'cat > /home/user/.attest/pcr-baseline.json'
        fi

tpm-verify-timer:
  file.managed:
    - name: /etc/systemd/system/tpm-attest-verify.service
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Verify TPM PCRs vs vault baseline
        [Service]
        Type=oneshot
        ExecStart=/usr/local/sbin/qubes-tpm-pcr-verify.sh

  file.managed:
    - name: /etc/systemd/system/tpm-attest-verify.timer
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Daily TPM verify
        [Timer]
        OnCalendar=daily
        Persistent=true
        [Install]
        WantedBy=timers.target

tpm-verify-enable:
  cmd.run:
    - name: |
        systemctl daemon-reload
        systemctl enable --now tpm-attest-verify.timer

# ---------- XEN MITIGATIONS (CONSERVATIVE) ---------- #}
xen-mitigations:
  cmd.run:
    - name: |
        set -e
        CFG=/etc/default/grub
        grep -q 'GRUB_CMDLINE_XEN_DEFAULT' "$CFG" || exit 0
        sed -i 's/^GRUB_CMDLINE_XEN_DEFAULT=.*/GRUB_CMDLINE_XEN_DEFAULT="dom0_mem=max:2048M dom0_max_vcpus=2 smt=off xpti=on spec-ctrl=on mitigations=auto,nosmt"/' "$CFG"
        grub2-mkconfig -o /boot/grub2/grub.cfg || grub2-mkconfig -o /boot/efi/EFI/qubes/grub.cfg || true
