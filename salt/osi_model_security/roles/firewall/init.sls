# ... (sysctl block stays the same)


{% from "osi_model_security/map.jinja" import cfg with context %}

{% if 'sys-firewall' in cfg.vms %}
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


{% if cfg.enable_dnsmasq_logs %}
sys-firewall-dnsmasq-install:
  module.run:
    - name: qvm.run
    - vm: sys-firewall
    - args:
      - |
        sh -lc '
          if command -v apt-get >/dev/null; then
            (dpkg -s dnsmasq >/dev/null 2>&1) || (apt-get update && apt-get -y install dnsmasq)
          else
            rpm -q dnsmasq >/dev/null 2>&1 || dnf -y install dnsmasq
          fi
        '

sys-firewall-dnsmasq-logging:
  module.run:
    - name: qvm.run
    - vm: sys-firewall
    - args:
      - |
        sh -lc '
          mkdir -p /etc/dnsmasq.d /var/log
          cat >/etc/dnsmasq.d/99-logging.conf <<EOF
          log-queries
          log-facility=/var/log/dnsmasq.log
          {% if cfg.enable_ecs %}
          add-subnet=32,128
          add-mac
          {% endif %}
          EOF
          systemctl enable dnsmasq || true
          systemctl restart dnsmasq || systemctl try-restart NetworkManager || true
          cat >/etc/logrotate.d/dnsmasq <<EOF
          /var/log/dnsmasq.log {
            weekly
            rotate {{ cfg.dns_tuning.rotate_weeks }}
            compress
            missingok
            notifempty
            create 0640 root adm
          }
          EOF
        '
  require:
    - module: sys-firewall-dnsmasq-install
    - qvm: sys-firewall-present
{% endif %}
{% endif %}
