# 1) Mental model: what a “policy” is in Qubes 4.2

**Everything funnels through qrexec**. When a qube tries an inter-VM action (copy file, open URL elsewhere, use Split-GPG, get template updates through a proxy, attach input devices, etc.), qrexec evaluates **policy rules** in dom0 and either allows, asks, denies, or redirects the request. In R4.2, policy files live here:

```
/etc/qubes/policy.d/
```

Files are evaluated **in C-locale lexicographic order**; lower numbers win. You put your customizations into **a lower-numbered file** (commonly `30-user.policy`) so they override defaults such as `50-config-*.policy` and `90-default.policy`. There’s also `/run/qubes/policy.d/` for ephemeral, auto-generated rules (e.g., disposables) that vanish on reboot. ([Qubes OS][1])

**Line grammar (new format)**:

```
service-name|* +argument|*  source  destination  {allow|deny|ask} [params]
```

Useful params: `target=...` (redirect), `default_target=...` (pre-select in “ask” dialog), `user=...`. **Selectors** for source/dest: `@anyvm`, `@tag:NAME`, `@type:AppVM|TemplateVM|...`, `@dispvm`, `@dispvm:BASE`, `@default` (no explicit target given). `+ARG` lets you write one service with fine-grained arguments (USB device IDs, etc.). Includes are supported: `!include`, `!include-dir`, `!include-service`. ([Qubes OS Developer Documentation][2])

**Tip (4.2 change):** Many older guides still reference `/etc/qubes-rpc/policy/...`. In 4.2, **use `/etc/qubes/policy.d/`** and keep your edits in `30-user.policy`. The official docs and forum confirm the new location and the “lower number overrides” model; the 4.2 tools (Global Config / Policy Editor) write `50-config-*.policy` and validate syntax. ([Qubes OS][1], [Qubes OS Developer Documentation][3], [Qubes OS Forum][4])

---

# 2) The policy surfaces you’ll actually tune

Below are the surfaces most people adjust—and _how_ strong users set them up in 2025. Each includes “why/when,” then **drop-in rules** you can paste into `30-user.policy` (adjust qube names & tags), plus notes.

## 2.1 File copy/move between qubes (qubes.FileCopy / qubes.FileMove)

**Why/when:** enforce “data guardrails,” e.g., allow copying within a trust domain, but require a prompt (or forbid) crossing domains.

**Baseline pattern (tag driven):**

```policy
# Let work↔work copy without prompts; ask everywhere else; deny to/from vault
qubes.FileCopy *  @tag:work @tag:work allow
qubes.FileMove *  @tag:work @tag:work allow
qubes.FileCopy *  vault      @anyvm   deny
qubes.FileCopy *  @anyvm     vault    deny
qubes.FileCopy *  @anyvm     @anyvm   ask  default_target=work-files
qubes.FileMove *  @anyvm     @anyvm   ask  default_target=work-files
```

Rationale and top-to-bottom matching behavior are documented in the RPC policies doc. ([Qubes OS][5])

**Testing:** from a source qube run `qvm-copy file` (no target) or `qvm-copy-to-vm target file` and watch policy prompts. ([Qubes OS][1])

---

## 2.2 Opening URLs and files in another qube (qubes.OpenURL / qubes.OpenInVM)

**Why/when:** make _all_ untrusted links & attachments open in a **DisposableVM** by default; optionally pre-select a “viewer” qube; never leak to _vault_.

**Pragmatic 2025 set (mix of allow+ask with defaults):**

```policy
# Hard stop for vault
qubes.OpenInVM *  *      vault   deny
qubes.OpenURL  *  *      vault   deny
qubes.OpenInVM *  vault  *       deny
qubes.OpenURL  *  vault  *       deny

# Always open URLs in a Disposable (no prompt) from work (fast UX)
qubes.OpenURL  *  work   @dispvm allow

# General case: ask, but prefill defaults people actually use
qubes.OpenInVM *  @anyvm @anyvm  ask default_target=personal
qubes.OpenURL  *  @anyvm @anyvm  ask default_target=untrusted

# (Optional) allow specific Disposable templates by name
qubes.OpenURL  *  @anyvm @dispvm:web-dvm allow
qubes.OpenInVM *  @anyvm @dispvm:view-dvm allow
```

Nuances around `ask`, `default_target`, and `@dispvm:` are covered in the community guide and qrexec docs. In particular, `@dispvm` refers to the caller’s default disposable template unless you specify `@dispvm:BASE`. ([Qubes OS Forum][6], [Qubes OS][1])

**App integration:** set default handlers (XDG `.desktop`) to call `qvm-open-in-vm`/`qvm-open-in-dvm`, so apps automatically honor your policy. The guide shows patterns for Firefox/Thunderbird and a “URL redirector” add-on. ([Qubes OS Forum][6])

---

## 2.3 Clipboard (qubes.ClipboardPaste) & hygiene

**How Qubes clipboard works by default:** you do `Ctrl+C` in source, `Ctrl+Shift+C` to global clipboard, focus target app, `Ctrl+Shift+V` (global→target), then normal `Ctrl+V`. The global buffer **clears on paste**; that one-shot design is intentional. ([Qubes OS][7])

**Policy angle:** Inter-VM clipboard flow hinges on the `qubes.ClipboardPaste` policy. Most users keep it **`ask` cross-domain** (or restrict with tags), and **deny dom0** to/from almost everywhere.

**Example:**

```policy
# Don’t let dom0 paste to/from anything (you can make narrow exceptions)
qubes.ClipboardPaste *  dom0     @anyvm  deny
qubes.ClipboardPaste *  @anyvm   dom0    deny

# Allow within the same trust tag; ask otherwise
qubes.ClipboardPaste *  @tag:work @tag:work allow
qubes.ClipboardPaste *  @anyvm    @anyvm    ask
```

**“Time-limited clipboard”** isn’t a built-in _policy_ flag; the built-in safety is “paste once then clear.” People who want extra hygiene add small user-units (per qube) that wipe the _qube_’s clipboard after N seconds, or rebind hotkeys (in `guid.conf`) to reduce keystrokes—discussed widely on the forum—while keeping the policy side conservative. ([Qubes OS Forum][8])

---

## 2.4 Updates proxy (qubes.UpdatesProxy)

**Why/when:** let **Templates** (and optionally Standalones/dom0) update through a proxy qube, commonly `sys-whonix` or a VPN FirewallVM. 4.2’s Global Config writes `50-config-updates.policy` for you; you override in `30-user.policy`. ([Whonix][9], [Qubes OS Forum][10])

**Typical policy shape (with Whonix):**

```policy
# (Ship default lives in 50-config-updates.policy)
# qubes.UpdatesProxy * @tag:whonix-updatevm @default allow target=sys-whonix
# qubes.UpdatesProxy * @tag:whonix-updatevm @anyvm deny

# Add: route ALL templates via sys-whonix; deny others
qubes.UpdatesProxy *  @type:TemplateVM @default allow target=sys-whonix
qubes.UpdatesProxy *  @anyvm           @anyvm   deny
```

Remember to enable the **`qubes-updates-proxy`** service in the proxy qube (GUI → Services or `qvm-service sys-vpn qubes-updates-proxy --enable`). Firewall rules don’t control UpdatesProxy (it’s not an IP path); the policy does. ([Qubes OS Forum][11], [Qubes OS][12])

---

## 2.5 Device & input policies (qubes.InputKeyboard / Mouse / Tablet)

**Why/when:** if you run a `sys-usb`, you _must_ tell dom0 which qube may forward keyboard/mouse input to dom0. In 4.2 these rules are in **policy.d** (e.g., `50-config-input.policy`). Many users set **`ask` for mouse/tablet** and **explicit `allow`** for the trusted USB qube’s keyboard. You can edit these in **Global Config → USB Devices**. ([Qubes OS Forum][13])

**Example:**

```policy
# Allow only sys-usb to forward keyboard to dom0
qubes.InputKeyboard *  sys-usb dom0 allow
# Ask when a mouse is attached
qubes.InputMouse    *  sys-usb dom0 ask default_target=dom0
```

(If you see older paths like `/etc/qubes-rpc/policy/qubes.InputKeyboard` in docs, that’s the pre-4.2 location.) ([Qubes OS][14])

---

## 2.6 Tightening “shell vs start app” (qubes.VMShell vs qubes.StartApp)

**Practice:** permit `qubes.StartApp+name` (safe: only apps with `.desktop` entries) but **forbid `qubes.VMShell`** from domUs to each other, because that’s effectively full control of the target.

```policy
# Never allow arbitrary shell from other qubes
qubes.VMShell *  @anyvm @anyvm deny

# Allow only specific StartApps, and only from selected sources
qubes.StartApp +firefox  work  @dispvm:web-dvm allow
qubes.StartApp *         @anyvm @anyvm        ask
```

The docs explain why `StartApp` is safer than `VMShell`. ([Qubes OS][1])

---

## 2.7 Split-\* services: GPG/SSH

Most people keep crypto keys in a “vault” and allow only RPC calls to the agent in that vault. For Split-GPG **v2**, the shipped GUI writes a `50-config-splitgpg.policy` file; v2’s newer plumbing lives on GitLab. Split-SSH setups (community) use a `qubes.SshAgent`/`qubes.SSHagent`-style service and a dedicated ssh-agent qube; policy whitelists which clients can talk to it. ([Qubes OS Forum][15], [Qubes OS][16], [about.gitlab.com][17], [GitHub][18])

**Example:**

```policy
# Split-GPG: only mail qube may talk to gpg-vault
qubes.Gpg *  mail  gpg-vault allow
qubes.Gpg *  @anyvm @anyvm    deny

# Split-SSH: only work qubes may use sys-ssh-agent
qubes.SshAgent *  @tag:work  sys-ssh-agent ask
qubes.SshAgent *  @anyvm     @anyvm        deny
```

---

## 2.8 Selective inter-VM ports (qubes.ConnectTCP)

Use this when two isolated qubes need a single TCP port, without routing one through the other’s NetVM. You bind a local socket to a _remote_ TCP on demand via RPC. Good for dev DBs, Grafana, etc. ([qubes-doc-rst-de.readthedocs.io][19])

**Policy & usage sketch**:

```policy
# Permit specific port from dev to db only
qubes.ConnectTCP +5432  dev  db allow
qubes.ConnectTCP *      @anyvm @anyvm deny
```

Then from `dev`:

```bash
qvm-connect-tcp 127.0.0.1:5432 db:5432
# ... client connects to localhost:5432
```

People often make systemd user services to auto-establish these tunnels on VM start. ([Qubes OS Forum][20])

---

# 3) Admin API & Policy API (and why your GUI changes “stick”)

- **Admin API** lets an “AdminVM” manage domains without logging into dom0—_subject to policy_. Calls look like `admin.vm.Start`, `admin.vm.property.Set`, etc., and are gated by the same policy.d mechanics. This is the foundation for multi-user/remote management and GUI-domain futures. ([Qubes OS][21])

- **Policy API** (services like `policy.Replace+FILE`, `policy.RestoreService+SERVICE`) is how **Qubes Global Config** and the **Policy Editor** safely write `50-config-*.policy` instead of mangling your `30-user.policy`. If you’ve seen errors mentioning `policy.Replace+50-config-filecopy`, that’s this layer. Keep _your_ rules in `30-user.policy`; let the GUI own the `50-config-*` files. ([Qubes OS Forum][22], [Qubes OS Developer Documentation][2])

- The **Policy Editor in 4.2** does **syntax checking before save**, which is why many power users now prefer it for edits; you can also open any policy file from there to study how toggles affect rules. ([Qubes OS Forum][4])

---

# 4) Patterns advanced users actually keep in 2025

1. **One user file, early in order**: put durable custom rules in `/etc/qubes/policy.d/30-user.policy`, leave shipped files (`50-config-*`, `90-default.policy`) to the system. ([Qubes OS][1])
2. **Tags everywhere**: define workflow domains with tags (`work`, `social`, `dev`) and write _few_ generic rules instead of hundreds of per-VM entries. The examples and docs use `@tag:work` liberally. ([Qubes OS][5])
3. **Prefer `ask` with `default_target=`** for cross-domain actions; save “no-prompt” **`allow`** for very deliberate flows (e.g., OpenURL→@dispvm). ([Qubes OS][1], [Qubes OS Forum][6])
4. **Force Disposables for risky ingress**: OpenURL / OpenInVM go to `@dispvm` or `@dispvm:BASE` by policy. Many keep two disposables: a “web-dvm” and a “viewer-dvm”. ([Qubes OS Forum][6])
5. **Don’t allow `qubes.VMShell` between qubes**; prefer `qubes.StartApp+…`. ([Qubes OS][1])
6. **Updates through a proxy** (often `sys-whonix` for Templates); set with Global Config, verify in `50-config-updates.policy`, override in `30-user.policy` if needed. ([Whonix][9])
7. **Input device policies live in policy.d now**; edit via Global Config’s USB tab; typical pattern is strict `allow` only from `sys-usb` to dom0 for keyboard, `ask` for mouse. ([Qubes OS Forum][13])
8. **Use `!include` to modularize** (e.g., split an “open-policies.policy” from “updates.policy” for readability). ([Qubes OS Developer Documentation][2])
9. **Keep ephemeral rules out of `/etc`**; anything session-specific goes into `/run/qubes/policy.d` (created by tools), and you don’t rely on its order vs. `/etc`. ([Qubes OS][1])

---

# 5) Verify, test, and troubleshoot

**Where to look/what to use**

- **Open and edit** policies with **Qubes Global Config → Policy Editor**; it validates syntax and shows you the live merged view. ([current-qubes-docrtd.readthedocs.io][23], [Qubes OS Forum][4])
- **Check precedence**: `ls /etc/qubes/policy.d/` and confirm your `30-user.policy` exists and sorts before `50-config-*` and `90-default.policy`. The multifile spec documents ordering and valid filenames. ([Qubes OS Developer Documentation][2])
- **Exercise rules** from a qube:

  - `qvm-open-in-dvm https://example.org` (triggers `qubes.OpenURL`)
  - `qvm-open-in-vm target somefile.pdf` (triggers `qubes.OpenInVM`)
  - `qvm-copy-to-vm target file` (triggers `qubes.FileCopy`)
  - `qrexec-client-vm target qubes.StartApp+firefox` (direct qrexec)
    The qrexec docs show exactly how these map to services and how `ask/default_target/target=` interact. ([Qubes OS][1])

- **UpdatesProxy** failures? Verify the policy file (`50-config-updates.policy` + your overrides), ensure the proxy qube has the `qubes-updates-proxy` service enabled, and remember that firewall rules don’t apply to UpdatesProxy traffic. ([Whonix][9], [Qubes OS Forum][11], [Qubes OS][12])
- **USB/input** oddities? In 4.2 the rules are not in `/etc/qubes-rpc/policy/...` anymore—people get tripped by old guides. Look for `50-config-input.policy` or use the Global Config GUI. ([Qubes OS Forum][13])

---

## A consolidated starter `30-user.policy` (edit names/tags to fit)

```policy
# --- Guard rails ---
# No shell between qubes
qubes.VMShell *           @anyvm         @anyvm          deny
# Vault isolation
*              *          vault          @anyvm          deny
*              *          @anyvm         vault           deny

# --- Clipboard ---
qubes.ClipboardPaste *    dom0           @anyvm          deny
qubes.ClipboardPaste *    @anyvm         dom0            deny
qubes.ClipboardPaste *    @tag:work      @tag:work       allow
qubes.ClipboardPaste *    @anyvm         @anyvm          ask

# --- File copy/move ---
qubes.FileCopy *          @tag:work      @tag:work       allow
qubes.FileMove *          @tag:work      @tag:work       allow
qubes.FileCopy *          @anyvm         @anyvm          ask default_target=work-files
qubes.FileMove *          @anyvm         @anyvm          ask default_target=work-files

# --- Open URLs/files ---
qubes.OpenURL  *          work           @dispvm         allow               # fast UX for work links
qubes.OpenInVM *          @anyvm         @anyvm          ask default_target=personal
qubes.OpenURL  *          @anyvm         @anyvm          ask default_target=untrusted
qubes.OpenURL  *          @anyvm         @dispvm:web-dvm allow
qubes.OpenInVM *          @anyvm         @dispvm:view-dvm allow

# --- Updates proxy (TemplateVMs through sys-whonix) ---
qubes.UpdatesProxy *      @type:TemplateVM  @default     allow target=sys-whonix
qubes.UpdatesProxy *      @anyvm            @anyvm       deny

# --- Split services ---
qubes.Gpg       *         mail           gpg-vault       allow
qubes.Gpg       *         @anyvm         @anyvm          deny
qubes.SshAgent  *         @tag:work      sys-ssh-agent   ask
qubes.SshAgent  *         @anyvm         @anyvm          deny

# --- Inter-VM port bridges (postgres dev only) ---
qubes.ConnectTCP +5432    dev            db              allow
qubes.ConnectTCP *        @anyvm         @anyvm          deny
```

(Leave USB input in the GUI-managed file; do not copy those lines here unless you know what you’re doing.)

---

## References you’ll find yourself going back to

- **Qrexec (how it works + policy basics, default_target, @dispvm, arguments):** official docs. ([Qubes OS][1])
- **RPC Policies overview & top-to-bottom matching example:** official docs. ([Qubes OS][5])
- **Multifile policy spec (4.1+ format, `/etc/qubes/policy.d`, includes, tokens, ordering):** dev docs. ([Qubes OS Developer Documentation][2])
- **Global Config / Policy Editor (4.2 GUI, syntax checking):** release notes and forum WIP guide. ([current-qubes-docrtd.readthedocs.io][23], [Qubes OS Forum][4])
- **Open URLs/files across qubes (patterns people use, handlers, @dispvm\:BASE):** forum community guide. ([Qubes OS Forum][6])
- **Clipboard “how to” (behavior by design) and community hygiene ideas:** docs & forum. ([Qubes OS][7], [Qubes OS Forum][8])
- **Updates Proxy policy in 4.2 (50-config-updates.policy, Whonix specifics):** Whonix doc + Qubes docs. ([Whonix][9], [Qubes OS][24])
- **Input device policy location & GUI editing in 4.2:** forum notes. ([Qubes OS Forum][13])
- **ConnectTCP (doc patterns & discussions):** docs in multiple languages and forum posts. ([qubes-doc-rst-de.readthedocs.io][19], [Qubes OS Forum][20])

---

If you want, I can fold these into your long-form README (with per-concept **how to use / when to use / advantages-disadvantages / examples**) and tailor the snippets to your exact qube names/tags.

[1]: https://www.qubes-os.org/doc/qrexec/ "
    
      Qrexec: secure communication across domains | Qubes OS
    
  "
[2]: https://dev.qubes-os.org/projects/qubes-core-qrexec/en/stable/multifile-policy.html "<no title> — qubes-core-qrexec mm_21ac359f-2-g66d41d3 documentation"
[3]: https://dev.qubes-os.org/projects/qubes-core-qrexec/en/stable/multifile-policy.html?utm_source=chatgpt.com "<no title> — qubes-core-qrexec v4.3.9-3-gcc6ed18 ..."
[4]: https://forum.qubes-os.org/t/how-to-use-the-qubes-admin-policies-api-despite-the-lack-of-documentation-wip/29863?utm_source=chatgpt.com "How to use the Qubes Admin Policies/API despite the lack ..."
[5]: https://www.qubes-os.org/doc/rpc-policy/ "
    
      RPC policies | Qubes OS
    
  "
[6]: https://forum.qubes-os.org/t/opening-urls-files-in-other-qubes/19026 "Opening URLs/files in other Qubes - Community Guides - Qubes OS Forum"
[7]: https://www.qubes-os.org/doc/how-to-copy-and-paste-text/?utm_source=chatgpt.com "How to copy and paste text"
[8]: https://forum.qubes-os.org/t/qubes-clipboard-is-painful/2830?utm_source=chatgpt.com "Qubes Clipboard™ is painful - General Discussion"
[9]: https://www.whonix.org/wiki/Qubes/UpdatesProxy?utm_source=chatgpt.com "Qubes-Whonix UpdatesProxy Settings"
[10]: https://forum.qubes-os.org/t/different-update-proxy-for-dom0-templates/26728?utm_source=chatgpt.com "Different update proxy for dom0 & templates - User Support"
[11]: https://forum.qubes-os.org/t/how-to-use-a-custom-qube-proxy-update/21220?utm_source=chatgpt.com "How-to use a custom qube proxy update - Community Guides"
[12]: https://www.qubes-os.org/doc/firewall/?utm_source=chatgpt.com "Firewall"
[13]: https://forum.qubes-os.org/t/cant-find-etc-qubes-rpc-policy-qubes-inputkeyboard/24700?utm_source=chatgpt.com "Can't find /etc/qubes-rpc/policy/qubes.InputKeyboard"
[14]: https://www.qubes-os.org/doc/usb-qubes/?utm_source=chatgpt.com "USB qubes"
[15]: https://forum.qubes-os.org/t/confused-about-split-gpg-gui-under-4-2/24533?utm_source=chatgpt.com "Confused about split-gpg gui under 4.2 - User Support"
[16]: https://www.qubes-os.org/doc/split-gpg-2/?utm_source=chatgpt.com "Split GPG-2"
[17]: https://gitlab.com/QubesOS/qubes-app-linux-split-gpg2?utm_source=chatgpt.com "QubesOS / qubes-app-linux-split-gpg2"
[18]: https://github.com/unman/qubes-ssh-agent?utm_source=chatgpt.com "unman/qubes-ssh-agent"
[19]: https://qubes-doc-rst-de.readthedocs.io/de/latest/user/security-in-qubes/firewall.html?utm_source=chatgpt.com "Firewall - Qubes Docs"
[20]: https://forum.qubes-os.org/t/understanding-how-qvm-connect-tcp-works-under-the-hood/30316?utm_source=chatgpt.com "Understanding how qvm-connect-tcp works under the hood"
[21]: https://www.qubes-os.org/doc/admin-api/?utm_source=chatgpt.com "Admin API"
[22]: https://forum.qubes-os.org/t/qubes-global-config-returning-error/34001?utm_source=chatgpt.com "Qubes global config returning error - General"
[23]: https://current-qubes-docrtd.readthedocs.io/en/rtd-deploy-pr/_sources/developer/releases/4_2/release-notes.rst.txt?utm_source=chatgpt.com "release-notes.rst.txt"
[24]: https://www.qubes-os.org/doc/how-to-install-software/?utm_source=chatgpt.com "How to install software"

# Advanced Qubes RPC Policies (R4.2.4) — A Practical, Modern Guide (2025)

> **Scope**: This guide covers the **new policy system used in Qubes OS 4.2.x** (single, merged policy set in `/etc/qubes/policy.d/…`). It’s written as a hands‑on tutorial for beginners who want to configure like advanced users in 2025.

---

## 0) Mental model (60 seconds)

- **qrexec service**: a named capability (e.g., `qubes.OpenURL`, `qubes.FileCopy`, `qubes.UpdatesProxy`).
- **Call**: _source qube_ → **service** (with optional argument) → _target qube_.
- **Policy**: A top‑to‑bottom list of rules in **dom0** that decides: `allow`, `ask` (show GUI prompt), or `deny`. You can also **redirect** to a specific target via `target=` or default GUI choice via `default_target=`.
- **GUI prompts** appear from the **GuiVM** (e.g., `dom0` or your `sys-gui-*`), not from the calling qube.

---

## 1) Where policies live & how they’re parsed

- **Persistent**: `/etc/qubes/policy.d/`
- **Runtime (generated)**: `/run/qubes/policy.d/` (do not edit)
- **Default file**: `/etc/qubes/policy.d/90-default.policy` (**do not edit**). Create your own file like:

  - `/etc/qubes/policy.d/30-user.policy` (lower number loads **earlier**, i.e., wins first‑match precedence).

**Policy line format**:

```
service-name | *   +argument | *   source   target   action  [options]
```

- `service-name`: e.g., `qubes.OpenURL`, `qubes.OpenInVM`, `qubes.ClipboardPaste`, `qubes.UpdatesProxy`, `qubes.ConnectTCP`, `qubes.VMShell`.
- `+argument`: match specific argument (e.g., `+22` for `ConnectTCP` SSH), or `*` for any.
- `source` & `target`: specific qube (`vault`, `work-web`), or tokens like `@anyvm`, `@tag:work`, `@type:TemplateVM`, `@dispvm`, `@dispvm:<base>`, `@default`, `@adminvm`.
- `action`: `allow`, `ask`, `deny`.
- `options`: e.g., `target=<vmname>`, `default_target=<vmname>`, `user=root`.

**Resolution is first match wins** (parse order is top→down). Keep tight rules first, broad catch‑alls last.

---

## 2) Tokens you will actually use

- `@anyvm`: any qube except dom0.
- `@default`: placeholder used when the caller didn’t hardcode a target (e.g., `qvm-open-in-vm` without `--target`).
- `@dispvm`: a Disposable VM spawned for this call (safe default for risky data).
- `@dispvm:<name>`: spawn a DispVM **based on** the named template (`<name>` is a _Disposable Template_, not a regular TemplateVM).
- `@tag:<name>`: qubes with that tag.
- `@type:<Type>`: `AppVM`, `TemplateVM`, `StandaloneVM`, etc.
- `@adminvm`: the administrative domain (traditionally `dom0`).

---

## 3) “Redirection” (target selection) — the superpower

You can **force** or **prefer** a target:

- **Force**: `allow,target=<vm>` → the target is fixed, no prompt.
- **Prefer** in Ask dialog: `ask,default_target=<vm>` → still prompts, but preselects `<vm>`.

This is how you turn vague calls into deterministic flows or smooth prompts.

---

## 4) What `/etc/qubes/policy.d` actually controls

- **Inter‑qube file access**: `qubes.OpenInVM`, `qubes.OpenURL`, `qubes.FileCopy`, `qubes.FileMove`.
- **Clipboard**: `qubes.ClipboardPaste`.
- **Updates**: `qubes.UpdatesProxy` (route TemplateVM updates via chosen update proxy, e.g., `sys-whonix`).
- **Networking tunnels**: `qubes.ConnectTCP` (dangerous; off by default, allow only specific ports/partners).
- **GUI & images**: `qubes.GetImageRGBA` (used by menus/icons), `qubes.StartApp`.
- **Shell/exec plumbing (dangerous)**: `qubes.VMShell`, `qubes.VMExec`, `qubes.VMRootShell`, `qubes.VMExecGUI` (defaults are restrictive).
- **Input devices**: `qubes.InputKeyboard`, `qubes.InputMouse` in a consolidated policy file (see §10).
- **Admin API** calls: numerous `admin.*` services (policy‑gated actions like start/kill/volume ops/device attach).

In short: _most user‑visible inter‑qube interactions pass through here_.

---

## 5) Starter pattern: make the safe things automatic

Create `/etc/qubes/policy.d/30-user.policy` and add these high‑value defaults near the top.

### 5.1 Always open URLs in a Disposable VM — with a sane fallback

```policy
qubes.OpenURL        *   @anyvm     @dispvm           allow
qubes.OpenURL        *   @anyvm     @anyvm            ask,default_target=work-web
```

- **Why**: opening untrusted links in a fresh DispVM minimizes risk. But sometimes you need it in a persistent browser → you’ll get an Ask dialog pre‑selecting `work-web`.
- **When**: daily web browsing from all qubes (mail, chat, docs). This is ubiquitous in 2025.

### 5.2 Always open files in a Disposable VM (viewer) by default

```policy
qubes.OpenInVM       *   @anyvm     @dispvm           allow
qubes.OpenInVM       *   @anyvm     @anyvm            ask,default_target=work-view
```

- **Why**: unknown file types shouldn’t run with your data. View first in a throwaway. If needed, pick a persistent viewer.
- **When**: PDFs, office docs, images dropped from chat/email or downloads.

### 5.3 Tighten `ConnectTCP` to explicit use‑cases only

```policy
# Example: only allow SSH from dev-shell → dev-net at TCP/22
qubes.ConnectTCP     +22   dev-shell   @default   allow,target=dev-net
# Block everything else by default
qubes.ConnectTCP     *     @anyvm      @anyvm     deny
```

- **Why**: `ConnectTCP` is powerful and abusable. Pin it down to _ports_ and _peers_.
- **When**: split‑network workflows (SSH, DB sockets, RPC to a net qube).

### 5.4 Updates via Tor for Templates (popular pattern)

```policy
# All TemplateVMs update through sys-whonix
qubes.UpdatesProxy   *   @type:TemplateVM   @default   allow,target=sys-whonix
```

- **Why**: reduces update correlation; a common 2025 hardening choice.
- **When**: global default unless you run a local mirror.

### 5.5 Clipboard: default Ask, with denylists

```policy
# Ask everywhere by default
qubes.ClipboardPaste   *   @anyvm     @anyvm     ask
# Example: never paste into vault
qubes.ClipboardPaste   *   @anyvm     vault      deny
# Example: never paste out of shady-web into work-docs directly
qubes.ClipboardPaste   *   shady-web  work-docs  deny
```

- **Why**: prevent accidental cross‑contamination; enforce explicit intent.
- **When**: ubiquitous; adapt deny rules to your high‑risk qubes.

> **Tip**: In Global Config → Clipboard you can also enable automatic clipboard clearing and other guardrails. Your custom rules still apply.

---

## 6) Ask vs Allow vs Deny — designing prompts

- **`allow`**: no GUI; fast path for **low‑risk**, **frequent** actions.
- **`ask`**: GUI dialog; great for **contextual decisions** and **user awareness**. Use `default_target=` to reduce clicks.
- **`deny`**: explicit tripwires for high‑risk flows you want to block by policy.

**Pattern**: `allow` the safe automation **and** end with an `ask` catch‑all → you stay productive and protected.

---

## 7) Using tags to express policy at scale

Assign tags to qubes and write rules against `@tag:<name>` instead of per‑qube lists.

```bash
# dom0
qvm-tags work-web add work
qvm-tags work-view add work
qvm-tags work-docs add work
```

```policy
# Only allow file copy within the work boundary
qubes.FileCopy   *   @tag:work   @tag:work   allow
# Block work → non-work
qubes.FileCopy   *   @tag:work   @anyvm      deny
# Ask for the rest
qubes.FileCopy   *   @anyvm      @anyvm      ask
```

**Why**: fewer lines, fewer mistakes, updating memberships is easy.

---

## 8) Real‑world bundles you can copy/paste

### 8.1 “Everything opens in a DispVM first”

```policy
qubes.OpenURL     *   @anyvm   @dispvm   allow
qubes.OpenInVM    *   @anyvm   @dispvm   allow
qubes.OpenURL     *   @anyvm   @anyvm    ask,default_target=work-web
qubes.OpenInVM    *   @anyvm   @anyvm    ask,default_target=work-view
```

**When**: you often handle untrusted links/files (newsletters, contractors, open‑source repos, PDFs).

### 8.2 “Split‑GPG2” (common in 2025)

Minimal policy idea (names are examples):

```policy
# Thunderbird qube (mail-app) can talk to gpg-backend
qubes.Gpg2        *   mail-app   gpg-backend   allow
```

Then set the client’s environment (in `mail-app`) to point at `gpg-backend`. Your GUI (Global Config → Split GPG) can generate a starter file; advanced users tailor flows by editing policy directly.

**When**: mail, dev signing, package signing.

### 8.3 “Open code in dev-viewer, never run it”

```policy
qubes.OpenInVM    *   @anyvm     dev-view    allow
# but do not allow OpenInVM into dev-build directly
qubes.OpenInVM    *   @anyvm     dev-build   deny
```

**When**: you want a viewer VM for initial inspection; builds pull vetted inputs only.

---

## 9) Redirecting (`target=`) vs prompting with defaults (`default_target=`)

**Force a known target**:

```policy
# Always send updates out the Tor update proxy
qubes.UpdatesProxy   *   @type:TemplateVM   @default   allow,target=sys-whonix
```

**Prompt, preselect a safe target**:

```policy
qubes.OpenInVM       *   @anyvm   @anyvm   ask,default_target=work-view
```

**Design note**: `target=` trades flexibility for safety/automation; `default_target=` keeps the user in the loop.

---

## 10) Input devices (keyboard/mouse) and USB/PCI

Modern Qubes consolidates **input** policy into one file (commonly generated as `50-config-input.policy`). The logic is the same policy grammar:

```policy
# Allow sys-usb to provide *keyboard* input to dom0 (AdminVM)
qubes.InputKeyboard   *   sys-usb   @adminvm   allow
# Allow sys-usb to provide *mouse* input to dom0
qubes.InputMouse      *   sys-usb   @adminvm   allow
```

- Use Qubes Global Settings → **USB**/**Input** to write sane defaults, then refine in your own `30-user.policy`.
- For **USB storage/cameras**: prefer attaching **block devices** to a specific AppVM (`qvm-block`/device manager). Only pass whole **controllers** as PCI **if you must** (last resort); that is a different mechanism than qrexec policy.

**When**: laptops with `sys-usb` handling human‑interface devices; you must explicitly allow input to the AdminVM.

---

## 11) Admin API policies (admin.\*)

The Admin API exposes management actions (start/kill/volume/device attach, etc.) as RPC services evaluated by the same policy engine. Examples you might adopt:

```policy
# Let mgmt-vm start/stop only qubes tagged staging
admin.vm.Start       *   mgmt-vm     @tag:staging     allow
admin.vm.Shutdown    *   mgmt-vm     @tag:staging     allow
# But block production unless explicitly allowed elsewhere
admin.vm.Start       *   mgmt-vm     @tag:production  deny

# Permit mgmt-vm to attach **block** devices from sys-usb to staging
admin.vm.device.block.Attach   *   mgmt-vm   @tag:staging   ask
```

- Start with **Ask** for dangerous operations, move to **allow** only after you’re confident in scoping (tags/types).
- Keep admin‑capable qubes minimal, network‑restricted, and audited.

---

## 12) ConnectTCP — safe patterns only

`qubes.ConnectTCP` lets a client qube reach a port on a server qube. Avoid global allows; **match the port with `+<port>` and restrict peers**.

```policy
# Only SSH from dev-shell to dev-net
qubes.ConnectTCP   +22   dev-shell   @default   allow,target=dev-net
# Only Postgres 5432 from analytics to db
qubes.ConnectTCP   +5432 analytics   @default   allow,target=db
# Everything else: deny
qubes.ConnectTCP   *     @anyvm      @anyvm     deny
```

**When**: GUI‑less client/server splits inside Qubes, DB admin from a non‑net qube, SOCKS chains.

---

## 13) Clipboard policies — examples you can ship today

```policy
# Default: Ask everywhere
qubes.ClipboardPaste   *   @anyvm    @anyvm    ask
# Never paste into vault
qubes.ClipboardPaste   *   @anyvm    vault     deny
# Allow intra‑work pastes without prompting
qubes.ClipboardPaste   *   @tag:work @tag:work allow
# But forbid shady-web → work-docs entirely
qubes.ClipboardPaste   *   shady-web work-docs deny
```

**Hygiene options** you can apply in Global Config (Clipboard): auto‑clear timeout; “don’t allow pasting back to same qube” hardening; dom0 exclusions.

---

## 14) Files & URLs — disp‑first with controlled escapes

**Files**: `qubes.OpenInVM` rules in §5.2.

**URLs**: `qubes.OpenURL` in §5.1.

**Power move**: add exceptions for trusted internal portals (e.g., `+https://intranet.example.com` → `work-web`), while keeping the default as `@dispvm`.

```policy
# Internal SSO portal always in work-web
qubes.OpenURL   +https://intranet.example.com   @anyvm   @default   allow,target=work-web
```

---

## 15) StartApp / GetImageRGBA — menu and icon hygiene

These services are generally `ask` or `allow` to `@dispvm`/`@anyvm` in defaults. Rarely changed by end users. If you trim menus to a launcher qube, you might pin:

```policy
# Only allow app launches from launcher → targets
qubes.StartApp  *   launcher   @anyvm   ask
```

---

## 16) Ordering, structure & includes

- Keep all **customizations** in **one** file like `30-user.policy` unless you have strong reasons to split.
- Order: **exact, restrictive** rules first; **broad** rules last.
- Use **tags** to keep line count small.
- Comment aggressively. Future‑you will thank you.

Example skeleton:

```policy
### 30-user.policy — my site policy ###

# --- hard denies (tripwires)
qubes.VMExec * @anyvm @anyvm deny

# --- disp-first defaults
qubes.OpenURL  * @anyvm @dispvm allow
qubes.OpenInVM * @anyvm @dispvm allow

# --- work boundary rules
qubes.FileCopy * @tag:work @tag:work allow
qubes.FileCopy * @tag:work @anyvm    deny

# --- clipboard hygiene
qubes.ClipboardPaste * @anyvm @anyvm ask
qubes.ClipboardPaste * @anyvm vault  deny

# --- updates
qubes.UpdatesProxy * @type:TemplateVM @default allow,target=sys-whonix

# --- ConnectTCP explicit
qubes.ConnectTCP +22 dev-shell @default allow,target=dev-net
qubes.ConnectTCP *   @anyvm    @anyvm   deny
```

---

## 17) Testing & debugging

- **Syntax safety**: Use the **Qubes Global Config** policy editor to make quick changes — it validates before saving.
- **Live logs** (dom0):

  - `journalctl -f` while triggering a call (e.g., paste, open URL) to see policy evaluation errors.

- **Dry‑runs**: Keep a duplicate of your file under a different name to diff changes. Apply one section at a time.
- **Rollback**: If you lock yourself out of basic functions (copy, open), temporarily rename your `30-user.policy` and re‑test.

---

## 18) Device policies — quick cookbook

- **USB storage/cameras**: Use the **Devices** panel (or `qvm-block`/`qvm-usb`) to attach per device. This is **not** controlled by `qubes.OpenInVM`; it’s device attachment, separate from RPC.
- **Input (keyboard/mouse)**: see §10 sample rules — these _do_ use the new policy grammar.
- **PCI controllers** (last resort): attach via `qvm-pci` (persistent) after you’ve identified the correct controller (USB bus mapping). Be aware of the security impact.

---

## 19) Policies people actually use in 2025 (patterns)

1. **disp‑first** for `OpenURL` and `OpenInVM` (with Ask fallback).
2. **Updates via Tor** for TemplateVMs (with dedicated `sys-whonix`).
3. **Clipboard Ask + denylists** for sensitive qubes.
4. **ConnectTCP locked to port & peer** (SSH/DB only).
5. **Split‑GPG2** (mail, signing) with narrow `allow` from client → key qube.
6. **Input policy** explicitly allowing `sys-usb` to AdminVM (and nowhere else).
7. **Admin API** constrained by tags (`staging` allowed; `production` ask/deny).

These are broadly reported and align with default security posture while keeping daily workflows smooth.

---

## 20) Frequently‑asked “why doesn’t it work?”

- **“Request refused”** when copying or opening: check you didn’t remove the broad `ask` catch‑all at the end, or you over‑matched earlier with a `deny`.
- **No prompt appears**: your rule says `allow` (no GUI) or a `deny` has matched earlier. Recheck order.
- **OpenURL/OpenInVM ignores my target**: you used `ask` without an earlier `allow` for that target — in `ask` the picker only lists valid targets as per earlier allow/ask rules.
- **Global Clipboard glitchy**: ensure qrexec services are installed in templates and policy syntax is valid; use `journalctl -f` while pasting to see the exact complaint.

---

## 21) Security notes you should keep

- Avoid enabling `qubes.VMExec` / `qubes.VMRootShell` across qubes; prefer task‑specific services.
- Be very conservative with `ConnectTCP` — pin **port + peer** and deny the rest.
- Label sensitive qubes with tags (`@tag:sensitive`) and write broad denylists against them (clipboard, file copy, URL open back into them).
- Favor `ask` with `default_target=` where you want awareness but low friction.

---

## Appendix A — Mini reference (cheatsheet‑style, but in prose 😉)

- **Tokens**: `@anyvm`, `@default`, `@dispvm`, `@dispvm:<base>`, `@tag:<t>`, `@type:<T>`, `@adminvm`.
- **Actions**: `allow` (no prompt), `ask` (GUI), `deny`.
- **Options**: `target=<vm>`, `default_target=<vm>`, `user=root`.
- **Order**: first matching rule wins; put precise → general.
- **Files**: place your rules in `/etc/qubes/policy.d/30-user.policy`. Don’t edit `90-default.policy`.

---

## Appendix B — Copy‑ready building blocks

### B.1 Block work → non‑work file moves; allow inside work; ask otherwise

```policy
qubes.FileMove * @tag:work @tag:work allow
qubes.FileMove * @tag:work @anyvm    deny
qubes.FileMove * @anyvm    @anyvm    ask
```

### B.2 Block pasting **into** secrets; allow inside project; ask otherwise

```policy
qubes.ClipboardPaste * @anyvm      vault        deny
qubes.ClipboardPaste * @tag:projX  @tag:projX   allow
qubes.ClipboardPaste * @anyvm      @anyvm       ask
```

### B.3 Developer split network

```policy
qubes.ConnectTCP +22    dev-shell @default allow,target=dev-net
qubes.ConnectTCP +5432  dev-analytics @default allow,target=dev-db
qubes.ConnectTCP *      @anyvm @anyvm deny
```

### B.4 Input from `sys-usb` only to AdminVM

```policy
qubes.InputKeyboard * sys-usb @adminvm allow
qubes.InputMouse    * sys-usb @adminvm allow
```

### B.5 Updates via Tor

```policy
qubes.UpdatesProxy * @type:TemplateVM @default allow,target=sys-whonix
```

---

## Appendix C — Adapting this guide

Start by pasting the **starter pattern** (section 5) into `30-user.policy`. Use tags to group qubes, then add the real‑world bundles from section 8–13 that match your workflow.

**Rule of thumb**: if you can describe the behavior as a sentence (who → what → where → allowed/ask/deny), you can implement it as **one line** of policy.

---

_End of README_
