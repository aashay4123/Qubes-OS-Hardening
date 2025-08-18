# /srv/salt/qubes/policies/lockdown.sls
/etc/qubes/policy.d/30-user-lockdown.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        ########################
        # Qubes lockdown policy
        ########################

        # --- Maintenance override: if either side is tagged 'maint', allow
        qubes.*  +allow-all-names        @tag:maint      allow
        qubes.*   @tag:maint  +allow-all-names           allow

        # --- Hard denials
        qubes.VMShell+allow-all-names* deny notify=yes

        # --- Vault: deny inbound; allow outbound on ask
        qubes.ClipboardPaste   vault    +allow-all-names       deny notify=yes
        qubes.Filecopy         vault    +allow-all-names       deny notify=yes
        qubes.ClipboardCopy   +allow-all-names        @tag:vault   allow
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
        qubes.OpenInDisposableVM  +allow-all-names  +allow-all-names  allow target=@dispvm:dvm-offline default_target=@dispvm:dvm-offline

        # --- Keep tor profiles self-contained
        qubes.Filecopy         @tag:tor        +allow-all-names     deny notify=yes
        qubes.Filecopy         @tag:tor        @tag:tor             ask
        qubes.ClipboardPaste   @tag:tor        +allow-all-names     deny notify=yes
        qubes.ClipboardPaste   @tag:tor        @tag:tor             ask


        # Deny clipboard/filecopy across personas; allow within same-tag domain
        # Persona tags: persona-work, persona-dev, persona-personal, persona-research, persona-forums

        qubes.ClipboardPaste  @tag:persona-work     @tag:persona-work     allow
        qubes.ClipboardPaste  @tag:persona-work     @anyvm                 deny notify=yes
        qubes.ClipboardPaste  @tag:persona-dev      @tag:persona-dev      allow
        qubes.ClipboardPaste  @tag:persona-dev      @anyvm                 deny notify=yes
        qubes.ClipboardPaste  @tag:persona-personal @tag:persona-personal allow
        qubes.ClipboardPaste  @tag:persona-personal @anyvm                 deny notify=yes
        qubes.ClipboardPaste  @tag:persona-research @tag:persona-research allow
        qubes.ClipboardPaste  @tag:persona-research @anyvm                 deny notify=yes
        qubes.ClipboardPaste  @tag:persona-forums   @tag:persona-forums   allow
        qubes.ClipboardPaste  @tag:persona-forums   @anyvm                 deny notify=yes

        qubes.Filecopy        @tag:persona-work     @tag:persona-work     ask
        qubes.Filecopy        @tag:persona-work     @anyvm                 deny notify=yes
        qubes.Filecopy        @tag:persona-dev      @tag:persona-dev      ask
        qubes.Filecopy        @tag:persona-dev      @anyvm                 deny notify=yes
        qubes.Filecopy        @tag:persona-personal @tag:persona-personal ask
        qubes.Filecopy        @tag:persona-personal @anyvm                 deny notify=yes
        qubes.Filecopy        @tag:persona-research @tag:persona-research ask
        qubes.Filecopy        @tag:persona-research @anyvm                 deny notify=yes
        qubes.Filecopy        @tag:persona-forums   @tag:persona-forums   ask
        qubes.Filecopy        @tag:persona-forums   @anyvm                 deny notify=yes

        # --- Fallbacks
        qubes.Filecopy         +allow-all-names  +allow-all-names  ask
        qubes.OpenURL          +allow-all-names  +allow-all-names  ask
        qubes.ClipboardCopy    +allow-all-names  +allow-all-names  ask
        qubes.ClipboardPaste   +allow-all-names  +allow-all-names  ask

        qubes.Filecopy    +allow-all-names    @anyvm    @anyvm    deny notify=yes
        qubes.ClipboardPaste  +allow-all-names    @anyvm    @anyvm    deny notify=yes
        qubes.OpenURL    +allow-all-names    @anyvm    @anyvm    deny notify=yes
        qubes.VMShell    +allow-all-names    @anyvm    @anyvm    deny notify=yes

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
