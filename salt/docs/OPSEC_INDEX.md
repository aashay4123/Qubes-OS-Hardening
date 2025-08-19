# OPSEC Playbook (High-Threat Edition)

**Purpose:** A practical, enforceable handbook for operating Qubes OS under a nation-state threat model with anonymity requirements.

**What this includes**

- Hardware/Firmware isolation
- Qubes topology & policies
- Persona management & spoofing (consistent)
- Content sanitization & publishing
- Communications discipline
- Monitoring & detection (what to watch)
- Travel/mobile OPSEC
- Incident response
- Daily/Weekly/Monthly/Quarterly checklists

**How this meshes with Salt**

- Use the Salt bundles you built (e.g., `normaliza.sls`, spoofing personas, sys-tor-gw, publish suite).
- This book tells you _what to do, when_, and _why_.

**Files**

1. `01_HARDWARE_FIRMWARE.md`
2. `02_QUBES_TOPOLOGY.md`
3. `03_PERSONAS.md`
4. `04_SPOOFING_BASELINES.md`
5. `05_CONTENT_SANITIZATION.md`
6. `06_COMMUNICATIONS.md`
7. `07_MONITORING_DETECTION.md`
8. `08_TRAVEL_MOBILE.md`
9. `09_INCIDENT_RESPONSE.md`
10. `10_CHECKLISTS.md`
11. `11_POLICIES_QUICKREF.md`
12. `12_LIMITS_RISKS.md`

> Golden rule: **Consistency beats cleverness.** Never mix fingerprints, accounts, or workflows across personas.
