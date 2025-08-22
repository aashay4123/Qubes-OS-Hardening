**turn-key Salt bundle** :

- builds the official **`sys-gui-vnc`** GUI domain;
- sets a **TigerVNC password** inside it (no interactivity);
- creates a hardened **relay** VM (`sys-remote`) that:

  - binds `sys-gui-vnc:5900` locally via **qrexec**,
  - exposes it **only over SSH** (no raw VNC on the network),
  - uses **OpenSSH+firewall** defaults for a tight surface.

You’ll get **secure + fast** remote GUI (use SSH compression + a decent VNC encoding).
Where the design comes from: the official GUI-domain + ConnectTCP flow (VNC runs **inside** `sys-gui-vnc`, is **not** given a NetVM; another qube bridges the port). ([Qubes OS][1])

---

## Apply it (in **dom0**)

```bash
sudo qubesctl state.apply remote-gui
```

---

## Connect from your Mac (fast & secure)

1. Install a VNC viewer (e.g., TigerVNC):

   ```bash
   brew install --cask tigervnc-viewer
   ```

2. SSH tunnel **to the relay**:

   ```bash
   ssh -L 5900:localhost:5900 user@<relay_public_ip_or_dns>
   ```

3. Open the viewer on macOS:

   ```
   open -a TigerVNC\ Viewer --args localhost:5900
   ```

   Enter the VNC password you set in the SLS.

> Why SSH + qrexec instead of exposing VNC? Because the recommended path is **VNC bound to localhost in `sys-gui-vnc`**, port bound into a **relay via `qubes.ConnectTCP`**, then **SSH tunnel** from outside—this keeps `sys-gui-vnc` off the network and avoids raw VNC on the internet. ([Qubes OS][1])

---

### Speed tips

- In TigerVNC Viewer: `Options → Compression: High`, `Encoding: Tight`, enable JPEG if bandwidth-limited.
- SSH: add `-C` (compression) and, if latency is low, `-o CompressionLevel=6`.
- The service override above pins **`-SecurityTypes VncAuth`** and the **password file**; SSH handles transport encryption/auth.

---
