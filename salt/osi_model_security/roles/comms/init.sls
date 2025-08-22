{% from "osi_model_security/map.jinja" import cfg with context %}
{% set C = cfg.clock_comms %}
{% set P = C.policies %}
{% set disp = C.dispvm_default %}
{% set sys_usb = P.sys_usb %}

/etc/qubes/policy.d/25-comms.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        # ===== Inter-qube communications hardening =====
        # Everything not listed explicitly → deny, with notify.

        ## File copy (qfilecopy)
        {% for t in P.filecopy_allow_tags %}
        qubes.Filecopy * @tag:{{ t }} @tag:{{ t }} ask,default_target=@dispvm
        {% endfor %}
        qubes.Filecopy * @anyvm @anyvm deny notify=yes

        ## Open in VM / Open in Disposable
        {% for t in P.openinvm_allow_tags %}
        qubes.OpenInVM * @tag:{{ t }} @tag:{{ t }} ask
        {% endfor %}
        qubes.OpenInVM * @anyvm @anyvm deny notify=yes

        {% for t in P.openindisp_allow_tags %}
        qubes.OpenInDisposableVM * @tag:{{ t }} @anyvm ask,default_target=@dispvm
        qubes.OpenInDisposable *  @tag:{{ t }} @anyvm ask,default_target=@dispvm
        {% endfor %}
        qubes.OpenInDisposableVM * @anyvm @anyvm deny notify=yes
        qubes.OpenInDisposable  * @anyvm @anyvm deny notify=yes

        ## Open URL (force into DispVM by default)
        {% for t in P.openurl_allow_tags %}
        qubes.OpenURL * @tag:{{ t }} @anyvm ask,default_target=@dispvm
        {% endfor %}
        qubes.OpenURL * @anyvm @anyvm deny notify=yes

        ## Clipboard (paste decision on target side)
        {% for t in P.clipboard_allow_tags %}
        qubes.ClipboardPaste * @tag:{{ t }} @tag:{{ t }} ask
        qubes.ClipboardCopy  * @tag:{{ t }} @tag:{{ t }} allow
        {% endfor %}
        qubes.ClipboardPaste * @anyvm @anyvm deny notify=yes
        qubes.ClipboardCopy  * @anyvm @anyvm deny notify=yes

        ## U2F / WebAuthn (proxy via sys-usb only, select tags)
        {% for t in P.u2f_allow_tags %}
        qubes.U2F *       @tag:{{ t }} @anyvm allow target={{ sys_usb }}
        qubes.WebAuthn *  @tag:{{ t }} @anyvm allow target={{ sys_usb }}
        {% endfor %}
        qubes.U2F *      @anyvm @anyvm deny notify=yes
        qubes.WebAuthn * @anyvm @anyvm deny notify=yes

# Hint the default DispVM (best effort, no fail if missing)
dispvm-hint:
  cmd.run:
    - name: qubes-prefs -s default_dispvm {{ disp }}
    - unless: test "$(qubes-prefs default_dispvm 2>/dev/null)" = "{{ disp }}"
