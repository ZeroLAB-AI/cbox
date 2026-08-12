# M4 host runbook: codex/hermes guard live verification

Every step here needs a docker-capable host with live codex and/or hermes installed.
None of this can run inside a cbox container. This is the ordered list to verify that
the pinned codex/hermes versions carry the hook features with the assumed semantics,
record native payloads, prove deny/block is honored, and flip the census status from
gated to live. See CAPABILITY_BRAIN_DESIGN.md section 12 for the design context.

## Mandatory sequence

Order matters. Each experiment gates the next; record fixtures before swapping.

| # | Phase | Mandatory before next | Optional / verification only |
|---|------|--------|--------|
| 1 | Codex experiment: enable and record | yes | |
| 2 | Codex verification: deny blocks | | yes |
| 3 | Codex verification: union vs replace | | yes |
| 4 | Hermes experiment: enable and record | yes | |
| 5 | Hermes verification: shell hooks + VALID_HOOKS | | yes |
| 6 | Hermes verification: block JSON honored | | yes |
| 7 | Hermes verification: crash=allow confirmed | | yes |
| 8 | Hermes verification: consent bypass semantics | | yes |
| 9 | Fixture swap and census bind | yes | |
| 10 | Version pin tripwires | yes | |

## 1. Codex experiment: enable and record

Codex guard coverage is gated by the `CBOX_CODEX_HOOKS` knob (default: `off`, defined in
`etc/registry/settings.json`, line 1777). The knob enables `[features].codex_hooks = true`
in the rendered profile and injects PreToolUse hook entries into `hooks.json`.

### 1a. Enable knob and re-bless on a host branch

```bash
cd /path/to/cbox
git checkout -b m4-codex-verify
cbox config set CBOX_CODEX_HOOKS on
cbox setup update
```

Expected output ends with:
```
templates re-blessed (CBOX_TPL_SHA updated) and artifacts regenerated
```

### 1b. Recreate container and start recording

```bash
cbox down
cbox run codex
```

This creates a new container with the enabled knob. Do not close the session yet.

### 1c. Capture real PreToolUse payloads

Inside the running codex session in the container, intercept the actual hook payloads.
The PreToolUse hook is invoked before every Bash tool use. Record payloads by wrapping
the hook command with a capture stage on the host.

**On the host** (in a separate terminal), edit the rendered profile to tee the hook input
to a capture file before invoking the bridge:

```bash
CODEX_HOME="$HOME/.codex"
PROFILE_GENERATED="$(find "$CODEX_HOME" -name "cbox-container.config.toml" -type f | head -1)"
# Example profile path (may vary):
# /root/.codex/cbox-container.config.toml

# Extract the existing hook command from hooks.json:
HOOKS_JSON="$CODEX_HOME/hooks.json"  # or find the path in cbox/generated/
python3 -c "
import json
doc = json.load(open('$HOOKS_JSON'))
for entry in doc.get('hooks', {}).get('PreToolUse', []):
    for h in entry.get('hooks', []):
        print(h.get('command', ''))
"
```

Back in the running codex session, execute a tool that triggers the hook. The hook
payload (JSON, PreToolUse event shape) is passed via stdin to codex_guard_bridge.py.

To record it, modify the generated hook command on the host to capture stdin:

```bash
# Inside the rendered hooks.json, the command looks like:
# "command": "python3 /path/to/codex_guard_bridge.py"

# Wrap it to capture:
# "command": "tee /tmp/codex_payload_capture.json | python3 /path/to/codex_guard_bridge.py"
```

Edit the hooks.json in the container's mounted config and restart. Then execute a
Bash tool (e.g., `ls /tmp`) from codex to trigger the hook.

Collect captures:
```bash
mkdir -p /tmp/m4_fixtures_recorded
cp /tmp/codex_payload_capture.json /tmp/m4_fixtures_recorded/codex_pretooluse_rm_glob_deny.json.raw
```

Repeat for other command shapes (innocuous commands, malformed input) by manually
invoking Bash tools in the codex session or injecting test commands.

### 1d. Verify deny blocks

Using the recorded deny-shaped payload, verify that the bridge decision is deny:

```bash
python3 /path/to/cbox/etc/hooks/codex_guard_bridge.py \
  < /tmp/m4_fixtures_recorded/codex_pretooluse_rm_glob_deny.json.raw
```

Expected output: JSON with `"permissionDecision": "deny"` and a reason.

### 1e. Verify union vs replace

The codex dialect must decide: when a PreToolUse guard denies, does codex **replace**
the entire hook output with the deny decision (replace), or **union** the decision
into the response (union)?

Execute a rm-glob command in the codex session while monitoring the session output.
The deny decision should appear in codex's response, and the tool should not execute.

Expected: the Bash command does not run; codex reports the deny decision to the user.

## 2. Hermes experiment: enable and record

Hermes guard coverage is gated by the `CBOX_HERMES_HOOKS` knob (default: `off`, defined in
`etc/registry/settings.json`, line 1171). The knob enables the hermes hooks: block into
`config.yaml` during container launch (via entrypoint.sh _hermes_apply_hooks).

### 2a. Enable knob and re-bless on the same host branch

```bash
cbox config set CBOX_HERMES_HOOKS on
cbox setup update
```

### 2b. Enable hermes and create a fresh container

```bash
cbox config set CBOX_HERMES on
cbox config set CBOX_HERMES_VERSION latest  # or the pinned version you want to verify
cbox down
cbox run hermes
```

### 2c. Verify pinned hermes version has shell hooks + VALID_HOOKS

On the host, confirm the pinned hermes-agent version carries the pre_tool_call hook
support and has the VALID_HOOKS set defined:

```bash
HERMES_VERSION=$(python3 -c "
import os, re
cbox_conf = os.path.expanduser('~/.claude-cbox/cbox.conf')
with open(cbox_conf) as f:
    for line in f:
        if 'CBOX_HERMES_VERSION=' in line:
            print(line.split('=')[1].strip())
            break
")

pip3 show hermes-agent | grep Version
# Check hermes-agent source or changelog for pre_tool_call hook support:
python3 -c "
import hermes_agent
import inspect
print(inspect.getsourcefile(hermes_agent))
# Locate hooks.py or similar; verify pre_tool_call is in VALID_HOOKS
"
```

Or, for a quick source check without running hermes:
```bash
pip3 show --files hermes-agent | grep hooks.py
# Check the package's hooks.py for VALID_HOOKS = {..., 'pre_tool_call', ...}
```

Expected: VALID_HOOKS includes 'pre_tool_call' (or pre-tool-call, depending on version).

### 2d. Capture real pre_tool_call payloads

Inside the running hermes session, record the actual pre_tool_call payloads as they
enter hermes_guard_bridge.py.

On the host, wrap the hermes hook command to capture stdin:

```bash
HERMES_HOME="$HOME/.claude/hermes" # or equivalent
HOOKS_YAML="$HERMES_HOME/hooks.yaml"

# Modify the generated hooks.yaml to wrap the command:
# Before: command: "python3 /path/to/hermes_guard_bridge.py"
# After:  command: "tee /tmp/hermes_payload_capture.json | python3 /path/to/hermes_guard_bridge.py"
```

Restart hermes or reload the config. Execute terminal tool commands (e.g., `ls /tmp`)
to trigger the hook.

Collect captures:
```bash
mkdir -p /tmp/m4_fixtures_recorded
cp /tmp/hermes_payload_capture.json /tmp/m4_fixtures_recorded/hermes_pretoolcall_rm_glob_deny.json.raw
```

### 2e. Verify block JSON honored

Using the recorded deny-shaped payload, verify that hermes_guard_bridge.py emits the
hermes dialect:

```bash
python3 /path/to/cbox/etc/hooks/hermes_guard_bridge.py \
  < /tmp/m4_fixtures_recorded/hermes_pretoolcall_rm_glob_deny.json.raw
```

Expected output: JSON with `"decision": "block"` and a reason string.

### 2f. Verify crash=allow confirmed

The bridge must degrade to allow (exit 0, no block decision) on any internal exception.
Test this by passing malformed input:

```bash
echo '{"broken": json}' | python3 /path/to/cbox/etc/hooks/hermes_guard_bridge.py
```

Expected: exit code 0, stderr contains a note about the malformed input, output contains
no `"decision": "block"`.

### 2g. Verify consent bypass semantics

Hermes consent rules: if the hook execution crashes, hermes continues (allow).
This is "fail-open armor"  -  the bridge's armored failure mode (catch, log, exit 0,
no block) ensures hermes always allows if the bridge fails.

Verify by introducing a syntax error in the bridge temporarily (for testing only):

```bash
cp /path/to/cbox/etc/hooks/hermes_guard_bridge.py /tmp/hermes_guard_bridge_broken.py
echo 'raise Exception("intentional break")' >> /tmp/hermes_guard_bridge_broken.py

echo '{"hook_event_name": "pre_tool_call", "tool_name": "terminal", "tool_input": {"command": "echo test"}}' | \
  python3 /tmp/hermes_guard_bridge_broken.py
```

Expected: exit code 0, stderr contains the exception note, output does not contain
`"decision": "block"`.

## 3. Fixture swap and census bind

Once both experiments pass verification, replace the spec fixtures with the recorded
ones and flip the capability registry binding status from gated to live.

### 3a. Prepare recorded fixtures

Copy the recorded payloads to the fixtures directory, renaming them to drop the `.raw`
suffix and changing the `provenance` field from "spec" to "recorded":

```bash
for file in /tmp/m4_fixtures_recorded/*.json.raw; do
  target="$(basename "$file" .raw)"
  target="/path/to/cbox/lib/fixtures/m4/$target"
  cp "$file" "$target"
  # Edit each file: change "provenance": "spec" to "provenance": "recorded"
  python3 << 'EOF'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
doc['provenance'] = 'recorded'
with open(path, 'w') as f:
    json.dump(doc, f, indent=2)
EOF
done
```

Files to update:
- `lib/fixtures/m4/codex_pretooluse_rm_glob_deny.json` -> provenance:recorded
- `lib/fixtures/m4/codex_pretooluse_innocuous_allow.json` -> provenance:recorded
- `lib/fixtures/m4/codex_pretooluse_malformed.json` -> provenance:recorded
- `lib/fixtures/m4/hermes_pretoolcall_rm_glob_deny.json` -> provenance:recorded
- `lib/fixtures/m4/hermes_pretoolcall_innocuous_allow.json` -> provenance:recorded
- `lib/fixtures/m4/hermes_pretoolcall_malformed.json` -> provenance:recorded

### 3b. Flip test assertions: from spec to recorded

The guard bridge tests (`lib/test_codex_guard_bridge.sh` and `lib/test_hermes_guard_bridge.sh`)
assert that all fixtures carry `"provenance": "spec"`. Update those assertions:

**In `lib/test_codex_guard_bridge.sh` (lines 32-36):**

```bash
# Before:
grep -q '"provenance": "spec"\|provenance: spec' "$fx" \
  || _fail "fixture $fx is missing the mandatory 'provenance: spec' marker"

# After:
grep -q '"provenance": "recorded"\|provenance: recorded' "$fx" \
  || _fail "fixture $fx is missing the mandatory 'provenance: recorded' marker"
```

**In `lib/test_hermes_guard_bridge.sh` (lines 32-36):**

Same change (spec -> recorded).

### 3c. Flip census binding status

Only two guard capabilities have a codex/hermes binding to flip at all: the bridges
(`etc/hooks/codex_guard_bridge.py`, `etc/hooks/hermes_guard_bridge.py`) invoke exactly
two source guards - `rm_glob_guard.py` and `commit_guard.py` - nothing else. The other
four guard capabilities (guard-code-hygiene, guard-agent-label, guard-spawn,
guard-codex-mode) have no codex/hermes binding in capabilities.json at all (removed as
phantom bindings - the bridges never call code_hygiene_guard.py, agent_label_guard.py,
spawn_gate.py, or codex_mode_guard.py, and codex_mode_guard.py in particular checks
Claude session permission_mode, which has no codex/hermes analog). Do not add codex/hermes
bindings for those four; their honest floor stays `degrade_floor: advisory-text` with no
binding.

Edit `etc/capabilities/capabilities.json` and change the binding status for the two
guard capabilities the bridges actually deliver, from `"gated:codex-hooks-experiment"`
and `"gated:hermes-hooks-experiment"` to `"live"`:

**In capabilities.json, for each guard capability (guard-commit, guard-rm-glob):**

```json
"codex": {
  "mechanism": "shell-hook-pre-tool-call",
  "matcher": "Bash",
  "artifact": "etc/hooks/codex_guard_bridge.py",
  "status": "live"  // was "gated:codex-hooks-experiment"
}

"hermes": {
  "mechanism": "shell-hook-pre-tool-call",
  "matcher": "terminal",
  "artifact": "etc/hooks/hermes_guard_bridge.py",
  "status": "live"  // was "gated:hermes-hooks-experiment"
}
```

The full list of capabilities to update:
- guard-commit: codex binding, hermes binding
- guard-rm-glob: codex binding, hermes binding

Scope note: guard-rm-glob is deny-capable (rm_glob_guard.py can return a hard deny), so
its live flip should be backed by a recorded DENY fixture. guard-commit is advisory-by-design
everywhere (commit_guard.py:33-41 always returns `permissionDecision: allow`, even when it
has a note) - its live flip should be backed by a recorded advisory-note fixture, not a
promised DENY the guard was never built to make.

### 3d. Check file inventory

Confirm that `etc/registry/file_inventory.json` references the m4 fixtures and bridges
in its purposes field (it does, lines 87-97). No changes needed; the inventory already
documents codex_guard_bridge.py and hermes_guard_bridge.py.

### 3e. Commit all changes together

```bash
cd /path/to/cbox
git add \
  lib/fixtures/m4/codex_pretooluse_rm_glob_deny.json \
  lib/fixtures/m4/codex_pretooluse_innocuous_allow.json \
  lib/fixtures/m4/codex_pretooluse_malformed.json \
  lib/fixtures/m4/hermes_pretoolcall_rm_glob_deny.json \
  lib/fixtures/m4/hermes_pretoolcall_innocuous_allow.json \
  lib/fixtures/m4/hermes_pretoolcall_malformed.json \
  lib/test_codex_guard_bridge.sh \
  lib/test_hermes_guard_bridge.sh \
  etc/capabilities/capabilities.json

git commit -m "cbox: M4 guard experiments live - fixtures recorded, census bindings gated->live"
```

This single commit bundles:
- All 6 recorded fixtures with provenance:recorded
- Both test assertion flips (spec -> recorded in both test files)
- The capability registry binding status flips (gated -> live for guard-commit and
  guard-rm-glob only, both codex and hermes - the only two guard capabilities the
  bridges actually deliver)

## 4. Version pin tripwires

After the commit lands, add tripwire alerts to re-verify if version pins change.

### 4a. Codex version pin

The `CBOX_CODEX_VERSION` knob (default: `latest`, defined in `etc/registry/settings.json`
line 1920) controls the pinned codex version. The `CBOX_CODEX_TARGET` variable is also
listed in `etc/engines/engines.json` line 20 under codex version_vars.

If either variable is changed to a non-latest pin:

```bash
CBOX_CODEX_VERSION=0.145.0  # example pin
cbox setup update
cbox down && cbox run codex
# Re-run codex experiment steps 1d-1e (deny blocks, union/replace)
```

Expected: the hooks feature flag still exists and functions identically.

### 4b. Hermes version pin

The `CBOX_HERMES_VERSION` knob (default: `latest`, defined in `etc/registry/settings.json`
line 1116) controls the pinned hermes-agent version.

If changed to a non-latest pin:

```bash
CBOX_HERMES_VERSION=0.4.0  # example pin; adjust to actual release
cbox setup update
cbox down && cbox run hermes
# Re-run hermes experiment steps 2c-2g (VALID_HOOKS check, block JSON, crash=allow, etc.)
```

Expected: VALID_HOOKS still includes pre_tool_call; block JSON is still honored;
crash=allow armor still functions.

### 4c. Running the test suites

Before committing the census flip, run the full test suites to ensure all gates pass:

```bash
cd /path/to/cbox
bash lib/test_codex_guard_bridge.sh
bash lib/test_hermes_guard_bridge.sh
```

Both should report PASS. If either fails, the fixtures or test assertions need revision.

## Fixture honesty invariant

Spec fixtures (provenance:spec) are hand-crafted examples that satisfy the expected
shape but are not actual runtime payloads. They serve as a gate before live experiments.

Recorded fixtures (provenance:recorded) are captured from real codex/hermes runtime
under the pinned versions, serialized exactly as they appear on the wire. They prove
that the assumed dialect and shape are correct and that the bridge handles the real
payload successfully.

The fixture-honesty invariant is: spec fixtures validate the bridge's static shape
assumptions; recorded fixtures validate that the bridge works against actual engines.
Never ship spec fixtures in production; the census status flip to live signals that
recorded fixtures have replaced them and are the source of truth.

## Rollback

If any verification step fails:

```bash
git reset --hard HEAD~1
cbox config set CBOX_CODEX_HOOKS off
cbox config set CBOX_HERMES_HOOKS off
cbox setup update
cbox down && cbox up
```

Investigate the failure, update the bridge code or fixtures, and restart from the
failing step. Do not force the census flip.
