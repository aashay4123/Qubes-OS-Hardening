win_tor_personas:
  - name: dell_xps13_us
    mac_oui: "3C:FD:FE"           # Intel OUI
    tz: "America/New_York"
    lang: "en-US,en;q=0.9"
    screen: "1920x1080"
    hostname_prefix: "DESKTOP"

  - name: hp_envy_uk
    mac_oui: "F4:8E:38"           # Intel OUI
    tz: "Europe/London"
    lang: "en-GB,en;q=0.9"
    screen: "1920x1080"
    hostname_prefix: "DESKTOP"

  - name: lenovo_t14_de
    mac_oui: "90:1B:0E"           # Intel OUI
    tz: "Europe/Berlin"
    lang: "de-DE,de;q=0.9,en;q=0.7"
    screen: "1920x1080"
    hostname_prefix: "DESKTOP"

  - name: acer_rtl_us
    mac_oui: "00:E0:4C"           # Realtek OUI
    tz: "America/Chicago"
    lang: "en-US,en;q=0.9"
    screen: "1920x1080"
    hostname_prefix: "DESKTOP"

  - name: asus_rtl_in
    mac_oui: "00:E0:4C"           # Realtek OUI
    tz: "Asia/Kolkata"
    lang: "en-IN,en-US;q=0.9,en;q=0.8"
    screen: "1920x1080"
    hostname_prefix: "DESKTOP"
# Enforce consistent Windows+Tor personas in Qubes without weakening isolation.

{% set personas = salt['pillar.get']('win_tor_personas', []) %}
{% set dvm      = 'disp-windows-tor' %}       # your Windows Disposable template name
{% set gw       = 'sys-tor-gw' %}             # your Tor gateway VM
{% set wrap     = '/usr/local/sbin/win-tor-persona' %}

# 0) Dom0 launcher that applies a persona atomically at start of a fresh Disposable
persona-launcher:
  file.managed:
    - name: {{ wrap }}
    - mode: '0755'
    - contents: |
      #!/bin/bash
      set -euo pipefail
      P="${1:-}"
      [ -n "$P" ] || { echo "usage: {{ wrap }} <persona-name>"; exit 2; }

      # lookup in pillar (requires yq / python3 installed in dom0 if you want to parse locally;
      # we pass down env to the VM instead, which is simpler in Qubes)
      DISP=$(qvm-create --class AppVM --label purple --template {{ dvm }} --property netvm={{ gw }} --property template_for_dispvms=False --property virt_mode=hvm --property include_in_backups=False disp-wtor-$(date +%s))
      echo "[*] Started $DISP ({{ dvm }} → {{ gw }})"

      # get persona JSON from pillar via salt-call (dom0)
      DATA=$(sudo salt-call --local pillar.get win_tor_personas --out json 2>/dev/null | sed -n 's/.*"win_tor_personas": \(.*\)}/\1/p')
      PER=$(python3 - <<'PY' "$P" "$DATA"
import json,sys
name=sys.argv[1]
arr=json.loads(sys.argv[2])
print(next((json.dumps(x) for x in arr if x['name']==name),''))
PY
)
      [ -n "$PER" ] || { echo "Persona not found: $P"; qvm-shutdown --wait "$DISP"; exit 1; }
      echo "$PER" | qvm-run --pass-io "$DISP" "cat > C:\\\\Users\\\\Public\\\\persona.json"

      # push Windows prep script
      qvm-run --pass-io "$DISP" 'powershell -NoProfile -Command "[IO.File]::WriteAllText(\"C:\Users\Public\persona.ps1\", \"`n\")"' >/dev/null
      qvm-run --pass-io "$DISP" "powershell -NoProfile -Command \
\$s=@'
# persona bootstrap inside Windows (Tor Browser only; no leaks)
\$p = Get-Content 'C:\Users\Public\persona.json' | ConvertFrom-Json
try {
  # Timezone
  Start-Process -Verb runAs powershell -ArgumentList \"-NoProfile -Command tzutil /s `\"\$([Environment]::GetEnvironmentVariable('tz'))`\"\" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
} catch {}
# Hostname (Windows requires reboot to fully apply; we set a Windows-like name for app layer)
\$rand = -join ((48..57)+(65..90) | Get-Random -Count 6 | % {[char]\$_})
\$hn = \"\$([Environment]::GetEnvironmentVariable('hostname_prefix','User'))-\$rand\"
Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\ComputerName\\ComputerName' -Name 'ComputerName' -Value \$hn -ErrorAction SilentlyContinue
Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\ComputerName\\ActiveComputerName' -Name 'ComputerName' -Value \$hn -ErrorAction SilentlyContinue

# Disable WebRTC OS IP leaks (Tor Browser also resists; belt-and-suspenders for Chromium fallback)
New-Item -Path 'HKLM:\\SOFTWARE\\Policies\\Google\\Chrome' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Google\\Chrome' -Name 'WebRtcUdpPortRange' -Value '0-0' -PropertyType String -Force | Out-Null

# Open Tor Browser only (assumes installed under C:\Tor Browser\Browser\firefox.exe)
Start-Process 'C:\Tor Browser\Browser\firefox.exe' -ArgumentList '--private-window' -WindowStyle Normal
'@; \
[IO.File]::WriteAllText('C:\Users\Public\persona.ps1', \$s)"

      # export persona vars as environment so PS sees them without parsing
      # (fallback if JSON parse fails)
      for key in tz lang screen hostname_prefix; do
        VAL=$(echo "$PER" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$key',''))")
        qvm-run --pass-io "$DISP" "powershell -NoProfile -Command [Environment]::SetEnvironmentVariable('$key', '$VAL', 'Machine')"
      done

      # run the PS bootstrap (non-blocking) and focus VM window
      qvm-run "$DISP" "powershell -ExecutionPolicy Bypass -File C:\\Users\\Public\\persona.ps1" &
      qvm-start --foreground "$DISP"

# 1) sys-net MAC OUI set at edge (only meaningful off-Tor; harmless otherwise)
{% for p in personas %}
mac-oui-{{ p['name'] }}:
  cmd.run:
    - name: |
        echo '{{ p['mac_oui'] }}' >/etc/qubes/spoof_oui_{{ p['name'] }}
    - unless: test -f /etc/qubes/spoof_oui_{{ p['name'] }}
{% endfor %}

# Script in sys-net to apply chosen OUI once and keep a stable suffix
sysnet-oui-helper:
  qvm.run:
    - name: sys-net
    - user: root
    - cmd: |
        set -e
        apt-get update -y || true
        apt-get install -y --no-install-recommends network-manager || true
        install -d -m 755 /usr/local/sbin
        cat >/usr/local/sbin/apply-oui <<'EOF'
        #!/bin/sh
        OUI_FILE=/rw/config/oui_prefix
        if [ ! -f "$OUI_FILE" ]; then echo "3C:FD:FE" > "$OUI_FILE"; fi
        OUI=$(cat "$OUI_FILE" | tr -d '\n')
        suf=$(printf ":%02X:%02X:%02X" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
        MAC="$OUI$suf"
        IF=$(nmcli -t -f DEVICE,TYPE dev | awk -F: '$2=="wifi"||$2=="ethernet"{print $1; exit}')
        UUID=$(nmcli -t -f UUID c show --active | head -n1)
        [ -z "$UUID" ] && UUID=$(nmcli -t -f UUID c show | head -n1)
        [ -n "$UUID" ] || exit 0
        nmcli connection modify "$UUID" ethernet.cloned-mac-address "$MAC"
        nmcli connection modify "$UUID" wifi.cloned-mac-address "$MAC"
        nmcli connection up "$UUID" || true
        echo "$MAC" > /rw/config/current_mac
        EOF
        chmod +x /usr/local/sbin/apply-oui

# 2) sys-firewall: TTL=128 (Windows-like); harmless over Tor but normalizes any non-Tor LAN
ttl-128:
  qvm.run:
    - name: sys-firewall
    - user: root
    - cmd: |
        set -e
        mkdir -p /etc/nftables.d
        cat >/etc/nftables.d/20-ttl-128.nft <<'EOF'
        table inet ttlfix {
          chain set_ttl {
            type filter hook postrouting priority 0; policy accept;
            ip ttl set 128
          }
        }
        EOF
        echo 'include "/etc/nftables.d/*.nft"' >/etc/nftables.conf
        systemctl enable nftables
        systemctl restart nftables || true
