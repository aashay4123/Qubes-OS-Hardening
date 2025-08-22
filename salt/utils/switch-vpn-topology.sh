# /usr/local/bin/switch-vpn-topology (dom0)
#!/bin/bash
set -euo pipefail

usage() {
  cat <<USAGE
usage: $0 <dns-vpn | dns-tor-vpn | dns-vpn-tor> [vpn-vm]
examples:
  $0 dns-vpn sys-vpn-nl
  $0 dns-vpn-tor sys-vpn-ru
  $0 dns-tor-vpn
USAGE
}

MODE="${1:-}"; VPN="${2:-}"
[[ -z "$MODE" ]] && { usage; exit 1; }

case "$MODE" in
  dns-vpn|dns-tor-vpn|dns-vpn-tor) ;;
  *) echo "Invalid mode: $MODE"; usage; exit 1;;
esac

need_vm() {
  qvm-ls --raw-list | grep -qx "$1" || { echo "Missing VM: $1" >&2; exit 1; }
}

need_vm sys-firewall
need_vm sys-dns
need_vm sys-net

# Pick VPN VM
if [[ -z "${VPN}" ]]; then
  if   qvm-ls --raw-list | grep -qx sys-vpn-ru; then VPN="sys-vpn-ru"
  elif qvm-ls --raw-list | grep -qx sys-vpn-nl; then VPN="sys-vpn-nl"
  else echo "No VPN VMs (sys-vpn-ru/sys-vpn-nl) found."; exit 1
  fi
else
  need_vm "$VPN"
fi

link() { qvm-prefs "$1" netvm "$2"; }

case "$MODE" in
  dns-vpn)
    link sys-firewall sys-net
    link sys-dns      "$VPN"
    link "$VPN"       sys-net
    ;;
  dns-tor-vpn)
    need_vm sys-vpn-tor
    link sys-firewall sys-net
    link sys-dns      sys-vpn-tor
    link sys-vpn-tor  "$VPN"
    link "$VPN"       sys-net
    ;;
  dns-vpn-tor)
    need_vm sys-vpn-tor
    link sys-firewall sys-net
    link sys-dns      "$VPN"
    link "$VPN"       sys-vpn-tor
    link sys-vpn-tor  sys-net
    ;;
esac

echo "Switched to: $MODE (VPN=$VPN)"
printf "%-14s -> %s\n" sys-firewall "$(qvm-prefs sys-firewall netvm)"
printf "%-14s -> %s\n" sys-dns      "$(qvm-prefs sys-dns netvm)"
[[ "$MODE" != "dns-tor-vpn" ]] && printf "%-14s -> %s\n" "$VPN" "$(qvm-prefs "$VPN" netvm)"
qvm-ls --raw-list | grep -qx sys-vpn-tor && printf "%-14s -> %s\n" sys-vpn-tor "$(qvm-prefs sys-vpn-tor netvm)"
chmod 0755 /usr/local/bin/switch-vpn-topology

# USAGE

# sudo install -m 755 switch-vpn-topology /usr/local/bin/

# sudo /usr/local/bin/switch-vpn-topology <mode> [vpn-vm]
# # e.g.
# sudo switch-vpn-topology dns-vpn sys-vpn-nl
# sudo switch-vpn-topology dns-vpn-tor sys-vpn-ru
# sudo switch-vpn-topology dns-tor-vpn
