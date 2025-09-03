# Enforce VM -> Template wiring with shutdown + verification
# Mapping:
#   sys-net, sys-firewall, sys-usb -> debian-12-hard-min
#   vault -> debian-12-xfce
#   personal -> debian-12-hard
#   work -> debian-12-work
#   untrusted -> debian-12-hard
# Optional DVM (set DVM_NAME below if you have one)

# ===== Optional: set this to your DVM VM name (or leave blank to skip) =====
# Example: DVM_NAME="debian-12-hard-min-dvm"
set-dvm-name-note:
  cmd.run:
    - name: /bin/true

# ---------- presence checks (non-fatal for optional; fatal for required) ----------
check-sys-net-present:
  cmd.run:
    - name: /bin/sh -c 'qvm-ls --raw-list | grep -qx sys-net'

check-sys-firewall-present:
  cmd.run:
    - name: /bin/sh -c 'qvm-ls --raw-list | grep -qx sys-firewall'

check-sys-usb-present:
  cmd.run:
    - name: /bin/sh -c 'qvm-ls --raw-list | grep -qx sys-usb'

check-vault-present:
  cmd.run:
    - name: /bin/sh -c 'qvm-ls --raw-list | grep -qx vault'

check-personal-present:
  cmd.run:
    - name: /bin/sh -c 'qvm-ls --raw-list | grep -qx personal'

check-work-present:
  cmd.run:
    - name: /bin/sh -c 'qvm-ls --raw-list | grep -qx work'

check-untrusted-present:
  cmd.run:
    - name: /bin/sh -c 'qvm-ls --raw-list | grep -qx untrusted'

# Optional DVM presence (non-fatal)
check-dvm-present:
  cmd.run:
    - name: /bin/sh -c 'DVM_NAME="${DVM_NAME:-}"; [ -z "$DVM_NAME" ] || qvm-ls --raw-list | grep -qx "$DVM_NAME"'
    - env:
        DVM_NAME: ""

# ---------- ensure VMs are shut down before changing template ----------
sys-net-shutdown:
  qvm.shutdown:
    - name: sys-net
    - require:
      - cmd: check-sys-net-present

sys-firewall-shutdown:
  qvm.shutdown:
    - name: sys-firewall
    - require:
      - cmd: check-sys-firewall-present

sys-usb-shutdown:
  qvm.shutdown:
    - name: sys-usb
    - require:
      - cmd: check-sys-usb-present

vault-shutdown:
  qvm.shutdown:
    - name: vault
    - require:
      - cmd: check-vault-present

personal-shutdown:
  qvm.shutdown:
    - name: personal
    - require:
      - cmd: check-personal-present

work-shutdown:
  qvm.shutdown:
    - name: work
    - require:
      - cmd: check-work-present

untrusted-shutdown:
  qvm.shutdown:
    - name: untrusted
    - require:
      - cmd: check-untrusted-present

# ---------- set templates (idempotent) ----------
sys-net-template:
  qvm.prefs:
    - name: sys-net
    - template: debian-12-hard-min
    - require:
      - qvm: sys-net-shutdown

sys-firewall-template:
  qvm.prefs:
    - name: sys-firewall
    - template: debian-12-hard-min
    - require:
      - qvm: sys-firewall-shutdown

sys-usb-template:
  qvm.prefs:
    - name: sys-usb
    - template: debian-12-hard-min
    - require:
      - qvm: sys-usb-shutdown

vault-template:
  qvm.prefs:
    - name: vault
    - template: debian-12-xfce
    - require:
      - qvm: vault-shutdown

personal-template:
  qvm.prefs:
    - name: personal
    - template: debian-12-hard
    - require:
      - qvm: personal-shutdown

work-template:
  qvm.prefs:
    - name: work
    - template: debian-12-work
    - require:
      - qvm: work-shutdown

untrusted-template:
  qvm.prefs:
    - name: untrusted
    - template: debian-12-hard
    - require:
      - qvm: untrusted-shutdown

# Optional: set template on your DVM VM if provided
dvm-template:
  qvm.prefs:
    - name: ""
    - template: debian-12-hard-min
    - onlyif: /bin/sh -c 'DVM_NAME="${DVM_NAME:-}"; [ -n "$DVM_NAME" ]'
    - require:
      - cmd: check-dvm-present
    - env:
        DVM_NAME: ""

# ---------- verification (hard fail on mismatch) ----------
verify-sys-net-template:
  cmd.run:
    - name: /bin/sh -c '[ "$(qvm-prefs sys-net template)" = "debian-12-hard-min" ]'
    - require:
      - qvm: sys-net-template

verify-sys-firewall-template:
  cmd.run:
    - name: /bin/sh -c '[ "$(qvm-prefs sys-firewall template)" = "debian-12-hard-min" ]'
    - require:
      - qvm: sys-firewall-template

verify-sys-usb-template:
  cmd.run:
    - name: /bin/sh -c '[ "$(qvm-prefs sys-usb template)" = "debian-12-hard-min" ]'
    - require:
      - qvm: sys-usb-template

verify-vault-template:
  cmd.run:
    - name: /bin/sh -c '[ "$(qvm-prefs vault template)" = "debian-12-xfce" ]'
    - require:
      - qvm: vault-template

verify-personal-template:
  cmd.run:
    - name: /bin/sh -c '[ "$(qvm-prefs personal template)" = "debian-12-hard" ]'
    - require:
      - qvm: personal-template

verify-work-template:
  cmd.run:
    - name: /bin/sh -c '[ "$(qvm-prefs work template)" = "debian-12-work" ]'
    - require:
      - qvm: work-template

verify-untrusted-template:
  cmd.run:
    - name: /bin/sh -c '[ "$(qvm-prefs untrusted template)" = "debian-12-hard" ]'
    - require:
      - qvm: untrusted-template

# Optional DVM verify (skips when no DVM_NAME)
verify-dvm-template:
  cmd.run:
    - name: /bin/sh -c 'DVM_NAME="${DVM_NAME:-}"; [ -z "$DVM_NAME" ] || [ "$(qvm-prefs "$DVM_NAME" template)" = "debian-12-hard-min" ]'
    - require:
      - qvm: dvm-template
    - env:
        DVM_NAME: ""

# ---------- summary (non-fatal pretty print) ----------
wiring-summary:
  cmd.run:
    - name: >
        /bin/sh -c '
        printf "\n=== VM -> Template mapping ===\n";
        for vm in sys-net sys-firewall sys-usb vault personal work untrusted; do
          if qvm-ls --raw-list | grep -qx "$vm"; then
            printf "%-16s -> %s\n" "$vm" "$(qvm-prefs "$vm" template)";
          else
            printf "%-16s -> (missing)\n" "$vm";
          fi
        done
        DVM_NAME="${DVM_NAME:-}";
        if [ -n "$DVM_NAME" ]; then
          if qvm-ls --raw-list | grep -qx "$DVM_NAME"; then
            printf "%-16s -> %s\n" "$DVM_NAME" "$(qvm-prefs "$DVM_NAME" template)";
          else
            printf "%-16s -> (missing)\n" "$DVM_NAME";
          fi
        fi
        '
    - require:
      - cmd: verify-sys-net-template
      - cmd: verify-sys-firewall-template
      - cmd: verify-sys-usb-template
      - cmd: verify-vault-template
      - cmd: verify-personal-template
      - cmd: verify-work-template
      - cmd: verify-untrusted-template
      - cmd: verify-dvm-template
    - env:
        DVM_NAME: ""
