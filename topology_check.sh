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

# ---------- Whonix: VPN ⇒ Tor gateway ----------
echo "=== Whonix VPN⇒Tor chain ==="
if has_vm sys-vpn-tor; then
  assert_eq "$(tmpl sys-vpn-tor)" "whonix-gateway-17" "sys-vpn-tor template"
  U="$(pref sys-vpn-tor netvm)"
  [[ "$U" == "sys-vpn-ru" || "$U" == "sys-vpn-nl" ]] && ok "sys-vpn-tor upstream NetVM = $U" || die "sys-vpn-tor NetVM must be sys-vpn-ru or sys-vpn-nl"
  assert_yes "$(pref sys-vpn-tor provides_network)" "sys-vpn-tor provides_network"

  # DNAT exclusion in sys-firewall (do not hijack Whonix DNS)
  SYS_VPN_TOR_IP="$(vm_ip sys-vpn-tor)"; [[ -n "$SYS_VPN_TOR_IP" ]] || die "Cannot get sys-vpn-tor IP"
  qvm-run -q -u root --pass-io sys-firewall \
    "nft list table ip nat | sed -n '/prerouting/,/}/p' | grep -E 'ip saddr ${SYS_VPN_TOR_IP}.*dport 53.*accept'" >/dev/null \
    && ok "sys-firewall NAT excludes DNS from sys-vpn-tor ($SYS_VPN_TOR_IP)" \
    || warn "Whonix DNS exclusion not found in NAT (ensure exclusion state applied)"
else
  warn "sys-vpn-tor not present (skip Whonix VPN⇒Tor checks)"
fi

# ---------- Whonix Workstations bound to sys-vpn-tor ----------
echo "=== Whonix WS over VPN⇒Tor ==="
for W in ws-tor-research ws-tor-forums; do
  if has_vm "$W"; then
    assert_eq "$(tmpl "$W")" "whonix-workstation-17" "$W template"
    assert_eq "$(pref "$W" netvm)" "sys-vpn-tor" "$W netvm"
  else
    warn "$W missing"
  fi
done

# ---------- Policies for Whonix pairings (soft guard) ----------
if [[ -f /etc/qubes/policy.d/50-whonix-vpn-tor.policy ]]; then
  ok "whonix-vpn-tor policy present"
else
  warn "50-whonix-vpn-tor.policy missing (optional soft guard)"
fi

# ---------- Split-GPG / Split-SSH ----------
echo "=== Split-GPG / Split-SSH ==="
# Vaults exist & networkless
for v in vault-secrets vault-dn-secrets; do
  has_vm "$v" || die "Missing vault: $v"
  assert_eq "$(pref "$v" netvm)" "none" "$v netvm"
done

# Client packages in templates
for t in deb_harden whonix-workstation-17; do
  qvm-run -q -u root --pass-io "$t" "dpkg -l | egrep -q 'qubes-gpg-client|qubes-app-linux-split-ssh'" \
    && ok "Split clients installed in $t" \
    || warn "Split clients missing in $t"
done

# Server bits in vaults
for v in vault-secrets vault-dn-secrets; do
  qvm-run -q -u root --pass-io "$v" "dpkg -l | egrep -q 'qubes-gpg-split|qubes-app-linux-split-ssh|gnupg'" \
    && ok "Split servers installed in $v" \
    || warn "Split servers missing in $v"
done

# Policies present
for p in /etc/qubes/policy.d/30-split-gpg.policy /etc/qubes/policy.d/30-split-ssh.policy; do
  [[ -f "$p" ]] && ok "Policy present: $p" || warn "Missing policy: $p"
done

# Tags applied to callers
for vm in work dev personal; do tagged "$vm" split-gpg-deb && tagged "$vm" split-ssh-deb \
  && ok "Tags OK on $vm (split-gpg-deb/split-ssh-deb)" \
  || warn "Missing split-gpg/ssh tags on $vm"; done
for vm in ws-tor-research ws-tor-forums; do tagged "$vm" split-gpg-ws && tagged "$vm" split-ssh-ws \
  && ok "Tags OK on $vm (split-gpg-ws/split-ssh-ws)" \
  || warn "Missing split-gpg/ssh tags on $vm"; done

# ---------- qube-pass integration ----------
echo "=== qube-pass ==="
# RPCs in vaults
for v in vault-secrets vault-dn-secrets; do
  qvm-run -q -u root --pass-io "$v" "[ -x /etc/qubes-rpc/my.pass.Lookup ]" \
    && ok "my.pass.Lookup installed in $v" \
    || warn "my.pass.Lookup missing in $v"
done
# Client wrappers in templates
for t in deb_harden whonix-workstation-17; do
  qvm-run -q -u root --pass-io "$t" "command -v qpass >/dev/null" \
    && ok "qpass present in $t" || warn "qpass missing in $t"
  qvm-run -q -u root --pass-io "$t" "command -v qpass-ws >/dev/null" \
    && ok "qpass-ws present in $t" || warn "qpass-ws missing in $t"
done
# Policy file
[[ -f /etc/qubes/policy.d/30-pass.policy ]] && ok "pass policy present" || warn "30-pass.policy missing"
# Tags for pass routing
for vm in work dev personal; do tagged "$vm" split-pass-deb && ok "pass tag ok on $vm" || warn "pass tag missing on $vm"; done
for vm in ws-tor-research ws-tor-forums; do tagged "$vm" split-pass-ws && ok "pass tag ok on $vm" || warn "pass tag missing on $vm"; done

# ---------- AppArmor enforcement for browsers ----------
echo "=== AppArmor (Firefox/Chromium) in templates ==="
for t in deb_harden whonix-workstation-17; do
  if qvm-run -q -u root --pass-io "$t" "aa-status 2>/dev/null | egrep -q '(firefox|chromium).*enforce'"; then
    ok "AppArmor enforced for browsers in $t"
  else
    warn "AppArmor not enforced for browsers in $t (profiles or aa-enforce missing)"
  fi
done


# Vault VMs exist + are networkless?
for v in vault-secrets vault-dn-secrets; do
  qvm-ls --raw-list | grep -qx $v || echo "MISSING VM: $v"
  nv=$(qvm-prefs $v netvm 2>/dev/null); [ "$nv" = "none" ] && echo "OK: $v netvm=none" || echo "FIX: $v netvm=$nv (should be none)"
done

# Client templates have Split-GPG/SSH bits?
for t in deb_harden whonix-workstation-17; do
  qvm-run -q -u root --pass-io $t "dpkg -l | egrep -q 'qubes-gpg-client|qubes-app-linux-split-ssh' && echo OK:$t clients" || echo "FIX: install split clients in $t"
done

# Vaults have server bits?
for v in vault-secrets vault-dn-secrets; do
  qvm-run -q -u root --pass-io $v "dpkg -l | egrep -q 'qubes-gpg-split|qubes-app-linux-split-ssh|gnupg' && echo OK:$v servers" || echo "FIX: install split servers in $v"
done

# qube-pass RPCs installed in vaults?
for v in vault-secrets vault-dn-secrets; do
  qvm-run -q -u root --pass-io $v "[ -x /etc/qubes-rpc/my.pass.Lookup ] && echo OK:$v pass.Lookup" || echo "FIX: my.pass.Lookup missing in $v"
done

# Policies present?
for p in /etc/qubes/policy.d/30-split-gpg.policy /etc/qubes/policy.d/30-split-ssh.policy /etc/qubes/policy.d/30-pass.policy; do
  [ -f $p ] && echo "OK: policy $p" || echo "FIX: missing $p"
done

# Tags present on callers?
for vm in work dev personal; do qvm-tags $vm | grep -q split-gpg-deb || echo "FIX: tag $vm with split-gpg-deb/split-ssh-deb"; done
for vm in ws-tor-research ws-tor-forums; do qvm-tags $vm | grep -q split-gpg-ws  || echo "FIX: tag $vm with split-gpg-ws/split-ssh-ws"; done

# AppArmor enforced for browsers in templates?
for t in deb_harden whonix-workstation-17; do
  qvm-run -q -u root --pass-io $t "aa-status 2>/dev/null | egrep -q '(firefox|chromium).*enforce' && echo OK:AppArmor:$t" || echo "WARN: AppArmor not enforced for browsers in $t"
done


echo "=== dom0 prefs ==="
UV="$(qubes-prefs updatevm || true)"
[[ "$UV" == "sys-firewall" ]] && ok "updatevm = sys-firewall" || warn "updatevm is '$UV' (recommend sys-firewall)"

echo -e "\n🎉 All checks done."
