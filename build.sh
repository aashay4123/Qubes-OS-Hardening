# dom0 (one-time)
qvm-clone debian-12-xfce deb12-dvm-base
qvm-run -u root deb12-dvm-base 'apt-get update && apt-get -y install --no-install-recommends evince xpdf file'
qvm-create --class AppVM --template deb12-dvm-base --label gray dvm-offline
qvm-prefs dvm-offline netvm ""
qvm-prefs dvm-offline template_for_dispvms True
qubes-prefs default_dispvm dvm-offline
sudo qubesctl --all state.highstate
