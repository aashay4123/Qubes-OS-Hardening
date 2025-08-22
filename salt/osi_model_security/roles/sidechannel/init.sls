{% from "osi_model_security/map.jinja" import cfg with context %}
{% set S = cfg.sidechannel %}
{% if not S.enable %}
sidechannel-disabled:
  test.succeed_without_changes:
    - name: 'sidechannel role disabled by pillar'
{% else %}
{% for vm, p in S.vms.items() %}
{{ vm }}-sc-vcpus:
  qvm.prefs:
    - name: {{ vm }}
    - key: vcpus
    - value: {{ p.vcpus }}

{{ vm }}-sc-cpu-affinity:
  qvm.prefs:
    - name: {{ vm }}
    - key: cpu-affinity
    - value: {{ p.cpu_affinity }}

{{ vm }}-sc-mem:
  qvm.prefs:
    - name: {{ vm }}
    - key: memory
    - value: {{ p.memory }}

{{ vm }}-sc-maxmem:
  qvm.prefs:
    - name: {{ vm }}
    - key: maxmem
    - value: {{ p.maxmem }}
{% endfor %}
{% endif %}
