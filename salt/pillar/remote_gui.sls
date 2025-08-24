remote_gui:
  admin_user: "user"              # dom0 X session user
  proxy_qube: "sys-remote"        # will be created if missing
  proxy_template: "fedora-42-xfce"
  proxy_label: "yellow"

  ssh_vault: "vault-ssh"          # offline key holder (will be created)
  vault_template: "debian-12-minimal"
  vault_label: "red"

  mac_user: "YOUR_MAC_USER"
  mac_host: "YOUR.MAC.IP.OR.DNS"
  mac_ssh_port: 22

  # If you already run a Split-SSH agent socket in the proxy, set it here; else leave default
  ssh_auth_sock: "/run/user/1000/ssh-agent"

  # Optional: pre-provision a VNC password hash (otherwise set it manually after)
  # vnc_pass_hash: "OUTPUT_OF: printf 'PASS' | vncpasswd -f"

  install_pipewire_utils: true
  audio:
    enable: true
    bitrate_k: 96
    sample_rate: 48000
    channels: 2

  # Optional: where a key might live in the vault (helper will search a few common paths)
  key_path: "/home/user/.ssh/id_ed25519_mac"
  key_comment: "qubes-remote-mac"
