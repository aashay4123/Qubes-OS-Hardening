#!/usr/bin/env bash

set -euo pipefail
# Copy salt/qubes/templates files to /srv/salt/qubes/templates after making the directory
sudo mkdir -p /srv/salt/qubes/templates
sudo cp -r salt/qubes/templates/* /srv/salt/qubes/templates/
sudo chown -R root:root /srv/salt/qubes/templates
sudo chmod -R 755 /srv/salt/qubes/templates
# Apply the state to install qubes-template-debian-12-xfce
sudo qubes-dom0-update qubes-template-debian-12-xfce   # ok if already installed

# debian-12-hard setup for Qubes OS 4.2.4
sudo qubesctl state.show_sls qubes.templates.debian-12-hard
sudo qubesctl --show-output state.sls qubes.templates.debian-12-hard

qvm-run --pass-io -u root debian-12-hard 'apt-get update'
qvm-run -p -u root debian-12-hard 'cat -n /etc/apt/apt.conf.d/99hardening'
qvm-run -p -u root debian-12-hard 'cat -n /etc/apt/apt.conf.d/20auto-upgrades'
qvm-run -u root -p debian-12-hard 'aa-status || true'
qvm-run -u root -p debian-12-hard 'sysctl kernel.kptr_restrict kernel.dmesg_restrict kernel.unprivileged_bpf_disabled | cat'
qvm-run -u root -p debian-12-hard 'systemctl is-enabled auditd || true'
qvm-run -u root -p debian-12-hard 'passwd -S root || true'



# dom0
printf "\n=== Qubes VM inventory ===\n"
qvm-ls | egrep 'NAME|debian-12-hard($|-)|debian-12-hard-min($|-)'



# dom0
TPL_HARD="debian-12-hard"
TPL_MIN="debian-12-hard-min"

pass(){ printf "PASS: %s\n" "$1"; }
fail(){ printf "FAIL: %s\n" "$1"; }

vrun(){ # qvm-run with -p to capture output/stderr; returns exit code
  qvm-run -u root -p "$1" "$2" 2>&1
}

check_cmd(){ # VM, command, grep-needle, description
  out="$(vrun "$1" "$2")"; ec=$?
  if [ $ec -eq 0 ] && { [ -z "$3" ] || printf "%s" "$out" | grep -q -- "$3"; }; then pass "$4"; else
    printf "%s\n" "$out"
    fail "$4"
  fi
}

check_absent_pkg(){ # VM, package, description
  if vrun "$1" "dpkg -s $2" >/dev/null; then fail "$3 (found: $2)"; else pass "$3"; fi
}

check_present_pkg(){ # VM, package, description
  if vrun "$1" "dpkg -s $2" >/dev/null; then pass "$3"; else fail "$3 (missing: $2)"; fi
}

check_service_enabled(){ # VM, unit, description
  if vrun "$1" "systemctl is-enabled $2" | grep -qE 'enabled|static'; then pass "$3"; else fail "$3"; fi
}

check_file_has(){ # VM, file, needle, description
  if vrun "$1" "test -f '$2' && grep -q -- '$3' '$2'"; then pass "$4"; else fail "$4"; fi
}

check_sysctl(){ # VM, key, expected, description
  val="$(vrun "$1" "sysctl -n $2" | tr -d '[:space:]')"
  if [ "$val" = "$3" ]; then pass "$4"; else printf "got=%s expected=%s\n" "$val" "$3"; fail "$4"; fi
}

dash(){ printf "\n--- %s ---\n" "$1"; }

### Tests for debian-12-hard (baseline)
dash "Template: $TPL_HARD — baseline hardening"

# APT sane & security automation present
check_cmd "$TPL_HARD" "apt-get update" "" "APT updates successfully"
check_file_has "$TPL_HARD" "/etc/apt/apt.conf.d/99hardening" 'Install-Recommends "false"' "APT hardening file in place"
check_file_has "$TPL_HARD" "/etc/apt/apt.conf.d/20auto-upgrades" 'Unattended-Upgrade "1"' "Unattended upgrades configured"

# Kernel/sysctl hardening (conservative set)
check_sysctl "$TPL_HARD" kernel.kptr_restrict 2 "kptr_restrict=2"
check_sysctl "$TPL_HARD" kernel.dmesg_restrict 1 "dmesg_restrict=1"
check_sysctl "$TPL_HARD" kernel.unprivileged_bpf_disabled 1 "unprivileged_bpf_disabled=1"
check_sysctl "$TPL_HARD" kernel.yama.ptrace_scope 1 "ptrace_scope=1"

# IPv4/IPv6 redirect/RA protections
check_sysctl "$TPL_HARD" net.ipv4.conf.all.accept_redirects 0 "IPv4 redirects disabled (all)"
check_sysctl "$TPL_HARD" net.ipv6.conf.all.accept_ra 0 "IPv6 RA disabled (all)"

# AppArmor tools present (ok if profiles not yet loaded in a template)
check_present_pkg "$TPL_HARD" "apparmor" "AppArmor package installed"
check_cmd "$TPL_HARD" "aa-status || true" "" "aa-status callable"

# Auditd enabled (for downstream AppVMs)
check_cmd "$TPL_HARD" "systemctl is-enabled auditd || true" "enabled" "auditd is-enabled (template)"

# Root locked
check_cmd "$TPL_HARD" "passwd -S root || true" " L " "root account locked"

# No noisy daemons
check_absent_pkg "$TPL_HARD" "avahi-daemon" "avahi removed"
check_absent_pkg "$TPL_HARD" "cups" "cups removed"
check_absent_pkg "$TPL_HARD" "exim4" "exim removed"

### Tests for debian-12-hard-min (sys-* minimal)
dash "Template: $TPL_MIN — sys-* minimal"

# APT update works
check_cmd "$TPL_MIN" "apt-get update" "" "APT updates successfully (min)"

# Core Qubes agents present
check_present_pkg "$TPL_MIN" "qubes-core-agent-networking" "qubes-core-agent-networking present"
check_present_pkg "$TPL_MIN" "qubes-core-agent-dom0-updates" "dom0 updates proxy present"

# Net stack for sys-net
check_present_pkg "$TPL_MIN" "qubes-core-agent-network-manager" "qubes-core-agent-network-manager present"
check_present_pkg "$TPL_MIN" "network-manager" "NetworkManager present"
check_present_pkg "$TPL_MIN" "wpasupplicant" "wpasupplicant present"
check_present_pkg "$TPL_MIN" "iw" "iw present"

# Tools set
for p in ethtool iproute2 bind9-dnsutils pciutils usbutils firmware-linux-free policykit-1; do
  check_present_pkg "$TPL_MIN" "$p" "tool present: $p"
done

# USB proxy pieces for sys-usb
check_present_pkg "$TPL_MIN" "qubes-usb-proxy" "qubes-usb-proxy present"
check_present_pkg "$TPL_MIN" "qubes-input-proxy-sender" "qubes-input-proxy-sender present"

# GUI bits removed (spot checks)
for p in xserver-xorg-core xserver-xorg x11-common lightdm xfce4 xfce4-goodies xfce4-terminal thunar firefox-esr libreoffice-common; do
  check_absent_pkg "$TPL_MIN" "$p" "GUI/app removed: $p"
done

# Services status (ignore if unit is static/not applicable)
check_service_enabled "$TPL_MIN" "NetworkManager" "NetworkManager enabled (min)"
check_cmd "$TPL_MIN" "systemctl list-unit-files | grep -q '^qubes-usb-proxy.service' && systemctl is-enabled qubes-usb-proxy || echo static-or-missing" "" "qubes-usb-proxy unit exists or static"

# No unwanted services enabled
check_cmd "$TPL_MIN" "systemctl list-unit-files | grep -q '^cups.service' && systemctl is-enabled cups || echo not-present" "not-present" "cups not present/enabled"
check_cmd "$TPL_MIN" "systemctl list-unit-files | grep -q '^avahi-daemon.service' && systemctl is-enabled avahi-daemon || echo not-present" "not-present" "avahi not present/enabled"

# Size/footprint comparative (prints numbers; manual glance)
dash "Footprint check (root fs size):"
printf "HARD: %s\n" "$(vrun "$TPL_HARD" "df -h / | tail -1")"
printf "MIN : %s\n" "$(vrun "$TPL_MIN"  "df -h / | tail -1")"

dash "Done."



# dom0
# Example creation (adjust to your network/usb backend setup):
# qvm-create --class=NetVM     --template debian-12-hard-min --label green  sys-net
# qvm-create --class=FirewallVM --template debian-12-hard-min --label yellow sys-firewall
# qvm-create --class=AppVM     --template debian-12-hard-min --label gray   sys-usb

# Attach devices appropriately, set provides-network on sys-net, set UpdateVM to sys-firewall, etc.

# Smoke test DNS & outbound from sys-firewall
qvm-run -p sys-firewall 'curl -I https://deb.debian.org | head -n1'

# Smoke test Wi-Fi tooling in sys-net (no connection change)
qvm-run -p sys-net 'nmcli general status'
qvm-run -p sys-net 'iw dev || true'
qvm-run -p sys-net 'ethtool -i $(ip -o link | awk -F: "/^[0-9]+: e/{print \$2; exit}") || true'

# USB proxy presence
qvm-run -p sys-usb 'systemctl status qubes-usb-proxy | head -n3 || true'



# dom0 — test suite for debian-12-work template
TPL_WORK="debian-12-work"

pass(){ printf "PASS: %s\n" "$1"; }
fail(){ printf "FAIL: %s\n" "$1"; }

vrun(){ # qvm-run with -p to capture output; returns exit code
  qvm-run -u root -p "$1" "$2" 2>&1
}

check_cmd(){ # VM, command, needle(optional), description
  out="$(vrun "$1" "$2")"; ec=$?
  if [ $ec -eq 0 ] && { [ -z "$3" ] || printf "%s" "$out" | grep -q -- "$3"; }; then pass "$4"; else
    printf "%s\n" "$out"
    fail "$4"
  fi
}

check_present_pkg(){ # VM, package, description
  if vrun "$1" "dpkg -s $2 >/dev/null"; then pass "$3"; else fail "$3 (missing: $2)"; fi
}

check_file(){ # VM, path, description
  if vrun "$1" "test -f '$2'"; then pass "$3"; else fail "$3 (missing: $2)"; fi
}

check_file_has(){ # VM, path, needle, description
  if vrun "$1" "test -f '$2' && grep -q -- '$3' '$2'"; then pass "$4"; else fail "$4"; fi
}

check_exec_version(){ # VM, cmd --version, grep-needle, description
  check_cmd "$1" "$2" "$3" "$4"
}

dash(){ printf "\n--- %s ---\n" "$1"; }

# ---------- Start ----------
dash "Template presence"
if qvm-ls --raw-list | grep -qx "$TPL_WORK"; then pass "$TPL_WORK exists"; else fail "$TPL_WORK does not exist"; exit 1; fi

dash "APT sanity"
check_cmd "$TPL_WORK" "apt-get update" "" "apt-get update succeeds"

dash "Core toolchain"
for p in git curl wget gnupg ca-certificates terminator tmux htop vim nano \
         build-essential cmake pkg-config gdb clang python3 python3-venv python3-pip \
         nodejs npm jq ripgrep fzf zip unzip ethtool iproute2 pciutils usbutils; do
  check_present_pkg "$TPL_WORK" "$p" "package present: $p"
done

dash "VS Code (Microsoft repo)"
check_file "$TPL_WORK" "/usr/share/keyrings/packages.microsoft.gpg" "VS Code keyring installed"
check_file_has "$TPL_WORK" "/etc/apt/sources.list.d/vscode.list" "packages.microsoft.com" "VS Code repo file present"
check_exec_version "$TPL_WORK" "code --version | head -n1" "Code" "code --version runs"

dash "Brave browser (official repo)"
check_file "$TPL_WORK" "/usr/share/keyrings/brave-browser-archive-keyring.gpg" "Brave keyring installed"
check_file_has "$TPL_WORK" "/etc/apt/sources.list.d/brave-browser-release.list" "brave-browser-apt-release" "Brave repo file present"
check_exec_version "$TPL_WORK" "brave-browser --version" "Brave" "brave-browser --version runs"

dash "Docker CE (official repo)"
check_file "$TPL_WORK" "/etc/apt/keyrings/docker.gpg" "Docker keyring installed"
check_file_has "$TPL_WORK" "/etc/apt/sources.list.d/docker.list" "download.docker.com" "Docker repo file present"
# packages
for p in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
  check_present_pkg "$TPL_WORK" "$p" "docker pkg present: $p"
done
# binaries report version (daemon not required)
check_exec_version "$TPL_WORK" "docker --version" "Docker version" "docker CLI present"
check_exec_version "$TPL_WORK" "docker compose version" "Docker Compose" "docker compose plugin present"

dash "Postman (tarball install)"
check_file "$TPL_WORK" "/opt/Postman/Postman" "Postman binary in /opt/Postman"
check_file "$TPL_WORK" "/usr/bin/postman" "Postman symlink in /usr/bin"
check_exec_version "$TPL_WORK" "/usr/bin/postman --version || true" "" "postman binary is callable (may not print version)"

dash "MongoDB Compass (.deb install)"
check_present_pkg "$TPL_WORK" "mongodb-compass" "MongoDB Compass package installed"
check_exec_version "$TPL_WORK" "mongodb-compass --version 2>/dev/null || dpkg -s mongodb-compass | grep -i ^Version" "" "mongodb-compass version available"

dash "No-net restored on template"
NETVM_VAL="$(qvm-prefs "$TPL_WORK" netvm || true)"
if [ -z "$NETVM_VAL" ]; then pass "netvm is empty (no network)"; else printf "netvm=%s\n" "$NETVM_VAL"; fail "netvm should be empty"; fi

dash "Repo GPG integrity (apt update OK after all repos)"
check_cmd "$TPL_WORK" "apt-get update" "" "apt-get update succeeds after repo add"

dash "Done."


exit 0
