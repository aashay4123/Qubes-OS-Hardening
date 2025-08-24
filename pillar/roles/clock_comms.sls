clock_comms:
  clockvm: sys-whonix
  ntp_block_on:
    # VMs where outbound NTP should be blocked (udp/123). AppVMs are safe to include.
    - sys-firewall
    - sys-dns
    - sys-vpn
    - sys-ids
  # Default DispVM for “open in disposable” and safe handlers
  dispvm_default: dispvm-default

  policies:
    # Tag-based allowances for intra-domain movement (everything else deny)
    filecopy_allow_tags:   [work]             # qubes.Filecopy: work ↔ work (ask)
    openinvm_allow_tags:   [work]             # qubes.OpenInVM: work → work (ask)
    openindisp_allow_tags: [work,dev]         # qubes.OpenInDisposable*: allow (ask)
    openurl_allow_tags:    [work,dev]         # qubes.OpenURL: work/dev → DispVM (ask)
    clipboard_allow_tags:  [work]             # work ↔ work (ask)
    u2f_allow_tags:        [work,dev]         # U2F/WebAuthn: work/dev only, via sys-usb
    # Backends
    sys_usb: sys-usb

sidechannel:
  enable: false   # turn true when you’re ready
  # pin cores & set static memory for sensitive service VMs (examples)
  vms:
    sys-net:    { vcpus: 1, cpu_affinity: "0",   memory: 512, maxmem: 512 }
    sys-usb:    { vcpus: 1, cpu_affinity: "1",   memory: 512, maxmem: 512 }
    sys-vpn:    { vcpus: 1, cpu_affinity: "2",   memory: 512, maxmem: 512 }
    sys-dns:    { vcpus: 1, cpu_affinity: "3",   memory: 512, maxmem: 512 }
    vault-gpg:  { vcpus: 1, cpu_affinity: "3",   memory: 512, maxmem: 512 }
    vault-ssh:  { vcpus: 1, cpu_affinity: "3",   memory: 512, maxmem: 512 }
    vault-pass: { vcpus: 1, cpu_affinity: "3",   memory: 512, maxmem: 512 }

emergency:
  keep_running: [dom0, sys-usb]   # don’t touch these in panic
  stop_vms_patterns: ['^work-', '^dev', '^personal', '^sys-(vpn|dns|firewall|net|whonix)$']

boot_firmware:
  enable: true
  # Microcode best-effort (safe no-ops if pkg missing in repo)
  ensure_microcode: true
  # Verify Secure Boot if UEFI present (alert if off)
  verify_secure_boot: true
