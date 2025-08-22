osi_model_security:
  # Global toggles
  strict_crypto: true                  # Fedora: FUTURE; Debian: SECLEVEL=3
  enable_dnsmasq_logs: true            # sys-firewall: log DNS queries per-VM
  enable_ecs: false                    # sys-firewall: EDNS Client Subnet tagging
  enable_dnstap: false                 # sys-dns: DNSTAP capture

  # Service / infra VMs
  vms:
    sys-usb:
      template: debian-12-minimal
      label: red
      layer: physical
      memory: 400
      maxmem: 800
      tags: [usb, physical]

    sys-net:
      template: fedora-40-minimal
      label: red
      layer: link
      provides_network: true
      memory: 500
      maxmem: 1000
      tags: [link, nic]

    sys-ids:
      template: fedora-40-minimal
      label: black
      layer: network
      provides_network: true
      netvm: sys-net
      memory: 700
      maxmem: 1400
      tags: [ids, inline]

    sys-dns:
      template: debian-12-minimal
      label: yellow
      layer: network
      provides_network: true
      netvm: sys-ids
      memory: 600
      maxmem: 1200
      tags: [dns, resolver, logging]

    sys-firewall:
      template: fedora-40-minimal
      label: orange
      layer: network
      provides_network: true
      netvm: sys-dns
      memory: 450
      maxmem: 900
      tags: [router, dnsmasq_logs]

  # Application / service VMs
  app_vms:
    work-web:
      template: debian-12-minimal
      netvm: sys-firewall
      allow: [https, dns, ntp]
      tags: [work, browser]
    dev:
      template: fedora-40-minimal
      netvm: sys-firewall
      allow: [https, dns, ssh]
      tags: [dev, usb_storage_ok]
