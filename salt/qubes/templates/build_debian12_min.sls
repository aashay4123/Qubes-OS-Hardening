# Minimal hardened Debian 12 template for service VMs (sys-net/sys-firewall/etc)

deb_harden_min-clone:
  cmd.run:
    - name: qvm-ls --raw-list | grep -qx deb_harden_min || qvm-clone deb_harden deb_harden_min

deb_harden_min-minimize:
  qvm.run:
    - name: deb_harden_min
    - user: root
    - cmd: |
        set -e
        # Purge desktop/DM if present (idempotent)
        apt-get -y purge xfce4* lightdm* xorg* || true
        apt-get -y autoremove --purge || true
        apt-get update
        apt-get -y install --no-install-recommends \
          qubes-core-agent-networking qubes-core-agent-dom0-updates \
          network-manager nftables
        mkdir   -p /etc/nftables.d
        cat >/etc/nftables.d/60-dnslock.nft <<'EOF'
        table inet tmpl_dnslock {
          chain output {
            type filter hook output priority 0; policy accept;
            udp dport 53 ip daddr != 127.0.0.1 drop
            tcp dport 53 ip daddr != 127.0.0.1 drop
          }
        }
        EOF
        if ! grep -q 'include "/etc/nftables.d/\*\.nft"' /etc/nftables.conf 2>/dev/null; then
          echo 'include "/etc/nftables.d/*.nft"' > /etc/nftables.conf
        fi
        systemctl enable nftables
        systemctl restart nftables

nm-randomize-mac:
  qvm.run:
    - name: deb12-net-min
    - user: root
    - cmd: |
        mkdir -p /etc/NetworkManager/conf.d
        cat >/etc/NetworkManager/conf.d/00-macrandomize.conf <<'EOF'
        [connection]
        wifi.mac-address-randomization=1
        ethernet.cloned-mac-address=random
        wifi.cloned-mac-address=random
        [device]
        wifi.scan-rand-mac-address=yes
        EOF
        systemctl restart NetworkManager || true
