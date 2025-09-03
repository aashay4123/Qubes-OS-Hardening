# Advanced Qubes OS 4.2.4 Concepts — A Practical Deep‑Dive

**Scope.** This README is a field manual for advanced Qubes OS 4.2.4 usage. For every concept, it answers four questions: **How to use**, **When to use**, **Advantages/Disadvantages**, and **Example(s)**. It aims to be both actionable and opinionated for real day‑to‑day workflows.

> Assumptions: you already have hardened templates, named disposables, work qubes, and reasonable default policies; you prefer Linux‑style UX and heavy CLI use. Focus is Qubes 4.2.x; avoid sys-gui-vnc for now.

---

## 1) Admin API (qubesd, qubesadmin)

### How to use

- Use the **Admin API** to perform admin actions from dom0 (or a designated admin qube) via the `qubesadmin` Python client or the `qvm-*` CLI. Typical operations are `admin.vm.Start`, `admin.vm.property.Set`, `admin.pool.*`, `admin.vm.volume.*`, `admin.Events`, `admin.vm.Stats`.
- From **dom0**: use `qvm-*` tools or Python with `qubesadmin.app.Qubes()`.
- From a **management VM**: use `qubesadmin.app.QubesRemote()`; calls cross domains via qrexec according to **Admin API policies**.
- Admin API is governed by **admin policy files**; keep them minimal/granular; prefer tags for grouping.

### When to use

- You want scripted, reproducible ops from a management qube (not dom0): provisioning, auditing, reacting to events, rotating pools/volumes.
- Building integrations: status bars, health checks, dashboards that subscribe to events.

### Advantages / Disadvantages

- **+** Programmable, event‑driven, works from a non-dom0 admin VM.
- **+** Fine‑grained policies; can be read‑only for most calls.
- **–** Policy misconfig can brick workflows; test with a dry‑run tool (see Policy section).
- **–** Long‑running listeners need careful hardening and resource limits.

### Example(s)

- **Python (dom0)**: subscribe to `admin.vm.Stats` and print CPU/mem for running VMs. Use the events API and throttle logging.
- **Admin qube**: a small daemon that watches for `vm-start` events to auto‑attach a YubiKey or set firewall rules for transient VMs.

---

## 2) Kernels (PVH/HVM, in‑VM kernels, pvgrub2)

### How to use

- Set per‑VM `virt_mode` (`pvh` for Linux; `hvm` when needed), select dom0‑provided kernel (default) or in‑VM kernel by setting VM `kernel` to `""` and installing a kernel + bootloader inside the VM (e.g., `pvgrub2-pvh`).
- Use `qvm-prefs <vm> kernel <version|"">`, `qvm-prefs <vm> virt_mode pvh|hvm`.

### When to use

- **In‑VM kernel**: you need custom kernel modules or kernel pinning; OSes not supported by dom0 kernel; Windows/BSD.
- **PVH**: default for modern Linux; best isolation/perf.
- **HVM**: UEFI boot, raw images, special device models.

### Advantages / Disadvantages

- **+** Per‑VM tuning; PVH improves security; in‑VM kernels allow distro control.
- **–** In‑VM kernels complicate maintenance and can slow boot; HVM adds overhead.

### Example(s)

- Pin a security‑hardened kernel in specific VMs; leave others on default kernel for convenience.
- Set `kernel=""`, install `grub`/kernel in the VM, and use `virt_mode=pvh` with pvgrub2 for an in‑VM kernel workflow.

---

## 3) Events & Integrations (admin.Events, admin.vm.Stats)

### How to use

- Write a small async Python program (in dom0 or an admin VM) using `qubesadmin.events.EventsDispatcher` to subscribe to **system events** or **vm‑stats** streams.
- Map events → actions: health alerts, auto‑policy toggles, dashboard updates.

### When to use

- Real‑time UX: notify on VPN drops, attach devices on VM start, drain volatile volumes when `vm-shutdown` happens.

### Advantages / Disadvantages

- **+** Reactive workflows; fewer polling loops; immediate feedback.
- **–** Needs backoff/reconnect handling; secure the admin VM itself.

### Example(s)

- Listen for `vm-start` and `vm-shutdown` to rotate split‑SSH agent sockets or clear inter‑qube clipboards automatically.

---

## 4) GUI Domain (sys‑gui) — pragmatic usage, not sys‑gui‑vnc

### How to use

- If you deploy **sys‑gui** (GUI domain), keep a simple topology: one GPU path, one GUI daemon. Prefer the documented sys‑gui (not VNC flavor). Keep dom0 lighter.
- Route **policy prompts** and window decorations through the GUI domain; ensure your Admin and qrexec policies account for it (ask prompts require a GUI path).

### When to use

- You want to separate display stack from dom0 for defense‑in‑depth.

### Advantages / Disadvantages

- **+** Reduces dom0 attack surface; enables multi‑GPU ideas.
- **–** Hardware‑sensitive; adds moving parts; troubleshooting can be involved.

### Example(s)

- Tight sys‑gui plus color‑aware window manager setup (AwesomeWM / i3) that reflects qube labels.

---

## 5) qrexec Core (services, arguments, policy routing)

### How to use

- qrexec services are **name‑spaced RPCs** (e.g., `qubes.OpenURL`, `qubes.FileCopy`, custom like `my.Service+arg`).
- Define **service stubs** inside VMs under `/etc/qubes-rpc/` (server side) and call from clients using `qrexec-client-vm` or higher‑level tools (e.g., `qvm-open-in-dvm`).
- Policy matching occurs in dom0 (or GUI domain), reading `policy.d/*.policy` in precedence order.

### When to use

- Any cross‑VM action (copy, URL/file opening, split-\* workflows, admin API calls from non‑dom0).

### Advantages / Disadvantages

- **+** Strong isolation with explicit brokering and central policy enforcement.
- **–** Wrong rules = prompts in weird places or broken UX; complex grammar.

### Example(s)

- Custom service `dev.DockerBuild+<tag>` limited to `@tag:build` qubes; `ask` with default target; deny everywhere else.

---

## 6) Cross‑VM Workflow (secure, robust, transparent)

### How to use

- Prefer **URL & file opening via DispVMs** and **split‑browser** (see §10). Make **Open in DisposableVM** and **Open in Another Qube** the default flow via policies.
- Set `default_dispvm` per qube/template; for each qube, ensure `xdg-open` maps to `qvm-open-in-…` wrappers.
- Use tags (`@tag:web`, `@tag:docs`) to reduce prompt lists and route to correct targets.

### When to use

- Email → Browser; Chat → Browser; PDF → Viewer; unknown files; all first‑touch actions.

### Advantages / Disadvantages

- **+** Massive risk reduction; disposable by default; clear boundaries.
- **–** More prompts if not tuned; cold‑start cost for heavy DispVMs.

### Example(s)

- Mail qube policy: `qubes.OpenURL` → `@dispvm:web-dvm` (ask/allow as you prefer). Office qube: `qubes.OpenInVM` limited to `docs-viewer` or `docs-dvm`.

---

## 7) Persistence Customization & Early‑Boot Control (bind‑dirs, rc.local, rc.local-early)

### How to use

- For files under template‑controlled paths, use **bind‑dirs** to make selected files/directories persistent across reboots.
- For boot‑time hooks:

  - `/rw/config/rc.local` runs late at boot; good for user services or tweaks.
  - `/rw/config/rc.local-early` runs **earlier** (before `sysinit.target`); use for network stack toggles, kernel param adjustments inside the VM, or pre‑GUI environment setup.

- If `rc.local-early` isn’t present by default, emulate it with a bind‑dir overlay or a dedicated systemd unit that runs before `qubes-early-vm-config.service`.

### When to use

- You need persistent config in `/etc` or `/usr` without switching to Standalone; you need very early hooks (e.g., DNS, sysctl) before userland.

### Advantages / Disadvantages

- **+** Fine‑grained persistence; avoids Standalone sprawl.
- **–** Incorrect bind‑dirs patterns can break package updates; early hooks can deadlock startup if they block.

### Example(s)

- Persist `/etc/NetworkManager/system-connections` in a net qube with bind‑dirs.
- Early boot script to seed `/etc/hosts` or bring up a wireguard interface before apps.

---

## 8) Concept of split‑\* (split‑GPG, split‑SSH, split‑Browser, etc.)

### How to use

- Split workflows isolate **secret‑holding agents** into a vault qube and pipe requests over qrexec:

  - **split‑GPG**: GPG keys in a vault; mail qubes call signing/decrypt services.
  - **split‑SSH**: ssh‑agent/socket lives in a vault; dev qubes forward operations.
  - **split‑Browser**: launcher qube sends URLs to a browser qube/DispVM; can combine with Tor/Mullvad nets.

- Implement with provided packages (GPG), community recipes (SSH), or simple RPC wrappers (Browser).

### When to use

- You need hotkey‑friendly, reusable, leak‑resistant flows (dev, ops, email, browsing).

### Advantages / Disadvantages

- **+** Secrets never touch untrusted app qubes; easy to rotate front‑ends.
- **–** More moving parts; debugging requires policy literacy.

### Example(s)

- split‑browser default: clicking any link in any qube opens in `@dispvm:web-dvm`; power users add a policy to route certain tags to a persistent `web-persist` qube for logged‑in sessions.

---

## 9) Efficient Use of Disposable VMs (DispVMs)

### How to use

- Create **named DVM templates** (e.g., `web-dvm`, `docs-dvm`, `pdf-dvm`) with minimal apps and tuned startup (pre‑created caches when safe).
- Set per‑qube `default_dispvm`; wire **right‑click → “Open in DisposableVM”** into muscle memory; ensure `qvm-open-in-dvm` is on PATH.
- For speed: smaller templates, disable heavy extensions, pin fonts; keep network path fast (e.g., `sys-firewall` → `sys-net` tuning).

### When to use

- First‑touch of files/URLs; untrusted downloads; previews; document viewing; ad‑hoc editing with `qvm-open-in-dvm --edit`.

### Advantages / Disadvantages

- **+** Automatic throw‑away; limits persistence and forensics risk.
- **–** Cold start overhead; need distinct DVMs for different file classes.

### Example(s)

- A `docs-dvm` that only has `evince`/`okular` and fonts; a `web-dvm` with hardened browser, no password manager.

---

## 10) Salt State (top.sls, pillars, testing, CI‑style checks)

### How to use

- Place user states in `/srv/user_salt/`, top in `/srv/user_salt/top.sls`; run with `qubesctl state.highstate saltenv=user`.
- Use **pillars** to keep secrets/parameters separate: `/srv/user_pillar/*` and map via your `top.sls` pillar file.
- Validate with: `qubesctl --show-output state.show_sls <name> saltenv=user`, `state.show_top`, `state.show_highstate`.
- Dry‑run with `state.highstate test=True`; lint Jinja/YAML structure; inspect logs (dom0 and targets) when needed.

### When to use

- Provision new installs; rebuild machines reproducibly; rotate policies, tags, features, and appmenus.

### Advantages / Disadvantages

- **+** Idempotent infra‑as‑code for Qubes; easier team sharing; disaster recovery.
- **–** Two execution contexts (dom0 vs templates) can confuse targeting; pillar scoping must be precise.

### Example(s)

- Single state file with Jinja blocks that runs VM creation in dom0 and package installs in the template, gated by `grains['id']`.

---

## 11) CLI Superpowers (patterns you’ll actually use)

### How to use

- Prefer **idempotent, composable** invocations; pipe JSON where possible; avoid `dom0` file copies unless vetted.

### When to use

- Daily automation, scripting, ad‑hoc troubleshooting.

### Advantages / Disadvantages

- **+** Speed, reproducibility; easy to wire into Salt and events.
- **–** Foot‑guns if you skip `--assume-yes-for-ask`/policy checks while testing.

### Example(s)

- **Inventory**: `qvm-ls --fields NAME,STATE,CLASS,NETVM,TEMPLATE --raw-list`
- **Start/Stop**: `qvm-start --skip-if-running <vm>`; `qvm-shutdown --wait --all`
- **Prefs/Features**: `qvm-prefs <vm> default_dispvm web-dvm`; `qvm-features <vm> rpc-clipboard=1`
- **Tags**: `qvm-tags <vm> add work`; `qvm-tags --list <vm>`
- **Devices**: `qvm-usb attach --persistent <vm> <dev>`; `qvm-block a <vm> <dev>`
- **Copy/Move**: `qvm-copy-to-vm <target> file`; `qvm-move-to-vm <target> file`
- **Openers**: `qvm-open-in-dvm <file_or_url>`; `qvm-open-in-vm <vm> <file_or_url>`
- **Volumes**: `qvm-volume list --all`; `qvm-volume info <vm>:private`; `qvm-volume resize <vm>:private +5G` ; `qvm-volume revert <vm>:root`
- **Pools**: `qvm-pool --all`; `qvm-pool --add btrfs_pool file-reflink -o dir_path=/var/lib/qubes_btrfs`
- **Policy test**: `qrexec-policy <src> <dst> qubes.OpenURL` and add `--assume-yes-for-ask` during simulation

---

## 12) Policies (deep dive)

### How to use

- Policies live in `/etc/qubes/policy.d/` with **ordered** file precedence (lower number first). Write minimal, explicit rules per service.
- **Actions**: `allow`, `deny`, `ask` (+ `default_target=`). **Targets**: concrete VM names, `@dispvm:<dvm>`, `@default`, `@anyvm`, `@tag:<name>`, `@adminvm`.
- Use **arguments**: `service+ARG` to match more granularly (e.g., limit `OpenInVM+pdf`).
- Keep a tight **default deny** at the end; use tags to avoid long allowlists.
- For Admin API, maintain separate `admin.*` policy files with clear comments.

### When to use

- Always; policies are your _graph of trust_. Revisit after template or topology changes.

### Advantages / Disadvantages

- **+** Central, auditable control; GUI editor in 4.2 validates syntax; ask‑prompts provide guardrails.
- **–** Syntax/ordering mistakes can silently block flows; prompts need a working GUI path; merging distro updates with local edits requires care.

### Example(s)

- **Clipboard hardening**: limit `qubes.ClipboardPaste` from any qube to only `@tag:work` targets and `ask` with short default target; add hotkeys to clear VM clipboards post‑paste.
- **File copy routing**: `qubes.FileCopy` only from `@tag:ingest` → `@dispvm:av-dvm` for malware screening, then onward to `@tag:docs`.
- **OpenURL default**: any source → `@dispvm:web-dvm` with `ask target=web-dvm`.

---

## 13) Pools & Volumes (LVM‑thin, Btrfs reflink, revisions)

### How to use

- Add pools with `qvm-pool --add <name> lvm_thin -o volume_group=...,thin_pool=...` or `file-reflink -o dir_path=...`.
- Create/clone qubes in a pool: `qvm-create -P <pool> ...` or `qvm-clone -P <pool> ...`.
- Tune volumes: `qvm-volume config <vm>:<vol> revisions_to_keep=3`; `ephemeral=true` for volatile.
- `qvm-volume revert` to roll back a root volume revision (VM must be off).

### When to use

- Offload cold qubes to slower storage; snapshot/revert frequently changed VMs; sandbox experiments.

### Advantages / Disadvantages

- **+** Flexible placement; reflink pools speed clones; revisions enable quick undo.
- **–** Shrink risks data loss; mixing pool types increases cognitive load.

### Example(s)

- Put templates in fast NVMe LVM‑thin; put media or build VMs in Btrfs `file-reflink` pool with compression; keep `revisions_to_keep=2` for root volumes.

---

## 14) Standalone VMs (HVM/StandaloneVMs)

### How to use

- Create with `qvm-create --class StandaloneVM --property virt_mode=hvm --property kernel='' <name>` and install inside the VM; or clone from a template and detach.
- Treat as a self‑contained OS; updates are per‑VM.

### When to use

- Specialized servers/services; OSes that don’t fit the template model; software that must write to `/` at runtime; experiments you will snapshot/export.

### Advantages / Disadvantages

- **+** Full control; no template coupling; easy distro diversity.
- **–** Heavy on disk; no centralized updates; policy sprawl if used widely. If you don’t _need_ it, don’t use it.

### Example(s)

- Self‑hosted dev server qube; Windows standalone for a single vendor tool; BSD firewall lab.

---

## 15) Split‑Browser (default handler, policy, UX)

### How to use

- Choose a **browser qube** (persistent) and a **browser DVM** (ephemeral). Set policies so `qubes.OpenURL` prefers the DVM by default; optionally add a selector `ask` to route to persistent browser when needed.
- In app qubes, ensure `xdg-open` calls `qvm-open-in-dvm` (or a wrapper) so non‑compliant apps still use the split flow.

### When to use

- Make _every_ first‑touch of a URL open in a disposable by default; route login‑required sites to the persistent browser on demand.

### Advantages / Disadvantages

- **+** Stops link‑based drive‑bys from lateralizing; user choice for login flows.
- **–** Some apps bypass xdg‑open; need extra wrappers or MIME tweaks.

### Example(s)

- Mail/chat/file manager in `work-*` qubes → links go to `@dispvm:web-dvm`; keyboard shortcut to force opening in `web-persist` via `qubes.SelectFile`/custom helper.

---

## 16) Troubleshooting Q\&A (common issues)

- **Policy prompts missing / clipboard paste denied**: verify GUI path and policy order; test with `qrexec-policy <src> <dst> qubes.ClipboardPaste` and inspect the result. Restart the policy daemon after fixes.
- **user_salt top not applied**: explicitly set `saltenv=user` or ensure `user_salt` is enabled on 4.2; check `state.show_top`.
- **DispVM slow**: slim templates, disable extensions, ensure enough RAM, consider pre‑warming strategies (launch a minimal DVM early in session).
- **In‑VM kernel boot issues**: confirm bootloader install and pvgrub2; drop to `virt_mode=hvm` for debugging; ensure `kernel=""` is set.
- **Volume revert fails**: VM must be powered off; some drivers block revert while cloning/exporting.

---

## 17) Extra Patterns (that power‑users love)

- **Time‑limited clipboard hygiene**: after paste, auto‑clear per‑VM clipboards with short scripts; keep inter‑qube clipboard transient.
- **Ingress scanning**: route `FileCopy` from ingest qubes → `@dispvm:av-dvm` → sanitized target.
- **Tag‑based routing**: tags like `web`, `docs`, `dev`, `build` replace long lists; update one policy line to reroute whole classes.
- **Events → Actions**: auto‑attach hardware keys on VM start; untag VMs on shutdown; rotate SSH sockets for split‑SSH.

---

# Appendices

## A) Policy snippets (drop‑in ready)

1. **Open URLs in a web DispVM by default**

```
qubes.OpenURL  *  @dispvm:web-dvm  ask target=web-dvm
# Optional convenience: persistent browser fallback
qubes.OpenURL  @tag:trusted  web-persist  ask
# Guardrail: deny everything else explicitly at the end
qubes.OpenURL  *  *  deny
```

2. **Clipboard hygiene (work ring only)**

```
qubes.ClipboardPaste  @tag:work  @tag:work  ask
qubes.ClipboardPaste  *           *          deny
```

3. **File copy via AV DispVM**

```
qubes.FileCopy  @tag:ingest  @dispvm:av-dvm  ask target=av-dvm
# Only after scanning allow onward copy
qubes.FileCopy  @dispvm:av-dvm  @tag:docs  ask
```

4. **Admin API constrained from admin VM**

```
admin.vm.List     adminvm   dom0   allow
admin.vm.property.Get  adminvm   dom0   allow
admin.vm.property.Set  adminvm   dom0   ask
admin.vm.Start    adminvm   dom0   ask
# deny everything else by default
admin.*          *         *      deny
```

## B) DispVM quick‑start (named templates)

1. Create `web-dvm` from a minimal browser template; set `template_for_dispvms=True`.
2. `qvm-prefs <sources> default_dispvm web-dvm` for mail/chat/dev qubes.
3. Add menu entries / MIME associations so unknown files open via `qvm-open-in-dvm`.

## C) Salt skeleton (user space)

```
# /srv/user_salt/top.sls
user:
  dom0:
    - core
```

```
# /srv/user_salt/core.sls (excerpt)
{% if grains['id'] == 'dom0' %}
web_dvm:
  qvm.template_installed:
    - name: fedora-<ver>-minimal
  qvm.vm:
    - name: web-dvm
    - present:
      - template: fedora-<ver>-minimal
      - label: red
    - prefs:
      - template_for_dispvms: True
{% endif %}
```

## D) Early‑boot hook pattern

```
# /rw/config/rc.local-early  (make executable)
#!/bin/sh
sysctl -w net.ipv4.ip_forward=0
# Pre‑seed hosts, etc.
```

## E) Split‑SSH minimal policy

```
ssh.Agent  @tag:dev  vault-ssh  ask
ssh.Sign   @tag:dev  vault-ssh  ask
```

---

# Final Notes

- Keep policies **short, tagged, and testable**. Add one new split‑\* at a time and validate with the policy simulator.
- Favor **templates + bind‑dirs** over Standalone VMs unless you have a strong reason.
- Build with **events → actions**; wire CLI + Salt; document everything in‑repo.

---

# Sources & notes (verified for Qubes 4.2.x)

- **Admin API & events**

  - Admin API docs, service names (e.g., `admin.vm.*`, `admin.Events`, `admin.vm.Stats`) and remote clients. ([Qubes OS][1])
  - Python `qubesadmin.events` dispatcher (listening to `admin.Events`/`admin.vm.Stats`). ([Gitea: Git with a cup of tea][2])

- **qrexec & policy system (4.2 format)**

  - Qrexec overview and service model.
  - RPC policy basics (new policy format introduced with 4.1 and used by default in 4.2).
  - Policy parser/reference for tokens, `@dispvm:<name>`, arguments (`service+ARG`), ordering, and validation.
  - Troubleshooting policy daemon (syntax problems / restarts).

- **Disposables, Open in DispVM, cross-VM openers**

  - “How to use Disposables” & “Disposable customization” including `default_dispvm` and the `qvm-open-in-dvm` behavior.
  - Community guides on opening URLs/files in other qubes and tying it to policy (`qubes.OpenURL`, `qubes.OpenInVM`).

- **Persistence, early-boot hooks**

  - `bind-dirs` for making specific files/dirs persistent.
  - Config files & early hooks (`/rw/config/rc.local`, `/rw/config/rc.local-early`) — what they are and when they run.
  - 4.2 note about `rc.local-early` not shipping by default + safe workaround patterns discussed by the community.

- **Pools & volumes**

  - Secondary storage / pool drivers (LVM-thin, file-reflink/Btrfs) and pool usage.
  - `qvm-volume` manpage (revisions, revert, ephemeral).

- **Kernels & virt modes**

  - Standalone/HVM guidance and `virt_mode`/`kernel=""` usage; when to choose PVH vs HVM and in-VM kernel.
  - Windows/HVM setup references (e.g., longer `qrexec_timeout`, in-VM boot).

- **Salt & pillars**

  - Qubes Salt beginner–to–intermediate guide with examples (`qvm.*` states, `top.sls`, targeting dom0 vs templates).
  - 4.2 user_salt behavior note (`saltenv=user` gotchas).

- **GUI domain**

  - Current state & practical caution around sys-gui-vnc issues (you asked to avoid this; the issue thread reflects instability).

- **Community repos & setups (for 4.2 era)**

  - Curated list (awesome-qubes-os) for tools, configs, and examples.
  - Salt/user_salt examples & packaging patterns (G. Bulnes).
  - Example WM/rice for Qubes (label-aware, widgets) to inspire GUI-domain/window-manager setups.

---

## Two quick, practical clarifications (based on your focus)

1. **“Disposable-first” URLs & files**
   Set a named DVM template (e.g., `web-dvm`) and make it your **default target** for `qubes.OpenURL` and “Open in DisposableVM”. The README includes drop-in policies that:

- send any `OpenURL` to `@dispvm:web-dvm` (with `ask` + default target for muscle-memory flow),
- force unknown files through a minimal `docs-dvm` viewer path first.
  These mirror recommended 4.2 practices and the docs for disposables/customization.

2. **Early-boot control without Standalones**
   On 4.2, use **bind-dirs** to persist only what you need under `/etc`/`/usr`, then hook **`rc.local`** and (if you need _very_ early actions) emulate **`rc.local-early`** with the documented patterns from the config-files page and the community workaround. This avoids the maintenance cost of Standalones while giving you precise boot-time control.

---

[1]: https://www.qubes-os.org/doc/admin-api "Admin API"
[2]: https://git.lsd.cat/Qubes/core-admin-client/blame/commit/060171f19f428368438a0292830573e62823eb70/qubesadmin/events/__init__.p "Qubes/core-admin-client - Gitea"
