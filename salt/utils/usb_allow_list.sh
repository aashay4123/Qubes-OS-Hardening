
#!/bin/bash
set -euo pipefail
POL="/etc/qubes/policy.d/30-usb.policy"
echo "# USB policy generated $(date)" | sudo tee "$POL" >/dev/null
echo "device.usb attach  @anyvm  sys-usb  deny  notify=yes" | sudo tee -a "$POL" >/dev/null
echo "# Allowed NICs to sys-net only:" | sudo tee -a "$POL" >/dev/null
qvm-usb | awk 'NR>1{print $1,$2,$3,$4}' | while read -r ID BUS DEV DESC; do
  # Show choices; user picks desired NICs and re-run, or edit below manually
  :
done
# echo "# Example NICs — edit with your VID:PID" | sudo tee -a "$POL" >/dev/null
# echo "device.usb attach  sys-net  sys-usb  allow  device=0bda:8153" | sudo tee -a "$POL" >/dev/null
# echo "device.usb attach  sys-net  sys-usb  allow  device=0bda:8156" | sudo tee -a "$POL" >/dev/null


# USB allow-list helper (VID:PID)
# Save in dom0 as ~/usb-allowlist-gen.sh:
# Run qvm-usb to see your device VID:PID and replace lines accordingly.
