# OPSEC OS EXTRAS: telemetry minimization & hygiene across templates and key service VMs.

{% set deb_templates = ['deb_harden','deb_harden_min','deb_work','deb_dev','deb_personal'] %}
{% set publish_tpl = 'deb_publish' %}

# 0) Drop the README into dom0 for reference
opsec-readme:
  file.managed:
    - name: /usr/local/share/opsec_extra_readme.md
    - mode: '0644'
    - contents_pillar: opsec_extra_readme   # optionally use pillars; else paste the markdown by hand

# 1) Disable persistent journals + coredumps + shell history in Debian templates
{% for t in deb_templates %}
opsec-journal-{{ t }}:
  qvm.run:
    - name: {{ t }}
    - user: root
    - cmd: |
        set -e
        apt-get update -y || true
        # journald volatile
        mkdir -p /etc/systemd/journald.conf.d
        cat >/etc/systemd/journald.conf.d/00-volatile.conf <<'EOF'
        [Journal]
        Storage=volatile
        RuntimeMaxUse=64M
        EOF
        systemctl restart systemd-journald || true
        # disable coredumps
        mkdir -p /etc/systemd/coredump.conf.d
        cat >/etc/systemd/coredump.conf.d/00-disable.conf <<'EOF'
        [Coredump]
        Storage=none
        ProcessSizeMax=0
        EOF
        # kernel dumpable off
        sysctl -w fs.suid_dumpable=0 || true
        echo fs.suid_dumpable=0 > /etc/sysctl.d/99-opsec-nodumps.conf
        # shell history off
        mkdir -p /etc/profile.d
        cat >/etc/profile.d/00-nohistory.sh <<'EOF'
        export HISTFILE=/dev/null
        export HISTSIZE=0
        export HISTCONTROL=ignorespace:ignoredups
        EOF
        # editor backups off (nano/vim)
        sed -i 's/^set backup/# set backup/' /etc/nanorc 2>/dev/null || true
        printf "set nobackup\nset nowritebackup\nset noswapfile\n" >/etc/vim/vimrc.local
{% endfor %}

# 2) UTC timezone + neutral locale (Debian templates)
{% for t in deb_templates %}
opsec-tz-{{ t }}:
  qvm.run:
    - name: {{ t }}
    - user: root
    - cmd: |
        set -e
        apt-get install -y --no-install-recommends tzdata locales || true
        ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
        printf "Etc/UTC\n" >/etc/timezone || true
        sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
        locale-gen || true
        update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
{% endfor %}

# 3) Random hostname per AppVM boot (hook via rc.local in templates)
{% for t in deb_templates %}
opsec-hostname-{{ t }}:
  qvm.run:
    - name: {{ t }}
    - user: root
    - cmd: |
        set -e
        mkdir -p /etc/qubes-rpc
        # ensure /rw/config/rc.local runs
        install -d -m 755 /rw/config
        cat >/rw/config/rc.local <<'EOF'
        #!/bin/sh
        # Randomize hostname per boot (does not affect Qubes VM name)
        new="vm-$(tr -dc a-z0-9 </dev/urandom | head -c8)"
        hostname "$new" 2>/dev/null || true
        echo "$new" >/etc/hostname 2>/dev/null || true
        exit 0
        EOF
        chmod +x /rw/config/rc.local
{% endfor %}

# 4) sys-net hygiene: kill Bluetooth, stop auto-connect, no saved secrets, MAC rand already elsewhere
sys-net-hygiene:
  qvm.run:
    - name: sys-net
    - user: root
    - cmd: |
        set -e
        apt-get update -y || true
        apt-get install -y --no-install-recommends network-manager || true
        systemctl disable --now bluetooth || true
        mkdir -p /etc/NetworkManager/conf.d
        cat >/etc/NetworkManager/conf.d/10-opsec-wifi.conf <<'EOF'
        [connection]
        autoconnect=false
        [wifi]
        mac-address-blacklist=00:00:00:00:00:00
        [device]
        wifi.scan-rand-mac-address=yes
        EOF
        # avoid storing PSKs (use agent prompts only)
        chmod 600 /etc/NetworkManager/system-connections/* 2>/dev/null || true

# 5) Disable suspend/hibernate in dom0 (avoid RAM image on disk)
dom0-nosleep:
  cmd.run:
    - name: |
        set -e
        systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target || true

# 6) Prepare a minimal Debian publish template (tools installed by the next state)
deb-publish-template:
  cmd.run:
    - name: |
        set -e
        qvm-ls --raw-list | grep -qx {{ publish_tpl }} || qvm-clone deb_harden_min {{ publish_tpl }}
        qvm-prefs {{ publish_tpl }} label yellow
