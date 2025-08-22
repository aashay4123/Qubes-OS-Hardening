{% from "osi_model_security/map.jinja" import cfg, templates with context %}

{% for tpl in templates %}
template-{{ tpl }}-crypto:
  module.run:
    - name: qvm.run
    - vm: {{ tpl }}
    - args:
      - |
        sh -lc '
          if command -v apt-get >/dev/null; then
            apt-get update
            apt-get -y install openssh-client gnutls-bin chrony
            # Debian OpenSSL policy
            mkdir -p /etc/ssl/openssl.cnf.d
            cat >/etc/ssl/openssl.cnf.d/40-system-policy.cnf <<EOF
            [system_default_sect]
            MinProtocol = TLSv1.2
            CipherString = DEFAULT@SECLEVEL={{ 3 if cfg.strict_crypto else cfg.transport.debian_openssl_seclevel }}
            Options = ServerPreference,PrioritizeChaCha
            EOF
            # GnuTLS policy
            cat >/etc/gnutls/config <<EOF
            [overrides]
            tls-disabled-versions = SSL3.0 TLS1.0 TLS1.1
            insecure-hash = md5
            EOF
            # Chrony with NTS
            sed -i "s/^pool .*/# disabled by Salt/" /etc/chrony/chrony.conf || true
            if ! grep -q nts /etc/chrony/chrony.conf; then
              echo "server {{ cfg.transport.chrony_nts_server }} iburst nts" >>/etc/chrony/chrony.conf
              echo "rtcsync" >>/etc/chrony/chrony.conf
              echo "makestep 1.0 3" >>/etc/chrony/chrony.conf
            fi
            systemctl enable chrony || true; systemctl restart chrony || true
          else
            dnf -y install chrony || true
            {% if cfg.strict_crypto %}update-crypto-policies --set FUTURE || true{% else %}update-crypto-policies --set DEFAULT || true{% endif %}
            sed -i "s/^pool .*/# disabled by Salt/" /etc/chrony.conf || true
            if ! grep -q nts /etc/chrony.conf; then
              echo "server {{ cfg.transport.chrony_nts_server }} iburst nts" >>/etc/chrony.conf
            fi
            systemctl enable chronyd || true; systemctl restart chronyd || true
          fi
          # SSH client hardening
          mkdir -p /etc/ssh/ssh_config.d
          cat >/etc/ssh/ssh_config.d/40-hardening.conf <<EOF
          Host *
            KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
            Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes256-ctr
            MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
            HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com
            PubkeyAuthentication yes
            PasswordAuthentication no
          EOF
        '
{% endfor %}
