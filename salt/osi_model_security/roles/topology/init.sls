{% from "osi_model_security/map.jinja" import cfg with context %}
{% set topo = cfg.net_topology %}
{% set active_name = topo.active %}
{% set chain = topo.chains.get(active_name, {}).get('order', []) %}

{# Safety: ensure sys-net exists; present others if missing #}
{% for name, spec in topo.vms.items() %}
{{ name }}-present:
  qvm.present:
    - name: {{ name }}
    - template: {{ spec.template }}
    - label: {{ spec.get('label', 'green') }}
{% if spec.get('provides_network', False) %}
{{ name }}-providesnet:
  qvm.prefs:
    - name: {{ name }}
    - key: provides_network
    - value: True
  require:
    - qvm: {{ name }}-present
{% endif %}
{% endfor %}

{# Optional: install basic VPN tooling in sys-vpn #}
{% if 'sys-vpn' in topo.vms %}
sys-vpn-tools:
  module.run:
    - name: qvm.run
    - vm: sys-vpn
    - args:
      - |
        sh -lc '
          if command -v dnf >/dev/null; then
            {% if topo.vpn_tools.get('openvpn', True) %}
            dnf -y install openvpn || true
            {% endif %}
            {% if topo.vpn_tools.get('wireguard', True) %}
            dnf -y install wireguard-tools || true
            {% endif %}
            {% if topo.vpn_tools.get('networkmanager_plugins', True) %}
            dnf -y install NetworkManager-openvpn NetworkManager-strongswan NetworkManager-l2tp || true
            {% endif %}
          elif command -v apt-get >/dev/null; then
            {% if topo.vpn_tools.get('openvpn', True) %}
            apt-get update && apt-get -y install openvpn || true
            {% endif %}
            {% if topo.vpn_tools.get('wireguard', True) %}
            apt-get -y install wireguard-tools || true
            {% endif %}
            {% if topo.vpn_tools.get('networkmanager_plugins', True) %}
            apt-get -y install network-manager-openvpn-gnome strongswan-network-manager network-manager-l2tp || true
            {% endif %}
          fi
        '
  require:
    - qvm: sys-vpn-present
{% endif %}

{# Build the chain:
   - For i in [0..n-1], set hop[i] netvm = hop[i+1]
   - Set last hop netvm = sys-net
   - Point all app VMs at hop[0] (first in order). #}

{% set last = 'sys-net' %}
{% if chain|length > 0 %}
{% for i in range(chain|length - 1, -1, -1) %}
{% set vm = chain[i] %}
{{ vm }}-netvm:
  qvm.prefs:
    - name: {{ vm }}
    - key: netvm
    - value: {{ last }}
  require:
    - qvm: {{ vm }}-present
{% set last = vm %}
{% endfor %}
{% else %}
# No chain? apps will go straight to sys-net.
{% endif %}

{# Apply app VM netvm = first hop (or sys-net if empty) #}
{% set first_hop = chain[0] if chain else 'sys-net' %}
{% for name, spec in cfg.app_vms.items() %}
{{ name }}-netvm-topology:
  qvm.prefs:
    - name: {{ name }}
    - key: netvm
    - value: {{ first_hop }}
  require:
    - qvm: {{ name }}-present
{% endfor %}

{# Tag the active chain on the hops for quick identification #}
{% for hop in chain %}
{{ hop }}-tag-active-chain:
  qvm.tags:
    - name: {{ hop }}
    - add: [topology_{{ active_name }}]
  require:
    - qvm: {{ hop }}-present
{% endfor %}


