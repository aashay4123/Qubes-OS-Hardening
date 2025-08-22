{% from "osi_model_security/map.jinja" import cfg with context %}
{% set sec = cfg.secrets %}
{% set v_gpg = sec.vaults.get('gpg') %}
{% set v_ssh = sec.vaults.get('ssh') %}
{% set v_pas = sec.vaults.get('pass') %}

# --------- A) Split-GPG per-operation policies + wrappers ---------

# dom0 policies (Qubes 4.2+ policy.d syntax). Custom services: gpg.Sign / gpg.Decrypt / gpg.Encrypt / gpg.Verify
dom0-policy-gpg-ops:
  file.managed:
    - name: /etc/qubes/policy.d/40-gpg-ops.policy
    - mode: '0644'
    - contents: |
        # Sign
        {% for t in sec.ops_allow_from_tags.get('sign', []) %}gpg.Sign * @tag:{{ t }} @anyvm allow target={{ v_gpg }}
        {% endfor %}
        gpg.Sign * @anyvm @anyvm deny

        # Decrypt
        {% for t in sec.ops_allow_from_tags.get('decrypt', []) %}gpg.Decrypt * @tag:{{ t }} @anyvm allow target={{ v_gpg }}
        {% endfor %}
        gpg.Decrypt * @anyvm @anyvm deny

        # Encrypt
        {% for t in sec.ops_allow_from_tags.get('encrypt', []) %}gpg.Encrypt * @tag:{{ t }} @anyvm allow target={{ v_gpg }}
        {% endfor %}
        gpg.Encrypt * @anyvm @anyvm deny

        # Verify
        {% for t in sec.ops_allow_from_tags.get('verify', []) %}gpg.Verify * @tag:{{ t }} @anyvm allow target={{ v_gpg }}
        {% endfor %}
        gpg.Verify * @anyvm @anyvm deny

# Vault-side RPC service shims to implement the custom ops
{% if v_gpg %}
{{ v_gpg }}-gpg-rpc-shims:
  module.run:
    - name: qvm.run
    - vm: {{ v_gpg }}
    - args:
      - |
        sh -lc '
          install -d /etc/qubes-rpc
          # Each service reads stdin (for data) and arguments via $1..; minimal wrappers.
          cat >/etc/qubes-rpc/gpg.Sign <<'\''EOF'\''
          #!/bin/sh
          # Usage: echo data | qrexec-client-vm <vault> gpg.Sign "--local-user" KEYID "--detach-sign" "--armor"
          exec gpg --batch --yes "$@"    # caller passes desired flags; data from stdin
          EOF
          chmod 0755 /etc/qubes-rpc/gpg.Sign

          cat >/etc/qubes-rpc/gpg.Verify <<'\''EOF'\''
          #!/bin/sh
          # Usage: qrexec-client-vm <vault> gpg.Verify --verify /tmp/sig -  < file
          exec gpg --batch --yes "$@"
          EOF
          chmod 0755 /etc/qubes-rpc/gpg.Verify

          cat >/etc/qubes-rpc/gpg.Encrypt <<'\''EOF'\''
          #!/bin/sh
          # Usage: echo plaintext | qrexec-client-vm <vault> gpg.Encrypt --encrypt -r RECIPIENT --armor
          exec gpg --batch --yes "$@"
          EOF
          chmod 0755 /etc/qubes-rpc/gpg.Encrypt

          cat >/etc/qubes-rpc/gpg.Decrypt <<'\''EOF'\''
          #!/bin/sh
          # Usage: cat msg.asc | qrexec-client-vm <vault> gpg.Decrypt --decrypt
          exec gpg --batch --yes "$@"
          EOF
          chmod 0755 /etc/qubes-rpc/gpg.Decrypt
        '
{% endif %}

# Client convenience wrappers (non-invasive; advanced_wrappers can be turned off)
{% set app_templates = [] %}
{% for _, spec in cfg.app_vms.items() %}
  {% if spec.get('template') %}{% do app_templates.append(spec.get('template')) %}{% endif %}
{% endfor %}
{% if sec.client.advanced_wrappers %}
{% for tpl in app_templates|unique %}
template-{{ tpl }}-gpg-op-wrappers:
  module.run:
    - name: qvm.run
    - vm: {{ tpl }}
    - args:
      - |
        sh -lc '
          install -d /usr/local/bin
          cat >/usr/local/bin/qgpg-sign <<EOF
          #!/bin/sh
          # echo data | qgpg-sign --local-user KEYID --detach-sign --armor
          exec qrexec-client-vm {{ v_gpg }} gpg.Sign "$@"
          EOF
          chmod 0755 /usr/local/bin/qgpg-sign

          cat >/usr/local/bin/qgpg-decrypt <<EOF
          #!/bin/sh
          # cat msg.asc | qgpg-decrypt --decrypt
          exec qrexec-client-vm {{ v_gpg }} gpg.Decrypt "$@"
          EOF
          chmod 0755 /usr/local/bin/qgpg-decrypt

          cat >/usr/local/bin/qgpg-encrypt <<EOF
          #!/bin/sh
          # echo plaintext | qgpg-encrypt --encrypt -r RECIPIENT --armor
          exec qrexec-client-vm {{ v_gpg }} gpg.Encrypt "$@"
          EOF
          chmod 0755 /usr/local/bin/qgpg-encrypt

          cat >/usr/local/bin/qgpg-verify <<EOF
          #!/bin/sh
          exec qrexec-client-vm {{ v_gpg }} gpg.Verify "$@"
          EOF
          chmod 0755 /usr/local/bin/qgpg-verify
        '
{% endfor %}
{% endif %}

# --------- B) Time-boxed maintenance tag (import/export) ---------

# dom0: policy allowing admin ops only for requestors with maintenance tag
dom0-policy-gpg-maint:
  file.managed:
    - name: /etc/qubes/policy.d/43-gpg-maint.policy
    - mode: '0644'
    - contents: |
        gpg.AdminImport * @tag:{{ sec.maintenance.tag }} @anyvm allow target={{ v_gpg }}
        gpg.AdminExport * @tag:{{ sec.maintenance.tag }} @anyvm allow target={{ v_gpg }}
        gpg.AdminImport * @anyvm @anyvm deny
        gpg.AdminExport * @anyvm @anyvm deny

# Vault-side RPC for admin ops
{% if v_gpg %}
{{ v_gpg }}-gpg-admin-rpc:
  module.run:
    - name: qvm.run
    - vm: {{ v_gpg }}
    - args:
      - |
        sh -lc '
          install -d /etc/qubes-rpc
          cat >/etc/qubes-rpc/gpg.AdminImport <<'\''EOF'\''
          #!/bin/sh
          # Import key material (stdin)
          exec gpg --import
          EOF
          chmod 0755 /etc/qubes-rpc/gpg.AdminImport

          cat >/etc/qubes-rpc/gpg.AdminExport <<'\''EOF'\''
          #!/bin/sh
          # Export public/secret keys based on args, e.g. "--armor --export-secret-keys KEYID"
          exec gpg "$@"
          EOF
          chmod 0755 /etc/qubes-rpc/gpg.AdminExport
        '
{% endif %}

# dom0: helper to add/remove the maintenance tag with auto-expiry using systemd-run
dom0-maint-tool:
  file.managed:
    - name: /usr/local/sbin/qubes-secrets-maint
    - mode: '0755'
    - contents: |
        #!/bin/bash
        set -euo pipefail
        TAG="{{ sec.maintenance.tag }}"
        DURATION="{{ sec.maintenance.minutes }}m"
        usage(){ echo "Usage: $0 add|del <vm> [minutes]"; exit 2; }
        [[ $# -lt 2 ]] && usage
        cmd="$1"; vm="$2"; dur="${3:-$DURATION}"
        case "$cmd" in
          add)
            qvm-tags "$vm" -a "$TAG"
            systemd-run --unit="rm-tag-$TAG-$vm-$(date +%s)" --on-active="$dur" \
              /usr/bin/qvm-tags "$vm" -d "$TAG" >/dev/null
            echo "Added tag $TAG to $vm for $dur"
            ;;
          del)
            qvm-tags "$vm" -d "$TAG" || true
            echo "Removed tag $TAG from $vm"
            ;;
          *) usage ;;
        esac

# Client wrappers for admin ops (optional)
{% if sec.client.advanced_wrappers %}
{% for tpl in app_templates|unique %}
template-{{ tpl }}-gpg-admin-wrappers:
  module.run:
    - name: qvm.run
    - vm: {{ tpl }}
    - args:
      - |
        sh -lc '
          install -d /usr/local/bin
          cat >/usr/local/bin/qgpg-import <<EOF
          #!/bin/sh
          # usage: qgpg-import < file.asc
          exec qrexec-client-vm {{ v_gpg }} gpg.AdminImport
          EOF
          chmod 0755 /usr/local/bin/qgpg-import

          cat >/usr/local/bin/qgpg-export <<EOF
          #!/bin/sh
          # usage: qgpg-export --armor --export-secret-keys KEYID
          exec qrexec-client-vm {{ v_gpg }} gpg.AdminExport "$@"
          EOF
          chmod 0755 /usr/local/bin/qgpg-export
        '
{% endfor %}
{% endif %}

# --------- C) qrexec audit logging in dom0 ---------

{% if sec.logging.enable_audit_log %}
dom0-qrexec-audit:
  file.managed:
    - name: /etc/rsyslog.d/40-qrexec-secrets.conf
    - mode: '0644'
    - contents: |
        # Mirror qrexec policy entries related to secrets into a dedicated file
        module(load="imfile")
        input(type="imfile" File="/var/log/qubes/qrexec-policy.log" Tag="qrexec.policy:")
        if ($programname == "qrexec.policy") and ($msg contains "service=") and re_match($msg, "{{ sec.logging.services_regex }}") then {
          action(type="omfile" file="/var/log/qubes/audit-secrets.log")
        }
dom0-qrexec-audit-restart:
  cmd.run:
    - name: systemctl restart rsyslog
    - require:
      - file: dom0-qrexec-audit
{% endif %}
