{% from "osi_model_security/map.jinja" import cfg with context %}

{% if 'sys-dns' in cfg.vms %}
sys-dns-unbound:
  module.run:
    - name: qvm.run
    - vm: sys-dns
    - args:
      - |
        sh -lc '
          if command -v apt-get >/dev/null; then
            (dpkg -s unbound >/dev/null 2>&1) || (apt-get update && apt-get -y install unbound)
            {% if cfg.enable_dnstap %}apt-get -y install libfstrm0 dnstap-ldns || true{% endif %}
          else
            rpm -q unbound >/dev/null 2>&1 || dnf -y install unbound
            {% if cfg.enable_dnstap %}dnf -y install fstrm protobuf-c || true{% endif %}
          fi
          mkdir -p /etc/unbound /var/log/unbound
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
            statistics-interval: {{ cfg.dns_tuning.stats_interval }}
            log-queries: yes
            log-replies: yes
            logfile: "/var/log/unbound/unbound.log"
            username: "unbound"
          {% if cfg.enable_dnstap %}
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
          forward-zone:
            name: "."
            forward-first: no
          EOF
          chown -R unbound:unbound /var/log/unbound || true
          systemctl enable unbound || true
          systemctl restart unbound || true
          cat >/etc/logrotate.d/unbound <<EOF
          /var/log/unbound/*.log {
            weekly
            rotate {{ cfg.dns_tuning.rotate_weeks }}
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
