# Split-GPG + Split-SSH vault on debian-12-xfce, no network.
# Wires clients: work, pro, personal, anon-whonix.
# Creates/refreshes "secrets-vault" AppVM; configures policies, client helpers, and verifies.

# ---------- 0) Preconditions ----------
check-template-xfce-present:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx debian-12-xfce'"

# ---------- 1) Create / enforce the vault VM ----------
remove-old-secrets-vault-conflict:   # only removes if a *stuck* DispVMTemplate/AppVM named the same exists
  cmd.run:
    - name: "/bin/sh -c 'if qvm-ls --raw-data | awk -F\"|\" \"/\\|secrets-vault\\|/ {print \$2}\" | grep -q \"\\(DispVMTemplate\\|StandaloneVM\\)\"; then qvm-shutdown --wait secrets-vault 2>/dev/null || true; qvm-remove -f secrets-vault; fi'"

create-secrets-vault:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx secrets-vault || qvm-create -C AppVM -t debian-12-xfce -l red secrets-vault'"
    - require:
      - cmd: check-template-xfce-present
      - cmd: remove-old-secrets-vault-conflict

secrets-vault-no-net:
  qvm.prefs:
    - name: secrets-vault
    - netvm: ''           # absolutely no network
    - require:
      - cmd: create-secrets-vault

secrets-vault-label:
  qvm.prefs:
    - name: secrets-vault
    - label: red
    - require:
      - cmd: create-secrets-vault

# ---------- 2) Vault packages + SSH agent in the vault ----------
secrets-vault-install-core:
  qvm.run:
    - name: secrets-vault
    - user: root
    - cmd: "env DEBIAN_FRONTEND=noninteractive apt-get -y update && apt-get -y install qubes-gpg-split gnupg pinentry-gtk2 openssh-client socat"
    - require:
      - qvm: secrets-vault-no-net    # still no-net (APT via template; installs into private volume)

# Vault qrexec server for split-ssh: /etc/qubes-rpc/qubes.SshAgent
secrets-vault-sshagent-rpc:
  qvm.run:
    - name: secrets-vault
    - user: root
    - cmd: "/bin/sh -c 'install -d -m 0755 /etc/qubes-rpc; cat > /etc/qubes-rpc/qubes.SshAgent <<\"EOF\"\n#!/bin/sh\nset -eu\n: \"${SSH_AUTH_SOCK:=/run/user/1000/ssh-agent.sock}\"\nexec socat - \"UNIX-CONNECT:${SSH_AUTH_SOCK}\"\nEOF\nchmod 0755 /etc/qubes-rpc/qubes.SshAgent'"
    - require:
      - qvm: secrets-vault-install-core

# Vault user-level ssh-agent systemd unit
secrets-vault-sshagent-service:
  qvm.run:
    - name: secrets-vault
    - user: root
    - cmd: "/bin/sh -c 'install -d -m 0755 ~user/.config/systemd/user; cat > ~user/.config/systemd/user/ssh-agent.service <<\"EOF\"\n[Unit]\nDescription=SSH Agent (Split-SSH vault)\n\n[Service]\nType=simple\nEnvironment=SSH_AUTH_SOCK=/run/user/%U/ssh-agent.sock\nExecStart=/usr/bin/ssh-agent -D -a ${SSH_AUTH_SOCK}\n\n[Install]\nWantedBy=default.target\nEOF\nchown -R user:user ~user/.config'"
    - require:
      - qvm: secrets-vault-install-core

secrets-vault-sshagent-enable:
  qvm.run:
    - name: secrets-vault
    - user: user
    - cmd: "systemctl --user enable --now ssh-agent.service || systemctl --user restart ssh-agent.service"
    - require:
      - qvm: secrets-vault-sshagent-service

# ---------- 3) Client-side helpers (work, pro, personal, anon-whonix) ----------
# (a) write Split-GPG domain hint file used by qubes-gpg-client-wrapper
define-gpg-domain-work:
  qvm.run:
    - name: work
    - user: root
    - cmd: "/bin/sh -c 'install -d -m 0755 /rw/config; echo secrets-vault > /rw/config/gpg-split-domain; chmod 0644 /rw/config/gpg-split-domain'"

define-gpg-domain-pro:
  qvm.run:
    - name: pro
    - user: root
    - cmd: "/bin/sh -c 'install -d -m 0755 /rw/config; echo secrets-vault > /rw/config/gpg-split-domain; chmod 0644 /rw/config/gpg-split-domain'"

define-gpg-domain-personal:
  qvm.run:
    - name: personal
    - user: root
    - cmd: "/bin/sh -c 'install -d -m 0755 /rw/config; echo secrets-vault > /rw/config/gpg-split-domain; chmod 0644 /rw/config/gpg-split-domain'"

define-gpg-domain-anon:
  qvm.run:
    - name: anon-whonix
    - user: root
    - cmd: "/bin/sh -c 'install -d -m 0755 /rw/config; echo secrets-vault > /rw/config/gpg-split-domain; chmod 0644 /rw/config/gpg-split-domain'"

# (b) ensure client VMs have qubes-gpg client bits (wrapper) and socat for Split-SSH
clients-install-tools:
  cmd.run:
    - name: >
        /bin/sh -c '
        for vm in work pro personal anon-whonix; do
          qvm-run -u root -p "$vm" "env DEBIAN_FRONTEND=noninteractive apt-get -y update && apt-get -y install qubes-gpg-split gnupg socat openssh-client" || exit 1;
        done
        '

# (c) install an opt-in SSH helper wrapper `ssh-vault` in clients (does not override ssh)
clients-install-ssh-wrapper:
  cmd.run:
    - name: >
        /bin/sh -c '
        for vm in work pro personal anon-whonix; do
          qvm-run -u root "$vm" "/bin/sh -c \"install -d -m 0755 /usr/local/bin; cat > /usr/local/bin/ssh-vault <<\\\"EOF\\\"\n#!/bin/sh\nset -eu\nVM=\\\"\\${QUBES_SSH_VAULT:-secrets-vault}\\\"\nSOCK=\\\"/run/user/1000/ssh-from-vault.sock\\\"\n# kill prior listener if any\nif [ -S \\\"$SOCK\\\" ]; then rm -f \\\"$SOCK\\\"; fi\n# start a background agent socket forwarder\n( socat UNIX-LISTEN:\\\"$SOCK\\\",fork EXEC:\\\"qrexec-client-vm $VM qubes.SshAgent\\\" ) >/dev/null 2>&1 &\nsleep 0.2\nexport SSH_AUTH_SOCK=\\\"$SOCK\\\"\nexec ssh \\\"$@\\\"\nEOF\nchmod 0755 /usr/local/bin/ssh-vault\" "
        done
        '
    - require:
      - cmd: clients-install-tools

# ---------- 4) dom0 qrexec policies (Split-GPG + Split-SSH) ----------
# Qubes 4.2 policy lives in /etc/qubes/policy.d/*.policy
split-gpg-policy:
  cmd.run:
    - name: >
        /bin/sh -c '
        f=/etc/qubes/policy.d/30-split-gpg.policy;
        umask 022;
        {
          echo "qubes.Gpg  work         secrets-vault    allow";
          echo "qubes.Gpg  pro          secrets-vault    allow";
          echo "qubes.Gpg  personal     secrets-vault    allow";
          echo "qubes.Gpg  anon-whonix  secrets-vault    allow";
          echo "qubes.Gpg  @anyvm       @anyvm           ask default_target=secrets-vault";
        } > "$f";
        '
    - require:
      - qvm: secrets-vault-no-net

split-ssh-policy:
  cmd.run:
    - name: >
        /bin/sh -c '
        f=/etc/qubes/policy.d/30-split-ssh.policy;
        umask 022;
        {
          echo "qubes.SshAgent  work         secrets-vault    allow";
          echo "qubes.SshAgent  pro          secrets-vault    allow";
          echo "qubes.SshAgent  personal     secrets-vault    allow";
          echo "qubes.SshAgent  anon-whonix  secrets-vault    allow";
          echo "qubes.SshAgent  @anyvm       @anyvm           ask";
        } > "$f";
        '

# ---------- 5) Verification ----------
verify-vault-exists:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx secrets-vault'"

verify-vault-template:
  cmd.run:
    - name: "/bin/sh -c '[ \"$(qvm-prefs secrets-vault template)\" = \"debian-12-xfce\" ]'"
    - require:
      - cmd: verify-vault-exists

verify-vault-no-net:
  cmd.run:
    - name: "/bin/sh -c '[ -z \"$(qvm-prefs secrets-vault netvm)\" ]'"
    - require:
      - cmd: verify-vault-exists

verify-gpg-policy:
  cmd.run:
    - name: "/bin/sh -c 'grep -q \"qubes.Gpg\" /etc/qubes/policy.d/30-split-gpg.policy'"

verify-ssh-policy:
  cmd.run:
    - name: "/bin/sh -c 'grep -q \"qubes.SshAgent\" /etc/qubes/policy.d/30-split-ssh.policy'"

verify-gpg-client-configs:
  cmd.run:
    - name: >
        /bin/sh -c '
        for vm in work pro personal anon-whonix; do
          qvm-run -u root -p "$vm" "test -f /rw/config/gpg-split-domain && grep -qx secrets-vault /rw/config/gpg-split-domain" || exit 1;
        done
        '

# ---------- 6) Summary ----------
split-secrets-summary:
  cmd.run:
    - name: |
        /bin/sh -c '
        printf "\n=== Split Secrets Summary ===\n"
        printf "Vault        : secrets-vault (template=%s, netvm=%s)\n" "$(qvm-prefs secrets-vault template)" "$(qvm-prefs secrets-vault netvm)"
        printf "Policies:\n  - /etc/qubes/policy.d/30-split-gpg.policy\n  - /etc/qubes/policy.d/30-split-ssh.policy\n"
        printf "\nClients wired for GPG + SSH: work, pro, personal, anon-whonix\n"
        printf "Client SSH helper: /usr/local/bin/ssh-vault (use instead of ssh)\n\n"
        '
    - require:
      - cmd: verify-vault-exists
      - cmd: verify-vault-template
      - cmd: verify-vault-no-net
      - cmd: verify-gpg-policy
      - cmd: verify-ssh-policy
      - cmd: verify-gpg-client-configs
