# TrenchBoot AEM (TPM2/UEFI) for Qubes 4.2 dom0
# Ref: Qubes news (TrenchBoot AEM) + TrenchBoot install docs (2025-06-06).
# Repo: https://dl.3mdeb.com/rpm/QubesOS/r4.2/current/dom0/fc37
# Installs packages safely and provides a provisioning wizard.
# You will run:  sudo aem-wizard-tpm2 --device /dev/sdX1 --mfa --sinit-from <vm> </path/ACM.bin>
# Docs: qubes-os.org (news) & trenchboot.org (install guide).  (cited in chat)

# Quick driver’s manual:

# Apply: sudo qubesctl state.apply qubes.stack.aem_trenchboot_tpm2
# Provision (UEFI/TPM2, with TOTP; SINIT from a VM path):
# sudo aem-wizard-tpm2 --mfa --device /dev/sdX1 \
#   --sinit-from vault-secrets /home/user/SINIT/YourPlatformACM.bin --post-grub
# Reboot and pick the AEM/TrenchBoot entry.
# Health (daily + on demand): sudo /usr/local/sbin/qubes-final-health.sh
# Two realities to confirm on your Asus:
# DRTM availability: TrenchBoot requires CPU/firmware DRTM (Intel TXT or AMD Secure Launch). Many consumer laptops ship TPM2 but no TXT. Check:
# grep -i txt /proc/cpuinfo and BIOS for “Intel TXT” option. If TXT isn’t available, TrenchBoot AEM can’t establish a DRTM; consider Heads hardware. 
# Heads option: Qubes-certified NovaCustom V54/V56 now ship with Heads—measured boot + TPM2, vendor-supported. If your current laptop lacks TXT, migrating to a Heads platform gives you the same “evil-maid” protection with cleaner UX. 
# Why this is the safest 2025-ready path
# TrenchBoot AEM is the actively maintained TPM2/UEFI way to do AEM on Qubes; the repo and steps above are from the June 2025 install doc. 
# Qubes endorsed/covered the work publicly; their article explains why TrenchBoot replaces the old TPM1.2/TXT stack and enables TPM2. 
# If your platform can’t do DRTM, Heads on certified laptops gives you robust measured boot with TPM2. 


{% set REPO = '/etc/yum.repos.d/aem.repo' %}
{% set KEY  = 'RPM-GPG-KEY-tb-aem' %}
{% set URL  = 'https://dl.3mdeb.com/rpm/QubesOS/r4.2/current/dom0/fc37' %}

# 0) Add TrenchBoot AEM repo (dom0)
aem-repo:
  file.managed:
    - name: {{ REPO }}
    - mode: '0644'
    - contents: |
        [aem]
        name = Anti Evil Maid based on TrenchBoot
        baseurl = {{ URL }}
        gpgcheck = 1
        gpgkey = {{ URL }}/RPM-GPG-KEY-tb-aem
        enabled = 1

aem-repo-key:
  cmd.run:
    - name: |
        set -e
        qvm-run --pass-io sys-net 'curl -fsSL {{ URL }}/RPM-GPG-KEY-tb-aem' > {{ KEY }}
        rpm --import {{ KEY }}
        rm -f {{ KEY }}

# 1) Prereqs from qubes-dom0-current-testing (per TrenchBoot doc)
aem-prereqs:
  cmd.run:
    - name: |
        set -e
        qubes-dom0-update --enablerepo=qubes-dom0-current-testing -y \
          oathtool openssl qrencode tpm2-tools tpm-tools || true

# 2) Install TrenchBoot AEM package set (auto-detect UEFI vs Legacy, Intel vs AMD)
aem-install:
  cmd.run:
    - name: |
      set -e
      pkgs=( anti-evil-maid grub2-common grub2-tools grub2-tools-extra grub2-tools-minimal \
             python3-xen xen xen-hypervisor xen-libs xen-licenses xen-runtime )
      if [ -d /sys/firmware/efi ]; then
        pkgs+=( grub2-efi-x64 grub2-efi-x64-modules )
      else
        pkgs+=( grub2-pc grub2-pc-modules )
      fi

      # Reinstall if Qubes has same NEVR; then install new-only (per doc)
      qubes-dom0-update --disablerepo="*" --enablerepo=aem --action=reinstall -y "${pkgs[@]}" || true
      qubes-dom0-update --disablerepo="*" --enablerepo=aem --action=install   -y "${pkgs[@]}"

# 3) Provisioning wizard for TPM2/TrenchBoot AEM
aem-wizard-tpm2:
  file.managed:
    - name: /usr/local/sbin/aem-wizard-tpm2
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      die(){ echo "AEM: $*" >&2; exit 1; }
      info(){ echo "AEM: $*"; }
      DEV="" ; MODE="mfa" ; SVM="" ; SFILE="" ; INTERNAL=""; POST=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --device) DEV="$2"; shift 2;;
          --mfa) MODE="mfa"; shift;;
          --text) MODE="text"; shift;;
          --sinit-from) SVM="$2"; SFILE="$3"; shift 3;;
          --internal) INTERNAL="yes"; shift;;
          --post-grub) POST="yes"; shift;;
          *) die "Unknown arg $1";;
        esac
      done
      [ -e /sys/class/tpm/tpm0 ] || die "No TPM device."
      if [ -n "$SVM" ] && [ -n "$SFILE" ]; then
        info "Placing SINIT ACM from $SVM:$SFILE into /boot"
        qvm-run --pass-io "$SVM" "cat '$SFILE'" > /boot/aem_sinit_acm.BIN
      fi
      [ -n "$DEV" ] || die "Specify --device /dev/sdX1 (or /dev/nvme0n1p1)"
      info "Clearing/initializing TPM for AEM (you may be prompted)"
      anti-evil-maid-tpm-setup || die "TPM setup failed (enable/clear TPM in BIOS, enable TXT/Secure Launch)"
      if [ "$MODE" = "mfa" ]; then
        anti-evil-maid-install -m "$DEV"
      else
        anti-evil-maid-install "$DEV"
      fi
      if [ -n "$POST" ]; then
        info "Attempting GRUB TrenchBoot stanza check/patch (adds 'slaunch' if missing)"
        CFG=/boot/grub2/grub.cfg
        if ! grep -q 'slaunch' "$CFG"; then
          cp -a "$CFG" "$CFG.bak.$(date +%s)"
          awk '
            BEGIN{done=0}
            /^menuentry .*Qubes OS/ && done==0 {print; print "  slaunch"; print "  slaunch_module /aem_sinit_acm.BIN"; done=1; next}
            {print}
          ' "$CFG.bak."* | tee "$CFG" >/dev/null
        fi
      fi
      echo "Done. Reboot, choose the AEM/TrenchBoot entry, and enroll the secret/TOTP."

# 4) A tiny quickcheck helper
aem-quickcheck:
  file.managed:
    - name: /usr/local/sbin/aem-quickcheck
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      echo "TPM: $(test -e /sys/class/tpm/tpm0 && echo present || echo MISSING)"
      echo "UEFI: $( [ -d /sys/firmware/efi ] && echo yes || echo legacy )"
      echo "Packages:"
      rpm -q anti-evil-maid xen-hypervisor grub2-common || true
      echo "SINIT: "; ls /boot/*SINIT* /boot/*BIN 2>/dev/null || echo "not found"
      echo "GRUB slaunch present?: $(grep -q slaunch /boot/grub2/grub.cfg && echo yes || echo no)"


# Daily & on-demand AEM/TPM2/DRTM health checks + privacy hygiene

final-health:
  file.managed:
    - name: /usr/local/sbin/qubes-final-health.sh
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      alert(){ command -v qrexec-client-vm >/dev/null && printf "%s" "$*" | qrexec-client-vm sys-alert my.alert.Send || echo "[ALERT] $*"; }
      ok(){ echo "OK: $*"; }
      FAIL=0

      # AEM packages
      rpm -q anti-evil-maid >/dev/null 2>&1 && ok "anti-evil-maid installed" || { alert "AEM not installed"; FAIL=1; }

      # TPM2 works
      if command -v tpm2_pcrread >/dev/null 2>&1; then
        tpm2_pcrread sha256:0 >/dev/null 2>&1 && ok "TPM2 PCR read ok" || { alert "TPM2 read failed"; FAIL=1; }
      else
        alert "tpm2-tools missing"; FAIL=1
      fi

      # GRUB has TrenchBoot hooks (slaunch)
      grep -q 'slaunch' /boot/grub2/grub.cfg && ok "GRUB slaunch present" || { alert "GRUB lacks slaunch; AEM may not launch"; FAIL=1; }

      # SINIT ACM present (Intel) or SKINIT path (AMD)
      ls /boot/*SINIT* /boot/*BIN >/dev/null 2>&1 && ok "SINIT present" || echo "NOTE: no SINIT file found (might be in firmware TXT region)"

      # sys-net MAC randomization config present
      qvm-run -q --pass-io sys-net 'test -f /etc/NetworkManager/conf.d/00-mac-rand.conf' \
         && ok "sys-net MAC randomization present" || { alert "sys-net MAC rand missing"; FAIL=1; }

      # dnscrypt-proxy in sys-dns
      qvm-run -q --pass-io sys-dns 'systemctl is-active dnscrypt-proxy' | grep -q active \
         && ok "sys-dns dnscrypt active" || { alert "dnscrypt not active in sys-dns"; FAIL=1; }

      # Suricata + digest timer in sys-firewall
      qvm-run -q --pass-io sys-firewall 'systemctl is-active suricata' | grep -q active \
         && ok "Suricata active" || { alert "Suricata not active"; FAIL=1; }
      qvm-run -q --pass-io sys-firewall 'systemctl is-active net-digest.timer' | grep -q active \
         && ok "net-digest timer active" || { alert "net-digest timer not active"; FAIL=1; }

      [ $FAIL -eq 0 ] && echo "FINAL HEALTH: OK" || { echo "FINAL HEALTH: FAIL($FAIL)"; exit 1; }

final-health-timer:
  file.managed:
    - name: /etc/systemd/system/qubes-final-health.service
    - mode: '0644'
    - contents: |
        [Unit] Description=Qubes final health (AEM/TPM2/dnscrypt/suricata)
        [Service] Type=oneshot ExecStart=/usr/local/sbin/qubes-final-health.sh
  file.managed:
    - name: /etc/systemd/system/qubes-final-health.timer
    - mode: '0644'
    - contents: |
        [Unit] Description=Run final health daily
        [Timer] OnCalendar=daily Persistent=true
        [Install] WantedBy=timers.target
  cmd.run:
    - name: systemctl daemon-reload && systemctl enable --now qubes-final-health.timer

# sys-net MAC randomization (privacy at every boot)
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
