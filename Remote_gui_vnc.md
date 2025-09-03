# Remote GUI via VNC (for Mac)

## 0) One-time prep (dom0)

Create a tiny env file so you can tune geometry once:

```bash
mkdir -p ~/.config
cat > ~/.config/qubes-xvnc.env <<'EOF'
GEOMETRY=2880x1800
DEPTH=24
DISPLAYNUM=1
RFB_AUTH=$HOME/.vnc/passwd
EOF
```

> If `~/.vnc/passwd` doesn’t exist, run `vncpasswd` in dom0 once to create it.

---

## 1) Helper scripts (dom0)

```bash
sudo install -d -m 755 /usr/local/sbin
```

### `/usr/local/sbin/qubes-xvnc-start`

```bash
sudo tee /usr/local/sbin/qubes-xvnc-start >/dev/null <<'EOF'
#!/bin/bash
set -euo pipefail
source "${HOME}/.config/qubes-xvnc.env" 2>/dev/null || true

D="${1:-${DISPLAYNUM:-1}}"
PORT=$((5900 + D))

# find shmoverride
LIB="/usr/lib64/qubes-gui-daemon/shmoverride.so"

GEOM="${GEOMETRY:-1920x1080}"
DEPTH="${DEPTH:-24}"
AUTH="${RFB_AUTH:-$HOME/.vnc/passwd}"

if [ ! -f "$AUTH" ]; then
  echo "VNC auth file not found: $AUTH"
  echo "Create it with: vncpasswd"
  exit 1
fi

# kill leftovers on this display
pkill -f "Xvnc :${D}" 2>/dev/null || true

# start Xvnc with shmoverride preloaded (required by qubes-guid)
LD_PRELOAD="$LIB" Xvnc :"${D}" -geometry "$GEOM" -depth "$DEPTH" \
  -localhost -rfbport "$PORT" -rfbauth "$AUTH" -SecurityTypes VncAuth \
  -AlwaysShared -AcceptKeyEvents -AcceptPointerEvents -AcceptCutText -SendCutText &

# wait for port
for i in {1..10}; do
  ss -ltn "sport = :$PORT" | grep -q ":$PORT" && break || sleep 0.2
done

# sanity: shm file should exist now
if [ ! -e "/var/run/qubes/shm.id.${D}" ]; then
  echo "WARNING: shm.id.${D} missing – check shmoverride path ($LIB)."
fi
EOF
sudo chmod +x /usr/local/sbin/qubes-xvnc-start
```

### `/usr/local/sbin/qubes-xvnc-stop`

```bash
sudo tee /usr/local/sbin/qubes-xvnc-stop >/dev/null <<'EOF'
#!/bin/bash
set -euo pipefail
source "${HOME}/.config/qubes-xvnc.env" 2>/dev/null || true
D="${1:-${DISPLAYNUM:-1}}"

# kill qubes-guid instances targeting this DISPLAY
# (best-effort; ignores others)
pkill -f "DISPLAY=:${D} .*qubes-guid" 2>/dev/null || true
pkill -f "Xvnc :${D}" 2>/dev/null || true
sleep 0.3
EOF
sudo chmod +x /usr/local/sbin/qubes-xvnc-stop
```

### `/usr/local/sbin/qubes-guid-attach`

```bash
sudo tee /usr/local/sbin/qubes-guid-attach >/dev/null <<'EOF'
#!/bin/bash
set -euo pipefail
source "${HOME}/.config/qubes-xvnc.env" 2>/dev/null || true
D="${1:-${DISPLAYNUM:-1}}"

# attach all running VMs’ windows to DISPLAY :D
mapfile -t VMS < <(qvm-ls --raw-list --running)
for vm in "${VMS[@]}"; do
  domid=$(xl domid "$vm" 2>/dev/null || true)
  [ -n "$domid" ] || continue
  DISPLAY=:${D} qubes-guid -d "$domid" -N "$vm" -q -f &
done
EOF
sudo chmod +x /usr/local/sbin/qubes-guid-attach
```

---

## 2) systemd **user** units (so you can toggle easily)

### `~/.config/systemd/user/qubes-xvnc@.service`

```ini
[Unit]
Description=XVNC server for Qubes GUI on :%i
After=graphical-session.target

[Service]
Type=simple
EnvironmentFile=-%h/.config/qubes-xvnc.env
ExecStart=/usr/local/sbin/qubes-xvnc-start %i
ExecStop=/usr/local/sbin/qubes-xvnc-stop %i
Restart=on-failure

[Install]
WantedBy=default.target
```

### `~/.config/systemd/user/qubes-guid-attach@.service`

```ini
[Unit]
Description=Attach running VMs to DISPLAY :%i
After=qubes-xvnc@%i.service
Requires=qubes-xvnc@%i.service

[Service]
Type=oneshot
EnvironmentFile=-%h/.config/qubes-xvnc.env
ExecStart=/usr/local/sbin/qubes-guid-attach %i
RemainAfterExit=yes

[Install]
WantedBy=default.target
```

### (Nice wrapper) `~/.config/systemd/user/qubes-remote-gui@.target`

```ini
[Unit]
Description=Qubes Remote GUI stack on :%i

[Install]
WantedBy=default.target

[Unit]
Wants=qubes-xvnc@%i.service qubes-guid-attach@%i.service
After=qubes-xvnc@%i.service
```

Reload user systemd:

```bash
systemctl --user daemon-reload
```

---

## 3) Use it (toggle)

- **Turn ON** remote GUI on `:1`:

  ```bash
  systemctl --user start qubes-remote-gui@1.target
  ```

  (Connect from your Mac to `localhost:5901` after you set your SSH tunnel.)

- **Turn OFF** everything for `:1`:

  ```bash
  systemctl --user stop qubes-remote-gui@1.target
  ```

- **Start automatically after login** (optional):

  ```bash
  systemctl --user enable qubes-remote-gui@1.target
  ```

  Remove with `disable`.

---

## 4) Quick health checks

- VNC port/listen:

  ```bash
  ss -ltn | grep 5901
  ```

- shmoverride active:

  ```bash
  ls /var/run/qubes/shm.id.1
  ```

- GUIDs on :1:

  ```bash
  pgrep -af "DISPLAY=:1 .*qubes-guid"
  ```

---

## 5) (Optional) tiny CLI toggles

Add to your `~/.bashrc` in dom0:

```bash
alias vnc-on='systemctl --user start qubes-remote-gui@1.target'
alias vnc-off='systemctl --user stop qubes-remote-gui@1.target'
alias guiA='systemctl --user start qubes-guid-attach@1'
```

---

### Notes / gotchas

- If you change resolution, edit `~/.config/qubes-xvnc.env` and `vnc-off && vnc-on`.
- If you start new VMs **after** bringing VNC up, either run:

  ```bash
  systemctl --user start qubes-guid-attach@1
  ```

  or just call `/usr/local/sbin/qubes-guid-attach 1` again—harmless to repeat.

- Keep your SSH tunnel recipe the same as before; this setup doesn’t change networking.

That’s it: persistent, one-command **on/off**, and it survives reboots (if you enable it).
Got it — now you’re asking not about **local SSH tunnel from your Mac → dom0**, but how you could expose this remote desktop session **over the internet** (to yourself, securely).
There are basically four classes of options, each with different trade-offs:

---

## 🔐 1. **Reverse SSH Tunnel (recommended, simplest)**

- You already have **SSH from dom0 to Mac** working. You can invert that.
- From dom0 you run:

  ```bash
  ssh -R 5901:localhost:5901 youruser@your-vps
  ```

  This makes `your-vps:5901` forward back into dom0’s VNC.

- Then, from anywhere (your Mac, phone, work PC), connect to `your-vps:5901`.
- **Pros**: No third-party, strong encryption (SSH), integrates with your VNC setup.
- **Cons**: Requires a VPS or some always-on server as a jump host.

---

## 🌍 2. **VPN tunnel (WireGuard / OpenVPN)**

- Run a small WireGuard server on a VPS or home router.
- Dom0 (or better, a NetVM like `sys-vpn`) connects to it.
- Your Mac joins the same VPN network. Then you can hit `dom0:5901` directly as if you were LAN-connected.
- **Pros**: Secure, stable, scales to multiple services.
- **Cons**: Slightly more setup, but clean.

---

## ☁️ 3. **ngrok / cloudflared / Tailscale Funnel**

- Tools like **ngrok**, **Cloudflare Tunnel**, or **Tailscale Funnel** expose a single TCP port via a public HTTPS endpoint.
- Example with ngrok:

  ```bash
  ngrok tcp 5901
  ```

  It will give you something like `tcp://3.tcp.ngrok.io:12345`, which you connect to in your VNC client.

- **Pros**: Very easy, no server required.
- **Cons**: Trust a third-party tunnel provider, bandwidth/latency depends on them.

---

## 🖥️ 4. **Spice / RDP Gateway inside a VM**

- Instead of dom0, you set up **spice-vdagent** or **xrdp** in a disposable Fedora/Debian VM and connect there.
- That VM has VNC/Spice exposed to the outside world via one of the above tunnels.
- **Pros**: You don’t expose dom0 directly.
- **Cons**: Adds complexity, but more secure than running remote desktop from dom0.

---

## ⚖️ Which would I suggest?

- **If you want quick & dirty access** → `ngrok tcp 5901` is easiest.
- **If you want reliable private access** → Reverse SSH tunnel through a VPS you own.
- **If you want the most secure** → Don’t expose dom0 at all; instead remote into a dedicated “gateway VM” (e.g., Fedora minimal with xrdp) and then jump into dom0 indirectly.
- **If you want it integrated like your own private cloud** → WireGuard VPN, then use VNC over it.

---

Got it ✅ Thanks for clarifying.
Here’s a **full design + setup guide** for turning your **Raspberry Pi 3 into a WireGuard-based VPS jump server**, even though you **don’t have a public IP**. We’ll avoid exposing dom0 directly and instead route through **sys-net → Pi → Mac**.

---

# 🔧 Overall Architecture

- **Raspberry Pi 3** → Your always-on “VPS” at home.
- **No public IP problem**: solved via **Tailscale (mesh VPN)** or **Cloudflare Tunnel**.
- **WireGuard** provides the secure transport.
- **Dom0 never exposed**: you expose via `sys-net` or `sys-vpn`.

So the flow is:

**Mac → Internet → Pi (via Tailscale/Cloudflare) → WireGuard tunnel → sys-net → dom0 VNC**

---

# 🛠 Step 1. Prep Raspberry Pi

Install a clean OS:

```bash
# Flash Raspberry Pi OS Lite (64-bit recommended)
```

Update:

```bash
sudo apt update && sudo apt upgrade -y
```

Install needed packages:

```bash
sudo apt install wireguard tailscale ufw -y
```

Enable firewall but allow VPN:

```bash
sudo ufw allow 22/tcp
sudo ufw allow 51820/udp
sudo ufw enable
```

---

# 🛠 Step 2. Solve “No Public IP”

### Option A: Use **Tailscale** (recommended)

- Install:

  ```bash
  curl -fsSL https://tailscale.com/install.sh | sh
  sudo tailscale up
  ```

- This puts your Pi on a **private mesh VPN** that your Mac and dom0 can also join.
- Every peer gets a stable `100.x.x.x` IP.

### Option B: Use **Cloudflare Tunnel**

- Install Cloudflared:

  ```bash
  sudo apt install cloudflare
  cloudflared tunnel login
  ```

- Expose WireGuard port 51820 → internet safely.

For simplicity, I’ll continue assuming **Tailscale**.

---

# 🛠 Step 3. Configure WireGuard on Pi

`/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.0.0.1/24
PrivateKey = <PiPrivateKey>
ListenPort = 51820

[Peer] # Mac
PublicKey = <MacPublicKey>
AllowedIPs = 10.0.0.2/32

[Peer] # sys-net (or dom0 behind sys-net)
PublicKey = <SysnetPublicKey>
AllowedIPs = 10.0.0.3/32
```

Enable:

```bash
sudo systemctl enable wg-quick@wg0 --now
```

---

# 🛠 Step 4. Configure **sys-net** VM

Inside sys-net:

```bash
sudo dnf install wireguard-tools -y
```

Config `/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.0.0.3/24
PrivateKey = <SysnetPrivateKey>

[Peer] # Pi
PublicKey = <PiPublicKey>
Endpoint = <PiTailscaleIP>:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
```

Start:

```bash
sudo wg-quick up wg0
```

Now sys-net can securely talk to the Pi.

---

# 🛠 Step 5. Configure **Mac**

On Mac:

```bash
brew install wireguard-tools
```

Config `/usr/local/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.0.0.2/24
PrivateKey = <MacPrivateKey>

[Peer] # Pi
PublicKey = <PiPublicKey>
Endpoint = <PiTailscaleIP>:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
```

Bring it up:

```bash
sudo wg-quick up wg0
```

---

# 🛠 Step 6. Remote VNC Access Flow

1. Start XVNC in dom0 bound to **localhost:5901** (as you already do).

   ```bash
   x0vncserver -display :0 -rfbauth ~/.vnc/passwd -rfbport 5901
   ```

2. Tunnel it through sys-net → Pi:

   ```bash
   ssh -R 5901:localhost:5901 user@10.0.0.1
   ```

3. On your Mac, connect to Pi:

   ```bash
   ssh -L 5901:localhost:5901 user@10.0.0.1
   ```

4. Open your Mac VNC Viewer:

   ```
   vnc://localhost:5901
   ```

---

# ✅ Result

- Your Mac always reaches dom0 GUI via the Pi, even without a public IP.
- The Pi provides stable routing via **Tailscale + WireGuard**.
- Dom0 never exposed directly → only through sys-net tunnel.

---

## 🔑 How it works

- Every device (your **Mac**, your **Raspberry Pi**, even **sys-net**) joins the same Tailscale network (called a _tailnet_).
- Tailscale automatically traverses NAT/firewalls (using WireGuard + DERP relays).
- Each device gets a stable **100.x.y.z** IP (or a MagicDNS name like `raspberrypi.tailnet-name.ts.net`).

So:

- At home → Pi runs Tailscale client.
- On the road → Mac also runs Tailscale client.
- Mac can reach Pi directly on its Tailscale IP (`100.x.x.x`) or MagicDNS name, no matter the ISP, NAT, or Wi-Fi.

---

## 🔧 Example

1. On the **Pi**:

   ```bash
   sudo tailscale up --ssh --advertise-exit-node
   ```

   → Pi joins the tailnet, gets e.g. `100.101.102.103`.

2. On the **Mac** (anywhere in the world):

   ```bash
   tailscale up
   ```

   → Mac joins the same tailnet, gets e.g. `100.104.105.106`.

3. Now from Mac, you can SSH/VNC directly into Pi:

   ```bash
   ssh user@100.101.102.103
   vncviewer 100.101.102.103:5901
   ```

And since Pi has WireGuard running as well, you can also route **sys-net** through Pi to dom0.

---

## ✨ Why this solves your issue

- **No port forwarding needed**.
- **No public IP needed**.
- Works across ISPs, NAT, mobile hotspots, etc.
- Stable IP (100.x) that never changes, even if your Pi’s LAN IP changes.

---
