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
