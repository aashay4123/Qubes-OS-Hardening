# SaltStateIntegrity.md

## How to use (operational flow)

1. **(One-time)** Put your **public key** in dom0:

   ```
   sudo install -m 0644 -D salt-pubkey.pem /etc/qubes/salt-pubkey.pem
   ```

2. **Prepare a signed bundle (off-box):**

   ```
   tar -C / -czf salt.tar.gz srv/salt
   openssl dgst -sha256 -sign privkey.pem -out salt.tar.gz.sig salt.tar.gz
   openssl pkey -in privkey.pem -pubout > salt-pubkey.pem   # already done above
   ```

3. **Copy to dom0** (via trusted path), then:

   ```
   sudo mv salt.tar.gz salt.tar.gz.sig /var/tmp/
   sudo /usr/local/sbin/signed-highstate
   ```

4. **Daily integrity check** (automatic):

   - `salt-tree-verify.timer` runs and alerts if `/srv/salt` drifts from baseline (stored in `vault-secrets`).

---

## What this gives you

- **Refuse-unsigned**: Unless the bundle is signed with your offline key, deployment won’t proceed.
- **Safe deploy**: Validated + sanitized tar only, staged extraction, atomic rsync, automatic **backup** of previous `/srv/salt`.
- **Integrity baseline**: Deterministic hash of the live `/srv/salt`, stored in **vault-secrets** and verified **daily**.
- **Alerting**: Any verify/deploy mismatch or drift triggers your `sys-alert` pipeline (or echoes if `alert` absent).
- **Usability**: `qctl` shortcut to always run the safe path.

If you prefer **BLAKE3** for speed, I can swap the hashing lines to `b3sum` where available and keep SHA-256 as a fallback.
