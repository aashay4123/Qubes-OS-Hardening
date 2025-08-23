remote_gui:
  admin_user: "user"           # dom0 X session user ('user' is default in Qubes)
  proxy_qube: "sys-remote"       # the qube that will hold the SSH ↔️ Mac tunnel
  mac_user:   "darlene"
  mac_host:   "192.168.1.70"
  mac_ssh_port: 22             # change if needed
  ssh_auth_sock: "/run/user/1000/ssh-agent"      # e.g. /run/user/1000/ssh-agent-split.sock (if using split-ssh)
  install_pipewire_utils: true # set false if dom0 already has pw-record
  proxy_qube: sys-remote
  proxy_template: fedora-42-xfce   # or debian-12-minimal
  proxy_label: yellow
  audio:
    enable: true
    bitrate_k: 96              # Opus kbps from proxy to Mac
    sample_rate: 48000
    channels: 2

