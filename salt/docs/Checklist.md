# 10) Checklists

## Daily (each active day)

- [ ] dom0 date/time sanity; templates up to date (no pending emergency QSB).
- [ ] sys-net MAC randomized (check `/rw/config/current_mac`).
- [ ] sys-firewall nft loaded; TTL=128 + QUIC drop present.
- [ ] Tor gateway healthy; newnym works; test https via Tor.
- [ ] Persona discipline: correct VM, accounts, timezone/locale, resolution fixed.
- [ ] Publish only via sanitize flow; no raw files leaked.

## Pre-Session (before doing sensitive work)

- [ ] Launch correct persona DVM.
- [ ] Verify no other personas running.
- [ ] Confirm Tor circuit isolated (newnym).
- [ ] Confirm clipboard/filecopy denies in place.

## Post-Session

- [ ] Close DVM; ensure it actually shut down.
- [ ] Check sys-firewall counters for odd spikes during the session.
- [ ] Notes saved to vault; nothing left in AppVM homes.

## Weekly

- [ ] Template updates (apt/dnf) in a **canary VM**; roll to main after smoke test.
- [ ] Review Suricata alerts; add allow/deny as needed.
- [ ] Backup vaults & /srv/salt to offline encrypted storage.

## Bi-Weekly

- [ ] Review policies: qrexec, clipboard/filecopy, device attach.
- [ ] Rotate Tor identity seeds if you use any long-lived circuits (advanced).

## Monthly

- [ ] Template hashing & compare to baseline; store new signed baseline if intended.
- [ ] Review personas: retire any that “got noisy”, create fresh ones if needed.
- [ ] Rehearse the IR playbook (tabletop).

## Quarterly

- [ ] Firmware/BIOS updates if available; Heads/TPM seal refresh.
- [ ] Test restoring from backups (actual restore to spare disk/box).
- [ ] Full audit of `/srv/salt` vs. running state (drift).

## Before Publication

- [ ] Full sanitize pipeline; manually review final file(s).
- [ ] Publish from the correct persona DVM via Tor.
- [ ] Don’t engage replies from the wrong persona.

## After Publication

- [ ] Monitor for targeting; increase alert sensitivity.
- [ ] Be ready to rotate the publishing persona if heat rises.
