# /srv/salt/qubes/firewall/harden.sls

{% for vm in ['hack','anon-vpn-ru','anon-vpn-nl'] %}
block-lan-{{ vm }}:
  cmd.run:
    - name: |
        qvm-firewall {{ vm }} reset
        qvm-firewall {{ vm }} add action=deny dsthost=10.0.0.0/8
        qvm-firewall {{ vm }} add action=deny dsthost=172.16.0.0/12
        qvm-firewall {{ vm }} add action=deny dsthost=192.168.0.0/16
        qvm-firewall {{ vm }} add action=accept
{% endfor %}

# Optional: per-qube default disposable
set-default-dvm:
  cmd.run:
    - name: qubes-prefs default_dispvm dvm-offline || true
