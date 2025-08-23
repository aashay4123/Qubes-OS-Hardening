{% from "osi_model_security/map.jinja" import cfg as CFG with context %}
{% set U = CFG.get('healthcheck_user_merge', {}) %}
{% set X = U.get('expect_templates', {}) %}
{% set RESOLVER = U.get('resolver', 'unbound') %}
{% set VPNVMS = U.get('vpn_vms', []) %}
{% set VPN_TOR = U.get('vpn_tor_gateway', '') %}
{% set WHONIX_WS = U.get('whonix_ws', []) %}
{% set APP_VMS = U.get('app_vms', []) %}
{% set GDEF = U.get('global_default_dispvm', '') %}
{% set PVDEF = U.get('per_vm_default_dispvm', {}) %}
{% set SUITE_TIMER = U.get('suite_timer','disable') %}
{% set C = U.get('checks', {}) %}

/etc/osi:
  file.directory: { - mode: '0755' }

/usr/local/sbin:
  file.directory: { - mode: '0755' }

/etc/osi/health.env:
  file.managed:
    - mode: '0644'
    - contents: |
        EXPECT_SYS_NET="{{ X.get('sys-net','') }}"
        EXPECT_SYS_FW="{{ X.get('sys-firewall','') }}"
        EXPECT_SYS_DNS="{{ X.get('sys-dns','') }}"
        EXPECT_APP_TPL="{{ X.get('app_default','') }}"
        RESOLVER="{{ RESOLVER }}"
        VPN_VMS="{{ ' '.join(VPNVMS) }}"
        VPN_TOR="{{ VPN_TOR }}"
        WHONIX_WS="{{ ' '.join(WHONIX_WS) }}"
        APP_VMS="{{ ' '.join(APP_VMS) }}"
        GLOBAL_DEFAULT_DISPVM="{{ GDEF }}"
        {% if PVDEF %}PER_VM_DEFAULTS="{{ ' '.join(['%s:%s'%(k,v) for k,v in PVDEF.items()]) }}"{% else %}PER_VM_DEFAULTS=""{% endif %}

        # deep check flags (1=on,0=off)
        CHECK_DNSMASQ={{ 1 if C.get('dnsmasq', True) else 0 }}
        CHECK_WHONIX_DNS_EXCL={{ 1 if C.get('whonix_dns_exclusion', True) else 0 }}
        CHECK_APPVM_FW_DROP={{ 1 if C.get('appvm_firewall_drop', True) else 0 }}
        CHECK_IDS={{ 1 if C.get('ids_suricata', True) else 0 }}
        CHECK_RESOLVER_LOGS={{ 1 if C.get('resolver_logs', True) else 0 }}
        CHECK_DEVICE_POLICIES={{ 1 if C.get('device_policies', True) else 0 }}
        CHECK_WHONIX_POLICY={{ 1 if C.get('whonix_policy_file', True) else 0 }}
        CHECK_OPENSSL={{ 1 if C.get('openssl_tls_policy', True) else 0 }}
        CHECK_CHRONY_NTS={{ 1 if C.get('chrony_nts', True) else 0 }}
        CHECK_SSH_CLIENT={{ 1 if C.get('ssh_client_hardening', True) else 0 }}
        CHECK_APPARMOR={{ 1 if C.get('apparmor_browsers', True) else 0 }}
        CHECK_VAULT_SRVS={{ 1 if C.get('vault_servers', True) else 0 }}
        CHECK_CLIENT_WRAPS={{ 1 if C.get('client_wrappers', True) else 0 }}
        CHECK_TAGS_SPLIT={{ 1 if C.get('tags_split_services', True) else 0 }}
        CHECK_UPDATEVM={{ 1 if C.get('updatevm_sys_firewall', True) else 0 }}
        CHECK_DVM_SPAWN={{ 1 if C.get('dvm_spawn_test', True) else 0 }}

/usr/local/bin/alert:
  file.managed:
    - mode: '0755'
    - contents: |
        #!/bin/bash
        set -euo pipefail
        vm="${ALERT_VM:-sys-alert}"
        msg="${*:-no message}"
        printf "%s" "$msg" | qrexec-client-vm "$vm" my.alert.Send || true

# ---------------- Net & Topology (deep) ----------------
/usr/local/sbin/osi-hc-net-topo.sh:
  file.managed:
    - mode: '0755'
    - contents: |
      #!/usr/bin/env bash
      set -euo pipefail
      . /etc/osi/health.env 2>/dev/null || true
      ok(){ echo -e "✅ $*"; }
      warn(){ echo -e "⚠️  $*"; }
      die(){ echo -e "❌ $*"; exit 1; }
      need(){ command -v "$1" >/dev/null || die "Missing $1 in dom0"; }
      for b in qvm-ls qvm-prefs qvm-run qvm-tags qvm-firewall; do need "$b"; done

      tmplt(){ qvm-prefs "$1" template 2>/dev/null | tr -d ' '; }
      pref(){ qvm-prefs "$1" "$2" 2>/dev/null | tr -d ' '; }
      has(){ qvm-ls --raw-list | grep -qx "$1"; }
      vm_ip(){ qvm-ls --raw-data --fields NAME,IP | awk -F'|' -v n="$1" '$1==n{gsub(/ /,"",$2);print $2}'; }

      echo "=== Core service VMs ==="
      for V in sys-net sys-firewall sys-dns; do has "$V" && ok "VM OK: $V" || die "Missing VM: $V"; done

      [[ -n "$EXPECT_SYS_NET"      ]] && [[ "$(tmplt sys-net)"      == "$EXPECT_SYS_NET"      ]] && ok "sys-net template ok"      || [[ -z "$EXPECT_SYS_NET"      ]] || die "sys-net template mismatch"
      [[ -n "$EXPECT_SYS_FW"       ]] && [[ "$(tmplt sys-firewall)" == "$EXPECT_SYS_FW"       ]] && ok "sys-firewall template ok" || [[ -z "$EXPECT_SYS_FW"       ]] || die "sys-firewall template mismatch"
      [[ -n "$EXPECT_SYS_DNS"      ]] && [[ "$(tmplt sys-dns)"      == "$EXPECT_SYS_DNS"      ]] && ok "sys-dns template ok"      || [[ -z "$EXPECT_SYS_DNS"      ]] || die "sys-dns template mismatch"

      [[ "$(pref sys-net netvm)" == "none" || "$(pref sys-net netvm)" == "None" ]] && ok "sys-net netvm = none" || die "sys-net must have netvm=None"
      [[ "$(pref sys-firewall netvm)" == "sys-net"    ]] && ok "sys-firewall → sys-net"  || die "sys-firewall must point to sys-net"
      [[ "$(pref sys-dns netvm)"      == "sys-firewall" ]] && ok "sys-dns → sys-firewall" || die "sys-dns must point to sys-firewall"

      echo "=== sys-firewall DNS guard ==="
      if qvm-run -q -u root --pass-io sys-firewall "nft list table ip nat | sed -n '/table ip nat/,/}/p' | grep -E 'dport (53).*(dnat to|redirect)'" >/dev/null 2>&1; then
        ok "NAT/redirect for DNS present"
      elif qvm-run -q -u root --pass-io sys-firewall "nft list ruleset | sed -n '/hook forward/,/}/p' | grep -E 'dport (53).*drop'" >/dev/null 2>&1; then
        ok "forward :53 drop present"
      else
        die "No DNS guard (neither DNAT nor drop) found in sys-firewall"
      fi
      qvm-run -q -u root --pass-io sys-firewall "nft list ruleset | grep -E 'dport 853.*(drop|reject)'" >/dev/null 2>&1 \
        && ok "DoT (853) blocked" || warn "No explicit DoT block (optional)"

      if [[ "${CHECK_DNSMASQ:-1}" -eq 1 ]]; then
        echo "=== sys-firewall dnsmasq ==="
        if qvm-run -q -u root --pass-io sys-firewall 'command -v dnsmasq >/dev/null; echo $?' | grep -qx 0; then
          ok "dnsmasq installed"
          st=$(qvm-run -q -u root --pass-io sys-firewall 'systemctl is-active dnsmasq || true')
          [[ "$st" == "active" ]] && ok "dnsmasq active" || warn "dnsmasq not active"
          qvm-run -q -u root --pass-io sys-firewall 'grep -q "log-queries" /etc/dnsmasq.d/99-logging.conf' >/dev/null && ok "dnsmasq logging configured" || warn "dnsmasq logging conf missing"
          qvm-run -q -u root --pass-io sys-firewall 'test -s /var/log/dnsmasq.log' >/dev/null && ok "dnsmasq log present" || warn "dnsmasq log missing/empty"
        else
          warn "dnsmasq not installed (ok if not in use)"
        fi
      fi

      echo "=== sys-dns resolver ==="
      if [[ "${RESOLVER:-unbound}" == "dnscrypt" ]]; then
        qvm-run -q -u root --pass-io sys-dns "systemctl is-active dnscrypt-proxy" | grep -qx active && ok "dnscrypt-proxy active" || die "dnscrypt-proxy must be active"
        qvm-run -q -u root --pass-io sys-dns "nft list ruleset | grep -E 'dport 53' | grep -E 'ip daddr != 127\\.0\\.0\\.1.*drop' -q" \
          && ok "sys-dns egress lock (only local)" || die "sys-dns must drop DNS not to 127.0.0.1"
        [[ "${CHECK_RESOLVER_LOGS:-1}" -eq 1 ]] && qvm-run -q -u root --pass-io sys-dns 'test -s /var/log/dnscrypt-proxy/dnscrypt-proxy.log' >/dev/null && ok "dnscrypt log present" || true
      else
        qvm-run -q -u root --pass-io sys-dns "systemctl is-active unbound" | grep -qx active && ok "unbound active" || die "unbound must be active"
        qvm-run -q -u root --pass-io sys-dns "unbound-checkconf /etc/unbound/unbound.conf >/dev/null 2>&1" && ok "unbound config valid" || die "unbound config invalid"
        if [[ "${CHECK_RESOLVER_LOGS:-1}" -eq 1 ]]; then
          qvm-run -q -u root --pass-io sys-dns 'grep -q "^log-queries: *yes" /etc/unbound/unbound.conf' >/dev/null && ok "unbound query logging enabled" || warn "unbound logging not enabled"
          qvm-run -q -u root --pass-io sys-dns 'test -s /var/log/unbound/unbound.log' >/dev/null && ok "unbound log present" || warn "unbound log missing/empty"
        fi
      fi

      echo "=== VPN VMs ==="
      for VPN in ${VPN_VMS:-}; do
        has "$VPN" || { warn "VPN VM missing: $VPN"; continue; }
        [[ "$(pref "$VPN" netvm)" == "sys-firewall" ]] && ok "$VPN → sys-firewall" || die "$VPN must point to sys-firewall"
        if [[ "${RESOLVER:-unbound}" == "dnscrypt" ]]; then
          st=$(qvm-run -q -u root --pass-io "$VPN" "systemctl is-active dnscrypt-proxy || true")
          [[ "$st" != "active" ]] && ok "$VPN has no dnscrypt" || die "$VPN must NOT run dnscrypt"
        endfi
      done

      if [[ "${CHECK_WHONIX_DNS_EXCL:-1}" -eq 1 ]] && [[ -n "${VPN_TOR:-}" ]] && has "$VPN_TOR"; then
        ip=$(vm_ip "$VPN_TOR"); [[ -n "$ip" ]] || die "Cannot get $VPN_TOR IP"
        qvm-run -q -u root --pass-io sys-firewall \
          "nft list table ip nat | sed -n '/prerouting/,/}/p' | grep -E 'ip saddr ${ip}.*dport 53.*accept'" >/dev/null \
          && ok "DNS NAT exclusion for $VPN_TOR present" || warn "Whonix DNS exclusion not found"
      fi
      [[ "${CHECK_WHONIX_POLICY:-1}" -eq 1 ]] && [[ -f /etc/qubes/policy.d/50-whonix-vpn-tor.policy ]] && ok "50-whonix-vpn-tor.policy present" || true

      if [[ "${CHECK_APPVM_FW_DROP:-1}" -eq 1 ]]; then
        echo "=== AppVM firewalls (default drop) ==="
        for V in ${APP_VMS:-}; do
          qvm-check -q "$V" || { warn "$V missing"; continue; }
          if qvm-firewall "$V" list 2>/dev/null | grep -Eiq 'default.*drop|policy.*drop'; then ok "$V: default drop detected"; else warn "$V: default drop NOT detected"; fi
        done
      fi

      echo -e "\n🎉 Net/Topology deep checks done."

# -------------- Secrets + OPSEC (deep) --------------
/usr/local/sbin/osi-hc-secrets-opsec.sh:
  file.managed:
    - mode: '0755'
    - contents: |
      #!/usr/bin/env bash
      set -euo pipefail
      . /etc/osi/health.env 2>/dev/null || true
      ok(){ echo -e "✅ $*"; }
      warn(){ echo -e "⚠️  $*"; }
      fail(){ echo -e "❌ $*"; ((F++)); }
      F=0
      for c in qvm-ls qvm-prefs qvm-run qvm-start qvm-check qvm-tags systemctl; do command -v "$c" >/dev/null || { echo "Missing $c"; exit 3; }; done

      # Device policies
      if [[ "${CHECK_DEVICE_POLICIES:-1}" -eq 1 ]]; then
        echo "=== Device policies ==="
        [[ -f /etc/qubes/policy.d/30-usb-core.policy || -f /etc/qubes/policy.d/30-usb.policy ]] && ok "USB policy present" || fail "USB policy missing"
        [[ -f /etc/qubes/policy.d/31-usb-input.policy || -f /etc/qubes/policy.d/30-input.policy ]] && ok "Input policy present" || fail "Input policy missing"
        [[ -f /etc/qubes/policy.d/30-pci.policy ]] && ok "PCI policy present" || warn "30-pci.policy missing"
      fi

      # UpdateVM
      if [[ "${CHECK_UPDATEVM:-1}" -eq 1 ]]; then
        uv=$(qubes-prefs updatevm || true)
        [[ "$uv" == "sys-firewall" ]] && ok "dom0 updatevm=sys-firewall" || warn "updatevm='$uv' (recommend sys-firewall)"
      fi

      # OpenSSL / Crypto policy
      if [[ "${CHECK_OPENSSL:-1}" -eq 1 || "${CHECK_SSH_CLIENT:-1}" -eq 1 || "${CHECK_CHRONY_NTS:-1}" -eq 1 || "${CHECK_APPARMOR:-1}" -eq 1 ]]; then
        declare -A TPLS=()
        for vm in sys-net sys-dns sys-firewall ${APP_VMS}; do qvm-check -q "$vm" || continue; t=$(qvm-prefs -g "$vm" template 2>/dev/null || true); [[ -n "$t" ]] && TPLS["$t"]=1; done
        for tpl in "${!TPLS[@]}"; do
          # Debian vs Fedora detection
          if qvm-run -q -u root --pass-io "$tpl" 'command -v apt-get >/dev/null; echo $?' | grep -qx 0; then deb=1; else deb=0; fi
          if [[ "${CHECK_OPENSSL:-1}" -eq 1 ]]; then
            if (( deb )); then
              qvm-run -q -u root --pass-io "$tpl" 'test -f /etc/ssl/openssl.cnf.d/40-system-policy.cnf && grep -q "MinProtocol *= *TLSv1.2" /etc/ssl/openssl.cnf.d/40-system-policy.cnf' >/dev/null \
                && ok "$tpl: OpenSSL MinProtocol>=TLS1.2" || warn "$tpl: OpenSSL MinProtocol not confirmed"
            else
              pol=$(qvm-run -q -u root --pass-io "$tpl" 'update-crypto-policies --show 2>/dev/null || echo ""')
              [[ "$pol" =~ ^(FUTURE|DEFAULT)$ ]] && ok "$tpl: crypto-policy $pol" || warn "$tpl: crypto-policy unknown"
            fi
          fi
          if [[ "${CHECK_CHRONY_NTS:-1}" -eq 1 ]]; then
            if (( deb )); then
              qvm-run -q -u root --pass-io "$tpl" 'systemctl is-active chrony >/dev/null 2>&1' >/dev/null && ok "$tpl: chrony active" || warn "$tpl: chrony not active"
              qvm-run -q -u root --pass-io "$tpl" 'grep -q "nts" /etc/chrony/chrony.conf' >/dev/null && ok "$tpl: NTS hinted" || warn "$tpl: NTS not found"
            else
              qvm-run -q -u root --pass-io "$tpl" 'systemctl is-active chronyd >/dev/null 2>&1' >/dev/null && ok "$tpl: chronyd active" || warn "$tpl: chronyd not active"
              qvm-run -q -u root --pass-io "$tpl" 'grep -q "nts" /etc/chrony.conf' >/dev/null && ok "$tpl: NTS hinted" || warn "$tpl: NTS not found"
            fi
          fi
          if [[ "${CHECK_SSH_CLIENT:-1}" -eq 1 ]]; then
            qvm-run -q -u root --pass-io "$tpl" 'test -f /etc/ssh/ssh_config.d/40-hardening.conf || test -f /etc/ssh/ssh_config.d/99-osi.conf' >/dev/null \
              && ok "$tpl: SSH client hardening present" || warn "$tpl: SSH client hardening missing"
          fi
          if [[ "${CHECK_APPARMOR:-1}" -eq 1 ]]; then
            qvm-run -q -u root --pass-io "$tpl" 'aa-status 2>/dev/null | egrep -q "(firefox|chromium).*enforce"' \
              && ok "$tpl: AppArmor enforced for browsers" || warn "$tpl: AppArmor not enforced for browsers"
          fi
        done
      fi

      # Vault servers & client wrappers & tags
      if [[ "${CHECK_VAULT_SRVS:-1}" -eq 1 || "${CHECK_CLIENT_WRAPS:-1}" -eq 1 || "${CHECK_TAGS_SPLIT:-1}" -eq 1 ]]; then
        for v in vault-gpg vault-ssh vault-pass vault-secrets; do
          qvm-check -q "$v" || continue
          if [[ "${CHECK_VAULT_SRVS:-1}" -eq 1 ]]; then
            for s in gpg.Sign gpg.Decrypt gpg.Encrypt gpg.Verify; do qvm-run -q -u root --pass-io "$v" "test -x /etc/qubes-rpc/${s}" >/dev/null && ok "$v: ${s} present" || warn "$v: ${s} missing"; done
            qvm-run -q -u root --pass-io "$v" "test -x /etc/qubes-rpc/qubes.SshAgent" >/dev/null && ok "$v: Split-SSH service" || warn "$v: Split-SSH service missing"
            qvm-run -q -u root --pass-io "$v" "test -x /etc/qubes-rpc/qubes.PassLookup" >/dev/null && ok "$v: qubes-pass service" || true
          fi
        done
        if [[ "${CHECK_CLIENT_WRAPS:-1}" -eq 1 ]]; then
          declare -A APPTPL=(); while read -r av; do [[ -z "$av" ]] && continue; t=$(qvm-prefs -g "$av" template 2>/dev/null || true); [[ -n "$t" ]] && APPTPL["$t"]=1; done < <(printf "%s\n" ${APP_VMS})
          for t in "${!APPTPL[@]}"; do
            qvm-run -q -u root --pass-io "$t" 'command -v qpass >/dev/null' && ok "$t: qpass present" || warn "$t: qpass missing"
            for w in qgpg-sign qgpg-decrypt qgpg-encrypt qgpg-verify; do qvm-run -q -u root --pass-io "$t" "command -v $w >/dev/null" && ok "$t: $w present" || warn "$t: $w missing"; done
          done
        fi
        if [[ "${CHECK_TAGS_SPLIT:-1}" -eq 1 ]]; then
          for vm in ${APP_VMS}; do
            qvm-check -q "$vm" || continue
            qvm-tags "$vm" -l | grep -q split-gpg || warn "tag split-gpg missing on $vm"
            qvm-tags "$vm" -l | grep -q split-ssh || warn "tag split-ssh missing on $vm"
            qvm-tags "$vm" -l | grep -q split-pass || warn "tag split-pass missing on $vm"
          done
        fi
      fi

      # sys-net hygiene & dom0 sleep masks (as before)
      qvm-check -q sys-net && qvm-run -q -u root --pass-io sys-net 'test -f /etc/NetworkManager/conf.d/10-opsec-wifi.conf && grep -q "autoconnect=false" /etc/NetworkManager/conf.d/10-opsec-wifi.conf' >/dev/null && ok "sys-net: NM autoconnect disabled" || warn "sys-net: autoconnect hardening missing"
      for u in sleep.target suspend.target hibernate.target hybrid-sleep.target; do systemctl is-enabled "$u" 2>/dev/null | grep -qx masked && ok "dom0: $u masked" || warn "dom0: $u not masked"; done

      if ((F==0)); then ok "Secrets/OPSEC deep checks passed"; else echo "❌ $F failure(s)"; exit 2; fi

# -------------- Disposables --------------
/usr/local/sbin/osi-hc-dispvm.sh:
  file.managed:
    - mode: '0755'
    - contents: |
      #!/usr/bin/env bash
      set -euo pipefail
      . /etc/osi/health.env 2>/dev/null || true
      ok(){ echo -e "✅ $*"; }
      warn(){ echo -e "⚠️  $*"; }
      fail(){ echo -e "❌ $*"; ((F++)); }
      F=0
      for c in qvm-ls qvm-prefs qvm-run; do command -v "$c" >/dev/null || { echo "Missing $c"; exit 3; }; done

      mapfile -t DVM_TEMPLATES < <(qvm-ls --raw-list | while read -r v; do [[ -z "$v" ]] && continue; [[ "$(qvm-prefs -g "$v" template_for_dispvms 2>/dev/null || echo false)" == "True" ]] && echo "$v"; done)
      ((${#DVM_TEMPLATES[@]})) && ok "DVM templates: ${DVM_TEMPLATES[*]}" || warn "No DVM templates detected"

      if [[ -n "${GLOBAL_DEFAULT_DISPVM:-}" ]]; then cur=$(qubes-prefs -g default_dispvm 2>/dev/null || echo ""); [[ "$cur" == "$GLOBAL_DEFAULT_DISPVM" ]] && ok "global default_dispvm=$cur" || warn "global default_dispvm='$cur' (want $GLOBAL_DEFAULT_DISPVM)"; fi
      if [[ -n "${PER_VM_DEFAULTS:-}" ]]; then for pair in ${PER_VM_DEFAULTS}; do vm="${pair%%:*}"; disp="${pair#*:}"; cur=$(qvm-prefs -g "$vm" default_dispvm 2>/dev/null || echo ""); [[ "$cur" == "$disp" ]] && ok "$vm default_dispvm=$disp" || warn "$vm default_dispvm='$cur' (want '$disp')"; done; fi

      for P in /etc/qubes/policy.d/33-dispvm-openurl.policy /etc/qubes/policy.d/34-dispvm-openinvm.policy; do [[ -f "$P" ]] && ok "policy present: $(basename "$P")" || warn "missing policy: $(basename "$P")"; done

      if [[ "${CHECK_DVM_SPAWN:-1}" -eq 1 ]]; then
        for d in ${GLOBAL_DEFAULT_DISPVM:-} ${DVM_TEMPLATES[@]}; do
          [[ -z "$d" ]] && continue
          echo "→ Spawning disposable from '$d'…"
          if qvm-run --pass-io --dispvm="$d" 'true' >/dev/null 2>&1; then ok "spawn OK: $d"; else fail "spawn FAILED: $d"; fi
        done
      fi

      ((F==0)) && { ok "Disposable checks passed"; exit 0; } || { echo "❌ $F failure(s)"; exit 2; }

# -------------- Suite wrapper + service/timer --------------
/usr/local/sbin/osi-health-suite:
  file.managed:
    - mode: '0755'
    - contents: |
      #!/usr/bin/env bash
      set -euo pipefail
      LOGDIR=/var/log/osi/health; mkdir -p "$LOGDIR"
      R="$LOGDIR/suite-$(date +%Y%m%d-%H%M%S).log"
      FAIL=0
      {
        echo "== OSI Health Suite =="; date -Is
        /usr/local/sbin/osi-hc-net-topo.sh       || FAIL=1
        /usr/local/sbin/osi-hc-secrets-opsec.sh  || FAIL=1
        /usr/local/sbin/osi-hc-dispvm.sh         || FAIL=1
        echo "== DONE =="
      } | tee -a "$R"
      if ((FAIL)); then
        printf "OSI suite FAIL. See %s\n" "$(basename "$R")" | /usr/local/bin/alert || true
        exit 2
      fi

/etc/systemd/system/osi-health-suite.service:
  file.managed:
    - mode: '0644'
    - contents: |
      [Unit]
      Description=Run merged OSI health suite
      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/osi-health-suite

{% if SUITE_TIMER != 'disable' %}
/etc/systemd/system/osi-health-suite.timer:
  file.managed:
    - mode: '0644'
    - contents: |
      [Unit]
      Description=Schedule OSI health suite
      [Timer]
      OnCalendar={{ SUITE_TIMER }}
      Persistent=true
      [Install]
      WantedBy=timers.target

osi-health-suite-enable:
  cmd.run:
    - name: |
        systemctl daemon-reload
        systemctl enable --now osi-health-suite.timer
{% else %}
osi-health-suite-noenable:
  cmd.run:
    - name: systemctl daemon-reload
{% endif %}
