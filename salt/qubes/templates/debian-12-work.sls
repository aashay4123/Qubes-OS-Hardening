# Work template from hardened base; temp net via sys-firewall for installs, then back to no-net.
# Base: debian-12-hard  ->  Target: debian-12-work

debian-12-work-present:
  qvm.clone:
    - name: debian-12-work
    - source: debian-12-hard

# Temporarily attach net to sys-firewall for installs
debian-12-work-netvm-enable:
  qvm.prefs:
    - name: debian-12-work
    - netvm: sys-firewall
    - require:
      - qvm: debian-12-work-present

# Refresh APT metadata
debian-12-work-apt-update:
  qvm.run:
    - name: debian-12-work
    - user: root
    - cmd: "apt-get update"
    - require:
      - qvm: debian-12-work-netvm-enable

# Core tools before repo/key work (needs curl, gpg, certs, etc.)
debian-12-work-core-tools:
  qvm.run:
    - name: debian-12-work
    - user: root
    - cmd: "env DEBIAN_FRONTEND=noninteractive apt-get -y install git curl wget gnupg ca-certificates terminator tmux htop vim nano build-essential cmake pkg-config gdb clang python3 python3-venv python3-pip nodejs npm jq ripgrep fzf zip unzip ethtool iproute2 pciutils usbutils"
    - require:
      - qvm: debian-12-work-apt-update

# ----------------- Add official repositories -----------------

# Brave
debian-12-work-repo-brave:
  qvm.run:
    - name: debian-12-work
    - user: root
    - cmd: "/bin/sh -c 'set -e; rm -f /etc/apt/sources.list.d/brave-browser-release.list; curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg; echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main\" > /etc/apt/sources.list.d/brave-browser-release.list'"
    - require:
      - qvm: debian-12-work-core-tools

# Docker CE (dearmor key → keyring, then source list)
debian-12-work-repo-docker:
  qvm.run:
    - name: debian-12-work
    - user: root
    - cmd: "/bin/sh -c 'set -e; install -m 0755 -d /etc/apt/keyrings; rm -f /etc/apt/sources.list.d/docker.list; curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; chmod a+r /etc/apt/keyrings/docker.gpg; echo \"deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable\" > /etc/apt/sources.list.d/docker.list'"
    - require:
      - qvm: debian-12-work-core-tools

# Update after adding repos
debian-12-work-apt-update-after-repos:
  qvm.run:
    - name: debian-12-work
    - user: root
    - cmd: "apt-get update"
    - require:
      - qvm: debian-12-work-repo-brave
      - qvm: debian-12-work-repo-docker

# ----------------- Install from repos -----------------

debian-12-work-install-brave:
  qvm.run:
    - name: debian-12-work
    - user: root
    - cmd: "env DEBIAN_FRONTEND=noninteractive apt-get -y install brave-browser"
    - require:
      - qvm: debian-12-work-apt-update-after-repos

debian-12-work-install-docker:
  qvm.run:
    - name: debian-12-work
    - user: root
    - cmd: "env DEBIAN_FRONTEND=noninteractive apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    - require:
      - qvm: debian-12-work-apt-update-after-repos

# Add 'user' to docker group (useful in derived AppVMs)
debian-12-work-docker-group:
  qvm.run:
    - name: debian-12-work
    - user: root
    - cmd: "/bin/sh -c 'set -e; if id user >/dev/null 2>&1; then groupadd -f docker; usermod -aG docker user; fi'"
    - require:
      - qvm: debian-12-work-install-docker

# ----------------- Postman (official tarball; your URL) -----------------

debian-12-work-install-postman:
  qvm.run:
    - name: debian-12-work
    - user: root
    - cmd: "/bin/sh -c 'set -e; curl -fL https://dl.pstmn.io/download/latest/linux_64 -o /tmp/postman.tar.gz; rm -rf /opt/Postman; mkdir -p /opt; tar -xzf /tmp/postman.tar.gz -C /opt; ln -sf /opt/Postman/Postman /usr/bin/postman'"

# ----------------- MongoDB Compass (official .deb; your URL) -----------------
debian-12-work-install-compass:
  qvm.run:
    - name: debian-12-work
    - user: root
    - cmd: "/bin/sh -c 'set -e; curl -fL https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64 -o /tmp/vscode.deb; dpkg -i /tmp/vscode.deb || apt-get -y -f install'"

debian-12-work-install-compass:
  qvm.run:
    - name: debian-12-work
    - user: root
    - cmd: "/bin/sh -c 'set -e; curl -fL https://downloads.mongodb.com/compass/mongodb-compass_1.46.8_amd64.deb -o /tmp/mongodb-compass.deb; dpkg -i /tmp/mongodb-compass.deb || apt-get -y -f install'"

# Always detach net in the end (even if some installs failed)
debian-12-work-netvm-disable:
  qvm.prefs:
    - name: debian-12-work
    - netvm: ''
    - require:
      - qvm: debian-12-work-present
    - order: last
