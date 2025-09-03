# 1) install the unified helper (auto-sourced for new shells)
sudo tee /etc/profile.d/qubes-funcs.sh >/dev/null <<'EOF'
# Qubes batch helpers + health/forensics + fzf TUI (single file)
# Place: /etc/profile.d/qubes-funcs.sh   (auto-sourced for interactive shells)

set -u

# ===== internals =====
_qf_err(){ printf "ERROR: %s\n" "$*" >&2; return 1; }
_qf_has(){ command -v "$1" >/dev/null 2>&1; }
_qf_templates(){ qvm-ls --raw-data | awk -F'|' 'NR>1 && $2=="TemplateVM"{print $1}' | sort; }
_qf_netvms(){ qvm-ls --raw-data | awk -F'|' 'NR>1 && $2=="AppVM" && $9=="True"{print $1}' | sort; } # provides_network=True
_qf_vms(){ qvm-ls --raw-list | sort; }
_qf_by_label(){ L="$1"; qvm-ls --raw-data | awk -F'|' -v L="$L" 'NR>1 && $7==L{print $1}' | sort; }
_qf_by_template(){ T="$1"; for v in $(qvm-ls --raw-list); do [ "$(qvm-prefs -g "$v" template 2>/dev/null || true)" = "$T" ] && echo "$v"; done }
_qf_by_netvm(){ N="$1"; for v in $(qvm-ls --raw-list); do [ "$(qvm-prefs -g "$v" netvm 2>/dev/null || true)" = "$N" ] && echo "$v"; done }
_qf_today(){ date -I; }
_qf_outdir(){ D="/var/lib/qubes/reports/$(_qf_today)"; mkdir -p "$D"; printf "%s" "$D"; }
_qf_bar(){ # usage: _qf_bar PCT
  P=${1:-0}; [ "$P" -gt 100 ] && P=100; B=$((P/4)); printf "%3d%% [" "$P"; for i in $(seq 1 $B); do printf "█"; done; for i in $(seq $((B+1)) 25); do printf " "; done; printf "]"; }

# print short hint once per shell
if [ -z "${QF_HINT_SHOWN-}" ]; then export QF_HINT_SHOWN=1; echo "[qubes-funcs] loaded. run: qf_help or qf_tui"; fi

# ===== help =====
qf_help(){
cat <<'HLP'
Qubes batch helper library (dom0) — loop-first ops + health

Inventory & topology:
  rep_inventory            # CSV of VM,class,template,state,label
  rep_topology             # CSV of VM,netvm,upstream
  rep_net_clients          # per NetVM, list client VMs (markdown)
  rep_autostart            # CSV of autostart flags
  rep_policy_grep [PAT]    # grep 4.2 policy.d (default: qubes.)
  rep_usb                  # usb list + usb policy grep

Templates (bulk):
  tmpl_update_all          # apt/dnf upgrade in all templates
  tmpl_pkglist_all         # per-template package list files
  tmpl_enabled_all         # enabled services per template
  tmpl_ports_all           # listening sockets per template
  tmpl_diff_services A B   # diff enabled services between two templates
  tmpl_rebase_all OLD NEW  # retarget *all* VMs using OLD -> NEW

Networking (bulk):
  net_fw_dump_all          # qvm-firewall list for every NetVM
  net_nft_check_all        # inet qubes table present? (each NetVM)
  net_route_all            # default route summary for every VM
  dns_stub_check_all       # resolv.conf uses Qubes stub?
  icmp_test_all            # ping quick test from all running app VMs

Batch selectors & actions:
  vms_by_label LBL         # list VMs with label
  vms_by_template TPL      # list VMs using template
  vms_by_netvm NET         # list VMs chained to NET
  set_netvm_by_label LBL NET
  set_template_by_label LBL TPL
  start_group   selector   # selector: label:<L> | template:<T> | netvm:<N>
  shutdown_group selector
  restart_group selector
  sync_menus_all

Ops & health:
  core_health              # dom0 services + key sys-VMs state
  pool_usage               # LVM thin pool usage
  rep_vm_disk              # per-VM volumes info
  timers_in_all            # timers for templates + sys VMs

DNS/VPN quick checks:
  sysdns_status            # :53 sockets + nft table in sys-dns
  vpn_status               # tun + default route in sys-vpn
  vpn_killswitch_check     # nft killswitch references tun

Audit / Monitoring tie-ins:
  leaks_today              # pretty-print last leakcheck CSV
  integrity_today          # pretty-print last integrity diffs
  ship_metrics_now         # trigger monitor backup + integrity diff
  rep_firewall_all         # overview of rules & clients (markdown)

=== 10 extra health/forensics gems ===
  rep_dom0_snapshots       # list LVM snapshots related to dom0
  take_dom0_snapshot [SZ]  # create dom0 root snapshot (default size 1G)
  compare_dom0_baseline    # shasum /etc & /boot vs stored baseline
  baseline_dom0_now        # (re)create dom0 baseline (hashes)
  vm_cpu_monitor_panel     # per-VM CPU usage bars (xentop)
  monitor_domU_xentop      # CSV export of CPU/MEM for domUs (xentop)
  qrexec_recent            # last lines from qrexec logs (dom0)
  net_widget_seed_sysnet   # drop a tiny net-usage script into sys-net
  check_qvm_template_deps  # templates missing qubes-repo-templates
  policy_matrix SERVICE    # summarize effective rules for a qrexec svc

UI:
  qf_tui                   # fzf-powered picker (fallback to basic menu)

HLP
}

# ===== Inventory & topology =====
rep_inventory(){
  OUT="$(_qf_outdir)/inventory.csv"
  echo "vm,class,template,state,label" > "$OUT"
  qvm-ls --raw-data | awk -F'|' 'NR>1{printf "%s,%s,%s,%s,%s\n",$1,$2,$5,$8,$7}' >> "$OUT"
  echo "=> $OUT"
}
rep_topology(){
  OUT="$(_qf_outdir)/topology.csv"
  echo "vm,netvm,upstream" > "$OUT"
  for vm in $(_qf_vms); do
    netvm=$(qvm-prefs -g "$vm" netvm 2>/dev/null || echo "")
    up=""; [ -n "$netvm" ] && up=$(qvm-prefs -g "$netvm" netvm 2>/dev/null || true)
    printf "%s,%s,%s\n" "$vm" "${netvm:-}" "${up:-}" >> "$OUT"
  done
  echo "=> $OUT"
}
rep_net_clients(){
  OUT="$(_qf_outdir)/netvm_clients.md"; : > "$OUT"
  for n in $(_qf_netvms); do
    echo "### $n" >> "$OUT"
    for vm in $(_qf_by_netvm "$n"); do echo "- $vm" >> "$OUT"; done
    echo >> "$OUT"
  done
  echo "=> $OUT"
}
rep_autostart(){
  OUT="$(_qf_outdir)/autostart.csv"; echo "vm,autostart" > "$OUT"
  for vm in $(_qf_vms); do a=$(qvm-prefs -g "$vm" autostart 2>/dev/null || echo "n/a"); echo "$vm,$a" >> "$OUT"; done
  echo "=> $OUT"
}
rep_policy_grep(){ PAT="${1:-qubes.}"; OUT="$(_qf_outdir)/policy-grep.txt"; grep -Hn "$PAT" /etc/qubes/policy.d/*.policy 2>/dev/null > "$OUT" || echo "(no matches)" > "$OUT"; echo "=> $OUT"; }
rep_usb(){
  OUTD="$(_qf_outdir)"; qvm-device usb list > "$OUTD/usb-list.txt" 2>/dev/null || true
  grep -Hn "usb" /etc/qubes/policy.d/*.policy 2>/dev/null > "$OUTD/usb-policy.txt" || echo "(no usb lines)" > "$OUTD/usb-policy.txt"
  echo "=> $OUTD/usb-list.txt"; echo "=> $OUTD/usb-policy.txt"
}

# ===== Templates (bulk) =====
tmpl_update_all(){
  for t in $(_qf_templates); do
    echo "== $t =="
    if qvm-run -p -u root "$t" 'test -r /etc/debian_version'; then
      qvm-run -p -u root "$t" 'DEBIAN_FRONTEND=noninteractive apt-get update && apt-get -y dist-upgrade'
    else
      qvm-run -p -u root "$t" 'dnf -y --refresh upgrade'
    fi
  done
}
tmpl_pkglist_all(){
  OUTD="$(_qf_outdir)/pkglists"; mkdir -p "$OUTD"
  for t in $(_qf_templates); do
    if qvm-run -p -u root "$t" 'test -r /etc/debian_version' 2>/dev/null; then
      qvm-run -p -u root "$t" 'dpkg-query -W -f=${binary:Package}\n | sort' > "$OUTD/$t.txt" || true
    else
      qvm-run -p -u root "$t" 'rpm -qa --qf "%{NAME}\n" | sort' > "$OUTD/$t.txt" || true
    fi
    echo "-> $OUTD/$t.txt"
  done
}
tmpl_enabled_all(){ OUTD="$(_qf_outdir)/enabled-services"; mkdir -p "$OUTD"; for t in $(_qf_templates); do qvm-run -p -u root "$t" 'systemctl list-unit-files --type=service --state=enabled --no-pager' > "$OUTD/$t.txt" || true; echo "-> $OUTD/$t.txt"; done; }
tmpl_ports_all(){ OUTD="$(_qf_outdir)/open-ports"; mkdir -p "$OUTD"; for t in $(_qf_templates); do qvm-run -p -u root "$t" 'ss -H -ltnup || netstat -ltnup' > "$OUTD/$t.txt" || true; echo "-> $OUTD/$t.txt"; done; }
tmpl_diff_services(){
  A="${1:-}"; B="${2:-}"; [ -n "$A" ] && [ -n "$B" ] || { _qf_err "usage: tmpl_diff_services <A> <B>"; return 2; }
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  qvm-run -p -u root "$A" 'systemctl list-unit-files --type=service --state=enabled --no-pager | awk "NR>1{print \$1}"' | sort >"$tmp/a"
  qvm-run -p -u root "$B" 'systemctl list-unit-files --type=service --state=enabled --no-pager | awk "NR>1{print \$1}"' | sort >"$tmp/b"
  echo "## Enabled in $A only:"; comm -23 "$tmp/a" "$tmp/b"; echo; echo "## Enabled in $B only:"; comm -13 "$tmp/a" "$tmp/b"
}
tmpl_rebase_all(){ OLD="${1:-}"; NEW="${2:-}"; [ -n "$OLD" ] && [ -n "$NEW" ] || { _qf_err "usage: tmpl_rebase_all <OLD> <NEW>"; return 2; }
  for vm in $(_qf_vms); do [ "$(qvm-prefs -g "$vm" template 2>/dev/null || true)" = "$OLD" ] && { qvm-prefs "$vm" template "$NEW"; echo "$vm -> $NEW"; }; done; }

# ===== Networking (bulk) =====
net_fw_dump_all(){ OUTD="$(_qf_outdir)/firewall"; mkdir -p "$OUTD"; for n in $(_qf_netvms); do qvm-firewall "$n" list > "$OUTD/$n.txt" || true; echo "-> $OUTD/$n.txt"; done; }
net_nft_check_all(){ OUT="$(_qf_outdir)/nft-inet-qubes.csv"; echo "netvm,has_table_inet_qubes" > "$OUT"; for n in $(_qf_netvms); do RES=$(qvm-run -p "$n" 'nft list ruleset | grep -q "table inet qubes" && echo yes || echo no' || echo "no"); echo "$n,$RES" >> "$OUT"; done; echo "=> $OUT"; }
net_route_all(){ OUT="$(_qf_outdir)/routes.csv"; echo "vm,egress_dev,via" > "$OUT"; for v in $(_qf_vms); do LINE=$(qvm-run -p "$v" 'ip route get 1.1.1.1 2>/dev/null | sed -n "s/.* via \\([^ ]*\\) dev \\([^ ]*\\).*/\\2,\\1/p"' 2>/dev/null || true); [ -n "$LINE" ] && echo "$v,$LINE" >> "$OUT" || echo "$v,," >> "$OUT"; done; echo "=> $OUT"; }
dns_stub_check_all(){ OUT="$(_qf_outdir)/dns-stub.csv"; echo "vm,has_qubes_stub" > "$OUT"; for v in $(_qf_vms); do if qvm-prefs -g "$v" provides_network >/dev/null 2>&1; then prov=$(qvm-prefs -g "$v" provides_network || echo False); [ "$prov" = "True" ] && continue; fi; RES=$(qvm-run -p "$v" 'grep -Eq "10\\.139\\.|10\\.137\\." /etc/resolv.conf && echo yes || echo no' 2>/dev/null || echo "no"); echo "$v,$RES" >> "$OUT"; done; echo "=> $OUT"; }
icmp_test_all(){ OUT="$(_qf_outdir)/icmp.csv"; echo "vm,ping" > "$OUT"; for v in $(_qf_vms); do qvm-check --running "$v" >/dev/null 2>&1 || continue; RES=$(qvm-run -p "$v" 'ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && echo ok || echo fail' 2>/dev/null || echo fail); echo "$v,$RES" >> "$OUT"; done; echo "=> $OUT"; }

# ===== selectors & group actions =====
vms_by_label(){ [ -n "${1:-}" ] || { _qf_err "usage: vms_by_label <LABEL>"; return 2; }; _qf_by_label "$1"; }
vms_by_template(){ [ -n "${1:-}" ] || { _qf_err "usage: vms_by_template <TEMPLATE>"; return 2; }; _qf_by_template "$1"; }
vms_by_netvm(){ [ -n "${1:-}" ] || { _qf_err "usage: vms_by_netvm <NETVM>"; return 2; }; _qf_by_netvm "$1"; }
set_netvm_by_label(){ L="${1:-}"; NET="${2:-}"; [ -n "$L" ] && [ -n "$NET" ] || { _qf_err "usage: set_netvm_by_label <LABEL> <NETVM>"; return 2; }; for vm in $(_qf_by_label "$L"); do qvm-prefs "$vm" netvm "$NET"; echo "$vm -> netvm=$NET"; done; }
set_template_by_label(){ L="${1:-}"; TPL="${2:-}"; [ -n "$L" ] && [ -n "$TPL" ] || { _qf_err "usage: set_template_by_label <LABEL> <TEMPLATE>"; return 2; }; for vm in $(_qf_by_label "$L"); do qvm-prefs "$vm" template "$TPL"; echo "$vm -> template=$TPL"; done; }
_sel_expand(){ S="${1:-}"; case "$S" in label:*) _qf_by_label "${S#label:}";; template:*) _qf_by_template "${S#template:}";; netvm:*) _qf_by_netvm "${S#netvm:}";; *) _qf_err "selector must be label:<L> | template:<T> | netvm:<N>"; return 2;; esac; }
start_group(){ SEL="${1:-}"; [ -n "$SEL" ] || { _qf_err "usage: start_group <selector>"; return 2; }; for v in $(_sel_expand "$SEL"); do qvm-check --running "$v" >/dev/null 2>&1 || qvm-start "$v" || true; done; }
shutdown_group(){ SEL="${1:-}"; [ -n "$SEL" ] || { _qf_err "usage: shutdown_group <selector>"; return 2; }; for v in $(_sel_expand "$SEL"); do qvm-check --running "$v" >/dev/null 2>&1 && qvm-shutdown --wait "$v" || true; done; }
restart_group(){ SEL="${1:-}"; [ -n "$SEL" ] || { _qf_err "usage: restart_group <selector>"; return 2; }; for v in $(_sel_expand "$SEL"); do qvm-shutdown --wait "$v" || true; qvm-start "$v" || true; done; }
sync_menus_all(){ qvm-sync-appmenus "@tag:created-by-dom0" || true; for v in $(_qf_vms); do qvm-sync-appmenus "$v" || true; done; }

# ===== Ops & health =====
core_health(){
  echo "== dom0 services ==";
  systemctl is-active --quiet qubesd && echo "qubesd: active" || { echo "qubesd: NOT active"; return 1; }
  systemctl is-active --quiet qubes-qrexec-policy-daemon && echo "qrexec policy: active" || { echo "qrexec policy: NOT active"; return 1; }
  echo; echo "== key service VMs ==";
  for s in sys-net sys-firewall sys-dns sys-vpn sys-usb sys-monitor sys-integrity; do
    qvm-check --running "$s" >/dev/null 2>&1 && echo "$s: running" || echo "$s: not running"
  done
}
pool_usage(){ sudo lvs -o+seg_monitor,segtype,thin_count,data_percent,metadata_percent --units g; }
rep_vm_disk(){ OUT="$(_qf_outdir)/vm-volumes.txt"; : > "$OUT"; for vm in $(_qf_vms); do echo "== $vm ==" >> "$OUT"; qvm-volume info "$vm":private 2>>"$OUT" >>"$OUT" || true; qvm-volume info "$vm":root 2>>"$OUT" >>"$OUT" || true; echo >> "$OUT"; done; echo "=> $OUT"; }
timers_in_all(){ OUTD="$(_qf_outdir)/timers"; mkdir -p "$OUTD"; for t in $(_qf_templates); do qvm-run -p -u root "$t" 'systemctl list-timers --all --no-pager' > "$OUTD/$t.txt" || true; echo "-> $OUTD/$t.txt"; done; for s in sys-monitor sys-integrity sys-dns sys-vpn; do qvm-run -p "$s" 'systemctl list-timers --all --no-pager' > "$OUTD/$s.txt" 2>/dev/null || true; done; }

# ===== DNS / VPN =====
sysdns_status(){ qvm-run -p sys-dns 'echo "== sockets :53 =="; ss -H -uap | awk "/:53 /"; echo; echo "== nft inet qubes =="; nft list table inet qubes 2>/dev/null || echo "(no table inet qubes)"' || true; }
vpn_status(){ qvm-run -p sys-vpn 'ip -o link show | grep -E "tun[0-9]"; echo; ip route get 1.1.1.1 2>/dev/null' || true; }
vpn_killswitch_check(){ qvm-run -p sys-vpn 'nft list ruleset 2>/dev/null | grep -n "oifname \"tun"' || echo "(no oifname tun match)"; }

# ===== Audit / monitoring tie-ins =====
leaks_today(){ D="/var/lib/qubes/leakcheck/$(_qf_today)/results.csv"; [ -f "$D" ] || { echo "No leak results at $D"; return 0; }; column -s, -t <"$D" | less -S; }
integrity_today(){ qvm-run -p sys-integrity 'D="$HOME/Integrity/$(date -I)/_diff"; test -d "$D" || { echo "No diff dir: $D" ; exit 0; }; for r in "$D"/*/REPORT.txt; do echo "== $r =="; sed -n "1,200p" "$r"; echo; done' || true; }
ship_metrics_now(){ qvm-run -p sys-monitor '/usr/local/bin/monitor-backup.sh "$(date -I)"' || true; qvm-run -p sys-integrity '/usr/local/bin/integrity-diff.sh' || true; }
rep_firewall_all(){
  OUTD="$(_qf_outdir)/firewall-overview"; mkdir -p "$OUTD"; MD="$OUTD/overview.md"; : > "$MD"
  for n in $(_qf_netvms); do
    echo "## $n" >> "$MD"; echo >> "$MD"; echo "### Rules" >> "$MD"
    qvm-firewall "$n" list >> "$MD" 2>/dev/null || echo "(no rules)" >> "$MD"
    echo >> "$MD"; echo "### Clients" >> "$MD"
    for vm in $(_qf_by_netvm "$n"); do echo "- $vm" >> "$MD"; done
    echo >> "$MD"
  done
  echo "=> $MD"
}

# ====== 10 extra health/forensics gems ======

# 1) list dom0 snapshots (if any)
rep_dom0_snapshots(){
  echo "== LVM logical volumes (including snapshots) =="
  sudo lvs -o lv_name,vg_name,lv_attr,origin,lv_time,lv_size --units g qubes_dom0 || sudo lvs --units g
}

# 2) take a dom0 snapshot (default 1G COW). WARNING: ensure free space.
take_dom0_snapshot(){
  SIZE="${1:-1G}"
  NAME="root-snap-$(date -Iseconds | tr ':' '_')"
  echo "Creating snapshot $NAME ($SIZE) of qubes_dom0/root ..."
  sudo lvcreate -s -L "$SIZE" -n "$NAME" qubes_dom0/root
  sudo lvs -o lv_name,origin,lv_attr,lv_size,lv_time --units g qubes_dom0
}

# 3) dom0 baseline hashes (create/update now)
baseline_dom0_now(){
  OUTD="/var/lib/qubes/dom0-baseline"; sudo mkdir -p "$OUTD"
  echo "Hashing /etc and /boot into $OUTD ..."
  sudo find /etc -xdev -type f -readable -print0 | sudo xargs -0 sha256sum | sudo sort -k2 > "$OUTD/sha256-etc.baseline"
  [ -d /boot ] && sudo find /boot -xdev -type f -readable -print0 | sudo xargs -0 sha256sum | sudo sort -k2 > "$OUTD/sha256-boot.baseline" || true
  echo "Baseline updated in $OUTD"
}

# 4) compare current dom0 hashes vs baseline
compare_dom0_baseline(){
  OUTD="/var/lib/qubes/dom0-baseline"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  [ -r "$OUTD/sha256-etc.baseline" ] || { _qf_err "no baseline; run baseline_dom0_now first"; return 1; }
  echo "Hashing current /etc ..."
  sudo find /etc -xdev -type f -readable -print0 | sudo xargs -0 sha256sum | sudo sort -k2 > "$TMP/sha256-etc.now"
  echo "=== CHANGED /etc files ==="
  join -j2 -v1 -o 1.2,1.1 "$OUTD/sha256-etc.baseline" "$TMP/sha256-etc.now" >/dev/null # warm mmap
  join -j2 "$OUTD/sha256-etc.baseline" "$TMP/sha256-etc.now" | awk '$2!=$3{print $1}' | sed 's/^/CHANGED: /'
  echo "=== ADDED /etc files ==="
  join -j2 -v2 "$OUTD/sha256-etc.baseline" "$TMP/sha256-etc.now" | awk '{print "ADDED: " $2}'
  echo "=== REMOVED /etc files ==="
  join -j2 -v1 "$OUTD/sha256-etc.baseline" "$TMP/sha256-etc.now" | awk '{print "REMOVED: " $2}'
  if [ -r "$OUTD/sha256-boot.baseline" ] && [ -d /boot ]; then
    echo; echo "=== /boot delta ==="
    sudo find /boot -xdev -type f -readable -print0 | sudo xargs -0 sha256sum | sudo sort -k2 > "$TMP/sha256-boot.now"
    echo "--- CHANGED ---"; join -j2 "$OUTD/sha256-boot.baseline" "$TMP/sha256-boot.now" | awk '$2!=$3{print $1}'
    echo "--- ADDED ---"; join -j2 -v2 "$OUTD/sha256-boot.baseline" "$TMP/sha256-boot.now" | awk '{print $2}'
    echo "--- REMOVED ---"; join -j2 -v1 "$OUTD/sha256-boot.baseline" "$TMP/sha256-boot.now" | awk '{print $2}'
  fi
}

# 5) per-VM CPU usage bars (top 25)
vm_cpu_monitor_panel(){
  if ! _qf_has xentop; then echo "(xentop not available)"; return 0; fi
  sudo xentop -b -i 1 -d 2 2>/dev/null | awk 'NR>5{printf "%s %s\n",$1,$4}' | head -n 25 | while read -r VM CPU; do
    CPU_INT=${CPU%.*}; printf "%-22s " "$VM"; _qf_bar "${CPU_INT:-0}"; echo
  done
}

# 6) export domUs CPU/MEM to CSV
monitor_domU_xentop(){
  if ! _qf_has xentop; then echo "(xentop not available)"; return 0; fi
  OUT="$(_qf_outdir)/xentop.csv"; echo "vm,cpu%,mem(MiB)" > "$OUT"
  sudo xentop -b -i 1 -d 2 2>/dev/null | awk 'NR>5{printf "%s,%s,%s\n",$1,$4,$6}' >> "$OUT"
  echo "=> $OUT"
}

# 7) recent qrexec activity from dom0 logs (best-effort)
qrexec_recent(){
  echo "== /var/log/qubes/qrexec-policy-daemon.log (tail) =="
  sudo tail -n 100 /var/log/qubes/qrexec-policy-daemon.log 2>/dev/null || echo "(no policy-daemon log)"
  echo; echo "== /var/log/qubes/qrexec.log (tail) =="
  sudo tail -n 100 /var/log/qubes/qrexec.log 2>/dev/null || echo "(no qrexec.log)"
}

# 8) seed a tiny bandwidth widget into sys-net (safe, optional)
net_widget_seed_sysnet(){
  qvm-run -p -u root sys-net '
    install -d -m 0755 /usr/local/bin
    cat >/usr/local/bin/net-usage.sh << "EON"
#!/bin/sh
IF=$(ip route | awk "/default via/{print \$5; exit}")
RX0=$(cat /sys/class/net/$IF/statistics/rx_bytes)
TX0=$(cat /sys/class/net/$IF/statistics/tx_bytes)
sleep 1
RX1=$(cat /sys/class/net/$IF/statistics/rx_bytes)
TX1=$(cat /sys/class/net/$IF/statistics/tx_bytes)
RB=$((RX1-RX0)); TB=$((TX1-TX0))
echo "net:${IF} down=$((RB/1024))KiB/s up=$((TB/1024))KiB/s"
EON
    chmod 0755 /usr/local/bin/net-usage.sh
  ' && echo "-> sys-net:/usr/local/bin/net-usage.sh"
}

# 9) find templates missing qubes-repo-templates (breaks qvm-template)
check_qvm_template_deps(){
  OUT="$(_qf_outdir)/template-deps.csv"; echo "template,has_qubes_repo_templates" > "$OUT"
  for t in $(_qf_templates); do
    if qvm-run -p -u root "$t" 'test -r /etc/debian_version'; then
      RES=$(qvm-run -p -u root "$t" 'dpkg -s qubes-repo-templates >/dev/null 2>&1 && echo yes || echo no')
    else
      RES=$(qvm-run -p -u root "$t" 'rpm -q qubes-repo-templates >/dev/null 2>&1 && echo yes || echo no')
    fi
    echo "$t,$RES" >> "$OUT"
  done
  echo "=> $OUT"
}

# 10) summarize effective policy lines for a given qrexec service
policy_matrix(){
  SVC="${1:-}"; [ -n "$SVC" ] || { _qf_err "usage: policy_matrix <SERVICE>"; return 2; }
  echo "== Policy lines affecting '$SVC' =="
  grep -Hn " $SVC " /etc/qubes/policy.d/*.policy 2>/dev/null || echo "(no explicit lines; defaults apply)"
}

# ===== fzf TUI (with plain fallback) =====
_qf_all_funcs(){
  # list functions with a short tag (for the picker)
  cat <<'LST'
rep_inventory  [inventory]
rep_topology  [inventory]
rep_net_clients  [inventory]
rep_autostart  [inventory]
rep_policy_grep  [policy]
rep_usb  [usb]
tmpl_update_all  [templates]
tmpl_pkglist_all  [templates]
tmpl_enabled_all  [templates]
tmpl_ports_all  [templates]
tmpl_diff_services  [templates]
tmpl_rebase_all  [templates]
net_fw_dump_all  [net]
net_nft_check_all  [net]
net_route_all  [net]
dns_stub_check_all  [net]
icmp_test_all  [net]
vms_by_label  [select]
vms_by_template  [select]
vms_by_netvm  [select]
set_netvm_by_label  [bulk]
set_template_by_label  [bulk]
start_group  [bulk]
shutdown_group  [bulk]
restart_group  [bulk]
sync_menus_all  [bulk]
core_health  [health]
pool_usage  [health]
rep_vm_disk  [storage]
timers_in_all  [timers]
sysdns_status  [dns]
vpn_status  [vpn]
vpn_killswitch_check  [vpn]
leaks_today  [audit]
integrity_today  [audit]
ship_metrics_now  [audit]
rep_firewall_all  [audit]
rep_dom0_snapshots  [forensics]
take_dom0_snapshot  [forensics]
baseline_dom0_now  [forensics]
compare_dom0_baseline  [forensics]
vm_cpu_monitor_panel  [perf]
monitor_domU_xentop  [perf]
qrexec_recent  [qrexec]
net_widget_seed_sysnet  [net]
check_qvm_template_deps  [templates]
policy_matrix  [policy]
LST
}

qf_tui(){
  # usage: qf_tui  (fzf picker)
  _qf_has fzf || { echo "(fzf not found; falling back to simple menu)"; _qf_menu_basic; return 0; }
  PICK=$(_qf_all_funcs | fzf --prompt="qubes> " --height=90% --reverse --with-nth=1 --preview 'printf "help: "; echo {}' | awk '{print $1}')
  [ -n "${PICK:-}" ] || return 0
  echo ">> $PICK"
  case "$PICK" in
    tmpl_diff_services|tmpl_rebase_all|set_netvm_by_label|set_template_by_label|start_group|shutdown_group|restart_group|policy_matrix|rep_policy_grep)
      echo "(this function expects args; type them now, e.g. \"A B\" )"
      read -r ARGS
      eval "$PICK $ARGS"
      ;;
    *) eval "$PICK";;
  esac
}

_qf_menu_basic(){
  i=1; mapfile -t L < <(_qf_all_funcs)
  for line in "${L[@]}"; do printf "%2d) %s\n" "$i" "$line"; i=$((i+1)); done
  printf "choose #: "; read -r n
  sel="${L[$((n-1))]}"; func=$(printf "%s" "$sel" | awk '{print $1}')
  [ -n "$func" ] || return 0
  case "$func" in
    tmpl_diff_services|tmpl_rebase_all|set_netvm_by_label|set_template_by_label|start_group|shutdown_group|restart_group|policy_matrix|rep_policy_grep)
      echo "(args required) > "; read -r ARGS; eval "$func $ARGS";;
    *) eval "$func";;
  esac
}

EOF

# 2) reload in current shell (or open a new terminal)
source /etc/profile.d/qubes-funcs.sh

# 3) optional: create a tiny wrapper so you can run the TUI directly from dom0 menu/terminal
echo -e '#!/bin/sh\n. /etc/profile.d/qubes-funcs.sh\nqf_tui\n' | sudo tee /usr/local/sbin/qf_menu >/dev/null
sudo chmod 0755 /usr/local/sbin/qf_menu
