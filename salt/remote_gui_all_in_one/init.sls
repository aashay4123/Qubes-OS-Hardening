{# =========================
   Remote dom0 GUI over Reverse-SSH (Option A + Audio) — All-in-one
   Qubes OS 4.2
   Edit the CONFIG block below (or override with pillar: remote_gui:*).
   ========================= #}

{# ---------- CONFIG (edit me) ---------- #}
{% set R = pillar.get('remote_gui', {}) %}
{% set ADMIN         = R.get('admin_user','user') %}
{% set PROXY         = R.get('proxy_qube','sys-remote') %}
{% set PROXY_TPL     = R.get('proxy_template','fedora-42-xfce') %}
{% set PROXY_LABEL   = R.get('proxy_label','yellow') %}

{% set SSH_VAULT     = R.get('ssh_vault','vault-ssh') %}
{% set VAULT_TPL     = R.get('vault_template','debian-12-minimal') %}
{% set VAULT_LABEL   = R.get('vault_label','red') %}

{% set MACU          = R.get('mac_user','YOUR_MAC_USER') %}
{% set MACH          = R.get('mac_host','192.168.1.70') %}
{% set MACP          = R.get('mac_ssh_port',22) %}

{# Split-SSH client socket inside the proxy (usually this is correct). #}
{% set AUTHSOCK      = R.get('ssh_auth_sock','/run/user/1000/ssh-agent') %}

{# VNC password provision (optional).
   EITHER set vnc_pass_hash (output of `printf PASS | vncpasswd -f`)
   OR leave empty and set it manually after apply. #}
{% set VNC_PASS_HASH = R.get('vnc_pass_hash','') %}

{# Audio options #}
{% set INSTALL_PW_UTILS = R.get('install_pipewire_utils', True) %}
{% set AUDIO         = R.get('audio', {'enable': True, 'bitrate_k': 96, 'sample_rate': 48000, 'channels': 2}) %}
{% set BITK          = AUDIO.get('bitrate_k',96) %}
{% set SR            = AUDIO.get('sample_rate',48000) %}
{% set CH            = AUDIO.get('channels',2) %}

{# Optional vault key helper paths (only used by the helper) #}
{% set KEY_PATH      = R.get('key_path','/home/user/.ssh/id_ed25519_mac') %}
{% set KEY_COMMENT   = R.get('key_comment','qubes-remote-mac') %}

{# ---------- A) Create / prepare vault-ssh (offline) ---------- #}
create-ssh-vault:
  cmd.run:
    - name: |
        set -e
        if ! qvm-ls --raw-list | grep -qx {{ SSH_VAULT }}; then
          qvm-create --class AppVM --template {{ VAULT_TPL }} --label {{ VAULT_LABEL }} {{ SSH_VAULT }}
        fi
        qvm-prefs {{ SSH_VAULT }} netvm none || true

vault-ssh-packages:
  qvm.run:
    - name: {{ SSH_VAULT }}
    - user: root
    - cmd: |
        set -e
        if command -v apt-get >/dev/null 2>&1; then
          apt-get update -y || true
          apt-get -y install openssh-client qubes-app-linux-split-ssh || true
        elif command -v dnf >/dev/null 2>&1; then
          dnf -y install openssh-clients qubes-app-linux-split-ssh || true
        fi
        install -d -m 700 /home/user/.ssh
        chown -R user:user /home/user/.ssh
    - require:
      - cmd: create-ssh-vault

/usr/local/sbin/remote-gui-print-pubkey:
  file.managed:
    - mode: '0755'
    - contents: |
        #!/bin/bash
        set -euo pipefail
        VAULT="{{ SSH_VAULT }}"
        CANDIDATES=("{{ KEY_PATH }}.pub" "/home/user/.ssh/id_ed25519_mac.pub" "/home/user/.ssh/id_ed25519.pub")
        echo "=== Public key(s) from $VAULT (paste ONE on your Mac) ==="
        FOUND=0
        for p in "${CANDIDATES[@]}"; do
          if qvm-run --pass-io -u user "$VAULT" "test -r $p && cat $p" >/dev/null 2>&1; then
            qvm-run --pass-io -u user "$VAULT" "cat $p" \
              | sed 's/^/restrict,permitlisten=\"127.0.0.1:5901\" /'
            FOUND=1
          fi
        done
        if [ "$FOUND" -eq 0 ]; then
          echo "No pubkey found in $VAULT. Create or import one (e.g. ssh-keygen -t ed25519 -C {{ KEY_COMMENT }})" >&2
          exit 1
        fi
        echo
        echo "Paste ONE line above into your Mac: ~/.ssh/authorized_keys"
        echo "  Permissions: chmod 700 ~/.ssh ; chmod 600 ~/.ssh/authorized_keys"
        echo

{# ---------- B) Create / prepare proxy qube ---------- #}
create-proxy-qube:
  cmd.run:
    - name: |
        set -e
        if ! qvm-ls --raw-list | grep -qx {{ PROXY }}; then
          qvm-create --class AppVM --template {{ PROXY_TPL }} --label {{ PROXY_LABEL }} {{ PROXY }}
          qvm-prefs {{ PROXY }} netvm sys-firewall
        fi

proxy-packages:
  qvm.run:
    - name: {{ PROXY }}
    - user: root
    - cmd: |
        set -e
        if command -v dnf >/dev/null 2>&1; then
          dnf -y install autossh ffmpeg openssh-clients qubes-app-linux-split-ssh || true
        elif command -v apt-get >/dev/null 2>&1; then
          apt-get update -y || true
          apt-get -y install autossh ffmpeg openssh-client qubes-app-linux-split-ssh || true
        fi
    - require:
      - cmd: create-proxy-qube

{# Attempt to ensure the client-side Split-SSH agent socket exists in the proxy #}
proxy-enable-ssh-agent-client:
  qvm.run:
    - name: {{ PROXY }}
    - user: user
    - cmd: |
        set -e
        # Try both common unit names; ignore errors
        systemctl --user list-unit-files | grep -q qubes-ssh-agent && systemctl --user enable --now qubes-ssh-agent || true
        systemctl --user list-unit-files | grep -q qubes-ssh-agent-client && systemctl --user enable --now qubes-ssh-agent-client || true
    - require:
      - qvm.run: proxy-packages

{# ---------- C) dom0: install & harden VNC (loopback only) ---------- #}
install-qubes-remote-desktop:
  cmd.run:
    - name: qubes-dom0-update -y qubes-remote-desktop
    - unless: rpm -q qubes-remote-desktop >/dev/null 2>&1

{% if INSTALL_PW_UTILS %}
install-pipewire-utils:
  cmd.run:
    - name: qubes-dom0-update -y pipewire-utils || true
    - unless: command -v pw-record >/dev/null 2>&1
{% endif %}

enable-vnc-service:
  cmd.run:
    - name: systemctl enable --now "qubes-vncserver@{{ ADMIN }}"
    - unless: systemctl is-active "qubes-vncserver@{{ ADMIN }}" >/dev/null 2>&1
    - require:
      - cmd: install-qubes-remote-desktop

qubes-vncserver-override:
  file.managed:
    - name: /etc/systemd/system/qubes-vncserver@.service.d/override.conf
    - makedirs: True
    - mode: '0644'
    - contents: |
        [Service]
        Environment=QUBES_VNC_ARGS=-localhost -rfbport 5901

reload-vnc-after-override:
  cmd.run:
    - name: systemctl daemon-reload && systemctl restart "qubes-vncserver@{{ ADMIN }}"
    - require:
      - file: qubes-vncserver-override
      - cmd: enable-vnc-service

{% if VNC_PASS_HASH %}
vnc-pass-dir:
  file.directory:
    - name: /home/{{ ADMIN }}/.vnc
    - user: {{ ADMIN }}
    - group: {{ ADMIN }}
    - mode: '0700'

vnc-pass-file:
  file.managed:
    - name: /home/{{ ADMIN }}/.vnc/passwd
    - user: {{ ADMIN }}
    - group: {{ ADMIN }}
    - mode: '0600'
    - contents: |
        {{ VNC_PASS_HASH }}
    - require:
      - file: vnc-pass-dir

restart-vnc-after-pass:
  cmd.run:
    - name: systemctl restart "qubes-vncserver@{{ ADMIN }}"
    - require:
      - file: vnc-pass-file
{% endif %}

{# ---------- D) dom0 qrexec policies (ConnectTCP+5901, Split-SSH, audio) ---------- #}
policy-remote-admin:
  file.managed:
    - name: /etc/qubes/policy.d/30-remote-admin.policy
    - mode: '0644'
    - contents: |
        # Only {{ PROXY }} may reach dom0:5901 via qubes.ConnectTCP
        qubes.ConnectTCP +5901   {{ PROXY }}   dom0   allow
        qubes.ConnectTCP +5901   *             dom0   deny  notify=yes

        # Dom0 audio capture allowed only to {{ PROXY }}
        my.audio.Capture         {{ PROXY }}   dom0   allow
        my.audio.Capture         *             dom0   deny  notify=yes

policy-split-ssh:
  file.managed:
    - name: /etc/qubes/policy.d/31-ssh-agent-remote-admin.policy
    - mode: '0644'
    - contents: |
        qubes.SshAgent   {{ PROXY }}   {{ SSH_VAULT }}   allow
        qubes.SshAgent   +allow-all-names   +allow-all-names   deny  notify=yes

tag-proxy-remote-admin:
  cmd.run:
    - name: qvm-tags {{ PROXY }} add remote-admin || true

{# ---------- E) dom0 audio RPC ---------- #}
dom0-audio-capture-script:
  file.managed:
    - name: /usr/local/sbin/dom0-audio-capture.sh
    - mode: '0755'
    - contents: |
        #!/bin/bash
        # Emit raw PCM (s16le {{ SR }} Hz, {{ CH }}ch) of dom0 desktop to stdout.
        # Prefer PipeWire (pw-record), fallback to PulseAudio (parec).
        set -euo pipefail
        SR={{ SR }}; CH={{ CH }}
        if command -v pw-record >/dev/null 2>&1; then
          SINK="$(pactl get-default-sink 2>/dev/null | awk '{print $NF}')"
          MON="${SINK:+${SINK}.monitor}"
          exec pw-record ${MON:+--target "$MON"} --rate "$SR" --channels "$CH" --format S16_LE - 2>/dev/null
        fi
        SINK="$(pactl get-default-sink 2>/dev/null | awk '{print $NF}')"
        MON="${SINK}.monitor"
        exec parec ${SINK:+-d "$MON"} --format=s16le --rate="$SR" --channels="$CH"

dom0-audio-capture-rpc:
  file.managed:
    - name: /etc/qubes-rpc/my.audio.Capture
    - mode: '0755'
    - contents: |
        #!/bin/sh
        exec runuser -l {{ ADMIN }} -c "/usr/local/sbin/dom0-audio-capture.sh"

{# ---------- F) Proxy wiring: qvm-connect-tcp + reverse SSH + audio ---------- #}
proxy-bind-dom0-vnc:
  qvm.run:
    - name: {{ PROXY }}
    - user: root
    - cmd: |
        set -e
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
        sudo -u user systemctl --user daemon-reload
        sudo -u user systemctl --user enable --now qct-vnc.service
    - require:
      - cmd: create-proxy-qube
      - qvm.run: proxy-packages

proxy-firewall:
  cmd.run:
    - name: |
        set -e
        qvm-firewall {{ PROXY }} reset || true
        qvm-firewall {{ PROXY }} add action=accept proto=tcp dsthost={{ MACH }} dstports={{ MACP }}
        qvm-firewall {{ PROXY }} set default=drop
    - require:
      - cmd: create-proxy-qube

proxy-known-hosts-mac:
  qvm.run:
    - name: {{ PROXY }}
    - user: user
    - cmd: |
        set -e
        mkdir -p ~/.ssh
        chmod 700 ~/.ssh
        ssh-keyscan -p {{ MACP }} {{ MACH }} >> ~/.ssh/known_hosts 2>/dev/null || true
        chmod 600 ~/.ssh/known_hosts || true
    - require:
      - cmd: create-proxy-qube

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
      - qvm.run: proxy-packages
      - qvm.run: proxy-bind-dom0-vnc
      - qvm.run: proxy-known-hosts-mac
      - cmd: proxy-firewall
      - qvm.run: proxy-enable-ssh-agent-client

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
      - qvm.run: proxy-packages
      - qvm.run: proxy-enable-ssh-agent-client
{% endif %}

{# ---------- G) Helper to check status ---------- #}
remote-admin-status:
  file.managed:
    - name: /usr/local/sbin/remote-admin-status
    - mode: '0755'
    - contents: |
        #!/bin/bash
        echo "=== Remote GUI (Option A) status ==="
        systemctl status "qubes-vncserver@{{ ADMIN }}" --no-pager || true
        echo
        echo "[dom0] ConnectTCP 5901 policy:"
        grep -E 'qubes\.ConnectTCP \+5901' /etc/qubes/policy.d/30-remote-admin.policy || true
        echo
        echo "[proxy] user services:"
        qvm-run {{ PROXY }} 'systemctl --user --no-pager --full status qct-vnc.service remote-vnc-reverse-ssh.service {% if AUDIO.get("enable", True) %}remote-audio.service{% endif %}' || true
