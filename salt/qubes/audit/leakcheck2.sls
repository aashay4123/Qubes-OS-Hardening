# Extended leak test battery (Qubes 4.2.x)
# Writes PASS/FAIL rows to dom0:/var/lib/qubes/leakcheck/<YYYY-MM-DD>/results.csv

leakcheck-run:
  cmd.run:
    - name: |
        /bin/sh -eu
        OUTDIR="/var/lib/qubes/leakcheck/$(date -I)"
        mkdir -p "$OUTDIR"
        SUMMARY="$OUTDIR/summary.txt"
        CSV="$OUTDIR/results.csv"
        : > "$SUMMARY"
        echo "id,name,vm,result,detail" > "$CSV"

        pass(){ echo "[$1] PASS  - $2 ($3)"; echo "$1,$2,$3,PASS," >>"$CSV"; }
        fail(){ echo "[$1] FAIL  - $2 ($3) -> $4"; echo "$1,$2,$3,FAIL,$4" >>"$CSV"; }
        note(){ echo "[$1] NOTE  - $2 ($3) -> $4"; echo "$1,$2,$3,NOTE,$4" >>"$CSV"; }

        rr(){ VM="$1"; shift; qvm-run -p --color-output=none --timeout=60000 "$VM" "$*"; }

        # --- Original core tests (1..18) ---
        # 01 stub resolver in personal
        if rr personal 'cat /etc/resolv.conf 2>/dev/null | grep -E "10\\.139\\.|10\\.137\\." -q'; then
          pass 1 "Qubes stub resolver in use" personal
        else
          fail 1 "Qubes stub resolver in use" personal "resolv.conf lacks 10.139.x.1/10.137.x.1"
        fi

        # 02 no plaintext UDP/53 leaving sys-dns (requires tcpdump+capinfos)
        if rr sys-dns 'command -v tcpdump >/dev/null 2>&1 && command -v capinfos >/dev/null 2>&1'; then
          rr sys-dns 'pkill tcpdump 2>/dev/null || true'
          rr sys-dns 'sh -c "tcpdump -n -i any udp port 53 -w /tmp/dnsleak.pcap & echo $! >/tmp/dns.pid; sleep 1"'
          rr personal 'sh -c "for i in 1 2 3; do getent hosts qubes-os.org >/dev/null; done"'
          rr sys-dns 'sleep 2; test -f /tmp/dns.pid && kill $(cat /tmp/dns.pid) 2>/dev/null || true'
          PKTS="$(rr sys-dns 'sh -c "test -f /tmp/dnsleak.pcap && capinfos -c /tmp/dnsleak.pcap 2>/dev/null | awk '\''/Number of packets/{print $4}'\'' || echo 0"')"
          [ "${PKTS:-0}" = "0" ] && pass 2 "No plaintext DNS leaves sys-dns (udp/53)" sys-dns || fail 2 "Plain DNS seen (udp/53)" sys-dns "$PKTS pkts"
        else note 2 "dnsleak passive probe" sys-dns "tcpdump/capinfos not present"; fi

        # 03 IPv6 disabled/unusable in personal
        V6R="$(rr personal 'ip -6 route 2>/dev/null | wc -l || true')"
        if [ "$V6R" -eq 0 ]; then pass 3 "No IPv6 route in personal" personal
        else if rr personal 'curl -6 --max-time 3 https://ifconfig.co >/dev/null 2>&1'; then
               fail 3 "IPv6 leak" personal "curl -6 succeeded"
             else pass 3 "IPv6 not usable outward" personal; fi
        fi

        # 04 sys-vpn tun default
        if rr sys-vpn 'ip -o link show | grep -q "tun"'; then
          DEV="$(rr sys-vpn 'ip route get 1.1.1.1 2>/dev/null | sed -n "s/.* dev \\([a-z0-9]\\+\\).*/\\1/p" | head -1 || true')"
          echo "$DEV" | grep -q '^tun' && pass 4 "Default egress via VPN tun" sys-vpn || fail 4 "Default via tun" sys-vpn "dev=$DEV"
        else fail 4 "VPN tun present" sys-vpn "no tun iface"; fi

        # 05 VPN killswitch mentions tun
        if rr sys-vpn 'nft list ruleset 2>/dev/null | grep -q "oifname \\\"tun"'; then
          pass 5 "Killswitch references tun" sys-vpn
        else note 5 "Killswitch references tun" sys-vpn "no oifname tun match"
        fi

        # 06 personal outbound v4 works
        rr personal 'curl -4 --max-time 5 https://ifconfig.io >/dev/null 2>&1' && pass 6 "Outbound IPv4 reachable" personal || fail 6 "Outbound IPv4 reachable" personal "curl -4 failed"

        # 07 Whonix egress Tor
        rr anon-whonix 'curl --max-time 10 -s https://check.torproject.org/api/ip | grep -q "\"IsTor\"\\s*:\\s*true"' && pass 7 "Whonix egress is Tor" anon-whonix || note 7 "Whonix egress Tor" anon-whonix "API not reachable or not Tor"

        # 08 nft inet qubes present
        rr sys-firewall 'nft list ruleset | grep -q "table inet qubes"' && pass 8 "nft table inet qubes present" sys-firewall || fail 8 "nft inet qubes" sys-firewall "not found"

        # 09 STUN WebRTC surface passive
        if rr sys-firewall 'command -v tcpdump >/dev/null 2>&1 && command -v capinfos >/dev/null 2>&1'; then
          rr sys-firewall 'sh -c "tcpdump -n -i any udp port 3478 -G 3 -W 1 -w /tmp/stun.pcap >/dev/null 2>&1"'
          SPK="$(rr sys-firewall 'sh -c "test -f /tmp/stun.pcap && capinfos -c /tmp/stun.pcap 2>/dev/null | awk '\''/Number of packets/{print $4}'\'' || echo 0"')"
          [ "${SPK:-0}" = "0" ] && pass 9 "No unsolicited STUN seen" sys-firewall || note 9 "STUN seen" sys-firewall "$SPK pkts"
        else note 9 "STUN probe" sys-firewall "tcpdump/capinfos not present"; fi

        # 10 NTP chatter
        if rr sys-firewall 'command -v tcpdump >/dev/null 2>&1 && command -v capinfos >/dev/null 2>&1'; then
          rr sys-firewall 'sh -c "tcpdump -n -i any udp port 123 -G 3 -W 1 -w /tmp/ntp.pcap >/dev/null 2>&1"'
          NPK="$(rr sys-firewall 'sh -c "test -f /tmp/ntp.pcap && capinfos -c /tmp/ntp.pcap 2>/dev/null | awk '\''/Number of packets/{print $4}'\'' || echo 0"')"
          [ "${NPK:-0}" = "0" ] && pass 10 "No stray NTP" sys-firewall || note 10 "NTP traffic exists" sys-firewall "$NPK pkts"
        else note 10 "NTP probe" sys-firewall "tcpdump/capinfos not present"; fi

        # 11 mDNS listener in personal
        rr personal 'ss -H -lun | grep -q 5353' && note 11 "mDNS listener present" personal "disable if unneeded" || pass 11 "No mDNS listener" personal

        # 12 IPv6 sysctl all=1
        rr personal 'sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q "^1$"' && pass 12 "IPv6 disabled via sysctl" personal || note 12 "IPv6 sysctl" personal "enabled/default"

        # 13 sys-dns not using :53
        rr sys-dns 'ss -H -uap | awk "/:53 /{f=1} END{exit(f?0:1)}"' && fail 13 "sys-dns using udp:53" sys-dns "found :53 socket" || pass 13 "sys-dns not using udp:53" sys-dns

        # 14 direct DNS bypass
        if rr personal 'command -v dig >/dev/null 2>&1'; then
          rr personal 'dig +time=2 +tries=1 @1.1.1.1 example.com >/dev/null 2>&1' && note 14 "Direct DNS @1.1.1.1 succeeded" personal "investigate path" || pass 14 "Direct DNS bypass blocked/unusable" personal
        else note 14 "dig not present" personal "skipped"; fi

        # 15 untrusted cannot reach RFC1918 TCP/80
        OUT="$(rr untrusted 'bash -lc "timeout 2 bash -c '\''> /dev/tcp/192.168.0.1/80'\'' 2>/dev/null && echo ok || echo no"')" || OUT="no"
        [ "$OUT" = "no" ] && pass 15 "LAN access blocked from untrusted" untrusted || note 15 "LAN reachable from untrusted" untrusted "tighten rules"

        # 16 sys-net MAC policy advisory
        MACPOL="$(rr sys-net 'nmcli -g 802-3-ethernet.cloned-mac-address,802-11-wireless.cloned-mac-address connection show 2>/dev/null | tr -s ":" "," || true')"
        echo "$MACPOL" | grep -Eiq '(random|stable)' && pass 16 "MAC randomization policy present" sys-net || note 16 "MAC randomization" sys-net "consider enabling"

        # 17 nft present sys-firewall
        rr sys-firewall 'nft -v >/dev/null 2>&1' && pass 17 "nft present" sys-firewall || fail 17 "nft present" sys-firewall "missing"

        # 18 Whonix no IPv6 route
        V6W="$(rr anon-whonix 'ip -6 route 2>/dev/null | wc -l || true')"
        [ "$V6W" -eq 0 ] && pass 18 "Whonix has no IPv6 route" anon-whonix || note 18 "Whonix IPv6 route exists" anon-whonix "$V6W lines"

        # --- Second-tier probes (19..35) ---

        # 19 DoH attempt from personal (success only if you intend it)
        if rr personal 'command -v curl >/dev/null 2>&1'; then
          rr personal 'curl -sS --max-time 4 -H "accept: application/dns-json" "https://cloudflare-dns.com/dns-query?name=example.com&type=A" >/dev/null' \
            && note 19 "DoH reachable from personal" personal "OK if intended; block otherwise" \
            || pass 19 "DoH not trivially reachable" personal
        else note 19 "curl not present" personal "skipped"; fi

        # 20 HTTP cleartext attempt (port 80)
        rr personal 'curl -sS --max-time 4 http://neverssl.com >/dev/null' \
          && note 20 "HTTP cleartext reachable" personal "expected if not blocked; consider policy" \
          || pass 20 "HTTP cleartext blocked/unreachable" personal

        # 21 ICMP egress via intended path (personal)
        rr personal 'ping -c1 -W2 1.1.1.1 >/dev/null 2>&1' \
          && pass 21 "ICMP egress working (personal)" personal \
          || note 21 "ICMP egress blocked" personal "OK if policy blocks pings"

        # 22 IPv6 Router Advertisement seen in sys-net (advisory)
        rr sys-net 'command -v rdisc6 >/dev/null 2>&1' \
          && ( rr sys-net 'timeout 3 rdisc6 -q -r 1 -w 1 -m eth0 >/dev/null 2>&1' \
               && note 22 "IPv6 RA observed on sys-net" sys-net "check v6 policy" || pass 22 "No IPv6 RA observed quickly" sys-net ) \
          || note 22 "rdisc6 not present" sys-net "skipped"

        # 23 LLMNR (udp/5355) listener in personal
        rr personal 'ss -H -lun | grep -q ":5355"' \
          && note 23 "LLMNR listener present" personal "disable if not needed" \
          || pass 23 "No LLMNR listener" personal

        # 24 SSDP/UPnP chatter from apps (udp/1900) passive
        if rr sys-firewall 'command -v tcpdump >/dev/null 2>&1 && command -v capinfos >/dev/null 2>&1'; then
          rr sys-firewall 'sh -c "tcpdump -n -i any udp port 1900 -G 3 -W 1 -w /tmp/ssdp.pcap >/dev/null 2>&1"'
          UPK="$(rr sys-firewall 'sh -c "test -f /tmp/ssdp.pcap && capinfos -c /tmp/ssdp.pcap 2>/dev/null | awk '\''/Number of packets/{print $4}'\'' || echo 0"')"
          [ "${UPK:-0}" = "0" ] && pass 24 "No SSDP chatter seen" sys-firewall || note 24 "SSDP seen" sys-firewall "$UPK pkts"
        else note 24 "SSDP probe" sys-firewall "tcpdump/capinfos not present"; fi

        # 25 Captive-portal probe reachable with VPN up (advisory)
        rr sys-vpn 'ip -o link show | grep -q "tun"' >/dev/null 2>&1 || note 25 "VPN not up; captive probe skipped" sys-vpn "start VPN and re-run"
        rr personal 'curl -sS --max-time 4 http://connectivitycheck.gstatic.com/generate_204 >/dev/null' \
          && note 25 "Captive probe reachable via current chain" personal "OK if intended" \
          || pass 25 "Captive probe blocked/unreachable" personal

        # 26 NTP policy lock (try non-allowed hostname; expect fail)
        rr personal 'timeout 3 ntpdate -q pool.ntp.org >/dev/null 2>&1' \
          && note 26 "NTP reachable to pool.ntp.org" personal "lock if undesired" \
          || pass 26 "NTP not trivially reachable" personal

        # 27 DNS over TCP fallback (dig +tcp to 1.1.1.1)
        if rr personal 'command -v dig >/dev/null 2>&1'; then
          rr personal 'dig +tcp +time=2 +tries=1 @1.1.1.1 example.com >/dev/null 2>&1' \
            && note 27 "DNS over TCP reachable (1.1.1.1)" personal "OK if policy allows" \
            || pass 27 "DNS over TCP not trivially reachable" personal
        else note 27 "dig not present" personal "skipped"; fi

        # 28 Split-tunnel sanity (if you run two chains, advisory)
        note 28 "Split-tunnel sanity" work "ensure VM labels map to right NetVM chain"

        # 29 Tor workstation cannot reach clearnet direct (curl http)
        rr anon-whonix 'curl -sS --max-time 5 http://neverssl.com >/dev/null 2>&1' \
          && note 29 "Whonix clearnet reachable (HTTP)" anon-whonix "verify Tor enforcement" \
          || pass 29 "Whonix blocked from direct clearnet (HTTP)" anon-whonix

        # 30 Reverse-DNS PTR for RFC1918 from sys-dns (should not leak)
        rr sys-dns 'host 1.0.168.192.in-addr.arpa 2>/dev/null' \
          && note 30 "PTR lookup attempt possible" sys-dns "ensure local zones are filtered" \
          || pass 30 "No PTR for RFC1918 (expected)" sys-dns

        # 31 SMTP egress block (25/587)
        rr personal 'bash -lc "timeout 2 bash -c '\''> /dev/tcp/1.1.1.1/25'\''"' >/dev/null 2>&1 \
          && note 31 "SMTP 25 reachable" personal "block unless intended" || pass 31 "SMTP 25 not reachable" personal
        rr personal 'bash -lc "timeout 2 bash -c '\''> /dev/tcp/1.1.1.1/587'\''"' >/dev/null 2>&1 \
          && note 31 "SMTP 587 reachable" personal "block unless intended" || pass 31 "SMTP 587 not reachable" personal

        # 32 Non-standard DNS ports (853 DoT)
        rr personal 'bash -lc "timeout 2 bash -c '\''> /dev/tcp/1.1.1.1/853'\''"' >/dev/null 2>&1 \
          && note 32 "DoT port 853 reachable" personal "OK if intended" || pass 32 "DoT 853 blocked/unreachable" personal

        # 33 Multicast/broadcast egress from apps (passive)
        if rr sys-firewall 'command -v tcpdump >/dev/null 2>&1 && command -v capinfos >/dev/null 2>&1'; then
          rr sys-firewall 'sh -c "tcpdump -n -i any multicast or broadcast -G 3 -W 1 -w /tmp/mcast.pcap >/dev/null 2>&1"'
          MPK="$(rr sys-firewall 'sh -c "test -f /tmp/mcast.pcap && capinfos -c /tmp/mcast.pcap 2>/dev/null | awk '\''/Number of packets/{print $4}'\'' || echo 0"')"
          [ "${MPK:-0}" = "0" ] && pass 33 "No multicast/broadcast seen" sys-firewall || note 33 "Multicast/Broadcast seen" sys-firewall "$MPK pkts"
        else note 33 "multicast probe" sys-firewall "tcpdump/capinfos not present"; fi

        # 34 Hidden IPv6 fallback when VPN down (advisory)
        note 34 "Hidden v6 fallback check" sys-vpn "disable VPN, re-run 3/21/22 to confirm no v6 egress"

        # 35 Known DoH bootstrap IPs reachable (advisory)
        rr personal 'bash -lc "timeout 2 bash -c '\''> /dev/tcp/1.1.1.1/443'\''"' >/dev/null 2>&1 \
          && note 35 "DoH bootstrap (1.1.1.1:443) reachable" personal "OK if intended" || pass 35 "DoH bootstrap blocked/unreachable" personal

        echo "Leakcheck completed $(date -Is)" > "$SUMMARY"
        echo "See $CSV for per-test results."
    - cwd: /
