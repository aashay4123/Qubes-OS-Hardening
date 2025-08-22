# /srv/salt/qubes/policies/maint_tool.sls
/usr/local/bin/qmaint:
  file.managed:
    - mode: '0755'
    - contents: |
        #!/bin/bash
        # Usage: qmaint <vm-name> [seconds]
        VM="$1"; SECS="${2:-300}"
        if [ -z "$VM" ]; then
          echo "Usage: qmaint <vm> [seconds]" 1>&2; exit 1
        fi
        echo "[qmaint] Adding tag 'maint' to $VM for $SECS seconds..."
        qvm-tags "$VM" add maint
        ( sleep "$SECS"; qvm-tags "$VM" del maint; echo "[qmaint] Removed tag 'maint' from $VM" ) &
        echo "[qmaint] Override active; policy rules with @tag:maint now allow."
