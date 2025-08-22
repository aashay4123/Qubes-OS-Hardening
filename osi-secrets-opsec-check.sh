#!/bin/bash
# Qubes OS — Secrets/Policy/OPSEC Healthcheck (add-on) v1.0
# Run in dom0. No changes, only checks.
#
# Usage examples:
#   sudo ./osi-secrets-opsec-check.sh \
#       --gpg-vault vault-gpg --ssh-vault vault-ssh --pass-vault vault-pass \
#       --maint-vm work-web --opsec-templates "deb_harden deb_harden_min deb_work deb_hack"
#
#   sudo ./osi-secrets-opsec-check.sh --no-start   # skip qvm-run checks that would start VMs
#


# How to use

# Run it (with your vault names and a test VM for the maintenance tag):

# sudo ~/osi-secrets-opsec-check.sh \
#   --gpg-vault vault-gpg --ssh-vault vault-ssh --pass-vault vault-pass \
#   --maint-vm work-web \
#   --opsec-templates "deb_harden deb_harden_min deb_work deb_hack"

# If you don’t want it to start any VMs (it’ll skip VM-internal checks):
# sudo ~/osi-secrets-opsec-check.sh --no-start

set -euo pipefail
RED="$(printf '\033[31m')"; GREEN="$(printf '\033[32m')"; YELLOW="$(printf '\033[33m')"; BOLD="$(printf '\033[1m')"; NC="$(printf '\033[0m')"
pass(){ echo -e "${GREEN}✔${NC} $*"; }
warn(){ echo -e "${YELLOW}⚠${NC} $*"; }
fail(){ echo -e "${RED}✘${NC} $*"; ((FAILS++)); }
info(){ echo -e "${BOLD}→${NC} $*"; }

FAILS=0; NO_START=0
GPG_VAULT=""; SSH_VAULT=""; PASS_VAULT=""
MAINT_VM=""
OPSEC_TEMPLATES=("deb_harden" "deb_harden_min" "deb_work" "deb_hack")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gpg-vault) GPG_VAULT="$2"; shift 2 ;;
    --ssh-vault) SSH_VAULT="$2"; shift 2 ;;
    --pass-vault) PASS_VAULT="$2"; shift 2 ;;
    --maint-vm) MAINT_VM="$2"; shift 2 ;;
    --opsec-templates) read -r -a OPSEC_TEMPLATES <<<"$2"; shift 2 ;;
    --no-start) NO_START=1; shift ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

need_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing dom0 command: $1"; exit 3; }; }
for c in qvm-ls qvm-prefs qvm-run qvm-start qvm-check qvm-tags systemctl; do need_cmd "$c"; done
command -v jq >/dev/null 2>&1 || true

start_vm(){ [[ $NO_START -eq 1 ]] && return 0; qvm-start --skip-if-running "$1" >/dev/null 2>&1 || true; }
rin(){ local vm="$1"; shift; qvm-run --pass-io -u root "$vm" "$*" 2>/dev/null; }

# ---------- 0) Discover app templates for client-wrapper checks ----------
detect_app_vms() {
  local out=()
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    if qvm-tags "$v" -l 2>/dev/null | grep -qx "layer_app"; then out+=("$v"); fi
  done < <(qvm-ls --raw-list 2>/dev/null || true)
  echo "${out[@]}"
}
APP_VMS=($(detect_app_vms))
declare -A APP_TEMPLATES=()
for v in "${APP_VMS[@]}"; do
  t=$(qvm-prefs -g "$v" template 2>/dev/null || true)
  [[ -n "$t" ]] && APP_TEMPLATES["$t"]=1
done
TEMPLATE_LIST=("${!APP_TEMPLATES[@]}")

# ---------- 1) dom0: qrexec policies ----------
info "Checking dom0 qrexec policies… (Qubes 4.2+ path /etc/qubes/policy.d)"
P40_OPS="/etc/qubes/policy.d/40-gpg-ops.policy"
P43_MNT="/etc/qubes/policy.d/43-gpg-maint.policy"
P40_SPLIT="/etc/qubes/policy.d/40-split-gpg.policy"
P41_SSH="/etc/qubes/policy.d/41-split-ssh.policy"
P42_PASS="/etc/qubes/policy.d/42-qubes-pass.policy"

[[ -f "$P40_OPS" ]] && pass "Found $P40_OPS" || fail "Missing $P40_OPS"
[[ -f "$P43_MNT" ]] && pass "Found $P43_MNT" || fail "Missing $P43_MNT"
[[ -f "$P41_SSH" ]] && pass "Found $P41_SSH" || warn "Missing $P41_SSH (Split-SSH)"
[[ -f "$P42_PASS" ]] && pass "Found $P42_PASS" || warn "Missing $P42_PASS (qubes-pass)"
[[ -f "$P40_SPLIT" ]] && pass "Found $P40_SPLIT (Split-GPG classic)" || warn "Missing $P40_SPLIT (ok if not using classic service)"

grep -q 'gpg.Sign'   "$P40_OPS" 2>/dev/null && pass "Policy covers gpg.Sign"   || fail "gpg.Sign rule not found"
grep -q 'gpg.Decrypt'"$P40_OPS" 2>/dev/null && pass "Policy covers gpg.Decrypt"|| fail "gpg.Decrypt rule not found"
grep -q 'gpg.Encrypt'"$P40_OPS" 2>/dev/null && pass "Policy covers gpg.Encrypt"|| fail "gpg.Encrypt rule not found"
grep -q 'gpg.Verify' "$P40_OPS" 2>/dev/null && pass "Policy covers gpg.Verify" || fail "gpg.Verify rule not found"
grep -q 'gpg.AdminImport' "$P43_MNT" 2>/dev/null && pass "Maintenance: AdminImport rule" || fail "AdminImport rule missing"
grep -q 'gpg.AdminExport' "$P43_MNT" 2>/dev/null && pass "Maintenance: AdminExport rule" || fail "AdminExport rule missing"
grep -q 'qubes.SshAgent' "$P41_SSH" 2>/dev/null && pass "Split-SSH policy present" || warn "No qubes.SshAgent rule detected"
grep -q 'qubes.PassLookup' "$P42_PASS" 2>/dev/null && pass "qubes-pass policy present" || warn "No qubes.PassLookup rule detected"

if [[ -n "$GPG_VAULT" ]]; then
  grep -q "target=${GPG_VAULT}" "$P40_OPS" 2>/dev/null && pass "gpg.* targets ${GPG_VAULT}" || warn "gpg.* target mismatch vs ${GPG_VAULT}"
  grep -q "target=${GPG_VAULT}" "$P43_MNT" 2>/dev/null && pass "gpg.Admin* targets ${GPG_VAULT}" || warn "gpg.Admin* target mismatch"
fi
[[ -n "$SSH_VAULT" ]] && grep -q "target=${SSH_VAULT}" "$P41_SSH" 2>/dev/null && pass "qubes.SshAgent target ${SSH_VAULT}" || true
[[ -n "$PASS_VAULT" ]] && grep -q "target=${PASS_VAULT}" "$P42_PASS" 2>/dev/null && pass "qubes.PassLookup target ${PASS_VAULT}" || true

# ---------- 2) Vault RPC services ----------
if [[ -n "$GPG_VAULT" ]] && qvm-check -q "$GPG_VAULT"; then
  info "Checking GPG vault RPC handlers in ${GPG_VAULT}…"
  start_vm "$GPG_VAULT"
  for s in Sign Decrypt Encrypt Verify AdminImport AdminExport; do
    rin "$GPG_VAULT" "test -x /etc/qubes-rpc/gpg.${s}" \
      && pass "${GPG_VAULT}: /etc/qubes-rpc/gpg.${s} present" \
      || fail "${GPG_VAULT}: gpg.${s} missing or not executable"
  done
fi

# ---------- 3) Client wrappers in templates used by AppVMs ----------
if ((${#TEMPLATE_LIST[@]})); then
  info "Checking client-side wrappers in templates used by app VMs: ${TEMPLATE_LIST[*]}"
  for tpl in "${TEMPLATE_LIST[@]}"; do
    start_vm "$tpl"
    for w in /usr/local/bin/qgpg-sign /usr/local/bin/qgpg-decrypt /usr/local/bin/qgpg-encrypt /usr/local/bin/qgpg-verify; do
      rin "$tpl" "test -x $w" && pass "$tpl: $w present" || warn "$tpl: $w missing"
    done
    for w in /usr/local/bin/qgpg-import /usr/local/bin/qgpg-export; do
      rin "$tpl" "test -x $w" && pass "$tpl: $w present (admin)" || warn "$tpl: $w missing (admin wrappers optional)"
    done
  done
else
  warn "No app templates detected (tag 'layer_app' on your app VMs for auto-discovery)"
fi

# ---------- 4) Maintenance tag tool + live test ----------
TOOL="/usr/local/sbin/qubes-secrets-maint"
if [[ -x "$TOOL" ]]; then
  pass "Found maintenance tool: $TOOL"
  TEST_VM="$MAINT_VM"
  if [[ -z "$TEST_VM" ]]; then
    # pick first layer_app VM if any
    if ((${#APP_VMS[@]})); then TEST_VM="${APP_VMS[0]}"; fi
  fi
  if [[ -n "$TEST_VM" ]] && qvm-check -q "$TEST_VM"; then
    info "Maintenance tag live test on ${TEST_VM} (1m)…"
    before=$(qvm-tags "$TEST_VM" -l | tr '\n' ' ')
    sudo "$TOOL" add "$TEST_VM" 1m >/dev/null 2>&1 || true
    sleep 1
    if qvm-tags "$TEST_VM" -l | grep -q "gpg_admin_30m"; then
      pass "Tag gpg_admin_30m added to ${TEST_VM}"
      # cleanup immediately
      sudo "$TOOL" del "$TEST_VM" >/dev/null 2>&1 || true
      qvm-tags "$TEST_VM" -l | grep -q "gpg_admin_30m" && warn "Tag still present after del (investigate)" || pass "Tag removed successfully"
    else
      warn "Could not verify tag add (tool ran but tag not observed)"
    fi
  else
    warn "Skip maintenance tag live test (no --maint-vm provided and no layer_app VM found)"
  fi
else
  warn "Maintenance tool not found at $TOOL"
fi

# ---------- 5) qrexec audit logging ----------
info "Checking qrexec audit logging hook…"
if [[ -f /etc/rsyslog.d/40-qrexec-secrets.conf ]]; then
  pass "rsyslog rule present: /etc/rsyslog.d/40-qrexec-secrets.conf"
  systemctl is-active rsyslog >/dev/null 2>&1 && pass "rsyslog active" || warn "rsyslog not active"
  if [[ -f /var/log/qubes/audit-secrets.log ]]; then
    if [[ -s /var/log/qubes/audit-secrets.log ]]; then pass "audit-secrets.log exists (has entries)"; else warn "audit-secrets.log exists but empty (ok if no recent events)"; fi
  else
    warn "audit-secrets.log not created yet (will appear after first matching qrexec event)"
  fi
else
  warn "rsyslog audit hook missing (expected /etc/rsyslog.d/40-qrexec-secrets.conf)"
fi

# ---------- 6) OPSEC EXTRAS on Debian templates ----------
if ((${#OPSEC_TEMPLATES[@]})); then
  info "Checking OPSEC hygiene on Debian templates: ${OPSEC_TEMPLATES[*]}"
  for t in "${OPSEC_TEMPLATES[@]}"; do
    if ! qvm-check -q "$t"; then warn "$t not found (skip)"; continue; fi
    start_vm "$t"
    rin "$t" 'test -f /etc/systemd/journald.conf.d/00-volatile.conf && grep -q "Storage=volatile" /etc/systemd/journald.conf.d/00-volatile.conf' \
      && pass "$t: journald set to volatile" || warn "$t: journald volatile not confirmed"
    rin "$t" 'test -f /etc/systemd/coredump.conf.d/00-disable.conf && grep -q "Storage=none" /etc/systemd/coredump.conf.d/00-disable.conf' \
      && pass "$t: coredumps disabled" || warn "$t: coredump disable not confirmed"
    rin "$t" 'test -f /etc/profile.d/00-nohistory.sh && grep -q "HISTFILE=/dev/null" /etc/profile.d/00-nohistory.sh' \
      && pass "$t: shell history disabled" || warn "$t: shell history hardening missing"
    rin "$t" 'test -f /etc/sysctl.d/99-opsec-nodumps.conf' \
      && pass "$t: kernel dumpable off (sysctl file present)" || warn "$t: sysctl nodumps file missing"
    # UTC + locale
    rin "$t" 'test -L /etc/localtime && readlink /etc/localtime | grep -q "Etc/UTC"' \
      && pass "$t: timezone set to UTC" || warn "$t: timezone not confirmed UTC"
    rin "$t" 'locale -a 2>/dev/null | grep -q "en_US.utf8\|en_US.UTF-8"' \
      && pass "$t: en_US.UTF-8 locale present" || warn "$t: locale not confirmed"
    # random hostname
    rin "$t" 'systemctl is-enabled qubes-random-hostname.service >/dev/null 2>&1' \
      && pass "$t: random-hostname service enabled" || warn "$t: random-hostname service not enabled"
  done
else
  warn "No OPSEC templates provided (use --opsec-templates \"tpl1 tpl2 …\")"
fi

# ---------- 7) sys-net hygiene ----------
if qvm-check -q sys-net; then
  info "Checking sys-net hygiene…"
  start_vm sys-net
  rin sys-net 'test -f /etc/NetworkManager/conf.d/10-opsec-wifi.conf && grep -q "autoconnect=false" /etc/NetworkManager/conf.d/10-opsec-wifi.conf' \
    && pass "sys-net: NM autoconnect disabled" || warn "sys-net: autoconnect hardening missing"
  rin sys-net 'systemctl is-enabled bluetooth >/dev/null 2>&1 || true' \
    | grep -Eq 'disabled|masked|static' && pass "sys-net: bluetooth not enabled" || warn "sys-net: bluetooth appears enabled"
else
  warn "sys-net VM not found"
fi

# ---------- 8) dom0 power hygiene ----------
info "Checking dom0 sleep/hibernate masking…"
for u in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
  systemctl is-enabled "$u" 2>/dev/null | grep -qx "masked" \
    && pass "dom0: $u masked" || warn "dom0: $u not masked"
done

# ---------- Summary ----------
echo
if (( FAILS == 0 )); then
  echo -e "${GREEN}${BOLD}All critical secrets/policy/OPSEC checks passed.${NC}"
else
  echo -e "${RED}${BOLD}$FAILS critical check(s) failed.${NC}  Review messages above."
fi
exit $(( FAILS > 0 ))



