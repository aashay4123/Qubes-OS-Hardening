You’re right — thanks for calling that out. Let’s keep this **strictly 4.2.4** (the new **qrexec policy framework**, not the legacy 4.1 stuff).

In **Qubes OS 4.2.x** all RPC policies are unified in:

```
/etc/qubes/policy.d/
```

There is no need to poke at `/etc/qubes-rpc/policy/` anymore unless you manually carried old files over.

---

## 🔎 How to check _all_ RPC service policies in 4.2.4

### 1. Full lint across every service

```bash
sudo qubes-policy lint -vv
```

- Scans all `.policy` files in `/etc/qubes/policy.d/`.
- Flags bad syntax, unknown services, precedence issues.
- This is the **only** correct linter in 4.2.x.

---

### 2. Dump the effective policy for any service

```bash
qrexec-policy dump qubes.FileCopy
qrexec-policy dump qubes.ClipboardPaste
```

This shows the **final rules** Qubes applies (after merging default + your overrides).

---

### 3. Query a decision for a service

```bash
qrexec-policy query <target-vm> <source-vm> <service>
# Example
qrexec-policy query sys-firewall work qubes.FileCopy
```

- Lets you test how the policy will resolve **without executing it**.

---

### 4. Enumerate every service defined in your policies

```bash
grep -hE '^[a-zA-Z0-9_.-]+' /etc/qubes/policy.d/*.policy \
  | awk '{print $1}' | sort -u > /tmp/services.txt
```

Loop through them:

```bash
while read -r svc; do
    echo "=== $svc ==="
    qrexec-policy dump "$svc" || echo "No effective policy (falls back to default)"
    echo
done < /tmp/services.txt
```

Now you have a **complete RPC policy audit** for your 4.2.4 system.

---

✅ **Bottom line (4.2.4 only):**

- Use `qubes-policy lint` to check the whole tree.
- Use `qrexec-policy dump/query` for per-service visibility.
- All policies live in `/etc/qubes/policy.d/`, nothing else matters anymore.

---

Do you want me to hand you a **ready-to-run dom0 script** that does a full sweep (lint + dump every service) and writes it into a Markdown report you can read in one file?
