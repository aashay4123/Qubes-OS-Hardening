{# ====== remote_gui: secure remote control of Qubes via sys-gui (Qubes 4.2) ====== #}
{% set RG      = salt['pillar.get']('remote_gui', {}) %}
{% set ENABLE  = RG.get('enable', False) %}
{% set GUIVM   = RG.get('guivm', 'sys-gui') %}
{% set NETVM   = RG.get('netvm', 'sys-net') %}
{% set MACIP   = RG.get('mac_client_ip', '') %}
{% set VAULT   = RG.get('vault_ssh', 'vault-ssh') %}
{% set SSHUSER = RG.get('ssh_user', 'user') %}
{% set PUBS    = RG.get('pubkey_paths', ['/home/user/.ssh/id_ed25519.pub','/home/user/.ssh/id_rsa.pub']) %}

{% if not ENABLE %}
remote-gui-disabled:
  test.show_notification:
    - text: "remote_gui.enable == false; skipping remote GUI provisioning."
{% else %}

/etc/osi:
  file.directory:
    - mode: '0755'

/etc/osi/remote-gui.env:
  file.managed:
    - mode: '0644'
    - contents: |
        GUIVM="{{ GUIVM }}"
        NETVM="{{ NETVM }}"
        MACIP="{{ MACIP }}"
        VAULT="{{ VAULT }}"
        SSHUSER="{{ SSHUSER }}"

# --- 0) Create GUI domain via the official formula if missing ---
sys-gui-bootstrap:
  cmd.run:
    - name: qubesctl state.sls qvm.sys-gui
    - unless: qvm-ls --raw-list | grep -qx {{ GUIVM|regex_escape }}
    - timeout: 1200

# Ensure GUIVM exists (if user created themselves, skip)
sys-gui-exists:
  cmd.run:
    - name: qvm-ls --raw-list | grep -qx {{ GUIVM|regex_escape }}
    - unless: "! qvm-ls --raw-list | grep -qx {{ GUIVM|regex_escape }}"

# --- 1) Wire GUIVM to chosen NetVM (still no network for dom0) ---
sys-gui-netvm:
  cmd.run:
    - name: |
        cur=$(qvm-prefs -g {{ GUIVM }} netvm 2>/dev/null || echo "")
        if [ "$cur" != "{{ NETVM }}" ]; then qvm-prefs {{ GUIVM }} netvm {{ NETVM }}; fi
    - require:
      - cmd: sys-gui-exists

# --- 2) Install packages & configure services inside GUIVM ---
sys-gui-packages:
  qvm.run:
    - name: {{ GUIVM }}
    - user: root
    - cmd: |
        set -e
        # Fedora or Debian minimal support
        if command -v dnf >/dev/null; then
          dnf -y install xrdp xorgxrdp openssh-server nftables fail2ban || true
          systemctl enable --now sshd || true
        elif command -v apt-get >/dev/null; then
          apt-get update -y || true
          apt-get install -y --no-install-recommends xrdp xorgxrdp openssh-server nftables fail2ban || true
          systemctl enable --now ssh || systemctl enable --now sshd || true
        fi
        systemctl enable --now xrdp || true
        systemctl enable --now nftables || true
    - require:
      - cmd: sys-gui-netvm

# xrdp: bind to localhost only; basic sane limits
sys-gui-xrdp-conf:
  qvm.run:
    - name: {{ GUIVM }}
    - user: root
    - cmd: |
        set -eu
        mkdir -p /etc/xrdp /etc/xrdp/sesman.d
        sed -i 's/^port=.*/port=3389/' /etc/xrdp/xrdp.ini 2>/dev/null || true
        # Ensure bind to localhost only (no direct LAN exposure)
        if grep -q '^address=' /etc/xrdp/xrdp.ini 2>/dev/null; then
          sed -i 's/^address=.*/address=127.0.0.1/' /etc/xrdp/xrdp.ini
        else
          echo "address=127.0.0.1" >> /etc/xrdp/xrdp.ini
        fi
        # Tighten a few defaults
        sed -i 's/^#* max_bpp=.*/max_bpp=24/' /etc/xrdp/xrdp.ini || true
        sed -i 's/^#* tcp_nodelay=.*/tcp_nodelay=true/' /etc/xrdp/xrdp.ini || true
        systemctl restart xrdp || true
    - require:
      - qvm.run: sys-gui-packages

# sshd hardened (keys only), allow the standard 'user'
sys-gui-sshd-harden:
  qvm.run:
    - name: {{ GUIVM }}
    - user: root
    - cmd: |
        set -eu
        mkdir -p /etc/ssh/sshd_config.d
        cat >/etc/ssh/sshd_config.d/60-remote-gui.conf <<'EOF'
        PasswordAuthentication no
        PubkeyAuthentication yes
        PermitRootLogin no
        KbdInteractiveAuthentication no
        ChallengeResponseAuthentication no
        AllowUsers {{ SSHUSER }}
        MaxAuthTries 3
        LoginGraceTime 20
        AllowAgentForwarding no
        X11Forwarding no
        GatewayPorts no
        ClientAliveInterval 60
        ClientAliveCountMax 2
        EOF
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    - require:
      - qvm.run: sys-gui-packages

# nftables on sys-gui: accept established, localhost, and ssh from MACIP only; drop rest
sys-gui-nft:
  qvm.run:
    - name: {{ GUIVM }}
    - user: root
    - cmd: |
        set -eu
        install -d -m 755 /etc/nftables.d
        cat >/etc/nftables.d/50-remote-gui.nft <<'EOF'
        table inet filter {
          chain input {
            type filter hook input priority 0;
            policy drop;
            ct state established,related accept
            iif lo accept
            tcp dport 22 ip saddr {{ MACIP }}/32 accept
            tcp dport 22 ip6 saddr ::1/128 accept
            # log dropped packets with a low rate to avoid noise
            limit rate 10/second burst 20 packets log prefix "sys-gui nft drop: " flags all counter drop
          }
        }
        EOF
        # Merge into main ruleset
        if ! grep -q "include \"/etc/nftables.d/*.nft\"" /etc/nftables.conf 2>/dev/null; then
          echo 'include "/etc/nftables.d/*.nft"' >> /etc/nftables.conf
        fi
        nft -f /etc/nftables.conf || true
        systemctl enable --now nftables || true
    - require:
      - qvm.run: sys-gui-packages

# --- 3) Pull your SSH public key from vault-ssh and install in sys-gui ---
sys-gui-authorized-keys:
  cmd.run:
    - name: |
        set -euo pipefail
        tmp=$(mktemp)
        found=0
        {% for p in PUBS %}
        if qvm-run -q --pass-io {{ VAULT|regex_escape }} 'test -s {{ p|regex_escape }} && cat {{ p|regex_escape }}' >"$tmp" 2>/dev/null; then
          found=1
        fi
        {% endfor %}
        if [ "$found" -eq 0 ]; then
          echo "No pubkey found in {{ VAULT }} (paths: {{ PUBS|join(', ') }})" >&2
          exit 1
        fi
        qvm-run -q --pass-io {{ GUIVM|regex_escape }} "install -d -m 700 /home/{{ SSHUSER }}/.ssh && cat > /home/{{ SSHUSER }}/.ssh/authorized_keys && chown -R {{ SSHUSER }}:{{ SSHUSER }} /home/{{ SSHUSER }}/.ssh && chmod 600 /home/{{ SSHUSER }}/.ssh/authorized_keys" < "$tmp"
        rm -f "$tmp"
    - require:
      - qvm.run: sys-gui-sshd-harden

# --- 4) DNAT on sys-net: forward TCP/22 from your Mac → sys-gui (but *not* 3389) ---
# We compute GUIVM IP once and provide a refresh tool if it changes later.
remote-gui-dnat-push:
  cmd.run:
    - name: |
        set -euo pipefail
        GUIIP="$(qvm-ls --raw-data --fields NAME,IP | awk -F'|' '$1=="{{ GUIVM }}"{gsub(/ /,"",$2);print $2}')"
        [ -n "$GUIIP" ] || { echo "Could not resolve {{ GUIVM }} IP"; exit 2; }
        # ship a small service + rules to sys-net
        qvm-run -q -u root --pass-io {{ NETVM|regex_escape }} 'install -d -m 755 /etc/remote-gui' </dev/null
        echo "$GUIIP" | qvm-run -q -u root --pass-io {{ NETVM|regex_escape }} 'cat > /etc/remote-gui/sys-gui.ip'
        qvm-run -q -u root --pass-io {{ NETVM|regex_escape }} 'cat > /etc/remote-gui/remote-gui.nft' <<'EOF'
        define macip = {{ MACIP }}
        define guiip = { $(cat /etc/remote-gui/sys-gui.ip) }
        table ip nat {
          chain prerouting {
            type nat hook prerouting priority -100;
            # SSH only: from MAC to laptop IP → DNAT to sys-gui:22
            tcp dport 22 ip saddr $macip dnat to $guiip:22
          }
        }
        EOF
        qvm-run -q -u root --pass-io {{ NETVM|regex_escape }} 'cat > /etc/systemd/system/remote-gui-nat.service' <<'EOF'
        [Unit]
        Description=DNAT SSH from MAC to sys-gui
        After=network-online.target
        Wants=network-online.target
        [Service]
        Type=oneshot
        ExecStart=/usr/sbin/nft -f /etc/remote-gui/remote-gui.nft
        RemainAfterExit=yes
        [Install]
        WantedBy=multi-user.target
        EOF
        qvm-run -q -u root --pass-io {{ NETVM|regex_escape }} 'systemctl daemon-reload && systemctl enable --now remote-gui-nat.service'
    - require:
      - cmd: sys-gui-exists

# --- 5) Dom0 helper to refresh DNAT if GUIVM IP ever changes ---
/usr/local/sbin/remote-gui-refresh:
  file.managed:
    - mode: '0755'
    - contents: |
        #!/bin/bash
        set -euo pipefail
        GUI="{{ GUIVM }}"; NET="{{ NETVM }}"
        IP="$(qvm-ls --raw-data --fields NAME,IP | awk -F'|' -v n="$GUI" '$1==n{gsub(/ /,"",$2);print $2}')"
        [ -n "$IP" ] || { echo "Could not get IP for $GUI"; exit 2; }
        echo "$IP" | qvm-run -q -u root --pass-io "$NET" 'cat > /etc/remote-gui/sys-gui.ip'
        qvm-run -q -u root "$NET" 'systemctl restart remote-gui-nat.service'
        echo "Updated DNAT to $IP"

{% endif %}
