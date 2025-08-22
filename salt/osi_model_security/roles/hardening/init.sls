{# Qubes "life-or-death" hardening — no new packages in dom0; strict per-qube controls. #}
{% from "osi_model_security/map.jinja" import cfg with context %}
{% set H = cfg.hardening %}
{% set T = cfg.net_topology %}
{% set chain = T.chains.get(T.active, {}).get('order', []) %}

{% if not H.get('enable', True) %}
hardening-disabled:
  test.succeed_without_changes:
    - name: "hardening role disabled by pillar"
{% endif %}

{# ----------------- helpers ----------------- #}
{% macro vm_run(vm, script) -%}
{{ vm }}-harden-cmd-{{ loop.index if loop else 'x' }}:
  module.run:
    - name: qvm.run
    - vm: {{ vm }}
    - args:
      - |
        sh -lc '
        set -e
{{ script|indent(8) }}
        '
{%- endmacro %}

{% macro ensure_nft(vm) -%}
{{ vm }}-harden-nft-setup:
  module.run:
    - name: qvm.run
    - vm: {{ vm }}
    - args:
      - |
        sh -lc '
          if command -v dnf >/dev/null; then dnf -y install nftables || true;
          elif command -v apt-get >/devnull 2>&1; then apt-get update && apt-get -y install nftables || true; fi
          mkdir -p /etc/nftables.d
          if [ ! -f /etc/nftables.conf ]; then echo "include \"/etc/nftables.d/*.nft\"" >/etc/nftables.conf;
          elif ! grep -q /etc/nftables.d /etc/nftables.conf; then echo "include \"/etc/nftables.d/*.nft\"" >>/etc/nftables.conf; fi
          systemctl enable nftables || true
        '
{%- endmacro %}

{% macro apply_sysctl(vm) -%}
{{ vm }}-harden-sysctl:
  module.run:
    - name: qvm.run
    - vm: {{ vm }}
    - args:
      - |
        sh -lc '
          mkdir -p /etc/sysctl.d
          cat >/etc/sysctl.d/90-osi-harden.conf <<EOF
{% for k,v in H.sysctl_common.items() %}
{{ k }} = {{ v }}
{% endfor %}
{% if H.ipv6_disable %}
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
{% endif %}
EOF
          sysctl --system || true
        '
{%- endmacro %}

{# ----------------- dom0 policy surface: vaults air-gap + policy files already managed elsewhere ----------------- #}
{% set vaults = H.get('vaults', {}) %}
{% for role, vname in vaults.items() if vname %}
vault-{{ role }}-airgap:
  qvm.prefs:
    - name: {{ vname }}
    - key: netvm
    - value: ''
{% endfor %}

{# ----------------- sys-usb: usbguard safety (default-deny, no implicit learns) ----------------- #}
{% if 'sys-usb' in T.vms %}
{{ vm_run('sys-usb', "
  mkdir -p /etc/usbguard
  (grep -q '^ImplicitPolicyTarget' /etc/usbguard/usbguard-daemon.conf 2>/dev/null && sed -i 's/^ImplicitPolicyTarget.*/ImplicitPolicyTarget=block/' /etc/usbguard/usbguard-daemon.conf) || echo 'ImplicitPolicyTarget=block' >>/etc/usbguard/usbguard-daemon.conf
  systemctl enable --now usbguard || true
") }}
{% endif %}

{# ----------------- sys-net: L2/L3 & link hygiene ----------------- #}
{% if 'sys-net' in T.vms %}
{{ apply_sysctl('sys-net') }}
{{ ensure_nft('sys-net') }}
{{ vm_run('sys-net', "
  cat >/etc/nftables.d/20-osi-sysnet.nft <<'EOF'
  table inet osi_sysnet {
    chain input { type filter hook input priority 0;
      ct state established,related accept
      iifname \"lo\" accept
      # Block multicast garbage and LLMNR/mDNS/NetBIOS
      ip daddr 224.0.0.0/4 drop
      udp dport {5353,5355,137,138,1900} drop
      tcp dport {139,445} drop
      # Default drop
      counter drop
    }
    chain forward { type filter hook forward priority 0;
      ct state established,related accept
      # Only forward VM traffic to uplink (eth0) and back; disallow hairpin to other bridges
      iifname \"vif+\" oifname \"eth0\" accept
      iifname \"eth0\" oifname \"vif+\" accept
      counter drop
    }
  }
  EOF
  nft -f /etc/nftables.conf || true
  systemctl restart nftables || true
") }}
{% endif %}

{# ----------------- sys-firewall: strict forward (no direct DNS/DoT/QUIC bypass) ----------------- #}
{% if 'sys-firewall' in T.vms %}
{{ apply_sysctl('sys-firewall') }}
{{ ensure_nft('sys-firewall') }}
{{ vm_run('sys-firewall', "
  cat >/etc/nftables.d/30-osi-firewall.nft <<EOF
  table inet osi_firewall {
    chain forward { type filter hook forward priority 0;
      ct state established,related accept
      {% if H.drop_quic %}udp dport 443 drop{% endif %}
      {% if H.drop_dot %}tcp dport 853 drop{% endif %}
      # app VMs must use local dnsmasq; block forwarded 53
      udp dport 53 drop
      tcp dport 53 drop
      accept
    }
  }
  EOF
  nft -f /etc/nftables.conf || true
  systemctl restart nftables || true
") }}
{% endif %}

{# ----------------- sys-dns: Unbound hardening + egress-only-DNS ----------------- #}
{% if 'sys-dns' in T.vms %}
{{ apply_sysctl('sys-dns') }}
{{ ensure_nft('sys-dns') }}
{{ vm_run('sys-dns', "
  # Unbound hardening
  install -d /etc/unbound/unbound.conf.d
  cat >/etc/unbound/unbound.conf.d/90-harden.conf <<'EOF'
  server:
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-referral-path: yes
    qname-minimisation: yes
    aggressive-nsec: yes
    unwanted-reply-threshold: 10000000
    prefetch: yes
    prefetch-key: yes
    rrset-roundrobin: yes
    cache-min-ttl: 60
    cache-max-ttl: 86400
  EOF
  systemctl restart unbound || true

  # Egress policy
  ALLOW='{% for ip in H.dns.resolver_allowlist %}{{ ip }} {% endfor %}'
  cat >/etc/nftables.d/30-osi-dns-egress.nft <<EOF
  table inet osi_dns {
    set dns_allow { type ipv4_addr; flags interval; elements = { ${ALLOW} } }
    chain output { type filter hook output priority 0;
      oifname \"lo\" accept
      ct state established,related accept
      {% if H.dns.only_dns_out %}
        {% if H.dns.dot_upstream %}
          tcp dport 853 {% if H.dns.resolver_allowlist|length>0 %} ip daddr @dns_allow {% endif %} accept
        {% endif %}
        udp dport 53  {% if H.dns.resolver_allowlist|length>0 %} ip daddr @dns_allow {% endif %} accept
        tcp dport 53  {% if H.dns.resolver_allowlist|length>0 %} ip daddr @dns_allow {% endif %} accept
        counter drop
      {% else %}
        accept
      {% endif %}
    }
  }
  EOF
  nft -f /etc/nftables.conf || true
  systemctl restart nftables || true
") }}
{% endif %}

{# ----------------- sys-vpn: hard kill-switch ----------------- #}
{% if 'sys-vpn' in T.vms and H.vpn.killswitch %}
{{ apply_sysctl('sys-vpn') }}
{{ ensure_nft('sys-vpn') }}
{{ vm_run('sys-vpn', "
  WGPORT={{ H.vpn.endpoints[0].port if H.vpn.endpoints and H.vpn.endpoints[0].get('port') else 51820 }}
  cat >/etc/nftables.d/30-osi-vpn.nft <<'EOF'
  table inet osi_vpn {
    chain output { type filter hook output priority 0;
      oifname \"lo\" accept
      ct state established,related accept
      # DHCP
      udp sport 68 udp dport 67 accept
      # allow traffic via tunnel devices
      oifname { \"wg0\", \"tun0\" } accept
      # allow contacting VPN endpoints on uplink only
{% for ep in H.vpn.endpoints %}
      ip daddr {{ ep.ip }} {{ 'udp' if ep.proto == 'udp' else 'tcp' }} dport {{ ep.port if ep.get('port') else (51820 if ep.proto=='udp' else 1194) }} oifname \"eth0\" accept
{% endfor %}
      # block raw uplink
      oifname \"eth0\" counter drop
      accept
    }
    chain forward { type filter hook forward priority 0;
      ct state established,related accept
      iifname \"vif+\" oifname { \"wg0\", \"tun0\" } accept
      iifname { \"wg0\", \"tun0\" } oifname \"vif+\" accept
      oifname \"eth0\" counter drop
      accept
    }
  }
  EOF
  nft -f /etc/nftables.conf || true
  systemctl restart nftables || true
") }}
{% endif %}

{# ----------------- sys-ids: Suricata hygiene (log rotation + optional drop) ----------------- #}
{% if 'sys-ids' in T.vms %}
{{ apply_sysctl('sys-ids') }}
{{ vm_run('sys-ids', "
  # rotate eve.json
  cat >/etc/logrotate.d/suricata <<EOF
  /var/log/suricata/*.log /var/log/suricata/*.json {
    weekly
    rotate {{ H.logrotate_weeks }}
    compress
    missingok
    notifempty
    create 0640 root adm
    postrotate
      systemctl kill -s HUP suricata || true
    endscript
  }
  EOF
  {% if H.ids.drop_on_anomaly %}
  # Enable drop for some categories (requires proper policy/rules)
  sed -i 's/^# *default-rule-path:.*/default-rule-path: \/etc\/suricata\/rules/' /etc/suricata/suricata.yaml || true
  sed -i 's/^ *- rule-files:.*$/  - rule-files:\\n    - suricata.rules/' /etc/suricata/suricata.yaml || true
  {% endif %}
  systemctl restart suricata || true
") }}
{% endif %}

{# ----------------- sys-whonix: do not override Whonix firewall; just sysctl hygiene ----------------- #}
{% if 'sys-whonix' in T.vms %}
{{ apply_sysctl('sys-whonix') }}
{% endif %}

{# ----------------- App VMs: enforce default-drop firewall ----------------- #}
{% if H.apps.enforce_default_drop %}
{% for name, spec in cfg.app_vms.items() %}
{{ name }}-fw-default-drop:
  cmd.run:
    - name: "qvm-firewall {{ name }} set default drop"
    - unless: "qvm-firewall {{ name }} list | grep -Eiq 'default.*drop|policy.*drop'"
{% endfor %}
{% endif %}

{# ----------------- Common sysctl across all service VMs we defined in topology ----------------- #}
{% for name, spec in T.vms.items() %}
{{ apply_sysctl(name) }}
{% endfor %}

{# ----------------- OPSEC hygiene: journald volatile, no coredumps, no shell history (Debian/Fedora) ----------------- #}
{% for name, spec in T.vms.items() %}
{{ vm_run(name, "
  # journald volatile
  mkdir -p /etc/systemd/journald.conf.d
  cat >/etc/systemd/journald.conf.d/00-volatile.conf <<EOF
  [Journal]
  Storage=volatile
  RuntimeMaxUse=64M
  EOF
  systemctl restart systemd-journald || true
  # disable coredumps
  mkdir -p /etc/systemd/coredump.conf.d
  cat >/etc/systemd/coredump.conf.d/00-disable.conf <<EOF
  [Coredump]
  Storage=none
  ProcessSizeMax=0
  EOF
  # shell history minimal
  mkdir -p /etc/profile.d
  cat >/etc/profile.d/00-nohistory.sh <<'EOF'
  export HISTFILE=/dev/null
  export HISTSIZE=0
  export HISTCONTROL=ignorespace:ignoredups
  EOF
") }}
{% endfor %}

{# ----------------- dom0 power hygiene (belt & suspenders) ----------------- #}
dom0-nosleep-harden:
  cmd.run:
    - name: |
        systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target || true
{# Qubes "life-or-death" hardening — no new packages in dom0; strict per-qube controls. #}
{% from "osi_model_security/map.jinja" import cfg with context %}
{% set H = cfg.hardening %}
{% set T = cfg.net_topology %}
{% set chain = T.chains.get(T.active, {}).get('order', []) %}

{% if not H.get('enable', True) %}
hardening-disabled:
  test.succeed_without_changes:
    - name: "hardening role disabled by pillar"
{% endif %}

{# ----------------- helpers ----------------- #}
{% macro vm_run(vm, script) -%}
{{ vm }}-harden-cmd-{{ loop.index if loop else 'x' }}:
  module.run:
    - name: qvm.run
    - vm: {{ vm }}
    - args:
      - |
        sh -lc '
        set -e
{{ script|indent(8) }}
        '
{%- endmacro %}

{% macro ensure_nft(vm) -%}
{{ vm }}-harden-nft-setup:
  module.run:
    - name: qvm.run
    - vm: {{ vm }}
    - args:
      - |
        sh -lc '
          if command -v dnf >/dev/null; then dnf -y install nftables || true;
          elif command -v apt-get >/devnull 2>&1; then apt-get update && apt-get -y install nftables || true; fi
          mkdir -p /etc/nftables.d
          if [ ! -f /etc/nftables.conf ]; then echo "include \"/etc/nftables.d/*.nft\"" >/etc/nftables.conf;
          elif ! grep -q /etc/nftables.d /etc/nftables.conf; then echo "include \"/etc/nftables.d/*.nft\"" >>/etc/nftables.conf; fi
          systemctl enable nftables || true
        '
{%- endmacro %}

{% macro apply_sysctl(vm) -%}
{{ vm }}-harden-sysctl:
  module.run:
    - name: qvm.run
    - vm: {{ vm }}
    - args:
      - |
        sh -lc '
          mkdir -p /etc/sysctl.d
          cat >/etc/sysctl.d/90-osi-harden.conf <<EOF
{% for k,v in H.sysctl_common.items() %}
{{ k }} = {{ v }}
{% endfor %}
{% if H.ipv6_disable %}
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
{% endif %}
EOF
          sysctl --system || true
        '
{%- endmacro %}

{# ----------------- dom0 policy surface: vaults air-gap + policy files already managed elsewhere ----------------- #}
{% set vaults = H.get('vaults', {}) %}
{% for role, vname in vaults.items() if vname %}
vault-{{ role }}-airgap:
  qvm.prefs:
    - name: {{ vname }}
    - key: netvm
    - value: ''
{% endfor %}

{# ----------------- sys-usb: usbguard safety (default-deny, no implicit learns) ----------------- #}
{% if 'sys-usb' in T.vms %}
{{ vm_run('sys-usb', "
  mkdir -p /etc/usbguard
  (grep -q '^ImplicitPolicyTarget' /etc/usbguard/usbguard-daemon.conf 2>/dev/null && sed -i 's/^ImplicitPolicyTarget.*/ImplicitPolicyTarget=block/' /etc/usbguard/usbguard-daemon.conf) || echo 'ImplicitPolicyTarget=block' >>/etc/usbguard/usbguard-daemon.conf
  systemctl enable --now usbguard || true
") }}
{% endif %}

{# ----------------- sys-net: L2/L3 & link hygiene ----------------- #}
{% if 'sys-net' in T.vms %}
{{ apply_sysctl('sys-net') }}
{{ ensure_nft('sys-net') }}
{{ vm_run('sys-net', "
  cat >/etc/nftables.d/20-osi-sysnet.nft <<'EOF'
  table inet osi_sysnet {
    chain input { type filter hook input priority 0;
      ct state established,related accept
      iifname \"lo\" accept
      # Block multicast garbage and LLMNR/mDNS/NetBIOS
      ip daddr 224.0.0.0/4 drop
      udp dport {5353,5355,137,138,1900} drop
      tcp dport {139,445} drop
      # Default drop
      counter drop
    }
    chain forward { type filter hook forward priority 0;
      ct state established,related accept
      # Only forward VM traffic to uplink (eth0) and back; disallow hairpin to other bridges
      iifname \"vif+\" oifname \"eth0\" accept
      iifname \"eth0\" oifname \"vif+\" accept
      counter drop
    }
  }
  EOF
  nft -f /etc/nftables.conf || true
  systemctl restart nftables || true
") }}
{% endif %}

{# ----------------- sys-firewall: strict forward (no direct DNS/DoT/QUIC bypass) ----------------- #}
{% if 'sys-firewall' in T.vms %}
{{ apply_sysctl('sys-firewall') }}
{{ ensure_nft('sys-firewall') }}
{{ vm_run('sys-firewall', "
  cat >/etc/nftables.d/30-osi-firewall.nft <<EOF
  table inet osi_firewall {
    chain forward { type filter hook forward priority 0;
      ct state established,related accept
      {% if H.drop_quic %}udp dport 443 drop{% endif %}
      {% if H.drop_dot %}tcp dport 853 drop{% endif %}
      # app VMs must use local dnsmasq; block forwarded 53
      udp dport 53 drop
      tcp dport 53 drop
      accept
    }
  }
  EOF
  nft -f /etc/nftables.conf || true
  systemctl restart nftables || true
") }}
{% endif %}

{# ----------------- sys-dns: Unbound hardening + egress-only-DNS ----------------- #}
{% if 'sys-dns' in T.vms %}
{{ apply_sysctl('sys-dns') }}
{{ ensure_nft('sys-dns') }}
{{ vm_run('sys-dns', "
  # Unbound hardening
  install -d /etc/unbound/unbound.conf.d
  cat >/etc/unbound/unbound.conf.d/90-harden.conf <<'EOF'
  server:
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-referral-path: yes
    qname-minimisation: yes
    aggressive-nsec: yes
    unwanted-reply-threshold: 10000000
    prefetch: yes
    prefetch-key: yes
    rrset-roundrobin: yes
    cache-min-ttl: 60
    cache-max-ttl: 86400
  EOF
  systemctl restart unbound || true

  # Egress policy
  ALLOW='{% for ip in H.dns.resolver_allowlist %}{{ ip }} {% endfor %}'
  cat >/etc/nftables.d/30-osi-dns-egress.nft <<EOF
  table inet osi_dns {
    set dns_allow { type ipv4_addr; flags interval; elements = { ${ALLOW} } }
    chain output { type filter hook output priority 0;
      oifname \"lo\" accept
      ct state established,related accept
      {% if H.dns.only_dns_out %}
        {% if H.dns.dot_upstream %}
          tcp dport 853 {% if H.dns.resolver_allowlist|length>0 %} ip daddr @dns_allow {% endif %} accept
        {% endif %}
        udp dport 53  {% if H.dns.resolver_allowlist|length>0 %} ip daddr @dns_allow {% endif %} accept
        tcp dport 53  {% if H.dns.resolver_allowlist|length>0 %} ip daddr @dns_allow {% endif %} accept
        counter drop
      {% else %}
        accept
      {% endif %}
    }
  }
  EOF
  nft -f /etc/nftables.conf || true
  systemctl restart nftables || true
") }}
{% endif %}

{# ----------------- sys-vpn: hard kill-switch ----------------- #}
{% if 'sys-vpn' in T.vms and H.vpn.killswitch %}
{{ apply_sysctl('sys-vpn') }}
{{ ensure_nft('sys-vpn') }}
{{ vm_run('sys-vpn', "
  WGPORT={{ H.vpn.endpoints[0].port if H.vpn.endpoints and H.vpn.endpoints[0].get('port') else 51820 }}
  cat >/etc/nftables.d/30-osi-vpn.nft <<'EOF'
  table inet osi_vpn {
    chain output { type filter hook output priority 0;
      oifname \"lo\" accept
      ct state established,related accept
      # DHCP
      udp sport 68 udp dport 67 accept
      # allow traffic via tunnel devices
      oifname { \"wg0\", \"tun0\" } accept
      # allow contacting VPN endpoints on uplink only
{% for ep in H.vpn.endpoints %}
      ip daddr {{ ep.ip }} {{ 'udp' if ep.proto == 'udp' else 'tcp' }} dport {{ ep.port if ep.get('port') else (51820 if ep.proto=='udp' else 1194) }} oifname \"eth0\" accept
{% endfor %}
      # block raw uplink
      oifname \"eth0\" counter drop
      accept
    }
    chain forward { type filter hook forward priority 0;
      ct state established,related accept
      iifname \"vif+\" oifname { \"wg0\", \"tun0\" } accept
      iifname { \"wg0\", \"tun0\" } oifname \"vif+\" accept
      oifname \"eth0\" counter drop
      accept
    }
  }
  EOF
  nft -f /etc/nftables.conf || true
  systemctl restart nftables || true
") }}
{% endif %}

{# ----------------- sys-ids: Suricata hygiene (log rotation + optional drop) ----------------- #}
{% if 'sys-ids' in T.vms %}
{{ apply_sysctl('sys-ids') }}
{{ vm_run('sys-ids', "
  # rotate eve.json
  cat >/etc/logrotate.d/suricata <<EOF
  /var/log/suricata/*.log /var/log/suricata/*.json {
    weekly
    rotate {{ H.logrotate_weeks }}
    compress
    missingok
    notifempty
    create 0640 root adm
    postrotate
      systemctl kill -s HUP suricata || true
    endscript
  }
  EOF
  {% if H.ids.drop_on_anomaly %}
  # Enable drop for some categories (requires proper policy/rules)
  sed -i 's/^# *default-rule-path:.*/default-rule-path: \/etc\/suricata\/rules/' /etc/suricata/suricata.yaml || true
  sed -i 's/^ *- rule-files:.*$/  - rule-files:\\n    - suricata.rules/' /etc/suricata/suricata.yaml || true
  {% endif %}
  systemctl restart suricata || true
") }}
{% endif %}

{# ----------------- sys-whonix: do not override Whonix firewall; just sysctl hygiene ----------------- #}
{% if 'sys-whonix' in T.vms %}
{{ apply_sysctl('sys-whonix') }}
{% endif %}

{# ----------------- App VMs: enforce default-drop firewall ----------------- #}
{% if H.apps.enforce_default_drop %}
{% for name, spec in cfg.app_vms.items() %}
{{ name }}-fw-default-drop:
  cmd.run:
    - name: "qvm-firewall {{ name }} set default drop"
    - unless: "qvm-firewall {{ name }} list | grep -Eiq 'default.*drop|policy.*drop'"
{% endfor %}
{% endif %}

{# ----------------- Common sysctl across all service VMs we defined in topology ----------------- #}
{% for name, spec in T.vms.items() %}
{{ apply_sysctl(name) }}
{% endfor %}

{# ----------------- OPSEC hygiene: journald volatile, no coredumps, no shell history (Debian/Fedora) ----------------- #}
{% for name, spec in T.vms.items() %}
{{ vm_run(name, "
  # journald volatile
  mkdir -p /etc/systemd/journald.conf.d
  cat >/etc/systemd/journald.conf.d/00-volatile.conf <<EOF
  [Journal]
  Storage=volatile
  RuntimeMaxUse=64M
  EOF
  systemctl restart systemd-journald || true
  # disable coredumps
  mkdir -p /etc/systemd/coredump.conf.d
  cat >/etc/systemd/coredump.conf.d/00-disable.conf <<EOF
  [Coredump]
  Storage=none
  ProcessSizeMax=0
  EOF
  # shell history minimal
  mkdir -p /etc/profile.d
  cat >/etc/profile.d/00-nohistory.sh <<'EOF'
  export HISTFILE=/dev/null
  export HISTSIZE=0
  export HISTCONTROL=ignorespace:ignoredups
  EOF
") }}
{% endfor %}

{# ----------------- dom0 power hygiene (belt & suspenders) ----------------- #}
dom0-nosleep-harden:
  cmd.run:
    - name: |
        systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target || true
