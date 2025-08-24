hardening:
  enable: true

  # Global knobs
  ipv6_disable: true
  drop_quic: true           # block UDP/443 in forward (stops HTTP/3/DoH)
  drop_dot: true            # block TCP/853 (DoT) except where explicitly allowed
  logrotate_weeks: 12

  # Identify vaults to air-gap (netvm = none)
  vaults: { gpg: vault-gpg, ssh: vault-ssh, pass: vault-pass }

  # DNS (sys-dns) egress controls
  dns:
    only_dns_out: true
    dot_upstream: false
    resolver_allowlist: []  # e.g., ["9.9.9.9","149.112.112.112"]

  # VPN (sys-vpn) kill-switch (you supply endpoints in your VPN config & pillar)
  vpn:
    killswitch: true
    type: wireguard           # wireguard | openvpn
    endpoints: []             # e.g., [{ip: "203.0.113.10", port: 51820, proto: udp}]

  # IDS (sys-ids)
  ids:
    eve_rotate_weeks: 13
    drop_on_anomaly: false    # set true if you want Suricata to drop (inline) where supported

  # Per-role sysctl hardening applied to ANY Fedora/Debian template-based VM we touch
  sysctl_common:
    kernel.kptr_restrict: 2
    kernel.dmesg_restrict: 1
    kernel.kexec_load_disabled: 1
    kernel.unprivileged_bpf_disabled: 1
    kernel.yama.ptrace_scope: 2
    net.ipv4.conf.all.rp_filter: 1
    net.ipv4.conf.default.rp_filter: 1
    net.ipv4.tcp_syncookies: 1
    net.ipv4.conf.all.accept_redirects: 0
    net.ipv4.conf.default.accept_redirects: 0
    net.ipv4.conf.all.send_redirects: 0
    net.ipv4.conf.default.send_redirects: 0
    net.ipv6.conf.all.accept_ra: 0
    net.ipv6.conf.default.accept_ra: 0
    fs.suid_dumpable: 0

  # App VMs firewall enforcement (default drop + allowlist from your existing app_vms pillar)
  apps:
    enforce_default_drop: true
