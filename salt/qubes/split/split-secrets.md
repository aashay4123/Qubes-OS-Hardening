Got it ✅ — here’s a **complete README.md** you can drop alongside your Salt states.
It explains **what Split-GPG and Split-SSH are**, how your `secrets-vault` is wired, how to **use it from other VMs**, and how to add new clients.

---

# Split-GPG & Split-SSH in Qubes OS 4.2.4

This setup creates a dedicated **vault VM** (`secrets-vault`) that holds your GPG keys and SSH keys/agent.
Other VMs (work, pro, personal, anon-whonix) use qrexec to _request cryptographic operations_ from the vault without ever seeing the private keys.

---

## Architecture

- **`secrets-vault`**

  - Template: `debian-12-xfce`
  - Network: **none** (`netvm` empty)
  - Installed packages: `qubes-gpg-split`, `gnupg`, `socat`, `openssh-client`
  - Runs an **SSH agent** (`ssh-agent.service`) and a qrexec service `qubes.SshAgent`
  - Holds your actual GPG keyrings and SSH keys

- **Client VMs:** `work`, `pro`, `personal`, `anon-whonix`

  - Installed packages: `qubes-gpg-split`, `gnupg`, `socat`, `openssh-client`
  - Configured with `/rw/config/gpg-split-domain = secrets-vault`
  - Policies in dom0 allow these VMs to call `qubes.Gpg` and `qubes.SshAgent` in `secrets-vault`.

---

## Split-GPG

### How it works

- Client VM runs `qubes-gpg-client-wrapper` instead of `gpg`.
- The wrapper sends the request via qrexec to `secrets-vault`.
- The vault’s GPG key does the operation, then returns the result.

### Usage from clients

In `work`, `pro`, `personal`, or `anon-whonix`:

```bash
# check version / connectivity
qubes-gpg-client-wrapper --version

# list public keys (via vault)
qubes-gpg-client-wrapper --list-keys

# sign a message
echo "hello world" | qubes-gpg-client-wrapper --clearsign > signed.txt

# verify a signature
qubes-gpg-client-wrapper --verify signed.txt
```

### Git commit signing

Configure Git to use the wrapper:

```bash
git config --global gpg.program qubes-gpg-client-wrapper
git config --global commit.gpgSign true
```

Now `git commit` will sign using your vault keys.

### Thunderbird / Email

- In Thunderbird account settings → **OpenPGP** → select **external GnuPG**.
- Set the executable to:

  ```
  /usr/bin/qubes-gpg-client-wrapper
  ```

---

## Split-SSH

### How it works

- The vault runs an `ssh-agent` with your SSH private keys loaded.
- The client calls `qubes.SshAgent` via qrexec.
- A helper script forwards the vault’s agent socket into the client.

### Usage from clients

Instead of `ssh`, use the wrapper `ssh-vault` (installed in `/usr/local/bin`):

```bash
ssh-vault user@host
```

This will:

- Start a local socket → forward to `secrets-vault` via qrexec
- Set `SSH_AUTH_SOCK` to that socket
- Execute `ssh` using keys from the vault agent

### Adding keys in the vault

Inside `secrets-vault`:

```bash
# generate a new key
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519

# add it to the agent
ssh-add ~/.ssh/id_ed25519

# list keys loaded
ssh-add -l
```

Then copy the **public key** to your servers as usual.

---

## Adding a New Client VM

If you create another AppVM (say, `dev`), wire it like this:

1. **Install client packages** in `dev`:

   ```bash
   sudo apt-get update
   sudo apt-get install -y qubes-gpg-split gnupg socat openssh-client
   ```

2. **Point it to the vault**:

   ```bash
   echo secrets-vault | sudo tee /rw/config/gpg-split-domain
   ```

3. **Install the SSH helper** (copy from other VMs):

   ```bash
   sudo cp /usr/local/bin/ssh-vault /usr/local/bin/ssh-vault
   sudo chmod 0755 /usr/local/bin/ssh-vault
   ```

4. **Update dom0 policy** (`/etc/qubes/policy.d/30-split-gpg.policy` and `30-split-ssh.policy`) to allow:

   ```
   qubes.Gpg      dev     secrets-vault   allow
   qubes.SshAgent dev     secrets-vault   allow
   ```

Now `dev` can use Split-GPG and Split-SSH like the others.

---

## dom0 Policies (already managed by Salt)

- `/etc/qubes/policy.d/30-split-gpg.policy`:

  ```
  qubes.Gpg  work        secrets-vault    allow
  qubes.Gpg  pro         secrets-vault    allow
  qubes.Gpg  personal    secrets-vault    allow
  qubes.Gpg  anon-whonix secrets-vault    allow
  qubes.Gpg  @anyvm      @anyvm           ask default_target=secrets-vault
  ```

- `/etc/qubes/policy.d/30-split-ssh.policy`:

  ```
  qubes.SshAgent  work        secrets-vault    allow
  qubes.SshAgent  pro         secrets-vault    allow
  qubes.SshAgent  personal    secrets-vault    allow
  qubes.SshAgent  anon-whonix secrets-vault    allow
  qubes.SshAgent  @anyvm      @anyvm           ask
  ```

---

## Verifying the Setup

From dom0, run:

```bash
# check global disposable + vault wiring
qvm-prefs default_dispvm
qvm-prefs secrets-vault template
qvm-prefs secrets-vault netvm   # should be blank

# run a test sign from a client
qvm-run -p work 'echo hello | qubes-gpg-client-wrapper --clearsign | head -n3'

# run a test ssh agent forward from a client
qvm-run -p work 'ssh-vault -T git@github.com'
```

If the signature succeeds and ssh lists your key / connects, the setup is correct.

---

## References

- **Split-GPG official docs:** [Qubes OS: Split GPG](https://www.qubes-os.org/doc/split-gpg/)
- **Qubes 4.2 Policy System:** [Admin API and Policy](https://www.qubes-os.org/doc/qrexec-policy/)
- **Community Split-SSH guides:** [Qubes Forum](https://forum.qubes-os.org/) (Split-SSH threads and configs)
- **Disposables & Templates in 4.2:** [How to use disposables](https://www.qubes-os.org/doc/how-to-use-disposables/)

## Resources

- [Split-GPG](https://www.qubes-os.org/doc/split-gpg-2/)
