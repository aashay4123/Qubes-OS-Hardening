{% from "osi_model_security/map.jinja" import cfg with context %}
{% set B = cfg.boot_firmware %}

{% if not B.enable %}
bootfw-disabled:
  test.succeed_without_changes:
    - name: 'boot/firmware role disabled by pillar'
{% else %}

# Microcode (best-effort, safe if already present or unavailable)
{% if B.ensure_microcode %}
dom0-microcode-intel:
  cmd.run:
    - name: qubes-dom0-update -y microcode_ctl || true
dom0-microcode-amd:
  cmd.run:
    - name: qubes-dom0-update -y linux-firmware || true
{% endif %}

/usr/local/sbin/verify_boot_firmware:
  file.managed:
    - mode: '0755'
    - contents: |
        #!/usr/bin/env bash
        set -euo pipefail
        ALERT=/usr/local/bin/alert
        ok=1

        echo "== Secure Boot status =="
        if [[ -d /sys/firmware/efi/efivars ]]; then
          if [[ -f /sys/firmware/efi/efivars/SecureBoot-* ]]; then
            val=$(hexdump -v -e '1/1 "%d"' /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | tail -c 1)
            if [[ "$val" == "1" ]]; then echo "Secure Boot: ENABLED"; else echo "Secure Boot: DISABLED"; ok=0; fi
          else
            echo "Secure Boot var missing (likely disabled)"; ok=0
          fi
        else
          echo "Legacy BIOS mode (no UEFI)"; ok=0
        fi

        echo "== Xen/Kernel mitigations (cmdline) =="
        CFG=/etc/default/grub
        if grep -q '^GRUB_CMDLINE_XEN_DEFAULT=' "$CFG"; then
          line=$(grep '^GRUB_CMDLINE_XEN_DEFAULT=' "$CFG")
          echo "$line"
          echo "$line" | grep -Eq 'smt=off|nosmt' || { echo "WARN: SMT not disabled"; ok=0; }
          echo "$line" | grep -Eq 'xpti=on|spec-ctrl=on' || { echo "WARN: xpti/spec-ctrl not present"; ok=0; }
        else
          echo "No GRUB_CMDLINE_XEN_DEFAULT found"; ok=0
        fi

        echo "== Microcode presence (best-effort) =="
        rpm -q microcode_ctl >/dev/null 2>&1 && echo "Intel microcode installed" || echo "Intel microcode not confirmed"
        rpm -q linux-firmware >/dev/null 2>&1 && echo "linux-firmware present" || echo "linux-firmware not confirmed"

        if [[ $ok -ne 1 ]]; then
          [[ -x "$ALERT" ]] && printf "%s" "BOOT/FW posture needs attention" | "$ALERT" || true
          exit 2
        fi
        echo "RESULT: PASS"

{% endif %}
