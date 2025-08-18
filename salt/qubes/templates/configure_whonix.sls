# Whonix-WS caller template
whonix-ws-split-clients:
  qvm.run:
    - name: whonix-workstation-17
    - user: root
    - cmd: |
        set -e
        apt-get update -y || true
        apt-get install -y --no-install-recommends \
          qubes-gpg-client qubes-app-linux-split-ssh
        sudo tee /etc/systemd/system/my-after-sdwdate.service <<'EOF'
        [Unit]
        Description=Start my apps only after sdwdate
        After=sdwdate.service tor@default.service network-online.target
        Wants=sdwdate.service

        [Service]
        Type=oneshot
        ExecStart=/usr/local/bin/start-my-stack.sh

        [Install]
        WantedBy=multi-user.target
        EOF
        sudo systemctl enable my-after-sdwdate.service


whonix-gw-time-leak-discipline:
  qvm.run:
    - name: whonix-gateway-17
    - user: root
    - cmd: |
        set -e
        apt-get update -y || true
        sudo tee /etc/systemd/system/my-after-sdwdate.service <<'EOF'
        [Unit]
        Description=Start my apps only after sdwdate
        After=sdwdate.service tor@default.service network-online.target
        Wants=sdwdate.service

        [Service]
        Type=oneshot
        ExecStart=/usr/local/bin/start-my-stack.sh

        [Install]
        WantedBy=multi-user.target
        EOF
        sudo systemctl enable my-after-sdwdate.service



# Whonix WS callers
whonix-ws-client-env:
  qvm.run:
    - name: whonix-workstation-17
    - user: root
    - cmd: |
        set -e
        cat >/etc/profile.d/20-split-gpg.sh <<'EOF'
        export GPG_TTY=$(tty 2>/dev/null || echo)
        alias gpg='qubes-gpg-client-wrapper'
        EOF
        cat >/etc/profile.d/20-split-ssh.sh <<'EOF'
        if systemctl --user list-unit-files 2>/dev/null | grep -q qubes-ssh-agent-proxy; then
          systemctl --user enable --now qubes-ssh-agent-proxy.socket qubes-ssh-agent-proxy.service 2>/dev/null || true
        fi
        EOF
