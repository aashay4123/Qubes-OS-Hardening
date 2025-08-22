{# === EDIT ME === #}
{% set vnc_password_plain = 'ChangeMe-Strong' %}     # your VNC password (used only inside sys-gui-vnc)
{% set vnc_port           = 5900 %}                  # sys-gui-vnc listens on localhost:this port

# Enable/Run the official qvm.sys-gui-vnc formula (creates the VM and VNC server)
enable-sys-gui-vnc:
  cmd.run:
    - name: |
        set -e
        qubesctl top.enable qvm.sys-gui-vnc
        qubesctl top.enable qvm.sys-gui-vnc pillar=True
        qubesctl --all state.highstate
        qubesctl top.disable qvm.sys-gui-vnc
        # ensure the VM exists & is default guivm
        qvm-ls --raw-list | grep -qx sys-gui-vnc || { echo "sys-gui-vnc missing"; exit 1; }
        qubes-prefs default_guivm sys-gui-vnc || true
    - creates: /var/lib/qubes/vm-templates   # dummy for idempotence

# Start sys-gui-vnc (no NetVM)
start-sys-gui-vnc:
  cmd.run:
    - name: |
        set -e
        qvm-prefs sys-gui-vnc netvm none || true
        qvm-start --skip-if-running sys-gui-vnc
    - require:
      - cmd: enable-sys-gui-vnc

# Set a TigerVNC password inside sys-gui-vnc, non-interactively
set-vnc-password:
  qvm.run:
    - name: sys-gui-vnc
    - user: user
    - cmd: |
        set -e
        mkdir -p ~/.config/tigervnc ~/.vnc
        # write hashed password using vncpasswd -f
        PASS="{{ vnc_password_plain }}"
        printf '%s\n' "$PASS" | vncpasswd -f > ~/.config/tigervnc/passwd
        install -m 0600 /dev/null ~/.vnc/passwd
        cp -f ~/.config/tigervnc/passwd ~/.vnc/passwd
        # convenience: viewer-side perf is bigger factor, but set sensible defaults if read
        cat > ~/.vnc/config <<'EOF'
        # Client can override; these are sane starting points for speed/quality
        geometry=auto
        localhost
        # PreferredEncoding and Quality are usually chosen by server; leave viewer to adapt
        EOF
        # make sure the VNC service is running (provided by qubes-remote-desktop)
        systemctl --user daemon-reload || true
        systemctl --user start qubes-vncserver@user || systemctl start qubes-vncserver@user || true
    - require:
      - cmd: start-sys-gui-vnc

# Optional: force the VNC service to use our port (5900 vs 5901) if needed
force-vnc-port:
  qvm.run:
    - name: sys-gui-vnc
    - user: root
    - cmd: |
        set -e
        install -d -m 0755 /etc/systemd/system/qubes-vncserver@user.service.d
        cat >/etc/systemd/system/qubes-vncserver@user.service.d/override.conf <<EOF
        [Service]
        # If upstream defaults to 5901, pin to {{ vnc_port }}
        ExecStart=
        ExecStart=/usr/bin/Xvnc :1 -rfbport {{ vnc_port }} -localhost -NeverShared -SecurityTypes VncAuth -rfbauth /home/user/.config/tigervnc/passwd
        EOF
        systemctl daemon-reload
        systemctl restart qubes-vncserver@user || true
    - require:
      - qvm.run: set-vnc-password
