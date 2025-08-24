net_topology:
  # Templates
  templates:
    net: fedora-42-minimal
    whonix_gw: whonix-gateway-17

  # Service VMs (created/ensured by topology role)
  vms:
    sys-net:       { template: fedora-42-minimal, label: red,    provides_network: true }
    sys-firewall:  { template: fedora-42-minimal, label: orange, provides_network: true }
    sys-dns:       { template: fedora-42-minimal, label: yellow, provides_network: true }
    sys-vpn:       { template: fedora-42-minimal, label: black,  provides_network: true }
    sys-whonix:    { template: whonix-gateway-17, label: black,  provides_network: true }

  # Chains (from app side → … → sys-net)
  chains:
    basic:
      order: [sys-firewall, sys-dns]
    vpn_after_dns:
      order: [sys-firewall, sys-dns, sys-vpn]
    vpn_then_tor:
      order: [sys-vpn, sys-whonix]

  # Default (you asked for basic by default)
  active: basic

  # Harden/guard toggles (used by net_guard role)
  guard:
    ipv6_disable: true            # drop/disable IPv6 in NetVMs to avoid v6 leaks
    block_quic: true              # drop UDP/443 in sys-firewall (kills DoH over HTTP/3)
    block_dot:  true              # drop TCP/853 in sys-firewall (clients can’t DoT-bypass)
    enforce_dns_out_only: true    # sys-dns: only UDP/TCP 53 (and optional 853) to Internet
    allow_ntp: true               # allow NTP out of sys-dns (Chrony)
    sys_dns_dot: false            # if true, sys-dns may egress TCP/853 (DoT upstreams)
    sys_dns_allow_ips: []         # optional allowlist of resolver IPs (tightens egress)

    vpn:
      killswitch: true            # sys-vpn: only tun/wg out; allow only VPN endpoints on eth0
      type: wireguard             # 'wireguard'|'openvpn' (for port defaults)
      endpoints:                  # YOU provide your VPN servers (IP is best)
        # - { ip: 203.0.113.10, port: 51820, proto: udp }     # WireGuard example
        # - { ip: 198.51.100.20, port: 1194,  proto: udp }     # OpenVPN example
