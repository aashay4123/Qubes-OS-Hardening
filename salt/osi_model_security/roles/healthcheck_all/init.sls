{% from "osi_model_security/map.jinja" import cfg with context %}
{% set I = cfg.get('integrity_alerts', {}) %}
{% set T = cfg.get('net_topology', {}) %}
{% set timer_when = I.get('timers', {}).get('all_in_one', 'hourly') %}
{% set alert_vm = I.get('alert_vm', 'sys-alert') %}

/usr/local/sbin/osi-all-healthcheck:
  file.managed:
    - mode: '0755'
    - contents: |
        #!/usr/bin/env bash
        # Qubes OS — All-in-one OSI/Net/Devices/Secrets/Integrity healthcheck
        set -euo pipefail
        RED="$(printf '\033[31m')"; GRN="$(printf '\033[32m')"; YLW="$(printf '\033[33m')"; B="$(printf '\033[1m')"; NC="$(printf '\033[0m')"
        pass(){ echo -e "${GRN}✔${NC} $*"; }
        warn(){ echo -e "${YLW}⚠${NC} $*"; }
        fail(){ echo -e "${RED}✘${NC} $*"; ((FAILS++)); }
        say(){ echo -e "${B}→${NC} $*"; }

        FAILS=0
        ALERT_VM="{{ alert_vm }}"
        ALERT=/usr/local/bin/alert
        LOGDIR=/var/log/osi/health; mkdir -p "$LOGDIR"
        REPORT="$LOGDIR/all-$(date +%Y%m%d-%H%M%S).log"
        exec > >(tee -a "$REPORT") 2>&1

        # ---------- A) Topology & chain wiring ----------
        say "Topology and NetVM chain…"
        # Discover active chain hops by tag topology_* and follow netvm edges back from sys-net
        mapfile -t TAGGED < <(for v in $(qvm-ls --raw-list); do qvm-tags "$v" -l 2>/dev/null | grep -q '^topology_' && echo "$v"; done)
        if ((${#TAGGED[@]}==0)); then warn "No topology_* tags found (ok if role not applied)"; else
          # Build reverse chain from sys-net
          CHAIN_REV=(); CUR="sys-net"; VISITED=""
          while :; do
            FOUND=""
            for v in "${TAGGED[@]}"; do
              nv=$(qvm-prefs -g "$v" netvm 2>/dev/null || true)
              [[ "$nv" == "$CUR" ]] && [[ ! " $VISITED " =~ " $v " ]] && { FOUND="$v"; break; }
            done
            [[ -z "$FOUND" ]] && break
            CHAIN_REV+=("$FOUND"); VISITED="$VISITED $FOUND"; CUR="$FOUND"
          done
          if ((${#CHAIN_REV[@]})); then
            CHAIN=(); for ((i=${#CHAIN_REV[@]}-1;i>=0;i--)); { CHAIN+=("${CHAIN_REV[i]}"); }
            pass "Active chain (app→…→sys-net): ${CHAIN[*]}"
            # NetVM pointers
            OK=1
            PREV="sys-net"
            for ((i=${#CHAIN[@]}-1;i>=0;i--)); do v="${CHAIN[i]}"; nv=$(qvm-prefs -g "$v" netvm 2>/dev/null || true)
              if [[ "$nv" == "$PREV" ]]; then pass "$v netvm=$nv"; else fail "$v netvm=$nv (expected $PREV)"; OK=0; fi; PREV="$v"
            done
            # AppVM spot-checks (best-effort)
            for app in work-web dev; do
              qvm-check -q "$app" || continue
              fh="${CHAIN[0]:-sys-net}"; av=$(qvm-prefs -g "$app" netvm 2>/dev/null || true)
              [[ "$av" == "$fh" ]] && pass "$app netvm=$av" || warn "$app netvm=$av (expected $fh)"
            done
          else
            warn "Could not derive chain from tags; check topology role"
          fi
        fi

        # ---------- B) Net guard / nftables presence ----------
        say "nftables guard tables…"
        check_nft(){
          local vm="$1"; shift; local patt=("$@")
          qvm-check -q "$vm" || { warn "$vm missing"; return; }
          qvm-run --pass-io "$vm" 'nft list ruleset' 2>/dev/null | grep -E -q "$(IFS='|'; echo "${patt[*]}")" \
            && pass "$vm: nft guard present" || fail "$vm: nft guard rules missing (${patt[*]})"
        }
        check_nft sys-firewall "table inet guard_fw" "table inet osi_firewall"
        check_nft sys-dns      "table inet guard_dns" "table inet osi_dns"
        check_nft sys-vpn      "table inet guard_vpn" "table inet osi_vpn"
        check_nft sys-net      "table inet osi_sysnet"

        # ---------- C) Device hardening (USB, input, mic) ----------
        say "Device hardening…"
        if [[ -x /usr/local/sbin/verify_device_hardening ]]; then
          /usr/local/sbin/verify_device_hardening || fail "verify_device_hardening failed"
        else
          warn "verify_device_hardening not installed"
        fi

        # ---------- D) Secrets + OPSEC (Split-GPG/SSH/pass, wrappers, OPSEC hygiene) ----------
        say "Secrets & OPSEC…"
        if [[ -x /usr/local/sbin/osi-secrets-opsec-check.sh ]]; then
          /usr/local/sbin/osi-secrets-opsec-check.sh || fail "osi-secrets-opsec-check failed"
        elif [[ -x ~/osi-secrets-opsec-check.sh ]]; then
          sudo -n ~/osi-secrets-opsec-check.sh || fail "osi-secrets-opsec-check (home) failed"
        else
          warn "osi-secrets-opsec-check not found"
        fi

        # ---------- E) Integrity & alerts (Salt/policy/templates/boot/TPM) ----------
        say "Integrity & Alerts…"
        if [[ -x /usr/local/sbin/verify_security_integrity ]]; then
          /usr/local/sbin/verify_security_integrity || fail "verify_security_integrity failed"
        else
          warn "verify_security_integrity not installed"
        fi

        # ---------- Summary ----------
        echo
        if ((FAILS==0)); then
          pass "ALL CHECKS PASSED"
          exit 0
        else
          echo -e "${RED}${B}FAILURES: $FAILS${NC}"
          SHORT="ALL-HC FAIL ($FAILS). See $(basename "$REPORT")."
          if [[ -x "$ALERT" ]]; then printf "%s" "$SHORT" | "$ALERT" || true; fi
          exit 2
        fi

# one-shot service + timer (optional)
#/etc/systemd/system/osi-all-healthcheck.service and .timer
/etc/systemd/system/osi-all-healthcheck.service:
  file.managed:
    - mode: '0644'
    - contents: |
        [Unit]
        Description=All-in-one OSI/Qubes healthcheck
        [Service]
        Type=oneshot
        ExecStart=/usr/local/sbin/osi-all-healthcheck

/etc/systemd/system/osi-all-healthcheck.timer:
  file.managed:
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Schedule: All-in-one OSI/Qubes healthcheck
        [Timer]
        OnCalendar={{ timer_when }}
        Persistent=true
        [Install]
        WantedBy=timers.target

osi-all-healthcheck-enable:
  cmd.run:
    - name: |
        systemctl daemon-reload
        systemctl enable --now osi-all-healthcheck.timer
