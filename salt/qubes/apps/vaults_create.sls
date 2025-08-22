# Create two networkless vaults and install Split-GPG/SSH server bits
# - vault-secrets (Debian)
# - vault-dn-secrets (Whonix-WS)

ensure-deb-harden:
  cmd.run:
    - name: qvm-ls --raw-list | grep -qx deb_harden || qvm-template install debian-12

ensure-whonix-ws:
  cmd.run:
    - name: qvm-ls --raw-list | grep -qx whonix-workstation-17 || qvm-template install whonix-workstation-17


# Server-side: set up pass + qrexec in both vaults.

{% for vlt in ['vault-secrets','vault-dn-secrets'] %}

{{ vlt }}-secrets-create:
  cmd.run:
    - name: |
        set -e
        if ! qvm-ls --raw-list | grep -qx {{ vlt }}; then
          qvm-create --class AppVM --template whonix-workstation-17 --label black {{ vlt }}
          qvm-prefs {{ vlt }} netvm none
        fi

{{ vlt }}-tag:
  cmd.run:
    - name: |
        qvm-tags {{ vlt }} add secrets-vault || true

{{ vlt }}-secrets-init:
  qvm.run:
    - name: {{ vlt }}
    - user: root
    - cmd: |
        set -e
        apt-get update -y || true
        apt-get install -y --no-install-recommends \
          gnupg gpg-agent qubes-gpg-split qubes-app-linux-split-ssh openssh-client
        # GnuPG owner perms
        install -d -m 700 -o user -g user /home/user/.gnupg
        chown -R user:user /home/user/.gnupg
        # Optional: restrict SSH known_hosts/keys dir
        install -d -m 700 -o user -g user /home/user/.ssh

{{ vlt }}-pass-install:
  qvm.run:
    - name: {{ vlt }}
    - user: root
    - cmd: |
        set -e
        apt-get update -y || true
        apt-get install -y --no-install-recommends pass git gnupg gpg-agent
        # Password store directory with safe permissions
        install -d -m 700 -o user -g user /home/user/.password-store
        # Ensure a GPG ID file exists (user should replace with their key ID)
        if [ ! -s /home/user/.password-store/.gpg-id ]; then
          echo "# TODO: inside {{ vlt }}, run:  pass init <YOUR-GPG-KEY-ID>" > /home/user/.password-store/.gpg-id
          chown user:user /home/user/.password-store/.gpg-id
        fi
        # Optional: initialize a bare git repo for store versioning (can point to remote later)
        if [ ! -d /home/user/.password-store/.git ]; then
          su -l user -c 'cd ~/.password-store && git init'
        fi

{{ vlt }}-rpc-service:
  qvm.run:
    - name: {{ vlt }}
    - user: root
    - cmd: |
        set -e
        install -d -m 755 /etc/qubes-rpc
        # Lookup service: reads one line path on stdin, prints first line (password) to stdout
        cat >/etc/qubes-rpc/my.pass.Lookup <<'EOF'
        #!/bin/sh
        set -eu
        # Read the secret path from stdin (e.g., github.com/user)
        read PATH_SPEC || exit 1
        export PASSWORD_STORE_DIR="/home/user/.password-store"
        # Use the unprivileged user to run pass
        su -s /bin/sh -l user -c "PASS_EXIT_FORCE=1 pass show -- \"$PATH_SPEC\"" 2>/dev/null | head -n1
        exit 0
        EOF
        chmod 0755 /etc/qubes-rpc/my.pass.Lookup

        # (Optional) my.pass.List to list entries; comment out if you prefer not to expose it.
        cat >/etc/qubes-rpc/my.pass.List <<'EOF'
        #!/bin/sh
        set -eu
        export PASSWORD_STORE_DIR="/home/user/.password-store"
        su -s /bin/sh -l user -c "pass ls" | sed 's/^[[:space:]]*//'
        EOF
        chmod 0755 /etc/qubes-rpc/my.pass.List
{% endfor %}
