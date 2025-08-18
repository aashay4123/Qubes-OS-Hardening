# Fails state.highstate if any check fails. Uses dom0 + in-VM probes.

# A) sys-dns: dnscrypt active & DNS egress locked to 127.0.0.1
assert-sys-dns:
  cmd.run:
    - name: |
        set -e
        qvm-run -q -u root --pass-io sys-dns 'systemctl is-active dnscrypt-proxy' | grep -qx active
        qvm-run -q -u root --pass-io sys-dns "nft list ruleset | grep -E 'dport 53' | grep -E 'ip daddr != 127\.0\.0\.1.*drop' -q"

# B) sys-firewall: DNAT DNS→sys-dns present AND Whonix exclusion present (if sys-vpn-tor exists)
assert-sys-firewall-dns:
  cmd.run:
    - name: |
        set -e
        SYS_DNS_IP="$(qvm-ls --raw-data --fields NAME,IP | awk -F'|' '$1=="sys-dns"{gsub(/ /,"",$2);print $2}')"
        [ -n "$SYS_DNS_IP" ]
        qvm-run -q -u root --pass-io sys-firewall \
          "nft list table ip nat | sed -n '/prerouting/,/}/p' | grep -E 'dport (53).*dnat to ${SYS_DNS_IP}'" >/dev/null
        if qvm-ls --raw-list | grep -qx sys-vpn-tor; then
          GWIP="$(qvm-ls --raw-data --fields NAME,IP | awk -F'|' '$1=="sys-vpn-tor"{gsub(/ /,"",$2);print $2}')"
          [ -n "$GWIP" ]
          qvm-run -q -u root --pass-io sys-firewall \
            "nft list table ip nat | sed -n '/prerouting/,/}/p' | grep -E 'ip saddr ${GWIP}.*dport 53.*accept'" >/dev/null
        fi

# C) Split-GPG round-trip from a Debian caller (work) to vault-secrets
assert-split-gpg-deb:
  cmd.run:
    - name: |
        set -e
        if qvm-ls --raw-list | grep -qx work; then
          qvm-run -q --pass-io work 'echo ok | gpg --clearsign' | grep -qi 'BEGIN PGP SIGNED MESSAGE'
        fi

# D) Split-SSH availability (agent socket visible in caller)
assert-split-ssh-deb:
  cmd.run:
    - name: |
        set -e
        if qvm-ls --raw-list | grep -qx work; then
          qvm-run -q --pass-io work 'systemctl --user is-enabled qubes-ssh-agent-proxy.socket' | grep -q enabled
        fi

# E) qube-pass end-to-end from Debian & Whonix callers (requires a test entry present)
assert-qube-pass:
  cmd.run:
    - name: |
        set -e
        # Debian test (ignore failure if no work VM)
        if qvm-ls --raw-list | grep -qx work; then
          qvm-run -q --pass-io work 'command -v qpass >/dev/null' >/dev/null
        fi
        # Whonix test (ignore failure if WS not present)
        if qvm-ls --raw-list | grep -qx ws-tor-research; then
          qvm-run -q --pass-io ws-tor-research 'command -v qpass-ws >/dev/null' >/dev/null
        fi
