# /srv/salt/qubes/templates/vault_gui.sls
deb12-vault:
  qvm.clone:
    - source: debian-12-xfce

deb12-vault-packages:
  qvm.run:
    - name: deb12-vault
    - user: root
    - cmd: |
        apt-get update
        apt-get -y install keepassxc xclip

vault-secrets:
  qvm.vm:
    - template: deb12-vault
    - label: purple
    - prefs: { netvm: none }

vault-storage:
  qvm.vm:
    - template: deb12-vault
    - label: purple
    - prefs: { netvm: none }
