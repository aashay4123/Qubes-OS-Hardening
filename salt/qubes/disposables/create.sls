# /srv/salt/qubes/disposables/create.sls
deb12-dvm-base:
  qvm.clone:
    - source: debian-12-xfce

deb12-dvm-base-packages:
  qvm.run:
    - name: deb12-dvm-base
    - user: root
    - cmd: |
        set -e
        apt-get update
        apt-get -y install --no-install-recommends evince xpdf file

dvm-offline:
  qvm.vm:
    - template: deb12-dvm-base
    - label: gray
    - prefs:
        netvm: none
        template_for_dispvms: True

set-default-dispvm:
  cmd.run:
    - name: qubes-prefs default_dispvm dvm-offline || true
