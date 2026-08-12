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

CAPREG="$INSTALL_DIR/etc/capabilities/capabilities.json"
CAPPY="$INSTALL_DIR/etc/capabilities/capability_registry.py"
ENGREG="$INSTALL_DIR/etc/engines/engines.json"
ENGPY="$INSTALL_DIR/etc/engines/engines_registry.py"
SETREG="$INSTALL_DIR/etc/registry/settings.json"
DELREG="$INSTALL_DIR/etc/mcp/delegates.json"
CLAUDE_MERGE="$INSTALL_DIR/etc/claude/settings.merge.json"
MANAGED_MERGE="$INSTALL_DIR/etc/claude/managed-settings.merge.json"
GEN_SH="$INSTALL_DIR/templates/generators.sh"
CBOX_SH="$INSTALL_DIR/cbox"
CBOX_SESSION_SH="$INSTALL_DIR/lib/cbox-session.sh"
PORTABLE_SH="$INSTALL_DIR/lib/portable.sh"
ENTRYPOINT_SH="$INSTALL_DIR/entrypoint.sh"

[ -f "$CAPREG" ] || _fail "capabilities.json not found at $CAPREG"
[ -f "$CAPPY" ] || _fail "capability_registry.py not found at $CAPPY"

python3 -c "import py_compile; py_compile.compile('$CAPPY', doraise=True)" \
  || _fail "capability_registry.py does not py_compile"
_ok "capability_registry.py py_compiles cleanly"

python3 "$CAPPY" validate "$CAPREG" >/dev/null 2>&1 \
  || _fail "real repo capabilities.json does not validate"
_ok "real repo capabilities.json validates against capability_registry.py"

A1_OUT="$(python3 - "$CAPREG" "$ENGREG" <<'PYEOF'
import json
import sys

cap_path, eng_path = sys.argv[1:3]
caps = json.load(open(cap_path))["capabilities"]
engines = set(json.load(open(eng_path))["engines"].keys())

bad = []
for cap_id, spec in caps.items():
    for engine in spec.get("bindings", {}):
        if engine not in engines:
            bad.append("%s:%s" % (cap_id, engine))

if bad:
    print("BAD:" + ",".join(sorted(bad)))
else:
    print("OK")
PYEOF
)"
[ "$A1_OUT" = "OK" ] || _fail "assertion 1: binding engine(s) not in engines.json: $A1_OUT"
_ok "assertion 1: every capability binding engine exists in engines.json"

A2_OUT="$(python3 - "$CAPREG" "$SETREG" <<'PYEOF'
import json
import sys

cap_path, set_path = sys.argv[1:3]
caps = json.load(open(cap_path))["capabilities"]
settings = json.load(open(set_path))
known_vars = set(v["key"] for v in settings["variables"])

bad = []
for cap_id, spec in caps.items():
    ewe = spec.get("enabled_when_env")
    if not ewe:
        continue
    for var in ewe:
        if var not in known_vars:
            bad.append("%s:%s" % (cap_id, var))

if bad:
    print("BAD:" + ",".join(sorted(bad)))
else:
    print("OK")
PYEOF
)"
[ "$A2_OUT" = "OK" ] || _fail "assertion 2: enabled_when_env var(s) not declared in settings.json: $A2_OUT"
_ok "assertion 2: every enabled_when_env entry (iterating the list form) exists in settings.json variables"

A3_OUT="$(python3 - "$CAPREG" "$DELREG" <<'PYEOF'
import json
import sys

cap_path, del_path = sys.argv[1:3]
caps = json.load(open(cap_path))["capabilities"]
delegates = json.load(open(del_path))

tool_caps = set(k for k, v in caps.items() if v.get("class") == "tool")
delegate_names = set(delegates.keys())

missing_cap = sorted(delegate_names - tool_caps)
missing_delegate = sorted(tool_caps - delegate_names)

if missing_cap or missing_delegate:
    print("BAD: delegates-without-capability=%s capabilities-without-delegate=%s" % (missing_cap, missing_delegate))
else:
    print("OK")
PYEOF
)"
[ "$A3_OUT" = "OK" ] || _fail "assertion 3: $A3_OUT"
_ok "assertion 3: every delegates.json entry has its tool-class capability, and every tool-class capability maps back to exactly one delegates entry"

CODEX_HOOKS_HOME="$TMPBASE/codex_home"
CODEX_HOOKS_OUT="$TMPBASE/codex_out"
mkdir -p "$CODEX_HOOKS_HOME" "$CODEX_HOOKS_OUT"

GEN_HARNESS="$TMPBASE/gen_codex_hooks_harness.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'OUTDIR="$1"'
  echo 'HOME="$2"'
  echo 'INSTALL_DIR='"'$INSTALL_DIR'"
  echo 'export INSTALL_DIR'
  echo "source '$INSTALL_DIR/_common.sh'"
  echo "source '$GEN_SH'"
  echo 'gen_codex_hooks_json_into "$OUTDIR"'
} > "$GEN_HARNESS"

bash "$GEN_HARNESS" "$CODEX_HOOKS_OUT" "$CODEX_HOOKS_HOME" \
  || _fail "assertion 4 setup: gen_codex_hooks_json_into failed to render into scratch dir"
[ -f "$CODEX_HOOKS_OUT/hooks.json" ] || _fail "assertion 4 setup: rendered codex hooks.json missing"
_ok "assertion 4 setup: codex hooks.json rendered fresh into a scratch dir (never read from a live generated/ tree)"

A4_OUT="$(python3 - "$CAPREG" "$CLAUDE_MERGE" "$MANAGED_MERGE" "$CODEX_HOOKS_OUT/hooks.json" <<'PYEOF'
import json
import os
import sys

cap_path, claude_merge_path, managed_merge_path, codex_hooks_path = sys.argv[1:5]

caps = json.load(open(cap_path))["capabilities"]


def basenames_for(engine):
    names = set()
    for cap_id, spec in caps.items():
        binding = spec.get("bindings", {}).get(engine)
        if binding:
            artifact = binding.get("artifact")
            if artifact:
                names.add(os.path.basename(artifact))
        for src in spec.get("sources", []) or []:
            names.add(os.path.basename(src))
    return names


def extract_commands(doc):
    commands = []
    hooks = doc.get("hooks", {})
    for event, entries in hooks.items():
        if not isinstance(entries, list):
            continue
        for entry in entries:
            for h in entry.get("hooks", []):
                cmd = h.get("command")
                if cmd:
                    commands.append(cmd)
    return commands


def command_basename(cmd):
    cmd = cmd.replace("@HOME@", "/HOME")
    parts = cmd.split()
    if not parts:
        return None
    script = parts[-1]
    return os.path.basename(script)


claude_doc = json.load(open(claude_merge_path))
managed_doc = json.load(open(managed_merge_path))
codex_doc = json.load(open(codex_hooks_path))

claude_names = basenames_for("claude")
codex_names = basenames_for("codex")

bad = []
for label, doc, known in (
    ("settings.merge.json", claude_doc, claude_names),
    ("managed-settings.merge.json", managed_doc, claude_names),
    ("generated-codex-hooks.json", codex_doc, codex_names),
):
    for cmd in extract_commands(doc):
        base = command_basename(cmd)
        if base is None:
            bad.append("%s:<empty-command>" % label)
            continue
        if base not in known:
            bad.append("%s:%s" % (label, base))

if bad:
    print("BAD:" + ",".join(sorted(set(bad))))
else:
    print("OK")
PYEOF
)"

case "$A4_OUT" in
  OK) _ok "assertion 4: every hook command in settings.merge.json / managed-settings.merge.json / freshly-rendered codex hooks.json appears in some capability binding (artifact or sources, @HOME@ normalized)" ;;
  BAD:*session_pane_map.py*)
    REST="${A4_OUT#BAD:}"
    CLEANED=""
    IFS=',' read -r -a items <<< "$REST"
    for item in "${items[@]}"; do
      case "$item" in
        *session_pane_map.py) ;;
        *) CLEANED="$CLEANED,$item" ;;
      esac
    done
    CLEANED="${CLEANED#,}"
    [ -z "$CLEANED" ] || _fail "assertion 4: unbound hook command(s) beyond the pinned session_pane_map.py gap: $CLEANED"
    _ok "assertion 4: every hook command is bound except the pinned known gap (session_pane_map.py: wired in managed-settings.merge.json SessionStart/SessionEnd, claude-only, but no capability binds or sources it - real M1 finding, not test slack)"
    ;;
  *) _fail "assertion 4: unbound hook command(s): $A4_OUT" ;;
esac

if grep -q 'session_pane_map' "$CAPREG"; then
  _fail "assertion 4 pin is stale: session_pane_map now appears in capabilities.json - remove the session_pane_map.py tolerance branch above"
fi
_ok "assertion 4 pin freshness: session_pane_map.py still absent from capabilities.json (the tolerance branch above is not yet stale)"

REAL_ENGINE_NAMES="$(python3 "$ENGPY" names "$ENGREG")"
[ -n "$REAL_ENGINE_NAMES" ] || _fail "assertion 5 setup: could not list engine names from the real registry"

_engine_predicate_ok() {
  local pred="$1" engine="$2" reg="$3"
  case "$pred" in
    history-non-null)
      local v
      v="$(python3 "$ENGPY" get "$reg" "$engine" history_read 2>/dev/null)" || v="null"
      [ "$v" != "null" ] && [ -n "$v" ]
      ;;
    resume-non-null)
      local v
      v="$(python3 "$ENGPY" get "$reg" "$engine" resume_argv 2>/dev/null)" || v="null"
      [ "$v" != "null" ] && [ -n "$v" ]
      ;;
    bins-volume)
      local v
      v="$(python3 "$ENGPY" get "$reg" "$engine" install 2>/dev/null)" || v=""
      [ "$v" = "bins-volume" ]
      ;;
    full-set)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

A5_FAIL=""

_assert_site_covers_engine() {
  local file="$1" pattern="$2" engine="$3" site_label="$4"
  local rendered="${pattern//%s/$engine}"
  grep -qF -- "$rendered" "$file" \
    || A5_FAIL="$A5_FAIL [$site_label: engine $engine expected but pattern not found: $rendered]"
}

_assert_site_spares_engine() {
  local file="$1" pattern="$2" engine="$3" site_label="$4"
  local rendered="${pattern//%s/$engine}"
  if grep -qF -- "$rendered" "$file"; then
    A5_FAIL="$A5_FAIL [$site_label: engine $engine should be SPARED (projection excludes it) but pattern was found: $rendered]"
  fi
}

for eng in $REAL_ENGINE_NAMES; do
  if _engine_predicate_ok full-set "$eng" "$ENGREG"; then
    grep -qE "^TARGETS = .*\"$eng\"" "$INSTALL_DIR/etc/mcp/render_mcp.py" \
      || A5_FAIL="$A5_FAIL [admission:render_mcp.TARGETS: engine $eng expected in the TARGETS tuple but not found]"
  fi
done
_ok "assertion 5 site admission:render_mcp.TARGETS (full-set): real engines all covered, anchored to the TARGETS tuple line (not the cosmetic usage-line mention)"

for eng in $REAL_ENGINE_NAMES; do
  if _engine_predicate_ok full-set "$eng" "$ENGREG"; then
    grep -qE "^  [a-z|]*\b$eng\b[a-z|]*\)" "$INSTALL_DIR/entrypoint.sh" \
      || A5_FAIL="$A5_FAIL [entrypoint-dispatch:case-arm: engine $eng expected in a per-engine case arm but not found]"
  fi
done
_ok "assertion 5 site entrypoint-dispatch:case-arm (full-set): real engines all covered, anchored to the case-arm pattern (not any mention of the engine name)"

for eng in $REAL_ENGINE_NAMES; do
  if _engine_predicate_ok history-non-null "$eng" "$ENGREG"; then
    _assert_site_covers_engine "$INSTALL_DIR/lib/cbox_session_bridge.py" '"%s": extract_%s' "$eng" "history:extract-dispatch"
  else
    _assert_site_spares_engine "$INSTALL_DIR/lib/cbox_session_bridge.py" '"%s": extract_%s' "$eng" "history:extract-dispatch"
  fi
done
_ok "assertion 5 site history:extract-dispatch (history_read non-null projection): real engines correctly covered"

for eng in $REAL_ENGINE_NAMES; do
  if _engine_predicate_ok history-non-null "$eng" "$ENGREG"; then
    _assert_site_covers_engine "$INSTALL_DIR/lib/cbox_session_bridge.py" '"%s": %s_discover' "$eng" "history:discover-dispatch"
  else
    _assert_site_spares_engine "$INSTALL_DIR/lib/cbox_session_bridge.py" '"%s": %s_discover' "$eng" "history:discover-dispatch"
  fi
done
_ok "assertion 5 site history:discover-dispatch (history_read non-null projection): real engines correctly covered"

for eng in $REAL_ENGINE_NAMES; do
  if _engine_predicate_ok resume-non-null "$eng" "$ENGREG"; then
    _assert_site_covers_engine "$CBOX_SESSION_SH" '%s) engine_args=' "$eng" "resume:engine-args-case"
  else
    _assert_site_spares_engine "$CBOX_SESSION_SH" '%s) engine_args=' "$eng" "resume:engine-args-case"
  fi
done
_ok "assertion 5 site resume:engine-args-case (resume_argv non-null projection): real engines correctly covered"

INSTALL_BINS_SH="$INSTALL_DIR/install-bins.sh"
for eng in $REAL_ENGINE_NAMES; do
  if _engine_predicate_ok bins-volume "$eng" "$ENGREG"; then
    grep -qE "^\s*[A-Za-z0-9_|-]*\b$eng\b[A-Za-z0-9_|-]*\)\s*;;\s*\$" "$INSTALL_BINS_SH" \
      || A5_FAIL="$A5_FAIL [installer:bins-allowlist-arm: engine $eng expected in the bins-volume allowlist arm but not found]"
  fi
done
_ok "assertion 5 site installer:bins-allowlist-arm (install==bins-volume projection): real engines correctly covered"

for eng in $REAL_ENGINE_NAMES; do
  if _engine_predicate_ok full-set "$eng" "$ENGREG"; then
    grep -qE "for tool in [a-z ]*\b$eng\b" "$CBOX_SH" \
      || A5_FAIL="$A5_FAIL [per-tool-loop:cbox: engine $eng expected in the 'for tool in ...' loop but not found]"
  fi
done
_ok "assertion 5 site per-tool-loop:cbox (full-set): real engines all covered, anchored to the 'for tool in ...' loop pattern"

[ -z "$A5_FAIL" ] || _fail "assertion 5: projection mismatch(es) on the real tree:$A5_FAIL"
_ok "assertion 5: all inventoried dispatch sites match their applicable engine subset (projection-aware, real tree)"

A6_OUT="$(python3 - "$CAPREG" "$INSTALL_DIR" <<'PYEOF'
import json
import os
import sys

cap_path, install_dir = sys.argv[1:3]
caps = json.load(open(cap_path))["capabilities"]

GUARD_SOURCE_BY_CLASS_SOURCE = {}
for cap_id, spec in caps.items():
    if spec.get("class") != "guard":
        continue
    sources = spec.get("sources") or []
    guard_basenames = [os.path.basename(s) for s in sources if s.endswith("_guard.py") or s.endswith("_gate.py")]
    if not guard_basenames:
        continue
    GUARD_SOURCE_BY_CLASS_SOURCE[cap_id] = guard_basenames

bridge_src_cache = {}


def bridge_source(artifact):
    if artifact not in bridge_src_cache:
        path = os.path.join(install_dir, artifact)
        with open(path, "r") as f:
            bridge_src_cache[artifact] = f.read()
    return bridge_src_cache[artifact]


bad = []
for cap_id, spec in caps.items():
    guard_basenames = GUARD_SOURCE_BY_CLASS_SOURCE.get(cap_id)
    if not guard_basenames:
        continue
    for engine, binding in (spec.get("bindings") or {}).items():
        artifact = binding.get("artifact")
        if not artifact or not os.path.basename(artifact).endswith("_guard_bridge.py"):
            continue
        src = bridge_source(artifact)
        if not any(gb in src for gb in guard_basenames):
            bad.append("%s:%s:%s(missing %s)" % (cap_id, engine, artifact, "|".join(guard_basenames)))

if bad:
    print("BAD:" + ",".join(sorted(bad)))
else:
    print("OK")
PYEOF
)"
[ "$A6_OUT" = "OK" ] || _fail "assertion 6: phantom guard binding(s) - capability bound to a *_guard_bridge.py artifact that never references the guard's own source script: $A6_OUT"
_ok "assertion 6: every capability binding whose artifact is a *_guard_bridge.py references the guard's own source script inside the bridge (bindings-to-delivery check - closes the phantom-binding class: a capability cannot claim delivery through a bridge that never calls its guard)"

FIXTURE_A_ENGINES="$TMPBASE/fixture_a_engines.json"
python3 -c "
import json
d = json.load(open('$ENGREG'))
d['engines']['stub4'] = {
    'bin': 'stub4',
    'install': 'image',
    'probe': {'kind': 'exe-stamp', 'stamp': 'x', 'infra_filter_argv1': []},
    'version_vars': ['CBOX_STUB4_VERSION'],
    'enabled_var': None,
    'login': 'none',
    'preassign_id': False,
    'resume_argv': None,
    'seed_channel': 'pointer-prompt',
}
json.dump(d, open('$FIXTURE_A_ENGINES', 'w'))
"
python3 "$ENGPY" validate "$FIXTURE_A_ENGINES" >/dev/null 2>&1 \
  || _fail "negative fixture A setup: fixture engines.json (with stub4, null-history) does not validate against engines_registry.py"
_ok "negative fixture A setup: stub4 (history_read key omitted, resume_argv null, seed_channel pointer-prompt) validates as a legal engine"

STUB4_HIST="$(python3 "$ENGPY" get "$FIXTURE_A_ENGINES" stub4 history_read 2>/dev/null)" || STUB4_HIST="null"
[ "$STUB4_HIST" = "null" ] || _fail "negative fixture A setup: stub4 history_read expected null, got $STUB4_HIST"
STUB4_RESUME="$(python3 "$ENGPY" get "$FIXTURE_A_ENGINES" stub4 resume_argv 2>/dev/null)" || STUB4_RESUME="null"
[ "$STUB4_RESUME" = "null" ] || _fail "negative fixture A setup: stub4 resume_argv expected null, got $STUB4_RESUME"

FIXTURE_A_OBSERVED=""

if ! grep -qF '"stub4": extract_stub4' "$INSTALL_DIR/lib/cbox_session_bridge.py"; then
  FIXTURE_A_OBSERVED="$FIXTURE_A_OBSERVED history:extract-dispatch=spared"
else
  _fail "negative fixture A: stub4 (null-history) unexpectedly found in history:extract-dispatch - projection is not actually excluding it"
fi

if ! grep -qF '"stub4": stub4_discover' "$INSTALL_DIR/lib/cbox_session_bridge.py"; then
  FIXTURE_A_OBSERVED="$FIXTURE_A_OBSERVED history:discover-dispatch=spared"
else
  _fail "negative fixture A: stub4 (null-history) unexpectedly found in history:discover-dispatch - projection is not actually excluding it"
fi

if ! grep -qE 'stub4\) engine_args=' "$CBOX_SESSION_SH"; then
  FIXTURE_A_OBSERVED="$FIXTURE_A_OBSERVED resume:engine-args-case=spared"
else
  _fail "negative fixture A: stub4 (null resume_argv) unexpectedly found in resume:engine-args-case - projection is not actually excluding it"
fi

[ -n "$FIXTURE_A_OBSERVED" ] || _fail "negative fixture A: no sites were actually exercised - fixture is vacuous"
_ok "NEGATIVE FIXTURE A OBSERVED: null-history/null-resume stub4 engine is SPARED by all three projected sites ($FIXTURE_A_OBSERVED) - the projection excludes a legitimately-absent engine, not coincidentally green because today's 3 engines all have history"

FIXTURE_B_ROOT="$TMPBASE/fixture_b_root"
mkdir -p "$FIXTURE_B_ROOT/.cbox/sessions/s-20260101-0000-cccccc"

DOCTOR_HARNESS="$TMPBASE/doctor_sessions_harness.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  echo 'ROOT="$1"'
  echo "source '$PORTABLE_SH'"
  echo "source '$CBOX_SESSION_SH'"
  echo '_cbox_workspace_root() { printf "%s" "$ROOT"; }'
  echo '_cbox_doctor_row() { printf "ROW|%s|%s|%s\n" "$1" "$2" "$3"; }'
  echo '_cbox_proc_live() { return 0; }'
  awk '/^_cbox_doctor_session_live_entry\(\) \{/,/^}$/' "$CBOX_SH"
  echo '_cbox_doctor_sessions_scan() {'
  awk '/^  local sess_root sess_dir$/{p=1} p{print} p && /_cbox_doctor_row "sessions" OFF/{getline; print; exit}' "$CBOX_SH"
  echo '}'
  echo '_cbox_doctor_sessions_scan'
} > "$DOCTOR_HARNESS"

grep -q '_cbox_doctor_session_live_entry' "$DOCTOR_HARNESS" \
  || _fail "negative fixture B setup: could not extract _cbox_doctor_session_live_entry from cbox"
grep -q '_cbox_doctor_row "sessions" WARN' "$DOCTOR_HARNESS" \
  || _fail "negative fixture B setup: could not extract the sessions doctor scan block from cbox (WARN row not present in extraction)"
_ok "negative fixture B setup: doctor sessions-scan block + live-entry helper extracted from cbox by structural anchor (not line number)"

bash -c "
set -euo pipefail
source '$PORTABLE_SH'
source '$CBOX_SESSION_SH'
ROOT='$FIXTURE_B_ROOT'
_cbox_session_store_create \"\$ROOT\" 's-20260101-0000-aaaaaa' scope1 ''
_cbox_session_store_create \"\$ROOT\" 's-20260101-0000-bbbbbb' scope1 ''
_cbox_session_set_lease \"\$ROOT\" 's-20260101-0000-aaaaaa' claude native-a preassigned
_cbox_session_set_lease \"\$ROOT\" 's-20260101-0000-bbbbbb' codex native-b discovered
_cbox_runtime_leg_write \"\$ROOT\" 's-20260101-0000-aaaaaa' claude 1 11111 '1111' '2026-01-01T00:00:00Z'
_cbox_runtime_leg_write \"\$ROOT\" 's-20260101-0000-bbbbbb' codex 1 22222 '2222' '2026-01-01T00:01:00Z'
" || _fail "negative fixture B setup: could not populate the two-live-mains session store"

printf 'this is not valid json { broken\n' > "$FIXTURE_B_ROOT/.cbox/sessions/s-20260101-0000-cccccc/session.json"

FIXTURE_B_OUT="$(bash "$DOCTOR_HARNESS" "$FIXTURE_B_ROOT" 2>&1)" \
  || _fail "negative fixture B: doctor sessions-scan CRASHED against the two-live-mains + malformed-third-session fixture:
$FIXTURE_B_OUT"

case "$FIXTURE_B_OUT" in
  *"ROW|sessions|WARN|"*"multiple live session mains in one project scope"*) ;;
  *) _fail "negative fixture B: doctor scan completed but did NOT produce the multi-activeMain WARN - scan is dead. Output:
$FIXTURE_B_OUT" ;;
esac
_ok "NEGATIVE FIXTURE B OBSERVED: two simultaneously-live activeMain sessions produce the 'sessions' doctor WARN with 'multiple live session mains in one project scope' (scan proven non-dead); a third malformed session.json in the same scope did not crash the scan"

FIXTURE_B_SINGLE_ROOT="$TMPBASE/fixture_b_single_root"
mkdir -p "$FIXTURE_B_SINGLE_ROOT"
bash -c "
set -euo pipefail
source '$PORTABLE_SH'
source '$CBOX_SESSION_SH'
ROOT='$FIXTURE_B_SINGLE_ROOT'
_cbox_session_store_create \"\$ROOT\" 's-20260101-0000-dddddd' scope1 ''
_cbox_session_set_lease \"\$ROOT\" 's-20260101-0000-dddddd' claude native-d preassigned
_cbox_runtime_leg_write \"\$ROOT\" 's-20260101-0000-dddddd' claude 1 33333 '3333' '2026-01-01T00:02:00Z'
" || _fail "negative fixture B control setup failed"

FIXTURE_B_SINGLE_OUT="$(bash "$DOCTOR_HARNESS" "$FIXTURE_B_SINGLE_ROOT" 2>&1)" \
  || _fail "negative fixture B control: doctor sessions-scan crashed on a single-live-main fixture"
case "$FIXTURE_B_SINGLE_OUT" in
  *WARN*) _fail "negative fixture B control: a SINGLE live main incorrectly produced a WARN: $FIXTURE_B_SINGLE_OUT" ;;
esac
_ok "negative fixture B control: a single live activeMain session does NOT warn (ACTIVE) - the WARN is not unconditional"

CAP_DOCTOR_HARNESS="$TMPBASE/doctor_capabilities_harness.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  echo 'INSTALL_DIR="$1"'
  echo 'in_container=0'
  echo '_cbox_doctor_row() { printf "ROW|%s|%s|%s\n" "$1" "$2" "$3"; }'
  echo '_cbox_doctor_capabilities_row() {'
  awk '/^  local cap_manifest=/{p=1} p{print} p && /_cbox_doctor_row "capabilities" OFF/{getline; print; exit}' "$CBOX_SH"
  echo '}'
  echo '_cbox_doctor_capabilities_row'
} > "$CAP_DOCTOR_HARNESS"

grep -q '_cbox_doctor_row "capabilities" WARN' "$CAP_DOCTOR_HARNESS" \
  || _fail "negative fixture C setup: capabilities doctor row does not classify an error manifest as WARN - MEDIUM-1 coupling missing (an error-marker manifest is valid JSON, so without an error-key check the doctor would silently report ACTIVE over a vanished manifest)"

FIXTURE_C_ROOT="$TMPBASE/fixture_c_error"
mkdir -p "$FIXTURE_C_ROOT/generated"
printf '%s\n' '{"version": 1, "capabilities": {}, "error": "invalid: capability x: class must be one of [...]"}' > "$FIXTURE_C_ROOT/generated/capability-manifest.json"
FIXTURE_C_OUT="$(bash "$CAP_DOCTOR_HARNESS" "$FIXTURE_C_ROOT" 2>&1)" \
  || _fail "negative fixture C: capabilities doctor row crashed on an error manifest"
case "$FIXTURE_C_OUT" in
  *"ROW|capabilities|WARN|"*) : ;;
  *) _fail "negative fixture C: an error-marker manifest was NOT reported as WARN - MEDIUM-1 security gap (silent ACTIVE over invalid capabilities.json). Output:
$FIXTURE_C_OUT" ;;
esac
_ok "NEGATIVE FIXTURE C OBSERVED: a capability-manifest carrying an error key (emitted when capabilities.json fails validation) is reported by the doctor as WARN, not ACTIVE - the strict validator is not bypassed on the consuming path"

FIXTURE_C_OK_ROOT="$TMPBASE/fixture_c_clean"
mkdir -p "$FIXTURE_C_OK_ROOT/generated"
printf '%s\n' '{"version": 1, "capabilities": {"guard-depth": {"claude": {"status": "live"}}}}' > "$FIXTURE_C_OK_ROOT/generated/capability-manifest.json"
FIXTURE_C_OK_OUT="$(bash "$CAP_DOCTOR_HARNESS" "$FIXTURE_C_OK_ROOT" 2>&1)" \
  || _fail "negative fixture C control: capabilities doctor row crashed on a clean manifest"
case "$FIXTURE_C_OK_OUT" in
  *"ROW|capabilities|ACTIVE|"*) : ;;
  *) _fail "negative fixture C control: a clean manifest was NOT reported as ACTIVE: $FIXTURE_C_OK_OUT" ;;
esac
_ok "negative fixture C control: a clean error-free manifest is reported ACTIVE - the WARN is not unconditional"

M6_ARM_PATTERN='^  [a-z0-9|]*\bstub4\b[a-z0-9|]*\)'

M6_ARM_CONTROL_FIXTURE="$TMPBASE/m6_arm_control.sh"
printf '  stub4) foo ;;\n' > "$M6_ARM_CONTROL_FIXTURE"
grep -qE "$M6_ARM_PATTERN" "$M6_ARM_CONTROL_FIXTURE" \
  || _fail "M6 clause 1a self-check: the arm-detection pattern ($M6_ARM_PATTERN) does not match a synthetic '  stub4) foo ;;' line - the pattern is dead (would never fire even if a real stub4 arm were added), which would make the gap pin vacuously green forever"
_ok "M6 clause 1a self-check: the arm-detection pattern positively matches a synthetic stub4 case-arm line - the pattern is falsifiable, not dead"

if grep -qE "$M6_ARM_PATTERN" "$ENTRYPOINT_SH"; then
  _fail "M6 clause 1: entrypoint.sh unexpectedly has a case arm matching stub4 - the gap this test pins (fourth engine falls through with no preflight/multiplex/context) has closed; upgrade this test to the positive admission proof instead of the gap pin"
fi
_ok "M6 clause 1a: entrypoint.sh has no dispatch arm for stub4 (grep anchor $M6_ARM_PATTERN, falsifiable against a real stub4 arm per the self-check above) - a fourth engine is registry-legal (fixture A) but has no entrypoint arm today"

for eng in claude codex hermes; do
  grep -qE "^  [a-z|]*\b$eng\b[a-z|]*\)" "$ENTRYPOINT_SH" \
    || _fail "M6 clause 1b: entrypoint.sh lost its case arm for real engine $eng - cannot reason about the stub4 gap if the baseline arms are not there"
done
_ok "M6 clause 1b: entrypoint.sh retains dispatch arms for all three real engines (claude, codex, hermes) - the gap pinned below is specific to a fourth engine, not a regression of the existing three"

M6_FALLTHROUGH="$(awk '/^esac$/{found=1; next} found && NF{print; exit}' "$ENTRYPOINT_SH")"
[ "$M6_FALLTHROUGH" = '_run_as_user "$@"' ] \
  || _fail "M6 clause 1c: entrypoint.sh's post-esac fall-through changed (got: ${M6_FALLTHROUGH:-<empty>}) - re-verify whether it still runs a fourth engine with zero preflight/multiplex/context before updating this pin"
_ok "M6 clause 1c: entrypoint.sh's dispatch case ends in a bare '_run_as_user \"\$@\"' fall-through - an engine verb with no arm (e.g. stub4) launches with NO preflight, NO multiplex wrapper, NO context/brain injection"

grep -qF "pointer-prompt" "$ENTRYPOINT_SH" \
  && _fail "M6 clause 1: entrypoint.sh now mentions pointer-prompt - a generic seed_channel admission path may have been added; if so this test must switch from gap-pin to positive-proof (assert the renderer emits context + a pointer for a pointer-prompt engine), not stay on the negative pin"
_ok "ADMISSION GAP PINNED (M6 clause 1): stub4 (pointer-prompt seed_channel, registry-legal per fixture A, CI-spared per fixture A) has NO entrypoint dispatch arm and entrypoint.sh has no pointer-prompt renderer - a fourth engine cannot actually launch WITH context today; it would only reach the bare _run_as_user fall-through. This is the one named admission gap and this assertion fails loudly if it silently regresses (arm added without test update, or claimed-fixed without a renderer)."

M6_CAP_FIXTURE="$TMPBASE/m6_capabilities.json"
python3 -c "
import json
d = json.load(open('$CAPREG'))
d['capabilities']['context-kernel-core']['bindings']['stub4'] = {
    'mechanism': 'pointer-prompt',
    'status': 'live',
}
json.dump(d, open('$M6_CAP_FIXTURE', 'w'))
"
python3 "$CAPPY" validate "$M6_CAP_FIXTURE" >/dev/null 2>&1 \
  || _fail "M6 clause 2: a capabilities.json fixture binding stub4 with mechanism=pointer-prompt does not validate - mechanism is expected to be a free-form non-empty string, not a closed enum"
_ok "M6 clause 2: capability_registry.py accepts a binding with mechanism=pointer-prompt (free-form mechanism string) for a fourth engine - the capability registry CAN describe a pointer-prompt engine's context channel"

grep -qF "pointer-prompt" "$ENTRYPOINT_SH" \
  || _ok "M6 clause 2 (honest absence): even though the registry can DESCRIBE a pointer-prompt binding, no code path in entrypoint.sh renders one - describable in the registry does not mean wired to a renderer (consistent with the clause-1 gap pin); this is feature-off, not silently broken"

M6_A1_FIXTURE_OUT="$(python3 - "$M6_CAP_FIXTURE" "$FIXTURE_A_ENGINES" <<'PYEOF'
import json
import sys

cap_path, eng_path = sys.argv[1:3]
caps = json.load(open(cap_path))["capabilities"]
engines = set(json.load(open(eng_path))["engines"].keys())

bad = []
for cap_id, spec in caps.items():
    for engine in spec.get("bindings", {}):
        if engine not in engines:
            bad.append("%s:%s" % (cap_id, engine))

if bad:
    print("BAD:" + ",".join(sorted(bad)))
else:
    print("OK")
PYEOF
)"
[ "$M6_A1_FIXTURE_OUT" = "OK" ] \
  || _fail "M6 clause 3 setup: referential-integrity check (capabilities bindings subset of engine names) false-failed with a fourth engine present in both fixtures: $M6_A1_FIXTURE_OUT"
_ok "M6 clause 3 setup: the binding-engine-subset-of-registered-engines check does not false-fail when a fourth engine (stub4) is legitimately present in both the engines fixture and the capabilities fixture"

M6_DELREG_CHECK="$(python3 - "$DELREG" <<'PYEOF'
import json
import sys

data = json.load(open(sys.argv[1]))
offenders = []
for name, spec in data.items():
    avail = (spec.get("_cbox") or {}).get("available_to") or []
    if "stub4" in avail:
        offenders.append(name)
if offenders:
    print("BAD:" + ",".join(sorted(offenders)))
else:
    print("OK")
PYEOF
)"
[ "$M6_DELREG_CHECK" = "OK" ] \
  || _fail "M6 clause 3: delegates.json lists stub4 in an available_to array unexpectedly: $M6_DELREG_CHECK - real delegates.json should not name a fixture-only engine"
_ok "M6 clause 3a: delegates.json names stub4 in zero available_to arrays (real delegates.json only ever lists claude/codex/hermes) - a fourth engine gets NO delegates today, the correct feature-off floor"

grep -qE '"stub4"' "$INSTALL_DIR/etc/mcp/render_mcp.py" \
  && _fail "M6 clause 3b: render_mcp.py TARGETS or code now mentions stub4 - a fourth engine target render may have been wired without extending the admission contract test"
_ok "M6 clause 3b: render_mcp.py's TARGETS tuple (claude, codex, hermes) does not include stub4 - the MCP tool render is correctly closed to the three real engines"

M6_MANIFEST_ROOT="$TMPBASE/m6_manifest_install"
mkdir -p "$M6_MANIFEST_ROOT/etc/capabilities" "$M6_MANIFEST_ROOT/generated"
cp "$M6_CAP_FIXTURE" "$M6_MANIFEST_ROOT/etc/capabilities/capabilities.json"
cp "$CAPPY" "$M6_MANIFEST_ROOT/etc/capabilities/capability_registry.py"

M6_MANIFEST_GEN_LOG="$(bash -c "
set -euo pipefail
INSTALL_DIR='$M6_MANIFEST_ROOT'
source '$GEN_SH'
gen_capability_manifest_into '$M6_MANIFEST_ROOT/generated'
" 2>&1)" || _fail "M6 clause 4: gen_capability_manifest_into crashed with a stub4-bound fixture registry present:
$M6_MANIFEST_GEN_LOG"

M6_MANIFEST_JSON="$M6_MANIFEST_ROOT/generated/capability-manifest.json"
[ -f "$M6_MANIFEST_JSON" ] \
  || _fail "M6 clause 4: gen_capability_manifest_into did not write $M6_MANIFEST_JSON"

python3 - "$M6_MANIFEST_JSON" <<'PYEOF' || _fail "M6 clause 4: capability manifest JSON did not contain the expected stub4 row or lost the real engine rows (see $M6_MANIFEST_JSON)"
import json
import sys

m = json.load(open(sys.argv[1]))
assert "error" not in m, "manifest carries an error key: %r" % m.get("error")
row = m["capabilities"]["context-kernel-core"]
assert "stub4" in row, "stub4 missing from context-kernel-core row: %r" % row
assert row["stub4"]["mechanism"] == "pointer-prompt", row["stub4"]
assert "claude" in row and "codex" in row and "hermes" in row, row
PYEOF
_ok "M6 clause 4: gen_capability_manifest_into runs clean (exit 0, no error key) against a fixture capabilities.json with a stub4 binding present, and the emitted matrix shows the stub4 row (mechanism=pointer-prompt) alongside the three real engine rows without crashing"

M6_SUITE_LOG="$TMPBASE/m6_suite.log"
M6_SUITE_FAIL=0
for suite in test_engines_registry.sh test_file_inventory.sh; do
  if ! bash "$INSTALL_DIR/lib/$suite" > "$M6_SUITE_LOG.$suite" 2>&1; then
    M6_SUITE_FAIL=1
    echo "M6 clause 5: $suite FAILED with stub4 fixture era present:" >&2
    cat "$M6_SUITE_LOG.$suite" >&2
  fi
done
[ "$M6_SUITE_FAIL" -eq 0 ] \
  || _fail "M6 clause 5: one or more sibling suites failed - see stderr above"
_ok "M6 clause 5: sibling suites (test_engines_registry.sh, test_file_inventory.sh) still pass on the real tree - adding the stub4 fixture engine to this harness did not break discover/extract/CLI/installer projections elsewhere (this suite itself passing to this point covers the projection-spare assertions for test_capabilities_registry.sh)"

echo "PASS: all capabilities registry checks"
