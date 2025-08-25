{# =========================
   Remote GUI over sys-gui-vnc (Qubes 4.2)
   End-to-end, single file, with audio + reverse SSH to macOS.
   ========================= #}

{# ---------- CONFIG (edit or override via pillar: remote_gui_vnc:*) ---------- #}
{% set R = pillar.get('remote_gui', {}) %}
{% set PROXY = R.get('proxy_qube','sys-remote') %}
{% set PROXY_TPL = R.get('proxy_template','fedora-42-xfce') %}
{% set PROXY_LABEL = R.get('proxy_label','yellow') %}
{% set SSH_VAULT = R.get('ssh_vault','vault-ssh') %}            {# for Split-SSH (optional) #}
{% set AUTHSOCK = R.get('ssh_auth_sock','/run/user/1000/ssh-agent') %}

{# macOS target for reverse SSH (you will connect to vnc://127.0.0.1:5901) #}
{% set MACU  = R.get('mac_user','darlene') %}
{% set MACH  = R.get('mac_host','192.168.1.70') %}
{% set MACP  = R.get('mac_ssh_port',22) %}

{# Audio (captured in sys-gui-vnc, encoded in proxy, played on Mac with ffplay) #}
{% set AUDIO = R.get('audio', {'enable': True, 'bitrate_k': 96, 'sample_rate': 48000, 'channels': 2}) %}
{% set BITK = AUDIO.get('bitrate_k',96) %}
{% set SR   = AUDIO.get('sample_rate',48000) %}
{% set CH   = AUDIO.get('channels',2) %}
{% set INSTALL_PW_UTILS = R.get('install_pipewire_utils', True) %}

{# ---------- 0) Ensure the Fedora XFCE template exists (used by sys-gui-vnc & proxy) ---------- #}
maybe-install-fedora-xfce:
  cmd.run:
    - name: |
        set -e
        if ! qvm-ls --raw-list | grep -Eq '^fedora-.*-xfce$'; then
          qubes-dom0-update -y qubes-template-{{ PROXY_TPL.split('-xfce')[0] }} || true
        fi

{# ---------- 1) Create/ensure sys-gui-vnc via official formula, enable service ---------- #}
ensure-sys-gui-vnc:
  cmd.run:
    - name: |
        set -e
        if ! qvm-ls --raw-list | grep -qx sys-gui-vnc; then
          qubesctl top.enable qvm.sys-gui-vnc || true
          qubesctl top.enable qvm.sys-gui-vnc pillar=True || true
          qubesctl --all state.highstate
        fi
        # Some builds require explicit service enable:
        qvm-service --enable sys-gui-vnc guivm-vnc || true
        qvm-start --skip-if-running sys-gui-vnc || true
    - require:
      - cmd: maybe-install-fedora-xfce

{# ---------- 2) qrexec policies: ConnectTCP to VNC, audio capture, Split-SSH ---------- #}
/etc/qubes/policy.d/30-remote-vnc.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        # Only {{ PROXY }} may reach sys-gui-vnc:5900
        qubes.ConnectTCP +5900  {{ PROXY }}    sys-gui-vnc   allow
        qubes.ConnectTCP +5900  *              sys-gui-vnc   deny  notify=yes

/etc/qubes/policy.d/31-remote-audio.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        # Only {{ PROXY }} may call audio capture in sys-gui-vnc
        my.audio.Capture        {{ PROXY }}    sys-gui-vnc   allow
        my.audio.Capture        *              sys-gui-vnc   deny  notify=yes

/etc/qubes/policy.d/32-remote-ssh-agent.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        # Allow Split-SSH (proxy → vault-ssh) if you use it
        qubes.SshAgent          {{ PROXY }}    {{ SSH_VAULT }}   allow
        qubes.SshAgent          +allow-all-names   +allow-all-names   deny  notify=yes

{# ---------- 3) Proxy qube: create, lock egress to Mac:22, install tools ---------- #}
create-proxy-qube:
  cmd.run:
    - name: |
        set -e
        if ! qvm-ls --raw-list | grep -qx {{ PROXY }}; then
          qvm-create --class AppVM --template {{ PROXY_TPL }} --label {{ PROXY_LABEL }} {{ PROXY }}
          qvm-prefs {{ PROXY }} netvm sys-firewall
        fi

proxy-firewall-to-mac-only:
  cmd.run:
    - name: |
        set -e
        qvm-firewall {{ PROXY }} reset || true
        qvm-firewall {{ PROXY }} add action=accept proto=tcp dsthost={{ MACH }} dstports={{ MACP }}
        qvm-firewall {{ PROXY }} set default=drop
    - require:
      - cmd: create-proxy-qube

proxy-packages:
  cmd.run:
    - name: |
        set -e
        # install autossh/ffmpeg + split-ssh client inside proxy
        if qvm-run -q {{ PROXY }} 'command -v dnf >/dev/null'; then
          qvm-run -q -u root {{ PROXY }} 'dnf -y install autossh ffmpeg openssh-clients qubes-app-linux-split-ssh || true'
        else
          qvm-run -q -u root {{ PROXY }} 'apt-get update -y || true; apt-get -y install autossh ffmpeg openssh-client qubes-app-linux-split-ssh || true'
        fi
        qvm-run -q -u root {{ PROXY }} 'install -d -m 700 /home/user/.config/systemd/user; chown -R user:user /home/user/.config/systemd/user'
    - require:
      - cmd: create-proxy-qube

{# ---------- 4) Bind 15900 → sys-gui-vnc:5900 inside proxy (qvm-connect-tcp) ---------- #}
proxy-bind-vnc:
  cmd.run:
    - name: |
        set -e
        qvm-run -q -u root {{ PROXY }} "bash -lc 'cat > /home/user/.config/systemd/user/qct-vnc.service <<\"EOF\"
        [Unit]
        Description=Bind local 15900 to sys-gui-vnc:5900 via qubes.ConnectTCP
        After=qubes-qrexec-agent.service
        [Service]
        Type=simple
        ExecStart=/usr/bin/qvm-connect-tcp 15900:sys-gui-vnc:5900
        Restart=always
        RestartSec=2
        [Install]
        WantedBy=default.target
        EOF
        chown user:user /home/user/.config/systemd/user/qct-vnc.service
        sudo -u user systemctl --user daemon-reload
        sudo -u user systemctl --user enable --now qct-vnc.service
        '"
    - require:
      - cmd: proxy-packages
      - cmd: ensure-sys-gui-vnc

proxy-known-hosts-mac:
  cmd.run:
    - name: |
        set -e
        qvm-run -q {{ PROXY }} "bash -lc 'mkdir -p ~/.ssh && chmod 700 ~/.ssh; ssh-keyscan -p {{ MACP }} {{ MACH }} >> ~/.ssh/known_hosts 2>/dev/null || true; chmod 600 ~/.ssh/known_hosts || true'"
    - require:
      - cmd: proxy-packages

{# ---------- 5) Reverse SSH from proxy → Mac (Mac gets localhost:5901) ---------- #}
proxy-reverse-ssh-vnc:
  cmd.run:
    - name: |
        set -e
        qvm-run -q {{ PROXY }} "bash -lc 'cat > ~/.config/systemd/user/remote-vnc-reverse-ssh.service <<\"EOF\"
        [Unit]
        Description=Reverse SSH: expose Proxy:15900 on Mac:5901
        After=network-online.target
        [Service]
        Environment=AUTOSSH_GATETIME=0
        {% if AUTHSOCK %}Environment=SSH_AUTH_SOCK={{ AUTHSOCK }}{% endif %}
        ExecStart=/usr/bin/autossh -N -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
                 -p {{ MACP }} -R 5901:localhost:15900 {{ MACU }}@{{ MACH }}
        Restart=always
        RestartSec=3
        [Install]
        WantedBy=default.target
        EOF
        systemctl --user daemon-reload
        systemctl --user enable --now remote-vnc-reverse-ssh.service
        '"
    - require:
      - cmd: proxy-bind-vnc
      - cmd: proxy-known-hosts-mac
      - cmd: proxy-firewall-to-mac-only

{# ---------- 6) sys-gui-vnc: install audio tools (optional), add RPC, capture script ---------- #}
sys-gui-vnc-audio-pkgs:
  cmd.run:
    - name: |
        set -e
        if {{ 'true' if INSTALL_PW_UTILS else 'false' }}; then
          NV="$(qvm-prefs -g sys-gui-vnc netvm || true)"
          if [ -z "$NV" ] || [ "$NV" = "none" ]; then qvm-prefs sys-gui-vnc netvm sys-firewall || true; ATTACH=1; else ATTACH=0; fi
          if qvm-run -q sys-gui-vnc 'command -v dnf >/dev/null'; then
            qvm-run -q -u root sys-gui-vnc 'dnf -y install pipewire-utils pulseaudio-utils ffmpeg || true'
          else
            qvm-run -q -u root sys-gui-vnc 'apt-get update -y || true; apt-get -y install pipewire-utils pulseaudio-utils ffmpeg || true'
          fi
          [ "${ATTACH:-0}" = "1" ] && qvm-prefs sys-gui-vnc netvm none || true
        fi
    - require:
      - cmd: ensure-sys-gui-vnc

sys-gui-vnc-audio-rpc:
  cmd.run:
    - name: |
        set -e
        qvm-run -q -u root sys-gui-vnc "bash -lc 'install -d -m 755 /usr/local/sbin /etc/qubes-rpc'"
        qvm-run -q -u root sys-gui-vnc "bash -lc 'cat > /usr/local/sbin/gui-audio-capture.sh <<\"EOF\"
        #!/bin/bash
        set -euo pipefail
        SR={{ SR }}; CH={{ CH }}
        if command -v pw-record >/dev/null 2>&1; then
          SINK=\$(pactl get-default-sink 2>/dev/null | awk \x27{print \$NF}\x27)
          MON=\"\${SINK:+\${SINK}.monitor}\"
          exec pw-record \${MON:+--target \"\$MON\"} --rate \"\$SR\" --channels \"\$CH\" --format S16_LE - 2>/dev/null
        fi
        SINK=\$(pactl get-default-sink 2>/dev/null | awk \x27{print \$NF}\x27)
        MON=\"\${SINK}.monitor\"
        exec parec \${SINK:+-d \"\$MON\"} --format=s16le --rate=\"\$SR\" --channels=\"\$CH\"
        EOF
        chmod 0755 /usr/local/sbin/gui-audio-capture.sh
        '"
        qvm-run -q -u root sys-gui-vnc "bash -lc 'cat > /etc/qubes-rpc/my.audio.Capture <<\"EOF\"
        #!/bin/sh
        exec /usr/local/sbin/gui-audio-capture.sh
        EOF
        chmod 0755 /etc/qubes-rpc/my.audio.Capture
        '"
    - require:
      - cmd: sys-gui-vnc-audio-pkgs

{# ---------- 7) Proxy: audio pull → Opus → SSH → ffplay on Mac ---------- #}
{% if AUDIO.get('enable', True) %}
proxy-audio-pipeline:
  cmd.run:
    - name: |
        set -e
        qvm-run -q {{ PROXY }} "bash -lc 'cat > ~/.config/systemd/user/remote-audio.service <<\"EOF\"
        [Unit]
        Description=sys-gui-vnc audio → qrexec → ffmpeg (Opus) → SSH → Mac ffplay
        After=qubes-qrexec-agent.service
        [Service]
        {% if AUTHSOCK %}Environment=SSH_AUTH_SOCK={{ AUTHSOCK }}{% endif %}
        ExecStart=/bin/bash -lc \x27
          set -euo pipefail;
          qrexec-client-vm sys-gui-vnc my.audio.Capture \
          | ffmpeg -hide_banner -loglevel warning \
              -f s16le -ac {{ CH }} -ar {{ SR }} -i - \
              -c:a libopus -b:a {{ BITK }}k -application lowdelay -frame_duration 20 \
              -f ogg - \
          | ssh -p {{ MACP }} {{ MACU }}@{{ MACH }} "ffplay -hide_banner -loglevel error -nodisp -autoexit -i -" \
        \x27
        Restart=always
        RestartSec=2
        [Install]
        WantedBy=default.target
        EOF
        systemctl --user daemon-reload
        systemctl --user enable --now remote-audio.service
        '"
    - require:
      - cmd: proxy-packages
      - cmd: sys-gui-vnc-audio-rpc
{% endif %}

{# ---------- 8) Helper: dom0 status ---------- #}
remote-gui-status:
  file.managed:
    - name: /usr/local/sbin/remote-gui-status
    - mode: '0755'
    - contents: |
        #!/bin/bash
        echo "== sys-gui-vnc =="
        qvm-ls | grep -E 'sys-gui-vnc' || true
        qvm-run sys-gui-vnc 'ss -lnt | grep 5900 || netstat -lnt | grep 5900' 2>/dev/null || true
        echo
        echo "== Policies (ConnectTCP 5900, audio) =="
        grep -E 'ConnectTCP \+5900|my\.audio\.Capture' /etc/qubes/policy.d/*.policy 2>/dev/null || true
        echo
        echo "== Proxy services =="
        qvm-run {{ PROXY }} 'systemctl --user --no-pager --full status qct-vnc.service remote-vnc-reverse-ssh.service {% if AUDIO.get("enable", True) %}remote-audio.service{% endif %}' 2>/dev/null || true
