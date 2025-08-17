     
# Block accidental NIC attachment to untrusted VMs
/etc/qubes/policy.d/30-network-devices.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        device.pci attach  @anyvm   sys-net   allow
        device.pci attach  @anyvm   @anyvm    deny  notify=yes
        
# Input devices (keyboard/mouse → dom0 via sys-usb only)
/etc/qubes/policy.d/30-input.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        # Allow only sys-usb to proxy input into dom0; deny everyone else.
        qubes.InputKeyboard  sys-usb  dom0  allow
        qubes.InputKeyboard  *       dom0  deny  notify=yes

        qubes.InputMouse     sys-usb  dom0  allow
        qubes.InputMouse     *       dom0  deny  notify=yes

        # Only sys-net can access networking hardware
        qubes.DeviceNetwork    *        sys-net           allow
        qubes.DeviceNetwork    *        @anyvm            deny  notify=yes

        # Block mic/cam except specific domains
        qubes.DeviceMic        *        @tag:work-allowed allow
        qubes.DeviceMic        *        @anyvm            deny  notify=yes
        qubes.DeviceCamera     *        @tag:work-allowed allow
        qubes.DeviceCamera     *        @anyvm            deny  notify=yes

# Device policies
/etc/qubes/policy.d/30-devices.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        # Deny USB to vaults and tor profiles and hack by default
        device.usb attach  @anyvm   vault-secrets    deny   notify=yes
        device.usb attach  @anyvm   vault-storage    deny   notify=yes
        device.usb attach  @anyvm   @tag:tor        deny   notify=yes
        device.usb attach  @anyvm   hack            deny   notify=yes

        
        # GENERAL RULE: only sys-net is allowed to attach USB devices from sys-usb.
        # Everything else is denied by default.
        device.usb attach  sys-net   sys-usb  allow
        device.usb attach  @anyvm    sys-usb  deny  notify=yes

        # If you want stricter "only USB NICs" allow-list, add VID:PID specific lines like:
        # device.usb attach  sys-net  sys-usb  allow  device=0bda:8153   # Realtek RTL8153

        # Ask for all other USB attaches
        device.usb attach  @anyvm   @anyvm          ask

        # (Optional) PCI devices (e.g. cameras on internal USB bridges) — ask by default
        device.pci attach  @anyvm   @anyvm          ask
   