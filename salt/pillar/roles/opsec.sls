opsec:
  enable: true
  # Debian templates to harden
  deb_templates: ['deb_harden','deb_harden_min','deb_work','deb_hack']

  sysnet_name: sys-net
  # Apply UTC+locale hygiene to Debian templates
  set_utc_and_locale: true
  # Randomize hostname at boot in all AppVMs built from those Debian templates
  randomize_hostname: true
  # dom0 power hygiene
  dom0_disable_sleep: true
