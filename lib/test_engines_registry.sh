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

REG="$INSTALL_DIR/etc/engines/engines.json"
PY="$INSTALL_DIR/etc/engines/engines_registry.py"

[ -f "$REG" ] || _fail "engines.json not found at $REG"
[ -f "$PY" ] || _fail "engines_registry.py not found at $PY"

python3 -c "import py_compile; py_compile.compile('$PY', doraise=True)" \
  || _fail "engines_registry.py does not py_compile"
_ok "engines_registry.py py_compiles cleanly"

python3 "$PY" validate "$REG" >/dev/null 2>&1 \
  || _fail "real registry does not validate"
_ok "real repo engines.json validates"

NAMES="$(python3 "$PY" names "$REG")"
[ "$NAMES" = "$(printf 'claude\ncodex\nhermes')" ] \
  || _fail "names output mismatch: got [$NAMES]"
_ok "names lists claude, codex, hermes in order"

BIN="$(python3 "$PY" get "$REG" claude bin)"
[ "$BIN" = "claude" ] || _fail "get claude bin mismatch: $BIN"
_ok "get claude bin == claude"

STAMP="$(python3 "$PY" get "$REG" codex probe.stamp)"
[ "$STAMP" = '$HOST_HOME/.codex/packages/.cbox-stamp' ] \
  || _fail "get codex probe.stamp mismatch: $STAMP"
_ok "get codex probe.stamp (dotted key into nested object)"

ENABLED="$(python3 "$PY" get "$REG" claude enabled_var)"
[ "$ENABLED" = "null" ] || _fail "get claude enabled_var should print null, got $ENABLED"
_ok "get claude enabled_var == null"

W="$TMPBASE/reg"
mkdir -p "$W"

cat > "$W/unknown_top.json" <<'EOF'
{"schema": 1, "engines": {"claude": {"bin": "claude", "install": "bins-volume", "probe": {"kind": "exe-stamp", "stamp": "x", "infra_filter_argv1": []}, "version_vars": ["V"], "enabled_var": null, "login": "none"}}, "extra": 1}
EOF
if python3 "$PY" validate "$W/unknown_top.json" >/dev/null 2>&1; then
  _fail "unknown top-level key was accepted"
fi
_ok "unknown top-level key rejected"

cat > "$W/unknown_engine_key.json" <<'EOF'
{"schema": 1, "engines": {"claude": {"bin": "claude", "install": "bins-volume", "probe": {"kind": "exe-stamp", "stamp": "x", "infra_filter_argv1": []}, "version_vars": ["V"], "enabled_var": null, "login": "none", "extra": 1}}}
EOF
if python3 "$PY" validate "$W/unknown_engine_key.json" >/dev/null 2>&1; then
  _fail "unknown per-engine key was accepted"
fi
_ok "unknown per-engine key rejected"

cat > "$W/missing_engine_key.json" <<'EOF'
{"schema": 1, "engines": {"claude": {"bin": "claude", "install": "bins-volume", "probe": {"kind": "exe-stamp", "stamp": "x", "infra_filter_argv1": []}, "version_vars": ["V"], "enabled_var": null}}}
EOF
if python3 "$PY" validate "$W/missing_engine_key.json" >/dev/null 2>&1; then
  _fail "missing per-engine key (login) was accepted"
fi
_ok "missing per-engine key rejected"

cat > "$W/wrong_probe_kind.json" <<'EOF'
{"schema": 1, "engines": {"claude": {"bin": "claude", "install": "bins-volume", "probe": {"kind": "made-up", "stamp": "x"}, "version_vars": ["V"], "enabled_var": null, "login": "none"}}}
EOF
if python3 "$PY" validate "$W/wrong_probe_kind.json" >/dev/null 2>&1; then
  _fail "unknown probe.kind was accepted"
fi
_ok "unknown probe.kind rejected"

cat > "$W/exe_stamp_missing_field.json" <<'EOF'
{"schema": 1, "engines": {"claude": {"bin": "claude", "install": "bins-volume", "probe": {"kind": "exe-stamp", "stamp": "x"}, "version_vars": ["V"], "enabled_var": null, "login": "none"}}}
EOF
if python3 "$PY" validate "$W/exe_stamp_missing_field.json" >/dev/null 2>&1; then
  _fail "exe-stamp probe missing infra_filter_argv1 was accepted"
fi
_ok "exe-stamp probe missing infra_filter_argv1 rejected"

cat > "$W/exe_stamp_extra_field.json" <<'EOF'
{"schema": 1, "engines": {"claude": {"bin": "claude", "install": "bins-volume", "probe": {"kind": "exe-stamp", "stamp": "x", "infra_filter_argv1": [], "argv0_prefix": "y"}, "version_vars": ["V"], "enabled_var": null, "login": "none"}}}
EOF
if python3 "$PY" validate "$W/exe_stamp_extra_field.json" >/dev/null 2>&1; then
  _fail "exe-stamp probe with canonical-paths field was accepted"
fi
_ok "exe-stamp probe with foreign field (argv0_prefix) rejected"

cat > "$W/canonical_missing_field.json" <<'EOF'
{"schema": 1, "engines": {"hermes": {"bin": "hermes", "install": "image", "probe": {"kind": "canonical-paths", "exe_realpath_prefix": "/usr/bin/python3", "argv0_prefix": "/opt/hermes/bin/"}, "version_vars": ["V"], "enabled_var": "CBOX_HERMES", "login": "none"}}}
EOF
if python3 "$PY" validate "$W/canonical_missing_field.json" >/dev/null 2>&1; then
  _fail "canonical-paths probe missing argv1 was accepted"
fi
_ok "canonical-paths probe missing argv1 rejected"

cat > "$W/bad_install.json" <<'EOF'
{"schema": 1, "engines": {"claude": {"bin": "claude", "install": "usb-stick", "probe": {"kind": "exe-stamp", "stamp": "x", "infra_filter_argv1": []}, "version_vars": ["V"], "enabled_var": null, "login": "none"}}}
EOF
if python3 "$PY" validate "$W/bad_install.json" >/dev/null 2>&1; then
  _fail "unknown install value was accepted"
fi
_ok "unknown install value rejected"

cat > "$W/bad_login.json" <<'EOF'
{"schema": 1, "engines": {"claude": {"bin": "claude", "install": "bins-volume", "probe": {"kind": "exe-stamp", "stamp": "x", "infra_filter_argv1": []}, "version_vars": ["V"], "enabled_var": null, "login": "carrier-pigeon"}}}
EOF
if python3 "$PY" validate "$W/bad_login.json" >/dev/null 2>&1; then
  _fail "unknown login value was accepted"
fi
_ok "unknown login value rejected"

cat > "$W/wrong_type.json" <<'EOF'
{"schema": 1, "engines": {"claude": {"bin": "claude", "install": "bins-volume", "probe": {"kind": "exe-stamp", "stamp": "x", "infra_filter_argv1": []}, "version_vars": "V", "enabled_var": null, "login": "none"}}}
EOF
if python3 "$PY" validate "$W/wrong_type.json" >/dev/null 2>&1; then
  _fail "version_vars as a string instead of a list was accepted"
fi
_ok "version_vars wrong type rejected"

cat > "$W/bad_schema.json" <<'EOF'
{"schema": 2, "engines": {"claude": {"bin": "claude", "install": "bins-volume", "probe": {"kind": "exe-stamp", "stamp": "x", "infra_filter_argv1": []}, "version_vars": ["V"], "enabled_var": null, "login": "none"}}}
EOF
if python3 "$PY" validate "$W/bad_schema.json" >/dev/null 2>&1; then
  _fail "schema != 1 was accepted"
fi
_ok "schema version mismatch rejected"

cat > "$W/whitespace_name.json" <<'EOF'
{"schema": 1, "engines": {" claude ": {"bin": "claude", "install": "bins-volume", "probe": {"kind": "exe-stamp", "stamp": "x", "infra_filter_argv1": []}, "version_vars": ["V"], "enabled_var": null, "login": "none"}}}
EOF
if python3 "$PY" validate "$W/whitespace_name.json" >/dev/null 2>&1; then
  _fail "engine name with surrounding whitespace was accepted"
fi
_ok "engine name with surrounding whitespace rejected"

cat > "$W/uppercase_name.json" <<'EOF'
{"schema": 1, "engines": {"Claude": {"bin": "claude", "install": "bins-volume", "probe": {"kind": "exe-stamp", "stamp": "x", "infra_filter_argv1": []}, "version_vars": ["V"], "enabled_var": null, "login": "none"}}}
EOF
if python3 "$PY" validate "$W/uppercase_name.json" >/dev/null 2>&1; then
  _fail "engine name with uppercase letters was accepted"
fi
_ok "engine name with uppercase letters rejected"

cat > "$W/schema_bool.json" <<'EOF'
{"schema": true, "engines": {"claude": {"bin": "claude", "install": "bins-volume", "probe": {"kind": "exe-stamp", "stamp": "x", "infra_filter_argv1": []}, "version_vars": ["V"], "enabled_var": null, "login": "none"}}}
EOF
if python3 "$PY" validate "$W/schema_bool.json" >/dev/null 2>&1; then
  _fail "schema: true (boolean) was accepted as schema 1"
fi
_ok "schema boolean true rejected (not the integer 1)"

cat > "$W/schema_float.json" <<'EOF'
{"schema": 1.0, "engines": {"claude": {"bin": "claude", "install": "bins-volume", "probe": {"kind": "exe-stamp", "stamp": "x", "infra_filter_argv1": []}, "version_vars": ["V"], "enabled_var": null, "login": "none"}}}
EOF
if python3 "$PY" validate "$W/schema_float.json" >/dev/null 2>&1; then
  _fail "schema: 1.0 (float) was accepted as schema 1"
fi
_ok "schema float 1.0 rejected (not the integer 1)"

echo '{ not json' > "$W/not_json.json"
if python3 "$PY" validate "$W/not_json.json" >/dev/null 2>&1; then
  _fail "malformed JSON was accepted"
fi
_ok "malformed JSON rejected"

v_cbox="$INSTALL_DIR/cbox"
v_install_bins="$INSTALL_DIR/install-bins.sh"
v_entrypoint="$INSTALL_DIR/entrypoint.sh"
v_sections="$INSTALL_DIR/templates/sections.sh"

[ -f "$v_cbox" ] || _fail "cbox script not found for textual-agreement harness"
[ -f "$v_install_bins" ] || _fail "install-bins.sh not found"
[ -f "$v_entrypoint" ] || _fail "entrypoint.sh not found"
[ -f "$v_sections" ] || _fail "sections.sh not found"

ib_allow="$(grep -oE '^\s*[A-Za-z0-9_|-]+\)\s*;;' "$v_install_bins" | head -1 | sed -E 's/^\s*//; s/\)\s*;;\s*$//')"
ep_arm="$(grep -oE '^  [A-Za-z0-9_|-]+\)\s*$' "$v_entrypoint" | sed -E 's/^\s*//; s/\)\s*$//' | tr '\n' '|' | sed 's/|$//')"

[ -n "$ib_allow" ] || _fail "could not extract install-bins.sh main() allowlist arm"
[ -n "$ep_arm" ] || _fail "could not extract entrypoint.sh verb gate arm"

case "|$ib_allow|" in *"|claude|"*) ;; *) _fail "install-bins allowlist missing claude: $ib_allow" ;; esac
case "|$ib_allow|" in *"|codex|"*) ;; *) _fail "install-bins allowlist missing codex: $ib_allow" ;; esac
case "|$ep_arm|" in *"|claude|"*) ;; *) _fail "entrypoint verb gate missing claude: $ep_arm" ;; esac
case "|$ep_arm|" in *"|codex|"*) ;; *) _fail "entrypoint verb gate missing codex: $ep_arm" ;; esac
case "|$ep_arm|" in *"|hermes|"*) ;; *) _fail "entrypoint verb gate missing hermes: $ep_arm" ;; esac
_ok "textual-agreement harness: install-bins + entrypoint arms contain claude, codex, hermes (matches verify-check greps)"

for eng in claude codex; do
  bin="$(python3 "$PY" get "$REG" "$eng" bin)"
  [ "$bin" = "$eng" ] || _fail "registry bin for $eng is $bin, expected $eng (entrypoint agreement)"
  install="$(python3 "$PY" get "$REG" "$eng" install)"
  [ "$install" = "bins-volume" ] || _fail "registry install for $eng is $install, expected bins-volume"
done

bin="$(python3 "$PY" get "$REG" hermes bin)"
[ "$bin" = "hermes" ] || _fail "registry bin for hermes is $bin, expected hermes"
install="$(python3 "$PY" get "$REG" hermes install)"
[ "$install" = "image" ] || _fail "registry install for hermes is $install, expected image"
case "|$ib_allow|" in *"|hermes|"*) _fail "hermes must not be in install-bins.sh allowlist (install=image, not bins-volume)" ;; esac
_ok "claude+codex registry bin/install fields agree with install-bins/entrypoint reality"

sec_binaries="$(grep -oE "^SEC_VARS\[binaries\]='[^']*'" "$v_sections" | sed -E "s/^SEC_VARS\[binaries\]='//; s/'\$//")"
for eng in claude codex; do
  vv="$(python3 "$PY" get "$REG" "$eng" version_vars | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)))')"
  for v in $vv; do
    case " $sec_binaries " in
      *" $v "*) ;;
      *) _fail "SEC_VARS[binaries] missing $v (declared by $eng.version_vars)" ;;
    esac
  done
done
_ok "claude+codex version_vars all present in SEC_VARS[binaries]"

HARNESS="$TMPBASE/live_verify_harness.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  echo "INSTALL_DIR=\"\$1\""
  echo 'VN=0; VOK=0; VFAIL=0; VSKIP=0'
  echo 'v_t() { VN=$((VN + 1)); :; }'
  echo 'v_ok() { VOK=$((VOK + 1)); }'
  echo 'v_fail() { VFAIL=$((VFAIL + 1)); echo "verify-check v_fail: ${1:-}" >&2; }'
  echo 'v_skip() { VSKIP=$((VSKIP + 1)); }'
  awk '/^_cbox_verify_engines_registry\(\) \{/,/^}$/' "$v_cbox"
  echo '_cbox_verify_engines_registry'
  echo 'echo "VN=$VN VOK=$VOK VFAIL=$VFAIL VSKIP=$VSKIP"'
} > "$HARNESS"

bash "$HARNESS" "$INSTALL_DIR" > "$TMPBASE/live_verify_check.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] || _fail "live _cbox_verify_engines_registry crashed:
$(cat "$TMPBASE/live_verify_check.out")"

grep -q 'v_fail' "$TMPBASE/live_verify_check.out" && _fail "live check against real repo reported a FAIL:
$(cat "$TMPBASE/live_verify_check.out")"
_ok "live _cbox_verify_engines_registry (extracted from cbox) reports no FAIL against the real repo"

grep -qE 'NOTE: engines pending an entrypoint arm:.*hermes' "$TMPBASE/live_verify_check.out" \
  && _fail "hermes is armed in entrypoint.sh now - it must no longer appear in the pending-entrypoint-arm NOTE:
$(cat "$TMPBASE/live_verify_check.out")"
_ok "live check no longer reports hermes in the pending-entrypoint-arm NOTE (hermes is armed)"

grep -qE 'NOTE: pending engines with no SEC_VARS coverage yet:.*hermes' "$TMPBASE/live_verify_check.out" \
  && _fail "hermes has SEC_VARS[hermes] coverage now - it must no longer appear in the pending SEC_VARS-gap NOTE:
$(cat "$TMPBASE/live_verify_check.out")"
_ok "live check no longer reports hermes in the pending-SEC_VARS-gap NOTE (hermes has SEC_VARS[hermes])"

HARNESS2="$TMPBASE/live_verify_harness_mixed.sh"
W2="$TMPBASE/mixed"
mkdir -p "$W2/etc/engines" "$W2/templates"
python3 - "$REG" "$W2/etc/engines/engines.json" <<'PYEOF'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
data = json.load(open(src))
data["engines"]["claude"]["version_vars"] = ["CBOX_CLAUDE_TOTALLY_UNCOVERED_VAR"]
json.dump(data, open(dst, "w"))
PYEOF
cp "$PY" "$W2/etc/engines/engines_registry.py"
cp "$v_install_bins" "$W2/install-bins.sh"
cp "$v_entrypoint" "$W2/entrypoint.sh"
cp "$v_sections" "$W2/templates/sections.sh"

{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  echo "INSTALL_DIR=\"\$1\""
  echo 'VN=0; VOK=0; VFAIL=0; VSKIP=0'
  echo 'v_t() { VN=$((VN + 1)); :; }'
  echo 'v_ok() { VOK=$((VOK + 1)); }'
  echo 'v_fail() { VFAIL=$((VFAIL + 1)); echo "verify-check v_fail: ${1:-}" >&2; }'
  echo 'v_skip() { VSKIP=$((VSKIP + 1)); }'
  awk '/^_cbox_verify_engines_registry\(\) \{/,/^}$/' "$v_cbox"
  echo '_cbox_verify_engines_registry'
} > "$HARNESS2"

bash "$HARNESS2" "$W2" > "$TMPBASE/mixed_check.out" 2>&1 || true
fail_line="$(grep 'verify-check v_fail:' "$TMPBASE/mixed_check.out" | grep 'sec-vars:claude' || true)"
[ -n "$fail_line" ] || _fail "sec-vars gap for claude was not reported at all:
$(cat "$TMPBASE/mixed_check.out")"
case "$fail_line" in
  *install-bins:*) _fail "sec-vars v_fail message leaked an unrelated install-bins entry: $fail_line" ;;
esac
_ok "sec-vars-only v_fail message does not leak install-bins entries (message filtering)"

W3="$TMPBASE/missing_engine"
mkdir -p "$W3/etc/engines" "$W3/templates"
python3 - "$REG" "$W3/etc/engines/engines.json" <<'PYEOF'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
data = json.load(open(src))
del data["engines"]["codex"]
json.dump(data, open(dst, "w"))
PYEOF
cp "$PY" "$W3/etc/engines/engines_registry.py"
cp "$v_install_bins" "$W3/install-bins.sh"
cp "$v_entrypoint" "$W3/entrypoint.sh"
cp "$v_sections" "$W3/templates/sections.sh"

HARNESS3="$TMPBASE/live_verify_harness_missing_engine.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  echo "INSTALL_DIR=\"\$1\""
  echo 'VN=0; VOK=0; VFAIL=0; VSKIP=0'
  echo 'v_t() { VN=$((VN + 1)); :; }'
  echo 'v_ok() { VOK=$((VOK + 1)); }'
  echo 'v_fail() { VFAIL=$((VFAIL + 1)); echo "verify-check v_fail: ${1:-}" >&2; }'
  echo 'v_skip() { VSKIP=$((VSKIP + 1)); }'
  awk '/^_cbox_verify_engines_registry\(\) \{/,/^}$/' "$v_cbox"
  echo '_cbox_verify_engines_registry'
} > "$HARNESS3"

bash "$HARNESS3" "$W3" > "$TMPBASE/missing_engine_check.out" 2>&1 || true
grep -qE 'verify-check v_fail:.*entrypoint-arm:codex' "$TMPBASE/missing_engine_check.out" \
  || _fail "deleting codex from engines.json did not trigger a v_fail for the missing registry entry:
$(cat "$TMPBASE/missing_engine_check.out")"
_ok "engine armed in entrypoint/install-bins but absent from registry is flagged (reverse cross-file check)"

CLAUDE_PREASSIGN="$(python3 "$PY" get "$REG" claude preassign_id)"
[ "$CLAUDE_PREASSIGN" = true ] || _fail "claude preassign_id should be true, got $CLAUDE_PREASSIGN"
_ok "claude preassign_id == true"

CLAUDE_RESUME="$(python3 "$PY" get "$REG" claude resume_argv)"
[ "$CLAUDE_RESUME" = "--resume {id}" ] || _fail "claude resume_argv mismatch: $CLAUDE_RESUME"
_ok "claude resume_argv == '--resume {id}'"

CLAUDE_SEED="$(python3 "$PY" get "$REG" claude seed_channel)"
[ "$CLAUDE_SEED" = "sessionstart-hook" ] || _fail "claude seed_channel mismatch: $CLAUDE_SEED"
_ok "claude seed_channel == sessionstart-hook"

CLAUDE_HIST="$(python3 "$PY" get "$REG" claude history_read)"
[ "$CLAUDE_HIST" = "claude-jsonl" ] || _fail "claude history_read mismatch: $CLAUDE_HIST"
_ok "claude history_read == claude-jsonl"

for eng in codex hermes; do
  v="$(python3 "$PY" get "$REG" "$eng" preassign_id)"
  [ "$v" = false ] || _fail "$eng preassign_id should be false, got $v"
done
[ "$(python3 "$PY" get "$REG" codex resume_argv)" = "resume {id}" ] || _fail "codex resume argv mismatch"
[ "$(python3 "$PY" get "$REG" codex seed_channel)" = sessionstart-hook ] || _fail "codex seed channel mismatch"
[ "$(python3 "$PY" get "$REG" codex history_read)" = codex-jsonl ] || _fail "codex history reader mismatch"
[ "$(python3 "$PY" get "$REG" hermes resume_argv)" = "--resume {id}" ] || _fail "hermes resume argv mismatch"
[ "$(python3 "$PY" get "$REG" hermes seed_channel)" = ephemeral-system-prompt ] || _fail "hermes seed channel mismatch"
[ "$(python3 "$PY" get "$REG" hermes history_read)" = hermes-sqlite ] || _fail "hermes history reader mismatch"
_ok "all engines publish resume, seed, and history capabilities"

cat > "$W/optional_fields_absent.json" <<'EOF'
{"schema": 1, "engines": {"claude": {"bin": "claude", "install": "bins-volume", "probe": {"kind": "exe-stamp", "stamp": "x", "infra_filter_argv1": []}, "version_vars": ["V"], "enabled_var": null, "login": "none"}}}
EOF
python3 "$PY" validate "$W/optional_fields_absent.json" >/dev/null 2>&1 \
  || _fail "registry entry without the optional capability fields at all should still validate (backward compatible)"
_ok "engine entries with no capability fields at all still validate (fields are optional)"

cat > "$W/bad_preassign_type.json" <<'EOF'
{"schema": 1, "engines": {"claude": {"bin": "claude", "install": "bins-volume", "probe": {"kind": "exe-stamp", "stamp": "x", "infra_filter_argv1": []}, "version_vars": ["V"], "enabled_var": null, "login": "none", "preassign_id": "yes"}}}
EOF
if python3 "$PY" validate "$W/bad_preassign_type.json" >/dev/null 2>&1; then
  _fail "preassign_id as a string instead of a boolean was accepted"
fi
_ok "preassign_id wrong type (string instead of boolean) rejected"

cat > "$W/bad_seed_channel.json" <<'EOF'
{"schema": 1, "engines": {"claude": {"bin": "claude", "install": "bins-volume", "probe": {"kind": "exe-stamp", "stamp": "x", "infra_filter_argv1": []}, "version_vars": ["V"], "enabled_var": null, "login": "none", "seed_channel": "carrier-pigeon"}}}
EOF
if python3 "$PY" validate "$W/bad_seed_channel.json" >/dev/null 2>&1; then
  _fail "unrecognized seed_channel value was accepted"
fi
_ok "unrecognized seed_channel value rejected"

cat > "$W/bad_history_read.json" <<'EOF'
{"schema": 1, "engines": {"claude": {"bin": "claude", "install": "bins-volume", "probe": {"kind": "exe-stamp", "stamp": "x", "infra_filter_argv1": []}, "version_vars": ["V"], "enabled_var": null, "login": "none", "history_read": "codex-history"}}}
EOF
if python3 "$PY" validate "$W/bad_history_read.json" >/dev/null 2>&1; then
  _fail "unrecognized history_read value was accepted"
fi
_ok "unrecognized history_read value rejected"

cat > "$W/null_capability_fields.json" <<'EOF'
{"schema": 1, "engines": {"codex": {"bin": "codex", "install": "bins-volume", "probe": {"kind": "exe-stamp", "stamp": "x", "infra_filter_argv1": []}, "version_vars": ["V"], "enabled_var": null, "login": "none", "preassign_id": false, "resume_argv": null, "seed_channel": null, "history_read": null}}}
EOF
python3 "$PY" validate "$W/null_capability_fields.json" >/dev/null 2>&1 \
  || _fail "codex-style null capability fields (preassign_id false, rest null) should validate"
_ok "null capability fields (codex/hermes style in C1) validate"

HARNESS4="$TMPBASE/live_verify_harness_claude_caps.sh"
W4="$TMPBASE/claude_caps_missing"
mkdir -p "$W4/etc/engines" "$W4/templates"
python3 - "$REG" "$W4/etc/engines/engines.json" <<'PYEOF'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
data = json.load(open(src))
data["engines"]["claude"].pop("preassign_id", None)
data["engines"]["claude"].pop("resume_argv", None)
data["engines"]["claude"].pop("seed_channel", None)
data["engines"]["claude"].pop("history_read", None)
json.dump(data, open(dst, "w"))
PYEOF
cp "$PY" "$W4/etc/engines/engines_registry.py"
cp "$v_install_bins" "$W4/install-bins.sh"
cp "$v_entrypoint" "$W4/entrypoint.sh"
cp "$v_sections" "$W4/templates/sections.sh"

{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  echo "INSTALL_DIR=\"\$1\""
  echo 'VN=0; VOK=0; VFAIL=0; VSKIP=0'
  echo 'v_t() { VN=$((VN + 1)); :; }'
  echo 'v_ok() { VOK=$((VOK + 1)); }'
  echo 'v_fail() { VFAIL=$((VFAIL + 1)); echo "verify-check v_fail: ${1:-}" >&2; }'
  echo 'v_skip() { VSKIP=$((VSKIP + 1)); }'
  awk '/^_cbox_verify_engines_registry\(\) \{/,/^}$/' "$v_cbox"
  echo '_cbox_verify_engines_registry'
} > "$HARNESS4"

bash "$HARNESS4" "$W4" > "$TMPBASE/claude_caps_missing_check.out" 2>&1 || true
grep -qE 'verify-check v_fail:.*shared-session capability fields' "$TMPBASE/claude_caps_missing_check.out" \
  || _fail "verify does not flag claude missing its session capability fields:
$(cat "$TMPBASE/claude_caps_missing_check.out")"
_ok "verify asserts shared-session capability fields are populated"

echo "PASS: all engines_registry checks"
