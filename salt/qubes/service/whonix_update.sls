# /srv/salt/qubes/services/whonix_update.sls
whonix-gw-update:
  qvm.run:
    - name: whonix-gw-17
    - user: root
    - cmd: |
        apt-get update || true
        apt-get -y install --reinstall whonix-keys ca-certificates || true
        apt-get update || true

whonix-ws-update:
  qvm.run:
    - name: whonix-ws-17
    - user: root
    - cmd: |
        apt-get update || true
        apt-get -y install --reinstall whonix-keys ca-certificates || true
        apt-get update || true
