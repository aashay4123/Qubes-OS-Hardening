# Baseline + diff helper for sys-integrity (Qubes 4.2.x)
# - Stores baseline in:  sys-integrity:~/Integrity/baseline/
# - Writes daily diffs:  sys-integrity:~/Integrity/<YYYY-MM-DD>/_diff/
# Run after your sys-integrity collector has produced daily files.

sys-integrity-diff-install:
  qvm.run:
    - name: sys-integrity
    - user: root
    - cmd: |
        /bin/sh -c '
        install -d -m 0755 /usr/local/bin /etc/systemd/system
        install -d -m 0755 /home/user/Integrity/baseline

        # --- extract sha blocks from a template report into a flat list ---
        cat > /usr/local/bin/integrity-extract-sha.sh << "EOF"
        #!/bin/sh
        set -eu
        IN="$1"    # e.g., ~/Integrity/2025-09-01/debian-12-hard.txt
        awk "/^BEGIN sha256/{flag=1;next}/^END sha256/{flag=0}flag" "$IN" | sed "s/  */ /g"
        EOF
        chmod 0755 /usr/local/bin/integrity-extract-sha.sh

        # --- create/update baseline from the latest day present ---
        cat > /usr/local/bin/integrity-baseline.sh << "EOF"
        #!/bin/sh
        set -eu
        BASE="$HOME/Integrity"
        BL="$BASE/baseline"
        LASTDAY="$(ls -1 "$BASE" | grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}$" | sort | tail -n1 || true)"
        [ -n "$LASTDAY" ] || { echo "No daily reports yet."; exit 0; }
        DAYDIR="$BASE/$LASTDAY"
        mkdir -p "$BL"

        for f in "$DAYDIR"/*.txt; do
          [ -f "$f" ] || continue
          vm="$(basename "$f" .txt)"
          /usr/local/bin/integrity-extract-sha.sh "$f" | sort > "$BL/${vm}.sha"
        done

        # dom0: unpack and record etc/boot hashes as baseline, if present
        if [ -f "$DAYDIR/dom0.tgz" ]; then
          TMP="$(mktemp -d)"
          tar -xzf "$DAYDIR/dom0.tgz" -C "$TMP"
          [ -f "$TMP/sha256-etc.txt" ]  && sort "$TMP/sha256-etc.txt"  > "$BL/dom0-etc.sha"
          [ -f "$TMP/sha256-boot.txt" ] && sort "$TMP/sha256-boot.txt" > "$BL/dom0-boot.sha"
          rm -rf "$TMP"
        fi

        echo "Baseline updated from $LASTDAY into $BL"
        EOF
        chmod 0755 /usr/local/bin/integrity-baseline.sh

        # --- diff today vs baseline; write _diff/ per-VM report files ---
        cat > /usr/local/bin/integrity-diff.sh << "EOF"
        #!/bin/sh
        set -eu
        BASE="$HOME/Integrity"
        BL="$BASE/baseline"
        TODAY="$(date -I)"
        DAYDIR="$BASE/$TODAY"
        OUTDIR="$DAYDIR/_diff"
        mkdir -p "$OUTDIR"

        # helper: unified diff with headings for added/changed/removed
        _diff_sets() {
          # args: <baseline> <current> <label> <out>
          B="$1"; C="$2"; LBL="$3"; OUT="$4"
          touch "$B" "$C"
          # mark by path
          awk "{print \$2,\$1}" "$B" | sort > "$OUT/.b.$$"
          awk "{print \$2,\$1}" "$C" | sort > "$OUT/.c.$$"
          comm -23 "$OUT/.c.$$" "$OUT/.b.$$" > "$OUT/.added.$$"    # present now, not in baseline
          comm -13 "$OUT/.c.$$" "$OUT/.b.$$" > "$OUT/.removed.$$"  # present in baseline, not now
          join -j1 "$OUT/.b.$$" "$OUT/.c.$$" 2>/dev/null | awk '"'"'{ if ($2!=$3) print $1"  baseline="$2"  current="$3 }'"'"' > "$OUT/.changed.$$"
          {
            echo "### $LBL"
            echo "# ADDED:"
            sed "s/^/+ /" "$OUT/.added.$$"
            echo "# REMOVED:"
            sed "s/^/- /" "$OUT/.removed.$$"
            echo "# CHANGED (hash mismatch):"
            cat "$OUT/.changed.$$"
          } >> "$OUT/REPORT.txt"
          rm -f "$OUT/.b.$$" "$OUT/.c.$$" "$OUT/.added.$$" "$OUT/.removed.$$" "$OUT/.changed.$$"
        }

        # templates
        for f in "$DAYDIR"/*.txt; do
          [ -f "$f" ] || continue
          vm="$(basename "$f" .txt)"
          CUR="$OUTDIR/${vm}.current.sha"
          BLF="$BL/${vm}.sha"
          /usr/local/bin/integrity-extract-sha.sh "$f" | sort > "$CUR"
          mkdir -p "$OUTDIR/${vm}"
          : > "$OUTDIR/${vm}/REPORT.txt"
          _diff_sets "$BLF" "$CUR" "$vm (/etc and /etc/qubes)" "$OUTDIR/${vm}"
        done

        # dom0: if we have both sides, diff etc and boot
        if [ -f "$DAYDIR/dom0.tgz" ]; then
          TMP="$(mktemp -d)"
          tar -xzf "$DAYDIR/dom0.tgz" -C "$TMP"
          if [ -f "$TMP/sha256-etc.txt" ]; then
            sort "$TMP/sha256-etc.txt" > "$OUTDIR/dom0.current-etc.sha"
            mkdir -p "$OUTDIR/dom0"
            : > "$OUTDIR/dom0/REPORT.txt"
            _diff_sets "$BL/dom0-etc.sha" "$OUTDIR/dom0.current-etc.sha" "dom0 (/etc)" "$OUTDIR/dom0"
          fi
          if [ -f "$TMP/sha256-boot.txt" ]; then
            sort "$TMP/sha256-boot.txt" > "$OUTDIR/dom0.current-boot.sha"
            mkdir -p "$OUTDIR/dom0"
            _diff_sets "$BL/dom0-boot.sha" "$OUTDIR/dom0.current-boot.sha" "dom0 (/boot)" "$OUTDIR/dom0"
          fi
          rm -rf "$TMP"
        fi

        echo "Diffs written to $OUTDIR"
        EOF
        chmod 0755 /usr/local/bin/integrity-diff.sh

        # --- daily timer: run 03:18 baseline (if missing) and 03:22 diff ---
        cat > /etc/systemd/system/integrity-baseline.service << "EOF"
        [Unit]
        Description=Create/Update integrity baseline in sys-integrity
        [Service]
        Type=oneshot
        ExecStart=/usr/local/bin/integrity-baseline.sh
        EOF

        cat > /etc/systemd/system/integrity-baseline.timer << "EOF"
        [Unit]
        Description=Daily integrity baseline (03:18)
        [Timer]
        OnCalendar=*-*-* 03:18:00
        Persistent=true
        Unit=integrity-baseline.service
        [Install]
        WantedBy=timers.target
        EOF

        cat > /etc/systemd/system/integrity-diff.service << "EOF"
        [Unit]
        Description=Diff today vs baseline in sys-integrity
        [Service]
        Type=oneshot
        ExecStart=/usr/local/bin/integrity-diff.sh
        EOF

        cat > /etc/systemd/system/integrity-diff.timer << "EOF"
        [Unit]
        Description=Daily integrity diff (03:22)
        [Timer]
        OnCalendar=*-*-* 03:22:00
        Persistent=true
        Unit=integrity-diff.service
        [Install]
        WantedBy=timers.target
        EOF

        systemctl daemon-reload
        systemctl enable --now integrity-baseline.timer
        systemctl enable --now integrity-diff.timer
        '
  require:
    - qvm.prefs: sys-integrity-prefs
