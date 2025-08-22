undercover_dom0:
  enabled: false              # set true to auto-apply on next state.apply
  username: user              # your dom0 login (default is 'user' on Qubes)
  # Look & feel
  gtk_theme: Adwaita          # built-in; keeps dom0 minimal
  icon_theme: Adwaita
  wm_theme: Default           # keep Qubes border colors (security labels)
  font: "Noto Sans 10"        # any installed font is fine; keep it simple
  # Panel tweaks
  panel_row_size: 36          # 28–40 looks “normal”
  panel_position: bottom      # bottom ≈ Windows-y
  clock_format: "%R  %a %d %b"  # 24h “HH:MM  Day DD Mon”
  # Files
  toggle_script_path: /usr/local/sbin/dom0-undercover-toggle.sh
  backup_dir: /var/lib/qubes/undercover-backups
