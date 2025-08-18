# Tag Debian callers
{% for vm in ['work','dev','personal'] %}
tag-{{ vm }}-split-gpg-ssh:
  cmd.run:
    - name: |
        qvm-tags {{ vm }} add split-gpg-deb || true
        qvm-tags {{ vm }} add split-ssh-deb || true
{% endfor %}

# Tag Whonix callers (add your WS names here)
{% for vm in ['ws-tor-research','ws-tor-forums'] %}
tag-{{ vm }}-split-gpg-ssh:
  cmd.run:
    - name: |
        qvm-tags {{ vm }} add split-gpg-ws || true
        qvm-tags {{ vm }} add split-ssh-ws || true
{% endfor %}


# /etc/qubes/policy.d/30-split-gpg.policy
/etc/qubes/policy.d/30-split-gpg.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        # Debian callers → vault-secrets
        qubes.Gpg  @tag:split-gpg-deb   vault-secrets    allow
        # Whonix callers → vault-dn-secrets
        qubes.Gpg  @tag:split-gpg-ws    vault-dn-secrets allow
        # Everything else denied
        qubes.Gpg  *                    *                deny  notify=yes

        # Optional: allow controlled key import into the right vault (from dom0 or a mgmt VM only)
        qubes.GpgImportKey  @tag:split-gpg-deb   vault-secrets    ask
        qubes.GpgImportKey  @tag:split-gpg-ws    vault-dn-secrets ask
        qubes.GpgImportKey  *                    *                deny  notify=yes

# /etc/qubes/policy.d/30-split-ssh.policy
/etc/qubes/policy.d/30-split-ssh.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        # Debian callers → vault-secrets
        qubes.SshAgent  @tag:split-ssh-deb   vault-secrets    allow
        # Whonix callers → vault-dn-secrets
        qubes.SshAgent  @tag:split-ssh-ws    vault-dn-secrets allow
        # Everything else denied
        qubes.SshAgent  *                    *                deny  notify=yes
