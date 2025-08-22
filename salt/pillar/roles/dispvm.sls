disposables:
  # System-wide default DispVM (must match one created below)
  default_dispvm: debian-12-dvm

  # Define named Disposable Templates (DVMs) to create
  create:
    debian-12-dvm:
      template: debian-12-minimal     # underlying TemplateVM
      label: gray
      netvm: sys-firewall             # where new dispVMs will egress by default
    fedora-40-dvm:
      template: fedora-40-minimal
      label: gray
      netvm: sys-firewall

  # Optionally set per-VM default DispVMs (for “View/Edit in disposable” in those VMs)
  per_vm_default:
    work-web: debian-12-dvm
    dev:      fedora-40-dvm

  # Force policies: which tagged VMs must open links/files in a DispVM
  force_policies:
    # VMs with these tags will have all “open URL” actions redirected to a DispVM
    openurl_tags: [mail, chat, work]
    # VMs with these tags will have “open file in other VM” redirected to a DispVM
    openinvm_tags: [untrusted, work]

  # Safety: last-policy behavior for others (ask/allow/deny)
  fallback:
    openurl: ask
    openinvm: ask
