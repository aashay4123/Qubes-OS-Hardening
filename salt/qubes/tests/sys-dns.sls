# Tests that:
#  - clients resolve OK
#  - sys-dns does NOT send plaintext :53 to the internet
#  - dnscrypt-proxy has active encrypted sessions (443/853)
# Adjust CLIENTS to your qubes present in this host.

# ---------- Config ----------
set-client-list:
  cmd.run:
    - name: /bin/true

# ---------- Sanity: chaining ----------
verify-chain:
  cmd.run:
    - name: /bin/sh -c '[ "$(qvm-prefs sys-firewall netvm)" = "sys-dns" ] && [ "$(qvm-prefs sys-dns netvm)" = "sys-net" ]'

# ---------- Start capture in sys-dns (no plaintext 53 should leave) ----------
sys-dns-start-capture:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: "/bin/sh -c 'rm -f /tmp/dns_out.pcap; timeout 6 tcpdump -ni any -w /tmp/dns_out.pcap port 53 and not host 127.0.0.1 and not net 10.139.0.0/16 and not net 10.137.0.0/16 >/dev/null 2>&1 &'"
    - require:
      - cmd: verify-chain

# ---------- Generate DNS lookups from clients ----------
clients-resolve:
  cmd.run:
    - name: >
        /bin/sh -c '
        FAIL=0;
        for vm in personal work pro untrusted; do
          if qvm-ls --raw-list | grep -qx "$vm"; then
            qvm-run -p -u root "$vm" "getent hosts qubes-os.org google.com github.com" >/dev/null || FAIL=1;
          fi
        done
        exit $FAIL
        '
    - require:
      - qvm: sys-dns-start-capture

# ---------- Check capture for plaintext egress (should be zero) ----------
no-plain53-egress:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: "/bin/sh -c 'CNT=$(tcpdump -nr /tmp/dns_out.pcap 2>/dev/null | wc -l); [ \"$CNT\" -eq 0 ]'"
    - require:
      - cmd: clients-resolve

# ---------- Check encrypted sessions to resolvers (DoT/DoH) ----------
dnscrypt-active-encrypted:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: "/bin/sh -c 'ss -tupon | grep -E \"dnscrypt|:853|:443\" >/dev/null'"
    - require:
      - cmd: clients-resolve

# ---------- Final summary ----------
tests-summary:
  cmd.run:
    - name: |
        /bin/sh -c '
        printf "\n=== sys-dns tests ===\n"
        printf "Chain  : sys-firewall -> sys-dns -> sys-net\n"
        printf "Plain53: none captured leaving sys-dns\n"
        printf "TLS/HTTPS upstream present from dnscrypt-proxy\n"
        '
    - require:
      - qvm: no-plain53-egress
      - qvm: dnscrypt-active-encrypted
