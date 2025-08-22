{% from "osi_model_security/map.jinja" import cfg with context %}

{% if 'sys-ids' in cfg.vms %}
sys-ids-suricata:
  module.run:
    - name: qvm.run
    - vm: sys-ids
    - args:
      - |
        sh -lc '
          if command -v apt-get >/dev/null; then
            (dpkg -s suricata >/dev/null 2>&1) || (apt-get update && apt-get -y install suricata)
          else
            rpm -q suricata >/dev/null 2>&1 || dnf -y install suricata
          fi
          # AF_PACKET inline & DNS EVE logs
          sed -i "s/^ *#\? *af-packet:.*/af-packet:/" /etc/suricata/suricata.yaml || true
          if ! grep -q \"af-packet:\" -n /etc/suricata/suricata.yaml; then
            printf \"af-packet:\\n  - interface: eth0\\n    cluster-type: cluster_flow\\n    defrag: yes\\n\" >>/etc/suricata/suricata.yaml
          fi
          if ! grep -q \"outputs:\" /etc/suricata/suricata.yaml; then
            cat >>/etc/suricata/suricata.yaml <<EOF
          outputs:
            - eve-log:
                enabled: yes
                filetype: regular
                filename: /var/log/suricata/eve.json
                types: [dns, flow, anomaly]
          EOF
          fi
          systemctl enable suricata || true
          systemctl restart suricata || true
        '
  require:
    - qvm: sys-ids-present
{% endif %}
