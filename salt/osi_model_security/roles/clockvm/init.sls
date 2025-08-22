{% from "osi_model_security/map.jinja" import cfg with context %}
{% set C = cfg.clock_comms %}
{% set clockvm = C.clockvm %}
{% set disp = C.dispvm_default %}

# Force a single ClockVM
clockvm-set:
  cmd.run:
    - name: qubes-prefs -s clockvm {{ clockvm }}
    - unless: test "$(qubes-prefs clockvm 2>/dev/null)" = "{{ clockvm }}"

# Default DispVM for opening files/URLs safely
dispvm-default:
  cmd.run:
    - name: qubes-prefs -s default_dispvm {{ disp }}
    - unless: test "$(qubes-prefs default_dispvm 2>/dev/null)" = "{{ disp }}"

# Block raw NTP in non-clock VMs (belt & suspenders)
{% for vm in C.get('ntp_block_on', []) %}
{{ vm }}-drop-ntp:
  cmd.run:
    - name: qvm-firewall {{ vm }} add action=drop proto=udp dstports=123 to=any
    - unless: qvm-firewall {{ vm }} list | grep -Eiq 'udp.*123.*drop'
{% endfor %}
