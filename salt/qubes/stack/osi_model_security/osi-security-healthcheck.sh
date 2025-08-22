#!/bin/bash
# Qubes OS — OSI Model Security Verifier / Health Check (v1.1)
# Adds DisposableVM checks (DVM templates, global & per-VM defaults, qrexec policy, optional spawn test).

set -euo pipefail
RED="$(printf '\033[31m')"; GREEN="$(printf '\033[32m')"; YELLOW="$(printf '\033[33m')"; BOLD="$(printf '\033[1m')"; NC="$(printf '\033[0m')"
pass(){ echo -e "${GREEN}✔${NC} $*"; }
warn(){ echo -e "${YELLOW}⚠${NC} $*"; }
fail(){ echo -e "${RED}✘${NC} $*"; ((FAILS++)); }
info(){ echo -e "${BOLD}→${NC} $*"; }

FAILS=0
NO_START=0
APP_VMS_CLI=""
# NEW: Disposable-related CLI hints (optional)
DVM_LIST=""                 # --dvm  "debian-12-dvm fedora-40-dvm"
DEFAULT_DISPVM_EXPECT=""    # --default-dispvm "debian-12-dvm"
PER_VM_DEFAULTS=""          # --per-vm-default "work-web:debian-12-dvm dev:fedora-40-dvm"
SPAWN_TEST=0                # --spawn-test to actually spawn disposables

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-start) NO_START=1; shift ;;
    --apps) APP_VMS_CLI="$2"; shift 2 ;;
    --dvm) DVM_LIST="$2"; shift 2 ;;
    --default-dispvm) DEFAULT_DISPVM_EXPECT="$2"; shift 2 ;;
    --per-vm-default) PER_VM_DEFAULTS="$2"; shift 2 ;;
    --spawn-test) SPAWN_TEST=1; shift ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

need_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing command in dom0: $1"; exit 3; }; }
for c in qvm-ls qvm-prefs qvm-run qvm-start qvm-check qvm-tags qvm-firewall; do need_cmd "$c"; done
command -v jq >/dev/null 2>&1 || true  # optional

# -------------------- helpers --------------------
SYS_VMS=(sys-usb sys-net sys-ids sys-dns sys-firewall)

detect_app_vms() {
  local detected=()
  while IFS= read -r vm; do
    [[ -z "$vm" ]] && continue
    if qvm-tags "$vm" -l 2>/dev/null | grep -qx "layer_app"; then
      detected+=("$vm")
    fi
  done < <(qvm-ls --raw-list 2>/dev/null || true)
  echo "${detected[@]}"
}
if [[ -n "$APP_VMS_CLI" ]]; then
  # shellcheck disable=SC2206
  APP_VMS=($APP_VMS_CLI)
else
  APP_VMS=($(detect_app_vms))
fi

start_vm() { [[ $NO_START -eq 1 ]] && return 0; qvm-start --skip-if-running "$1" >/dev/null 2>&1 || true; }
rin() { local vm="$1"; shift; qvm-run --pass-io -u root "$vm" "$*" 2>/dev/null; }
get_tpl(){ qvm-prefs -g "$1" template 2>/dev/null || echo ""; }

# -------------------- 0) Presence & chain --------------------
info "Checking core service VMs exist and have expected prefs…"
for vm in "${SYS_VMS[@]}"; do
  if qvm-check -q "$vm"; then pass "$vm exists"; else fail "$vm is missing"; fi
done

info "Checking provides_network flags…"
for vm in sys-net sys-ids sys-dns sys-firewall; do
  if qvm-check -q "$vm"; then
    pn=$(qvm-prefs -g "$vm" provides_network 2>/dev/null || echo "False")
    [[ "$pn" == "True" ]] && pass "$vm provides_network=True" || fail "$vm provides_network != True"
  fi
done

info "Checking NetVM chain app → sys-firewall → sys-dns → sys-ids → sys-net…"
sf=$(qvm-prefs -g sys-firewall netvm 2>/dev/null || true)
sd=$(qvm-prefs -g sys-dns netvm 2>/dev/null || true)
si=$(qvm-prefs -g sys-ids netvm 2>/dev/null || true)
[[ "$sf" == "sys-dns" ]] && pass "sys-firewall → sys-dns" || fail "sys-firewall netvm is '$sf' (want sys-dns)"
[[ "$sd" == "sys-ids" ]] && pass "sys-dns → sys-ids" || fail "sys-dns netvm is '$sd' (want sys-ids)"
[[ "$si" == "sys-net" ]] && pass "sys-ids → sys-net" || fail "sys-ids netvm is '$si' (want sys-net)"
if ((${#APP_VMS[@]})); then
  for avm in "${APP_VMS[@]}"; do
    nv=$(qvm-prefs -g "$avm" netvm 2>/dev/null || true)
    [[ "$nv" == "sys-firewall" ]] && pass "$avm → sys-firewall" || warn "$avm netvm is '$nv' (expected sys-firewall)"
  done
else
  warn "No app VMs detected with tag 'layer_app'. Use --apps \"vm1 vm2\" to check specific VMs."
fi

# -------------------- 1) dom0 USB policies --------------------
info "Checking dom0 USB policies…"
C1="/etc/qubes/policy.d/30-usb-core.policy"
C2="/etc/qubes/policy.d/31-usb-input.policy"
C3="/etc/qubes/policy.d/32-usb-storage.policy"
[[ -f "$C1" ]] && grep -Eq 'device\+usb|qubes.USB' "$C1" && grep -Eq 'sys-usb' "$C1" \
  && pass "usb core policy present and routes USB to sys-usb" \
  || fail "usb core policy missing or not routing to sys-usb ($C1)"
[[ -f "$C2" ]] && grep -q 'qubes.InputKeyboard' "$C2" && grep -q 'sys-usb dom0 ask' "$C2" \
  && pass "input policy requires ask via sys-usb" \
  || fail "input policy missing/weak ($C2)"
if [[ -f "$C3" ]] && grep -q '@tag:' "$C3" && grep -q 'device+block' "$C3"; then pass "storage policy tag-gated"; else warn "storage policy ($C3) not tag-gated or missing device+block rule"; fi

# -------------------- 2) sys-usb --------------------
if qvm-check -q sys-usb; then
  info "Checking sys-usb (usbguard)…"
  start_vm sys-usb
  st=$(rin sys-usb 'systemctl is-active usbguard || true')
  [[ "$st" == "active" ]] && pass "sys-usb: usbguard active" || fail "sys-usb: usbguard not active"
  rin sys-usb 'test -f /etc/usbguard/rules.conf' >/dev/null && pass "sys-usb: usbguard rules present" || warn "sys-usb: rules.conf missing"
  rin sys-usb 'test -s /var/log/usbguard/audit.log' >/dev/null && pass "sys-usb: audit log exists" || warn "sys-usb: audit log missing/empty"
fi

# -------------------- 3) sys-net --------------------
if qvm-check -q sys-net; then
  info "Checking sys-net (link hygiene)…"
  start_vm sys-net
  rin sys-net 'grep -q "wifi.cloned-mac-address=random" /etc/NetworkManager/conf.d/20-mac-randomize.conf' >/dev/null \
    && pass "sys-net: MAC randomization configured" || warn "sys-net: MAC randomization not found"
  rin sys-net 'grep -q "rp_filter=1" /etc/sysctl.d/99-qubes-link-harden.conf' >/dev/null \
    && pass "sys-net: sysctl hardening present" || warn "sys-net: sysctl hardening file not found"
fi

# -------------------- 4) sys-dns --------------------
if qvm-check -q sys-dns; then
  info "Checking sys-dns (Unbound)…"
  start_vm sys-dns
  st=$(rin sys-dns 'systemctl is-active unbound || true')
  [[ "$st" == "active" ]] && pass "sys-dns: unbound active" || fail "sys-dns: unbound not active"
  rin sys-dns 'unbound-checkconf /etc/unbound/unbound.conf >/dev/null 2>&1' \
    && pass "sys-dns: config valid" || fail "sys-dns: config invalid"
  rin sys-dns 'grep -q "log-queries: yes" /etc/unbound/unbound.conf' >/dev/null \
    && pass "sys-dns: query logging enabled" || warn "sys-dns: query logging not enabled"
  rin sys-dns 'test -s /var/log/unbound/unbound.log' >/dev/null \
    && pass "sys-dns: log file exists (has entries)" || warn "sys-dns: log file missing/empty"
fi

# -------------------- 5) sys-firewall --------------------
if qvm-check -q sys-firewall; then
  info "Checking sys-firewall (dnsmasq + sysctl)…"
  start_vm sys-firewall
  rin sys-firewall 'grep -q "ip_forward=1" /etc/sysctl.d/99-qubes-router-harden.conf' >/dev/null \
    && pass "sys-firewall: sysctl router hardening present" || warn "sys-firewall: sysctl hardening file not found"
  if rin sys-firewall 'command -v dnsmasq >/dev/null; echo $?' | grep -qx 0; then
    pass "sys-firewall: dnsmasq installed"
    st=$(rin sys-firewall 'systemctl is-active dnsmasq || true')
    [[ "$st" == "active" ]] && pass "sys-firewall: dnsmasq active" || warn "sys-firewall: dnsmasq not active"
    rin sys-firewall 'grep -q "log-queries" /etc/dnsmasq.d/99-logging.conf' >/dev/null \
      && pass "sys-firewall: dnsmasq logging configured" || warn "sys-firewall: dnsmasq logging conf missing"
    rin sys-firewall 'test -s /var/log/dnsmasq.log' >/dev/null \
      && pass "sys-firewall: dnsmasq log exists (has entries)" || warn "sys-firewall: dnsmasq log missing/empty"
  else
    warn "sys-firewall: dnsmasq not installed"
  fi
fi

# -------------------- 6) sys-ids --------------------
if qvm-check -q sys-ids; then
  info "Checking sys-ids (Suricata)…"
  start_vm sys-ids
  st=$(rin sys-ids 'systemctl is-active suricata || true')
  [[ "$st" == "active" ]] && pass "sys-ids: suricata active" || warn "sys-ids: suricata not active"
  rin sys-ids 'test -s /var/log/suricata/eve.json' >/dev/null \
    && pass "sys-ids: eve.json present (DNS/flow logs)" || warn "sys-ids: eve.json missing/empty"
fi

# -------------------- 7) Transport crypto (templates) --------------------
info "Gathering templates used by service + app VMs…"
declare -A TPLS=()
for vm in "${SYS_VMS[@]}"; do if qvm-check -q "$vm"; then t=$(get_tpl "$vm"); [[ -n "$t" ]] && TPLS["$t"]=1; fi; done
for avm in "${APP_VMS[@]}"; do if qvm-check -q "$avm"; then t=$(get_tpl "$avm"); [[ -n "$t" ]] && TPLS["$t"]=1; fi; done
for tpl in "${!TPLS[@]}"; do
  info "Checking template: $tpl (TLS/SSH/Chrony)"
  start_vm "$tpl"
  if rin "$tpl" 'command -v apt-get >/dev/null; echo $?' | grep -qx 0; then
    rin "$tpl" 'test -f /etc/ssl/openssl.cnf.d/40-system-policy.cnf' >/dev/null && pass "$tpl: OpenSSL policy present" || warn "$tpl: OpenSSL policy missing"
    rin "$tpl" 'grep -q "MinProtocol = TLSv1.2" /etc/ssl/openssl.cnf.d/40-system-policy.cnf' >/dev/null && pass "$tpl: TLS >=1.2 enforced" || warn "$tpl: TLS MinProtocol not enforced"
    rin "$tpl" 'systemctl is-active chrony >/dev/null 2>&1' >/dev/null && pass "$tpl: chrony active" || warn "$tpl: chrony not active"
    rin "$tpl" 'grep -q "nts" /etc/chrony/chrony.conf' >/dev/null && pass "$tpl: Chrony NTS configured" || warn "$tpl: Chrony NTS not found"
  else
    pol=$(rin "$tpl" 'update-crypto-policies --show 2>/dev/null || echo "unknown"')
    [[ "$pol" == "FUTURE" || "$pol" == "DEFAULT" ]] && pass "$tpl: crypto-policy $pol" || warn "$tpl: crypto-policy unknown"
    rin "$tpl" 'systemctl is-active chronyd >/dev/null 2>&1' >/vol/null && pass "$tpl: chronyd active" || warn "$tpl: chronyd not active"
    rin "$tpl" 'grep -q "nts" /etc/chrony.conf' >/dev/null && pass "$tpl: Chrony NTS configured" || warn "$tpl: Chrony NTS not found"
  fi
  rin "$tpl" 'test -f /etc/ssh/ssh_config.d/40-hardening.conf' >/dev/null && pass "$tpl: SSH client hardening present" || warn "$tpl: SSH client hardening missing"
done

# -------------------- 8) App VM firewall (best-effort) --------------------
if ((${#APP_VMS[@]})); then
  info "Checking app VM firewalls (default drop + allows)…"
  for avm in "${APP_VMS[@]}"; do
    if qvm-check -q "$avm"; then
      if qvm-firewall "$avm" list 2>/dev/null | grep -Eiq 'default.*drop|policy.*drop'; then
        pass "$avm: default drop in firewall"
      else
        warn "$avm: firewall default drop not detected"
      fi
    fi
  done
fi

# -------------------- 9) DisposableVMs (DVM templates, defaults, policies) --------------------
info "Checking DisposableVM configuration…"
# 9.1: discover all DVM templates
mapfile -t DVM_TEMPLATES < <(qvm-ls --raw-list 2>/dev/null | while read -r v; do [[ -n "$v" ]] || continue; if [[ "$(qvm-prefs -g "$v" template_for_dispvms 2>/dev/null || echo false)" == "True" ]]; then echo "$v"; fi; done)
if ((${#DVM_TEMPLATES[@]})); then pass "Found DVM templates: ${DVM_TEMPLATES[*]}"; else warn "No DVM templates detected (template_for_dispvms=True)"; fi

# 9.2: global default_dispvm
GLOBAL_DISPVM=$(qubes-prefs -g default_dispvm 2>/dev/null || echo "")
if [[ -n "$GLOBAL_DISPVM" ]]; then
  pass "Global default_dispvm is '$GLOBAL_DISPVM'"
  if ((${#DVM_TEMPLATES[@]})) && ! printf '%s\n' "${DVM_TEMPLATES[@]}" | grep -qx "$GLOBAL_DISPVM"; then
    warn "Global default_dispvm is not one of the detected DVM templates"
  fi
else
  warn "Global default_dispvm is not set"
fi
# Assert expected if provided via CLI
if [[ -n "$DEFAULT_DISPVM_EXPECT" ]]; then
  [[ "$GLOBAL_DISPVM" == "$DEFAULT_DISPVM_EXPECT" ]] && pass "Global default_dispvm matches expected '$DEFAULT_DISPVM_EXPECT'" || fail "Global default_dispvm '$GLOBAL_DISPVM' != expected '$DEFAULT_DISPVM_EXPECT'"
fi

# 9.3: per-VM default_dispvm (from CLI map "vm:disp vm2:disp2")
if [[ -n "$PER_VM_DEFAULTS" ]]; then
  for pair in $PER_VM_DEFAULTS; do
    vm="${pair%%:*}"; disp="${pair#*:}"
    cur=$(qvm-prefs -g "$vm" default_dispvm 2>/dev/null || echo "")
    [[ "$cur" == "$disp" ]] && pass "$vm: default_dispvm='$disp' (as expected)" || fail "$vm: default_dispvm='$cur' (expected '$disp')"
  done
fi

# 9.4: qrexec policy files (Qubes 4.2+)
POL_OPENURL="/etc/qubes/policy.d/33-dispvm-openurl.policy"
POL_OPENINVM="/etc/qubes/policy.d/34-dispvm-openinvm.policy"
[[ -f "$POL_OPENURL" ]] && pass "OpenURL policy file present" || warn "OpenURL policy file missing ($POL_OPENURL)"
[[ -f "$POL_OPENINVM" ]] && pass "OpenInVM policy file present" || warn "OpenInVM policy file missing ($POL_OPENINVM)"
if [[ -f "$POL_OPENURL" ]]; then grep -q "@dispvm" "$POL_OPENURL" && pass "OpenURL policy forces @dispvm for some tag(s)" || warn "OpenURL policy does not force @dispvm"; fi
if [[ -f "$POL_OPENINVM" ]]; then grep -q "@dispvm" "$POL_OPENINVM" && pass "OpenInVM policy forces @dispvm for some tag(s)" || warn "OpenInVM policy does not force @dispvm"; fi

# 9.5: optional spawn test (will start a transient disposable; skip with --no-start)
if (( SPAWN_TEST == 1 )); then
  if [[ -n "$DVM_LIST" ]]; then
    # shellcheck disable=SC2206
    for d in $DVM_LIST; do
      info "Spawning quick disposable from '$d'…"
      if qvm-run --pass-io --dispvm="$d" 'true' >/dev/null 2>&1; then
        pass "Spawn test OK for '$d'"
      else
        fail "Failed to spawn disposable from '$d'"
      fi
    done
  else
    warn "No --dvm list provided; skipping spawn tests."
  fi
fi

# -------------------- Summary --------------------
echo
if (( FAILS == 0 )); then
  echo -e "${GREEN}${BOLD}All critical checks passed.${NC}"
else
  echo -e "${RED}${BOLD}$FAILS critical check(s) failed.${NC}  Review messages above."
fi
exit $(( FAILS > 0 ))
