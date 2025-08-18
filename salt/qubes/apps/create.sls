# /srv/salt/qubes/apps/create.sls

# Work/Personal/Dev
{% set tmpl = 'deb_harden' %}
{% set default_netvm = 'sys-firewall' %}
{% for vm in ['work','dev'] %}

{{ vm }}-create:
  qvm.vm:
    - template: {{ tmpl }}
    - label: yellow
    - prefs:
        netvm: {{ default_netvm }}
        autostart: False

{% endfor %}


# Pentest
hack:
  qvm.vm:
    - template: deb_harden
    - label: red
    - prefs: { netvm: sys-firewall }

# Vaults (no net)

{% set tmpl = 'deb_harden_min' %}
{% set default_netvm = 'sys-firewall' %}
{% for vm in ['vault-secrets','vault-dn-secrets','vault-storage'] %}

{{ vm }}-create:
  qvm.vm:
    - template: {{ tmpl }}
    - label: purple
    - prefs: { netvm: none }

{% endfor %}



# Create two Workstations that must use the VPN⇒Tor gateway
#   ws-tor-research  (strict research persona)
#   ws-tor-forums    (forums/help persona)

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

