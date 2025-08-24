hvm_install:
  # Where the ISOs live (a qube you control)
  iso_qube: vault_iso

  vms:
    win11:
      name: win11-standalone
      label: orange
      class: StandaloneVM
      virt_mode: hvm
      disk: 80g
      memory: 6244
      maxmem: 6444
      vcpus: 4
      netvm: sys-firewall
      qrexec_timeout: 7200          # recommended for Windows per Qubes docs
      cdrom_path: /home/user/ISOs/win11.iso

    openbsd:
      name: openbsd-standalone
      label: black
      class: StandaloneVM
      virt_mode: hvm
      disk: 30g
      memory: 2048
      maxmem: 2048
      vcpus: 2
      netvm: sys-firewall
      cdrom_path: /home/user/ISOs/openbsd.iso
