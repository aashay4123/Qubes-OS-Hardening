{# Qubes HVM/Standalone installer helper
   - Creates Standalone HVMs with sensible prefs
   - Boots installer from ISO located in another qube (no ISO in dom0)
   - Drops a sentinel so we don't re-run the installer boot
#}
# sudo strings /sys/firmware/acpi/tables/MSDM


{% set cfg = pillar.get('hvm_install', {}) %}
{% set iso_qube = cfg.get('iso_qube', 'vault_iso') %}
{% set sentinel_root = '/var/lib/qubes/osi_hvm_install' %}

# Ensure sentinel dir exists
hvm-install-sentinel-dir:
  file.directory:
    - name: {{ sentinel_root }}
    - mode: '0755'

{% for key, spec in cfg.get('vms', {}).items() %}
{% set name     = spec.get('name', key) %}
{% set label    = spec.get('label', 'orange') %}
{% set klass    = spec.get('class', 'StandaloneVM') %}
{% set virt     = spec.get('virt_mode', 'hvm') %}
{% set disk     = spec.get('disk', '60g') %}
{% set mem      = spec.get('memory', 4096) %}
{% set maxmem   = spec.get('maxmem', mem) %}
{% set vcpus    = spec.get('vcpus', 2) %}
{% set netvm    = spec.get('netvm', 'sys-firewall') %}
{% set qto      = spec.get('qrexec_timeout', None) %}
{% set cdrom    = spec.get('cdrom_path') %}
{% set sentinel = sentinel_root ~ '/' ~ name ~ '.booted_installer' %}

# Create VM if missing (use CLI to be explicit about class/HVM)
{{ name }}-create:
  cmd.run:
    - name: >
        bash -lc "qvm-check -q {{ name }} || qvm-create --class {{ klass }} --label {{ label }} --property virt_mode={{ virt }} {{ name }}"
    - unless: qvm-check -q {{ name }}

# Base prefs
{{ name }}-prefs:
  qvm.prefs:
    - name: {{ name }}
    - key: kernel
    - value: ''
  require:
    - cmd: {{ name }}-create

{{ name }}-mem:
  qvm.prefs:
    - name: {{ name }}
    - key: memory
    - value: {{ mem }}
  require:
    - cmd: {{ name }}-create

{{ name }}-maxmem:
  qvm.prefs:
    - name: {{ name }}
    - key: maxmem
    - value: {{ maxmem }}
  require:
    - cmd: {{ name }}-create

{{ name }}-vcpus:
  qvm.prefs:
    - name: {{ name }}
    - key: vcpus
    - value: {{ vcpus }}
  require:
    - cmd: {{ name }}-create

{{ name }}-netvm:
  qvm.prefs:
    - name: {{ name }}
    - key: netvm
    - value: {{ netvm }}
  require:
    - cmd: {{ name }}-create

{% if qto %}
{{ name }}-qrexec-timeout:
  qvm.prefs:
    - name: {{ name }}
    - key: qrexec_timeout
    - value: {{ qto }}
  require:
    - cmd: {{ name }}-create
{% endif %}

# Root disk sizing
{{ name }}-disk:
  cmd.run:
    - name: qvm-volume extend {{ name }}:root {{ disk }}
    - unless: |
        bash -lc 'cur=$(qvm-volume info {{ name }}:root | awk "/size:/ {print $2}"); \
                  want="{{ disk }}"; [[ "$cur" == "$want" ]]'
  require:
    - cmd: {{ name }}-create

# First boot from ISO (only once). ISO is served from {{ iso_qube }} qube path {{ cdrom or 'N/A' }}
{% if cdrom %}
{{ name }}-boot-installer-once:
  cmd.run:
    - name: >
        bash -lc 'qvm-start --cdrom={{ iso_qube }}:{{ cdrom }} {{ name }} && touch {{ sentinel }}'
    - unless: test -f {{ sentinel }}
  require:
    - cmd: {{ name }}-disk
    - qvm: {{ name }}-prefs
{% else %}
{{ name }}-boot-installer-skip:
  test.succeed_without_changes:
    - name: "No cdrom_path set for {{ name }}; skipping first-boot."
{% endif %}

{% endfor %}
