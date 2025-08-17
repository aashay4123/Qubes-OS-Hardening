#!/bin/bash
set -euo pipefail

ok(){ echo -e "✅ $*"; }
warn(){ echo -e "⚠️  $*"; }
die(){ echo -e "❌ $*"; exit 1; }

need(){ command -v "$1" >/dev/null || die "Missing $1 in dom0"; }
for b in qvm-ls qvm-prefs qvm-run qvm-tags; do need "$b"; done

has_vm(){ qvm-ls --raw-list | grep -qx "$1"; }
pref(){ qvm-prefs "$1" "$2" 2>/dev/null | tr -d ' '; }
tmpl(){ qvm-prefs "$1" template 2>/dev/null | tr -d ' '; }
tagged(){ qvm-tags "$1" | grep -qx "$2"; }
vm_ip(){ qvm-ls --raw-data --fields NAME,IP | awk -F'|' -v n="$1" '$1==n{gsub(/ /,"",$2);print $2}'; }

assert_eq(){ [[ "$1" == "$2" ]] && ok "$3 = $2" || die "$3 expected=$2 got=$1"; }
assert_yes(){ [[ "$1" =~ ^(True|true)$ ]] && ok "$2 = True" || die "$2 must be True"; }
assert_none(){ [[ -z "$1" || "$1" == "None" || "$1" == "none" ]] && ok "$2 is None" || die "$2 must be None"; }

echo "=== Templates present ==="
for T in deb_harden_min deb_harden deb_dev deb_work deb_personal fedora-42-vpn; do
  has_vm "$T" && ok "Template OK: $T" || die "Template missing: $T"
done

echo "=== Core service VMs ==="
for V in sys-net sys-firewall sys-dns; do has_vm "$V" && ok "VM OK: $V" || die "Missing VM: $V"; done
for V in sys-vpn-ru sys-vpn-nl; do has_vm "$V" && ok "VM OK: $V" || warn "VPN VM missing: $V (ok if not created)"; done
has_vm sys-usb && ok "VM OK: sys-usb" || warn "sys-usb not present"

echo "=== sys-net checks ==="
assert_eq "$(tmpl sys-net)" "deb_harden_min" "sys-net template"
assert_none "$(pref sys-net netvm)" "sys-net netvm"
assert_yes "$(pref sys-net provides_network)" "sys-net provides_network"
violators=$(qvm-ls --raw-data --fields NAME,NETVM | awk -F'|' '$2 ~ /sys-net/ && $1!="sys-firewall"{print $1}')
[[ -z "$violators" ]] && ok "Only sys-firewall uses sys-net" || { echo "$violators" | sed 's/^/❌ Violator uses sys-net: /'; die "Only sys-firewall may use sys-net"; }

echo "=== sys-firewall checks ==="
assert_eq "$(tmpl sys-firewall)" "deb_harden_min" "sys-firewall template"
assert_eq "$(pref sys-firewall netvm)" "sys-net" "sys-firewall netvm"
SYS_DNS_IP="$(vm_ip sys-dns)"; [[ -n "$SYS_DNS_IP" ]] || die "Cannot get sys-dns IP"
# DNAT DNS to sys-dns:
qvm-run -q -u root --pass-io sys-firewall \
  "nft list table ip nat | sed -n '/table ip nat/,/}/p' | grep -E 'dport (53).*dnat to ${SYS_DNS_IP}'" >/dev/null \
  && ok "sys-firewall DNAT tcp/udp:53 -> $SYS_DNS_IP" \
  || { qvm-run -u root sys-firewall 'nft list table ip nat || true'; die "Missing DNAT to sys-dns"; }
# DoT block present:
qvm-run -q -u root --pass-io sys-firewall \
  "nft list ruleset | sed -n '/hook forward/,/}/p' | grep -E 'dport 853.*drop'" >/dev/null \
  && ok "sys-firewall blocks DoT (tcp/udp 853)" \
  || warn "DoT block not found (optional)."

echo "=== sys-dns checks ==="
assert_eq "$(tmpl sys-dns)" "deb_harden_min" "sys-dns template"
assert_eq "$(pref sys-dns netvm)" "sys-firewall" "sys-dns netvm"
tagged sys-dns @tag:dns-resolver && ok "sys-dns tagged @tag:dns-resolver" || die "sys-dns must have @tag:dns-resolver"
qvm-run -q -u root --pass-io sys-dns "grep -q '^nameserver 127\.0\.0\.1' /etc/resolv.conf" && ok "sys-dns resolv.conf = 127.0.0.1" || die "sys-dns resolv.conf must be localhost"
qvm-run -q -u root --pass-io sys-dns "systemctl is-active dnscrypt-proxy" | grep -qx active && ok "dnscrypt-proxy active in sys-dns" || die "dnscrypt-proxy must run in sys-dns"
qvm-run -q -u root --pass-io sys-dns "nft list ruleset | grep -E 'dport 53' | grep -E 'ip daddr != 127\.0\.0\.1.*drop' -q" \
  && ok "sys-dns local DNS egress lock" || die "sys-dns must drop DNS not to 127.0.0.1"

echo "=== VPN VMs (if present) — no dnscrypt inside ==="
for VPN in sys-vpn-ru sys-vpn-nl; do
  if has_vm "$VPN"; then
    assert_eq "$(tmpl "$VPN")" "fedora-42-vpn" "$VPN template"
    assert_eq "$(pref "$VPN" netvm)" "sys-firewall" "$VPN netvm"
    # ensure NOT running dnscrypt
    if qvm-run -q -u root --pass-io "$VPN" "systemctl is-active dnscrypt-proxy" >/dev/null 2>&1; then
      state=$(qvm-run -q -u root --pass-io "$VPN" "systemctl is-active dnscrypt-proxy" || true)
      [[ "$state" != "active" ]] && ok "$VPN has no active dnscrypt (state=$state)" || die "$VPN must NOT run dnscrypt (only sys-dns does)"
    else
      ok "$VPN has no dnscrypt-proxy service"
    fi
  fi
done

echo "=== AppVMs (work/dev/personal) ==="
for V in work dev personal; do
  has_vm "$V" || { warn "$V missing"; continue; }
  assert_eq "$(tmpl "$V")" "deb_harden" "$V template"
  NV="$(pref "$V" netvm)"
  [[ "$NV" == "sys-firewall" || "$NV" == "sys-vpn-ru" || "$NV" == "sys-vpn-nl" ]] \
    && ok "$V netvm = $NV" || die "$V netvm must be sys-firewall or sys-vpn-*"
done

echo "=== sys-usb & device policies ==="
if has_vm sys-usb; then
  assert_eq "$(pref sys-usb netvm)" "none" "sys-usb netvm"
  # Input policy presence
  [[ -f /etc/qubes/policy.d/30-input.policy ]] && ok "input policy present" || die "30-input.policy missing"
  grep -q 'qubes\.InputKeyboard.*sys-usb.*dom0.*allow' /etc/qubes/policy.d/30-input.policy && ok "keyboard proxied via sys-usb" || die "keyboard policy missing"
  grep -q 'qubes\.InputMouse.*sys-usb.*dom0.*allow' /etc/qubes/policy.d/30-input.policy && ok "mouse proxied via sys-usb" || die "mouse policy missing"
  # PCI policy presence
  [[ -f /etc/qubes/policy.d/30-pci.policy ]] && ok "PCI policy present" || die "30-pci.policy missing"
  grep -q 'device\.pci attach.*@anyvm.*sys-net.*allow' /etc/qubes/policy.d/30-pci.policy && ok "PCI attach -> sys-net only (allow)" || die "PCI allow to sys-net missing"
  grep -q 'device\.pci attach.*@anyvm.*@anyvm.*deny' /etc/qubes/policy.d/30-pci.policy && ok "PCI attach denied elsewhere" || die "PCI deny rule missing"
  # USB policy presence
  [[ -f /etc/qubes/policy.d/30-usb.policy ]] && ok "USB policy present" || die "30-usb.policy missing"
  # Either a generic allow to sys-net or at least one VID:PID allow line:
  if grep -q '^device\.usb attach\s\+sys-net\s\+sys-usb\s\+allow' /etc/qubes/policy.d/30-usb.policy || grep -q 'device=..*:' /etc/qubes/policy.d/30-usb.policy; then
    ok "USB policy allows only sys-net (with general or VID:PID allow)"
  else
    warn "USB policy has default deny; no allow for NICs found — add VID:PID lines for your USB NICs."
  fi
else
  warn "sys-usb missing — USB lockdown not enforced"
fi

echo "=== dom0 prefs ==="
UV="$(qubes-prefs updatevm || true)"
[[ "$UV" == "sys-firewall" ]] && ok "updatevm = sys-firewall" || warn "updatevm is '$UV' (recommend sys-firewall)"

echo -e "\n🎉 All checks done."
