# Behavioral Discipline for High-Threat OPSEC

## The Core Principle: “You are the weakest link.”

Everything else is fortified; **how you use it** determines your safety.

---

### 1.1 Thought Framework → Always Assume Observation

- Every keystroke, pattern, rhythm, and choice is potentially logged (organization, ISP, exit node, vendor).
- Operate as if **someone can see you typing** until proven otherwise.

### 1.2 Separation is Everything

- **No cross-persona awareness**: what belongs to persona A must never overlap with persona B.
- Separate passwords, email threads, friends, writing style.
- Treat each VM as a “mind in a box”—don't let the boxes think about each other.

### 1.3 Operational Reliability

- Before session: double-check persona, workflow, VM is correct.
- After session: properly shut down, save artifacts to vault via sanitized flow, clear clipboard.
- Use a mental **activation checklist**: Silence notifications, confirm Tor circuit, confirm logs off.

### 1.4 Language, Tone, Style

- Choose a **voice and stick with it**.
  - Persona A: short sentences, US-centric idioms.
  - Persona B: longer, more formal tone, British spelling, no overlap.
- Rotate writing patterns per persona to avoid stylometry linking.

### 1.5 Time Patterns & Cadence

- Don’t always publish at “exactly 9:00 AM.” Add ± random jitter (say, 15–45 minutes).
- Don’t post same persona at same times daily; spread out.

### 1.6 Metadata Awareness

- Always strip EXIF/metadata from files.
- Know that email timestamps, log submission times, file share names can identify you.

### 1.7 Hygiene & Fatigue

- OPSEC fatigue is real. When tired, pause sensitive operations.
- If you catch yourself reusing a password or crossing personas, **stop everything**, re-evaluate.

---

### Quick Behavioral Checklist (Per Session)

- [ ] Am I in the correct persona VM?
- [ ] Has the VM fingerprint been confirmed?
- [ ] Clipboard/filecopy policies in place?
- [ ] Tor path healthy and isolated?
- [ ] Drafts stored encrypted in Vault only?
- [ ] No cross-persona interaction or reuse of handles?
- [ ] After session: VM shut down, logs wiped, artifacts sanitized, copy released only if sanitized.

---

# Operational Discipline: Do’s & Don’ts

## DO:

- **Build the habit** of always starting a session with “am I in the right persona?”
- **Use DisposableVMs** for any external link, doc preview, or untrusted input.
- **Review final outputs** in a controlled environment (publish template) before release.
- **Trust but verify**: run integrity checks weekly.
- **Automate hygiene** where possible (Salt states, timers).
- **Backup securely** (Vaults and configs) and test restore quarterly.
- **Rotate personas** on regular cadence; retire old ones.
- **Document: date, VM, path, purpose** for sensitive activities.

## DON’T:

- Don’t open personal emails/web sessions in any Tor or persona VM.
- Don’t use real or linking usernames/accounts across personas.
- Don’t leave VMs, especially persona or vault VMs, running idle unattended.
- Don’t ignore UI prompts or policy messages—they're fundamental alarms.
- Don’t install extra software or ad-blockers that may leak behavior (stick to minimal tools).
- Don’t trust browser “private mode”; assume browsing history is fingerprintable.
- Don’t rush setup when mobile or under stress; mistakes compound.
