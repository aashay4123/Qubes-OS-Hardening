gotcha — here are two clean, copy-pasteable READMEs you can drop into your repo:

---

# README — `sys-integrity.sls` (TemplateVM + dom0 integrity)

## What it does

- Creates a dedicated offline AppVM **`sys-integrity`** that:

  - once per day pulls integrity reports **from every TemplateVM** via a qrexec RPC (`qubes.Integrity.Get`);
  - stores per-template reports under `~/Integrity/YYYY-MM-DD/` inside `sys-integrity`.

- Runs a **dom0** job daily that:

  - verifies package files (`rpm -Va`) and hashes key trees (`/etc`, `/etc/qubes`, `/boot`);
  - ships an archive into `sys-integrity:~/Integrity/YYYY-MM-DD/dom0.tgz`.

- Uses **Qubes Admin API/qrexec** with minimal permissions (list/start/shutdown templates; pull a single RPC). This follows Qubes’ model for cross-VM management and the 4.2 policy format. ([Qubes OS][1])
- Avoids installing extra software in **dom0** (strongly discouraged by Qubes except for advanced use). ([Qubes OS][2])

## What gets checked (default)

- **Debian-based templates**:

  - `debsums -s` (report suspicious package file changes), plus SHA-256 of `/etc` and `/etc/qubes`. ([Debian Manpages][3])

- **Fedora-based templates**:

  - `rpm -Va` (verify installed files), plus SHA-256 of `/etc` and `/etc/qubes`. ([Red Hat Docs][4])

- **dom0**:

  - `rpm -Va`, and SHA-256 of `/etc`, `/etc/qubes`, `/boot`. (No third-party agents in dom0 by design.) ([Qubes OS][2])

## Files & where to find them

Inside **`sys-integrity`**:

```
~/Integrity/2025-09-01/debian-12-hard.txt
~/Integrity/2025-09-01/debian-12-hard-min.txt
~/Integrity/2025-09-01/debian-12-work.txt
~/Integrity/2025-09-01/fedora-41-vpn-min.txt
~/Integrity/2025-09-01/dom0.tgz
```

## How to use (daily workflow)

- Let the timers run (default \~03:05 dom0, \~03:10 templates).
- To eyeball today’s results:

  ```bash
  qvm-run -p sys-integrity 'ls -lh ~/Integrity/$(date -I)'
  qvm-run -p sys-integrity 'sed -n "1,120p" ~/Integrity/$(date -I)/debian-12-hard.txt'
  ```

- To diff two days:

  ```bash
  qvm-run -p sys-integrity 'diff -u ~/Integrity/2025-08-31/debian-12-hard.txt ~/Integrity/2025-09-01/debian-12-hard.txt | less'
  ```

## When to use it

- After **template updates** (confirm nothing drifted).
- Before distributing a **new template** (prove state).
- During **incident response** (quick file-integrity signals without deploying heavy FIM everywhere).

## When _not_ to rely on it alone

- This is not a kernel-level HIDS. For continuous, tamper-evident monitoring, add **AIDE** or similar _inside templates_ (not dom0) if you need stronger guarantees. Keep it minimal. ([Qubes OS][5])

## Customization knobs

- **Scope**: Edit the handler to add/remove directories (e.g., add `/usr/local`, `/lib/modules`).
- **Timing**: Change `OnCalendar` in the two timers.
- **Policy**: File is `/etc/qubes/policy.d/31-integrity.policy` (4.2 style). Use the policy editor if preferred. ([Qubes OS Forum][6])

## Interpreting results (quick tips)

- `debsums -s` / `rpm -Va` lines mean package files changed vs. vendor metadata. False positives can occur (e.g., local config files). Review diffs, compare to update history.
- Hash sections (`BEGIN sha256 ...`) let you **baseline** and later **diff** line-by-line.

---
