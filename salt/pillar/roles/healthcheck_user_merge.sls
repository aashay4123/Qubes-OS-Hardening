healthcheck_user_merge:
  expect_templates:
    sys-net:      fedora-42-minimal
    sys-firewall: fedora-42-minimal
    sys-dns:      fedora-42-minimal
    app_default:  deb_harden

  resolver: unbound
  vpn_vms: [sys-vpn-ru, sys-vpn-nl]
  vpn_tor_gateway: sys-vpn-tor
  whonix_ws: [ws-tor-research, ws-tor-forums]
  app_vms: [work, dev, personal]

  global_default_dispvm: debian-12-dvm
  per_vm_default_dispvm:
    work: debian-12-dvm
    dev: debian-12-dvm

  suite_timer: disable  # set to 'hourly' or 'daily' if you want it scheduled

  # >>> NEW: turn on every deep check <<<
  checks:
    dnsmasq: true                 # sys-firewall dnsmasq presence/logging
    whonix_dns_exclusion: true    # NAT exclusion for Whonix VPN→Tor DNS
    appvm_firewall_drop: true     # AppVM qvm-firewall default-drop
    ids_suricata: true            # sys-ids Suricata & eve.json
    resolver_logs: true           # unbound/dnsmasq log presence
    device_policies: true         # USB/Input/PCI policy sanity
    whonix_policy_file: true      # 50-whonix-vpn-tor.policy presence
    openssl_tls_policy: true      # OpenSSL/Fedora crypto-policy checks
    chrony_nts: true              # Chrony/chronyd + NTS hints
    ssh_client_hardening: true    # /etc/ssh/ssh_config.d/* checks
    apparmor_browsers: true       # Firefox/Chromium AppArmor enforce
    vault_servers: true           # split-GPG/SSH servers in vaults
    client_wrappers: true         # qgpg*/qpass* client wrappers
    tags_split_services: true     # split-gpg/ssh/pass tags on callers
    updatevm_sys_firewall: true   # dom0 updatevm=sys-firewall
    dvm_spawn_test: true          # actually spawn DVMs to test
