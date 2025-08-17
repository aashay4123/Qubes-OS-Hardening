f42-present:
  cmd.run:
    - name: qvm-ls --raw-list | grep -qx fedora-42-xfce || qvm-template install fedora-42-xfce


fedora42-vpn-template-create:
  cmd.run:
    - name: |
        set -e
        # Pick an available Fedora 42 template (prefer -xfce if present)
        SRC=""
        for s in fedora-42-xfce fedora-42; do
          if qvm-ls --raw-list | grep -qx "$s"; then SRC="$s"; break; fi
        done
        if [ -z "$SRC" ]; then
          # Install base template if missing
          qvm-template install fedora-42-xfce
          SRC="fedora-42"
        fi
        # Clone role template if not present
        if ! qvm-ls --raw-list | grep -qx fedora-42-vpn; then
          qvm-clone "$SRC" fedora-42-vpn
        fi

# 2) Harden the Fedora VPN template (IPv6 off, nftables default-drop, services trimmed)
fedora42-vpn-harden:
  qvm.run:
    - name: fedora-42-vpn
    - user: root
    - cmd: |
        set -e

        # Keep packages current
        dnf -y upgrade --refresh

        # Core hardening + Qubes agents
        dnf -y install \
          qubes-core-agent-networking qubes-core-agent-dom0-updates \
          nftables fail2ban ca-certificates sudo

        update-ca-trust

        # Disable IPv6 globally in the template
        cat >/etc/sysctl.d/99-qubes-ipv6-off.conf <<'EOF'
        net.ipv6.conf.all.disable_ipv6=1
        net.ipv6.conf.default.disable_ipv6=1
        EOF
        sysctl --system || true

        # nftables: default drop inbound; allow loopback + established; output open
        cat >/etc/nftables.conf <<'EOF'
        table inet filter {
          chains = { input, forward, output }
          chain input { type filter hook input priority 0; policy drop;
            ct state {established, related} accept
            iif lo accept
            ip protocol icmp accept
          }
          chain forward { type filter hook forward priority 0; policy drop; }
          chain output { type filter hook output priority 0; policy accept; }
        }
        EOF
        systemctl enable nftables
        systemctl restart nftables

        # Prefer nftables over firewalld
        systemctl disable --now firewalld || true

        # Trim noisy/unused services
        systemctl disable --now avahi-daemon || true
        systemctl disable --now bluetooth || true
        systemctl disable --now cups || true
        systemctl disable --now sshd || true

# 3) Install VPN tooling + GUI (NM applet, OpenVPN, WireGuard) and lock DNS handling
fedora42-vpn-vpnstack:
  qvm.run:
    - name: fedora-42-vpn
    - user: root
    - cmd: |
        set -e
        dnf -y install \
          NetworkManager network-manager-applet nm-connection-editor \
          NetworkManager-openvpn NetworkManager-openvpn-gnome \
          NetworkManager-wireguard-gnome wireguard-tools \
          xterm || true

        # Tell NetworkManager to NOT manage resolv.conf; we will
        mkdir -p /etc/NetworkManager/conf.d
        cat >/etc/NetworkManager/conf.d/00-dns-none.conf <<'EOF'
        [main]
        dns=none
        EOF

        # Stop systemd-resolved if present; assert a local resolv.conf
        systemctl disable --now systemd-resolved || true
        rm -f /etc/resolv.conf
        echo "nameserver 127.0.0.1" > /etc/resolv.conf

        # Quiet NM logs a bit and restart it (template-level)
        nmcli general logging level ERR || true
        systemctl restart NetworkManager || true


# 4) Unattended security updates in the template
fedora42-vpn-auto-updates:
  qvm.run:
    - name: fedora-42-vpn
    - user: root
    - cmd: |
        dnf -y install dnf-automatic
        systemctl enable --now dnf-automatic.timer || true
