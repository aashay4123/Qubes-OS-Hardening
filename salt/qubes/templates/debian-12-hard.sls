# Hardened Debian 12 template (no nftables, no qvm.prefs)
# Source: debian-12-xfce  -> Target: debian-12-hard

debian-12-xfce-installed:
  qvm.template_installed:
    - name: debian-12-xfce

debian-12-hard-present:
  qvm.clone:
    - name: debian-12-hard
    - source: debian-12-xfce
    - require:
      - qvm: debian-12-xfce-installed

# --- Base update/upgrade & core hardening pkgs (no shell wrappers needed) ---

debian-12-hard-apt-update:
  qvm.run:
    - name: debian-12-hard
    - user: root
    - cmd: apt-get update
    - require:
      - qvm: debian-12-hard-present

debian-12-hard-dist-upgrade:
  qvm.run:
    - name: debian-12-hard
    - user: root
    - cmd: env DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade
    - require:
      - qvm: debian-12-hard-apt-update

debian-12-hard-install-core:
  qvm.run:
    - name: debian-12-hard
    - user: root
    - cmd: >
        env DEBIAN_FRONTEND=noninteractive apt-get -y install
        apparmor apparmor-utils apparmor-profiles apparmor-profiles-extra
        auditd audispd-plugins
        needrestart unattended-upgrades debsecan debsums
        libpam-tmpdir sudo
        curl wget ca-certificates gnupg
    - require:
      - qvm: debian-12-hard-dist-upgrade

# --- APT config files written via /bin/sh -c with proper heredocs (YAML literal blocks!) ---

debian-12-hard-apt-hardening:
  qvm.run:
    - name: debian-12-hard
    - user: root
    - cmd: |
        /bin/sh -c "cat > /etc/apt/apt.conf.d/99hardening << 'EOF'
        APT::Get::Assume-Yes \"true\";
        APT::Install-Recommends \"false\";
        APT::Install-Suggests \"false\";
        Acquire::http::Pipeline-Depth \"0\";
        EOF
        chmod 0644 /etc/apt/apt.conf.d/99hardening"
    - require:
      - qvm: debian-12-hard-install-core

debian-12-hard-unattended-setup:
  qvm.run:
    - name: debian-12-hard
    - user: root
    - cmd: |
        /bin/sh -c "cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
        APT::Periodic::Update-Package-Lists \"1\";
        APT::Periodic::Unattended-Upgrade \"1\";
        EOF
        chmod 0644 /etc/apt/apt.conf.d/20auto-upgrades"
    - require:
      - qvm: debian-12-hard-install-core

# verify APT configuration parses
debian-12-hard-apt-verify:
  qvm.run:
    - name: debian-12-hard
    - user: root
    - cmd: apt-get update
    - require:
      - qvm: debian-12-hard-apt-hardening
      - qvm: debian-12-hard-unattended-setup

# --- System hardening (safe, conservative) ---

debian-12-hard-sysctl:
  qvm.run:
    - name: debian-12-hard
    - user: root
    - cmd: |
        /bin/sh -c "cat > /etc/sysctl.d/90-hardening.conf << 'EOF'
        kernel.kptr_restrict=2
        kernel.dmesg_restrict=1
        kernel.unprivileged_bpf_disabled=1
        kernel.kexec_load_disabled=1
        kernel.yama.ptrace_scope=1
        fs.protected_hardlinks=1
        fs.protected_symlinks=1
        vm.mmap_min_addr=65536
        net.ipv4.conf.all.rp_filter=1
        net.ipv4.conf.default.rp_filter=1
        net.ipv4.conf.all.accept_redirects=0
        net.ipv4.conf.default.accept_redirects=0
        net.ipv4.conf.all.send_redirects=0
        net.ipv4.conf.default.send_redirects=0
        net.ipv4.icmp_echo_ignore_bogus_error_responses=1
        net.ipv4.icmp_echo_ignore_broadcasts=1
        net.ipv4.tcp_syncookies=1
        net.ipv6.conf.all.accept_redirects=0
        net.ipv6.conf.default.accept_redirects=0
        net.ipv6.conf.all.accept_ra=0
        net.ipv6.conf.default.accept_ra=0
        EOF
        chmod 0644 /etc/sysctl.d/90-hardening.conf;
        sysctl --system || true"
    - require:
      - qvm: debian-12-hard-apt-verify

# apply AppArmor profiles if tool is present
debian-12-hard-aa-enforce:
  qvm.run:
    - name: debian-12-hard
    - user: root
    - cmd: /bin/sh -c 'command -v aa-enforce >/dev/null 2>&1 && aa-enforce /etc/apparmor.d/* || true'
    - require:
      - qvm: debian-12-hard-install-core

# remove unneeded daemons in templates
debian-12-hard-purge-noisy:
  qvm.run:
    - name: debian-12-hard
    - user: root
    - cmd: |
        /bin/sh -c "env DEBIAN_FRONTEND=noninteractive apt-get -y purge \
        avahi-daemon cups-browsed cups exim4 rpcbind nfs-common || true; \
        apt-get -y autoremove --purge || true; apt-get -y clean || true"
    - require:
      - qvm: debian-12-hard-install-core

# enable auditd at boot (idempotent)
debian-12-hard-auditd-enable:
  qvm.run:
    - name: debian-12-hard
    - user: root
    - cmd: /bin/sh -c 'systemctl is-enabled auditd >/dev/null 2>&1 || systemctl enable auditd'
    - require:
      - qvm: debian-12-hard-install-core

# reduce core dumps
debian-12-hard-no-core:
  qvm.run:
    - name: debian-12-hard
    - user: root
    - cmd: |
        /bin/sh -c "install -d -m 0755 /etc/security/limits.d; \
        echo '* hard core 0' > /etc/security/limits.d/99-no-core.conf; \
        chmod 0644 /etc/security/limits.d/99-no-core.conf"

# lock root (tolerate already-locked)
debian-12-hard-lock-root:
  qvm.run:
    - name: debian-12-hard
    - user: root
    - cmd: /bin/sh -c 'passwd -S root 2>/dev/null | grep -q " L " || passwd -l root || /usr/sbin/usermod -L root || true'
