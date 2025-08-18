whonix-ws-template-present:
  cmd.run:
    - name: qvm-ls --raw-list | grep -qx whonix-workstation-17 || qvm-template install whonix-workstation-17

{% for ws in ['ws-tor-research','ws-tor-forums'] %}
{{ ws }}-create:
  cmd.run:
    - name: |
        set -e
        if ! qvm-ls --raw-list | grep -qx {{ ws }}; then
          qvm-create --class AppVM --template whonix-workstation-17 --label purple {{ ws }}
          qvm-prefs {{ ws }} netvm sys-vpn-tor
        fi
