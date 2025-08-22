{% from "osi_model_security/map.jinja" import cfg with context %}
{% set op = cfg.opsec %}
{% if not op.enable %}{% do salt['test.succeed_without_changes']('opsec-disabled') %}{% endif %}

{% set deb_templates = op.get('deb_templates', []) %}

# ---- 1) Debian template hygiene: volatile journals, no coredumps, no shell history ----
{% for t in deb_templates %}
opsec-journal-{{ t }}:
  module.run:
    - name: qvm.run
    - vm: {{ t }}
    - args:
      - |
        sh -lc '
          set -e
          if command -v apt-get >/dev/null; then
            apt-get update -y || true
            # journald volatile
            mkdir -p /etc/systemd/journald.conf.d
            cat >/etc/systemd/journald.conf.d/00-volatile.conf <<EOF
            [Journal]
            Storage=volatile
            RuntimeMaxUse=64M
            EOF
            systemctl restart systemd-journald || true
            # disable coredumps
            mkdir -p /etc/systemd/coredump.conf.d
            cat >/etc/systemd/coredump.conf.d/00-disable.conf <<EOF
            [Coredump]
            Storage=none
            ProcessSizeMax=0
            EOF
            # kernel dumpable off
            sysctl -w fs.suid_dumpable=0 || true
            echo fs.suid_dumpable=0 >/etc/sysctl.d/99-opsec-nodumps.conf
            # shell history off
            mkdir -p /etc/profile.d
            cat >/etc/profile.d/00-nohistory.sh <<EOF
            export HISTFILE=/dev/null
            export HISTSIZE=0
            export HISTCONTROL=ignorespace:ignoredups
            EOF
            # editor backups off
            sed -i "s/^set backup/# set backup/" /etc/nanorc 2>/dev/null || true
            printf "set nobackup\nset nowritebackup\nset noswapfile\n" >/etc/vim/vimrc.local
          fi
        '
{% endfor %}

# ---- 2) UTC timezone + neutral locale (Debian templates) ----
{% if op.get('set_utc_and_locale', True) %}
{% for t in deb_templates %}
opsec-tz-{{ t }}:
  module.run:
    - name: qvm.run
    - vm: {{ t }}
    - args:
      - |
        sh -lc '
          if command -v apt-get >/dev/null; then
            apt-get install -y --no-install-recommends tzdata locales || true
            ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
            printf "Etc/UTC\n" >/etc/timezone || true
            sed -i "s/^# *en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
            locale-gen || true
            update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
          fi
        '
{% endfor %}
{% endif %}

# ---- 3) Random hostname per boot (systemd unit so it works in AppVMs) ----
{% if op.get('randomize_hostname', True) %}
{% for t in deb_templates %}
opsec-hostname-{{ t }}:
  module.run:
    - name: qvm.run
    - vm: {{ t }}
    - args:
      - |
        sh -lc '
          cat >/usr/local/sbin/qubes-random-hostname << "EOF"
          #!/bin/sh
          new="vm-$(tr -dc a-z0-9 </dev/urandom | head -c8)"
          hostname "$new" 2>/dev/null || true
          printf "%s\n" "$new" >/etc/hostname 2>/dev/null || true
          EOF
          chmod 0755 /usr/local/sbin/qubes-random-hostname
          cat >/etc/systemd/system/qubes-random-hostname.service << "EOF"
          [Unit]
          Description=Randomize hostname at boot
          After=network-pre.target
          [Service]
          Type=oneshot
          ExecStart=/usr/local/sbin/qubes-random-hostname
          [Install]
          WantedBy=multi-user.target
          EOF
          systemctl enable qubes-random-hostname.service || true
        '
{% endfor %}
{% endif %}

# ---- 4) sys-net hygiene (Fedora or Debian templates) ----
sys-net-hygiene:
  module.run:
    - name: qvm.run
    - vm: {{ op.get('sysnet_name','sys-net') }}
    - args:
      - |
        sh -lc '
          if command -v dnf >/dev/null; then
            dnf -y install NetworkManager || true
            systemctl disable --now bluetooth || true
            mkdir -p /etc/NetworkManager/conf.d
            cat >/etc/NetworkManager/conf.d/10-opsec-wifi.conf <<EOF
            [connection]
            autoconnect=false
            [wifi]
            mac-address-blacklist=00:00:00:00:00:00
            [device]
            wifi.scan-rand-mac-address=yes
            EOF
          elif command -v apt-get >/dev/null; then
            apt-get update -y || true
            apt-get install -y --no-install-recommends network-manager || true
            systemctl disable --now bluetooth || true
            mkdir -p /etc/NetworkManager/conf.d
            cat >/etc/NetworkManager/conf.d/10-opsec-wifi.conf <<EOF
            [connection]
            autoconnect=false
            [wifi]
            mac-address-blacklist=00:00:00:00:00:00
            [device]
            wifi.scan-rand-mac-address=yes
            EOF
          fi
          chmod 600 /etc/NetworkManager/system-connections/* 2>/dev/null || true
        '

# ---- 5) dom0: disable sleep/hibernate ----
{% if op.get('dom0_disable_sleep', True) %}
dom0-nosleep:
  cmd.run:
    - name: |
        set -e
        systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target || true
{% endif %}
