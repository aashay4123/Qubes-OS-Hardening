# README — net-monitor.md

## What this does

- In each NetVM (`sys-dns`, `sys-vpn`) we run **tcpdump** on **`any`** interface with a small **snaplen (96 bytes)** to keep size sane while still catching 5-tuple + headers.
- Files rotate **hourly** with a fixed retention window.
- A **dom0 timer** (daily) **pulls** the pcaps from each NetVM and streams them into **`secrets-vault`**, so nothing sits long-term on service qubes.

## Default paths

- In NetVMs: logs under `/var/log/netpcap/pcap-YYYYmmddHHMMSS.pcap`
- In secrets-vault: archives in `~/NetLogs/` per source VM and day (e.g., `sys-vpn-2025-08-31.tgz`)

## Resource footprint

- `tcpdump -i any -s 96 -nn -tttt` with hourly rotation (`-G 3600 -W 48`) is light on CPU/IO for typical Qubes traffic. Tune `-W` if you need a longer window.
- We don’t try to parse/IDS—just capture. You can inspect later from a work qube.

## Privacy knobs

- Capturing **everything** can collect sensitive metadata. If you want to **exclude** specific subnets or ports, edit the filter expression in the SLS below (e.g., to exclude inter-VM admin ranges like `10.137.0.0/16` and `10.139.0.0/16`).

## Daily backup flow (dom0)

- dom0 opens a qrexec stream:

  1. `sys-vpn`/`sys-dns` → **tar.gz to stdout**
  2. dom0 pipes that into **`secrets-vault`** via `--pass-io`

- After a successful copy, old files on the source qubes are pruned.

## Verify quickly

- Check service status: `qvm-run -p sys-vpn 'systemctl --no-pager status netpcap.service'`
- See live files: `qvm-run -p sys-dns 'ls -lh /var/log/netpcap'`
- After 3:30 AM (default): `qvm-run -p secrets-vault 'ls -lh ~/NetLogs'`

---

# SLS 1: enable rotating pcaps in `sys-dns` and `sys-vpn`

Save as: `/srv/salt/qubes/monitor/netlog.sls`

**To apply:**

```bash
sudo qubesctl state.show_sls qubes.monitor.netlog
sudo qubesctl --show-output state.sls qubes.monitor.netlog
```

> Want to **exclude** subnets/ports? Replace the `ExecStart` lines with a filter, e.g.:
>
> ```
> ... tcpdump -i any not net 10.137.0.0/16 and not net 10.139.0.0/16 -s 96 ...
> ```

---

# SLS 2: dom0 nightly backup into `secrets-vault`

Save as: `/srv/salt/qubes/monitor/netlog-backup-dom0.sls`

**To apply:**

```bash
sudo qubesctl state.show_sls qubes.monitor.netlog-backup-dom0
sudo qubesctl --show-output state.sls qubes.monitor.netlog-backup-dom0
```

---

## Quick sanity checks

- Start capture immediately:

  - `qvm-run -p sys-vpn 'systemctl is-active netpcap.service'`
  - `qvm-run -p sys-vpn 'ls -lh /var/log/netpcap'`

- Trigger backup now:

  ```bash
  sudo systemctl start qubes-netlogs-backup.service
  qvm-run -p secrets-vault 'ls -lh ~/NetLogs'
  ```

- Restore a pcap into a work qube for inspection:

  ```bash
  qvm-run --pass-io secrets-vault 'cat ~/NetLogs/sys-vpn-2025-08-31.tgz' \
    > /tmp/sys-vpn-2025-08-31.tgz
  qvm-run --pass-io work 'cat > ~/sys-vpn-2025-08-31.tgz' < /tmp/sys-vpn-2025-08-31.tgz
  ```

You’re absolutely right to look at **sys-firewall** when it comes to holistic system monitoring. Qubes’ compartmentalization places sys-firewall in a key position—**all app qubes’ traffic passes through it**—making it a great vantage point for observing what's going in and out. Plus, it’s better suited for logging than sys-net, which interfaces directly with untrusted networks.

I checked the Qubes 4.2 Firewall documentation and community forums for best practices around monitoring—here’s what I found:

---

### What Qubes' Docs & Community Say

#### 1. Monitoring via system journal

The Qubes Firewall service (`qubes-firewall.service`) logs to the system journal. You can view its activity with:

```bash
journalctl -u qubes-firewall.service
```

This gives you insight into when firewall rules are applied, but **does not log individual packets**.([Qubes OS Forum][1], [Qubes OS][2])

#### 2. Packet-level logging via nftables

There’s active forum discussion about how to enable packet logging with nftables. One user suggested enabling logging in `sys-firewall` and `sys-net` using standard nft logging tools—though not part of core docs, it's practical.([Qubes OS Forum][1])

#### 3. Interface-based monitoring

Users often observe that `sys-firewall`’s RX and TX counters look identical because it simply forwards RAM traffic across interfaces. Tools like `ip -s link show` or `nethogs` are frequently used to monitor per-interface or per-process network usage in service qubes.([Qubes OS Forum][3])

#### 4. dom0 remains minimal

Qubes design discourages installing monitoring tools in dom0. Instead, raw logs and traffic data get collected in service qubes and then transferred securely (e.g., to a vault qube) for processing.([Qubes OS Forum][4])

---

### Recommendations for sys-firewall Monitoring

Here’s a refined plan based on the above:

#### What to add to `sys-firewall`:

1. **Nftables packet logging rules**: Add match rules that log specific traffic, e.g., new connections from AppVMs, or port 53 lookups, dropping, etc.
2. **Traffic accounting**: Optionally run lightweight tools like `nethogs` or `ip -s link show` to monitor interface stats.

#### How to deploy:

- Use the `qubes-firewall-user-script` to apply nftables logging rules upon startup (this respects Qubes’ policy of where to put custom rules).
- Capture logs via the `qubes-firewall.service` journal.
- Periodically (via dom0 or a logging qube) pull logs (journals or packet dumps) from `sys-firewall` into your `secrets-vault` for retention and analysis.

---

### Example: Enabling Basic Packet Logging in sys-firewall

Here is a concept snippet of what could go into `sys-firewall:/rw/config/qubes-firewall-user-script`:

```bash
#!/bin/sh
# Log new inbound TCP connections from AppVMs
nft add rule ip qubes filter forward ct state new counter log prefix \"sys-fw-new: \"

# Log all DNS lookups (UDP port 53) from AppVMs
nft add rule ip qubes filter forward udp dport 53 counter log prefix \"sys-fw-dns: \"
```

These logs can then be viewed via:

```bash
journalctl -u qubes-firewall.service | grep sys-fw-dns
```

---

### Summary of Best Practices

| Goal               | Approach                                                 |
| ------------------ | -------------------------------------------------------- |
| Per-packet logging | Use nftables `log` via `qubes-firewall-user-script`      |
| Interface stats    | Use `ip -s link show` or `nethogs` inside `sys-firewall` |
| Long-term storage  | Pull logs into `secrets-vault` periodically              |
| Avoid dom0 bloat   | Keep monitoring tools in service qubes only              |

---

Let me know if you'd like a dedicated SLS to enable this packet logging in `sys-firewall`, along with a `log-poll` routine that ships logs into `secrets-vault` (similar to the netcap pipeline we built earlier).

[1]: https://forum.qubes-os.org/t/firewall-troubleshooting-in-qubes-4-2/23893?utm_source=chatgpt.com "Firewall troubleshooting in Qubes 4.2 - User Support"
[2]: https://www.qubes-os.org/doc/firewall/?utm_source=chatgpt.com "Firewall"
[3]: https://forum.qubes-os.org/t/system-monitor-for-firewall-receiving-and-sending-match/26283?utm_source=chatgpt.com "System Monitor for Firewall, Receiving and Sending Match"
[4]: https://forum.qubes-os.org/t/qubesos-system-monitoring-tools/30935?utm_source=chatgpt.com "QubesOS System Monitoring Tools - General Discussion"
