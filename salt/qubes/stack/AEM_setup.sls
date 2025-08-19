# Qubes Anti-Evil-Maid (AEM) staging & helper (dom0)
# Requires: TPM 1.2 + Intel TXT per Qubes docs.

{% set ALERT = '/usr/local/bin/alert' %}

aem-packages:
  cmd.run:
    - name: |
        set -e
        # Install AEM & tpm tools (AEM expects TPM 1.2; tpm2-tools harmless if present)
        qubes-dom0-update -y anti-evil-maid || true

aem-alert-shim:
  file.managed:
    - name: {{ ALERT }}
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      MSG="${*:-no message}"
      if command -v qrexec-client-vm >/dev/null 2>&1; then
        printf "%s" "$MSG" | qrexec-client-vm sys-alert my.alert.Send || echo "[ALERT] $MSG"
      else
        echo "[ALERT] $MSG"
      fi

# Readme with hard warnings about dom0+USB (Qubes doc)
aem-readme:
  file.managed:
    - name: /usr/local/share/AEM-READ-ME-FIRST.txt
    - mode: '0644'
    - contents: |
      QUBES AEM HARD WARNING:
      - Using USB mass storage directly in dom0 is a trade-off; prefer internal-disk AEM if feasible.
      - If you must use external media: use brand-new media with a physical RO switch, move switch to RO after provisioning,
        and never leave AEM media inserted after the boot code displays the secret/TOTP. :contentReference[oaicite:1]{index=1}

# AEM setup wizard (you run it manually once you have media and SINIT ready)
aem-wizard:
  file.managed:
    - name: /usr/local/sbin/aem-wizard
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail

      die(){ echo "AEM: $*" >&2; exit 1; }
      info(){ echo "AEM: $*"; }

      DEV="" ; MODE="text" ; SINIT_VM="" ; SINIT_PATH="" ; SUFFIX="" ; INTERNAL=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --device) DEV="$2"; shift 2;;
          --mfa) MODE="mfa"; shift;;
          --text) MODE="text"; shift;;
          --suffix) SUFFIX="$2"; shift 2;;
          --sinit-from) SINIT_VM="$2"; SINIT_PATH="$3"; shift 3;;
          --internal) INTERNAL="yes"; shift;;
          *) die "Unknown arg $1";;
        esac
      done

      # 0) Sanity: TPM + TXT path
      [ -e /sys/class/tpm/tpm0 ] || die "No TPM device (AEM needs TPM 1.2)."
      grep -qi txt /proc/cpuinfo || echo "NOTE: CPU flags don't show TXT; ensure TXT is enabled in BIOS."

      # 1) TPM initialization for AEM (ownerless SRK for external media)
      info "Initializing TPM for AEM (ownerless SRK)..."
      anti-evil-maid-tpm-setup -z || die "TPM setup failed"

      # 2) SINIT module provisioning (required for Intel TXT launch)
      if [ -n "$SINIT_VM" ] && [ -n "$SINIT_PATH" ]; then
        info "Copying SINIT ACM from $SINIT_VM:$SINIT_PATH to /boot ..."
        qvm-run --pass-io "$SINIT_VM" "cat '$SINIT_PATH'" > /boot/aem_sinit_acm.BIN || die "SINIT copy failed"
      fi
      ls /boot/*.BIN >/dev/null 2>&1 || info "Reminder: place SINIT *.BIN in /boot. (See Intel TXT SINIT docs)."

      # 3) Choose target
      if [ -n "$INTERNAL" ]; then
        # Internal boot partition (e.g., /dev/nvme0n1p1 or /dev/sda1)
        [ -n "$DEV" ] || die "Use --device /dev/XYZn to point at internal boot partition"
        TARGET="$DEV"
      else
        [ -n "$DEV" ] || die "Use --device /dev/sdX1 (USB/SD) for external AEM media"
        TARGET="$DEV"
      fi

      # 4) Install AEM media
      if [ "$MODE" = "mfa" ]; then
        # Multi-factor (TOTP) AEM media (will display QR; you confirm TOTP during install)
        info "Provisioning MFA AEM on $TARGET ..."
        if [ -n "$SUFFIX" ]; then
          anti-evil-maid-install -m -s "$SUFFIX" "$TARGET"
        else
          anti-evil-maid-install -m "$TARGET"
        fi
      else
        # Text-secret mode (fallback)
        info "Provisioning TEXT AEM on $TARGET ..."
        if [ -n "$SUFFIX" ]; then
          anti-evil-maid-install -s "$SUFFIX" "$TARGET"
        else
          anti-evil-maid-install "$TARGET"
        fi
        cat >/var/lib/anti-evil-maid/aem${SUFFIX:+$SUFFIX}/secret.txt <<'EOF'
        My AEM secret (change me!)
        EOF
        systemctl restart anti-evil-maid-unseal || true
      fi

      # 5) Internal-boot hardening note
      if [ -z "$INTERNAL" ]; then
        info "External-media mode: consider removing internal /boot from dom0 /etc/fstab and do not mount it again."
      fi

      info "AEM provisioning done. Reboot from AEM media to test. After kernel/Xen updates you may see 'freshness token' message; it will auto-reseal post-boot per AEM docs."

# Quick helper to verify after boot (TPM & AEM bits visible)
aem-quickcheck:
  file.managed:
    - name: /usr/local/sbin/aem-quickcheck
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      echo "== TPM present =="; test -e /sys/class/tpm/tpm0 && echo OK || { echo "NO TPM"; exit 1; }
      echo "== AEM files =="; ls -l /var/lib/anti-evil-maid || true
      echo "== SINIT in /boot =="; ls /boot/*.BIN 2>/dev/null || echo "No SINIT BIN found"
      echo "== AEM services =="; systemctl -a | egrep 'anti-evil-maid|tpm' || true

# NOTE: For security rationale & commands, see:
# - Qubes AEM doc (TPM1.2 + TXT; dom0+USB tradeoff)  :contentReference[oaicite:2]{index=2}
# - qubes-antievilmaid README (commands: anti-evil-maid-*-setup/install; SINIT/TOTP flow)  :contentReference[oaicite:3]{index=3}
# - Heads-on-Qubes as hardware alternative (measured boot on TPM2)  :contentReference[oaicite:4]{index=4}
# - TrenchBoot AEM for TPM2/UEFI track (if platform supports)  :contentReference[oaicite:5]{index=5}

# Final health checks & alerting (dom0)
# - Verifies AEM install, TPM readable, SINIT present
# - Confirms Xen mitigations (smt=off)
# - Ensures sys-net MAC randomization enabled each boot
# - Reuses dnscrypt/suricata/digest checks (sys-dns/sys-firewall)
# - Runs daily + on-demand, alert to sys-alert

final-checks-script:
  file.managed:
    - name: /usr/local/sbin/qubes-final-health.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      alert(){ if command -v alert >/dev/null; then alert "$@"; else echo "[ALERT] $*"; fi; }
      ok(){ echo "OK: $*"; }

      FAIL=0

      # 1) AEM presence & TPM
      rpm -q anti-evil-maid >/dev/null 2>&1 && ok "anti-evil-maid installed" || { alert "AEM not installed"; FAIL=1; }
      [ -e /sys/class/tpm/tpm0 ] && ok "TPM device present" || { alert "No TPM at /sys/class/tpm/tpm0"; FAIL=1; }
      ls /boot/*.BIN >/dev/null 2>&1 && ok "SINIT in /boot" || { alert "No SINIT *.BIN found in /boot"; FAIL=1; }
      [ -d /var/lib/anti-evil-maid ] && ok "AEM data dir exists" || { alert "Missing /var/lib/anti-evil-maid"; FAIL=1; }

      # 2) Xen mitigations (SMT off)
      if grep -q 'GRUB_CMDLINE_XEN_DEFAULT=' /etc/default/grub; then
        grep -q 'smt=off' /etc/default/grub && ok "Xen smt=off set" || { alert "Xen smt=off not set"; FAIL=1; }
      fi

      # 3) sys-net MAC randomization present
      qvm-run -q --pass-io sys-net 'test -f /etc/NetworkManager/conf.d/00-mac-rand.conf' \
        && ok "sys-net MAC rand conf present" || { alert "sys-net MAC randomization conf missing"; FAIL=1; }

      # 4) sys-dns dnscrypt up
      qvm-run -q --pass-io sys-dns 'systemctl is-active dnscrypt-proxy' | grep -q active \
        && ok "dnscrypt-proxy active in sys-dns" || { alert "dnscrypt-proxy not active in sys-dns"; FAIL=1; }

      # 5) sys-firewall Suricata & digest timer
      qvm-run -q --pass-io sys-firewall 'systemctl is-active suricata' | grep -q active \
        && ok "Suricata active" || { alert "Suricata not active"; FAIL=1; }
      qvm-run -q --pass-io sys-firewall 'systemctl is-active net-digest.timer' | grep -q active \
        && ok "net-digest.timer active" || { alert "Network digest timer not active"; FAIL=1; }

      # 6) Template/policy/dom0 boot hash timers (from integrity stack)
      for T in salt-tree-verify.timer template-hash-verify.timer policy-verify.timer dom0-boot-verify.timer; do
        systemctl is-active "$T" >/dev/null 2>&1 && ok "$T active" || { alert "$T not active"; FAIL=1; }
      done

      [ $FAIL -eq 0 ] && echo "FINAL HEALTH: OK" || { echo "FINAL HEALTH: FAIL($FAIL)"; exit 1; }

final-checks-timer:
  file.managed:
    - name: /etc/systemd/system/qubes-final-health.service
    - mode: '0644'
    - contents: |
        [Unit] Description=Qubes final health
        [Service] Type=oneshot ExecStart=/usr/local/sbin/qubes-final-health.sh
  file.managed:
    - name: /etc/systemd/system/qubes-final-health.timer
    - mode: '0644'
    - contents: |
        [Unit] Description=Run Qubes final health daily
        [Timer] OnCalendar=daily Persistent=true
        [Install] WantedBy=timers.target
  cmd.run:
    - name: systemctl daemon-reload && systemctl enable --now qubes-final-health.timer

# Ensure sys-net MAC randomization (per-boot) – hardware ID privacy on Wi-Fi/Ethernet
sys-net-macrand:
  qvm.run:
    - name: sys-net
    - user: root
    - cmd: |
        set -e
        apt-get update -y || true
        apt-get install -y --no-install-recommends network-manager || true
        mkdir -p /etc/NetworkManager/conf.d
        cat >/etc/NetworkManager/conf.d/00-mac-rand.conf <<'EOF'
        [device]
        wifi.scan-rand-mac-address=yes
        [connection]
        wifi.cloned-mac-address=random
        ethernet.cloned-mac-address=random
        EOF
        systemctl restart NetworkManager || true
