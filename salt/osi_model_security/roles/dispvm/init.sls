{% from "osi_model_security/map.jinja" import cfg with context %}

{# ---------------------------
   Disposables helper role
   - Create named DVM templates (AppVMs with template_for_dispvms=True)
   - Set system & per-VM default_dispvm
   - Install qrexec policies to force @dispvm for URLs/files from tagged VMs
   --------------------------- #}

{# 1) Create named DVM templates #}
{% for dvm_name, spec in cfg.disposables.create.items() %}

{{ dvm_name }}-present:
  qvm.present:
    - name: {{ dvm_name }}
    - template: {{ spec.template }}
    - label: {{ spec.get('label', 'gray') }}

{{ dvm_name }}-prefs:
  qvm.prefs:
    - name: {{ dvm_name }}
    - key: template_for_dispvms
    - value: True
  require:
    - qvm: {{ dvm_name }}-present

{% if spec.get('netvm') %}
{{ dvm_name }}-netvm:
  qvm.prefs:
    - name: {{ dvm_name }}
    - key: netvm
    - value: {{ spec.netvm }}
  require:
    - qvm: {{ dvm_name }}-present
{% endif %}

{% endfor %}

{# 2) Set system default DispVM (dom0 global) #}
{% if cfg.disposables.default_dispvm %}
dispvm-global-default:
  cmd.run:
    - name: "qubes-prefs -s default_dispvm {{ cfg.disposables.default_dispvm }}"
{% endif %}

{# 3) Set per-VM default DispVM #}
{% for vmname, dvm in cfg.disposables.per_vm_default.items() %}
{{ vmname }}-default-dispvm:
  qvm.prefs:
    - name: {{ vmname }}
    - key: default_dispvm
    - value: {{ dvm }}
{% endfor %}

{# 4) qrexec policy: force @dispvm for tagged VMs #}
# Qubes 4.2+ policy location & syntax. See: /etc/qubes/policy.d/*  (qubes.OpenURL / qubes.OpenInVM)
# Docs: "How to use disposables" & "Disposable customization" + qrexec services overview.
dispvm-policy-openurl:
  file.managed:
    - name: /etc/qubes/policy.d/33-dispvm-openurl.policy
    - mode: '0644'
    - contents: |
        # Force tagged VMs to open URLs in a DisposableVM
        # FROM: tag::<tag>   TO: anyvm   ACTION: allow target=@dispvm:<name>
        {% for t in cfg.disposables.force_policies.openurl_tags %}
        qubes.OpenURL * @tag:{{ t }} @anyvm allow target=@dispvm:{{ cfg.disposables.default_dispvm }}
        {% endfor %}
        # Fallback for others:
        qubes.OpenURL * @anyvm @anyvm {{ cfg.disposables.fallback.openurl }}

dispvm-policy-openinvm:
  file.managed:
    - name: /etc/qubes/policy.d/34-dispvm-openinvm.policy
    - mode: '0644'
    - contents: |
        # Force tagged VMs to open files in a DisposableVM (redirect OpenInVM)
        {% for t in cfg.disposables.force_policies.openinvm_tags %}
        qubes.OpenInVM * @tag:{{ t }} @anyvm allow target=@dispvm:{{ cfg.disposables.default_dispvm }}
        {% endfor %}
        # Fallback for others:
        qubes.OpenInVM * @anyvm @anyvm {{ cfg.disposables.fallback.openinvm }}
