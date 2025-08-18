# Install tiny client wrappers in Debian and Whonix WS templates.
# Debian callers use vault-secrets; Whonix callers use vault-dn-secrets.

{% for t in ['deb_harden','whonix-workstation-17'] %}
{{ t }}-client-wrappers:
  qvm.run:
    - name: {{ t }}
    - user: root
    - cmd: |
        set -e
        install -d -m 755 /usr/local/bin
        # Debian-oriented wrapper (targets vault-secrets)
        cat >/usr/local/bin/qpass <<'EOF'
        #!/bin/sh
        set -eu
        if [ $# -lt 1 ]; then echo "Usage: qpass <path/in/store>"; exit 2; fi
        printf "%s\n" "$1" | qrexec-client-vm vault-secrets my.pass.Lookup
        EOF
        chmod 0755 /usr/local/bin/qpass

        # Whonix-oriented wrapper (targets vault-dn-secrets)
        cat >/usr/local/bin/qpass-ws <<'EOF'
        #!/bin/sh
        set -eu
        if [ $# -lt 1 ]; then echo "Usage: qpass-ws <path/in/store>"; exit 2; fi
        printf "%s\n" "$1" | qrexec-client-vm vault-dn-secrets my.pass.Lookup
        EOF
        chmod 0755 /usr/local/bin/qpass-ws
{% endfor %}
