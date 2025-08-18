{% for t in ['deb_harden','whonix-workstation-17'] %}

{{ t }}-clipdeps:
  qvm.run:
    - name: {{ t }}
    - user: root
    - cmd: |
        set -e
        apt-get update -y || true
        apt-get install -y --no-install-recommends xclip

        
{{ t }}-qpass-clipboard:
  qvm.run:
    - name: {{ t }}
    - user: root
    - cmd: |
        set -e
        install -d -m 755 /usr/local/bin
        cat >/usr/local/bin/qpass <<'EOF'
        #!/bin/sh
        # Usage: qpass <path> [seconds]
        set -eu
        [ $# -ge 1 ] || { echo "Usage: qpass <path> [seconds]"; exit 2; }
        DURATION="${2:-45}"
        PW="$(printf "%s\n" "$1" | qrexec-client-vm vault-secrets my.pass.Lookup)"
        printf "%s" "$PW" | xclip -selection clipboard
        echo "[qpass] Secret copied to clipboard for ${DURATION}s."
        ( sleep "$DURATION"; printf "" | xclip -selection clipboard; echo "[qpass] Clipboard cleared." ) >/dev/null 2>&1 &
        EOF
        chmod 0755 /usr/local/bin/qpass

        cat >/usr/local/bin/qpass-ws <<'EOF'
        #!/bin/sh
        # Usage: qpass-ws <path> [seconds]
        set -eu
        [ $# -ge 1 ] || { echo "Usage: qpass-ws <path> [seconds]"; exit 2; }
        DURATION="${2:-45}"
        PW="$(printf "%s\n" "$1" | qrexec-client-vm vault-dn-secrets my.pass.Lookup)"
        printf "%s" "$PW" | xclip -selection clipboard
        echo "[qpass-ws] Secret copied to clipboard for ${DURATION}s."
        ( sleep "$DURATION"; printf "" | xclip -selection clipboard; echo "[qpass-ws] Clipboard cleared." ) >/dev/null 2>&1 &
        EOF
        chmod 0755 /usr/local/bin/qpass-ws
{% endfor %}
