# Hardened Debian 12 template (base for all other Debian templates)

ensure-debian12:
  cmd.run:
    - name: qvm-ls --raw-list | grep -qx debian-12-xfce || qvm-template install debian-12

deb_harden-clone:
  cmd.run:
    - name: qvm-ls --raw-list | grep -qx deb_harden || qvm-clone debian-12-xfce deb_harden

deb_harden-hardening:
  qvm.run:
    - name: deb_harden
    - user: root
    - cmd: |
        set -e
        apt-get update
        apt-get -y full-upgrade
        apt-get -y install --no-install-recommends \
          apparmor apparmor-profiles apparmor-utils \
          ca-certificates debsums unattended-upgrades needrestart \
          nftables fail2ban sudo curl wget rsync \
          qubes-core-agent-networking qubes-core-agent-dom0-updates
        update-ca-certificates

        #  Apparmor Enable
        mkdir -p /etc/default/grub.d
        echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet apparmor=1 security=apparmor"' > /etc/default/grub.d/apparmor.cfg || true
        update-grub || true

        # apt-secure-and-auto:
        dpkg-reconfigure -f noninteractive unattended-upgrades
        sed -i 's|^//Unattended-Upgrade::Remove-Unused-Dependencies.*|Unattended-Upgrade::Remove-Unused-Dependencies "true";|' /etc/apt/apt.conf.d/50unattended-upgrades        

        # sysctl-hardening:
        cat >/etc/sysctl.d/99-qubes-hardening.conf <<'EOF'
        kernel.kptr_restrict=1
        kernel.unprivileged_bpf_disabled=1
        kernel.dmesg_restrict=1
        net.ipv4.conf.all.rp_filter=1
        net.ipv4.conf.default.rp_filter=1
        net.ipv4.conf.all.accept_redirects=0
        net.ipv4.conf.default.accept_redirects=0
        net.ipv4.conf.all.send_redirects=0
        net.ipv4.conf.default.send_redirects=0
        net.ipv4.tcp_syncookies=1
        net.ipv6.conf.all.accept_ra=0
        net.ipv6.conf.default.accept_ra=0
        net.ipv6.conf.all.accept_redirects=0
        net.ipv6.conf.default.accept_redirects=0
        fs.protected_hardlinks=1
        fs.protected_symlinks=1
        EOF
        sysctl --system || true

        # IPv6 OFF
        cat >/etc/sysctl.d/99-qubes-ipv6-off.conf <<'EOF'
        net.ipv6.conf.all.disable_ipv6=1
        net.ipv6.conf.default.disable_ipv6=1
        EOF
        sysctl --system || true

        # nftables default: drop inbound, allow loopback/established; output open
        mkdir -p /etc/nftables.d
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

        # Minimize attack surface
        systemctl disable --now avahi-daemon || true
        systemctl disable --now cups || true
        systemctl disable --now bluetooth || true
        systemctl disable --now ssh || true
        apt-get -y purge telnetd xinetd rsh-server rlogin openssh-server || true
        apt-get -y autoremove --purge


# Debian caller template
deb-harden-split-clients:
  qvm.run:
    - name: deb_harden
    - user: root
    - cmd: |
        set -e
        apt-get update -y || true
        apt-get install -y --no-install-recommends \
          qubes-gpg-client qubes-app-linux-split-ssh

# Debian callers
deb-harden-client-env:
  qvm.run:
    - name: deb_harden
    - user: root
    - cmd: |
        set -e
        cat >/etc/profile.d/20-split-gpg.sh <<'EOF'
        export GPG_TTY=$(tty 2>/dev/null || echo)
        alias gpg='qubes-gpg-client-wrapper'
        EOF
        cat >/etc/profile.d/20-split-ssh.sh <<'EOF'
        # Start proxy if present; otherwise user can run: systemctl --user start qubes-ssh-agent-proxy
        if systemctl --user list-unit-files 2>/dev/null | grep -q qubes-ssh-agent-proxy; then
          systemctl --user enable --now qubes-ssh-agent-proxy.socket qubes-ssh-agent-proxy.service 2>/dev/null || true
        fi
        EOF
