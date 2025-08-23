{# ---------- Pillar / defaults ---------- #}
{% set R = pillar.get('remote_gui', {}) %}
{% set ADMIN = R.get('admin_user','user') %}
{% set PROXY = R.get('proxy_qube','work-web') %}
{% set MACU  = R.get('mac_user','SET_ME') %}
{% set MACH  = R.get('mac_host','SET.ME') %}
{% set MACP  = R.get('mac_ssh_port',22) %}
{% set AUTHSOCK = R.get('ssh_auth_sock','') %}
{% set INSTALL_PW_UTILS = R.get('install_pipewire_utils', True) %}
{% set AUDIO = R.get('audio', {'enable': True, 'bitrate_k': 96, 'sample_rate': 48000, 'channels': 2}) %}
{% set BITK = AUDIO.get('bitrate_k',96) %}
{% set SR   = AUDIO.get('sample_rate',48000) %}
{% set CH   = AUDIO.get('channels',2) %}


{% set PROXY_TPL = R.get('proxy_template','fedora-42-xfce') %}
{% set PROXY_LABEL = R.get('proxy_label','yellow') %}

create-proxy-qube:
  cmd.run:
    - name: |
        set -e
        if ! qvm-ls --raw-list | grep -qx {{ PROXY }}; then
          qvm-create --class AppVM --template {{ PROXY_TPL }} --label {{ PROXY_LABEL }} {{ PROXY }}
          qvm-prefs {{ PROXY }} netvm sys-firewall
        fi

{# ---------- 0) dom0 packages & service (VNC on loopback) ---------- #}
qubes-remote-desktop:
  cmd.run:
    - name: qubes-dom0-update -y qubes-remote-desktop
    - unless: rpm -q qubes-remote-desktop >/dev/null 2>&1

{% if INSTALL_PW_UTILS %}
pipewire-utils-dom0:
  cmd.run:
    - name: qubes-dom0-update -y pipewire-utils || true
    - unless: command -v pw-record >/dev/null 2>&1
{% endif %}

# Harden VNC: service only binds localhost, auth over SSH tunnel only (default of the package).
# Enable on the actual logged-in dom0 user (usually 'user').
enable-vnc-service:
  cmd.run:
    - name: systemctl enable --now "qubes-vncserver@{{ ADMIN }}"
    - unless: systemctl is-active "qubes-vncserver@{{ ADMIN }}" >/dev/null 2>&1

# Optional unit drop-in to be explicit about localhost binding and disable clipboard syncing if supported.
# (The upstream service already exposes only localhost:5901. This adds conservative flags if available.)
/etc/systemd/system/qubes-vncserver@.service.d/override.conf:
  file.managed:
    - makedirs: True
    - mode: '0644'
    - contents: |
        [Service]
        Environment=QUBES_VNC_ARGS=-localhost -rfbport 5901
  cmd.run:
    - name: systemctl daemon-reload && systemctl restart "qubes-vncserver@{{ ADMIN }}"

/etc/qubes/policy.d/31-ssh-agent-remote-admin.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        qubes.SshAgent  sys-remote   vault-ssh   allow
        qubes.SshAgent  +allow-all-names   +allow-all-names   deny  notify=yes


{# ---------- 1) qrexec policy: allow VNC & audio only from your proxy ---------- #}
/etc/qubes/policy.d/30-remote-admin.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        # Remote admin access (tight scope)
        # Only {{ PROXY }} may reach dom0:5901 via qubes.ConnectTCP
        qubes.ConnectTCP +5901  {{ PROXY }}   dom0   allow
        # Refuse others, log
        qubes.ConnectTCP +5901  *            dom0   deny  notify=yes

        # Audio capture (dom0 -> proxy via qrexec)
        my.audio.Capture        {{ PROXY }}   dom0   allow
        my.audio.Capture        *             dom0   deny  notify=yes

# Make sure the proxy has the expected tag for your own inventory hygiene (optional).
tag-proxy-remote-admin:
  cmd.run:
    - name: qvm-tags {{ PROXY }} add remote-admin || true

{# ---------- 2) dom0 audio capture RPC (raw PCM) ---------- #}
/usr/local/sbin/dom0-audio-capture.sh:
  file.managed:
    - mode: '0755'
    - contents: |
        #!/bin/bash
        # Emit raw PCM (s16le {{ SR }} Hz, {{ CH }}ch) of dom0 desktop to stdout.
        # Prefer PipeWire (pw-record), fallback to PulseAudio (parec).
        set -euo pipefail
        SR={{ SR }}; CH={{ CH }}
        # Try pw-record first
        if command -v pw-record >/dev/null 2>&1; then
          exec pw-record --target "$(pactl get-default-sink 2>/dev/null | awk '{print $NF}').monitor" \
                         --rate "$SR" --channels "$CH" --format S16_LE - 2>/dev/null
        fi
        # Fallback to PulseAudio
        SINK="$(pactl get-default-sink 2>/dev/null | awk '{print $NF}')"
        MON="${SINK}.monitor"
        exec parec -d "$MON" --format=s16le --rate="$SR" --channels="$CH"

# RPC handler (runs capture as {{ ADMIN }} user)
/etc/qubes-rpc/my.audio.Capture:
  file.managed:
    - mode: '0755'
    - contents: |
        #!/bin/sh
        exec runuser -l {{ ADMIN }} -c "/usr/local/sbin/dom0-audio-capture.sh"

{# ---------- 3) proxy qube: local port bind to dom0 VNC via ConnectTCP; reverse-SSH to Mac ---------- #}
# Create a local port 15901 in {{ PROXY }} that is a Qubes tunnel to dom0:5901
proxy-bind-dom0-vnc:
  qvm.run:
    - name: {{ PROXY }}
    - user: root
    - cmd: |
        set -e
        # install minimal deps
        if command -v dnf >/dev/null 2>&1; then dnf -y install autossh ffmpeg || true; fi
        if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get -y install autossh ffmpeg || true; fi
        # systemd user service that binds local 15901 -> dom0:5901 using qubes.ConnectTCP
        install -d -m 700 /home/user/.config/systemd/user
        cat >/home/user/.config/systemd/user/qct-vnc.service <<'EOF'
        [Unit]
        Description=Bind local 15901 to dom0:5901 via qubes.ConnectTCP
        After=qubes-qrexec-agent.service
        [Service]
        Type=simple
        ExecStart=/usr/bin/qvm-connect-tcp 15901:dom0:5901
        Restart=always
        RestartSec=2
        [Install]
        WantedBy=default.target
        EOF
        chown -R user:user /home/user/.config/systemd/user
        # enable in user session
        sudo -u user systemctl --user daemon-reload
        sudo -u user systemctl --user enable --now qct-vnc.service
    - require:
      - cmd: create-proxy-qube

# Strict egress firewall on {{ PROXY }} (22/tcp to Mac only)
proxy-firewall:
  cmd.run:
    - name: |
        set -e
        qvm-firewall {{ PROXY }} reset || true
        qvm-firewall {{ PROXY }} add action=accept proto=tcp dsthost={{ MACH }} dstports={{ MACP }}
        qvm-firewall {{ PROXY }} set default=drop
    - require:
      - cmd: create-proxy-qube

# Reverse SSH to publish the VNC pipe on your Mac:  localhost:5901 on Mac -> local 15901 in PROXY
proxy-reverse-vnc-ssh:
  qvm.run:
    - name: {{ PROXY }}
    - user: user
    - cmd: |
        set -e
        mkdir -p ~/.config/systemd/user
        cat >~/.config/systemd/user/remote-vnc-reverse-ssh.service <<'EOF'
        [Unit]
        Description=Reverse SSH: expose Proxy:15901 on Mac:5901
        After=network-online.target
        [Service]
        Environment=AUTOSSH_GATETIME=0
        {% if AUTHSOCK %}Environment=SSH_AUTH_SOCK={{ AUTHSOCK }}{% endif %}
        ExecStart=/usr/bin/autossh -N -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
                 -p {{ MACP }} -R 5901:localhost:15901 {{ MACU }}@{{ MACH }}
        Restart=always
        RestartSec=3
        [Install]
        WantedBy=default.target
        EOF
        systemctl --user daemon-reload
        systemctl --user enable --now remote-vnc-reverse-ssh.service
    - require:
      - cmd: create-proxy-qube

{# ---------- 4) proxy qube: audio pull from dom0 via qrexec, encode, push over SSH to Mac ---------- #}
{% if AUDIO.get('enable', True) %}
proxy-audio-pipeline:
  qvm.run:
    - name: {{ PROXY }}
    - user: user
    - cmd: |
        set -e
        mkdir -p ~/.config/systemd/user
        cat >~/.config/systemd/user/remote-audio.service <<'EOF'
        [Unit]
        Description=Dom0 audio → (qrexec) → ffmpeg (Opus) → SSH → Mac ffplay
        After=qubes-qrexec-agent.service
        [Service]
        {% if AUTHSOCK %}Environment=SSH_AUTH_SOCK={{ AUTHSOCK }}{% endif %}
        # Capture raw PCM from dom0, encode to Opus with low latency, play on Mac
        ExecStart=/bin/bash -lc '\
          set -euo pipefail; \
          qrexec-client-vm dom0 my.audio.Capture \
          | ffmpeg -hide_banner -loglevel warning \
              -f s16le -ac {{ CH }} -ar {{ SR }} -i - \
              -c:a libopus -b:a {{ BITK }}k -application lowdelay -frame_duration 20 \
              -f ogg - \
          | ssh -p {{ MACP }} {{ MACU }}@{{ MACH }} "ffplay -hide_banner -loglevel error -nodisp -autoexit -i -" \
        '
        Restart=always
        RestartSec=2
        [Install]
        WantedBy=default.target
        EOF
        systemctl --user daemon-reload
        systemctl --user enable --now remote-audio.service
    - require:
      - cmd: create-proxy-qube
{% endif %}

{# ---------- 5) quick helpers & health ---------- #}
remote-admin-help:
  file.managed:
    - name: /usr/local/sbin/remote-admin-status
    - mode: '0755'
    - contents: |
        #!/bin/bash
        echo "=== Remote Admin (Option A) ==="
        systemctl status "qubes-vncserver@{{ ADMIN }}" --no-pager || true
        echo
        echo "[dom0] Allowed ConnectTCP 5901 callers:"
        grep -E 'qubes\.ConnectTCP \+5901' /etc/qubes/policy.d/30-remote-admin.policy || true
        echo
        echo "[proxy] user services:"
        qvm-run {{ PROXY }} 'systemctl --user --no-pager --full status qct-vnc.service remote-vnc-reverse-ssh.service {{ "remote-audio.service" if AUDIO.get("enable", True) else "" }}' || true
