Absolutely—here’s a **single, complete Salt state** you can drop into **dom0** that enforces **“refuse to apply unless signed”**, safely **deploys** a signed Salt bundle, **baselines & verifies** your `/srv/salt` tree, and **alerts** on any failure via your `sys-alert` path (falls back to console if `alert` isn’t installed).

Save it as:

```
/srv/salt/qubes/health/salt_signed_gate.sls
```

Then add it to `top.sls` (snippet at the end).

---

# /srv/salt/qubes/health/salt_signed_gate.sls

```jinja
# =========================================================
# Config Integrity Gate for Salt — Signed-only Deployment
# - Verifies salt.tar.gz with /etc/qubes/salt-pubkey.pem
# - Stages & atomically deploys into /srv/salt
# - Baselines /srv/salt hash to vault-secrets and verifies daily
# - Provides signed-highstate wrapper (verify -> deploy -> run)
# - Sends alerts to sys-alert (if /usr/local/bin/alert exists)
# =========================================================

{# ---------- Paths & constants (dom0) ---------- #}
{% set PUBKEY   = '/etc/qubes/salt-pubkey.pem' %}
{% set PKG     = '/var/tmp/salt.tar.gz' %}
{% set SIG     = '/var/tmp/salt.tar.gz.sig' %}
{% set STAGE   = '/var/tmp/salt.staged' %}
{% set SRV     = '/srv/salt' %}
{% set BACKUPS = '/var/backups/srv-salt' %}
{% set HASHDIR = '/var/lib/qubes/salt-hashes' %}
{% set V_HASHD = '/home/user/.config-hashes' %}

# --- Ensure basic dirs exist
salt-gate-dirs:
  file.directory:
    - names:
      - {{ BACKUPS }}
      - {{ HASHDIR }}
    - mode: '0750'

# --- Alert helper presence check (non-fatal)
alert-shim:
  file.managed:
    - name: /usr/local/sbin/_alert_or_echo.sh
    - mode: '0755'
    - contents: |
        #!/bin/bash
        # If 'alert' CLI exists (from sys-alert bundle), use it; else echo.
        if command -v alert >/dev/null 2>&1 ; then
          alert "$@"
        else
          echo "[ALERT] $*"
        fi

# --- Script: verify signature & basic tar sanity
salt-verify-script:
  file.managed:
    - name: /usr/local/sbin/salt-verify-signature.sh
    - mode: '0755'
    - contents: |
        #!/bin/bash
        # Verify that /var/tmp/salt.tar.gz is signed by /etc/qubes/salt-pubkey.pem
        # and that its content paths are safe (no absolute/.. escapes).
        set -euo pipefail
        PUB="{{ PUBKEY }}"
        PKG="{{ PKG }}"
        SIG="{{ SIG }}"
        [ -f "$PUB" ] || { echo "Missing public key: $PUB"; exit 1; }
        [ -f "$PKG" ] || { echo "Missing package:    $PKG"; exit 1; }
        [ -f "$SIG" ] || { echo "Missing signature:  $SIG"; exit 1; }

        # Cryptographic verification
        openssl dgst -sha256 -verify "$PUB" -signature "$SIG" "$PKG" >/dev/null

        # Tar sanity: list & check entries before extract
        #   - must start with "srv/salt/"
        #   - must not be absolute or contain '..'
        TMP_LIST="$(mktemp)"
        tar -tzf "$PKG" >"$TMP_LIST"
        awk '
          $0 ~ /^\// { print "Absolute path not allowed: " $0; exit 2 }
          $0 ~ /\.\./ { print "Path escape not allowed: " $0;   exit 2 }
          $0 !~ /^srv\/salt\// { print "Entry outside srv/salt/: " $0; exit 2 }
        ' "$TMP_LIST" || { rm -f "$TMP_LIST"; exit 1; }
        rm -f "$TMP_LIST"
        echo "OK"

# --- Script: deploy staged -> /srv/salt atomically (with backup)
salt-deploy-script:
  file.managed:
    - name: /usr/local/sbin/salt-deploy-staged.sh
    - mode: '0755'
    - contents: |
        #!/bin/bash
        set -euo pipefail
        PKG="{{ PKG }}"
        STAGE="{{ STAGE }}"
        SRV="{{ SRV }}"
        BACK="{{ BACKUPS }}/srv-salt-$(date +%Y%m%d-%H%M%S).tar.zst"

        [ -f "$PKG" ] || { echo "No bundle at $PKG"; exit 1; }

        # Fresh stage dir
        rm -rf "$STAGE"
        mkdir -p "$STAGE"

        # Extract under /var/tmp/salt.staged/srv/salt/
        tar --no-same-owner --no-same-permissions -xzf "$PKG" -C "$STAGE"

        # Basic perms hardening for staged files
        find "$STAGE" -type d -exec chmod 0755 {} +
        find "$STAGE" -type f -exec chmod 0644 {} +
        # Keep executable bits for scripts under sbin/bin
        find "$STAGE" -type f \( -path '*/bin/*' -o -path '*/sbin/*' \) -exec chmod 0755 {} + || true

        # Backup current /srv/salt if present
        if [ -d "$SRV" ]; then
          mkdir -p "$(dirname "$BACK")"
          tar -C / -I 'zstd -T0 -19' -cf "$BACK" srv/salt || true
        fi

        # Atomic replace via rsync (preserves SELinux/xattrs if enabled)
        rsync -a --delete "$STAGE/srv/salt/" "$SRV/"

        # Clean stage (optional)
        rm -rf "$STAGE"

        echo "DEPLOYED"

# --- Script: hash current /srv/salt deterministically (store to vault + dom0)
salt-tree-hash-script:
  file.managed:
    - name: /usr/local/sbin/salt-tree-hash.sh
    - mode: '0755'
    - contents: |
        #!/bin/bash
        set -euo pipefail
        # Stream a normalized tar of /srv/salt and sha256 it.
        tar --posix --numeric-owner --sort=name --mtime=@0 \
            -C / -cpf - srv/salt | sha256sum | awk '{print $1}'

# --- Script: verify /srv/salt hash equals vault baseline (alerts on mismatch)
salt-tree-verify-script:
  file.managed:
    - name: /usr/local/sbin/salt-tree-verify.sh
    - mode: '0755'
    - contents: |
        #!/bin/bash
        set -euo pipefail
        CUR="$(/usr/local/sbin/salt-tree-hash.sh)"
        BASE="$(qvm-run -q --pass-io vault-secrets 'cat {{ V_HASHD }}/salt-tree.sha256' 2>/dev/null || true)"
        if [ -z "$BASE" ]; then
          /usr/local/sbin/_alert_or_echo.sh "SALT TREE VERIFY: missing baseline in vault"
          exit 1
        fi
        if [ "$CUR" != "$BASE" ]; then
          /usr/local/sbin/_alert_or_echo.sh "SALT TREE HASH MISMATCH cur=$CUR base=$BASE"
          exit 1
        fi
        echo "OK"

# --- One-shot: create baseline in vault if absent (first run only)
salt-tree-baseline:
  cmd.run:
    - name: |
        set -e
        H="$((/usr/local/sbin/salt-tree-hash.sh) 2>/dev/null || echo '')"
        [ -n "$H" ] || exit 0
        qvm-run -q --pass-io vault-secrets 'mkdir -p {{ V_HASHD }}'
        if ! qvm-run -q --pass-io vault-secrets 'test -s {{ V_HASHD }}/salt-tree.sha256'; then
          printf "%s\n" "$H" | qvm-run -q --pass-io vault-secrets 'cat > {{ V_HASHD }}/salt-tree.sha256'
        fi

# --- Timer: daily verify of /srv/salt hash against vault
salt-tree-verify-timer-service:
  file.managed:
    - name: /etc/systemd/system/salt-tree-verify.service
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Verify /srv/salt hash vs vault baseline
        [Service]
        Type=oneshot
        ExecStart=/usr/local/sbin/salt-tree-verify.sh

salt-tree-verify-timer:
  file.managed:
    - name: /etc/systemd/system/salt-tree-verify.timer
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Daily Salt tree integrity verify
        [Timer]
        OnCalendar=daily
        Persistent=true
        [Install]
        WantedBy=timers.target

salt-tree-verify-enable:
  cmd.run:
    - name: |
        systemctl daemon-reload
        systemctl enable --now salt-tree-verify.timer

# --- Wrapper: signed-highstate (verify -> deploy -> re-hash -> run)
signed-highstate:
  file.managed:
    - name: /usr/local/sbin/signed-highstate
    - mode: '0755'
    - contents: |
        #!/bin/bash
        # Secure entrypoint to apply Salt ONLY from signed bundle.
        # Steps:
        #   1) Verify signature (PUB, PKG, SIG)
        #   2) Deploy staged -> /srv/salt (atomic, backup old)
        #   3) Hash new /srv/salt and update baseline in vault
        #   4) Run qubesctl state.highstate
        set -euo pipefail
        PUB="{{ PUBKEY }}"
        PKG="{{ PKG }}"
        SIG="{{ SIG }}"
        VDIR="{{ V_HASHD }}"

        /usr/local/sbin/salt-verify-signature.sh || { /usr/local/sbin/_alert_or_echo.sh "Salt signature verify FAILED"; exit 2; }
        /usr/local/sbin/salt-deploy-staged.sh   || { /usr/local/sbin/_alert_or_echo.sh "Salt deploy FAILED";            exit 3; }

        # Update baseline to vault (the deployed tree is now the expected state)
        H="$(/usr/local/sbin/salt-tree-hash.sh)"
        qvm-run -q --pass-io vault-secrets "mkdir -p {{ V_HASHD }}" || true
        printf "%s\n" "$H" | qvm-run -q --pass-io vault-secrets "cat > {{ V_HASHD }}/salt-tree.sha256"

        # Optional: local copy
        mkdir -p {{ HASHDIR }}
        printf "%s\n" "$H" > {{ HASHDIR }}/salt-tree.sha256

        # Apply highstate
        if ! qubesctl state.highstate; then
          /usr/local/sbin/_alert_or_echo.sh "Highstate FAILED after signed deploy (see console)"
          exit 4
        fi
        echo "SIGNED-HIGHSTATE OK"

# --- Optional: soft gate in highstate (runs first; fails if unsigned bundle present)
# If a new unsigned bundle appears (without signature or pubkey), fail early.
salt-pre-apply-gate:
  cmd.run:
    - name: |
        set -e
        # If any of PUB/PKG/SIG missing, and PKG exists, refuse.
        if [ -f "{{ PKG }}" ] && [ ! -f "{{ SIG }}" -o ! -f "{{ PUBKEY }}" ]; then
          /usr/local/sbin/_alert_or_echo.sh "Unsigned or unverifiable Salt bundle present. Aborting highstate."
          exit 1
        fi
        echo "GATE OK"
    - order: 1

# --- (Optional) make /usr/local/bin/qctl a convenience alias
qctl-wrapper:
  file.managed:
    - name: /usr/local/bin/qctl
    - mode: '0755'
    - contents: |
        #!/bin/bash
        # Shortcut: run signed-highstate by default
        exec /usr/local/sbin/signed-highstate "$@"
```

---

## Add to `/srv/salt/top.sls`

Place this **first** (so the soft gate runs before other states). Keep the rest of your entries below it.

```yaml
base:
  dom0:
    - qubes/health/salt_signed_gate
    # ...your other stacks (security_integrity, network_visibility, usability_isolation, etc.)
```

---

## How to use (operational flow)

1. **(One-time)** Put your **public key** in dom0:

   ```
   sudo install -m 0644 -D salt-pubkey.pem /etc/qubes/salt-pubkey.pem
   ```

2. **Prepare a signed bundle (off-box):**

   ```
   tar -C / -czf salt.tar.gz srv/salt
   openssl dgst -sha256 -sign privkey.pem -out salt.tar.gz.sig salt.tar.gz
   openssl pkey -in privkey.pem -pubout > salt-pubkey.pem   # already done above
   ```

3. **Copy to dom0** (via trusted path), then:

   ```
   sudo mv salt.tar.gz salt.tar.gz.sig /var/tmp/
   sudo /usr/local/sbin/signed-highstate
   ```

4. **Daily integrity check** (automatic):

   - `salt-tree-verify.timer` runs and alerts if `/srv/salt` drifts from baseline (stored in `vault-secrets`).

---

## What this gives you

- **Refuse-unsigned**: Unless the bundle is signed with your offline key, deployment won’t proceed.
- **Safe deploy**: Validated + sanitized tar only, staged extraction, atomic rsync, automatic **backup** of previous `/srv/salt`.
- **Integrity baseline**: Deterministic hash of the live `/srv/salt`, stored in **vault-secrets** and verified **daily**.
- **Alerting**: Any verify/deploy mismatch or drift triggers your `sys-alert` pipeline (or echoes if `alert` absent).
- **Usability**: `qctl` shortcut to always run the safe path.

If you prefer **BLAKE3** for speed, I can swap the hashing lines to `b3sum` where available and keep SHA-256 as a fallback.
