#!/bin/bash
set -euo pipefail

# --- config (edit if your names differ)
SYS_VPN="sys-vpn"
SYS_DNS="sys-dns"
SYS_FW="sys-firewall"
SYS_NET="sys-net"

# helper
info(){ printf "[*] %s\n" "$*"; }
ok(){ printf "[OK] %s\n" "$*"; }
die(){ printf "[!!] %s\n" "$*" >&2; exit 1; }

# --- 0) sanity / wiring
info "Checking qube presence and wiring…"
qvm-ls --raw-list | grep -qx "$SYS_VPN" || die "$SYS_VPN missing"
qvm-ls --raw-list | grep -qx "$SYS_DNS" || die "$SYS_DNS missing"
qvm-ls --raw-list | grep -qx "$SYS_FW"  || die "$SYS_FW missing"
qvm-ls --raw-list | grep -qx "$SYS_NET" || die "$SYS_NET missing"

[[ "$(qvm-prefs "$SYS_VPN" netvm)" == "$SYS_NET" ]] || die "Expected $SYS_VPN → $SYS_NET"
[[ "$(qvm-prefs "$SYS_DNS" netvm)" == "$SYS_VPN" ]] || die "Expected $SYS_DNS → $SYS_VPN"
[[ "$(qvm-prefs "$SYS_FW"  netvm)" == "$SYS_DNS" ]] || die "Expected $SYS_FW → $SYS_DNS"
ok "Chain: $SYS_FW → $SYS_DNS → $SYS_VPN → $SYS_NET"

# --- 1) detect active VPN connection name (NetworkManager)
info "Detecting active VPN connection in $SYS_VPN…"
ACTIVE_VPN_LINE=$(qvm-run -p "$SYS_VPN" "nmcli -t -f NAME,TYPE,DEVICE connection show --active | egrep ':vpn:' || true")
if [[ -z "$ACTIVE_VPN_LINE" ]]; then
  info "No active VPN; attempting to bring it up (autoconnect expected)…"
  qvm-run -p "$SYS_VPN" "nmcli -t -f NAME,TYPE connection show | awk -F: '\$2==\"vpn\"{print \$1;exit}'" | read -r VPN_NAME || true
  [[ -n "${VPN_NAME:-}" ]] || die "No VPN profile found in NetworkManager. Import your .ovpn/.conf first."
  qvm-run "$SYS_VPN" "nmcli connection up \"$VPN_NAME\"" || die "Failed to bring up VPN $VPN_NAME"
  ACTIVE_VPN_LINE=$(qvm-run -p "$SYS_VPN" "nmcli -t -f NAME,TYPE,DEVICE connection show --active | egrep ':vpn:'")
fi
VPN_NAME="${ACTIVE_VPN_LINE%%:*}"
ok "VPN active: ${VPN_NAME}"

# --- 2) fetch public IP via sys-vpn and compare to sys-net (baseline)
info "Grabbing public IPs (via sys-vpn and via sys-net baseline)…"
IP_VPN=$(qvm-run -p "$SYS_VPN" "curl -4s --max-time 8 https://ifconfig.co/ip || curl -4s --max-time 8 https://api.ipify.org")
[[ -n "$IP_VPN" ]] || die "Could not fetch public IP via $SYS_VPN"
IP_NET=$(qvm-run -p "$SYS_NET" "curl -4s --max-time 8 https://ifconfig.co/ip || curl -4s --max-time 8 https://api.ipify.org")
[[ -n "$IP_NET" ]] || die "Could not fetch public IP via $SYS_NET"
printf "  %s egress IP: %s\n" "$SYS_VPN" "$IP_VPN"
printf "  %s egress IP: %s\n" "$SYS_NET" "$IP_NET"
[[ "$IP_VPN" != "$IP_NET" ]] && ok "Egress IP differs from sys-net → likely tunneled" || info "Egress IP equals sys-net (provider might exit near you)."

# --- 3) DNS leak check from sys-dns (no plaintext :53 off-box)
info "Checking for plaintext DNS leaving $SYS_DNS…"
qvm-run "$SYS_DNS" "rm -f /tmp/dns_out.pcap"
qvm-run "$SYS_DNS" "timeout 6 tcpdump -ni any -w /tmp/dns_out.pcap port 53 and not host 127.0.0.1 and not net 10.139.0.0/16 and not net 10.137.0.0/16 >/dev/null 2>&1 &"
sleep 1
# trigger lookups via a couple of client VMs if present
for vm in personal work pro untrusted; do
  if qvm-ls --raw-list | grep -qx "$vm"; then
    qvm-run -p -u root "$vm" "getent hosts qubes-os.org google.com github.com >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  fi
done
sleep 6
CNT=$(qvm-run -p "$SYS_DNS" "tcpdump -nr /tmp/dns_out.pcap 2>/dev/null | wc -l" || echo "X")
[[ "$CNT" == "0" ]] && ok "No plaintext DNS egress from $SYS_DNS" || die "Detected plaintext DNS ($CNT packets). Fix DNAT in $SYS_DNS qubes-firewall-user-script."

# --- 4) vpn killswitch test: bring VPN down and confirm no egress
info "Testing killswitch by bringing VPN down…"
# remember initial state to restore later
INIT_STATE="up"
qvm-run "$SYS_VPN" "nmcli connection down \"$VPN_NAME\"" || die "Failed to bring VPN down"
sleep 2
# attempt egress from a client via the normal chain (should fail or time out)
LEAK_OK=1
if qvm-ls --raw-list | grep -qx personal; then
  set +e
  qvm-run -p personal "curl -4sS --max-time 6 https://ifconfig.co/ip" >/dev/null 2>&1
  RC=$?
  set -e
  [[ $RC -ne 0 ]] && LEAK_OK=0
else
  # fallback: test from sys-vpn directly (should be blocked by killswitch)
  set +e
  qvm-run -p "$SYS_VPN" "curl -4sS --max-time 6 https://ifconfig.co/ip" >/dev/null 2>&1
  RC=$?
  set -e
  [[ $RC -ne 0 ]] && LEAK_OK=0
fi
[[ $LEAK_OK -eq 0 ]] && ok "Killswitch blocks egress when VPN is down" || die "Traffic escaped with VPN down. Fix killswitch rules in $SYS_VPN."

# --- 5) restore VPN and re-check egress IP
info "Restoring VPN…"
qvm-run "$SYS_VPN" "nmcli connection up \"$VPN_NAME\"" || die "Failed to bring VPN back up"
sleep 3
IP_VPN2=$(qvm-run -p "$SYS_VPN" "curl -4s --max-time 8 https://ifconfig.co/ip || curl -4s --max-time 8 https://api.ipify.org")
[[ -n "$IP_VPN2" ]] || die "Could not fetch public IP after bringing VPN up"
ok "VPN restored; egress IP: $IP_VPN2"

echo
ok "All tests completed successfully."
