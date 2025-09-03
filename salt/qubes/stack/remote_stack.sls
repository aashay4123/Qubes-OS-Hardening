{# ==============================
   One-file remote stack for Qubes 4.2
   Apply on dom0:   sudo qubesctl state.apply remote_stack
   Apply on sys-net: sudo qubesctl --targets sys-net state.apply remote_stack
   Adjust IPs/gateway below as needed.
   ============================== #}

{%- set DOM0_USER = "user" %}
{%- set SYSNET_NAME = "sys-net" %}
{%- set SYSNET_IP = "192.168.1.74" %}
{%- set SYSNET_MASK = "255.255.255.0" %}
{%- set SYSNET_GW = "192.168.1.1" %}

{%- if grains['id'] == 'dom0' %}

# ============================
# DOM0 SIDE
# ============================

# 1) RPC handler: user.vnc-dom0  (stdin/stdout <-> dom0:5901 via socat)
dom0_rpc_handler_vnc:
  file.managed:
    - name: /etc/qubes/rpc/user.vnc-dom0
    - mode: 0755
    - user: root
    - group: root
    - contents: |
        #!/bin/sh
        exec /usr/bin/socat STDIO TCP:127.0.0.1:5901

# 2) Policy: allow sys-net to call it
dom0_policy_vnc_allow:
  file.managed:
    - name: /etc/qubes/policy.d/50-vnc-dom0.policy
    - mode: 0644
    - user: root
    - group: root
    - contents: |
        user.vnc-dom0  {{ SYSNET_NAME }}  dom0  allow

reload_qrexec_daemon:
  cmd.run:
    - name: systemctl reload qubes-qrexec-policy-daemon
    - onchanges:
      - file: dom0_rpc_handler_vnc
      - file: dom0_policy_vnc_allow

# 3) Helper scripts in dom0 user’s bin
dom0_bin_dir:
  file.directory:
    - name: /home/{{ DOM0_USER }}/bin
    - user: {{ DOM0_USER }}
    - group: {{ DOM0_USER }}
    - mode: 0755

# 3a) all-in-one remote GUI helper
dom0_remote_gui_script:
  file.managed:
    - name: /home/{{ DOM0_USER }}/bin/qubes-remote-gui.sh
    - user: {{ DOM0_USER }}
    - group: {{ DOM0_USER }}
    - mode: 0755
    - contents: |
        #!/usr/bin/env bash
        set -euo pipefail
        D="${DISPLAYNUM:-1}"
        GEOMETRY="${GEOMETRY:-2880x1800}"
        DEPTH="${DEPTH:-24}"
        VNC_AUTH="${VNC_AUTH:-$HOME/.vnc/passwd}"
        SHM_LIB="/usr/lib64/qubes/libshmoverride.so"; [ -f "$SHM_LIB" ] || SHM_LIB="/usr/lib/qubes/libshmoverride.so"
        say(){ printf '\033[1;36m%s\033[0m\n' "$*"; }
        port(){ echo $((5900 + D)); }
        need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }

        ensure_vnc(){
          need Xvnc
          [ -f "$VNC_AUTH" ] || { echo "No VNC password ($VNC_AUTH). Run: vncpasswd"; exit 1; }
          pkill -f "Xvnc :$D" 2>/dev/null || true
          LD_PRELOAD="$SHM_LIB" Xvnc ":$D" -geometry "$GEOMETRY" -depth "$DEPTH" \
            -localhost -rfbport "$(port)" -rfbauth "$VNC_AUTH" -SecurityTypes VncAuth \
            -AlwaysShared -AcceptKeyEvents -AcceptPointerEvents -AcceptCutText -SendCutText -IdleTimeout=0 >/dev/null 2>&1 &
          sleep 1
          sudo mkdir -p /run/qubes
          [ -e "/run/qubes/shm.id.$D" ] || echo "WARN: /run/qubes/shm.id.$D missing (check $SHM_LIB)"
        }

        attach_one(){
          local vm="$1"; local id; id=$(qvm-domid "$vm" 2>/dev/null || true); [ -n "$id" ] || return 0
          pgrep -f "qubes-guid -d ${id}\b" >/dev/null && return 0
          DISPLAY=":$D" qubes-guid -d "$id" -N "$vm" -q -f &
        }
        attach_all(){ for vm in $(qvm-ls --raw-list --running); do attach_one "$vm"; done; }

        panel_on(){ DISPLAY=":$D" pkill xfce4-panel 2>/dev/null || true; DISPLAY=":$D" nohup xfce4-panel >/dev/null 2>&1 & }
        manager_on(){ DISPLAY=":$D" nohup qubes-qube-manager >/dev/null 2>&1 & }

        alerts_on(){
          export DISPLAY=":$D"
          # ensure a user session D-Bus
          if ! gdbus call --session --dest org.freedesktop.DBus --object-path / \
               --method org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
            eval "$(dbus-launch --sh-syntax)"
          fi
          # pick notifier (xfce4-notifyd preferred)
          NB=""
          for p in /usr/libexec/xfce4/notifyd/xfce4-notifyd /usr/bin/xfce4-notifyd /usr/bin/dunst; do
            [ -x "$p" ] && NB="$p" && break
          done
          [ -n "$NB" ] || { echo "No notifier found"; return 0; }
          mkdir -p ~/.local/share/dbus-1/services
          cat > ~/.local/share/dbus-1/services/org.freedesktop.Notifications.service <<EOF
        [D-BUS Service]
        Name=org.freedesktop.Notifications
        Exec=$NB
        EOF
          pkill -x xfce4-notifyd 2>/dev/null || true; pkill -x dunst 2>/dev/null || true
          nohup "$NB" >/dev/null 2>&1 &
        }

        case "${1:-}" in
          on) ensure_vnc; attach_all; panel_on; alerts_on; manager_on; say "VNC ready on localhost:$(port)";;
          off) DISPLAY=":$D" pkill xfce4-panel 2>/dev/null || true; pkill xfce4-notifyd 2>/dev/null || true; pkill -f "DISPLAY=:$D .*qubes-guid" 2>/dev/null || true; pkill -f "Xvnc :$D" 2>/dev/null || true;;
          attach) attach_all;;
          alerts) alerts_on;;
          panel) panel_on;;
          manager) manager_on;;
          *) echo "Usage: $(basename "$0") [on|off|attach|alerts|panel|manager]"; exit 1;;
        esac

# 4) Enforce static IP for sys-net via Qubes properties (idempotent)
sysnet_provides_network_true:
  cmd.run:
    - name: qvm-prefs {{ SYSNET_NAME }} provides_network True
    - unless: test "$(qvm-prefs -g {{ SYSNET_NAME }} provides_network)" = "True"

sysnet_ip_set:
  cmd.run:
    - name: qvm-prefs {{ SYSNET_NAME }} ip {{ SYSNET_IP }}
    - unless: test "$(qvm-prefs -g {{ SYSNET_NAME }} ip)" = "{{ SYSNET_IP }}"

sysnet_netmask_set:
  cmd.run:
    - name: qvm-prefs {{ SYSNET_NAME }} netmask {{ SYSNET_MASK }}
    - unless: test "$(qvm-prefs -g {{ SYSNET_NAME }} netmask)" = "{{ SYSNET_MASK }}"

sysnet_gateway_set:
  cmd.run:
    - name: qvm-prefs {{ SYSNET_NAME }} gateway {{ SYSNET_GW }}
    - unless: test "$(qvm-prefs -g {{ SYSNET_NAME }} gateway)" = "{{ SYSNET_GW }}"

{%- else %}

# ============================
# SYS-NET SIDE
# ============================

# 1) VNC relay service (127.0.0.1:5901 -> dom0:5901 via qrexec)
vnc_relay_unit:
  file.managed:
    - name: /etc/systemd/system/qubes-vnc-relay.service
    - mode: 0644
    - user: root
    - group: root
    - contents: |
        [Unit]
        Description=Qubes VNC relay (local 5901 -> dom0:5901 via qrexec)
        After=network-online.target

        [Service]
        ExecStart=/usr/bin/socat TCP-LISTEN:5901,bind=127.0.0.1,reuseaddr,fork EXEC:'qrexec-client-vm -T dom0 user.vnc-dom0'
        Restart=always

        [Install]
        WantedBy=multi-user.target

vnc_relay_enable:
  service.enabled:
    - name: qubes-vnc-relay.service
    - enable: True

vnc_relay_running:
  service.running:
    - name: qubes-vnc-relay.service
    - enable: True
    - watch:
      - file: vnc_relay_unit

# 2) SSH server (you use it to hop in from Mac)
sshd_pkg:
  pkg.installed:
    - pkgs:
      - openssh-server

sshd_enable:
  service.enabled:
    - name: sshd

sshd_running:
  service.running:
    - name: sshd
    - enable: True

# 3) Persistent nft/iptables hook stub
rw_config_dir:
  file.directory:
    - name: /rw/config
    - mode: 0755

rc_local_file:
  file.managed:
    - name: /rw/config/rc.local
    - mode: 0755
    - contents: |
        #!/bin/sh
        # Add your persistent nftables/iptables here, e.g.:
        # nft add table inet mytbl || true
        # nft add chain inet mytbl preroute { type filter hook prerouting priority 0\; } || true
        # logger -t rc.local "sys-net rc.local executed"

{%- endif %}
