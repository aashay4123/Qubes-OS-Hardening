# Minimal hardened template for system qubes (sys-net, sys-firewall, sys-usb)
# Source: debian-12-hard  ->  Target: debian-12-hard-min

debian-12-hard-min-present:
  qvm.clone:
    - name: debian-12-hard-min
    - source: debian-12-hard

debian-12-hard-min-apt-update:
  qvm.run:
    - name: debian-12-hard-min
    - user: root
    - cmd: "apt-get update"
    - require:
      - qvm: debian-12-hard-min-present

debian-12-hard-min-install-qubes-core:
  qvm.run:
    - name: debian-12-hard-min
    - user: root
    - cmd: "env DEBIAN_FRONTEND=noninteractive apt-get -y install qubes-core-agent-networking qubes-core-agent-dom0-updates"
    - require:
      - qvm: debian-12-hard-min-apt-update

debian-12-hard-min-install-netstack:
  qvm.run:
    - name: debian-12-hard-min
    - user: root
    - cmd: "env DEBIAN_FRONTEND=noninteractive apt-get -y install qubes-core-agent-network-manager network-manager wpasupplicant iw"
    - require:
      - qvm: debian-12-hard-min-install-qubes-core

debian-12-hard-min-install-tools:
  qvm.run:
    - name: debian-12-hard-min
    - user: root
    - cmd: "env DEBIAN_FRONTEND=noninteractive apt-get -y install ethtool iproute2 bind9-dnsutils pciutils usbutils firmware-linux-free policykit-1"
    - require:
      - qvm: debian-12-hard-min-install-netstack

debian-12-hard-min-install-usb:
  qvm.run:
    - name: debian-12-hard-min
    - user: root
    - cmd: "env DEBIAN_FRONTEND=noninteractive apt-get -y install qubes-usb-proxy qubes-input-proxy-sender"
    - require:
      - qvm: debian-12-hard-min-install-tools

debian-12-hard-min-purge-x-core:
  qvm.run:
    - name: debian-12-hard-min
    - user: root
    - cmd: "/bin/sh -c 'set -e; for p in xserver-xorg-core xserver-xorg x11-common; do if dpkg -s \"$p\" >/dev/null 2>&1; then env DEBIAN_FRONTEND=noninteractive apt-get -y purge \"$p\"; fi; done'"
    - require:
      - qvm: debian-12-hard-min-install-usb

debian-12-hard-min-purge-xfce:
  qvm.run:
    - name: debian-12-hard-min
    - user: root
    - cmd: "/bin/sh -c 'set -e; for p in lightdm xfce4 xfce4-goodies xfce4-terminal mousepad thunar thunar-archive-plugin ristretto parole; do if dpkg -s \"$p\" >/dev/null 2>&1; then env DEBIAN_FRONTEND=noninteractive apt-get -y purge \"$p\"; fi; done'"
    - require:
      - qvm: debian-12-hard-min-purge-x-core

debian-12-hard-min-purge-audio-and-apps:
  qvm.run:
    - name: debian-12-hard-min
    - user: root
    - cmd: "/bin/sh -c 'set -e; for p in pulseaudio pipewire pipewire-pulse pavucontrol firefox-esr thunderbird libreoffice-common; do if dpkg -s \"$p\" >/dev/null 2>&1; then env DEBIAN_FRONTEND=noninteractive apt-get -y purge \"$p\"; fi; done'"
    - require:
      - qvm: debian-12-hard-min-purge-xfce

debian-12-hard-min-autoremove:
  qvm.run:
    - name: debian-12-hard-min
    - user: root
    - cmd: "apt-get -y autoremove --purge"
    - require:
      - qvm: debian-12-hard-min-purge-audio-and-apps

debian-12-hard-min-clean:
  qvm.run:
    - name: debian-12-hard-min
    - user: root
    - cmd: "apt-get -y clean"
    - require:
      - qvm: debian-12-hard-min-autoremove

debian-12-hard-min-disable-unneeded:
  qvm.run:
    - name: debian-12-hard-min
    - user: root
    - cmd: "/bin/sh -c 'set -e; if systemctl list-unit-files | grep -q \"^cups.service\"; then systemctl disable --now cups; fi; if systemctl list-unit-files | grep -q \"^avahi-daemon.service\"; then systemctl disable --now avahi-daemon; fi'"
    - require:
      - qvm: debian-12-hard-min-clean

debian-12-hard-min-enable-needed:
  qvm.run:
    - name: debian-12-hard-min
    - user: root
    - cmd: "/bin/sh -c 'set -e; if systemctl list-unit-files | grep -q \"^NetworkManager.service\"; then systemctl enable NetworkManager; fi; if systemctl list-unit-files | grep -q \"^qubes-usb-proxy.service\"; then systemctl enable qubes-usb-proxy; fi'"
    - require:
      - qvm: debian-12-hard-min-install-tools
