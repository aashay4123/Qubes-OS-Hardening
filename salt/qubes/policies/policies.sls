# Tag only sys-dns as resolver
tag-dns-resolver:
  qvm.tag:
    - name: @tag:dns-resolver
    - vm: [ sys-dns ]

# Policy: allow only @tag:dns-resolver
/etc/qubes/policy.d/30-dns.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        qubes.Dns +allow-all-names @tag:dns-resolver  allow
        qubes.Dns +allow-all-names @anyvm             deny  notify=yes

