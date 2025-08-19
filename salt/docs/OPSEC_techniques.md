# 50 OPSEC Techniques from DNM / DNF Operators (2025 perspective)

### Phase 1: Identity Bootstrapping

1. **Clean slate device acquisition** — no links to real identity, purchased in cash.
2. **Use of burner laptops** with never-connected Wi-Fi cards.
3. **Firmware reflash before first boot** (BIOS/UEFI integrity).
4. **Air-gapped key generation** for PGP, SSH, TLS.
5. **Split keys** — secret split between multiple media (Shamir’s Secret Sharing).
6. **Uniform PGP style** — no unique comment lines in keyblocks.
7. **Pre-burn persona narratives** — backstory consistency (location, slang, posting style).
8. **Language stylometry shielding** — copy/paste + paraphrase to normalize writing.
9. **Timezone consistency** — always align VM clock to persona’s region.
10. **Persona calendar drift** — random offset for logins to avoid exact time windows.

---

### Phase 2: Daily Operational Security

11. **Dedicated opsec rituals** — confirm VM, network, and persona before typing.
12. **Multiple wallets per role** — never reuse deposit/withdrawal addresses.
13. **Tor-only publishing** — no clearnet mirrors (they lead to leaks).
14. **Consistent browser fingerprints** — same font set, same UA, no plugins.
15. **Clipboard scrubbers** — flush on schedule, not just session end.
16. **Regular posting cadence randomization** — prevent timing correlations.
17. **Decoy sessions** — fake logins with dummy content to dilute analysis.
18. **Persona silence days** — days with zero activity to avoid machine-learned rhythm.
19. **Multiple entrance points** — rotate between bridges, pluggable transports.
20. **Consistent file packaging** — all zips/tars with identical tool/version/flags.

---

### Phase 3: Hosting & Infrastructure

21. **Hidden service rotation** — migrate onions quarterly with redirects.
22. **Multi-onion mirrors** — never rely on one .onion hostname.
23. **Template VM rebuilds** — fresh installs for app VMs to avoid drift.
24. **Server binary reproducibility** — compile on trusted, documented build env.
25. **DNS avoidance** — strictly .onion or IP, no domain leaks.
26. **TLS certificate normalization** — if used, mimic Let’s Encrypt defaults.
27. **No uptime bragging** — extended uptime → fingerprintable pattern.
28. **Process isolation** — separate markets forums, wallet, escrow into different VMs.
29. **Hidden admin panel** — non-obvious paths with access-token guard.
30. **No external assets** — images/scripts hosted locally only.

---

### Phase 4: Communications

31. **Strict PGP policy** — no plaintext negotiation, all escrow in PGP.
32. **Standard cipher suites** — don’t stand out by using rare crypto.
33. **User manual enforcement** — teach staff exact PGP command usage.
34. **Compartmentalized handles** — never reuse forum/admin names across contexts.
35. **Persona IP drift** — force VPN+Tor with random exit guards per identity.
36. **Consistent contact style** — same greeting, sign-off, line breaks.
37. **Message length normalization** — pad short responses, clip long ones.
38. **Cautious emoji use** — avoid unique emoji patterns that track.
39. **One-time rendezvous accounts** — disposable jabber/XMPP or email for bridges.
40. **Delayed responses** — intentional hours-long delays to avoid real-time correlation.

---

### Phase 5: Payments & Finance

41. **Fresh wallet each market cycle** — never mix escrow with cold store.
42. **Tumbler/mixer layering** — 2–3 hops before cash-out.
43. **Test withdrawal first** — small amounts before bulk transfer.
44. **Hardware wallet in airgap** — import/export via QR, never USB.
45. **Price normalization** — round BTC/XMR amounts to common values.
46. **Escrow multi-sig** — reduce risk of exit scam suspicion + compromise.
47. **Transaction timing randomization** — not always after X sales.
48. **Avoid “vanity” addresses** — never encode memes or names.
49. **No exchange reuse** — spread across multiple, never log from same IP.
50. **Cold storage burn cycle** — periodically destroy old wallets, migrate funds.

---

✅ These are **realistically observed + evolved techniques**.
DNM/Forum admins usually fail not because the tech was weak, but because of **human pattern leaks**:

- Same writing style across aliases.
- Same login hours (from home).
- Laziness in key handling or password reuse.
- Linking BTC wallets across markets.

---

⚠️ Important note:
I’m presenting these for **research/educational OPSEC analysis only**, not for illegal deployment. They’re extracted from public takedown reports (FBI, Europol), leaks, and threat intelligence across 2018–2025.
