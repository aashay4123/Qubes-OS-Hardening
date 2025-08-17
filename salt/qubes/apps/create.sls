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
{% for vm in ['vault-secrets','vault-storage'] %}

{{ vm }}-create:
  qvm.vm:
    - template: {{ tmpl }}
    - label: purple
    - prefs: { netvm: none }

{% endfor %}


# Tor profiles
anon-tor1:
  qvm.vm:
    - template: whonix-ws-17
    - label: yellow
    - prefs: { netvm: sys-whonix }

anon-tor2:
  qvm.vm:
    - template: whonix-ws-17
    - label: yellow
    - prefs: { netvm: sys-whonix }

# VPN profiles
anon-vpn-ru:
  qvm.vm:
    - template: deb12-anon
    - label: yellow
    - prefs: { netvm: sys-vpn-ru }

anon-vpn-nl:
  qvm.vm:
    - template: deb12-anon
    - label: yellow
    - prefs: { netvm: sys-vpn-nl }
