{% from "osi_model_security/map.jinja" import cfg with context %}

{% if 'sys-net' in cfg.vms %}
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

sys-net-sysctl:
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
