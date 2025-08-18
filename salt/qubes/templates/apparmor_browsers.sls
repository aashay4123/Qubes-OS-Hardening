# Enforce AppArmor for Firefox/Chromium in Debian + Whonix-WS templates

{% for t in ['deb_harden','whonix-workstation-17'] %}
apparmor-install-{{ t }}:
  qvm.run:
    - name: {{ t }}
    - user: root
    - cmd: |
        set -e
        apt-get update -y || true
        apt-get install -y --no-install-recommends apparmor apparmor-utils apparmor-profiles-extra

        # Make sure apparmor service is enabled (template-level)
        systemctl enable apparmor || true

        # Gentle local overrides (Downloads + ~/.cache access)
        mkdir -p /etc/apparmor.d/local

        # Firefox ESR profile names used on Debian/Whonix
        for P in /etc/apparmor.d/usr.bin.firefox* /etc/apparmor.d/usr.lib.firefox*/firefox*; do
          [ -e "$P" ] || continue
          B=$(basename "$P")
          printf "owner @{HOME}/Downloads/** rwk,\nowner @{HOME}/.cache/** rwk,\n" > "/etc/apparmor.d/local/$B"
          aa-enforce "$P" || true
        done

        # Chromium profile names vary; try common ones
        for P in /etc/apparmor.d/usr.bin.chromium* /etc/apparmor.d/usr.lib.chromium*/chromium*; do
          [ -e "$P" ] || continue
          B=$(basename "$P")
          printf "owner @{HOME}/Downloads/** rwk,\nowner @{HOME}/.cache/** rwk,\n" > "/etc/apparmor.d/local/$B"
          aa-enforce "$P" || true
        done
{% endfor %}
