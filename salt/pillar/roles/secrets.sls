secrets:
  vaults: { gpg: vault-gpg, ssh: vault-ssh, pass: vault-pass }

  # Requestor TAGs that may use each *operation* (strictest first)
  ops_allow_from_tags:
    sign:    [work, prod]
    decrypt: [work]
    encrypt: [work, dev]
    verify:  [work, dev, prod]

  # classic services (from earlier)
  allow_from_tags:
    gpg:  [work, dev, prod]
    ssh:  [work, dev]
    pass: [work]

  fallback: { gpg: ask, ssh: ask, pass: ask }

  # maintenance window for import/export (minutes) + tag name
  maintenance:
    tag: gpg_admin_30m
    minutes: 30

  # client conveniences
  client: { set_env_domains: true, add_wrappers: true, advanced_wrappers: true }

  packages:
    client_debian:  [qubes-gpg-client, pinentry-gtk2, pass, git, openssh-client]
    client_fedora:  [qubes-gpg-split, pinentry-gtk,  pass, git, openssh-clients]
    vault_debian:   [gnupg2, pinentry-gtk2, pass, git, openssh-client]
    vault_fedora:   [gnupg2, pinentry-gtk,  pass, git, openssh-clients]

  logging:
    enable_audit_log: true
    # anything matching these services will be mirrored into /var/log/qubes/audit-secrets.log
    services_regex: '(gpg\\.|qubes\\.Gpg|qubes\\.SshAgent|qubes\\.PassLookup)'

