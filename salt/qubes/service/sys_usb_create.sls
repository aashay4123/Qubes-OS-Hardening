# Create a sys-usb VM from your minimal Debian template
{% set usb_template = 'deb_harden_min' %}

sys-usb:
  qvm.vm:
    - template: {{ usb_template }}
    - label: gray
    - prefs:
        netvm: none   # no networking for sys-usb

# Optional: helper to attach all USB *controllers* to sys-usb (run manually after verifying input policy)
sys-usb-helper-script:
  cmd.run:
    - name: |
        cat > ~/attach-usb-controllers-to-sys-usb.sh <<'EOF'
        #!/bin/bash
        set -euo pipefail
        echo "Attaching all USB controllers (class 0c03) to sys-usb (persistent)..."
        qvm-pci | awk '/0c03/ {print $1}' | while read -r BDF; do
          echo " -> $BDF"
          qvm-pci attach --persistent sys-usb "dom0:$BDF" || true
        done
        echo "Done. Reboot required for some controllers."
        EOF
        chmod +x ~/attach-usb-controllers-to-sys-usb.sh
