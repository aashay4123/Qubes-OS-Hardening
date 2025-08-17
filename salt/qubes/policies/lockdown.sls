# /srv/salt/qubes/policies/lockdown.sls
/etc/qubes/policy.d/30-user-lockdown.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        ########################
        # Qubes lockdown policy
        ########################

        # --- Maintenance override: if either side is tagged 'maint', allow
        qubes.*   *         @tag:maint      allow
        qubes.*   @tag:maint   *            allow

        # --- Hard denials
        qubes.VMShell * * deny notify=yes

        # --- Vault: deny inbound; allow outbound on ask
        qubes.ClipboardPaste   vault     *        deny notify=yes
        qubes.Filecopy         vault     *        deny notify=yes
        qubes.ClipboardCopy    *         @tag:vault   allow
        qubes.Filecopy         @default  @tag:vault   ask

        # --- Trust groups (add tags via Salt or CLI)
        # trusted: work/personal/dev ; untrusted: hack/kodachi ; tor: anon-tor*
        qubes.Filecopy         @tag:trusted @tag:trusted allow
        qubes.Filecopy         @tag:untrusted @tag:trusted deny notify=yes
        qubes.Filecopy         @tag:trusted   @tag:untrusted deny notify=yes

        qubes.ClipboardPaste   @tag:trusted   @tag:untrusted deny notify=yes
        qubes.ClipboardPaste   @tag:trusted   @tag:trusted   ask

        # --- Block untrusted popping URLs in trusted VMs
        qubes.OpenURL          @tag:trusted   @tag:untrusted  deny notify=yes
        qubes.OpenURL          @tag:trusted   @tag:trusted    ask

        # --- Force offline DVM for "Open in DisposableVM"
        qubes.OpenInDisposableVM  *  *  allow target=@dispvm:dvm-offline default_target=@dispvm:dvm-offline

        # --- Keep tor profiles self-contained
        qubes.Filecopy         @tag:tor        *              deny notify=yes
        qubes.Filecopy         @tag:tor        @tag:tor       ask
        qubes.ClipboardPaste   @tag:tor        *              deny notify=yes
        qubes.ClipboardPaste   @tag:tor        @tag:tor       ask

        # --- Fallbacks
        qubes.Filecopy         *  *  ask
        qubes.OpenURL          *  *  ask
        qubes.ClipboardCopy    *  *  ask
        qubes.ClipboardPaste   *  *  ask
        
        # Only sys-net can access networking hardware
        qubes.DeviceNetwork    *        sys-net           allow
        qubes.DeviceNetwork    *        @anyvm            deny  notify=yes

        # Block mic/cam except specific domains
        qubes.DeviceMic        *        @tag:work-allowed allow
        qubes.DeviceMic        *        @anyvm            deny  notify=yes
        qubes.DeviceCamera     *        @tag:work-allowed allow
        qubes.DeviceCamera     *        @anyvm            deny  notify=yes

# Tagging
tag-trusted:
  qvm.tag:
    - name: @tag:trusted
    - vm: [ work, personal, dev ]

tag-untrusted:
  qvm.tag:
    - name: @tag:untrusted
    - vm: [ hack ]  # add kodachi after you install it

tag-tor:
  qvm.tag:
    - name: @tag:tor
    - vm: [ anon-tor1, anon-tor2 ]

tag-vault:
  qvm.tag:
    - name: @tag:vault
    - vm: [ vault-secrets, vault-storage ]
