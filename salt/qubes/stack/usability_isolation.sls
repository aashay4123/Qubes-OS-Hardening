# ============================
# USABILITY WITH STRONG ISOLATION
# - Default DisposableVM + OpenURL/OpenInVM -> DVM
# - USB policy: known VID:PID -> sys-net; unknown -> @dispvm (ask)
# - sys-audio / sys-camera VMs + strict policies
# - Clipboard/Filecopy persona guardrails + timed bypass helper
# - Backups helper + monthly template patch cycle (canary)
# ============================

# ---------- DispVM defaults & open policies ---------- #}
default-dvm:
  cmd.run:
    - name: qubes-prefs default_dispvm debian-12-dvm || true   # EDIT if your DVM is different

/etc/qubes/policy.d/40-open-in-dvm.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        qubes.OpenInVM +allow-all-names @dispvm  allow
        qubes.OpenURL  +allow-all-names @dispvm  allow

# ---------- USB policy: known -> sys-net; unknown -> @dispvm ---------- #}
usb-dvm-template:
  cmd.run:
    - name: |
        set -e
        if ! qvm-ls --raw-list | grep -qx deb-12-usb-dvm; then
          qvm-clone deb_harden_min deb-12-usb-dvm
          qvm-prefs deb-12-usb-dvm template_for_dispvms True
        fi

# EDIT the VID:PID values to your actual NICs (run qvm-usb to see)
# Known NICs allowed; unknown -> ask into @dispvm:deb-12-usb-dvm
/etc/qubes/policy.d/30-usb.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        device.usb attach  sys-net  sys-usb  allow  device=0bda:8153
        device.usb attach  sys-net  sys-usb  allow  device=0bda:8156
        device.usb attach  @dispvm:deb-12-usb-dvm  sys-usb  ask
        device.usb attach  @anyvm  @anyvm  deny  notify=yes

# ---------- Audio/Camera isolation ---------- #}
sys-audio:
  cmd.run:
    - name: |
        set -e
        qvm-ls --raw-list | grep -qx sys-audio || qvm-create --class AppVM --template deb_harden_min --label gray sys-audio
        qvm-prefs sys-audio netvm none || true

sys-camera:
  cmd.run:
    - name: |
        set -e
        qvm-ls --raw-list | grep -qx sys-camera || qvm-create --class AppVM --template deb_harden_min --label gray sys-camera
        qvm-prefs sys-camera netvm none || true

/etc/qubes/policy.d/30-audio-camera.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        qubes.AudioPlayback  work      sys-audio  allow
        qubes.AudioPlayback  personal  sys-audio  allow
        qubes.AudioPlayback +allow-all-names       +allow-all-names         deny  notify=yes

        qubes.VideoInput     ws-tor-forums  sys-camera  allow
        qubes.VideoInput    +allow-all-names            +allow-all-names          deny  notify=yes

# ---------- Clipboard/Filecopy persona guardrails + timed bypass ---------- #}
/etc/qubes/policy.d/25-clipboard-ephemeral.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        qubes.ClipboardPaste+allow-all-names@anyvm deny notify=yes

/etc/qubes/policy.d/30-clipboard-filecopy.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        qubes.ClipboardPaste  @tag:persona-work     @tag:persona-work     allow
        qubes.ClipboardPaste  @tag:persona-work     @anyvm                 deny notify=yes
        qubes.ClipboardPaste  @tag:persona-dev      @tag:persona-dev      allow
        qubes.ClipboardPaste  @tag:persona-dev      @anyvm                 deny notify=yes
        qubes.ClipboardPaste  @tag:persona-personal @tag:persona-personal allow
        qubes.ClipboardPaste  @tag:persona-personal @anyvm                 deny notify=yes
        qubes.ClipboardPaste  @tag:persona-research @tag:persona-research allow
        qubes.ClipboardPaste  @tag:persona-research @anyvm                 deny notify=yes
        qubes.ClipboardPaste  @tag:persona-forums   @tag:persona-forums   allow
        qubes.ClipboardPaste  @tag:persona-forums   @anyvm                 deny notify=yes

        qubes.Filecopy        @tag:persona-work     @tag:persona-work     ask
        qubes.Filecopy        @tag:persona-work     @anyvm                 deny notify=yes
        qubes.Filecopy        @tag:persona-dev      @tag:persona-dev      ask
        qubes.Filecopy        @tag:persona-dev      @anyvm                 deny notify=yes
        qubes.Filecopy        @tag:persona-personal @tag:persona-personal ask
        qubes.Filecopy        @tag:persona-personal @anyvm                 deny notify=yes
        qubes.Filecopy        @tag:persona-research @tag:persona-research ask
        qubes.Filecopy        @tag:persona-research @anyvm                 deny notify=yes
        qubes.Filecopy        @tag:persona-forums   @tag:persona-forums   ask
        qubes.Filecopy        @tag:persona-forums   @anyvm                 deny notify=yes

# Timed bypass helper in dom0 (clipboard & filecopy relax for N seconds)
bypass-helper:
  file.managed:
    - name: /home/user/pause-clipboard-guard.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      DUR="${1:-300}"
      CP="/etc/qubes/policy.d/30-clipboard-filecopy.policy"
      BK="/etc/qubes/policy.d/30-clipboard-filecopy.policy.bak"
      [ -f "$CP" ] || { echo "Missing $CP"; exit 1; }
      sudo cp -f "$CP" "$BK"
      echo "# TEMP BYPASS $(date -Is)" | sudo tee "$CP" >/dev/null
      echo "qubes.ClipboardPaste+allow-all-names* allow" | sudo tee -a "$CP" >/dev/null
      echo "qubes.Filecopy+allow-all-names* ask" | sudo tee -a "$CP" >/dev/null
      echo "Bypass active for ${DUR}s..."
      sleep "$DUR"
      sudo mv -f "$BK" "$CP"
      echo "Bypass restored."

# ---------- Backups + monthly template patch cycle ---------- #}
backup-script:
  file.managed:
    - name: /home/user/qubes-backup.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      TARGET="/mnt/backup/qubes-$(date +%Y%m%d)"    # EDIT mount path
      INCLUDE="vault-secrets vault-dn-secrets deb_harden deb_harden_min deb_dev deb_work deb_personal fedora-42-vpn"
      SALT_TAR="/home/user/srv-salt-$(date +%Y%m%d).tar.gz"
      tar -C / -czf "$SALT_TAR" srv/salt
      qvm-backup --yes --compress lz4 --dest "$TARGET" $INCLUDE
      echo "Salt tree saved at $SALT_TAR"

template-patch-cycle:
  file.managed:
    - name: /usr/local/sbin/template-patch-cycle.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      LIST="deb_harden deb_harden_min deb_dev deb_work deb_personal fedora-42-vpn whonix-gateway-17 whonix-workstation-17"
      for t in $LIST; do
        if qvm-run -q -u root --pass-io "$t" 'test -f /etc/debian_version'; then
          qvm-run -q -u root --pass-io "$t" 'apt-get update -y || true; DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y || true'
        else
          qvm-run -q -u root --pass-io "$t" 'dnf -y upgrade --refresh || true'
        fi
        C="${t}-canary"
        qvm-ls --raw-list | grep -qx "$C" || qvm-create --class AppVM --template "$t" --label green "$C"
        qvm-start "$C" || true
        sleep 5
        qvm-shutdown --wait "$C" || true
      done
