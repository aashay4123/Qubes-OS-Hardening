{% from "osi_model_security/map.jinja" import cfg with context %}
{% set E = cfg.emergency %}
{% set keep = E.keep_running %}
{% set pats = E.stop_vms_patterns %}

/usr/local/sbin/osi-panic:
  file.managed:
    - mode: '0755'
    - contents: |
        #!/usr/bin/env bash
        set -euo pipefail
        ALERT=/usr/local/bin/alert
        echo "[PANIC] Triggered at $(date -Is)"
        # Enumerate VMs
        mapfile -t VMS < <(qvm-ls --raw-list)
        KEEP="{{ keep|join(' ') }}"
        STOP_LIST=()
        for v in "${VMS[@]}"; do
          [[ "$v" == "dom0" ]] && continue
          SKIP=0
          for k in {{ keep|tojson }}; do [[ "$v" == "$k" ]] && SKIP=1; done
          if [[ $SKIP -eq 1 ]]; then continue; fi
          for re in {{ pats|tojson }}; do
            if [[ "$v" =~ $re ]]; then STOP_LIST+=("$v"); break; fi
          done
        done
        # Stop targets (parallel best-effort)
        for vm in "${STOP_LIST[@]}"; do
          qvm-shutdown --wait --timeout=60 "$vm" || true
        done
        # Final alert
        [[ -x "$ALERT" ]] && printf "%s" "PANIC: stopped ${#STOP_LIST[@]} VMs" | "$ALERT" || true
        echo "[PANIC] Completed."

/etc/systemd/system/osi-panic.service:
  file.managed:
    - mode: '0644'
    - contents: |
        [Unit] Description=OSI Panic — emergency stop
        [Service] Type=oneshot ExecStart=/usr/local/sbin/osi-panic

# Optional: quick alias
/usr/local/bin/panic:
  file.symlink:
    - target: /usr/local/sbin/osi-panic
