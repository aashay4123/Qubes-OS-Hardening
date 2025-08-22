{% from "osi_model_security/map.jinja" import cfg with context %}
{% set u = pillar.get('undercover_dom0', {}) %}
{% set user = u.get('username', 'user') %}

# Place the toggle script
dom0-undercover-toggle-script:
  file.managed:
    - name: {{ u.get('toggle_script_path', '/usr/local/sbin/dom0-undercover-toggle.sh') }}
    - mode: '0755'
    - user: root
    - group: root
    - contents: |
        #!/bin/bash
        # Qubes dom0 Undercover toggle (best-effort, no extra packages)
        set -euo pipefail
        USERNAME="{{ user }}"
        BACKUP_DIR="{{ u.get('backup_dir', '/var/lib/qubes/undercover-backups') }}"
        GTK_THEME="{{ u.get('gtk_theme', 'Adwaita') }}"
        ICON_THEME="{{ u.get('icon_theme', 'Adwaita') }}"
        WM_THEME="{{ u.get('wm_theme', 'Default') }}"
        FONT="{{ u.get('font', 'Noto Sans 10') }}"
        PANEL_POS="{{ u.get('panel_position', 'bottom') }}"
        PANEL_SIZE="{{ u.get('panel_row_size', 36) }}"
        CLOCK_FMT="{{ u.get('clock_format', '%R  %a %d %b') }}"

        # helpers
        run_u(){ sudo -u "$USERNAME" env DISPLAY=:0 xfconf-query "$@"; }
        save_backup(){
          ts="$(date +%Y%m%d-%H%M%S)"
          dest="$BACKUP_DIR/$ts"
          mkdir -p "$dest"
          for ch in xsettings xfwm4 xfce4-panel xfce4-desktop; do
            sudo -u "$USERNAME" mkdir -p "$dest/$ch"
            cfgdir="/home/$USERNAME/.config/xfce4/xfconf/xfce-perchannel-xml"
            if [[ -d "$cfgdir" ]]; then
              for f in "$cfgdir"/$ch*.xml; do
                [[ -f "$f" ]] && cp -a "$f" "$dest/$ch"/ || true
              done
            fi
          done
          echo "$dest"
        }

        apply_undercover(){
          # GTK / Icons / Fonts
          run_u -c xsettings -p /Net/ThemeName -s "$GTK_THEME" || true
          run_u -c xsettings -p /Net/IconThemeName -s "$ICON_THEME" || true
          run_u -c xsettings -p /Gtk/FontName -s "$FONT" || true
          # Window manager theme (keeps Qubes label coloring with 'Default')
          run_u -c xfwm4 -p /general/theme -s "$WM_THEME" || true
          # Panel: move main panel to bottom, set size; try panel-1 first
          if run_u -c xfce4-panel -p /panels -l >/dev/null 2>&1; then
            # Use panel-1 if present; else first panel id
            pid="panel-1"
            if ! run_u -c xfce4-panel -p /panels/panel-1 -l >/dev/null 2>&1; then
              pid=$(run_u -c xfce4-panel -p /panels -t string -l 2>/dev/null | head -n1 | awk '{print $NF}')
              [[ -z "$pid" ]] && pid="panel-1"
            fi
            # Position: bottom (p=8); Xfce stores as 'p=<num>;x=0;y=0'
            case "$PANEL_POS" in
              bottom) pos="p=8;x=0;y=0" ;;
              top)    pos="p=2;x=0;y=0" ;;
              left)   pos="p=4;x=0;y=0" ;;
              right)  pos="p=10;x=0;y=0" ;;
              *)      pos="p=8;x=0;y=0" ;;
            esac
            run_u -c xfce4-panel -p /panels/$pid/position -s "$pos" || true
            # Size (row size in pixels)
            run_u -c xfce4-panel -p /panels/$pid/size -s "$PANEL_SIZE" || true
            run_u -c xfce4-panel -p /panels/$pid/size-adjust -s false || true
            # Clock plugin format (if clock exists, try plugin ids commonly used)
            # Iterate all plugin ids and set on any 'clock' plugin
            for id in $(run_u -c xfce4-panel -p /plugins -t string -l 2>/dev/null | awk '{print $NF}'); do
              t=$(run_u -c xfce4-panel -p /plugins/$id/plugin -l 2>/dev/null || true)
              [[ "$t" == "clock" ]] && run_u -c xfce4-panel -p /plugins/$id/digital-time-format -s "$CLOCK_FMT" || true
              [[ "$t" == "clock" ]] && run_u -c xfce4-panel -p /plugins/$id/mode -s 2 || true  # digital mode
            done
          fi
          # Subtle compositor tweaks (slightly reduce “Linux-y” shadows)
          run_u -c xfwm4 -p /general/use_compositing -s true || true
          run_u -c xfwm4 -p /general/frame_opacity -s 100 || true
        }

        restore_latest(){
          bdir="$BACKUP_DIR/$(ls -1 "$BACKUP_DIR" 2>/dev/null | sort | tail -n1)"
          [[ -d "$bdir" ]] || { echo "No backup found in $BACKUP_DIR"; exit 1; }
          dest="/home/$USERNAME/.config/xfce4/xfconf/xfce-perchannel-xml"
          for ch in xsettings xfwm4 xfce4-panel xfce4-desktop; do
            for f in "$bdir/$ch"/*.xml; do
              [[ -f "$f" ]] && install -m 600 -o "$USERNAME" -g "$USERNAME" "$f" "$dest/"
            done
          done
          # Signal panel to reload
          sudo -u "$USERNAME" xfce4-panel -r || true
        }

        usage(){ echo "Usage: $0 [--apply|--revert|--status]"; }

        case "${1:---apply}" in
          --apply)
            mkdir -p "$BACKUP_DIR"
            bk=$(save_backup)
            echo "Backup saved to: $bk"
            apply_undercover
            sudo -u "$USERNAME" xfce4-panel -r || true
            echo "Undercover mode applied."
            ;;
          --revert)
            restore_latest
            echo "Undercover mode reverted (restored latest backup)."
            ;;
          --status)
            echo "GTK: $(sudo -u "$USERNAME" xfconf-query -c xsettings -p /Net/ThemeName 2>/dev/null || echo n/a)"
            echo "Icons: $(sudo -u "$USERNAME" xfconf-query -c xsettings -p /Net/IconThemeName 2>/dev/null || echo n/a)"
            echo "WM theme: $(sudo -u "$USERNAME" xfconf-query -c xfwm4 -p /general/theme 2>/dev/null || echo n/a)"
            echo "Panel pos: $(sudo -u "$USERNAME" xfconf-query -c xfce4-panel -p /panels/panel-1/position 2>/dev/null || echo n/a)"
            ;;
          *) usage; exit 2 ;;
        esac

# Ensure backup directory exists
dom0-undercover-backupdir:
  file.directory:
    - name: {{ u.get('backup_dir', '/var/lib/qubes/undercover-backups') }}
    - mode: '0750'
    - user: root
    - group: root

# Optionally apply immediately
{% if u.get('enabled', False) %}
dom0-undercover-apply-now:
  cmd.run:
    - name: "{{ u.get('toggle_script_path', '/usr/local/sbin/dom0-undercover-toggle.sh') }} --apply"
    - require:
      - file: dom0-undercover-toggle-script
      - file: dom0-undercover-backupdir
{% endif %}



# # Apply (dom0)
# sudo qubesctl --all state.apply osi_model_security
# # Manually toggle later:
# sudo /usr/local/sbin/dom0-undercover-toggle.sh --apply
# sudo /usr/local/sbin/dom0-undercover-toggle.sh --status
# sudo /usr/local/sbin/dom0-undercover-toggle.sh --revert
