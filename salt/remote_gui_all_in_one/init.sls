{# ===== Remote dom0 GUI over reverse-SSH (Option A + Audio) ===== #}
{# Pure cmd.run/file.managed; no pillar. Edit the CONFIG block. #}

{# ---------- CONFIG (EDIT THESE) ---------- #}
{% set ADMIN = "user" %}                       {# dom0 desktop user #}
{% set PROXY = "sys-remote" %}                 {# proxy qube name #}
{% set PROXY_TPL = "fedora-42-xfce" %}         {# template for proxy #}
{% set PROXY_LABEL = "yellow" %}
{% set SSH_VAULT = "vault-ssh" %}              {# offline key holder #}

{% set MACU  = "darlene" %}              {# macOS login user #}
{% set MACH  = "192.167.1.70" %}         {# mac hostname/IP #}
{% set MACP  = 22 %}                           {# mac ssh port #}
{% set AUTHSOCK = "/run/user/1000/ssh-agent" %}{# split-ssh agent sock in proxy (or leave) #}

{% set INSTALL_PW_UTILS = True %}
{% set AUDIO_ENABLE = True %}
{% set BITK = 96 %}        {# Opus kbps #}
{% set SR   = 48000 %}     {# sample rate #}
{% set CH   = 2 %}         {# channels #}
{% set VNC_HASH = "" %}    {# optional: printf 'PASS' | vncpasswd -f ; put string here #}
{# ---------------------------------------- #}

create-ssh-vault:
  cmd.run:
    - name: |
        set -e
        if ! qvm-ls --raw-list | grep -qx {{ SSH_VAULT }}; then
          qvm-create --class AppVM --template debian-12-minimal --label red {{ SSH_VAULT }}
        fi
        qvm-prefs {{ SSH_VAULT }} netvm none

vault-ssh-install-client:
  cmd.run:
    - name: |
        set -e
        qvm-run -u root --pass-io {{ SSH_VAULT }} 'bash -lc "
          if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y || true
            apt-get -y install openssh-client || true
          elif command -v dnf >/dev/null 2>&1; then
            dnf -y install openssh-clients || true
          fi
          install -d -m 700 /home/user/.ssh && chown -R user:user /home/user/.ssh
        "'
    - require:
      - cmd: create-ssh-vault

/usr/local/sbin/remote-gui-print-pubkey:
  file.managed:
    - mode: '0755'
    - contents: |
        #!/bin/bash
        set -euo pipefail
        VAULT="{{ SSH_VAULT }}"
        for p in "/home/user/.ssh/id_ed25519_mac.pub" "/home/user/.ssh/id_ed25519.pub"; do
          if qvm-run --pass-io -u user "$VAULT" "test -r $p && cat $p" >/dev/null 2>&1; then
            qvm-run --pass-io -u user "$VAULT" "cat $p" \
            | sed 's/^/restrict,permitlisten=\"127.0.0.1:5901\" /'
          fi
        done
        echo "Paste ONE line above into your Mac: ~/.ssh/authorized_keys (chmod 600)."

/usr/share/doc/remote-gui-MAC-SETUP.txt:
  file.managed:
    - mode: '0644'
    - contents: |
        macOS one-time:
          1) Settings → General → Sharing → Remote Login: ON
          2) brew install ffmpeg
          3) Put ONE public key line from:
               sudo /usr/local/sbin/remote-gui-print-pubkey
             into ~/.ssh/authorized_keys (chmod 600)
          4) After the state, verify listener:  lsof -iTCP:5901 -sTCP:LISTEN
             Connect:  open vnc://127.0.0.1:5901

create-proxy-qube:
  cmd.run:
    - name: |
        set -e
        if ! qvm-ls --raw-list | grep -qx {{ PROXY }}; then
          qvm-create --class AppVM --template {{ PROXY_TPL }} --label {{ PROXY_LABEL }} {{ PROXY }}
          qvm-prefs {{ PROXY }} netvm sys-firewall
        fi

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

/etc/systemd/system/qubes-vncserver@.service.d/override.conf:
  file.managed:
    - makedirs: True
    - mode: '0644'
    - contents: |
        [Service]
        Environment=QUBES_VNC_ARGS=-localhost -rfbport 5901
  require:
    - cmd: install-qubes-remote-desktop

enable-vnc-service:
  cmd.run:
    - name: |
        set -e
        systemctl daemon-reload
        systemctl enable --now "qubes-vncserver@{{ ADMIN }}"
  require:
    - file: /etc/systemd/system/qubes-vncserver@.service.d/override.conf

{% if VNC_HASH %}
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
        {{ VNC_HASH }}
  require:
    - file: vnc-pass-dir
restart-vnc-after-pass:
  cmd.run:
    - name: systemctl restart "qubes-vncserver@{{ ADMIN }}"
  require:
    - file: vnc-pass-file
{% endif %}

/etc/qubes/policy.d/30-remote-admin.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        qubes.ConnectTCP +5901   {{ PROXY }}   dom0   allow
        qubes.ConnectTCP +5901   *             dom0   deny  notify=yes
        my.audio.Capture         {{ PROXY }}   dom0   allow
        my.audio.Capture         *             dom0   deny  notify=yes

/etc/qubes/policy.d/31-ssh-agent-remote-admin.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        qubes.SshAgent   {{ PROXY }}   {{ SSH_VAULT }}   allow
        qubes.SshAgent   +allow-all-names   +allow-all-names   deny  notify=yes

tag-proxy-remote-admin:
  cmd.run:
    - name: qvm-tags {{ PROXY }} add remote-admin || true

/usr/local/sbin/dom0-audio-capture.sh:
  file.managed:
    - mode: '0755'
    - contents: |
        #!/bin/bash
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

/etc/qubes-rpc/my.audio.Capture:
  file.managed:
    - mode: '0755'
    - contents: |
        #!/bin/sh
        exec runuser -l {{ ADMIN }} -c "/usr/local/sbin/dom0-audio-capture.sh"

proxy-install-pkgs:
  cmd.run:
    - name: |
        set -e
        qvm-run -u root --pass-io {{ PROXY }} 'bash -lc "
          if command -v dnf >/dev/null 2>&1; then
            dnf -y install autossh ffmpeg openssh-clients qubes-app-linux-split-ssh || true
          elif command -v apt-get >/dev/null 2>&1; then
            apt-get update -y || true
            apt-get -y install autossh ffmpeg openssh-client qubes-app-linux-split-ssh || true
          fi
        "'
  require:
    - cmd: create-proxy-qube

proxy-bind-dom0-vnc:
  cmd.run:
    - name: |
        set -e
        qvm-run -u root --pass-io {{ PROXY }} 'bash -lc "
          install -d -m 700 /home/user/.config/systemd/user
          cat >/home/user/.config/systemd/user/qct-vnc.service <<EOF
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
        "'
  require:
    - cmd: proxy-install-pkgs

proxy-firewall-allow-mac:
  cmd.run:
    - name: |
        set -e
        qvm-firewall {{ PROXY }} reset || true
        qvm-firewall {{ PROXY }} add action=accept proto=tcp dsthost={{ MACH }} dstports={{ MACP }}
        qvm-firewall {{ PROXY }} set default=drop
  require:
    - cmd: create-proxy-qube

proxy-known-hosts-mac:
  cmd.run:
    - name: |
        set -e
        qvm-run -u user --pass-io {{ PROXY }} 'bash -lc "
          mkdir -p ~/.ssh && chmod 700 ~/.ssh
          ssh-keyscan -p {{ MACP }} {{ MACH }} >> ~/.ssh/known_hosts 2>/dev/null || true
          chmod 600 ~/.ssh/known_hosts || true
        "'
  require:
    - cmd: create-proxy-qube

proxy-reverse-vnc-ssh:
  cmd.run:
    - name: |
        set -e
        qvm-run -u user --pass-io {{ PROXY }} 'bash -lc "
          mkdir -p ~/.config/systemd/user
          cat >~/.config/systemd/user/remote-vnc-reverse-ssh.service <<EOF
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
        "'
  require:
    - cmd: proxy-install-pkgs
    - cmd: proxy-bind-dom0-vnc
    - cmd: proxy-known-hosts-mac
    - cmd: proxy-firewall-allow-mac

{% if AUDIO_ENABLE %}
proxy-audio-pipeline:
  cmd.run:
    - name: |
        set -e
        qvm-run -u user --pass-io {{ PROXY }} 'bash -lc "
          mkdir -p ~/.config/systemd/user
          cat >~/.config/systemd/user/remote-audio.service <<EOF
          [Unit]
          Description=Dom0 audio → qrexec → ffmpeg (Opus) → SSH → Mac ffplay
          After=qubes-qrexec-agent.service
          [Service]
          {% if AUTHSOCK %}Environment=SSH_AUTH_SOCK={{ AUTHSOCK }}{% endif %}
          ExecStart=/bin/bash -lc '\''qrexec-client-vm dom0 my.audio.Capture \
            | ffmpeg -hide_banner -loglevel warning -f s16le -ac {{ CH }} -ar {{ SR }} -i - \
                -c:a libopus -b:a {{ BITK }}k -application lowdelay -frame_duration 20 -f ogg - \
            | ssh -p {{ MACP }} {{ MACU }}@{{ MACH }} "ffplay -hide_banner -loglevel error -nodisp -autoexit -i -"'\''
          Restart=always
          RestartSec=2
          [Install]
          WantedBy=default.target
          EOF
          systemctl --user daemon-reload
          systemctl --user enable --now remote-audio.service
        "'
  require:
    - cmd: proxy-install-pkgs
{% endif %}

/usr/local/sbin/remote-admin-status:
  file.managed:
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
        qvm-run {{ PROXY }} 'systemctl --user --no-pager --full status qct-vnc.service remote-vnc-reverse-ssh.service remote-audio.service' || true
