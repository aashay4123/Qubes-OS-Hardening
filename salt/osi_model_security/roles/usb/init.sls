{% from "osi_model_security/map.jinja" import cfg with context %}

# dom0 policy: realistic input + tag-gated storage
dom0-usb-core:
  file.managed:
    - name: /etc/qubes/policy.d/30-usb-core.policy
    - mode: '0644'
    - contents: |
        device+usb * @anyvm @default allow target=sys-usb
        device+usb * @anyvm @anyvm deny

dom0-usb-input:
  file.managed:
    - name: /etc/qubes/policy.d/31-usb-input.policy
    - mode: '0644'
    - contents: |
        qubes.InputKeyboard * sys-usb dom0 ask
        qubes.InputMouse    * sys-usb dom0 ask
        qubes.InputKeyboard * @anyvm @anyvm deny
        qubes.InputMouse    * @anyvm @anyvm deny

dom0-usb-storage:
  file.managed:
    - name: /etc/qubes/policy.d/32-usb-storage.policy
    - mode: '0644'
    - contents: |
        {# allow only tagged VMs; build lines dynamically #}
        {%- for tag in cfg.usb_policy.storage_allowed_tags %}
        device+block * @anyvm @tag:{{ tag }} ask
        {%- endfor %}
        device+block * @anyvm @anyvm deny

# sys-usb: usbguard default-deny + logrotate
{% if 'sys-usb' in cfg.vms %}
sys-usb-usbguard:
  module.run:
    - name: qvm.run
    - vm: sys-usb
    - args:
      - |
        sh -lc '
          if command -v apt-get >/dev/null; then
            (dpkg -s usbguard >/dev/null 2>&1) || (apt-get update && apt-get -y install usbguard)
          else
            rpm -q usbguard >/dev/null 2>&1 || dnf -y install usbguard
          fi
          mkdir -p /etc/usbguard /var/log/usbguard
          usbguard generate-policy > /etc/usbguard/rules.conf
          grep -q "^ImplicitPolicyTarget" /etc/usbguard/usbguard-daemon.conf && \
            sed -i "s/^ImplicitPolicyTarget.*/ImplicitPolicyTarget=block/" /etc/usbguard/usbguard-daemon.conf || \
            echo "ImplicitPolicyTarget=block" >>/etc/usbguard/usbguard-daemon.conf
          grep -q "^PresentDevicePolicy" /etc/usbguard/usbguard-daemon.conf && \
            sed -i "s/^PresentDevicePolicy.*/PresentDevicePolicy=apply-policy/" /etc/usbguard/usbguard-daemon.conf || \
            echo "PresentDevicePolicy=apply-policy" >>/etc/usbguard/usbguard-daemon.conf
          grep -q "^AuditFilePath" /etc/usbguard/usbguard-daemon.conf && \
            sed -i "s|^AuditFilePath.*|AuditFilePath=/var/log/usbguard/audit.log|" /etc/usbguard/usbguard-daemon.conf || \
            echo "AuditFilePath=/var/log/usbguard/audit.log" >>/etc/usbguard/usbguard-daemon.conf
          systemctl enable usbguard || true
          systemctl restart usbguard || true
          cat >/etc/logrotate.d/usbguard <<EOF
          /var/log/usbguard/audit.log {
            weekly
            rotate {{ cfg.dns_tuning.rotate_weeks }}
            compress
            missingok
            notifempty
            create 0640 root root
          }
          EOF
        '
  require:
    - qvm: sys-usb-present
{% endif %}
