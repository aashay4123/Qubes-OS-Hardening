{# === EDIT ME === #}
{% set relay_vm   = 'sys-remote' %}
{% set vnc_port   = 5900 %}

# Allow the relay to bind sys-gui-vnc:VNC_PORT to its own localhost:VNC_PORT
policy-connecttcp-5900:
  cmd.run:
    - name: |
        set -e
        install -d -m 0755 /etc/qubes/policy.d
        POLICY="/etc/qubes/policy.d/30-remote-gui.policy"
        LINE="qubes.ConnectTCP +{{ vnc_port }} {{ relay_vm }} @default allow target=sys-gui-vnc"
        if [ ! -f "$POLICY" ] || ! grep -Fqx "$LINE" "$POLICY"; then
          echo "$LINE" >> "$POLICY"
        fi
