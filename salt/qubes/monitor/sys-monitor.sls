# sys-monitor (v2): rich, append-only daily CSVs, 10s polling, nightly vault backup
# Qubes OS 4.2.4
#
# Output layout in sys-monitor:
#   ~/Monitor/YYYY-MM-DD/
#     system.csv       (ts,vm,cpu_user,cpu_system,cpu_idle,load1,load5,load15,mem_total_kb,mem_used_kb,mem_avail_kb,swap_total_kb,swap_used_kb,procs_running,procs_blocked)
#     network.csv      (ts,vm,if,rx_bytes,rx_errs,rx_drop,tx_bytes,tx_errs,tx_drop)
#     connections.csv  (ts,vm,tcp_established,udp_sockets)
#     disk.csv         (ts,vm,fs,mount,size_kb,used_kb,avail_kb,pct_used)
#     alerts.csv       (ts,vm,msg)
#     qubes.csv        (ts,vm,state)     # once per minute, admin view of VM states

# -------------------- presence checks --------------------
check-sys-monitor:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx sys-monitor || qvm-create --class=AppVM --template=debian-12-hard-min --label=orange sys-monitor'"

sys-monitor-prefs:
  qvm.prefs:
    - name: sys-monitor
    - autostart: true
    - netvm: ""         # no network
    - memory: 400
    - maxmem: 800
    - vcpus: 1
  require:
    - cmd: check-sys-monitor

# -------------------- which templates get the handler --------------------
check-template-debian-hard:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx debian-12-hard'"

check-template-debian-hard-min:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx debian-12-hard-min'"

check-template-debian-work:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx debian-12-work'"

check-template-fedora-vpn-min:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx fedora-41-vpn-min'"

# -------------------- qrexec handler: qubes.Metrics.Get (Debian templates) --------------------
metrics-handler-debian-12-hard:
  qvm.run:
    - name: debian-12-hard
    - user: root
    - cmd: |
        /bin/sh -c '
        install -d -m 0755 /etc/qubes-rpc
        cat > /etc/qubes-rpc/qubes.Metrics.Get << "EOF"
        #!/bin/sh
        # Lightweight metrics provider for Qubes VMs. Outputs parsable lines:
        #   time=ISO8601
        #   sys: key=val ...
        #   net: if=name rx_bytes=... rx_errs=... rx_drop=... tx_bytes=... tx_errs=... tx_drop=...
        #   conn: tcp_established=N udp_sockets=M
        #   disk: fs=/dev/... mount=/ size_kb=... used_kb=... avail_kb=... pct_used=...
        #   alert: <journal-line>
        set -eu

        # timestamp
        now="$(date -Is 2>/dev/null || date)"
        echo "time=${now}"

        # --- system (cpu/load/mem/procs) ---
        # CPU usage (%): compute quickly from /proc/stat two snapshots
        awk '
          function readcpu(a,  i){getline; split($0,f," "); for(i=2;i<=NF;i++) a[i]=f[i]}
          BEGIN{
            # first read
            while((getline < "/proc/stat")>0){ if($1=="cpu"){ for(i=2;i<=NF;i++) a1[i]=$i; close("/proc/stat"); break } }
            # small delay
            system("sleep 0.2");
            # second read
            while((getline < "/proc/stat")>0){ if($1=="cpu"){ for(i=2;i<=NF;i++) a2[i]=$i; close("/proc/stat"); break } }
            total=0; idle=0; user=0; sys=0;
            for(i=2;i<=NF;i++){ d=a2[i]-a1[i]; total+=d; if(i==5) idle=d; if(i==2||i==3) user+=d; if(i==4) sys+=d }
            cu = (total>0? 100*user/total : 0)
            cs = (total>0? 100*sys/total  : 0)
            ci = (total>0? 100*idle/total : 0)
            # load averages
            while((getline la < "/proc/loadavg")>0){ split(la, L, " "); l1=L[1]; l5=L[2]; l15=L[3]; close("/proc/loadavg"); break }
            # meminfo
            while((getline mi < "/proc/meminfo")>0){
              split(mi, M, ":"); gsub(/[[:space:]]+/,"",M[1]); sub(/^ /,"",M[2]);
              if(M[1]=="MemTotal") mt=M[2]+0;
              if(M[1]=="MemAvailable") ma=M[2]+0;
              if(M[1]=="SwapTotal") st=M[2]+0;
              if(M[1]=="SwapFree") sf=M[2]+0;
            }
            close("/proc/meminfo");
            mu = (mt>0? mt-ma: 0)
            su = (st>0? st-sf: 0)
            # processes
            pr=pb=0;
            while((getline ps < "/proc/stat")>0){
              if($1=="procs_running") {pr=$2+0}
              if($1=="procs_blocked") {pb=$2+0}
            }
            close("/proc/stat");

            printf("sys: cpu_user=%.1f cpu_system=%.1f cpu_idle=%.1f load1=%s load5=%s load15=%s mem_total_kb=%d mem_used_kb=%d mem_avail_kb=%d swap_total_kb=%d swap_used_kb=%d procs_running=%d procs_blocked=%d\n",
                   cu, cs, ci, l1, l5, l15, mt, mu, ma, st, su, pr, pb);
          }
        ' </dev/null

        # --- network counters (per interface) ---
        awk -F: 'NR>2{
          gsub(/^ +/,"",$1); iface=$1;
          split($2, A, " ");
          # A indexes have empties; pick by position ignoring empties
          c=0; for(i=1;i<=length(A);i++){ if(A[i]!=""){ c++; B[c]=A[i] } }
          rx_bytes=B[1]+0;  rx_errs=B[3]+0;  rx_drop=B[4]+0;
          tx_bytes=B[9]+0;  tx_errs=B[11]+0; tx_drop=B[12]+0;
          printf("net: if=%s rx_bytes=%d rx_errs=%d rx_drop=%d tx_bytes=%d tx_errs=%d tx_drop=%d\n", iface, rx_bytes, rx_errs, rx_drop, tx_bytes, tx_errs, tx_drop);
          for(i=1;i<=c;i++) delete B[i]
        }' /proc/net/dev

        # --- connections summary ---
        tcp_est=$(awk 'NR>1{st=substr($4,1,2); if(st=="01") c++} END{print c+0}' /proc/net/tcp)
        udp_s=$(awk 'NR>1{c++} END{print c+0}' /proc/net/udp)
        echo "conn: tcp_established=${tcp_est} udp_sockets=${udp_s}"

        # --- disk usage ---
        # df -P -k: POSIX, KB units
        df -P -k | awk 'NR>1{printf("disk: fs=%s mount=%s size_kb=%s used_kb=%s avail_kb=%s pct_used=%s\n",$1,$6,$2,$3,$4,$5)}'

        # --- alerts: recent important journal lines (notice+ in last 10s) ---
        journalctl --since "10 seconds ago" -p notice --no-pager -o short-iso 2>/dev/null | sed "s/^/alert: /"
        exit 0
        EOF
        chmod 0755 /etc/qubes-rpc/qubes.Metrics.Get
        '
  require:
    - cmd: check-template-debian-hard

metrics-handler-debian-12-hard-min:
  qvm.run:
    - name: debian-12-hard-min
    - user: root
    - cmd: |
        /bin/sh -c '
        install -d -m 0755 /etc/qubes-rpc
        cp -f /etc/qubes-rpc/qubes.Metrics.Get /etc/qubes-rpc/qubes.Metrics.Get 2>/dev/null || exit 0
        '
  require:
    - qvm.run: metrics-handler-debian-12-hard
    - cmd: check-template-debian-hard-min

metrics-handler-debian-12-work:
  qvm.run:
    - name: debian-12-work
    - user: root
    - cmd: |
        /bin/sh -c '
        install -d -m 0755 /etc/qubes-rpc
        cp -f /etc/qubes-rpc/qubes.Metrics.Get /etc/qubes-rpc/qubes.Metrics.Get 2>/dev/null || exit 0
        '
  require:
    - qvm.run: metrics-handler-debian-12-hard
    - cmd: check-template-debian-work

# -------------------- qrexec handler (Fedora template) --------------------
metrics-handler-fedora-41-vpn-min:
  qvm.run:
    - name: fedora-41-vpn-min
    - user: root
    - cmd: |
        /bin/sh -c '
        install -d -m 0755 /etc/qubes-rpc
        cat > /etc/qubes-rpc/qubes.Metrics.Get << "EOF"
        #!/bin/sh
        set -eu
        now="$(date -Is 2>/dev/null || date)"
        echo "time=${now}"
        awk '
          function readcpu(a,  i){getline; split($0,f," "); for(i=2;i<=NF;i++) a[i]=f[i]}
          BEGIN{
            while((getline < "/proc/stat")>0){ if($1=="cpu"){ for(i=2;i<=NF;i++) a1[i]=$i; close("/proc/stat"); break } }
            system("sleep 0.2");
            while((getline < "/proc/stat")>0){ if($1=="cpu"){ for(i=2;i<=NF;i++) a2[i]=$i; close("/proc/stat"); break } }
            total=0; idle=0; user=0; sys=0;
            for(i=2;i<=NF;i++){ d=a2[i]-a1[i]; total+=d; if(i==5) idle=d; if(i==2||i==3) user+=d; if(i==4) sys+=d }
            cu=(total>0?100*user/total:0); cs=(total>0?100*sys/total:0); ci=(total>0?100*idle/total:0)
            while((getline la < "/proc/loadavg")>0){ split(la, L, " "); l1=L[1]; l5=L[2]; l15=L[3]; close("/proc/loadavg"); break }
            while((getline mi < "/proc/meminfo")>0){
              split(mi, M, ":"); gsub(/[[:space:]]+/,"",M[1]); sub(/^ /,"",M[2]);
              if(M[1]=="MemTotal") mt=M[2]+0;
              if(M[1]=="MemAvailable") ma=M[2]+0;
              if(M[1]=="SwapTotal") st=M[2]+0;
              if(M[1]=="SwapFree") sf=M[2]+0;
            }
            close("/proc/meminfo"); mu=(mt>0?mt-ma:0); su=(st>0?st-sf:0)
            pr=pb=0; while((getline ps < "/proc/stat")>0){ if($1=="procs_running") pr=$2+0; if($1=="procs_blocked") pb=$2+0 } close("/proc/stat")
            printf("sys: cpu_user=%.1f cpu_system=%.1f cpu_idle=%.1f load1=%s load5=%s load15=%s mem_total_kb=%d mem_used_kb=%d mem_avail_kb=%d swap_total_kb=%d swap_used_kb=%d procs_running=%d procs_blocked=%d\n",
                   cu, cs, ci, l1, l5, l15, mt, mu, ma, st, su, pr, pb);
          }
        ' </dev/null
        awk -F: 'NR>2{
          gsub(/^ +/,"",$1); iface=$1;
          split($2, A, " "); c=0; for(i=1;i<=length(A);i++){ if(A[i]!=""){ c++; B[c]=A[i] } }
          rx_bytes=B[1]+0; rx_errs=B[3]+0; rx_drop=B[4]+0; tx_bytes=B[9]+0; tx_errs=B[11]+0; tx_drop=B[12]+0;
          printf("net: if=%s rx_bytes=%d rx_errs=%d rx_drop=%d tx_bytes=%d tx_errs=%d tx_drop=%d\n", iface, rx_bytes, rx_errs, rx_drop, tx_bytes, tx_errs, tx_drop);
          for(i=1;i<=c;i++) delete B[i]
        }' /proc/net/dev
        tcp_est=$(awk 'NR>1{st=substr($4,1,2); if(st=="01") c++} END{print c+0}' /proc/net/tcp)
        udp_s=$(awk 'NR>1{c++} END{print c+0}' /proc/net/udp)
        echo "conn: tcp_established=${tcp_est} udp_sockets=${udp_s}"
        df -P -k | awk 'NR>1{printf("disk: fs=%s mount=%s size_kb=%s used_kb=%s avail_kb=%s pct_used=%s\n",$1,$6,$2,$3,$4,$5)}'
        journalctl --since "10 seconds ago" -p notice --no-pager -o short-iso 2>/dev/null | sed "s/^/alert: /"
        exit 0
        EOF
        chmod 0755 /etc/qubes-rpc/qubes.Metrics.Get
        '
  require:
    - cmd: check-template-fedora-vpn-min

# -------------------- qrexec policies (4.2 format) --------------------
metrics-policy-file:
  file.managed:
    - name: /etc/qubes/policy.d/30-metrics.policy
    - mode: '0644'
    - contents: |
        ## Allow sys-monitor to pull metrics and list VMs; allow filecopy to secrets-vault
        qubes.Metrics.Get     *   sys-monitor   @anyvm        allow
        admin.vm.List         *   sys-monitor   dom0          allow
        qubes.Filecopy        *   sys-monitor   secrets-vault allow

metrics-policy-reload:
  cmd.run:
    - name: /bin/sh -c 'systemctl reload qubes-qrexec-policy-daemon || systemctl restart qubes-qrexec-policy-daemon'
  require:
    - file: metrics-policy-file

# -------------------- install pollers/timers in sys-monitor --------------------
sys-monitor-install:
  qvm.run:
    - name: sys-monitor
    - user: root
    - cmd: |
        /bin/sh -c '
        install -d -m 0755 /usr/local/bin /etc/systemd/system
        # ---- poller every 10s: append to daily CSVs ----
        cat > /usr/local/bin/monitor-poll.sh << "EOF"
        #!/bin/bash
        set -euo pipefail
        BASE="${HOME}/Monitor"
        DAY="$(date -I)"
        DIR="${BASE}/${DAY}"
        mkdir -p "${DIR}"

        # Ensure CSV headers exist once per day
        touch "${DIR}/.headers"
        if [ ! -s "${DIR}/.headers" ]; then
          echo "ts,vm,cpu_user,cpu_system,cpu_idle,load1,load5,load15,mem_total_kb,mem_used_kb,mem_avail_kb,swap_total_kb,swap_used_kb,procs_running,procs_blocked" > "${DIR}/system.csv"
          echo "ts,vm,if,rx_bytes,rx_errs,rx_drop,tx_bytes,tx_errs,tx_drop" > "${DIR}/network.csv"
          echo "ts,vm,tcp_established,udp_sockets" > "${DIR}/connections.csv"
          echo "ts,vm,fs,mount,size_kb,used_kb,avail_kb,pct_used" > "${DIR}/disk.csv"
          echo "ts,vm,msg" > "${DIR}/alerts.csv"
          echo done > "${DIR}/.headers"
        fi

        # Ask dom0 for running VMs
        mapfile -t LINES < <(qrexec-client-vm dom0 admin.vm.List 2>/dev/null || true)
        VMS=()
        for L in "${LINES[@]}"; do
          name="${L%% *}"
          case "$L" in *"state=Running"*)
            if [ "$name" != "dom0" ] && [ "$name" != "sys-monitor" ]; then VMS+=("$name"); fi
          esac
        done

        for vm in "${VMS[@]}"; do
          OUT="$(qrexec-client-vm "$vm" qubes.Metrics.Get 2>/dev/null || true)"
          [ -n "$OUT" ] || { echo "$(date -Is),${vm},no-output" >> "${DIR}/alerts.csv"; continue; }

          TS=""
          while IFS= read -r line; do
            case "$line" in
              time=*) TS="${line#time=}";;
              "sys:"*)
                # turn "key=val ..." into CSV fields
                kv="${line#sys: }"
                # defaults
                cpu_user= cpu_system= cpu_idle= load1= load5= load15= mem_total_kb= mem_used_kb= mem_avail_kb= swap_total_kb= swap_used_kb= procs_running= procs_blocked=
                for t in $kv; do
                  k="${t%%=*}"; v="${t#*=}"
                  case "$k" in
                    cpu_user) cpu_user="$v";;
                    cpu_system) cpu_system="$v";;
                    cpu_idle) cpu_idle="$v";;
                    load1) load1="$v";;
                    load5) load5="$v";;
                    load15) load15="$v";;
                    mem_total_kb) mem_total_kb="$v";;
                    mem_used_kb) mem_used_kb="$v";;
                    mem_avail_kb) mem_avail_kb="$v";;
                    swap_total_kb) swap_total_kb="$v";;
                    swap_used_kb) swap_used_kb="$v";;
                    procs_running) procs_running="$v";;
                    procs_blocked) procs_blocked="$v";;
                  esac
                done
                echo "${TS},${vm},${cpu_user},${cpu_system},${cpu_idle},${load1},${load5},${load15},${mem_total_kb},${mem_used_kb},${mem_avail_kb},${swap_total_kb},${swap_used_kb},${procs_running},${procs_blocked}" >> "${DIR}/system.csv"
                ;;
              "net:"*)
                kv="${line#net: }"
                IF= rx_bytes= rx_errs= rx_drop= tx_bytes= tx_errs= tx_drop=
                for t in $kv; do k="${t%%=*}"; v="${t#*=}"; case "$k" in
                  if) IF="$v";;
                  rx_bytes) rx_bytes="$v";;
                  rx_errs)  rx_errs="$v";;
                  rx_drop)  rx_drop="$v";;
                  tx_bytes) tx_bytes="$v";;
                  tx_errs)  tx_errs="$v";;
                  tx_drop)  tx_drop="$v";;
                esac; done
                echo "${TS},${vm},${IF},${rx_bytes},${rx_errs},${rx_drop},${tx_bytes},${tx_errs},${tx_drop}" >> "${DIR}/network.csv"
                ;;
              "conn:"*)
                kv="${line#conn: }"
                tcp_established= udp_sockets=
                for t in $kv; do k="${t%%=*}"; v="${t#*=}"; case "$k" in
                  tcp_established) tcp_established="$v";;
                  udp_sockets)     udp_sockets="$v";;
                esac; done
                echo "${TS},${vm},${tcp_established},${udp_sockets}" >> "${DIR}/connections.csv"
                ;;
              "disk:"*)
                kv="${line#disk: }"
                fs= mount= size_kb= used_kb= avail_kb= pct_used=
                for t in $kv; do k="${t%%=*}"; v="${t#*=}"; case "$k" in
                  fs) fs="$v";;
                  mount) mount="$v";;
                  size_kb) size_kb="$v";;
                  used_kb) used_kb="$v";;
                  avail_kb) avail_kb="$v";;
                  pct_used) pct_used="$v";;
                esac; done
                echo "${TS},${vm},${fs},${mount},${size_kb},${used_kb},${avail_kb},${pct_used}" >> "${DIR}/disk.csv"
                ;;
              "alert:"*)
                msg="${line#alert: }"
                # strip commas to keep CSV intact
                msg="${msg//,/ }"
                echo "${TS},${vm},${msg}" >> "${DIR}/alerts.csv"
                ;;
            esac
          done <<EOF_LINES
        ${OUT}
        EOF_LINES
        done
        EOF
        chmod 0755 /usr/local/bin/monitor-poll.sh

        # ---- once per minute: admin VM state snapshot (qubes.csv) ----
        cat > /usr/local/bin/monitor-qubes.sh << "EOF"
        #!/bin/bash
        set -euo pipefail
        BASE="${HOME}/Monitor"
        DAY="$(date -I)"
        DIR="${BASE}/${DAY}"
        mkdir -p "${DIR}"
        if [ ! -s "${DIR}/qubes.csv" ]; then echo "ts,vm,state" > "${DIR}/qubes.csv"; fi
        TS="$(date -Is)"
        qrexec-client-vm dom0 admin.vm.List 2>/dev/null | while read -r L; do
          VM="${L%% *}"
          STATE="unknown"
          case "$L" in *"state="*) STATE="${L#*state=}"; STATE="${STATE%% *}";; esac
          echo "${TS},${VM},${STATE}" >> "${DIR}/qubes.csv"
        done
        EOF
        chmod 0755 /usr/local/bin/monitor-qubes.sh

        # ---- backup yesterday to secrets-vault ----
        cat > /usr/local/bin/monitor-backup.sh << "EOF"
        #!/bin/bash
        set -euo pipefail
        BASE="${HOME}/Monitor"
        DAY="${1:-$(date -I -d "yesterday")}"
        VAULT="${BACKUP_VAULT:-secrets-vault}"
        SRC="${BASE}/${DAY}"
        [ -d "$SRC" ] || exit 0
        ARCH="/tmp/monitor-${DAY}.tgz"
        tar -C "${BASE}" -czf "${ARCH}" "${DAY}"
        # send to vault (policy allows)
        echo "${ARCH}" | qvm-copy-to-vm "${VAULT}" >/dev/null 2>&1 || true
        # optional local prune: keep last 14 days (adjust if you want)
        find "${BASE}" -maxdepth 1 -type d -name '20*' -mtime +14 -print -exec rm -rf {} \;
        EOF
        chmod 0755 /usr/local/bin/monitor-backup.sh

        # ---- timers ----
        cat > /etc/systemd/system/monitor-poll.service << "EOF"
        [Unit]
        Description=Poll metrics from running VMs (append to CSVs)
        After=qubes-qrexec-agent.service
        [Service]
        Type=oneshot
        ExecStart=/usr/local/bin/monitor-poll.sh
        EOF

        cat > /etc/systemd/system/monitor-poll.timer << "EOF"
        [Unit]
        Description=Every 10s metrics poll
        [Timer]
        OnBootSec=2min
        OnUnitActiveSec=10s
        AccuracySec=2s
        Unit=monitor-poll.service
        [Install]
        WantedBy=timers.target
        EOF

        cat > /etc/systemd/system/monitor-qubes.service << "EOF"
        [Unit]
        Description=Snapshot VM states into qubes.csv
        After=qubes-qrexec-agent.service
        [Service]
        Type=oneshot
        ExecStart=/usr/local/bin/monitor-qubes.sh
        EOF

        cat > /etc/systemd/system/monitor-qubes.timer << "EOF"
        [Unit]
        Description=Every 1 minute VM state snapshot
        [Timer]
        OnBootSec=2min
        OnUnitActiveSec=1min
        AccuracySec=5s
        Unit=monitor-qubes.service
        [Install]
        WantedBy=timers.target
        EOF

        cat > /etc/systemd/system/monitor-backup.service << "EOF"
        [Unit]
        Description=Archive & send yesterday's metrics to vault
        After=qubes-qrexec-agent.service
        [Service]
        Type=oneshot
        Environment=BACKUP_VAULT=secrets-vault
        ExecStart=/usr/local/bin/monitor-backup.sh
        EOF

        cat > /etc/systemd/system/monitor-backup.timer << "EOF"
        [Unit]
        Description=Nightly metrics backup to vault
        [Timer]
        OnCalendar=*-*-* 03:50:00
        Persistent=true
        Unit=monitor-backup.service
        [Install]
        WantedBy=timers.target
        EOF

        systemctl daemon-reload
        systemctl enable --now monitor-poll.timer
        systemctl enable --now monitor-qubes.timer
        systemctl enable --now monitor-backup.timer
        '
  require:
    - qvm.prefs: sys-monitor-prefs
    - cmd: metrics-policy-reload

# -------------------- first run now --------------------
sys-monitor-first-poll:
  cmd.run:
    - name: qvm-run -p sys-monitor /usr/local/bin/monitor-poll.sh
  require:
    - qvm.run: sys-monitor-install
