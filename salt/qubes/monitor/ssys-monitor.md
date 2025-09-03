# sys-monitor — lightweight, append-only metrics for all VMs (Qubes 4.2.x)

## quick answer: does it capture DNS requests?

**sys-monitor itself does not capture per-packet DNS.**
It collects **counters and summaries** (CPU/mem/load, interface RX/TX bytes & errors, socket counts, disk usage, recent system notices). For DNS **packet visibility** you’re already covered by the earlier **netlog bundle**:

- rotating **pcaps** in `sys-dns` and `sys-vpn`
- **nft DNS logs** in `sys-firewall` / `sys-net`

So: use **sys-monitor** for fast, low-overhead **metrics**; use the **netlog** pipeline for **packet-level DNS** when you need it.

---

## what this SLS sets up

### a dedicated monitor VM

- `sys-monitor` (AppVM), **no NetVM**, autostarts on boot
- minimal footprint (≈ 1 vCPU, 400–800 MB RAM target)

### secure cross-VM collection

- a tiny qrexec RPC handler `qubes.Metrics.Get` installed in your templates:

  - `debian-12-hard`, `debian-12-hard-min`, `debian-12-work`, `fedora-41-vpn-min`

- policy in dom0 (`/etc/qubes/policy.d/30-metrics.policy`) allows **only**:

  - `sys-monitor` → `@anyvm` : `qubes.Metrics.Get`
  - `sys-monitor` → `dom0` : `admin.vm.List`
  - `sys-monitor` → `secrets-vault` : `qubes.Filecopy` (for nightly archive)

### polling cadence & files

- **every 10 seconds**: poll all **running** VMs (except dom0 & sys-monitor)
- append to **CSV files** under `sys-monitor:~/Monitor/YYYY-MM-DD/`:

  - `system.csv` — CPU, load, memory, processes
  - `network.csv` — per-interface RX/TX counters & errors
  - `connections.csv` — TCP established count, UDP socket count
  - `disk.csv` — filesystem usage (KB & %)
  - `alerts.csv` — journal **notice+** entries in last 10s (for “what just happened?”)
  - `qubes.csv` — once/min snapshot of **VM states** (Running/Halted/etc)

### nightly archive to vault

- at **03:50**, `sys-monitor` creates `monitor-YYYY-MM-DD.tgz` (yesterday’s folder)
  and copies it to **`secrets-vault`** via `qvm-copy-to-vm` (policy = allow)

---

## file schemas (Grafana-friendly)

1. `system.csv`

```
ts,vm,cpu_user,cpu_system,cpu_idle,load1,load5,load15,mem_total_kb,mem_used_kb,mem_avail_kb,swap_total_kb,swap_used_kb,procs_running,procs_blocked
2025-08-31T12:00:10Z,work,3.1,1.7,95.0,0.37,0.28,0.22,16310256,421234,15234567,0,0,1,0
...
```

2. `network.csv`

```
ts,vm,if,rx_bytes,rx_errs,rx_drop,tx_bytes,tx_errs,tx_drop
2025-08-31T12:00:10Z,work,eth0,1234567,0,0,7654321,0,0
...
```

3. `connections.csv`

```
ts,vm,tcp_established,udp_sockets
2025-08-31T12:00:10Z,work,12,4
...
```

4. `disk.csv`

```
ts,vm,fs,mount,size_kb,used_kb,avail_kb,pct_used
2025-08-31T12:00:10Z,work,/dev/xvda3,/rw,52428800,1000000,51428800,2%
...
```

5. `alerts.csv` _(free-text msg, commas stripped for CSV safety)_

```
ts,vm,msg
2025-08-31T12:00:10Z,work,Aug 31 12:00:09 kernel: NET: eth0 link up 1000Mb/s
...
```

6. `qubes.csv` (once/min)

```
ts,vm,state
2025-08-31T12:00:00Z,work,Running
...
```

---

## how to deploy (recap)

```bash
# preview
sudo qubesctl state.show_sls qubes.monitor.sys-monitor

# apply
sudo qubesctl --show-output state.sls qubes.monitor.sys-monitor
```

It will:

- create/adjust `sys-monitor`
- install the qrexec handler into templates
- write qrexec policy
- drop `monitor-*.sh` helpers & systemd timers inside `sys-monitor`
- perform an immediate first poll

---

## day-to-day use

- **check it’s running**

  ```bash
  qvm-run -p sys-monitor 'systemctl --no-pager status monitor-poll.timer monitor-qubes.timer'
  ```

- **peek at current day**

  ```bash
  qvm-run -p sys-monitor 'tail -n 5 ~/Monitor/$(date -I)/system.csv'
  qvm-run -p sys-monitor 'tail -n 5 ~/Monitor/$(date -I)/alerts.csv'
  ```

- **force a poll now**

  ```bash
  qvm-run -p sys-monitor '/usr/local/bin/monitor-poll.sh'
  ```

- **nightly archive already in vault?**

  ```bash
  qvm-run -p secrets-vault 'ls -lh ~/QubesIncoming/sys-monitor | tail'
  ```

---

## feeding into Grafana / others later

You’ve got simple, tidy CSVs. Options:

- **Ad-hoc**: copy yesterday’s archive to your analysis VM and point Grafana/Telegraf at the unzipped directory.
- **Telegraf (file input)**: parse CSV with `inputs.tail`/`inputs.file` + `data_format = "csv"` and column mapping; ship to Influx/Prometheus.
- **Loki/Promtail** (alerts): treat `alerts.csv` as logs; label `{vm="<name>", type="alert"}`.

Because the files are **append-only**, you can tail them safely.

---

## tuning & customization

### polling interval

In `sys-monitor`:

```
sudo nano /etc/systemd/system/monitor-poll.timer
# change:
# OnUnitActiveSec=10s
sudo systemctl daemon-reload
sudo systemctl restart monitor-poll.timer
```

- **5s** if you want tighter granularity
- **30s / 60s** for ultra-low overhead

### which VMs are polled

By default: **all running VMs** (except dom0 & sys-monitor).
To exclude certain names, add a small filter in `/usr/local/bin/monitor-poll.sh`:

```bash
# after we assemble VMS array:
VMS=("${VMS[@]/untrusted}")   # drop 'untrusted'
```

### vault name / backup time

- Change `BACKUP_VAULT=` in `/etc/systemd/system/monitor-backup.service`
- Change schedule in `/etc/systemd/system/monitor-backup.timer` (default 03:50)

### add more metrics

The handler script (`/etc/qubes-rpc/qubes.Metrics.Get` inside templates) is the place:

- add `vmstat` columns, `iostat` summaries, `nft list counters` excerpts, etc.
- always print lines prefixed with one of:

  - `sys: ...` `net: ...` `conn: ...` `disk: ...` `alert: ...`

- the poller already knows how to file those lines into the CSVs

### rate & size planning

- At 10s intervals and modest VM counts, CSV growth is tiny (kilobytes to a few MB/day per VM).
- If you add many VMs or reduce to 1–5s intervals, consider weekly pruning or compressing old days in `sys-monitor` (the SLS already prunes >14 days locally after a successful nightly backup).

---

## what not to do

- **Don’t install heavy agents** (Prometheus node_exporter, collectd, etc.) in every VM unless you truly need that depth — the whole point here is **no resident daemons** in guests, just a quick qrexec scrape when needed.
- **Don’t give sys-monitor a NetVM** — it doesn’t need one, and staying offline reduces its attack surface.
- **Don’t edit dom0 policy to allow more than needed** — the provided policy is minimal; keep it that way.

---

## troubleshooting

- **no CSVs today**
  Check timers:

  ```bash
  qvm-run -p sys-monitor 'systemctl list-timers --all | egrep "monitor-(poll|qubes|backup)"'
  qvm-run -p sys-monitor 'journalctl -u monitor-poll.service --since "1 hour ago" --no-pager'
  ```

- **a VM missing from files**
  Is it running? `qvm-ls | grep Running`
  Try calling the service directly:

  ```bash
  qvm-run -p sys-monitor 'qrexec-client-vm <VMNAME> qubes.Metrics.Get | head'
  ```

  If that fails, make sure its **template** has `/etc/qubes-rpc/qubes.Metrics.Get` (the SLS installs into the listed templates).

- **alerts too noisy**
  In the handler, change:

  ```
  journalctl --since "10 seconds ago" -p notice
  ```

  to `-p warning` or `-p err` (per-VM), and re-apply the SLS (or just update the template & restart the appVMs).

---

## FAQ

**Q: Can sys-monitor see DNS queries?**
**A:** Not the packets themselves. It records network counters and socket counts. For DNS packets you already have the **pcap/nft logging** from our netlog setup in `sys-dns`/`sys-vpn`/`sys-firewall`/`sys-net`.

**Q: Can I alert on thresholds (e.g., CPU > 90% for 5 min)?**
Yes — easiest path is to ingest the CSVs into your metrics stack and set alerts there. If you want a local “quick-and-dirty” alert, we can add a tiny rule engine in `sys-monitor` that appends to `alerts.csv` when thresholds are breached.

**Q: How do I include Whonix VMs?**
Copy the same handler into the Whonix template (`whonix-ws-*`), or add a block to the SLS to deploy it there. The poller doesn’t care which distro; it just calls the qrexec service.

---

## appendices

### paths to know

- `sys-monitor:~/Monitor/YYYY-MM-DD/*.csv` — your primary time-series files
- `secrets-vault:~/QubesIncoming/sys-monitor/monitor-YYYY-MM-DD.tgz` — nightly archives

### safety & privacy

- CSVs are **metadata only** (no payloads), but still sensitive (hostnames may appear in `alerts.csv`). Treat vault archives as confidential.
- `sys-monitor` has **no network** and only least-privilege qrexec access granted via policy.

---
