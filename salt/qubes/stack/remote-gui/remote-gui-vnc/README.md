# Remote dom0 GUI over Reverse-SSH (with Audio) — Qubes 4.2

## What this is

This state lets you operate your Qubes laptop from your Mac **without exposing dom0 to the network**.

- dom0 runs **qubes-remote-desktop** (VNC) on **localhost:5901** only.
- A **proxy qube** (e.g., `sys-remote` or `work-web`) uses **`qubes.ConnectTCP+5901`** to bridge connections to dom0.
- The proxy opens a **reverse SSH tunnel** to your **Mac**, so on the Mac you connect to `127.0.0.1:5901`.
- **Audio** is captured in dom0, sent over **qrexec** to the proxy, encoded (Opus), and **played on the Mac** via `ffplay` over SSH.

No LAN DNAT, no ports opened to the world, no dom0 NetVM changes.

---

## Files this state creates

- dom0:

  - Enables `qubes-vncserver@<admin_user>` (loopback only)
  - `/etc/qubes/policy.d/30-remote-admin.policy` (allows only the proxy qube to call `qubes.ConnectTCP +5901` and `my.audio.Capture`)
  - `/usr/local/sbin/dom0-audio-capture.sh` and `/etc/qubes-rpc/my.audio.Capture`
  - Helper: `/usr/local/sbin/remote-admin-status`

- Proxy qube (user services):

  - `qct-vnc.service` — binds local `15901 → dom0:5901` via `qvm-connect-tcp`
  - `remote-vnc-reverse-ssh.service` — reverse SSH to your Mac (publishes `Mac:5901`)
  - `remote-audio.service` — pulls audio from dom0 via qrexec, encodes, and forwards to `ffplay` on the Mac

---

## Requirements

### On the Mac (one-time)

1. **Enable SSH**: System Settings → General → Sharing → **Remote Login**: ON
2. **Install ffmpeg** (for `ffplay`):

   ```bash
   brew install ffmpeg
   ```

3. (Recommended) **Pin the Mac’s SSH host key** in the proxy qube (see “Pin host key” below).

### On Qubes

- Qubes OS **4.2**.
- A **proxy qube** with network (`netvm = sys-firewall`), based on Debian/Fedora minimal or similar.
- For SSH auth, either:

  - **Split-SSH** via your `vault-ssh` (recommended), or
  - A local SSH key stored inside the proxy qube (less ideal).

---

## Pillar configuration (variables)

Create or edit `/srv/pillar/remote_gui.sls`:

```yaml
remote_gui:
  admin_user: "user" # dom0 desktop user (default Qubes user is 'user')
  proxy_qube: "sys-remote" # the qube that will host the reverse tunnel
  mac_user: "YOUR_MAC_LOGIN" # your macOS account
  mac_host: "192.168.1.50" # your Mac’s LAN IP or hostname
  mac_ssh_port: 22 # macOS SSH port (default 22)

  # If you use Split-SSH, set the agent socket path inside the proxy qube environment:
  ssh_auth_sock: "" # e.g. "/run/user/1000/ssh-agent" or your split-ssh socket

  install_pipewire_utils: true # install pw-record in dom0 if missing

  audio:
    enable: true
    bitrate_k: 96 # Opus bitrate (kbps) from proxy → Mac
    sample_rate: 48000 # Hz
    channels: 2
```

> Tip: If you don’t use Pillar, you can hardcode these in the SLS, but Pillar is cleaner.

Update your pillar top file (if needed), e.g. `/srv/pillar/top.sls`:

```yaml
base:
  "*":
    - remote_gui
```

---

## Apply the state

Place the state at:

```
/srv/salt/remote_gui_option_a_plus_audio/init.sls
```

Then apply:

```bash
sudo qubesctl --all state.apply remote_gui_option_a_plus_audio
```

This:

- Installs/starts the dom0 VNC service (loopback only).
- Installs RPC handler for audio capture in dom0.
- Creates user services in the proxy qube and starts them.
- Limits the proxy qube firewall to **SSH to your Mac only** (default drop).

---

## Set a VNC password (strongly recommended)

The VNC server authenticates at the viewer. Set the password for the dom0 desktop user:

```bash
# In dom0
sudo -u user mkdir -p /home/user/.vnc
printf 'CHOOSE_A_STRONG_PASSWORD' | vncpasswd -f | sudo -u user tee /home/user/.vnc/passwd >/dev/null
sudo chmod 600 /home/user/.vnc/passwd
sudo systemctl restart qubes-vncserver@user
```

---

## Pin your Mac’s SSH host key (recommended)

From dom0:

```bash
qvm-run -u user sys-remote "ssh-keyscan -p 22 192.168.1.50 >> ~/.ssh/known_hosts"
```

(Change VM/user/port/host to your values.)

---

## Connect from the Mac

1. Make sure the proxy qube is running (the state enables user services that auto-start; otherwise `qvm-start sys-remote`).
2. On the Mac, open any VNC viewer to:

   ```
   vnc://127.0.0.1:5901
   ```

   Enter the **VNC password** you set.

**Audio**: starts automatically via `remote-audio.service`. If you don’t hear audio, see “Troubleshooting”.

---

## Operational helpers

**Health/status (in dom0):**

```bash
sudo /usr/local/sbin/remote-admin-status
```

It shows:

- dom0 VNC service state
- active policy line for `qubes.ConnectTCP +5901`
- proxy’s user services (`qct-vnc.service`, `remote-vnc-reverse-ssh.service`, `remote-audio.service`)

**Start/stop services manually**

- dom0 VNC:

  ```bash
  sudo systemctl start  qubes-vncserver@user
  sudo systemctl stop   qubes-vncserver@user
  ```

- Proxy user services:

  ```bash
  qvm-run sys-remote 'systemctl --user restart qct-vnc.service remote-vnc-reverse-ssh.service remote-audio.service'
  ```

---

## Security hardening checklist (already covered or opt-in)

- dom0 VNC **binds localhost** (`-localhost`) and is only reachable via `qubes.ConnectTCP`.
- Only the **proxy qube** is allowed in `/etc/qubes/policy.d/30-remote-admin.policy`.
- Proxy qube firewall: **default drop**, allow **SSH→Mac** only.
- Use **Split-SSH** (agent in `vault-ssh`) rather than placing private keys in the proxy.
- **Pin Mac host key** and keep SSH passwords **disabled** on the Mac.
- Use a **strong VNC password** (and consider long random).
- Lock/blank the local Qubes panel if you don’t want shoulder-surfing at the laptop:

  ```bash
  xset dpms force off
  ```

---

## Troubleshooting

**I can’t connect to VNC from the Mac**

- Check that the proxy user services are running:

  ```bash
  qvm-run sys-remote 'systemctl --user --no-pager --full status qct-vnc.service remote-vnc-reverse-ssh.service'
  ```

- Verify the reverse tunnel is up (on the Mac):
  `lsof -iTCP:5901 -sTCP:LISTEN` should show ssh/launchd is listening.
- Ensure macOS firewall allows **Remote Login** and `sshd`.
- Verify the VNC password file exists in dom0: `/home/user/.vnc/passwd` (mode `600`).

**No audio**

- Confirm ffplay is installed on the Mac: `which ffplay`.
- Check the proxy audio service:

  ```bash
  qvm-run sys-remote 'systemctl --user --no-pager --full status remote-audio.service'
  ```

- Ensure dom0 has `pw-record` (or PulseAudio’s `parec`). If not, set `install_pipewire_utils: true` and re-apply.
- Some desktops rename the default sink; our script auto-picks the default. Make sure sound in dom0 is not muted.

**SSH auth fails from proxy**

- If using Split-SSH, set the socket path in pillar:
  `remote_gui.ssh_auth_sock: "/run/user/1000/ssh-agent"` (example; use your actual path).
- Pin host key (see above).
- Try manual test:

  ```bash
  qvm-run -u user sys-remote "ssh -p 22 YOUR_MAC_LOGIN@YOUR_MAC_IP 'echo ok'"
  ```

**The proxy firewall blocks the tunnel**

- The state sets `default=drop` and only allows TCP/22 to your Mac. If your Mac IP changes, update `mac_host` and re-apply.

---

## Changing defaults

- **Proxy qube name**: change `proxy_qube` in Pillar.
- **Mac SSH port**: change `mac_ssh_port`.
- **Opus bitrate**: change `audio.bitrate_k` (64–160 is a good range).
- **Sample rate/channels**: `audio.sample_rate` / `audio.channels`.
- **VNC port**: The state uses `dom0:5901` and `proxy:15901` internally, and `Mac:5901` externally. If you must change these, tell me and I’ll provide a safe delta.

---

## Clean removal (rollback)

```bash
# dom0
sudo systemctl disable --now qubes-vncserver@user
sudo rm -f /etc/qubes/policy.d/30-remote-admin.policy \
            /usr/local/sbin/dom0-audio-capture.sh \
            /etc/qubes-rpc/my.audio.Capture \
            /usr/local/sbin/remote-admin-status
sudo systemctl daemon-reload

# proxy qube (remove user services)
qvm-run sys-remote 'systemctl --user disable --now qct-vnc.service remote-vnc-reverse-ssh.service remote-audio.service; \
                    rm -f ~/.config/systemd/user/qct-vnc.service \
                          ~/.config/systemd/user/remote-vnc-reverse-ssh.service \
                          ~/.config/systemd/user/remote-audio.service; \
                    systemctl --user daemon-reload'
# optional: relax proxy firewall (or leave default drop)
qvm-firewall sys-remote reset
```

---

## Quick verification flow

```bash
# 1) Check dom0 is listening (loopback only)
sudo ss -ltnp | grep 5901

# 2) Check policy gate
grep 'qubes.ConnectTCP +5901' /etc/qubes/policy.d/30-remote-admin.policy

# 3) From proxy, ensure local bind is up
qvm-run sys-remote 'ss -ltn | grep 15901'

# 4) From Mac, confirm 5901 is listening (reverse tunnel)
lsof -iTCP:5901 -sTCP:LISTEN

# 5) Connect VNC from Mac: vnc://127.0.0.1:5901
#    Audio should autoplay; otherwise check remote-audio.service logs.
```

---

## FAQ

**Do I need the older “Option A” state too?**
No. This README covers the **Option A + audio** state; it **replaces** the earlier one.

**Can I use Trackpad gestures / special keys?**
Basic keys work; some macOS-specific combos may not map 1:1 over VNC. That’s cosmetic, not a security issue.

**Can I switch audio off sometimes?**
Yes:
`qvm-run sys-remote 'systemctl --user stop remote-audio.service'`
Start again with `start`.

---

If you want this wrapped as a printable PDF or want me to add **host-key pinning** automatically in the state (with your `ssh-ed25519` line), say the word and I’ll drop in a tiny, safe patch.
