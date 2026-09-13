#!/usr/bin/env bash
set -euo pipefail

REAL_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() { echo "FAIL: $1" >&2; exit 1; }
_ok() { echo "ok: $1"; }

_extract_fn() {
  awk -v fn="$2" '$0 == fn"() {" , $0 == "}"' "$1"
}

unset CBOX_MODE CBOX_SESSION_SCOPE CBOX_BASE_DIGEST_TTL CBOX_NAME CBOX_WORKSPACES \
  CBOX_WORKDIR CBOX_TPL_SHA CBOX_HERMES CBOX_HERMES_EFFORT CBOX_OLLAMA_MODE \
  CBOX_LOCAL_MODEL_URL 2>/dev/null || true

INSTALL_DIR="$REAL_INSTALL_DIR"
. "$REAL_INSTALL_DIR/_common.sh"
. "$REAL_INSTALL_DIR/templates/sections.sh"
. "$REAL_INSTALL_DIR/templates/generators.sh"
. "$REAL_INSTALL_DIR/templates/conf_lib.sh"

_cbox_machine_scoped_vars() {
  printf 'CBOX_OLLAMA_MODE\nCBOX_LOCAL_MODEL_URL\n'
}
_cbox_flock() { return 0; }

GLOBAL="$TMPBASE/global"
HOME="$TMPBASE/home"
EFF="$TMPBASE/eff"
ROOT="$TMPBASE/ws"
mkdir -p "$GLOBAL/templates" "$HOME" "$EFF" "$ROOT"
cp "$REAL_INSTALL_DIR/_common.sh" "$GLOBAL/_common.sh"
cp "$REAL_INSTALL_DIR/templates/generators.sh" "$GLOBAL/templates/generators.sh"
INSTALL_DIR="$GLOBAL"

_reset_env() {
  local v
  for v in $(compgen -A variable | grep -E '^(CBOX_|OLLAMA_NUM_PARALLEL$)' || true); do
    unset "$v" 2>/dev/null || true
  done
}

_load_conf() {
  local f="$1"
  _reset_env
  if [ -f "$f" ]; then . "$f"; fi
  _cbox_reg_conf_defaults
}

_write_global_conf() {
  cat > "$GLOBAL/cbox.conf" <<'EOF'
CBOX_MODE=global
CBOX_HERMES_EFFORT=medium
CBOX_OLLAMA_MODE=off
CBOX_LOCAL_MODEL_URL=http://global:11434
EOF
}

_write_global_conf

rm -rf "$EFF"; mkdir -p "$EFF"
_load_conf "$GLOBAL/cbox.conf"
CBOX_MODE=isolated
CBOX_WORKSPACES="$ROOT"
CBOX_WORKDIR="$ROOT"
_cbox_layered_bootstrap_adopt "$EFF" "$ROOT" >/dev/null || _fail "bootstrap adopt on a brand-new project must not fail"
[ -f "$EFF/cbox.base" ] && _fail "bootstrap adopt must not create cbox.base when cbox.conf does not exist yet"
_cbox_reg_conf_write_whitelist "$EFF/cbox.base.new" 1
[ -f "$EFF/cbox.override" ] || : > "$EFF/cbox.override"
mv "$EFF/cbox.base.new" "$EFF/cbox.base"
_cbox_reg_conf_write_whitelist "$EFF/cbox.conf" 0
_cbox_reg_conf_write_whitelist "$TMPBASE/eff_scoped" 1
[ -s "$EFF/cbox.override" ] && _fail "a fresh derive must leave an empty override"
changed="$(_cbox_conf_changed_keys "$TMPBASE/eff_scoped" "$EFF/cbox.base" | wc -l | tr -d ' ')"
[ "$changed" = 0 ] || _fail "a fresh derive must leave effective == base (project-scoped keys), $changed differ"
_ok "fresh derive: effective == base, override empty"

rm -rf "$EFF"; mkdir -p "$EFF"
_load_conf "$GLOBAL/cbox.conf"
_cbox_reg_conf_write_whitelist "$EFF/cbox.base" 1
_cbox_override_set "$EFF" CBOX_HERMES_EFFORT '"xhigh"'
_cbox_reg_conf_write_whitelist "$EFF/cbox.base.new" 1
_cbox_layered_merge "$EFF"
grep -q '^CBOX_HERMES_EFFORT=' "$EFF/cbox.override" || _fail "KEEP: override for an unmoved global key must survive the merge"
[ -f "$EFF/override.dropped.log" ] && _fail "KEEP: nothing should be dropped when the global value did not move"
_ok "merge: KEEP when the global value behind an override did not move"

rm -rf "$EFF"; mkdir -p "$EFF"
_load_conf "$GLOBAL/cbox.conf"
_cbox_reg_conf_write_whitelist "$EFF/cbox.base" 1
_cbox_override_set "$EFF" CBOX_HERMES_EFFORT '"xhigh"'
_load_conf "$GLOBAL/cbox.conf"
CBOX_HERMES_EFFORT=low
_cbox_reg_conf_write_whitelist "$EFF/cbox.base.new" 1
merge_err="$(_cbox_layered_merge "$EFF" 2>&1 >/dev/null)"
if grep -q '^CBOX_HERMES_EFFORT=' "$EFF/cbox.override" 2>/dev/null; then
  _fail "DROP: override for a moved global key must not survive the merge"
fi
[ -f "$EFF/override.dropped.log" ] || _fail "DROP: dropped.log must be written"
grep -q '^CBOX_HERMES_EFFORT ' "$EFF/override.dropped.log" || _fail "DROP: dropped.log must name the dropped key"
case "$merge_err" in
  *"dropping project override for CBOX_HERMES_EFFORT"*) ;;
  *) _fail "DROP: merge must report the drop, got: $merge_err" ;;
esac
_ok "merge: DROP + report + dropped.log when the global value behind an override moved"

rm -rf "$EFF"; mkdir -p "$EFF"
_load_conf "$GLOBAL/cbox.conf"
_cbox_reg_conf_write_whitelist "$EFF/cbox.base" 1
_cbox_override_set "$EFF" CBOX_HERMES_EFFORT '"xhigh"'
cp "$EFF/cbox.override" "$TMPBASE/override.before"
_load_conf "$GLOBAL/cbox.conf"
CBOX_OLLAMA_MODE=on
_cbox_reg_conf_write_whitelist "$EFF/cbox.base.new" 1
_cbox_layered_merge "$EFF"
diff -q "$TMPBASE/override.before" "$EFF/cbox.override" >/dev/null || _fail "a change to a non-overridden key must not touch the override file"
grep -q '^CBOX_HERMES_EFFORT=' "$EFF/cbox.override" || _fail "an unrelated global move must not drop an untouched override"
_ok "merge: a global change to a non-overridden key flows through, override untouched"

rm -rf "$EFF"; mkdir -p "$EFF"
_load_conf "$GLOBAL/cbox.conf"
_cbox_reg_conf_write_whitelist "$EFF/cbox.base" 1
_cbox_override_set "$EFF" CBOX_HERMES_EFFORT '"xhigh"'
[ -s "$EFF/cbox.override" ] || _fail "setup: override must be non-empty before reset"
rm -f "$EFF/cbox.override"
[ -f "$EFF/cbox.override" ] && _fail "reset must remove cbox.override"
keys="$(_cbox_override_keys "$EFF" | wc -l | tr -d ' ')"
[ "$keys" = 0 ] || _fail "reset: no override keys must remain"
_ok "reset: cbox.override removed, no keys remain"

rm -rf "$EFF"; mkdir -p "$EFF"
cat > "$EFF/cbox.conf" <<EOF
CBOX_MODE=isolated
CBOX_WORKSPACES=$ROOT
CBOX_WORKDIR=$ROOT
CBOX_NAME=cbox
CBOX_HERMES_EFFORT=xhigh
CBOX_OLLAMA_MODE=on
CBOX_TPL_SHA=$(printf 'placeholder' | _cbox_sha256)
EOF
_cbox_manifest_write "$EFF" "$ROOT" "$EFF/cbox.conf"
[ "$(_cbox_manifest_status "$EFF" "$ROOT")" = ok ] || _fail "setup: baseline manifest for the bootstrap scenario must read ok"
out="$(_cbox_layered_bootstrap_adopt "$EFF" "$ROOT")" || _fail "bootstrap adopt on a legacy conf with an ok manifest must not fail"
[ -f "$EFF/cbox.base" ] || _fail "bootstrap adopt must create cbox.base"
[ -f "$EFF/cbox.override" ] || _fail "bootstrap adopt must create cbox.override"
grep -q '^CBOX_HERMES_EFFORT=' "$EFF/cbox.override" || _fail "bootstrap adopt must adopt a legitimately-changed project key"
for k in CBOX_MODE CBOX_WORKSPACES CBOX_WORKDIR CBOX_NAME CBOX_TPL_SHA CBOX_OLLAMA_MODE; do
  grep -q "^${k}=" "$EFF/cbox.override" && _fail "bootstrap adopt must never turn $k into an override"
done
case "$out" in
  *"adopted 1 project overrides: CBOX_HERMES_EFFORT"*) ;;
  *) _fail "bootstrap adopt must report what it adopted, got: $out" ;;
esac
_ok "bootstrap adopt: excluded and machine keys never appear, legitimate diffs are adopted and reported"

[ "$(_cbox_manifest_status "$EFF" "$ROOT")" = ok ] \
  || _fail "manifest status must stay ok after base/override lines are added (anti-lockout)"
base_sha="$(_cbox_sha256 "$EFF/cbox.base")"
ovr_sha="$(_cbox_sha256 "$EFF/cbox.override")"
grep -q "^base=$base_sha$" "$EFF/manifest.sha256" || _fail "manifest must carry base=<sha of cbox.base>"
grep -q "^override=$ovr_sha$" "$EFF/manifest.sha256" || _fail "manifest must carry override=<sha of cbox.override>"
_ok "manifest: base=/override= lines present, status stays ok"

WRITE_FN="$(_extract_fn "$REAL_INSTALL_DIR/templates/generators.sh" _cbox_manifest_write)"
KEEP_FN="$(_extract_fn "$REAL_INSTALL_DIR/templates/generators.sh" _cbox_manifest_write_keep_generated)"
printf '%s\n' "$WRITE_FN" | grep -q "printf 'base=%s\\\\n'" || _fail "_cbox_manifest_write must emit base=<sha>"
printf '%s\n' "$WRITE_FN" | grep -q "printf 'override=%s\\\\n'" || _fail "_cbox_manifest_write must emit override=<sha>"
printf '%s\n' "$KEEP_FN" | grep -q "printf 'base=%s\\\\n'" || _fail "_cbox_manifest_write_keep_generated must emit base=<sha>"
printf '%s\n' "$KEEP_FN" | grep -q "printf 'override=%s\\\\n'" || _fail "_cbox_manifest_write_keep_generated must emit override=<sha>"
_ok "pin: both allowlist manifest writers emit base=/override="

rm -rf "$EFF"; mkdir -p "$EFF"
cat > "$EFF/cbox.conf" <<EOF
CBOX_MODE=isolated
CBOX_WORKSPACES=$ROOT
CBOX_WORKDIR=$ROOT
CBOX_HERMES_EFFORT=xhigh
EOF
_cbox_manifest_write "$EFF" "$ROOT" "$EFF/cbox.conf"
[ "$(_cbox_layered_status "$EFF")" = ok ] || _fail "setup: layered status must read ok before base/override exist"
_cbox_reg_conf_write_whitelist "$EFF/cbox.base" 1
: > "$EFF/cbox.override"
[ "$(_cbox_layered_status "$EFF")" = drifted ] \
  || _fail "[G8] cbox.base/cbox.override appearing outside cbox (no manifest lines) must read drifted"
_ok "[G8] base/override files without manifest lines are refused as drifted"

_cbox_manifest_write "$EFF" "$ROOT" "$EFF/cbox.conf"
[ "$(_cbox_layered_status "$EFF")" = ok ] || _fail "setup: layered status must read ok once the manifest carries base=/override="
echo tampered >> "$EFF/cbox.override"
[ "$(_cbox_layered_status "$EFF")" = drifted ] \
  || _fail "[G8] a cbox.override changed after the manifest was written must read drifted"
_ok "[G8] a cbox.override edited outside cbox after the manifest was written reads drifted"

rm -rf "$EFF"; mkdir -p "$EFF"
cat > "$EFF/cbox.conf" <<EOF
CBOX_MODE=isolated
CBOX_WORKSPACES=$ROOT
CBOX_WORKDIR=$ROOT
CBOX_HERMES_EFFORT=xhigh
EOF
_cbox_manifest_write "$EFF" "$ROOT" "$EFF/cbox.conf"
printf 'CBOX_HAND_EDITED=1\n' >> "$EFF/cbox.conf"
[ "$(_cbox_manifest_status "$EFF" "$ROOT")" = drifted ] || _fail "setup: hand-edited conf must read drifted"
if _cbox_layered_bootstrap_adopt "$EFF" "$ROOT" 2>/dev/null; then
  _fail "bootstrap adopt must refuse a drifted legacy conf"
fi
[ -f "$EFF/cbox.base" ] && _fail "a refused bootstrap must not create cbox.base"
_ok "bootstrap adopt: a drifted legacy conf is refused, no base is created"

rm -rf "$EFF"; mkdir -p "$EFF"
cat > "$EFF/cbox.conf" <<EOF
CBOX_MODE=isolated
CBOX_WORKSPACES=$ROOT
CBOX_WORKDIR=$ROOT
CBOX_HERMES_EFFORT=xhigh
EOF
_cbox_manifest_write "$EFF" "$ROOT" "$EFF/cbox.conf"
_cbox_layered_bootstrap_adopt "$EFF" "$ROOT" >/dev/null
base_sha1="$(_cbox_sha256 "$EFF/cbox.base")"
ovr_sha1="$(_cbox_sha256 "$EFF/cbox.override")"
_cbox_layered_bootstrap_adopt "$EFF" "$ROOT" >/dev/null
base_sha2="$(_cbox_sha256 "$EFF/cbox.base")"
ovr_sha2="$(_cbox_sha256 "$EFF/cbox.override")"
[ "$base_sha1" = "$base_sha2" ] || _fail "a second bootstrap adopt must not change cbox.base"
[ "$ovr_sha1" = "$ovr_sha2" ] || _fail "a second bootstrap adopt must not change cbox.override"
_ok "bootstrap adopt: a second call is a no-op"

rm -rf "$EFF"; mkdir -p "$EFF"
_cbox_layered_require_ok "$EFF" \
  || _fail "require_ok: a project with neither cbox.base nor cbox.override must pass through"
_ok "require_ok: no base/override on disk is a pass-through"

rm -rf "$EFF"; mkdir -p "$EFF"
printf 'CBOX_GPU="none"\n' > "$EFF/cbox.override"
[ -f "$EFF/cbox.base" ] && _fail "test setup: cbox.base must not exist for this case"
if _cbox_layered_require_ok "$EFF"; then
  _fail "[HIGH] a planted cbox.override with no cbox.base and no manifest lines must not read ok"
fi
_ok "[HIGH] require_ok refuses a planted cbox.override even when cbox.base is absent"

rm -rf "$EFF"; mkdir -p "$EFF"
cat > "$EFF/cbox.conf" <<EOF
CBOX_MODE=isolated
CBOX_WORKSPACES=$ROOT
CBOX_WORKDIR=$ROOT
CBOX_HERMES_EFFORT=xhigh
EOF
_cbox_manifest_write "$EFF" "$ROOT" "$EFF/cbox.conf"
_cbox_layered_bootstrap_adopt "$EFF" "$ROOT" >/dev/null
_cbox_layered_require_ok "$EFF" || _fail "require_ok: a freshly adopted base/override matching the manifest must read ok"
echo tampered >> "$EFF/cbox.override"
if _cbox_layered_require_ok "$EFF"; then
  _fail "require_ok: a cbox.override edited outside cbox must not read ok"
fi
_ok "require_ok: ok on a fresh adopt, refused once the override is tampered"

rm -rf "$EFF"; mkdir -p "$EFF"
cat > "$EFF/cbox.conf" <<EOF
CBOX_MODE=isolated
CBOX_WORKSPACES=$ROOT
CBOX_WORKDIR=$ROOT
CBOX_HERMES_EFFORT=xhigh
EOF
_cbox_manifest_write "$EFF" "$ROOT" "$EFF/cbox.conf"
printf 'do-not-touch-me\n' > "$EFF/cbox.override.target"
before_target="$(cat "$EFF/cbox.override.target")"
ln -s "$EFF/cbox.override.target" "$EFF/cbox.override"
_cbox_layered_bootstrap_adopt "$EFF" "$ROOT" >/dev/null 2>&1 || true
[ -h "$EFF/cbox.override" ] && _fail "[MEDIUM] bootstrap adopt must not leave cbox.override as a symlink"
after_target="$(cat "$EFF/cbox.override.target" 2>/dev/null || printf 'missing')"
[ "$before_target" = "$after_target" ] \
  || _fail "[MEDIUM] a symlinked cbox.override must not let bootstrap adopt truncate the link target"
_ok "[MEDIUM] a symlinked cbox.override is replaced, not followed and truncated"

rm -rf "$EFF"; mkdir -p "$EFF" "$ROOT"
printf 'do-not-touch-me\n' > "$TMPBASE/protected_target"
before_protected="$(cat "$TMPBASE/protected_target")"
ln -s "$TMPBASE/protected_target" "$EFF/override.dropped.log"
_cbox_reg_conf_write_whitelist "$EFF/cbox.base" 1
_cbox_override_set "$EFF" CBOX_HERMES_EFFORT '"xhigh"'
_load_conf "$GLOBAL/cbox.conf"
CBOX_HERMES_EFFORT=low
_cbox_reg_conf_write_whitelist "$EFF/cbox.base.new" 1
_cbox_layered_merge "$EFF" >/dev/null 2>&1 || true
after_protected="$(cat "$TMPBASE/protected_target")"
[ "$before_protected" = "$after_protected" ] \
  || _fail "[MEDIUM] a symlinked override.dropped.log must not let merge append into an arbitrary file"
_ok "[MEDIUM] a symlinked override.dropped.log is replaced, not followed and appended to"

WS_FN="$(_extract_fn "$REAL_INSTALL_DIR/templates/generators.sh" _cbox_check_workspace_overlap)"
eval "$WS_FN"
die() { echo "die: $*" >&2; exit 1; }
_cbox_realpath_m() { printf '%s' "$1"; }
_cbox_path_within() {
  case "$1" in
    "$2") return 0 ;;
    "$2"/*) return 0 ;;
  esac
  return 1
}
HOME="$TMPBASE/home"
if ( _cbox_check_workspace_overlap "$HOME/.config/cbox/projects/deadbeef" ) 2>/dev/null; then
  _fail "[MEDIUM] a workspace inside \$HOME/.config/cbox must be refused"
fi
if ( _cbox_check_workspace_overlap "$HOME/some/normal/project" ) 2>/dev/null; then :; else
  _fail "an ordinary workspace outside \$HOME/.config/cbox must still be accepted"
fi
_ok "[MEDIUM] _cbox_check_workspace_overlap refuses a workspace overlapping \$HOME/.config/cbox"

rm -rf "$EFF"; mkdir -p "$EFF"
_cbox_override_set "$EFF" CBOX_HERMES_EFFORT '"xhigh"'
_cbox_override_set "$EFF" CBOX_HERMES 'on'
_cbox_override_del "$EFF" CBOX_HERMES_EFFORT
grep -q '^CBOX_HERMES_EFFORT=' "$EFF/cbox.override" && _fail "override del must remove the targeted key"
grep -q '^CBOX_HERMES=on$' "$EFF/cbox.override" || _fail "override del must leave the other key untouched"
_ok "override del: removes only the targeted key, leaves the rest intact"

echo "--- drift recovery is reachable, not circular ---"

DIFF_FN="$(_extract_fn "$REAL_INSTALL_DIR/cbox" _cbox_config_diff)"
SET_FN="$(_extract_fn "$REAL_INSTALL_DIR/cbox" _cbox_config_set_isolated)"
UNSET_FN="$(_extract_fn "$REAL_INSTALL_DIR/cbox" _cbox_config_unset)"
[ -n "$DIFF_FN" ] && [ -n "$SET_FN" ] && [ -n "$UNSET_FN" ] \
  || _fail "drift recovery: cannot extract the config verbs"

printf '%s' "$DIFF_FN" | grep -q "_cbox_layered_require_ok" \
  || _fail "drift recovery: config diff must still notice a drifted layered state"
printf '%s' "$DIFF_FN" | awk '/_cbox_layered_require_ok/{f=1} f&&/return 1/{found=1} END{exit !found}' \
  && _fail "drift recovery: config diff is read-only and must WARN on drift, never refuse - refusing it leaves the owner unable to see what a reset would destroy"
_ok "drift recovery: config diff warns on a drifted layered state instead of refusing"

for _v in SET UNSET; do
  eval "_body=\"\$${_v}_FN\""
  printf '%s' "$_body" | grep -q "_cbox_layered_recovery_hint" \
    || _fail "drift recovery: the $_v refusal must point at the shared recovery hint"
  printf '%s' "$_body" | grep -q "fix with cbox config set\|fix with cbox config unset" \
    && _fail "drift recovery: the $_v refusal must not send the owner to another verb that the same gate blocks"
done
_ok "drift recovery: the write verbs point at a recovery path that is not blocked by the same gate"

echo "PASS: layered project config (base/override/merge/bootstrap/manifest)"
