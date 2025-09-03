# Create a minimal Fedora-based sys-vpn with OpenVPN/WireGuard and a strict nft killswitch.
# Assumes template 'fedora-41-xfce' exists.

# ---------- Template: clone ----------
fedora-41-vpn-min-present:
  cmd.run:
    - name: |
        /bin/sh -c '
        if ! qvm-ls --raw-list | grep -qx fedora-41-vpn-min; then
          qvm-clone fedora-41-xfce fedora-41-vpn-min
        fi
        '

# ---------- sys-vpn VM ----------
sys-vpn-present:
  cmd.run:
    - name: |
        /bin/sh -c '
        if ! qvm-ls --raw-list | grep -qx sys-vpn; then
          qvm-create -C AppVM -t fedora-41-vpn-min -l green sys-vpn
        fi
        '

sys-vpn-netvm:
  qvm.prefs:
    - name: sys-vpn
    - netvm: sys-net
    - autostart: True
    - provides-network: True
    - require:
      - cmd: sys-vpn-present

# ---------- Packages inside sys-vpn ----------
sys-vpn-install:
  qvm.run:
    - name: sys-vpn
    - user: root
    - cmd: |
        /bin/sh -c '
        dnf -y update
        dnf -y install NetworkManager openvpn NetworkManager-openvpn \
                       wireguard-tools NetworkManager-wireguard \
                       nftables iproute tcpdump curl
        systemctl enable --now NetworkManager
        systemctl enable --now nftables
        '
    - require:
      - qvm: sys-vpn-netvm

# ---------- VPN config staging (optional, if you provide a file) ----------
# Put your file at: /srv/salt/files/vpn/myvpn.ovpn  (dom0)
sys-vpn-stage-ovpn:
  qvm.run:
    - name: sys-vpn
    - user: root
    - cmd: |
        /bin/sh -c '
        install -d -m 0755 /rw/config/vpn
        if [ -s /rw/config/vpn/myvpn.ovpn ]; then
          echo "ovpn already present"
        elif [ -s /home/user/myvpn.ovpn ]; then
          mv /home/user/myvpn.ovpn /rw/config/vpn/myvpn.ovpn
        fi
        '
    - require:
      - qvm: sys-vpn-install

# ---------- NetworkManager import & autostart (only if file is present) ----------
sys-vpn-nm-import:
  qvm.run:
    - name: sys-vpn
    - user: root
    - cmd: |
        /bin/sh -c '
        if [ -s /rw/config/vpn/myvpn.ovpn ]; then
          nmcli --wait 30 connection import type openvpn file /rw/config/vpn/myvpn.ovpn >/tmp/nm-import.log 2>&1 || exit 1
          NAME="$(nmcli -t -f NAME,TYPE connection show | awk -F: "$"\'"'"'$2=="vpn"{print $1; exit}'"\'"'"')"
          [ -n "$NAME" ] && nmcli connection modify "$NAME" connection.autoconnect yes
        fi
        '
    - require:
      - qvm: sys-vpn-stage-ovpn

# ---------- Killswitch (qubes-firewall-user-script) ----------
# You should create /rw/config/vpn/endpoints.txt inside sys-vpn with one IPv4 per line.
# Prefer using numeric IPs in your .ovpn to avoid DNS before the tunnel comes up.
sys-vpn-killswitch:
  qvm.run:
    - name: sys-vpn
    - user: root
    - cmd: |
        /bin/sh -c '
        cat > /rw/config/qubes-firewall-user-script << "EOF"
        #!/bin/sh
        # Early-applied vpn killswitch for Qubes 4.2:
        #  - Allow bootstrap only to VPN endpoint IPs on common ports.
        #  - Allow any egress/forwarding only via tun0.
        #  - Drop everything else (prevents leaks).
        # Endpoints file: /rw/config/vpn/endpoints.txt (one IPv4 per line)

        nft list table ip qubes >/dev/null 2>&1 || exit 0

        # Ensure set exists for endpoints
        if ! nft list set ip qubes vpn_endpoints >/dev/null 2>&1; then
          nft add set ip qubes vpn_endpoints { type ipv4_addr; flags interval; }
        fi

        # Populate from file if present
        if [ -s /rw/config/vpn/endpoints.txt ]; then
          nft flush set ip qubes vpn_endpoints
          while read ip; do
            case "$ip" in ""|\#*) continue;; esac
            nft add element ip qubes vpn_endpoints { $ip }
          done < /rw/config/vpn/endpoints.txt
        fi

        # idempotent add helper
        have_rule() { nft list chain ip qubes "$1" 2>/dev/null | grep -Fq -- "$2"; }

        # OUTPUT (egress from sys-vpn itself)
        # Allow loopback
        have_rule custom-output 'oif "lo" accept' || nft add rule ip qubes custom-output oif "lo" accept
        # Allow VPN bootstrap to endpoints on common ports (adjust as needed)
        have_rule custom-output 'ip daddr @vpn_endpoints udp dport { 1194, 51820 } accept' || \
          nft add rule ip qubes custom-output ip daddr @vpn_endpoints udp dport { 1194, 51820 } accept
        have_rule custom-output 'ip daddr @vpn_endpoints tcp dport 443 accept' || \
          nft add rule ip qubes custom-output ip daddr @vpn_endpoints tcp dport 443 accept
        # Allow anything via the tunnel
        have_rule custom-output 'oif "tun0" accept' || nft add rule ip qubes custom-output oif "tun0" accept
        # Final drop (keep last)
        have_rule custom-output 'counter drop' || nft add rule ip qubes custom-output counter drop

        # FORWARD (traffic from client qubes)
        have_rule custom-forward 'oif "tun0" accept' || nft add rule ip qubes custom-forward oif "tun0" accept
        have_rule custom-forward 'counter drop' || nft add rule ip qubes custom-forward counter drop
        EOF
        chmod +x /rw/config/qubes-firewall-user-script
        systemctl restart qubes-firewall
        '
    - require:
      - qvm: sys-vpn-install

# ---------- Rewire: route DNS through VPN too ----------
sys-dns-through-vpn:
  qvm.prefs:
    - name: sys-dns
    - netvm: sys-vpn
    - require:
      - qvm: sys-vpn-killswitch

# ---------- Verification ----------
sys-vpn-verify:
  qvm.run:
    - name: sys-vpn
    - user: root
    - cmd: |
        /bin/sh -c '
        nmcli -t -f NAME,TYPE,DEVICE connection show --active
        ip -br a
        nft list ruleset >/dev/null
        '
    - require:
      - qvm: sys-dns-through-vpn

summary:
  cmd.run:
    - name: |
        /bin/sh -c '
        printf "\n=== wiring ===\n"
        printf "sys-dns netvm : %s\n" "$(qvm-prefs sys-dns netvm)"
        printf "sys-vpn netvm : %s\n" "$(qvm-prefs sys-vpn netvm)"
        '
    - require:
      - qvm: sys-vpn-verify
