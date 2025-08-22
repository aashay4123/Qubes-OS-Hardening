integrity_alerts:
  # VMs
  vault_vm: vault-secrets
  alert_vm: sys-alert
  alert_template: deb_harden_min     # or debian-12-minimal
  alert_label: red
  allow_senders: [dom0, sys-firewall, sys-dns, sys-ids, sys-vpn, sys-whonix]

  # Signed Salt deploy (bundle + detached signature path in dom0)
  signed_deploy:
    pubkey_path: /etc/qubes/salt-pubkey.pem
    bundle_path: /var/tmp/salt.tar.gz
    sig_path:    /var/tmp/salt.tar.gz.sig
    stage_dir:   /var/tmp/salt.staged
    srv_dir:     /srv/salt
    backups_dir: /var/backups/srv-salt
    hash_dir:    /var/lib/qubes/salt-hashes

  # Template hashing (list only those you actually have)
  templates:
    - deb_harden
    - deb_harden_min
    - deb_work
    - deb_dev
    - fedora-42-vpn
    - whonix-gateway-17
    - whonix-workstation-17

  # Policy pack hashing
  policy_dirs:
    - /etc/qubes/policy.d

  # Dom0 boot/Xen hashing
  dom0_boot:
    include_dirs: ["/boot", "/usr/lib/xen"]

  # TPM attestation
  tpm:
    enable: true
    pcrs: [0,2,5,7]
    bank: sha256

  # Xen mitigations (conservative)
  xen_mitigations:
    enable: true
    cmdline: 'dom0_mem=max:2048M dom0_max_vcpus=2 smt=off xpti=on spec-ctrl=on mitigations=auto,nosmt'

  # Timers (systemd OnCalendar expressions)
  timers:
    templates_daily: 'daily'
    policy_daily:    'daily'
    salt_daily:      'daily'
    boot_daily:      'daily'
    tpm_daily:       'daily'
    all_in_one:      'daily' 
