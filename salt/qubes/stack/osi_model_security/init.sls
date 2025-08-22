{# import cfg & templates #}
{% from "osi_model_security/map.jinja" import cfg, templates with context %}

# 0) Ensure VMs exist, labeled, and tagged
{% for name, spec in cfg.vms.items() %}
{{ name }}-present:
  qvm.present:
    - name: {{ name }}
    - template: {{ spec.template }}
    - label: {{ spec.get('label', 'green') }}
    - prefs:
        {% if spec.get('provides_network', False) %}provides_network: True{% endif %}
        {% if spec.get('netvm') %}netvm: {{ spec.netvm }}{% endif %}
        {% if spec.get('memory') %}memory: {{ spec.memory }}{% endif %}
        {% if spec.get('maxmem') %}maxmem: {{ spec.maxmem }}{% endif %}

{{ name }}-tags:
  qvm.tags:
    - name: {{ name }}
    - add:
      - layer_{{ spec.get('layer', 'app') }}
      {% for t in spec.get('tags', []) %}- {{ t }}{% endfor %}
  require:
    - qvm: {{ name }}-present
{% endfor %}

{% for name, spec in cfg.app_vms.items() %}
{{ name }}-present:
  qvm.present:
    - name: {{ name }}
    - template: {{ spec.template }}
    - label: {{ spec.get('label', 'green') }}

{{ name }}-tags:
  qvm.tags:
    - name: {{ name }}
    - add:
      - layer_app
      {% for t in spec.get('tags', []) %}- {{ t }}{% endfor %}
  require:
    - qvm: {{ name }}-present
{% endfor %}

# 1) Include layered roles
include:
  - osi_model_security.roles.usb
  - osi_model_security.roles.net
  - osi_model_security.roles.dns
  - osi_model_security.roles.firewall
  - osi_model_security.roles.ids
  - osi_model_security.roles.transport
  - osi_model_security.roles.app
  - osi_model_security.roles.dispvm 
  
# 2) NetVM chain (app → sys-firewall → sys-dns → sys-ids → sys-net) from pillar
{% if cfg.vms.get('sys-firewall') and cfg.vms.get('sys-firewall').get('netvm') %}
sys-firewall-netvm:
  qvm.prefs:
    - name: sys-firewall
    - key: netvm
    - value: {{ cfg.vms.get('sys-firewall').get('netvm') }}
  require:
    - qvm: sys-firewall-present
{% endif %}

{% if cfg.vms.get('sys-dns') and cfg.vms.get('sys-dns').get('netvm') %}
sys-dns-netvm:
  qvm.prefs:
    - name: sys-dns
    - key: netvm
    - value: {{ cfg.vms.get('sys-dns').get('netvm') }}
  require:
    - qvm: sys-dns-present
{% endif %}

{% if cfg.vms.get('sys-ids') and cfg.vms.get('sys-ids').get('netvm') %}
sys-ids-netvm:
  qvm.prefs:
    - name: sys-ids
    - key: netvm
    - value: {{ cfg.vms.get('sys-ids').get('netvm') }}
  require:
    - qvm: sys-ids-present
{% endif %}

{% for name, spec in cfg.app_vms.items() %}
{{ name }}-netvm:
  qvm.prefs:
    - name: {{ name }}
    - key: netvm
    - value: {{ spec.get('netvm', 'sys-firewall') }}
  require:
    - qvm: {{ name }}-present
{% endfor %}
