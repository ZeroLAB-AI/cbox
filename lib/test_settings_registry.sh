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
for arr in SECTIONS SEC_TITLE SEC_DESC SEC_VARS SEC_APPLY SEC_PROFILE SEC_SCOPE SEC_DEPS SEC_DEP_TEXT SEC_DOCTOR_ROWS DOCTOR_EXTRA_ROWS; do
  declare -p "$arr" 2>/dev/null || true
done
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

diff -u "$TMPBASE/old_norm.txt" "$TMPBASE/new_norm.txt" > "$TMPBASE/parity_diff.txt" 2>&1 \
  || _fail "SEC_* arrays (declare -p, key order normalised) differ between the pre-registry sections.sh snapshot and the generated one:
$(cat "$TMPBASE/parity_diff.txt")"
_ok "parity gate: SEC_TITLE/SEC_DESC/SEC_VARS/SEC_APPLY/SEC_PROFILE/SEC_SCOPE/SEC_DEPS/SEC_DEP_TEXT/SEC_DOCTOR_ROWS/SECTIONS/DOCTOR_EXTRA_ROWS identical to the pre-registry snapshot after sourcing (declare -p, key order normalised)"

NAMES="$(python3 "$PY" sections "$REG")"
[ -n "$NAMES" ] || _fail "sections command returned nothing"
_ok "sections command lists section ids"

VARS="$(python3 "$PY" vars "$REG")"
[ -n "$VARS" ] || _fail "vars command returned nothing"
VAR_COUNT="$(printf '%s\n' "$VARS" | grep -c .)"
[ "$VAR_COUNT" -eq 96 ] || _fail "expected 96 variables in the registry, got $VAR_COUNT"
_ok "vars command lists all 96 variables"

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
TWO_DEP_OUT="$(python3 "$GEN" "$W/two_dep_section.json")"
echo "$TWO_DEP_OUT" | grep -qx "SEC_DEPS\[gpu\]='disable:no-cdi dictate:hooks'" \
  || _fail "generator does not space-join a section's multiple dependency tokens into one SEC_DEPS assignment: $(echo "$TWO_DEP_OUT" | grep 'SEC_DEPS\[gpu\]')"
_ok "a section with two dependencies generates one space-joined SEC_DEPS assignment"

echo "PASS: all settings_registry checks"
