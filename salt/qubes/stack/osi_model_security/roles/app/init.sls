{% from "osi_model_security/map.jinja" import cfg with context %}

{# Sandbox tooling in templates used by app VMs #}
{% set app_templates = [] %}
{% for _, spec in cfg.app_vms.items() %}
  {% if spec.get('template') %}{% do app_templates.append(spec.get('template')) %}{% endif %}
{% endfor %}
{% for tpl in app_templates|unique %}
template-{{ tpl }}-sandbox-tools:
  module.run:
    - name: qvm.run
    - vm: {{ tpl }}
    - args:
      - |
        sh -lc '
          if command -v apt-get >/dev/null; then
            apt-get -y install firejail apparmor apparmor-utils
            systemctl enable apparmor || true; systemctl start apparmor || true
          else
            dnf -y install firejail || true
          fi
        '
{% endfor %}

{# Per-VM firewall rules with default drop #}
{% set svcmap = {
  'dns':   [{'proto': 'udp', 'dst_ports': '53'}],
  'dot':   [{'proto': 'tcp', 'dst_ports': '853'}],
  'http':  [{'proto': 'tcp', 'dst_ports': '80'}],
  'https': [{'proto': 'tcp', 'dst_ports': '443'}],
  'ssh':   [{'proto': 'tcp', 'dst_ports': '22'}],
  'ntp':   [{'proto': 'udp', 'dst_ports': '123'}]
} %}

{% for name, spec in cfg.app_vms.items() %}
{{ name }}-firewall:
  qvm.firewall:
    - name: {{ name }}
    - default: drop
    - rules:
      {% for svc in spec.get('allow', ['https','dns']) %}
      {% for r in svcmap.get(svc, []) %}
      - action: accept
        proto: {{ r.proto }}
        dst_ports: {{ r.dst_ports }}
      {% endfor %}
      {% endfor %}
  require:
    - qvm: {{ name }}-present
{% endfor %}
