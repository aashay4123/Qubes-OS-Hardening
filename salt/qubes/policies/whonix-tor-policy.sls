# /srv/salt/qubes/policies/maint_tool.sls
/etc/qubes/policy.d/50-whonix-vpn-tor.policy:
  file.managed:
    - mode: '0755'
    - contents: |
          # ws-tor-research may only use sys-vpn-tor as its NetVM gateway (soft guard)
          qubes.ConnectTCP +ws-tor-research @default deny
          qubes.ConnectTCP +ws-tor-research +sys-vpn-tor allow

          # ws-tor-forums may only use sys-vpn-tor too (you can split later if needed)
          qubes.ConnectTCP +ws-tor-forums @default deny
          qubes.ConnectTCP +ws-tor-forums +sys-vpn-tor allow
