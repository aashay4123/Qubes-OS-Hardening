# Tag Debian callers
{% for vm in ['work','dev','personal'] %}
tag-{{ vm }}-pass:
  cmd.run:
    - name: qvm-tags {{ vm }} add split-pass-deb || true
{% endfor %}

# Tag Whonix callers
{% for vm in ['ws-tor-research','ws-tor-forums'] %}
tag-{{ vm }}-pass:
  cmd.run:
    - name: qvm-tags {{ vm }} add split-pass-ws || true
{% endfor %}


# /etc/qubes/policy.d/30-pass.policy
/etc/qubes/policy.d/30-pass.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        # Read-only lookup:
        my.pass.Lookup   @tag:split-pass-deb   vault-secrets      allow
        my.pass.Lookup   @tag:split-pass-ws    vault-dn-secrets   allow
        my.pass.Lookup  +allow-all-names                   +allow-all-names                 deny  notify=yes

        # (Optional) listing is often sensitive: you can enable per-group if needed
        my.pass.List     @tag:split-pass-deb   vault-secrets      ask
        my.pass.List     @tag:split-pass-ws    vault-dn-secrets   ask
        my.pass.List    +allow-all-names                   +allow-all-names                 deny  notify=yes
