{% from "osi_model_security/map.jinja" import cfg with context %}
{% set I = cfg.integrity_alerts %}
{% set VAULT = I.vault_vm %}
{% set ALERT = I.alert_vm %}
{% set ALLOW = I.allow_senders %}
{% set S  = I.signed_deploy %}
{% set T  = I.timers %}
{% set TP = I.tpm %}
{% set XM = I.xen_mitigations %}

# --------------------------- sys-alert (networkless sink) ---------------------------
sys-alert-present:
  qvm.present:
    - name: {{ ALERT }}
    - template: {{ I.alert_template }}
    - label: {{ I.alert_label|default('red') }}
    - prefs:
        netvm: ''

sys-alert-qrexec:
  module.run:
    - name: qvm.run
    - vm: {{ ALERT }}
    - args:
      - |
        sh -lc '
          set -e
          if command -v apt-get >/dev/null; then apt-get update -y || true; apt-get install -y --no-install-recommends libnotify-bin jq || true; fi
          install -d -m 755 /etc/qubes-rpc
          cat >/etc/qubes-rpc/my.alert.Send << "EOF"
          #!/bin/sh
          set -eu
          LOG=/var/log/sys-alert.log
          TS="$(date -Is)"
          MSG="$(cat - || true)"
          mkdir -p "$(dirname "$LOG")"
          echo "$TS $QREXEC_SERVICE_FROM_DOMAIN $MSG" >> "$LOG"
          command -v notify-send >/dev/null && notify-send "Qubes Alert: $QREXEC_SERVICE_FROM_DOMAIN" "$MSG" || true
          EOF
          chmod 0755 /etc/qubes-rpc/my.alert.Send
        '

/etc/qubes/policy.d/20-alert.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        # Qubes Integrity: alert sink policy
        {% for s in ALLOW %}
        my.alert.Send  {{ s }}   {{ ALERT }}   allow
        {% endfor %}
        my.alert.Send  @anyvm    @anyvm        deny  notify=yes

alert-cli:
  file.managed:
    - name: /usr/local/bin/alert
    - mode: '0755'
    - contents: |
        #!/bin/bash
        set -euo pipefail
        MSG="${*:-no message}"
        printf "%s" "$MSG" | qrexec-client-vm {{ ALERT }} my.alert.Send

# --------------------------- Signed-only Salt pipeline ---------------------------
salt-dirs:
  file.directory:
    - names:
      - {{ S.backups_dir }}
      - {{ S.hash_dir }}
    - mode: '0750'

salt-verify-signature.sh:
  file.managed:
    - name: /usr/local/sbin/salt-verify-signature.sh
    - mode: '0755'
    - contents: |
        #!/bin/bash
        set -euo pipefail
        PUB="{{ S.pubkey_path }}"; PKG="{{ S.bundle_path }}"; SIG="{{ S.sig_path }}"
        [ -f "$PUB" ] || { echo "Missing $PUB"; exit 1; }
        [ -f "$PKG" ] || { echo "Missing $PKG"; exit 1; }
        [ -f "$SIG" ] || { echo "Missing $SIG"; exit 1; }
        openssl dgst -sha256 -verify "$PUB" -signature "$SIG" "$PKG" >/dev/null
        tar -tzf "$PKG" | awk '
          /^\// {print "Absolute path: "$0; exit 2}
          /\.\./ {print "Escape path: "$0; exit 2}
          !/^srv\/salt\// {print "Outside srv/salt/: "$0; exit 2}
        ' >/dev/null

salt-deploy-staged.sh:
  file.managed:
    - name: /usr/local/sbin/salt-deploy-staged.sh
    - mode: '0755'
    - contents: |
        #!/bin/bash
        set -euo pipefail
        PKG="{{ S.bundle_path }}"; STAGE="{{ S.stage_dir }}"; SRV="{{ S.srv_dir }}"
        BACK="{{ S.backups_dir }}/srv-salt-$(date +%Y%m%d-%H%M%S).tar.zst"
        [ -f "$PKG" ] || { echo "No bundle $PKG"; exit 1; }
        rm -rf "$STAGE"; mkdir -p "$STAGE"
        tar --no-same-owner --no-same-permissions -xzf "$PKG" -C "$STAGE"
        find "$STAGE" -type d -exec chmod 0755 {} +; find "$STAGE" -type f -exec chmod 0644 {} +
        find "$STAGE" -type f \( -path '*/bin/*' -o -path '*/sbin/*' \) -exec chmod 0755 {} + || true
        if [ -d "$SRV" ]; then tar -C / -I 'zstd -T0 -19' -cf "$BACK" srv/salt || true; fi
        rsync -a --delete "$STAGE/srv/salt/" "$SRV/"
        rm -rf "$STAGE"
        echo "DEPLOYED"

salt-tree-hash.sh:
  file.managed:
    - name: /usr/local/sbin/salt-tree-hash.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      tar --posix --numeric-owner --sort=name --mtime=@0 -C / -cpf - srv/salt | sha256sum | awk '{print $1}'

salt-tree-verify.sh:
  file.managed:
    - name: /usr/local/sbin/salt-tree-verify.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      CUR="$(/usr/local/sbin/salt-tree-hash.sh)"
      BASE="$(qvm-run -q --pass-io {{ VAULT }} 'cat {{ S.hash_dir }}/salt-tree.sha256' 2>/dev/null || true)"
      [ -n "$BASE" ] || { alert "SALT VERIFY: missing baseline"; exit 1; }
      [ "$CUR" = "$BASE" ] || { alert "SALT TREE HASH MISMATCH cur=$CUR base=$BASE"; exit 1; }

salt-tree-baseline:
  cmd.run:
    - name: |
        set -e
        H="$((/usr/local/sbin/salt-tree-hash.sh) 2>/dev/null || echo '')"
        [ -n "$H" ] || exit 0
        qvm-run -q --pass-io {{ VAULT }} 'mkdir -p {{ S.hash_dir }}'
        if ! qvm-run -q --pass-io {{ VAULT }} 'test -s {{ S.hash_dir }}/salt-tree.sha256'; then
          printf "%s\n" "$H" | qvm-run -q --pass-io {{ VAULT }} 'cat > {{ S.hash_dir }}/salt-tree.sha256'
        fi

salt-tree-timer:
  file.managed:
    - name: /etc/systemd/system/salt-tree-verify.service
    - mode: '0644'
    - contents: |
        [Unit] Description=Verify /srv/salt against baseline
        [Service] Type=oneshot ExecStart=/usr/local/sbin/salt-tree-verify.sh
  file.managed:
    - name: /etc/systemd/system/salt-tree-verify.timer
    - mode: '0644'
    - contents: |
        [Unit] Description=Daily Salt tree verify
        [Timer] OnCalendar={{ T.salt_daily }} Persistent=true
        [Install] WantedBy=timers.target
  cmd.run:
    - name: systemctl daemon-reload && systemctl enable --now salt-tree-verify.timer

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
      qvm-run -q --pass-io {{ VAULT }} 'mkdir -p {{ S.hash_dir }}'
      printf "%s\n" "$H" | qvm-run -q --pass-io {{ VAULT }} 'cat > {{ S.hash_dir }}/salt-tree.sha256'
      qubesctl state.highstate || { alert "Highstate FAILED after signed deploy"; exit 4; }
      echo "SIGNED-HIGHSTATE OK"

# --------------------------- Template full-FS hashing ---------------------------
template-hash.sh:
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

template-verify.sh:
  file.managed:
    - name: /usr/local/sbin/qubes-template-hash-verify.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      FAIL=0
      for t in {{ I.templates|tojson }}; do
        qvm-ls --raw-list | grep -qx "$t" || continue
        CUR=$(/usr/local/sbin/qubes-template-hash.sh "$t")
        BASE="$(qvm-run -q --pass-io {{ VAULT }} "cat /home/user/.template-hashes/${t}.sha256" 2>/dev/null || true)"
        if [ -z "$BASE" ]; then alert "TEMPLATE HASH: missing baseline for $t"; FAIL=1; continue; fi
        if [ "$CUR" != "$BASE" ]; then alert "TEMPLATE HASH MISMATCH: $t cur=$CUR base=$BASE"; FAIL=1; fi
      done
      exit $FAIL

template-baseline:
  cmd.run:
    - name: |
        set -e
        qvm-run -q --pass-io {{ VAULT }} 'mkdir -p /home/user/.template-hashes'
        mkdir -p /var/lib/qubes/template-hashes
        for t in {{ I.templates|join(' ') }}; do
          qvm-ls --raw-list | grep -qx "$t" || continue
          OUT="/var/lib/qubes/template-hashes/${t}.sha256"
          if [ ! -s "$OUT" ]; then
            H=$(/usr/local/sbin/qubes-template-hash.sh "$t")
            echo "$H" > "$OUT"
            printf "%s\n" "$H" | qvm-run -q --pass-io {{ VAULT }} "cat > /home/user/.template-hashes/${t}.sha256"
          fi
        done

template-timer:
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
        [Timer] OnCalendar={{ T.templates_daily }} Persistent=true
        [Install] WantedBy=timers.target
  cmd.run:
    - name: systemctl daemon-reload && systemctl enable --now template-hash-verify.timer

# --------------------------- Policy pack hashing ---------------------------
policy-hash.sh:
  file.managed:
    - name: /usr/local/sbin/qubes-policy-hash.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      {% for d in I.policy_dirs %}
      find {{ d }} -maxdepth 1 -type f -name "*.policy" -print0
      {% endfor %} \
      | xargs -0 cat | sed 's/[ \t]\+/ /g' | sed 's/#.*$//' | grep -v '^[[:space:]]*$' \
      | sha256sum | awk '{print $1}'

policy-verify.sh:
  file.managed:
    - name: /usr/local/sbin/qubes-policy-verify.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      CUR="$(/usr/local/sbin/qubes-policy-hash.sh)"
      BASE="$(qvm-run -q --pass-io {{ VAULT }} 'cat /home/user/.policy-hashes/qubes-policy.sha256' 2>/dev/null || true)"
      [ -n "$BASE" ] || { alert "POLICY HASH: no baseline in vault"; exit 1; }
      [ "$CUR" = "$BASE" ] || { alert "POLICY HASH MISMATCH cur=$CUR base=$BASE"; exit 1; }

policy-baseline:
  cmd.run:
    - name: |
        set -e
        H="$(/usr/local/sbin/qubes-policy-hash.sh)"
        qvm-run -q --pass-io {{ VAULT }} 'mkdir -p /home/user/.policy-hashes'
        printf "%s\n" "$H" | qvm-run -q --pass-io {{ VAULT }} 'cat > /home/user/.policy-hashes/qubes-policy.sha256'

policy-timer:
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
        [Timer] OnCalendar={{ T.policy_daily }} Persistent=true
        [Install] WantedBy=timers.target
  cmd.run:
    - name: systemctl daemon-reload && systemctl enable --now policy-verify.timer

# --------------------------- Dom0 boot & Xen hashing ---------------------------
dom0-boot-hash.sh:
  file.managed:
    - name: /usr/local/sbin/dom0-boot-hash.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      tar --posix --numeric-owner --sort=name --mtime=@0 \
          -C / -cpf - {{ I.dom0_boot.include_dirs|join(' ') }} 2>/dev/null \
      | sha256sum | awk '{print $1}'

dom0-boot-verify.sh:
  file.managed:
    - name: /usr/local/sbin/dom0-boot-verify.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      CUR="$(/usr/local/sbin/dom0-boot-hash.sh)"
      BASE="$(qvm-run -q --pass-io {{ VAULT }} 'cat {{ S.hash_dir }}/dom0-boot.sha256' 2>/dev/null || true)"
      [ -n "$BASE" ] || { alert "DOM0 BOOT VERIFY: missing baseline"; exit 1; }
      [ "$CUR" = "$BASE" ] || { alert "DOM0 BOOT HASH MISMATCH"; exit 1; }

dom0-boot-baseline:
  cmd.run:
    - name: |
        set -e
        H="$((/usr/local/sbin/dom0-boot-hash.sh) 2>/dev/null || echo '')"
        [ -n "$H" ] || exit 0
        qvm-run -q --pass-io {{ VAULT }} 'mkdir -p {{ S.hash_dir }}'
        if ! qvm-run -q --pass-io {{ VAULT }} 'test -s {{ S.hash_dir }}/dom0-boot.sha256'; then
          printf "%s\n" "$H" | qvm-run -q --pass-io {{ VAULT }} 'cat > {{ S.hash_dir }}/dom0-boot.sha256'
        fi

dom0-boot-timer:
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
        [Timer] OnCalendar={{ T.boot_daily }} Persistent=true
        [Install] WantedBy=timers.target
  cmd.run:
    - name: systemctl daemon-reload && systemctl enable --now dom0-boot-verify.timer

# --------------------------- TPM PCR baseline/verify ---------------------------
{% if TP.enable %}
tpm2-tools-install:
  cmd.run:
    - name: qubes-dom0-update -y tpm2-tools || true

tpm-baseline.sh:
  file.managed:
    - name: /usr/local/sbin/qubes-tpm-pcr-baseline.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      OUT="${1:-/tmp/pcr-baseline.json}"
      BANK="{{ TP.bank }}"; LIST="{{ TP.pcrs|join(',') }}"
      tpm2_pcrread ${BANK}:${LIST} -Q > /tmp/pcr.txt || exit 0
      printf '{ "%s": {' "$BANK" > "$OUT"
      SEP=""
      awk '/^{{ TP.bank }}/ { split($0,a,/[(): ]+/); idx=a[2]; val=a[4]; printf "%s\"%s\":\"%s\"", "'"$SEP"'", idx, val; SEP="," }' /tmp/pcr.txt >> "$OUT"
      printf '}, "meta": { "date": "%s" } }\n' "$(date -Is)" >> "$OUT"
      cat "$OUT"

tpm-verify.sh:
  file.managed:
    - name: /usr/local/sbin/qubes-tpm-pcr-verify.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      BANK="{{ TP.bank }}"
      TMP="/tmp/pcr-cur.json"
      command -v tpm2_pcrread >/dev/null 2>&1 || exit 0
      /usr/local/sbin/qubes-tpm-pcr-baseline.sh "$TMP" >/dev/null
      BASE="$(qvm-run -q --pass-io {{ VAULT }} 'cat {{ S.hash_dir }}/pcr-baseline.json' 2>/dev/null || true)"
      [ -n "$BASE" ] || { alert "TPM VERIFY: no baseline"; exit 0; }
      diff -u <(echo "$BASE" | tr -d " \t\n\r") <(tr -d " \t\n\r" < "$TMP") >/dev/null || { alert "TPM PCR MISMATCH"; exit 1; }

tpm-baseline:
  cmd.run:
    - name: |
        set -e
        command -v tpm2_pcrread >/dev/null 2>&1 || exit 0
        qvm-run -q --pass-io {{ VAULT }} 'mkdir -p {{ S.hash_dir }}'
        if ! qvm-run -q --pass-io {{ VAULT }} 'test -s {{ S.hash_dir }}/pcr-baseline.json'; then
          /usr/local/sbin/qubes-tpm-pcr-baseline.sh /tmp/pcr.json >/dev/null
          cat /tmp/pcr.json | qvm-run -q --pass-io {{ VAULT }} 'cat > {{ S.hash_dir }}/pcr-baseline.json'
        fi

tpm-timer:
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
        [Timer] OnCalendar={{ T.tpm_daily }} Persistent=true
        [Install] WantedBy=timers.target
  cmd.run:
    - name: systemctl daemon-reload && systemctl enable --now tpm-attest-verify.timer
{% endif %}

# --------------------------- Xen mitigations (conservative) ---------------------------
{% if XM.enable %}
xen-mitigations:
  cmd.run:
    - name: |
        set -e
        CFG=/etc/default/grub
        grep -q '^GRUB_CMDLINE_XEN_DEFAULT=' "$CFG" || exit 0
        sed -i 's/^GRUB_CMDLINE_XEN_DEFAULT=.*/GRUB_CMDLINE_XEN_DEFAULT="{{ XM.cmdline }}"/' "$CFG"
        grub2-mkconfig -o /boot/grub2/grub.cfg || grub2-mkconfig -o /boot/efi/EFI/qubes/grub.cfg || true
{% endif %}

# --------------------------- One-shot meta verifier ---------------------------
/usr/local/sbin/verify_security_integrity:
  file.managed:
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      ok=1
      echo "== Integrity & Alerts quick verification =="
      # sys-alert policy
      grep -q "^my.alert.Send" /etc/qubes/policy.d/20-alert.policy || { echo "No alert policy"; ok=0; }
      # Salt tree
      /usr/local/sbin/salt-tree-verify.sh || ok=0
      # Policy pack
      /usr/local/sbin/qubes-policy-verify.sh || ok=0
      # Templates
      /usr/local/sbin/qubes-template-hash-verify.sh || ok=0
      # Dom0 boot/Xen
      /usr/local/sbin/dom0-boot-verify.sh || ok=0
      # TPM
      if systemctl list-unit-files | grep -q tpm-attest-verify; then /usr/local/sbin/qubes-tpm-pcr-verify.sh || ok=0; fi
      if [ $ok -eq 1 ]; then echo "RESULT: PASS"; exit 0; else echo "RESULT: FAIL"; exit 2; fi
