# Qubes OPSEC "micro-normalizers" in one place
# - TTL=128 on egress (Windows-like)
# - TCP/IP small normalizations (timestamps, window scaling, safe r/w mem hints)
# - Block QUIC (UDP/443) at the edge
# - Realistic MAC OUI helper in sys-net (+ stable per-boot suffix)
# - Kill mDNS/Avahi & make journals volatile in templates
# - Mount /tmp, /var/tmp, /var/log as tmpfs in AppVMs (evaporate traces)
# - Random Windows-like hostname per boot in AppVMs
# - Lock consistent GUI resolution (letterbox) for chosen VMs
# - Kernel module drift detector in sys-firewall (alerts to sys-alert)
# - Pause tool to temporarily lift net normalizers for 300s if needed

{% set EDGE_VMS = ['sys-firewall','sys-net'] %}
{% set DEB_TEMPLATES = ['deb_harden','deb_harden_min','deb_work','deb_dev','deb_personal'] %}
{% set LETTERBOX_VMS = ['disp-windows-tor'] %}   # add more VMs if you want fixed 1920x1080
{% set OUI_DEFAULT = '3C:FD:FE' %}               # Intel OUI; change if you prefer Realtek (00:E0:4C)

# ---------- A) sys-firewall: TTL=128 + QUIC drop ----------
{% for vm in ['sys-firewall'] %}
ttl128-and-quic-{{ vm }}:
  qvm.run:
    - name: {{ vm }}
    - user: root
    - cmd: |
        set -e
        mkdir -p /etc/nftables.d
        # TTL normalize to 128 (Windows-like)
        cat >/etc/nftables.d/20-ttl-128.nft <<'EOF'
        table inet ttlfix {
          chain set_ttl {
            type filter hook postrouting priority 0; policy accept;
            ip ttl set 128
          }
        }
        EOF
        # Block QUIC (UDP 443) universally
        cat >/etc/nftables.d/30-no-quic.nft <<'EOF'
        table inet noquic {
          chain drop_quic {
            type filter hook prerouting priority 0; policy accept;
            udp dport 443 drop
          }
        }
        EOF
        echo 'include "/etc/nftables.d/*.nft"' >/etc/nftables.conf
        systemctl enable nftables
        systemctl restart nftables || true
{% endfor %}

# ---------- B) sys-net: OUI helper + small TCP sysctl hygiene ----------
sysnet-oui-helper:
  qvm.run:
    - name: sys-net
    - user: root
    - cmd: |
        set -e
        apt-get update -y || true
        apt-get install -y --no-install-recommends network-manager || true
        install -d -m 755 /usr/local/sbin
        # Store OUI prefix once (editable later by you)
        [ -f /rw/config/oui_prefix ] || echo "{{ OUI_DEFAULT }}" > /rw/config/oui_prefix
        cat >/usr/local/sbin/apply-oui <<'EOF'
        #!/bin/sh
        set -e
        OUI=$(cat /rw/config/oui_prefix 2>/dev/null | tr -d '\n')
        [ -n "$OUI" ] || OUI="{{ OUI_DEFAULT }}"
        suf=$(printf ":%02X:%02X:%02X" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
        MAC="$OUI$suf"
        IF=$(nmcli -t -f DEVICE,TYPE dev | awk -F: '$2=="wifi"||$2=="ethernet"{print $1; exit}')
        UUID=$(nmcli -t -f UUID c show --active | head -n1)
        [ -z "$UUID" ] && UUID=$(nmcli -t -f UUID c show | head -n1)
        [ -n "$UUID" ] || exit 0
        nmcli connection modify "$UUID" ethernet.cloned-mac-address "$MAC"
        nmcli connection modify "$UUID" wifi.cloned-mac-address "$MAC"
        nmcli connection up "$UUID" || true
        echo "$MAC" > /rw/config/current_mac
        EOF
        chmod +x /usr/local/sbin/apply-oui
        # Run once per boot from rc.local
        install -d -m 755 /rw/config
        if ! grep -q apply-oui /rw/config/rc.local 2>/dev/null; then
          cat >>/rw/config/rc.local <<'EOF'
          #!/bin/sh
          /usr/local/sbin/apply-oui || true
          exit 0
          EOF
          chmod +x /rw/config/rc.local
        fi
        # Small TCP/IP hygiene (doesn't break Tor/VPN)
        cat >/etc/sysctl.d/98-net-hygiene.conf <<'EOF'
        net.ipv4.tcp_timestamps=1
        net.ipv4.tcp_window_scaling=1
        net.ipv4.tcp_sack=1
        net.ipv4.tcp_rmem=4096 87380 6291456
        net.ipv4.tcp_wmem=4096 65536 6291456
        EOF
        sysctl --system || true

# Kill Bluetooth & mDNS at edge
edge-daemons-trim:
  qvm.run:
    - name: sys-net
    - user: root
    - cmd: |
        systemctl disable --now bluetooth || true
        systemctl disable --now avahi-daemon || true

# ---------- C) Templates: volatile logs/tmp, no mDNS, no coredumps, random hostname ----------
{% for t in DEB_TEMPLATES %}
tmpl-volatile-{{ t }}:
  qvm.run:
    - name: {{ t }}
    - user: root
    - cmd: |
        set -e
        apt-get update -y || true
        apt-get install -y --no-install-recommends systemd-sysv locales || true

        # Journald volatile
        mkdir -p /etc/systemd/journald.conf.d
        cat >/etc/systemd/journald.conf.d/00-volatile.conf <<'EOF'
        [Journal]
        Storage=volatile
        RuntimeMaxUse=64M
        EOF
        systemctl restart systemd-journald || true

        # Disable mDNS/Avahi, coredumps, and suid dumps
        systemctl disable --now avahi-daemon || true
        mkdir -p /etc/systemd/coredump.conf.d
        cat >/etc/systemd/coredump.conf.d/00-disable.conf <<'EOF'
        [Coredump]
        Storage=none
        ProcessSizeMax=0
        EOF
        echo fs.suid_dumpable=0 > /etc/sysctl.d/99-opsec-nodumps.conf
        sysctl --system || true

        # AppVM boot-time: mount tmpfs for tmp and logs; randomize hostname; UTC + en_US
        install -d -m 755 /rw/config
        cat >/rw/config/rc.local <<'EOF'
        #!/bin/sh
        # tmpfs mounts
        mountpoint -q /tmp || mount -t tmpfs -o mode=1777,size=256M tmpfs /tmp
        mountpoint -q /var/tmp || mount -t tmpfs -o mode=1777,size=128M tmpfs /var/tmp
        mountpoint -q /var/log || mount -t tmpfs -o size=128M tmpfs /var/log
        # hostname random (Windows-like prefix)
        new="DESKTOP-$(tr -dc A-Z0-9 </dev/urandom | head -c7)"
        hostname "$new" 2>/dev/null || true
        echo "$new" >/etc/hostname 2>/dev/null || true
        # UTC + neutral locale
        ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
        printf "Etc/UTC\n" >/etc/timezone 2>/dev/null || true
        if [ -f /etc/locale.gen ]; then
          sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen || true
          locale-gen || true
          update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 || true
        fi
        exit 0
        EOF
        chmod +x /rw/config/rc.local
{% endfor %}

# ---------- D) Fix GUI geometry (letterbox) for specific VMs ----------
{% for v in LETTERBOX_VMS %}
gui-geometry-{{ v }}:
  cmd.run:
    - name: qvm-features {{ v }} gui-default-geometry 1920x1080+0+0
    - unless: test "$(qvm-features {{ v }} gui-default-geometry 2>/dev/null | awk '{print $NF}')" = "1920x1080+0+0"
{% endfor %}

# ---------- E) Kernel module drift detector in sys-firewall (cheap integrity canary) ----------
mod-drift-check:
  qvm.run:
    - name: sys-firewall
    - user: root
    - cmd: |
        set -e
        install -d -m 755 /usr/local/sbin
        cat >/usr/local/sbin/check-mod-drift.sh <<'EOF'
        #!/bin/sh
        set -e
        mkdir -p /rw/state
        cur=/rw/state/modules.cur
        prev=/rw/state/modules.prev
        cat /proc/modules | awk '{print $1,$2,$3,$6}' | sort > "$cur"
        if [ -f "$prev" ]; then
          DIFF=$(diff -u "$prev" "$cur" || true)
          if [ -n "$DIFF" ]; then
            printf "%s\n%s\n" "[mod-drift] Kernel module set changed in sys-firewall:" "$DIFF" | qrexec-client-vm sys-alert my.alert.Send || true
          fi
        fi
        cp -f "$cur" "$prev"
        EOF
        chmod +x /usr/local/sbin/check-mod-drift.sh
        # timer daily + at boot
        cat >/etc/systemd/system/mod-drift.service <<'EOF'
        [Unit] Description=Kernel module drift check
        [Service] Type=oneshot ExecStart=/usr/local/sbin/check-mod-drift.sh
        EOF
        cat >/etc/systemd/system/mod-drift.timer <<'EOF'
        [Unit] Description=Daily kernel module drift check
        [Timer] OnBootSec=2min OnUnitActiveSec=24h Persistent=true
        [Install] WantedBy=timers.target
        EOF
        systemctl daemon-reload
        systemctl enable --now mod-drift.timer || true

# ---------- F) Pause/Resume tool in sys-firewall to lift net locks briefly ----------
pause-normalize:
  qvm.run:
    - name: sys-firewall
    - user: root
    - cmd: |
        set -e
        install -d -m 755 /usr/local/sbin
        cat >/usr/local/sbin/pause-normalize <<'EOF'
        #!/bin/sh
        D="${1:-300}"
        echo "[normalize] Pausing TTL/QUIC locks for $D seconds..."
        nft list table inet ttlfix >/dev/null 2>&1 && nft delete table inet ttlfix || true
        nft list table inet noquic >/dev/null 2>&1 && nft delete table inet noquic || true
        sleep "$D"
        echo 'include "/etc/nftables.d/*.nft"' >/etc/nftables.conf
        systemctl restart nftables || true
        echo "[normalize] Restored."
        EOF
        chmod +x /usr/local/sbin/pause-normalize
