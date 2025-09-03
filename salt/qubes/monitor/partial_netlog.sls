# Lightweight packet logging in NetVMs (sys-dns, sys-vpn) with hourly rotation.

# --- helper to ensure a VM exists before we touch it
check-sys-dns:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx sys-dns'"

check-sys-vpn:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx sys-vpn'"

# --- packages + dirs in each VM
sys-dns-netlog-install:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: "/bin/sh -c 'apt-get -y update && apt-get -y install tcpdump && install -d -m 0750 /var/log/netpcap'"
    - require:
      - cmd: check-sys-dns

sys-vpn-netlog-install:
  qvm.run:
    - name: sys-vpn
    - user: root
    - cmd: "/bin/sh -c 'dnf -y install tcpdump && install -d -m 0750 /var/log/netpcap'"
    - require:
      - cmd: check-sys-vpn

# --- systemd unit to run tcpdump persistently (hourly rotation, keep last 48 files)
sys-dns-netpcap-service:
  qvm.run:
    - name: sys-dns
    - user: root
    - cmd: |
        /bin/sh -c '
        cat > /etc/systemd/system/netpcap.service << "EOF"
        [Unit]
        Description=Packet capture (rotating) for NetVM
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        ExecStart=/usr/sbin/tcpdump -i any -s 96 -nn -tttt -w /var/log/netpcap/pcap-%Y%m%d%H%M%S.pcap -G 3600 -W 48
        Restart=always
        RestartSec=5s
        Nice=10
        IOSchedulingClass=best-effort
        IOSchedulingPriority=7

        [Install]
        WantedBy=multi-user.target
        EOF
        systemctl daemon-reload
        systemctl enable --now netpcap.service
        '
    - require:
      - qvm: sys-dns-netlog-install

sys-vpn-netpcap-service:
  qvm.run:
    - name: sys-vpn
    - user: root
    - cmd: |
        /bin/sh -c '
        cat > /etc/systemd/system/netpcap.service << "EOF"
        [Unit]
        Description=Packet capture (rotating) for NetVM
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        ExecStart=/usr/sbin/tcpdump -i any -s 96 -nn -tttt -w /var/log/netpcap/pcap-%Y%m%d%H%M%S.pcap -G 3600 -W 48
        Restart=always
        RestartSec=5s
        Nice=10
        IOSchedulingClass=best-effort
        IOSchedulingPriority=7

        [Install]
        WantedBy=multi-user.target
        EOF
        systemctl daemon-reload
        systemctl enable --now netpcap.service
        '
    - require:
      - qvm: sys-vpn-netlog-install

# --- summary
netlog-summary:
  cmd.run:
    - name: |
        /bin/sh -c '
        printf "\n=== netlog ===\n"
        printf "sys-dns: %s\n" "$(qvm-run -p sys-dns 'systemctl is-active netpcap.service' 2>/dev/null || echo not-found)"
        printf "sys-vpn: %s\n" "$(qvm-run -p sys-vpn 'systemctl is-active netpcap.service' 2>/dev/null || echo not-found)"
        '
    - require:
      - qvm: sys-dns-netpcap-service
      - qvm: sys-vpn-netpcap-service
