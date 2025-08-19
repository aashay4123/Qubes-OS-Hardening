# ============================
# INTEGRITY & ALERTING STACK
# - sys-alert VM + qrexec service + dom0 alert shim
# - Signed-only Salt deployment (verify -> stage -> atomic deploy)
# - Baselines (vault-secrets) + daily verify:
#     * /srv/salt tree (config integrity)
#     * Template full-filesystem hashes
#     * /etc/qubes/policy.d policy pack hash
#     * dom0 boot & Xen binaries hash (/boot, /usr/lib/xen)
# - TPM PCR(0,2,5,7) baseline + daily verify (if TPM available)
# - Conservative Xen mitigations (SMT off etc.)
# ============================

{% set PUBKEY   = '/etc/qubes/salt-pubkey.pem' %}
{% set PKG     = '/var/tmp/salt.tar.gz' %}
{% set SIG     = '/var/tmp/salt.tar.gz.sig' %}
{% set STAGE   = '/var/tmp/salt.staged' %}
{% set SRV     = '/srv/salt' %}
{% set BACKUPS = '/var/backups/srv-salt' %}
{% set HASHDIR = '/var/lib/qubes/salt-hashes' %}
{% set V_HASHD = '/home/user/.config-hashes' %}

# ---- sys-alert sink (networkless) ----
sys-alert-create:
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
        my.alert.Send  *            *           deny  notify=yes

alert-shim:
  file.managed:
    - name: /usr/local/bin/alert
    - mode: '0755'
    - contents: |
        #!/bin/bash
        set -euo pipefail
        MSG="${*:-no message}"
        printf "%s" "$MSG" | qrexec-client-vm sys-alert my.alert.Send

# ---- dirs for backups & hashes ----
salt-gate-dirs:
  file.directory:
    - names:
      - {{ BACKUPS }}
      - {{ HASHDIR }}
    - mode: '0750'

# ---- signed Salt: verify signature & tar sanity ----
salt-verify-script:
  file.managed:
    - name: /usr/local/sbin/salt-verify-signature.sh
    - mode: '0755'
    - contents: |
        #!/bin/bash
        set -euo pipefail
        PUB="{{ PUBKEY }}"; PKG="{{ PKG }}"; SIG="{{ SIG }}"
        [ -f "$PUB" ] || { echo "Missing $PUB"; exit 1; }
        [ -f "$PKG" ] || { echo "Missing $PKG"; exit 1; }
        [ -f "$SIG" ] || { echo "Missing $SIG"; exit 1; }
        openssl dgst -sha256 -verify "$PUB" -signature "$SIG" "$PKG" >/dev/null
        # Reject absolute paths, .., or entries outside srv/salt/
        tar -tzf "$PKG" | awk '
          /^\// {print "Absolute path: "$0; exit 2}
          /\.\./ {print "Escape path: "$0; exit 2}
          !/^srv\/salt\// {print "Outside srv/salt/: "$0; exit 2}
        ' >/dev/null

# ---- deploy staged -> /srv/salt atomically (backup old) ----
salt-deploy-script:
  file.managed:
    - name: /usr/local/sbin/salt-deploy-staged.sh
    - mode: '0755'
    - contents: |
        #!/bin/bash
        set -euo pipefail
        PKG="{{ PKG }}"; STAGE="{{ STAGE }}"; SRV="{{ SRV }}"
        BACK="{{ BACKUPS }}/srv-salt-$(date +%Y%m%d-%H%M%S).tar.zst"
        [ -f "$PKG" ] || { echo "No bundle $PKG"; exit 1; }
        rm -rf "$STAGE"; mkdir -p "$STAGE"
        tar --no-same-owner --no-same-permissions -xzf "$PKG" -C "$STAGE"
        find "$STAGE" -type d -exec chmod 0755 {} +; find "$STAGE" -type f -exec chmod 0644 {} +
        find "$STAGE" -type f \( -path '*/bin/*' -o -path '*/sbin/*' \) -exec chmod 0755 {} + || true
        if [ -d "$SRV" ]; then tar -C / -I 'zstd -T0 -19' -cf "$BACK" srv/salt || true; fi
        rsync -a --delete "$STAGE/srv/salt/" "$SRV/"
        rm -rf "$STAGE"
        echo "DEPLOYED"

# ---- /srv/salt tree hashing (baseline in vault, daily verify) ----
salt-tree-hash:
  file.managed:
    - name: /usr/local/sbin/salt-tree-hash.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      tar --posix --numeric-owner --sort=name --mtime=@0 -C / -cpf - srv/salt | sha256sum | awk '{print $1}'

salt-tree-baseline:
  cmd.run:
    - name: |
        set -e
        H="$((/usr/local/sbin/salt-tree-hash.sh) 2>/dev/null || echo '')"
        [ -n "$H" ] || exit 0
        qvm-run -q --pass-io vault-secrets 'mkdir -p {{ V_HASHD }}'
        if ! qvm-run -q --pass-io vault-secrets 'test -s {{ V_HASHD }}/salt-tree.sha256'; then
          printf "%s\n" "$H" | qvm-run -q --pass-io vault-secrets 'cat > {{ V_HASHD }}/salt-tree.sha256'
        fi

salt-tree-verify:
  file.managed:
    - name: /usr/local/sbin/salt-tree-verify.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      CUR="$(/usr/local/sbin/salt-tree-hash.sh)"
      BASE="$(qvm-run -q --pass-io vault-secrets 'cat {{ V_HASHD }}/salt-tree.sha256' 2>/dev/null || true)"
      [ -n "$BASE" ] || { alert "SALT VERIFY: missing baseline"; exit 1; }
      [ "$CUR" = "$BASE" ] || { alert "SALT TREE HASH MISMATCH cur=$CUR base=$BASE"; exit 1; }

salt-tree-verify-timer:
  file.managed:
    - name: /etc/systemd/system/salt-tree-verify.service
    - mode: '0644'
    - contents: |
        [Unit] Description=Verify /srv/salt vs vault baseline
        [Service] Type=oneshot ExecStart=/usr/local/sbin/salt-tree-verify.sh
  file.managed:
    - name: /etc/systemd/system/salt-tree-verify.timer
    - mode: '0644'
    - contents: |
        [Unit] Description=Daily Salt tree verify
        [Timer] OnCalendar=daily Persistent=true
        [Install] WantedBy=timers.target
  cmd.run:
    - name: systemctl daemon-reload && systemctl enable --now salt-tree-verify.timer

# ---- Template full-filesystem hashing (baseline + daily verify) ----
tmpl-hash:
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

tmpl-verify:
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
        if [ -z "$BASE" ]; then alert "TEMPLATE HASH: missing baseline for $t"; FAIL=1; continue; fi
        if [ "$CUR" != "$BASE" ]; then alert "TEMPLATE HASH MISMATCH: $t cur=$CUR base=$BASE"; FAIL=1; fi
      done
      exit $FAIL

tmpl-baseline:
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

tmpl-verify-timer:
  file.managed:
    - name: /etc/systemd/system/template-hash-verify.service
    - mode: '0644'
    - contents: |
        [Unit] Description=Verify template hashes vs baseline
        [Service] Type=oneshot ExecStart=/usr/local/sbin/qubes-template-hash-verify.sh
  file.managed:
    - name: /etc/systemd/system/template-hash-verify.timer
    - mode: '0644'
    - contents: |
        [Unit] Description=Daily template verify
        [Timer] OnCalendar=daily Persistent=true
        [Install] WantedBy=timers.target
  cmd.run:
    - name: systemctl daemon-reload && systemctl enable --now template-hash-verify.timer

# ---- Policy pack hashing (/etc/qubes/policy.d) ----
policy-hash:
  file.managed:
    - name: /usr/local/sbin/qubes-policy-hash.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      find /etc/qubes/policy.d -maxdepth 1 -type f -name "*.policy" -print0 \
        | xargs -0 cat | sed 's/[ \t]\+/ /g' | sed 's/#.*$//' | grep -v '^[[:space:]]*$' \
        | sha256sum | awk '{print $1}'

policy-verify:
  file.managed:
    - name: /usr/local/sbin/qubes-policy-verify.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      CUR="$(/usr/local/sbin/qubes-policy-hash.sh)"
      BASE="$(qvm-run -q --pass-io vault-secrets 'cat /home/user/.policy-hashes/qubes-policy.sha256' 2>/dev/null || true)"
      [ -n "$BASE" ] || { alert "POLICY HASH: missing baseline"; exit 1; }
      [ "$CUR" = "$BASE" ] || { alert "POLICY HASH MISMATCH cur=$CUR base=$BASE"; exit 1; }

policy-baseline:
  cmd.run:
    - name: |
        set -e
        H="$(/usr/local/sbin/qubes-policy-hash.sh)"
        qvm-run -q --pass-io vault-secrets 'mkdir -p /home/user/.policy-hashes'
        printf "%s\n" "$H" | qvm-run -q --pass-io vault-secrets 'cat > /home/user/.policy-hashes/qubes-policy.sha256'

policy-verify-timer:
  file.managed:
    - name: /etc/systemd/system/policy-verify.service
    - mode: '0644'
    - contents: |
        [Unit] Description=Verify policy pack vs baseline
        [Service] Type=oneshot ExecStart=/usr/local/sbin/qubes-policy-verify.sh
  file.managed:
    - name: /etc/systemd/system/policy-verify.timer
    - mode: '0644'
    - contents: |
        [Unit] Description=Daily policy verify
        [Timer] OnCalendar=daily Persistent=true
        [Install] WantedBy=timers.target
  cmd.run:
    - name: systemctl daemon-reload && systemctl enable --now policy-verify.timer

# ---- dom0 boot & Xen binaries hash (/boot, /usr/lib/xen) ----
dom0-hash:
  file.managed:
    - name: /usr/local/sbin/dom0-boot-hash.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      tar --posix --numeric-owner --sort=name --mtime=@0 \
          -C / -cpf - boot usr/lib/xen 2>/dev/null | sha256sum | awk '{print $1}'

dom0-hash-baseline:
  cmd.run:
    - name: |
        set -e
        H="$((/usr/local/sbin/dom0-boot-hash.sh) 2>/dev/null || echo '')"
        [ -n "$H" ] || exit 0
        qvm-run -q --pass-io vault-secrets 'mkdir -p {{ V_HASHD }}'
        if ! qvm-run -q --pass-io vault-secrets 'test -s {{ V_HASHD }}/dom0-boot.sha256'; then
          printf "%s\n" "$H" | qvm-run -q --pass-io vault-secrets 'cat > {{ V_HASHD }}/dom0-boot.sha256'
        fi

dom0-hash-verify:
  file.managed:
    - name: /usr/local/sbin/dom0-boot-verify.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      CUR="$(/usr/local/sbin/dom0-boot-hash.sh)"
      BASE="$(qvm-run -q --pass-io vault-secrets 'cat {{ V_HASHD }}/dom0-boot.sha256' 2>/dev/null || true)"
      [ -n "$BASE" ] || { alert "DOM0 BOOT VERIFY: missing baseline"; exit 1; }
      [ "$CUR" = "$BASE" ] || { alert "DOM0 BOOT HASH MISMATCH"; exit 1; }

dom0-hash-verify-timer:
  file.managed:
    - name: /etc/systemd/system/dom0-boot-verify.service
    - mode: '0644'
    - contents: |
        [Unit] Description=Verify dom0 /boot and Xen binaries vs baseline
        [Service] Type=oneshot ExecStart=/usr/local/sbin/dom0-boot-verify.sh
  file.managed:
    - name: /etc/systemd/system/dom0-boot-verify.timer
    - mode: '0644'
    - contents: |
        [Unit] Description=Daily dom0 boot verify
        [Timer] OnCalendar=daily Persistent=true
        [Install] WantedBy=timers.target
  cmd.run:
    - name: systemctl daemon-reload && systemctl enable --now dom0-boot-verify.timer

# ---- TPM PCR (0,2,5,7) baseline + verify (if tpm2-tools present) ----
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
      tpm2_pcrread sha256:0,2,5,7 -Q > /tmp/pcr.txt || exit 0
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
      command -v tpm2_pcrread >/dev/null 2>&1 || exit 0
      /usr/local/sbin/qubes-tpm-pcr-baseline.sh "$TMP" >/dev/null
      BASE="$(qvm-run -q --pass-io vault-secrets 'cat {{ V_HASHD }}/pcr-baseline.json' 2>/dev/null || true)"
      [ -n "$BASE" ] || { alert "TPM VERIFY: no baseline"; exit 0; }
      diff -u <(echo "$BASE" | tr -d ' \t\n\r') <(tr -d ' \t\n\r' < "$TMP") >/dev/null || { alert "TPM PCR MISMATCH"; exit 1; }

tpm-baseline:
  cmd.run:
    - name: |
        set -e
        command -v tpm2_pcrread >/dev/null 2>&1 || exit 0
        qvm-run -q --pass-io vault-secrets 'mkdir -p {{ V_HASHD }}'
        if ! qvm-run -q --pass-io vault-secrets 'test -s {{ V_HASHD }}/pcr-baseline.json'; then
          /usr/local/sbin/qubes-tpm-pcr-baseline.sh /tmp/pcr.json >/dev/null
          cat /tmp/pcr.json | qvm-run -q --pass-io vault-secrets 'cat > {{ V_HASHD }}/pcr-baseline.json'
        fi

tpm-verify-timer:
  file.managed:
    - name: /etc/systemd/system/tpm-attest-verify.service
    - mode: '0644'
    - contents: |
        [Unit] Description=Verify TPM PCRs vs baseline
        [Service] Type=oneshot ExecStart=/usr/local/sbin/qubes-tpm-pcr-verify.sh
  file.managed:
    - name: /etc/systemd/system/tpm-attest-verify.timer
    - mode: '0644'
    - contents: |
        [Unit] Description=Daily TPM verify
        [Timer] OnCalendar=daily Persistent=true
        [Install] WantedBy=timers.target
  cmd.run:
    - name: systemctl daemon-reload && systemctl enable --now tpm-attest-verify.timer

# ---- Conservative Xen mitigations ----
xen-mitigations:
  cmd.run:
    - name: |
        set -e
        CFG=/etc/default/grub
        grep -q 'GRUB_CMDLINE_XEN_DEFAULT' "$CFG" || exit 0
        sed -i 's/^GRUB_CMDLINE_XEN_DEFAULT=.*/GRUB_CMDLINE_XEN_DEFAULT="dom0_mem=max:2048M dom0_max_vcpus=2 smt=off xpti=on spec-ctrl=on mitigations=auto,nosmt"/' "$CFG"
        grub2-mkconfig -o /boot/grub2/grub.cfg || grub2-mkconfig -o /boot/efi/EFI/qubes/grub.cfg || true

# ---- Signed-highstate wrapper (safe entrypoint) ----
signed-highstate:
  file.managed:
    - name: /usr/local/sbin/signed-highstate
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      /usr/local/sbin/salt-verify-signature.sh || { alert "Salt signature verify FAILED"; exit 2; }
      /usr/local/sbin/salt-deploy-staged.sh   || { alert "Salt deploy FAILED";            exit 3; }
      H="$(/usr/local/sbin/salt-tree-hash.sh)"
      qvm-run -q --pass-io vault-secrets 'mkdir -p {{ V_HASHD }}'
      printf "%s\n" "$H" | qvm-run -q --pass-io vault-secrets 'cat > {{ V_HASHD }}/salt-tree.sha256'
      qubesctl state.highstate || { alert "Highstate FAILED after signed deploy"; exit 4; }
      echo "SIGNED-HIGHSTATE OK"
