{# === EDIT ME === #}
{% set relay_vm         = 'sys-remote' %}
{% set relay_template   = 'fedora-40' %}        # or debian-12
{% set relay_label      = 'yellow' %}
{% set vnc_port         = 5900 %}
{% set allow_ssh_from   = 'any' %}              # 'any' or '203.0.113.55/32' etc
{% set ssh_user         = 'user' %}             # default user inside the relay AppVM
{% set ssh_pubkey       = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexampleYourKeyGoesHere comment' %}

{{ relay_vm }}-create:
  qvm.vm:
    - template: {{ relay_template }}
    - label: {{ relay_label }}
    - prefs:
        netvm: sys-firewall
        autostart: false

# minimal packages + SSH server + nftables
{{ relay_vm }}-pkgs:
  qvm.run:
    - name: {{ relay_vm }}
    - user: root
    - cmd: |
        set -e
        if command -v dnf >/dev/null; then
          dnf -y install openssh-server nftables tigervnc || true
          systemctl enable --now sshd
        else
          apt-get update
          apt-get -y install openssh-server nftables tigervnc-standalone-server || true
          systemctl enable --now ssh
        fi
        systemctl enable nftables || true

# allow only SSH (22) from chosen CIDR; VNC stays loopback-only in relay
{{ relay_vm }}-fw:
  qvm.run:
    - name: {{ relay_vm }}
    - user: root
    - cmd: |
        set -e
        mkdir -p /etc/nftables.d
        cat >/etc/nftables.d/10-relay-base.nft <<'EOF'
        table inet relay {
          chain input {
            type filter hook input priority 0; policy drop;
            iif lo accept; ct state established,related accept;
            ip protocol icmp accept; ip6 nexthdr ipv6-icmp accept;
            tcp dport 22 accept    # SSH
            # VNC ({{ vnc_port }}) intentionally NOT exposed; stays on loopback
          }
          chain forward { type filter hook forward priority 0; policy drop; }
          chain output  { type filter hook output  priority 0; policy accept; }
        }
        EOF
        {% if allow_ssh_from != 'any' %}
        nft add rule inet relay input tcp dport 22 ip saddr {{ allow_ssh_from }} accept
        nft add rule inet relay input tcp dport 22 drop
        {% endif %}
        if ! grep -q 'include "/etc/nftables.d/*.nft"' /etc/nftables.conf 2>/dev/null; then
          echo 'include "/etc/nftables.d/*.nft"' > /etc/nftables.conf
        fi
        systemctl restart nftables

# install your SSH pubkey (password login can be disabled if desired)
{{ relay_vm }}-sshkey:
  qvm.run:
    - name: {{ relay_vm }}
    - user: root
    - cmd: |
        set -e
        install -d -m 0700 /home/{{ ssh_user }}/.ssh
        echo '{{ ssh_pubkey }}' > /home/{{ ssh_user }}/.ssh/authorized_keys
        chown -R {{ ssh_user }}:{{ ssh_user }} /home/{{ ssh_user }}/.ssh
        chmod 0600 /home/{{ ssh_user }}/.ssh/authorized_keys
        # Hardening
        if [ -f /etc/ssh/sshd_config ]; then
          sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config || true
          sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config || true
          systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
        fi

# bind sys-gui-vnc:VNC_PORT -> relay's localhost:VNC_PORT on boot
{{ relay_vm }}-bind:
  qvm.run:
    - name: {{ relay_vm }}
    - user: root
    - cmd: |
        set -e
        install -d -m 0755 /rw/config
        grep -q 'qvm-connect-tcp ::{{ vnc_port }}' /rw/config/rc.local 2>/dev/null || \
          echo 'qvm-connect-tcp ::{{ vnc_port }}' >> /rw/config/rc.local
        chmod +x /rw/config/rc.local
