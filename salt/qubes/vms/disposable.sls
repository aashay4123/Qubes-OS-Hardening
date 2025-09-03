# Create/replace a Debian-based DispVM template "DefaultDVM" and set it as global default.
# Leaves Whonix disposables alone (just reports presence).

# --- Presence checks (do not hard-fail where not required) ---

check-debian-12-hard-present:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx debian-12-hard'"

check-existing-DefaultDVM:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx DefaultDVM'"
    - success_retcodes:
      - 0
      - 1

check-whonix-dvm-present:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --fields CLASS,NAME | awk \"\\$1==\\\"DispVMTemplate\\\"{print \\$2}\" | grep -Eqx \"whonix-ws-[0-9]+-dvm\" || true'"
    - success_retcodes:
      - 0

# --- Remove old DefaultDVM (idempotent) ---

remove-old-DefaultDVM:
  cmd.run:
    - name: "/bin/sh -c 'if qvm-ls --raw-list | grep -qx DefaultDVM; then qvm-shutdown --wait DefaultDVM 2>/dev/null || true; qvm-remove -f DefaultDVM; fi'"
    - require:
      - cmd: check-existing-DefaultDVM

# --- Create fresh DefaultDVM as DispVMTemplate (2-step, robust) ---

create-DefaultDVM-class:
  cmd.run:
    - name: "/bin/sh -c 'set -e; qvm-ls --raw-list | grep -qx DefaultDVM || qvm-create -C DispVMTemplate -l yellow DefaultDVM'"
    - require:
      - cmd: check-debian-12-hard-present
      - cmd: remove-old-DefaultDVM

set-DefaultDVM-template:
  cmd.run:
    - name: "/bin/sh -c 'qvm-prefs DefaultDVM template debian-12-hard'"
    - require:
      - cmd: create-DefaultDVM-class

# Optional basic prefs (safe no-ops if unchanged)
DefaultDVM-prefs:
  cmd.run:
    - name: "/bin/sh -c 'qvm-prefs DefaultDVM label yellow >/dev/null'"
    - require:
      - cmd: set-DefaultDVM-template

# --- Set global default disposable template ---

set-global-default-dispvm:
  cmd.run:
    - name: "/bin/sh -c 'qubes-prefs default_dispvm DefaultDVM'"
    - require:
      - cmd: set-DefaultDVM-template

# --- Verification (hard fail on mismatch) ---

verify-DefaultDVM-exists:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --raw-list | grep -qx DefaultDVM'"
    - require:
      - cmd: create-DefaultDVM-class

verify-DefaultDVM-is-dispvmtemplate:
  cmd.run:
    - name: "/bin/sh -c 'qvm-ls --fields CLASS,NAME | awk \"\\$1==\\\"DispVMTemplate\\\"{print \\$2}\" | grep -qx DefaultDVM'"
    - require:
      - cmd: create-DefaultDVM-class

verify-DefaultDVM-template-source:
  cmd.run:
    - name: "/bin/sh -c '[ \"$(qvm-prefs DefaultDVM template)\" = \"debian-12-hard\" ]'"
    - require:
      - cmd: set-DefaultDVM-template

verify-global-default:
  cmd.run:
    - name: "/bin/sh -c '[ \"$(qubes-prefs default_dispvm)\" = \"DefaultDVM\" ]'"
    - require:
      - cmd: set-global-default-dispvm

# --- Summary (always prints) ---

disposable-summary:
  cmd.run:
    - name: |
        /bin/sh -c '
        printf "\n=== Disposable setup ===\n"
        printf "DefaultDVM class     : %s\n" "$(qvm-ls --fields CLASS,NAME | awk "/ DefaultDVM$/ {print \$1}")"
        printf "DefaultDVM template  : %s\n" "$(qvm-prefs DefaultDVM template 2>/dev/null || echo "(missing)")"
        printf "Global default_dispvm: %s\n" "$(qubes-prefs default_dispvm 2>/dev/null)"
        printf "\nKnown DispVM templates:\n"
        qvm-ls --fields CLASS,NAME | awk "\$1==\"DispVMTemplate\"{print \" - \" \$2}"
        '
    - require:
      - cmd: verify-DefaultDVM-exists
      - cmd: verify-DefaultDVM-is-dispvmtemplate
      - cmd: verify-DefaultDVM-template-source
      - cmd: verify-global-default
