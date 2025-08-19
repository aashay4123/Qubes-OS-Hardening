# 1) Hardware & Firmware Isolation

## 1.1 Threat model anchors

- Assume physical access is possible.
- Assume ISP and global passive monitoring is real.
- Assume supply-chain tampering is possible but not certain.

## 1.2 Platform setup (minimums)

- **UEFI/BIOS**

  - Set strong firmware password; disable boot from external media.
  - Disable Intel AMT/Manageability if present; disable Wake-on-LAN.
  - Prefer **IOMMU/VT-d** and **UEFI** boot; enable Secure Boot if using Heads/TrenchBoot variant, else keep it consistent with your boot chain.

- **TPM 2.0**

  - Enable TPM 2.0 in firmware.
  - Plan for **measured boot** (e.g., Heads/TrenchBoot) if your hardware supports it; otherwise use your template hashing/attestation scripts.

- **Peripherals**

  - Physically disable/cover cameras & mics.
  - Use a **USB isolation VM (sys-usb)**; never attach untrusted USBs directly to sensitive VMs.
  - Prefer wired Ethernet. If using Wi-Fi, randomize MAC via sys-net OUI helper.

- **Storage**
  - Full disk encryption (Qubes installer).
  - Keep **cold spares** of SSDs for fast reimage.
  - Maintain **golden templates** offline on read-only media.

## 1.3 Heads/TrenchBoot (if feasible)

- Measure boot chain to TPM, pin secrets to known-good PCRs.
- Signal on tamper and refuse to decrypt if measurements differ.
- Keep signed/verified updates only; maintain a “known-good” sealed set.

## 1.4 EMSEC / Side-channels (optional hard mode)

- Faraday pouch for mobile use; avoid active radios.
- Don’t work with sensitive data in public/near glass walls (shoulder-surf/laser mic).
- Avoid speakers; keep audio devices disabled except in `sys-audio` when required.

## 1.5 Maintenance

- Firmware updates on a fixed schedule (quarterly) and after relevant QSB/XSA.
- Maintain a hardware inventory of all serials; if they change unexpectedly → investigate.
