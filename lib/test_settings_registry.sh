#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

REG="$INSTALL_DIR/etc/registry/settings.json"
PY="$INSTALL_DIR/etc/registry/settings_registry.py"
GEN="$INSTALL_DIR/etc/registry/gen_sections_sh.py"
SEC="$INSTALL_DIR/templates/sections.sh"
GEN_CONF="$INSTALL_DIR/etc/registry/gen_conf_lib.py"
CONF_LIB="$INSTALL_DIR/templates/conf_lib.sh"
GEN_VAL="$INSTALL_DIR/etc/registry/gen_validators.py"
VAL_DISPATCH="$INSTALL_DIR/templates/validator_dispatch.sh"
VAL_LIB="$INSTALL_DIR/templates/validator_lib.sh"

[ -f "$REG" ] || _fail "settings.json not found at $REG"
[ -f "$PY" ] || _fail "settings_registry.py not found at $PY"
[ -f "$GEN" ] || _fail "gen_sections_sh.py not found at $GEN"
[ -f "$SEC" ] || _fail "sections.sh not found at $SEC"
[ -f "$GEN_CONF" ] || _fail "gen_conf_lib.py not found at $GEN_CONF"
[ -f "$CONF_LIB" ] || _fail "conf_lib.sh not found at $CONF_LIB"
[ -f "$GEN_VAL" ] || _fail "gen_validators.py not found at $GEN_VAL"
[ -f "$VAL_DISPATCH" ] || _fail "validator_dispatch.sh not found at $VAL_DISPATCH"
[ -f "$VAL_LIB" ] || _fail "validator_lib.sh not found at $VAL_LIB"

python3 -c "import py_compile; py_compile.compile('$PY', doraise=True)" \
  || _fail "settings_registry.py does not py_compile"
_ok "settings_registry.py py_compiles cleanly"

python3 -c "import py_compile; py_compile.compile('$GEN', doraise=True)" \
  || _fail "gen_sections_sh.py does not py_compile"
_ok "gen_sections_sh.py py_compiles cleanly"

python3 -c "import py_compile; py_compile.compile('$GEN_CONF', doraise=True)" \
  || _fail "gen_conf_lib.py does not py_compile"
_ok "gen_conf_lib.py py_compiles cleanly"

python3 -c "import py_compile; py_compile.compile('$GEN_VAL', doraise=True)" \
  || _fail "gen_validators.py does not py_compile"
_ok "gen_validators.py py_compiles cleanly"

bash -n "$VAL_LIB" || _fail "templates/validator_lib.sh does not pass bash -n"
_ok "templates/validator_lib.sh passes bash -n"

bash -n "$VAL_DISPATCH" || _fail "templates/validator_dispatch.sh does not pass bash -n"
_ok "templates/validator_dispatch.sh passes bash -n"

python3 "$PY" validate "$REG" >/dev/null 2>&1 \
  || _fail "real settings.json does not validate"
_ok "real repo settings.json validates"

GEN_OUT="$TMPBASE/sections_generated.sh"
python3 "$GEN" "$REG" "$GEN_OUT" || _fail "generator crashed"
diff -u "$SEC" "$GEN_OUT" >"$TMPBASE/gen_diff.txt" 2>&1 \
  || _fail "regenerating templates/sections.sh from the registry produces a diff (generated file is stale):
$(cat "$TMPBASE/gen_diff.txt")"
_ok "templates/sections.sh is current (regenerating produces no diff)"

GEN_CONF_OUT="$TMPBASE/conf_lib_generated.sh"
python3 "$GEN_CONF" "$REG" "$GEN_CONF_OUT" || _fail "conf_lib generator crashed"
diff -u "$CONF_LIB" "$GEN_CONF_OUT" >"$TMPBASE/gen_conf_diff.txt" 2>&1 \
  || _fail "regenerating templates/conf_lib.sh from the registry produces a diff (generated file is stale):
$(cat "$TMPBASE/gen_conf_diff.txt")"
_ok "templates/conf_lib.sh is current (regenerating produces no diff)"

GEN_VAL_OUT="$TMPBASE/validator_dispatch_generated.sh"
python3 "$GEN_VAL" "$REG" "$GEN_VAL_OUT" || _fail "validator dispatch generator crashed"
diff -u "$VAL_DISPATCH" "$GEN_VAL_OUT" >"$TMPBASE/gen_val_diff.txt" 2>&1 \
  || _fail "regenerating templates/validator_dispatch.sh from the registry produces a diff (generated file is stale):
$(cat "$TMPBASE/gen_val_diff.txt")"
_ok "templates/validator_dispatch.sh is current (regenerating produces no diff)"

DUMP_HARNESS="$TMPBASE/dump.sh"
cat > "$DUMP_HARNESS" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$1"

_declare_p_escape() {
  local v="$1"
  case "$v" in
    *[$'\x01'-$'\x1f']*)
      printf 'dump: value contains a control character; the synthetic declare -A form cannot mirror the ANSI-C $'"'"'...'"'"' quoting real declare -p emits for such values, so the parity gate would silently lose data on one side. Add control-character-safe quoting to _synth_assoc before allowing such a value into the registry.\n' >&2
      exit 1
      ;;
  esac
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  v="${v//\$/\\\$}"
  v="${v//\`/\\\`}"
  printf '%s' "$v"
}

_synth_assoc() {
  local arr="$1" k line
  line="declare -A $arr=("
  while IFS= read -r k; do
    line+="[$k]=\"$(_declare_p_escape "$(sec_get "$arr" "$k")")\" "
  done < <(sec_keys "$arr")
  line+=")"
  printf '%s\n' "$line"
}

for arr in SECTIONS DOCTOR_EXTRA_ROWS; do
  declare -p "$arr" 2>/dev/null || true
done

if declare -F sec_get >/dev/null 2>&1; then
  for arr in SEC_TITLE SEC_DESC SEC_VARS SEC_APPLY SEC_PROFILE SEC_SCOPE SEC_DEPS SEC_DEP_TEXT SEC_DOCTOR_ROWS; do
    _synth_assoc "$arr"
  done
else
  for arr in SEC_TITLE SEC_DESC SEC_VARS SEC_APPLY SEC_PROFILE SEC_SCOPE SEC_DEPS SEC_DEP_TEXT SEC_DOCTOR_ROWS; do
    declare -p "$arr" 2>/dev/null || true
  done
fi
EOF

NORMALIZE_PY="$TMPBASE/normalize.py"
cat > "$NORMALIZE_PY" << 'EOF'
import sys, re
text = open(sys.argv[1]).read()
out = []
for line in text.splitlines():
    m = re.match(r'declare -a (\w+)=\((.*)\)$', line)
    if m:
        name, body = m.groups()
        items = re.findall(r'\[\d+\]="((?:[^"\\]|\\.)*)"', body)
        out.append((name, "array", items))
        continue
    m = re.match(r'declare -A (\w+)=\((.*) \)$', line)
    if m:
        name, body = m.groups()
        pairs = re.findall(r'\[([^\]]*)\]="((?:[^"\\]|\\.)*)"', body)
        pairs.sort()
        out.append((name, "assoc", pairs))
        continue
    m = re.match(r'declare -A (\w+)$', line)
    if m:
        out.append((m.group(1), "assoc", []))
        continue
    out.append(("RAW", "raw", line))
out.sort(key=lambda x: (x[0], x[1]))
for item in out:
    print(item)
EOF

PRE_REGISTRY_SNAPSHOT="$INSTALL_DIR/lib/fixtures/sections.sh.pre_registry_snapshot"
[ -f "$PRE_REGISTRY_SNAPSHOT" ] || _fail "pre-registry sections.sh snapshot fixture not found at $PRE_REGISTRY_SNAPSHOT (git HEAD is far behind the working tree in this repo, so the parity baseline is a captured fixture, not git HEAD)"

bash "$DUMP_HARNESS" "$PRE_REGISTRY_SNAPSHOT" > "$TMPBASE/old_dump.txt" 2>/dev/null || true
bash "$DUMP_HARNESS" "$SEC" > "$TMPBASE/new_dump.txt" 2>/dev/null || true

python3 "$NORMALIZE_PY" "$TMPBASE/old_dump.txt" > "$TMPBASE/old_norm.txt"
python3 "$NORMALIZE_PY" "$TMPBASE/new_dump.txt" > "$TMPBASE/new_norm.txt"

ADOPTION_DELTA_PY="$TMPBASE/adoption_delta.py"
cat > "$ADOPTION_DELTA_PY" << 'EOF'
import ast, sys

NEW_SECTIONS = ["autoupdate", "dns", "clipboard", "kernel-lang", "user-layer"]
DELTA = {
    "SEC_TITLE": {
        "autoupdate": "Engine autoupdate",
        "dns": "DNS",
        "clipboard": "Clipboard image bridge",
        "kernel-lang": "Conduct kernel language rule",
        "user-layer": "User extension layer",
    },
    "SEC_DESC": {
        "autoupdate": "Host-side engine autoupdate for channel targets (claude stable/latest, codex latest, hermes latest): re-runs the vendor installer once the TTL elapses.",
        "dns": "DNS resolution inside the container when egress is enabled: Docker embedded DNS, public resolvers, or a host-stable stub resolver IP.",
        "clipboard": "Host clipboard image bridge over a unix socket answering Claude Code's Ctrl+V image paste inside the container.",
        "kernel-lang": "Two-part language rule rendered into the deployed conduct kernel: reason in one language, answer in another. Off (output language empty) by default - the rule is not rendered until an output language is set.",
        "user-layer": "Host directory mounted read-only into the container at /etc/cbox/user, letting a user drop their own MCP server declarations (user/mcp/*.json) without touching cbox-owned config. cbox never writes under this directory - only the directory itself is created if missing.",
    },
    "SEC_VARS": {
        "autoupdate": "CBOX_AUTOUPDATE CBOX_AUTOUPDATE_TTL_HOURS",
        "dns": "CBOX_DNS_MODE CBOX_DNS_SERVERS CBOX_DNS_STUB_IP",
        "clipboard": "CBOX_CLIPBOARD_MODE",
        "kernel-lang": "CBOX_KERNEL_LANG_OUTPUT CBOX_KERNEL_LANG_REASONING",
        "user-layer": "CBOX_USER_DIR",
    },
    "SEC_APPLY": {
        "autoupdate": "none",
        "dns": "recreate",
        "clipboard": "recreate",
        "kernel-lang": "none",
        "user-layer": "recreate",
    },
    "SEC_PROFILE": {
        "autoupdate": "skip",
        "dns": "skip",
        "clipboard": "skip",
        "kernel-lang": "skip",
        "user-layer": "skip",
    },
    "SEC_SCOPE": {
        "autoupdate": "project",
        "dns": "project",
        "clipboard": "project",
        "kernel-lang": "project",
        "user-layer": "project",
    },
    "SEC_DOCTOR_ROWS": {
        "autoupdate": "",
        "dns": "",
        "clipboard": "clipboard",
        "kernel-lang": "",
        "user-layer": "",
    },
}

MODIFIED = {
    "SEC_VARS": {
        "netaccess": "CBOX_NETACCESS_MODE CBOX_NETACCESS_APPLIED CBOX_NETACCESS_SCOPE CBOX_NETACCESS_NETWORKS CBOX_NETACCESS_CIDRS CBOX_NETACCESS_SOCKS_PORT CBOX_NETACCESS_EXEC_MODE CBOX_NETACCESS_EXEC_WORKSPACE_GUARD CBOX_NETACCESS_EXEC_TIMEOUT CBOX_NETACCESS_EXEC_MAX_BYTES CBOX_CONTAINER_EXEC_TOOL",
        "mounts": "CBOX_CLAUDE_MODE CBOX_CLAUDE_PATH CBOX_CLAUDE_BACKUP CBOX_CODEX_MODE CBOX_CODEX_PATH CBOX_CODEX_BACKUP CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG",
        "autoresume": "CBOX_LIMIT_AUTORESUME CBOX_SESSION_MULTIPLEX CBOX_SAFEGUARD_AUTOCONFIRM CBOX_SESSION_BROKER_MODE CBOX_SSHD_LISTEN_ADDR CBOX_SSHD_PORT CBOX_LIMIT_RESUME_DELAY CBOX_LIMIT_RESUME_PROMPT CBOX_LIMIT_RESUME_STAGGER CBOX_LIMIT_RESUME_MAX_PER_DAY",
        "wireguard": "CBOX_WG_MODE CBOX_WG_IMPL CBOX_WG_ADDRESS CBOX_WG_LISTEN_PORT CBOX_WG_PUBLISH_ADDR CBOX_WG_PEER_ENDPOINT CBOX_WG_PEER_PUBKEY CBOX_WG_PEER_ADDRESS CBOX_WG_KEEPALIVE CBOX_WG_FORWARDS",
        "bashrc": "CBOX_BASHRC CBOX_BASHRC_COMMANDS",
        "hermes": "CBOX_HERMES CBOX_HERMES_VERSION CBOX_HERMES_PROVIDER CBOX_HERMES_MODEL_URL CBOX_HERMES_MODEL_NAME CBOX_HERMES_HOOKS",
        "codex-mcp": "CBOX_CODEX_MCP CBOX_CODEX_HOOKS CBOX_CODEX_MODEL CBOX_CODEX_EFFORT",
        "ollama": "CBOX_OLLAMA_MODE CBOX_OLLAMA_IMAGE CBOX_OLLAMA_GPU CBOX_OLLAMA_STORE CBOX_OLLAMA_STORE_PATH CBOX_OLLAMA_PORT CBOX_OLLAMA_NUM_PARALLEL CBOX_OLLAMA_CONTEXT_LENGTH CBOX_OLLAMA_FLASH_ATTENTION CBOX_OLLAMA_KV_CACHE_TYPE CBOX_OLLAMA_KEEP_ALIVE",
        "local-model": "CBOX_LOCAL_MODEL CBOX_LOCAL_MODEL_URL CBOX_LOCAL_MODEL_NAME CBOX_LOCAL_MODEL_TIMEOUT_SEC",
    },
    "SEC_DESC": {
        "autoresume": "Wrap interactive sessions in tmux and let a per-container watchdog type the resume prompt after a usage-limit window resets (isolated session scope + claude mount only). Also carries the in-container sshd remote-attach feature (disabled by default): three layers - WireGuard, an ssh key, and this container's access level - gate list/attach/spawn against the tmux sessions the wrap creates.",
    },
    "SEC_DOCTOR_ROWS": {
        "netaccess": "netaccess container-exec container-exec-tool",
        "autoresume": "session-broker",
    },
}


def load(path):
    return [ast.literal_eval(line) for line in open(path) if line.strip()]


old = load(sys.argv[1])
new = load(sys.argv[2])

expected = []
for name, kind, payload in old:
    if name == "SECTIONS" and kind == "array":
        payload = payload + NEW_SECTIONS
    elif name in DELTA and kind == "assoc":
        payload = sorted(payload + list(DELTA[name].items()))
    if name in MODIFIED and kind == "assoc":
        payload = [
            (k, MODIFIED[name].get(k, v)) for k, v in payload
        ]
    if name == "RAW" and kind == "raw":
        payload = payload.replace(
            'DOCTOR_EXTRA_ROWS="codex-profile context-manifest local-model local-model-egress managed-dirs config-pending sessions"',
            'DOCTOR_EXTRA_ROWS="codex-profile context-manifest local-model local-model-egress managed-dirs config-pending sessions capabilities stale-binds"',
        )
    expected.append((name, kind, payload))

if expected != new:
    exp_lines = [repr(x) for x in expected]
    new_lines = [repr(x) for x in new]
    import difflib
    sys.stderr.write("\n".join(difflib.unified_diff(exp_lines, new_lines, "expected(old+delta)", "generated", lineterm="")))
    sys.stderr.write("\n")
    sys.exit(1)
EOF

python3 "$ADOPTION_DELTA_PY" "$TMPBASE/old_norm.txt" "$TMPBASE/new_norm.txt" 2> "$TMPBASE/parity_diff.txt" \
  || _fail "SEC_* arrays differ from the pre-registry snapshot by MORE than the declared shadow-setting adoption (sections autoupdate/dns/clipboard with their six variables, plus the netaccess CBOX_CONTAINER_EXEC_TOOL variable/doctor-row addition, plus the mounts CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG variable addition, plus the autoresume CBOX_SESSION_MULTIPLEX variable addition, plus the wireguard CBOX_WG_FORWARDS variable addition, plus the autoresume CBOX_SESSION_BROKER_MODE variable and session-broker doctor-row addition, plus the autoresume CBOX_SSHD_LISTEN_ADDR and CBOX_SSHD_PORT variable additions and updated SEC_DESC for the in-container sshd ForceCommand entry, plus the new kernel-lang section with its two CBOX_KERNEL_LANG_OUTPUT/CBOX_KERNEL_LANG_REASONING variables, plus the capabilities and stale-binds doctor-extra-row additions to DOCTOR_EXTRA_ROWS, plus the clipboard doctor row on the clipboard section, plus the hermes CBOX_HERMES_HOOKS variable addition, plus the codex-mcp CBOX_CODEX_HOOKS variable addition, plus the codex-mcp CBOX_CODEX_MODEL and CBOX_CODEX_EFFORT variable additions, plus the ollama CBOX_OLLAMA_CONTEXT_LENGTH/CBOX_OLLAMA_FLASH_ATTENTION/CBOX_OLLAMA_KV_CACHE_TYPE/CBOX_OLLAMA_KEEP_ALIVE variable additions, plus the local-model CBOX_LOCAL_MODEL_TIMEOUT_SEC variable addition):
$(cat "$TMPBASE/parity_diff.txt")"
_ok "parity gate: generated sections.sh equals the pre-registry snapshot plus exactly the declared adoption delta (autoupdate/dns/clipboard sections, six variables, skip profile, project scope, empty doctor rows; plus CBOX_CONTAINER_EXEC_TOOL added to the existing netaccess section and its container-exec-tool doctor row; plus CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG added to the existing mounts section; plus CBOX_SESSION_MULTIPLEX added to the existing autoresume section; plus CBOX_SAFEGUARD_AUTOCONFIRM added to the existing autoresume section; plus CBOX_WG_FORWARDS added to the existing wireguard section; plus CBOX_SESSION_BROKER_MODE added to the existing autoresume section and its session-broker doctor row; plus CBOX_SSHD_LISTEN_ADDR and CBOX_SSHD_PORT added to the existing autoresume section with its SEC_DESC updated for sshd; plus the new kernel-lang section (CBOX_KERNEL_LANG_OUTPUT, CBOX_KERNEL_LANG_REASONING), apply_class none, skip profile, project scope, empty doctor rows; plus the capabilities and stale-binds doctor-extra-rows added to DOCTOR_EXTRA_ROWS; plus the clipboard section gaining its own clipboard doctor row; plus CBOX_HERMES_HOOKS added to the existing hermes section (M4 experiment gate, default off); plus CBOX_CODEX_HOOKS added to the existing codex-mcp section (M4 experiment gate, default off); plus CBOX_CODEX_MODEL and CBOX_CODEX_EFFORT added to the existing codex-mcp section (configurable codex profile model/effort, defaults gpt-5.6-terra/xhigh)) - nothing else moved"

NAMES="$(python3 "$PY" sections "$REG")"
[ -n "$NAMES" ] || _fail "sections command returned nothing"
_ok "sections command lists section ids"

VARS="$(python3 "$PY" vars "$REG")"
[ -n "$VARS" ] || _fail "vars command returned nothing"
VAR_COUNT="$(printf '%s\n' "$VARS" | grep -c .)"
[ "$VAR_COUNT" -eq 117 ] || _fail "expected 117 variables in the registry, got $VAR_COUNT"
_ok "vars command lists all 117 variables"

W="$TMPBASE/reg"
mkdir -p "$W"

python3 - "$REG" "$W/incomplete_var.json" << 'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
del data["variables"][0]["prompt"]
json.dump(data, open(sys.argv[2], "w"))
PYEOF
if python3 "$PY" validate "$W/incomplete_var.json" >/dev/null 2>&1; then
  _fail "variable record missing a required key was accepted"
fi
_ok "incomplete variable record rejected"

python3 - "$REG" "$W/unknown_section_ref.json" << 'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
data["variables"][0]["section"] = "does-not-exist"
json.dump(data, open(sys.argv[2], "w"))
PYEOF
if python3 "$PY" validate "$W/unknown_section_ref.json" >/dev/null 2>&1; then
  _fail "variable referencing an unknown section was accepted"
fi
_ok "variable with unknown section reference rejected"

python3 - "$REG" "$W/unbound_validator.json" << 'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
data["variables"][0]["type"] = {"kind": "string", "escape_hatch": "made-up-validator"}
json.dump(data, open(sys.argv[2], "w"))
PYEOF
if python3 "$PY" validate "$W/unbound_validator.json" >/dev/null 2>&1; then
  _fail "unbound named validator escape hatch was accepted"
fi
_ok "unbound named validator rejected"

python3 - "$REG" "$W/unbound_resolver.json" << 'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
for v in data["variables"]:
    if v["key"] == "CBOX_WORKDIR":
        v["default"] = {"kind": "resolver", "name": "made-up-resolver"}
json.dump(data, open(sys.argv[2], "w"))
PYEOF
if python3 "$PY" validate "$W/unbound_resolver.json" >/dev/null 2>&1; then
  _fail "unbound named resolver was accepted"
fi
_ok "unbound named resolver rejected"

python3 - "$REG" "$W/dup_owner.json" << 'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
dup = dict(data["variables"][0])
dup["section"] = data["sections"][1]["id"]
data["variables"].append(dup)
json.dump(data, open(sys.argv[2], "w"))
PYEOF
if python3 "$PY" validate "$W/dup_owner.json" >/dev/null 2>&1; then
  _fail "variable owned by two sections was accepted"
fi
_ok "variable owned by two sections rejected"

python3 - "$REG" "$W/bad_default.json" << 'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
for v in data["variables"]:
    if v["key"] == "CBOX_GPU":
        v["default"] = "not-a-valid-enum-value"
json.dump(data, open(sys.argv[2], "w"))
PYEOF
if python3 "$PY" validate "$W/bad_default.json" >/dev/null 2>&1; then
  _fail "default failing its own declared enum validator was accepted"
fi
_ok "default failing its own declared validator rejected"

python3 - "$REG" "$W/dep_no_text.json" << 'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
data["sections"][0]["dependencies"] = [{"kind": "disable", "reason": "never-documented"}]
json.dump(data, open(sys.argv[2], "w"))
PYEOF
if python3 "$PY" validate "$W/dep_no_text.json" >/dev/null 2>&1; then
  _fail "dependency without a dependency_text entry was accepted"
fi
_ok "dependency missing dependency_text entry rejected"

python3 - "$REG" "$W/unknown_top.json" << 'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
data["extra"] = 1
json.dump(data, open(sys.argv[2], "w"))
PYEOF
if python3 "$PY" validate "$W/unknown_top.json" >/dev/null 2>&1; then
  _fail "unknown top-level key was accepted"
fi
_ok "unknown top-level key rejected"

python3 - "$REG" "$W/bad_schema.json" << 'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
data["schema_version"] = 2
json.dump(data, open(sys.argv[2], "w"))
PYEOF
if python3 "$PY" validate "$W/bad_schema.json" >/dev/null 2>&1; then
  _fail "schema_version != 1 was accepted"
fi
_ok "schema_version mismatch rejected"

python3 - "$REG" "$W/bad_uint_type.json" << 'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
for v in data["variables"]:
    if v["key"] == "CBOX_BASE_DIGEST_TTL":
        v["type"] = {"kind": "made-up-type"}
json.dump(data, open(sys.argv[2], "w"))
PYEOF
if python3 "$PY" validate "$W/bad_uint_type.json" >/dev/null 2>&1; then
  _fail "unknown type.kind was accepted"
fi
_ok "unknown type.kind rejected"

python3 - "$REG" "$W/dup_section_id.json" << 'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
data["sections"].append(dict(data["sections"][0]))
json.dump(data, open(sys.argv[2], "w"))
PYEOF
if python3 "$PY" validate "$W/dup_section_id.json" >/dev/null 2>&1; then
  _fail "duplicate section id was accepted"
fi
_ok "duplicate section id rejected"

echo '{ not json' > "$W/not_json.json"
if python3 "$PY" validate "$W/not_json.json" >/dev/null 2>&1; then
  _fail "malformed JSON was accepted"
fi
_ok "malformed JSON rejected"

python3 - "$REG" "$W/two_dep_section.json" << 'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
for s in data["sections"]:
    if s["id"] == "gpu":
        s["dependencies"] = [
            {"kind": "disable", "reason": "no-cdi"},
            {"kind": "dictate", "reason": "hooks"},
        ]
data["dependency_text"]["dictate:hooks"] = "auto-deploys the ask-claude hook when enabled"
json.dump(data, open(sys.argv[2], "w"))
PYEOF
python3 "$PY" validate "$W/two_dep_section.json" >/dev/null 2>&1 \
  || _fail "a section with two dependencies failed to validate"
python3 "$GEN" "$W/two_dep_section.json" "$W/two_dep_sections.sh" || _fail "generator crashed on the two-dependency section"
TWO_DEP_VAL="$(. "$W/two_dep_sections.sh"; sec_get SEC_DEPS gpu)"
[ "$TWO_DEP_VAL" = 'disable:no-cdi dictate:hooks' ] \
  || _fail "generator does not space-join a section's multiple dependency tokens into one SEC_DEPS entry: got [$TWO_DEP_VAL]"
_ok "a section with two dependencies generates one space-joined SEC_DEPS entry"

(
  CBOX_SSH_AGENT_DIR=/tmp/agent-dir-preset
  CBOX_USER_DIR=""
  CBOX_KERNEL_LANG_REASONING=""
  CBOX_CLAUDE_PATH=""
  . "$INSTALL_DIR/templates/conf_lib.sh"
  _cbox_reg_conf_defaults
  [ -z "$CBOX_USER_DIR" ] || { echo "CBOX_USER_DIR reset to [$CBOX_USER_DIR]" >&2; exit 1; }
  [ -z "$CBOX_KERNEL_LANG_REASONING" ] || { echo "CBOX_KERNEL_LANG_REASONING reset to [$CBOX_KERNEL_LANG_REASONING]" >&2; exit 1; }
  [ -z "$CBOX_CLAUDE_PATH" ] || { echo "CBOX_CLAUDE_PATH reset to [$CBOX_CLAUDE_PATH]" >&2; exit 1; }
) || _fail "conf defaults clobber explicitly-empty values - an empty (disabled) setting does not survive conf_load (colon-equals regression)"
_ok "conf defaults preserve explicitly-empty values (empty CBOX_USER_DIR stays disabled across save/load)"

(
  unset CBOX_USER_DIR CBOX_KERNEL_LANG_REASONING CBOX_MODE 2>/dev/null || true
  CBOX_SSH_AGENT_DIR=/tmp/agent-dir-preset
  . "$INSTALL_DIR/templates/conf_lib.sh"
  _cbox_reg_conf_defaults
  [ "$CBOX_USER_DIR" = "$HOME/.config/cbox/user" ] || { echo "unset CBOX_USER_DIR default broken: [$CBOX_USER_DIR]" >&2; exit 1; }
  [ "$CBOX_KERNEL_LANG_REASONING" = "slovencina bez diakritiky" ] || { echo "unset CBOX_KERNEL_LANG_REASONING default broken: [$CBOX_KERNEL_LANG_REASONING]" >&2; exit 1; }
  [ "$CBOX_MODE" = "global" ] || { echo "unset CBOX_MODE default broken: [$CBOX_MODE]" >&2; exit 1; }
) || _fail "conf defaults no longer apply to unset variables"
_ok "conf defaults still apply to unset variables (unset CBOX_USER_DIR gets the shipped default)"

echo "PASS: all settings_registry checks"
