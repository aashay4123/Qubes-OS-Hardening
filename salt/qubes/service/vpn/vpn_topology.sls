
# -------------------------
#  Helper: apply selected topology
#  ------------------------- #}
apply-vpn-topology:
  cmd.run:
    - name: |
        set -e
        VPN="{{ selected_vpn }}"
        MODE="{{ topology_mode }}"

        # Make sure the selected VPN exists; fall back if not
        if ! qvm-ls --raw-list | grep -qx "$VPN"; then
          echo "Selected VPN '$VPN' not found; falling back to sys-vpn-ru or sys-vpn-nl" >&2
          if   qvm-ls --raw-list | grep -qx sys-vpn-ru; then VPN="sys-vpn-ru"
          elif qvm-ls --raw-list | grep -qx sys-vpn-nl; then VPN="sys-vpn-nl"
          else echo "No VPN VMs found." >&2; exit 1
          fi
        fi

        # Ensure core VMs exist
        for VM in sys-firewall sys-dns sys-net; do
          qvm-ls --raw-list | grep -qx "$VM" || { echo "$VM missing" >&2; exit 1; }
        done

        # Topology wiring helper
        link() { qvm-prefs "$1" netvm "$2"; }

        case "$MODE" in
          dns-vpn)
            # firewall -> dns -> vpn -> net
            link sys-firewall sys-net
            link sys-dns      "$VPN"
            link "$VPN"       sys-net
            ;;

          dns-tor-vpn)
            # firewall -> dns -> tor -> vpn -> net
            qvm-ls --raw-list | grep -qx sys-vpn-tor || { echo "sys-vpn-tor missing" >&2; exit 1; }
            link sys-firewall sys-net
            link sys-dns      sys-vpn-tor
            link sys-vpn-tor  "$VPN"
            link "$VPN"       sys-net
            ;;

          dns-vpn-tor)
            # firewall -> dns -> vpn -> tor -> net
            qvm-ls --raw-list | grep -qx sys-vpn-tor || { echo "sys-vpn-tor missing" >&2; exit 1; }
            link sys-firewall sys-net
            link sys-dns      "$VPN"
            link "$VPN"       sys-vpn-tor
            link sys-vpn-tor  sys-net
            ;;

          *)
            echo "Unknown topology_mode: $MODE (expected: dns-vpn | dns-tor-vpn | dns-vpn-tor)" >&2
            exit 1
            ;;
        esac

        # Optional: set UpdateVM to sys-firewall (handy)
        qubes-prefs updatevm sys-firewall || true
    - require:
      - qvm.vm: sys-vpn-ru-create
      - qvm.vm: sys-vpn-nl-create
      - cmd:    sys-vpn-tor-create
      - qvm.tag: sys-vpn-tor-tag

# -------------------------
#  Optional: quick status output
#  ------------------------- #}
show-vpn-topology:
  cmd.run:
    - name: |
        set -e
        echo "Topology mode = {{ topology_mode }}"
        echo "Selected VPN  = {{ selected_vpn }}"
        echo
        printf "%-14s -> netvm\n" "VM"
        for VM in sys-firewall sys-dns sys-vpn-ru sys-vpn-nl sys-vpn-tor; do
          if qvm-ls --raw-list | grep -qx "$VM"; then
            printf "%-14s -> %s\n" "$VM" "$(qvm-prefs "$VM" netvm || echo '-')"
          fi
        done
        echo
        echo "Chain preview (AppVMs should use sys-firewall):"
        echo "  AppVM -> sys-firewall -> ... (per topology)"
    - require:
      - cmd: apply-vpn-topology
