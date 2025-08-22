# Qubes SaltStack States

This directory contains Salt states to manage various Qubes OS resources, including VMs, templates, and policies. These states help automate the setup and configuration of a secure and efficient Qubes OS environment.

## Split GPG, SSH, and Password Management

# 1) How to use it (day-to-day)

## A) Split-GPG (from a caller VM)

**Prereqs (one-time, inside each vault):**

- Import your private keys into the vault’s GnuPG (`vault-secrets` for Debian callers; `vault-dn-secrets` for Whonix callers).

  ```bash
  # inside vault
  gpg --import /path/to/private.key
  gpg --edit-key <KEYID> trust   # set trust level
  ```

**Use from a Debian caller** (e.g., `work`, `dev`, `personal`):

```bash
# In the caller VM:
echo "hello" | gpg --clearsign
# This invokes qubes-gpg-client-wrapper → vault-secrets; you'll get a signature back.
```

**Use from a Whonix WS** (e.g., `ws-tor-research`):

```bash
echo "hello" | gpg --clearsign
# Routed to vault-dn-secrets via policy/tags.
```

Tips:

- `gpg --list-keys` in callers shows **stubs**, not private keys—expected.
- If pinentry prompts appear, they do so in the caller (by design). Cache lives in the vault’s gpg-agent.

## B) Split-SSH (from a caller VM)

**Prereqs (one-time, inside each vault):**

```bash
# inside vault (vault-secrets or vault-dn-secrets)
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
# add pubs to servers as usual (ssh-copy-id etc., but from a mgmt VM or via admin channel)
```

**Start the proxy in the caller** (our helper tried to do this automatically; here’s manual):

```bash
# In the caller VM:
systemctl --user enable --now qubes-ssh-agent-proxy.socket qubes-ssh-agent-proxy.service
export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/qubes/ssh-agent"    # usually set by the service
ssh -o IdentitiesOnly=yes user@host.example
```

- The proxy asks the **vault** (via `qubes.SshAgent`) to sign challenges. Private keys never leave the vault.
- Check `ssh-add -L` in the caller: you should see public keys proxied from the vault.

## C) qube-pass (passwords from the vault)

**Prereqs (one-time, inside each vault):**

```bash
# inside vault (choose correct one)
pass init <YOUR-GPG-KEYID>
pass insert github.com/youruser            # type secret; first line = password
```

**Use from Debian callers:**

```bash
qpass github.com/youruser          # prints the password line to stdout
# example use:
export PGPASSWORD="$(qpass db/prod)"; psql ...
```

**Use from Whonix callers:**

```bash
qpass-ws github.com/youruser
```

---

## Network and Firewall Management

https://www.qubes-os.org/doc/firewall/#enabling-networking-between-two-qubes

## Managing Qubes Standalone VMs

planning to add 1 OPENBSD
