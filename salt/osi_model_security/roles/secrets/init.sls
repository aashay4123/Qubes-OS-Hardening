{% from "osi_model_security/map.jinja" import cfg with context %}
{% set sec = cfg.secrets %}
{% set vault_gpg  = sec.vaults.get('gpg') %}
{% set vault_ssh  = sec.vaults.get('ssh') %}
{% set vault_pass = sec.vaults.get('pass') %}
{% set allow = sec.get('allow_from_tags', {}) %}
{% set fb   = sec.get('fallback', {'gpg':'ask','ssh':'ask','pass':'ask'}) %}

# ---- Tag the vault VMs for clarity (no changes to your data) ----
{% for v, tag in [(vault_gpg,'vault_gpg'), (vault_ssh,'vault_ssh'), (vault_pass,'vault_pass')] %}
{% if v %}
{{ v }}-tag:
  qvm.tags:
    - name: {{ v }}
    - add: [{{ tag }}]
{% endif %}
{% endfor %}

# ---- dom0 qrexec policies (Qubes 4.2+ syntax; adjust path if on 4.1) ----
# Split-GPG
dom0-policy-split-gpg:
  file.managed:
    - name: /etc/qubes/policy.d/40-split-gpg.policy
    - mode: '0644'
    - contents: |
        # Route GPG requests by *requestor tag* -> GPG vault
        {% for t in allow.get('gpg', []) %}
        qubes.Gpg * @tag:{{ t }} @anyvm allow target={{ vault_gpg }}
        {% endfor %}
        qubes.Gpg * @anyvm @anyvm {{ fb.get('gpg','ask') }}
  require_in:
    - file: dom0-policy-split-ssh
    - file: dom0-policy-qubes-pass

# Split-SSH (agent forwarding)
dom0-policy-split-ssh:
  file.managed:
    - name: /etc/qubes/policy.d/41-split-ssh.policy
    - mode: '0644'
    - contents: |
        # Route SSH agent requests by tag -> SSH vault
        {% for t in allow.get('ssh', []) %}
        qubes.SshAgent * @tag:{{ t }} @anyvm allow target={{ vault_ssh }}
        {% endfor %}
        qubes.SshAgent * @anyvm @anyvm {{ fb.get('ssh','ask') }}

# qubes-pass (password lookup; service name used by qubes-pass)
dom0-policy-qubes-pass:
  file.managed:
    - name: /etc/qubes/policy.d/42-qubes-pass.policy
    - mode: '0644'
    - contents: |
        # Route password lookups by tag -> PASS vault
        {% for t in allow.get('pass', []) %}
        qubes.PassLookup * @tag:{{ t }} @anyvm allow target={{ vault_pass }}
        {% endfor %}
        qubes.PassLookup * @anyvm @anyvm {{ fb.get('pass','ask') }}

# ---- Optional: vault VM bootstrap (no key creation; just tools & agent quality-of-life) ----
{% for v in [vault_gpg, vault_ssh, vault_pass] if v %}
{{ v }}-bootstrap:
  module.run:
    - name: qvm.run
    - vm: {{ v }}
    - args:
      - |
        sh -lc '
          if command -v apt-get >/dev/null; then
            apt-get update || true
            apt-get -y install {{ (sec.packages.vault_debian|join(' ')) if sec.get('packages') else '' }} || true
          elif command -v dnf >/dev/null; then
            dnf -y install {{ (sec.packages.vault_fedora|join(' ')) if sec.get('packages') else '' }} || true
          fi
          # Harden gpg-agent caching a bit (does not touch your keys)
          mkdir -p ~/.gnupg && chmod 700 ~/.gnupg
          grep -q "^default-cache-ttl" ~/.gnupg/gpg-agent.conf 2>/dev/null || echo "default-cache-ttl 300" >> ~/.gnupg/gpg-agent.conf
          grep -q "^max-cache-ttl" ~/.gnupg/gpg-agent.conf 2>/dev/null || echo "max-cache-ttl 3600" >> ~/.gnupg/gpg-agent.conf
          gpgconf --kill gpg-agent || true
        '
{% endfor %}

# ---- Client side: install tools in templates used by your AppVMs; add helpers/env if desired ----
{% set app_templates = [] %}
{% for _, spec in cfg.app_vms.items() %}
  {% if spec.get('template') %}{% do app_templates.append(spec.get('template')) %}{% endif %}
{% endfor %}
{% for tpl in app_templates|unique %}
template-{{ tpl }}-client-tools:
  module.run:
    - name: qvm.run
    - vm: {{ tpl }}
    - args:
      - |
        sh -lc '
          if command -v apt-get >/dev/null; then
            apt-get update || true
            apt-get -y install {{ (sec.packages.client_debian|join(' ')) if sec.get('packages') else '' }} || true
          elif command -v dnf >/dev/null; then
            dnf -y install {{ (sec.packages.client_fedora|join(' ')) if sec.get('packages') else '' }} || true
          fi
          # Optional helpers/wrappers
          {% if sec.client.add_wrappers %}
          install -d /usr/local/bin
          cat >/usr/local/bin/qpass <<EOF
          #!/bin/sh
          # Usage: qpass path/in/pass/store
          exec qrexec-client-vm {{ vault_pass }} qubes.PassLookup "\$1"
          EOF
          chmod 0755 /usr/local/bin/qpass
          cat >/usr/local/bin/qgpg <<'EOF'
          #!/bin/sh
          # Pipe data into split-GPG: echo data | qgpg --sign --local-user KEYID
          exec qubes-gpg-client -- "$@"
          EOF
          chmod 0755 /usr/local/bin/qgpg
          cat >/usr/local/bin/qssh-add <<EOF
          #!/bin/sh
          # Add key inside the SSH vault (forwarded by split-ssh config)
          exec qrexec-client-vm {{ vault_ssh }} qubes.SshAgent "\$@"
          EOF
          chmod 0755 /usr/local/bin/qssh-add
          {% endif %}

          {% if sec.client.set_env_domains %}
          mkdir -p /etc/profile.d
          cat >/etc/profile.d/50-qubes-secrets.sh <<EOF
          # convenience: hints for split-GPG/SSH clients (policy still rules)
          export QUBES_GPG_DOMAIN={{ vault_gpg }}
          export QUBES_SSH_VAULT={{ vault_ssh }}
          EOF
          chmod 0644 /etc/profile.d/50-qubes-secrets.sh
          {% endif %}
        '
{% endfor %}
