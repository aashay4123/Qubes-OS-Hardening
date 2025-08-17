# /srv/salt/top.sls
base:
  dom0:
    - qubes.harden.debian12_base
    - qubes.harden.fedora42_vpn
    - qubes.templates.build_debian12
    - qubes.templates.vault
    - qubes.templates.build_fedora42
    - qubes.services.nm_hardening
    - qubes.disposables.create
    - qubes.services.whonix_update  
    - qubes.services.create
    - qubes.services.debian_dns_firewall
    - qubes.services.fedora_dns_vpn
    - qubes.apps.create
    - qubes.policies.lockdown
    - qubes.policies.maint_tool
    - qubes.policies.devices
    - qubes.policies.dns_policy
    - qubes.firewall.harden
