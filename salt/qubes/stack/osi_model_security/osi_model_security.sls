{# ---------------------------
   OSI model security state (v2)
   Layers & mapping
   - Physical:  sys-usb       -> usbguard + strict dom0 input policy
   - Link:      sys-net       -> MAC randomization + sysctl hygiene
   - Network:   sys-firewall  -> default drop, per-VM firewall + dnsmasq logs
   - DNS:       sys-dns       -> Unbound (validating recursive), logs, stats, optional DNSTAP
   - IDS:       sys-ids       -> Suricata (AF_PACKET), optional DNS eve logs
   - Transport: templates     -> Debian+Fedora TLS/SSH policy, Chrony(NTS), sysctl
   - App:       app qubes     -> firejail/AppArmor + per-VM firewall
   Example chain: app → sys-firewall → sys-dns → sys-ids → sys-net
   --------------------------- #}

{% set cfg = pillar.get('osi_model_security', {}) %}
{% set vms = cfg.get('vms', {}) %}
{% set app_vms = cfg.get('app_vms', {}) %}
{% set strict_crypto = cfg.get('strict_crypto', False) %}
{% set enable_dnsmasq_logs = cfg.get('enable_dnsmasq_logs', True) %}
{% set enable_ecs = cfg.get('enable_ecs', False) %}
{% set enable_dnstap = cfg.get('enable_dnstap', False) %}

{# --------- 0. Ensure qubes exist (with labels/prefs/tags) --------- #}
{% for name, spec in vms.items() %}
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
      {% for t in spec.get('tags', []) %}
      - {{ t }}
      {% endfor %}
  require:
    - qvm: {{ name }}-present
{% endfor %}

{# --------- 1. dom0: realistic USB/input policy (Physical) --------- #}
# Policy: all USB goes to sys-usb; dom0 gets *no* direct USB except optional
# explicit ask for keyboard/mouse from sys-usb. Everything else is denied by default.
dom0-usb-policy-core:
  file.managed:
    - name: /etc/qubes/policy.d/30-usb-core.policy
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # Route all USB devices to sys-usb; deny generic attaches elsewhere
        device+usb * @anyvm @default allow target=sys-usb
        device+usb * @anyvm @anyvm deny

dom0-usb-policy-input:
  file.managed:
    - name: /etc/qubes/policy.d/31-usb-input.policy
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # Input devices to dom0 only via sys-usb and with prompt
        qubes.InputKeyboard * sys-usb dom0 ask
        qubes.InputMouse    * sys-usb dom0 ask
        # Block input events to other VMs by default
        qubes.InputKeyboard * @anyvm @anyvm deny
        qubes.InputMouse    * @anyvm @anyvm deny

# Optional: allow storage to *tagged* VMs only (attach happens *via* sys-usb).
dom0-usb-policy-storage:
  file.managed:
    - name: /etc/qubes/policy.d/32-usb-storage.policy
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # Only VMs tagged "usb_storage_ok" may receive block devices
        device+block * @anyvm @tag:usb_storage_ok ask
        device+block * @anyvm @anyvm deny

{# --------- 2. sys-usb: usbguard default-deny + allowlist workflow --------- #}
{% if 'sys-usb' in vms %}
sys-usb-usbguard:
  module.run:
    - name: qvm.run
    - vm: sys-usb
    - args:
      - |
        sh -lc '
          # Install usbguard
          if command -v apt-get >/dev/null 2>&1; then
            (dpkg -s usbguard >/dev/null 2>&1) || (apt-get update && apt-get -y install usbguard)
          else
            rpm -q usbguard >/dev/null 2>&1 || dnf -y install usbguard
          fi

          # Generate a baseline policy (default deny for new/unknown)
          mkdir -p /etc/usbguard
          usbguard generate-policy > /etc/usbguard/rules.conf
          sed -i "s/^ImplicitPolicyTarget.*/ImplicitPolicyTarget=block/" /etc/usbguard/usbguard-daemon.conf || echo "ImplicitPolicyTarget=block" >>/etc/usbguard/usbguard-daemon.conf
          sed -i "s/^PresentDevicePolicy.*/PresentDevicePolicy=apply-policy/" /etc/usbguard/usbguard-daemon.conf || echo "PresentDevicePolicy=apply-policy" >>/etc/usbguard/usbguard-daemon.conf
          sed -i "s|^AuditFilePath.*|AuditFilePath=/var/log/usbguard/audit.log|" /etc/usbguard/usbguard-daemon.conf || echo "AuditFilePath=/var/log/usbguard/audit.log" >>/etc/usbguard/usbguard-daemon.conf
          mkdir -p /var/log/usbguard

          systemctl enable usbguard || true
          systemctl restart usbguard || true

          # Logrotate
          cat >/etc/logrotate.d/usbguard <<EOF
          /var/log/usbguard/audit.log {
            weekly
            rotate 8
            compress
            missingok
            notifempty
            create 0640 root root
          }
          EOF
        '
  require:
    - qvm: sys-usb-present
{% endif %}

{# --------- 3. sys-net: link-layer hygiene --------- #}
{% if 'sys-net' in vms %}
sys-net-mac-randomization:
  module.run:
    - name: qvm.run
    - vm: sys-net
    - args:
      - |
        sh -lc '
          mkdir -p /etc/NetworkManager/conf.d
          cat >/etc/NetworkManager/conf.d/20-mac-randomize.conf <<EOF
          [device]
          wifi.scan-rand-mac-address=yes
          [connection]
          wifi.cloned-mac-address=random
          ethernet.cloned-mac-address=random
          EOF
          systemctl restart NetworkManager || true
        '

sys-net-sysctl-harden:
  module.run:
    - name: qvm.run
    - vm: sys-net
    - args:
      - |
        sh -lc '
          cat >/etc/sysctl.d/99-qubes-link-harden.conf <<EOF
          net.ipv4.conf.all.rp_filter=1
          net.ipv4.conf.default.rp_filter=1
          net.ipv4.conf.all.accept_redirects=0
          net.ipv4.conf.all.send_redirects=0
          net.ipv6.conf.all.accept_redirects=0
          net.ipv4.tcp_syncookies=1
          EOF
          sysctl --system || true
        '
{% endif %}

{# --------- 4. sys-dns: Unbound resolver (logs, stats, optional DNSTAP) --------- #}
{% if 'sys-dns' in vms %}
sys-dns-unbound:
  module.run:
    - name: qvm.run
    - vm: sys-dns
    - args:
      - |
        sh -lc '
          if command -v apt-get >/dev/null 2>&1; then
            (dpkg -s unbound >/dev/null 2>&1) || (apt-get update && apt-get -y install unbound)
            {% if enable_dnstap %}
            apt-get -y install unbound-dbg libfstrm0 dnstap-ldns || true
            {% endif %}
          else
            rpm -q unbound >/dev/null 2>&1 || dnf -y install unbound
            {% if enable_dnstap %}
            dnf -y install fstrm protobuf-c || true
            {% endif %}
          fi

          mkdir -p /etc/unbound
          curl -fsSL https://www.internic.net/domain/named.cache -o /etc/unbound/root.hints || true

          cat >/etc/unbound/unbound.conf <<EOF
          server:
            interface: 0.0.0.0
            access-control: 10.0.0.0/8 allow
            do-ip4: yes
            do-ip6: no
            do-udp: yes
            do-tcp: yes
            harden-glue: yes
            harden-dnssec-stripped: yes
            prefetch: yes
            qname-minimisation: yes
            cache-min-ttl: 120
            cache-max-ttl: 86400
            auto-trust-anchor-file: "/var/lib/unbound/root.key"
            root-hints: "/etc/unbound/root.hints"
            extended-statistics: yes
            statistics-interval: 60
            log-queries: yes
            log-replies: yes
            logfile: "/var/log/unbound/unbound.log"
            username: "unbound"

          {% if enable_dnstap %}
            dnstap:
              dnstap-enable: yes
              dnstap-log-resolver-response-messages: yes
              dnstap-log-client-response-messages: yes
              dnstap-socket-path: "/var/run/unbound/dnstap.sock"
          {% endif %}

          remote-control:
            control-enable: yes
            control-interface: 127.0.0.1
            control-use-cert: no

          # auth root (no forwards) for full validation transparency
          forward-zone:
            name: "."
            forward-first: no
          EOF

          mkdir -p /var/log/unbound
          chown -R unbound:unbound /var/log/unbound || true

          systemctl enable unbound || true
          systemctl restart unbound || true

          # logrotate
          cat >/etc/logrotate.d/unbound <<EOF
          /var/log/unbound/*.log {
            weekly
            rotate 8
            compress
            missingok
            notifempty
            create 0640 unbound unbound
          }
          EOF
        '
  require:
    - qvm: sys-dns-present
{% endif %}

{# --------- 5. sys-firewall: router hardening + dnsmasq logging/ECS --------- #}
{% if 'sys-firewall' in vms %}
sys-firewall-sysctl:
  module.run:
    - name: qvm.run
    - vm: sys-firewall
    - args:
      - |
        sh -lc '
          cat >/etc/sysctl.d/99-qubes-router-harden.conf <<EOF
          net.ipv4.ip_forward=1
          net.ipv4.conf.all.rp_filter=1
          net.ipv4.conf.default.rp_filter=1
          net.ipv4.conf.all.accept_redirects=0
          net.ipv6.conf.all.accept_redirects=0
          net.ipv4.conf.all.send_redirects=0
          net.ipv4.tcp_syncookies=1
          EOF
          sysctl --system || true
        '

{% if enable_dnsmasq_logs %}
sys-firewall-dnsmasq-logging:
  module.run:
    - name: qvm.run
    - vm: sys-firewall
    - args:
      - |
        sh -lc '
          mkdir -p /etc/dnsmasq.d /var/log
          # Per-VM visibility from firewall (source IP) + forward to sys-dns (via resolv.conf)
          cat >/etc/dnsmasq.d/99-logging.conf <<EOF
          log-queries
          log-facility=/var/log/dnsmasq.log
          {% if enable_ecs %}
          add-subnet=32,128
          add-mac
          {% endif %}
          EOF
          systemctl restart dnsmasq || systemctl try-restart NetworkManager || true

          # logrotate
          cat >/etc/logrotate.d/dnsmasq <<EOF
          /var/log/dnsmasq.log {
            weekly
            rotate 8
            compress
            missingok
            notifempty
            create 0640 root adm
          }
          EOF
        '
  require:
    - qvm: sys-firewall-present
{% endif %}
{% endif %}

{# --------- 6. sys-ids: Suricata (unchanged minimal, useful for DNS eve logs too) --------- #}
{% if 'sys-ids' in vms %}
sys-ids-suricata:
  module.run:
    - name: qvm.run
    - vm: sys-ids
    - args:
      - |
        sh -lc '
          if command -v apt-get >/dev/null 2>&1; then
            (dpkg -s suricata >/dev/null 2>&1) || (apt-get update && apt-get -y install suricata)
          else
            rpm -q suricata >/dev/null 2>&1 || dnf -y install suricata
          fi

          # AF_PACKET on eth0; enable DNS eve output
          sed -i "s/^ *#\? *af-packet:.*/af-packet:/" /etc/suricata/suricata.yaml || true
          if ! grep -q \"af-packet:\" -n /etc/suricata/suricata.yaml; then
            printf \"af-packet:\\n  - interface: eth0\\n    cluster-type: cluster_flow\\n    defrag: yes\\n\" >>/etc/suricata/suricata.yaml
          fi

          # Enable DNS EVE logging
          if ! grep -q \"dns:\" /etc/suricata/suricata.yaml; then
            cat >>/etc/suricata/suricata.yaml <<EOF
          outputs:
            - eve-log:
                enabled: yes
                filetype: regular
                filename: /var/log/suricata/eve.json
                types:
                  - dns
                  - flow
                  - anomaly
          EOF
          fi

          systemctl enable suricata || true
          systemctl restart suricata || true
        '
  require:
    - qvm: sys-ids-present
{% endif %}

{# --------- 7. Transport crypto (Debian & Fedora templates) + Chrony(NTS) --------- #}
{% set templates = vms|map(attribute='1')|map(attribute='template')|list %}
{% for tpl in templates|unique %}
template-{{ tpl }}-crypto-and-ssh:
  module.run:
    - name: qvm.run
    - vm: {{ tpl }}
    - args:
      - |
        sh -lc '
          if command -v apt-get >/dev/null 2>&1; then
            apt-get update
            apt-get -y install openssh-client gnutls-bin chrony
            # OpenSSL system policy (Debian-friendly)
            mkdir -p /etc/ssl/openssl.cnf.d
            cat >/etc/ssl/openssl.cnf.d/40-system-policy.cnf <<EOF
            [system_default_sect]
            MinProtocol = TLSv1.2
            CipherString = {{ "DEFAULT@SECLEVEL=3" if {{ "true" if strict_crypto else "false" }} == "true" else "DEFAULT@SECLEVEL=2" }}
            Options = ServerPreference,PrioritizeChaCha
            EOF

            # GnuTLS system policy (used by e.g. wget)
            cat >/etc/gnutls/config <<EOF
            [overrides]
            insecure-hash = md5
            tls-disabled-versions = SSL3.0 TLS1.0 TLS1.1
            EOF

            # Chrony with NTS (Network Time Security)
            sed -i "s/^pool .*/# disabled by Salt/" /etc/chrony/chrony.conf || true
            if ! grep -q nts /etc/chrony/chrony.conf; then
              cat >>/etc/chrony/chrony.conf <<EOF
            server time.cloudflare.com iburst nts
            driftfile /var/lib/chrony/drift
            rtcsync
            makestep 1.0 3
            EOF
            fi
            systemctl enable chrony || true; systemctl restart chrony || true
          else
            # Fedora family: crypto-policies + chrony (NTS)
            dnf -y install chrony || true
            {% if strict_crypto %}
            update-crypto-policies --set FUTURE || true
            {% else %}
            update-crypto-policies --set DEFAULT || true
            {% endif %}
            sed -i "s/^pool .*/# disabled by Salt/" /etc/chrony.conf || true
            if ! grep -q nts /etc/chrony.conf; then
              echo "server time.cloudflare.com iburst nts" >>/etc/chrony.conf
            fi
            systemctl enable chronyd || true; systemctl restart chronyd || true
          fi

          # SSH client hardening (applies to both Debian/Fedora)
          mkdir -p /etc/ssh/ssh_config.d
          cat >/etc/ssh/ssh_config.d/40-hardening.conf <<EOF
          Host *
            KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
            Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes256-ctr
            MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
            HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com
            PubkeyAuthentication yes
            PasswordAuthentication no
          EOF
        '
{% endfor %}

{# --------- 8. Application layer: sandbox + per-VM firewall --------- #}
{% for name, spec in app_vms.items() %}
{{ name }}-sandbox:
  module.run:
    - name: qvm.run
    - vm: {{ spec.get('template', vms.get(name, {}).get('template', 'debian-12-minimal')) }}
    - args:
      - |
        sh -lc '
          if command -v apt-get >/dev/null 2>&1; then
            apt-get -y install firejail apparmor apparmor-utils
            systemctl enable apparmor || true; systemctl start apparmor || true
          else
            dnf -y install firejail || true
          fi
        '

{% endfor %}

{% set svcmap = {
  'dns':   [{'proto': 'udp', 'dst_ports': '53'}],
  'dot':   [{'proto': 'tcp', 'dst_ports': '853'}],
  'http':  [{'proto': 'tcp', 'dst_ports': '80'}],
  'https': [{'proto': 'tcp', 'dst_ports': '443'}],
  'ssh':   [{'proto': 'tcp', 'dst_ports': '22'}],
  'ntp':   [{'proto': 'udp', 'dst_ports': '123'}]
} %}

{% for name, spec in app_vms.items() %}
{{ name }}-firewall:
  qvm.firewall:
    - name: {{ name }}
    - default: drop
    - rules:
      {% for svc in spec.get('allow', ['https','dns']) %}
      {% for rule in svcmap.get(svc, []) %}
      - action: accept
        proto: {{ rule.proto }}
        dst_ports: {{ rule.dst_ports }}
      {% endfor %}
      {% endfor %}
  require:
    - qvm: {{ name }}-present
{% endfor %}

{# --------- 9. NetVM chain: app → sys-firewall → sys-dns → sys-ids → sys-net --------- #}
{% if 'sys-firewall' in vms and vms.get('sys-firewall', {}).get('netvm') %}
sys-firewall-netvm:
  qvm.prefs:
    - name: sys-firewall
    - key: netvm
    - value: {{ vms.get('sys-firewall').get('netvm') }}
  require:
    - qvm: sys-firewall-present
{% endif %}

{% if 'sys-dns' in vms and vms.get('sys-dns', {}).get('netvm') %}
sys-dns-netvm:
  qvm.prefs:
    - name: sys-dns
    - key: netvm
    - value: {{ vms.get('sys-dns').get('netvm') }}
  require:
    - qvm: sys-dns-present
{% endif %}

{% if 'sys-ids' in vms and vms.get('sys-ids', {}).get('netvm') %}
sys-ids-netvm:
  qvm.prefs:
    - name: sys-ids
    - key: netvm
    - value: {{ vms.get('sys-ids').get('netvm') }}
  require:
    - qvm: sys-ids-present
{% endif %}

{% for name, spec in app_vms.items() %}
{{ name }}-netvm:
  qvm.prefs:
    - name: {{ name }}
    - key: netvm
    - value: {{ spec.get('netvm', 'sys-firewall') }}
  require:
    - qvm: {{ name }}-present
{% endfor %}
