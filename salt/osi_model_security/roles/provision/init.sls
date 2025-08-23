{# Data comes from map.jinja #}
{% from "osi_model_security/map.jinja" import cfg with context %}
{% set VMS        = cfg.get('vms', {}) %}
{% set APP_VMS    = cfg.get('app_vms', {}) %}
{% set DISP       = cfg.get('disposables', {}) %}
{% set FORCE_POL  = DISP.get('force_policies', {'openurl_tags': [], 'openinvm_tags': []}) %}
{% set FALLBACK   = DISP.get('fallback', {'openurl': 'ask', 'openinvm': 'ask'}) %}

{# ---------- helpers ---------- #}
{% macro sh(multi) -%}
  cmd.run:
    - name: |
        set -e
{{ multi|indent(8) }}
{%- endmacro %}

{# Map friendly service names -> (proto,ports, dst net) #}
{% set svcmap = {
  'dns':   [{'proto':'udp','dstports':'53'},{'proto':'tcp','dstports':'53'}],
  'ntp':   [{'proto':'udp','dstports':'123'}],
  'http':  [{'proto':'tcp','dstports':'80'}],
  'https': [{'proto':'tcp','dstports':'443'}],
  'ssh':   [{'proto':'tcp','dstports':'22'}],
  'smtp':  [{'proto':'tcp','dstports':'25'}],
  'submission': [{'proto':'tcp','dstports':'587'}],
  'imap':  [{'proto':'tcp','dstports':'143'}],
  'imaps': [{'proto':'tcp','dstports':'993'}],
  'pop3s': [{'proto':'tcp','dstports':'995'}]
} %}

{# ---------- 0) optional: sys-alert sink (networkless) ---------- #}
{% if 'sys-alert' in VMS or 'sys-alert' in APP_VMS %}
create-sys-alert:
  {{ sh("
if ! qvm-ls --raw-list | grep -qx sys-alert; then
  qvm-create --class AppVM --template debian-12-minimal --label red sys-alert
  qvm-prefs sys-alert netvm none
fi
") }}
{% endif %}

{# ---------- 1) Service VMs from cfg.vms ---------- #}
{% for name, spec in VMS.items() %}
create-{{ name }}:
  {{ sh("
if ! qvm-ls --raw-list | grep -qx {{ name|shellquote }}; then
  qvm-create --class AppVM --template {{ spec.get('template','debian-12-minimal')|shellquote }} --label {{ spec.get('label','gray')|shellquote }} {{ name|shellquote }}
fi
") }}

prefs-{{ name }}:
  {{ sh("
# label (idempotent)
cur=$(qvm-prefs -g {{ name|shellquote }} label || true); if [ \"$cur\" != {{ spec.get('label','gray')|shellquote }} ]; then qvm-prefs {{ name|shellquote }} label {{ spec.get('label','gray')|shellquote }}; fi
# provides_network
{% if spec.get('provides_network', False) -%}
if [ \"$(qvm-prefs -g {{ name|shellquote }} provides_network || true)\" != \"True\" ]; then qvm-prefs -s {{ name|shellquote }} provides_network True; fi
{% endif -%}
# netvm (none vs name)
{% set nv = spec.get('netvm','') %}
{% if nv in ('none','None',None) -%}
if [ \"$(qvm-prefs -g {{ name|shellquote }} netvm || true)\" != \"none\" ]; then qvm-prefs {{ name|shellquote }} netvm none; fi
{% elif nv -%}
if [ \"$(qvm-prefs -g {{ name|shellquote }} netvm || true)\" != {{ nv|shellquote }} ]; then qvm-prefs {{ name|shellquote }} netvm {{ nv|shellquote }}; fi
{% endif -%}
") }}

{# tags #}
{% for tag in spec.get('tags', []) %}
tag-{{ name }}-{{ tag }}:
  {{ sh("qvm-tags -l {{ name|shellquote }} | grep -qx {{ tag|shellquote }} || qvm-tags {{ name|shellquote }} -a {{ tag|shellquote }}") }}
{% endfor %}

{# features (qvm-features) #}
{% for k,v in spec.get('features', {}).items() %}
feature-{{ name }}-{{ k }}:
  {{ sh("
cur=$(qvm-features {{ name|shellquote }} {{ k|shellquote }} 2>/dev/null || echo '')
if [ \"$cur\" != {{ (v|string)|shellquote }} ]; then qvm-features {{ name|shellquote }} {{ k|shellquote }} {{ (v|string)|shellquote }}; fi
") }}
{% endfor %}

{# extra prefs dictionary (arbitrary) #}
{% for pk,pv in spec.get('prefs', {}).items() %}
pref-{{ name }}-{{ pk }}:
  {{ sh("
cur=$(qvm-prefs -g {{ name|shellquote }} {{ pk|shellquote }} 2>/dev/null || echo '')
want={{ (pv|string)|shellquote }}
# normalize booleans
[ \"$want\" = \"True\" ] || [ \"$want\" = \"False\" ] || true
if [ \"$cur\" != \"$want\" ]; then qvm-prefs -s {{ name|shellquote }} {{ pk|shellquote }} $want; fi
") }}
{% endfor %}
{% endfor %}

{# ---------- 2) App VMs from cfg.app_vms ---------- #}
{% for name, spec in APP_VMS.items() %}
create-{{ name }}:
  {{ sh("
if ! qvm-ls --raw-list | grep -qx {{ name|shellquote }}; then
  qvm-create --class AppVM --template {{ spec.get('template','deb_harden')|shellquote }} --label {{ spec.get('label', 'green')|shellquote }} {{ name|shellquote }}
fi
") }}

prefs-{{ name }}:
  {{ sh("
# label
cur=$(qvm-prefs -g {{ name|shellquote }} label || true); if [ \"$cur\" != {{ spec.get('label','green')|shellquote }} ]; then qvm-prefs {{ name|shellquote }} label {{ spec.get('label','green')|shellquote }}; fi
# netvm (default -> sys-firewall if not provided)
{% set nv = spec.get('netvm', 'sys-firewall') %}
if [ \"$(qvm-prefs -g {{ name|shellquote }} netvm || true)\" != {{ nv|shellquote }} ]; then qvm-prefs {{ name|shellquote }} netvm {{ nv|shellquote }}; fi
") }}

{# tags #}
{% for tag in spec.get('tags', []) %}
tag-{{ name }}-{{ tag }}:
  {{ sh("qvm-tags -l {{ name|shellquote }} | grep -qx {{ tag|shellquote }} || qvm-tags {{ name|shellquote }} -a {{ tag|shellquote }}") }}
{% endfor %}

{# features #}
{% for k,v in spec.get('features', {}).items() %}
feature-{{ name }}-{{ k }}:
  {{ sh("
cur=$(qvm-features {{ name|shellquote }} {{ k|shellquote }} 2>/dev/null || echo '')
if [ \"$cur\" != {{ (v|string)|shellquote }} ]; then qvm-features {{ name|shellquote }} {{ k|shellquote }} {{ (v|string)|shellquote }}; fi
") }}
{% endfor %}

{# prefs #}
{% for pk,pv in spec.get('prefs', {}).items() %}
pref-{{ name }}-{{ pk }}:
  {{ sh("
cur=$(qvm-prefs -g {{ name|shellquote }} {{ pk|shellquote }} 2>/dev/null || echo '')
want={{ (pv|string)|shellquote }}
if [ \"$cur\" != \"$want\" ]; then qvm-prefs -s {{ name|shellquote }} {{ pk|shellquote }} $want; fi
") }}
{% endfor %}

{# per-AppVM firewall: build rules then default=drop if allow list present #}
{% if spec.get('allow') %}
fw-{{ name }}-reset:
  {{ sh("qvm-firewall {{ name|shellquote }} reset || true") }}

{% for item in spec.get('allow') %}
  {# item can be a known key or a dict like {'proto':'tcp','dstports':'8443'} #}
  {% if item in svcmap %}
    {% for r in svcmap[item] %}
fw-{{ name }}-{{ item }}-{{ loop.index }}:
  {{ sh("qvm-firewall {{ name|shellquote }} add action=accept proto={{ r.proto }} dstports={{ r.dstports }}") }}
    {% endfor %}
  {% elif item is mapping %}
fw-{{ name }}-raw-{{ loop.index }}:
  {{ sh("qvm-firewall {{ name|shellquote }} add action=accept proto={{ item.get('proto','tcp') }} dstports={{ item.get('dstports','443') }}") }}
  {% else %}
fw-{{ name }}-unknown-{{ loop.index }}:
  {{ sh("# unknown allow token: {{ item }} (ignored)") }}
  {% endif %}
{% endfor %}

fw-{{ name }}-default-drop:
  {{ sh("qvm-firewall {{ name|shellquote }} default drop || true") }}
{% endif %}
{% endfor %}

{# ---------- 3) Disposables: create templates & defaults ---------- #}
{% for dvm_name, dspec in DISP.get('create', {}).items() %}
create-dvm-{{ dvm_name }}:
  {{ sh("
if ! qvm-ls --raw-list | grep -qx {{ dvm_name|shellquote }}; then
  qvm-create --class AppVM --template {{ dspec.get('template','debian-12-minimal')|shellquote }} --label {{ dspec.get('label','blue')|shellquote }} {{ dvm_name|shellquote }}
fi
# mark as template for disposables
if [ \"$(qvm-prefs -g {{ dvm_name|shellquote }} template_for_dispvms || true)\" != \"True\" ]; then
  qvm-prefs -s {{ dvm_name|shellquote }} template_for_dispvms True
fi
# optional netvm
{% set dnet = dspec.get('netvm', '') %}
{% if dnet in ('none','None',None) %}
if [ \"$(qvm-prefs -g {{ dvm_name|shellquote }} netvm || true)\" != \"none\" ]; then qvm-prefs {{ dvm_name|shellquote }} netvm none; fi
{% elif dnet %}
if [ \"$(qvm-prefs -g {{ dvm_name|shellquote }} netvm || true)\" != {{ dnet|shellquote }} ]; then qvm-prefs {{ dvm_name|shellquote }} netvm {{ dnet|shellquote }}; fi
{% endif %}
") }}
{% endfor %}

{# global default_dispvm #}
{% if DISP.get('default_dispvm') %}
default-dispvm:
  {{ sh("
cur=$(qubes-prefs -g default_dispvm || true)
if [ \"$cur\" != {{ DISP.get('default_dispvm')|shellquote }} ]; then qubes-prefs default_dispvm {{ DISP.get('default_dispvm')|shellquote }}; fi
") }}
{% endif %}

{# per-VM default_dispvm #}
{% for vm, dvm in DISP.get('per_vm_default', {}).items() %}
pervm-dispvm-{{ vm }}:
  {{ sh("
if qvm-ls --raw-list | grep -qx {{ vm|shellquote }}; then
  cur=$(qvm-prefs -g {{ vm|shellquote }} default_dispvm || true)
  if [ \"$cur\" != {{ dvm|shellquote }} ]; then qvm-prefs {{ vm|shellquote }} default_dispvm {{ dvm|shellquote }}; fi
fi
") }}
{% endfor %}

{# ---------- 4) DispVM policies (force tags to @dispvm) ---------- #}
/etc/qubes/policy.d/33-dispvm-openurl.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        qubes.OpenURL  +allow-all-names  +allow-all-names  {{ FALLBACK.get('openurl','ask') }}
{% for tag in FORCE_POL.get('openurl_tags', []) %}
        qubes.OpenURL  @tag:{{ tag }}   @dispvm           allow
{% endfor %}

/etc/qubes/policy.d/34-dispvm-openinvm.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        qubes.OpenInVM +allow-all-names  +allow-all-names  {{ FALLBACK.get('openinvm','ask') }}
{% for tag in FORCE_POL.get('openinvm_tags', []) %}
        qubes.OpenInVM @tag:{{ tag }}    @dispvm           allow
{% endfor %}
