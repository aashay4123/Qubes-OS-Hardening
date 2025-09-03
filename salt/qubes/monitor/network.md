# README — network logging/pcap capture & daily vault backup

## What you get

- **`sys-dns`** & **`sys-vpn`**: `tcpdump` captures with hourly rotation (96-byte snaplen to keep size light). Files live in `/var/log/netpcap/pcap-YYYYmmddHHMMSS.pcap`.
- **`sys-firewall`** & **`sys-net`**: nftables **packet logs** into the **kernel journal** with explicit prefixes:

  - `SYSFW:new` / `SYSFW:dns` (in `sys-firewall`)
  - `SYSNET:new` / `SYSNET:dns` (in `sys-net`)

- **dom0 timer**: nightly (03:35) pulls:

  - pcaps from `sys-dns` & `sys-vpn`
  - yesterday’s nft log lines from `sys-firewall` & `sys-net`
    into **`secrets-vault:~/NetLogs/<vm>/YYYY-MM-DD.*`**, then prunes old source files.

## Quick verify

- Are capture daemons up?

  - `qvm-run -p sys-dns 'systemctl is-active netpcap.service'`
  - `qvm-run -p sys-vpn 'systemctl is-active netpcap.service'`

- Do nft logs show up?

  - `qvm-run -p sys-firewall "journalctl -k --since '1 hour ago' | grep 'SYSFW:'"`
  - `qvm-run -p sys-net "journalctl -k --since '1 hour ago' | grep 'SYSNET:'"`

- Did archives land in the vault?

  - `qvm-run -p secrets-vault 'ls -l ~/NetLogs'`

## Tuning

- **Retention**: pcaps rotate hourly (keep 48 by default). Adjust `-W` in the service ExecStart to change the window.
- **Noise**: logging every DNS packet is useful; everything else logs only **new** connections (conntrack state). You can narrow rules further or add `limit rate 10/second` if you expect bursts.
- **Privacy/exclusions**: want to skip inter-VM admin ranges? Replace the tcpdump ExecStart with a filter like `... -i any not net 10.137.0.0/16 and not net 10.139.0.0/16 ...`.

---

# One file to do it all

Save as: **`/srv/salt/qubes/monitor/full-netlog.sls`**

---

## How to apply

```bash
# Preview
sudo qubesctl state.show_sls qubes.monitor.full-netlog

# Apply
sudo qubesctl --show-output state.sls qubes.monitor.full-netlog
```

---

## Optional tweaks you might want later

- **Rate-limit nft logging** to avoid bursts:

  - Append `limit rate 10/second` before `log` in those rules.

- **Per-VM tagging** in logs: nft can add `meta skuid/saddr` info; the kernel log already includes `IN=/OUT=` iface names (good for tracing); if you want more, we can expand the prefixes or add separate rules per class of traffic.
- **Longer pcap retention**: change `-W 48` (48 hourly files ≈ 2 days) to larger, and/or change the dom0 prune policy.

If you want me to ship a tiny **viewer script** in a work VM to pull & list the latest day’s bundle from the vault and open the pcaps in Wireshark with a click, say the word and I’ll add it.

awesome — here’s a clean, “drop-in and go” viewer + a thorough guide so you (or teammates) know exactly how, why, and when to use the network logs we’re now collecting.

---

# README — Network Logs: How/Why/When (and when _not_) to use

## What you now have

From our previous bundle:

- **Rotating pcaps** (96-byte snaplen, hourly rotation) in:

  - `sys-dns` → `/var/log/netpcap/pcap-YYYYmmddHHMMSS.pcap`
  - `sys-vpn` → `/var/log/netpcap/pcap-YYYYmmddHHMMSS.pcap`

- **nft per-packet logs** in the kernel journal with clear prefixes:

  - `sys-firewall`: `SYSFW:new` (new connections), `SYSFW:dns` (DNS)
  - `sys-net`: `SYSNET:new`, `SYSNET:dns`

- **Nightly dom0 backup (03:35)** into **secrets-vault**:

  - pcaps: `~/NetLogs/sys-dns/<date>/pcaps-<date>.tgz`, same for `sys-vpn`
  - nft logs: `~/NetLogs/sys-firewall/<date>/nft-<date>.log.gz`, same for `sys-net`

This gives you wire-level evidence (pcaps) + control-plane audit (nft logs) with minimal runtime cost.

---

## Why capture this way (design rationale)

- **Right vantage points**:

  - `sys-dns`: see DNS queries after DNSCrypt DNAT — helps spot plaintext attempts and app behavior.
  - `sys-vpn`: see what ultimately leaves the box (inside the tunnel), confirm no off-tunnel leaks.
  - `sys-firewall` / `sys-net`: minimal packet logging where it matters (connection starts & DNS), without drowning in noise.

- **Low-impact**: 96-byte snaplen + hourly rotation keeps CPU/IO sane.
- **Forensics & debug**: pcaps + nft logs give you enough to reconstruct flows and prove policy.

---

## When to use (and what for)

- **Incident triage** (suspicious outbound, weird DNS, unexpected latency)
- **Policy verification** (DNSCrypt enforced; VPN killswitch working)
- **Change audits** (after updating a template, did anything start “phoning home”?)
- **Provider issues** (VPN path flaps, resolver timeouts)

---

## When _not_ to use (or to reduce scope)

- **Privacy** / **Regulatory**: pcaps include metadata (IPs, ports, SNI for HTTPS, etc.). If that’s sensitive, consider:

  - Reducing capture scope (filter out subnets/ports),
  - Shortening retention,
  - Encrypting archives inside the vault.

- **Very high throughput** links: consider raising rotation frequency or using sampling for nft logs (rate-limit).

---

## Common gotchas (and fixes)

- **No files in the vault**: the nightly pull hasn’t run yet. Kick it once:

  ```bash
  sudo systemctl start qubes-netlogs-backup.service
  ```

- **Empty pcap archive**: the source qube had nothing in the last window. Check service:

  ```bash
  qvm-run -p sys-vpn 'systemctl status netpcap.service'
  ```

- **Too noisy nft logs**: add a rate-limit (e.g., `limit rate 10/second`) to the nft log rules in the `qubes-firewall-user-script`.
- **Disk usage creeping**: pcaps rotate by count (48 by default \~2 days) and sources prune older than 2 days after each backup. If you need longer retention, plan vault storage accordingly.

---

## Your daily flow (quick)

1. Let the nightly job push bundles into **secrets-vault**.
2. Use the **dom0 pull helper** (below) to copy the latest day’s bundles from **secrets-vault** into your **work** VM.
3. In **work**, run the **viewer script** to unpack & open pcaps in Wireshark, and read nft logs.

---

# Tools

You get two tiny helpers:

1. A **dom0 helper** to copy the latest bundles from `secrets-vault` → `work`.
2. A **viewer** that runs **inside `work`** to unpack archives and open pcaps in Wireshark.

### 1) dom0: pull latest bundles into `work`

Save in **dom0** as `/usr/local/sbin/pull-netlogs-to-work` and make it executable:

```bash
#!/bin/sh
set -eu
VAULT="secrets-vault"
WORK="work"
TODAY="$(date -I)"

# Ensure target dir inside work
qvm-run --pass-io "$WORK" "mkdir -p -m 0750 ~/NetLogs/${TODAY}" >/dev/null

# Copy all trees for today's date from vault → work
for SRC in sys-dns sys-vpn sys-firewall sys-net; do
  SRC_PATH="~/NetLogs/${SRC}/${TODAY}"
  # If folder exists in vault, stream it
  if qvm-run --pass-io "$VAULT" "test -d ${SRC_PATH} && tar -C ${SRC_PATH%/*} -cz ${TODAY}" \
     | qvm-run --pass-io "$WORK"  "cat > ~/NetLogs/${TODAY}/${SRC}.tgz"
  then
    echo "Pulled ${SRC}"
  fi
done

echo "Done. Check in 'work': ~/NetLogs/${TODAY}/"
```

```bash
sudo install -m 0755 /usr/local/sbin/pull-netlogs-to-work /usr/local/sbin/pull-netlogs-to-work
```

Usage from **dom0**:

```bash
pull-netlogs-to-work
```

This leaves you with `~/NetLogs/<YYYY-MM-DD>/{sys-dns.tgz,sys-vpn.tgz,sys-firewall.tgz,sys-net.tgz}` inside **work**.

---

### 2) work VM: viewer / unpacker

Save in **work** as `~/bin/open-netlogs.sh` (and `chmod +x ~/bin/open-netlogs.sh`):

```bash
#!/bin/bash
set -euo pipefail

BASE="${HOME}/NetLogs"
TODAY="$(date -I)"
DAY="${1:-$TODAY}"

mkdir -p "$BASE/$DAY"

# Unpack any .tgz dropped by dom0 (idempotent; skips if already unpacked)
shopt -s nullglob
for f in "$BASE/$DAY"/*.tgz; do
  dir="${f%.tgz}"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    tar -xzf "$f" -C "$dir"
  fi
done

# Find pcaps (from sys-dns/sys-vpn bundles)
echo "[*] Available pcaps for ${DAY}:"
mapfile -t PCAPS < <(find "$BASE/$DAY" -type f -name '*.pcap' -o -name '*.pcapng' 2>/dev/null | sort)
if [ ${#PCAPS[@]} -eq 0 ]; then
  echo "  (none found)"; exit 0
fi

i=0
for p in "${PCAPS[@]}"; do
  printf "  [%02d] %s\n" "$i" "$p"
  ((i++))
done

echo
read -rp "Open which pcap (index or 'a' for all, ENTER to quit)? " pick
case "$pick" in
  '' ) exit 0 ;;
  a|A )
    # Open all pcaps in separate Wireshark instances (careful: can be heavy)
    for p in "${PCAPS[@]}"; do
      ( wireshark "$p" >/dev/null 2>&1 & ) || true
    done
    ;;
  * )
    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 0 ] && [ "$pick" -lt "${#PCAPS[@]}" ]; then
      wireshark "${PCAPS[$pick]}" >/dev/null 2>&1 &
    else
      echo "Invalid choice"; exit 1
    fi
    ;;
esac

# Show nft log text files if present
echo
echo "[*] nft logs (if any):"
find "$BASE/$DAY" -type f -name 'nft-*.log.gz' -print -exec sh -c 'echo "-----"; gzip -cd "$1" | tail -n 40' _ {} \; 2>/dev/null || true
```

Usage in **work**:

```bash
# open today's bundle (if present)
~/bin/open-netlogs.sh

# or a specific day
~/bin/open-netlogs.sh 2025-08-31
```

> If Wireshark isn’t installed in `work`, install it (e.g., Debian: `sudo apt-get -y install wireshark` or Fedora: `sudo dnf -y install wireshark`).
> For headless review, swap `wireshark` with `tshark -r <pcap>` in the script.

---

## Tips for efficient analysis

- **Filter suggestions (Wireshark)**

  - See DNS only: `dns`
  - Exclude inter-VM admin ranges: `!(ip.addr == 10.137.0.0/16 || ip.addr == 10.139.0.0/16)`
  - Focus on suspect host: `ip.addr == 203.0.113.42`
  - TLS SNI (metadata): use `tls.handshake.extensions_server_name` (note: only visible in clientHello)

- **Correlate with nft logs**
  Open the `nft-*.log.gz` (viewer already shows the last lines) and match timestamps + 5-tuples with the pcap.

- **Performance**
  If “Open all” feels heavy, open one hour at a time. You can also merge hourly pcaps first (`mergecap`) if you prefer a single file.

---

## Retention & security

- **Retention** is your call. The pipeline prunes sources after 2 days but keeps archives in the vault indefinitely by default. If you want auto-prune in the vault, I can add a size- or age-based retention policy.
- **Access**: only copy bundles into `work` when needed. Treat pcaps as sensitive (IPs, hostnames, SNI). Delete them in `work` after analysis (`rm -rf ~/NetLogs/<date>`).

---

## Troubleshooting quickies

- **No pcaps in `work`** after running the dom0 helper:

  - Check vault paths: `qvm-run -p secrets-vault 'find ~/NetLogs -maxdepth 2 -type d -mtime -1'`
  - Kick a manual backup: `sudo systemctl start qubes-netlogs-backup.service` (dom0)
  - Pull again: `pull-netlogs-to-work` (dom0)

- **Viewer shows “none found”**:

  - Ensure you ran the dom0 pull helper today.
  - Ensure the archives actually contain `netpcap/…`. If blank, check services in `sys-dns`/`sys-vpn`.

---
