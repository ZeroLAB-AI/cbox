#!/usr/bin/env bash
set -euo pipefail

REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

for _v in $(compgen -v CBOX_); do
  unset "$_v"
done
unset OLLAMA_NUM_PARALLEL _v

_fail() { echo "FAIL: $1" >&2; exit 1; }
_ok() { echo "ok: $1"; }

TB="$(cd "$TMPBASE" && pwd -P)"
HOME="$TB/home"
export HOME
FARM="$TB/install"
mkdir -p "$HOME/.config/cbox" "$HOME/.claude/hooks" "$HOME/.codex" "$FARM/bin"
for _f in _common.sh lib templates etc entrypoint.sh install-bins.sh; do
  ln -s "$REAL/$_f" "$FARM/$_f"
done
: > "$FARM/.dockerignore"
sed 's/^_cbox_config_in_container() {$/&\n  return 1/' "$REAL/cbox" > "$FARM/cbox"
chmod +x "$FARM/cbox"
grep -q '^  return 1$' "$FARM/cbox" || _fail "fixture: the host-path patch of cbox did not apply"
printf '#!/bin/sh\nexit 0\n' > "$FARM/bin/docker"
chmod +x "$FARM/bin/docker"
printf 'ubuntu:24.04|sha256:%064d|%s\n' 0 "$(date +%s)" > "$HOME/.config/cbox/base-digest.cache"
printf 'x\n' > "$HOME/.claude/hooks/session_scope_farm.py"

_mkrepo() {
  mkdir -p "$1"
  git -C "$1" init -q
  (cd "$1" && pwd -P)
}

ROOT="$(_mkrepo "$TB/work/proj")"
ROOT2="$(_mkrepo "$TB/work/proj2")"
X1="$(_mkrepo "$TB/work/x1")"
X2="$(_mkrepo "$TB/work/x2")"
GL1="$(_mkrepo "$TB/work/gl1")"
GL2="$(_mkrepo "$TB/work/gl2")"
PLAIN="$TB/work/plain"
mkdir -p "$PLAIN" "$ROOT/sub" "$X1/deep" "$TB/work/afile.d"
: > "$TB/work/afile"

_write_global() {
  local mode="${1:-global}" apt="${2:-curl}"
  {
    printf 'CBOX_MODE=%s\n' "$mode"
    printf 'CBOX_WORKSPACES=%q\n' "$GL1 $GL2"
    printf 'CBOX_WORKDIR=%s\n' "$GL1"
    printf 'CBOX_APT_EXTRA=%s\n' "$apt"
    printf 'CBOX_SSH_MODE=none\n'
    printf 'CBOX_VENV_MODE=none\n'
  } > "$FARM/cbox.conf"
}
_write_global global

RC=0
OUT="$TB/out"
ERR="$TB/err"
_cb() {
  local cwd="$1"
  shift
  RC=0
  ( cd "$cwd" && env -i HOME="$HOME" PATH="$FARM/bin:$PATH" CBOX_TUI=0 bash "$FARM/cbox" "$@" < /dev/null > "$OUT" 2> "$ERR" ) || RC=$?
}

_eff_for() {
  printf '%s/.config/cbox/projects/%s' "$HOME" "$(printf '%s' "$1" | sha256sum | cut -c1-12)"
}

_ws_line() {
  printf 'CBOX_WORKSPACES=%q' "$1"
}

_conf_ws() {
  local eff="$1"
  grep -m1 '^CBOX_WORKSPACES=' "$eff/cbox.conf" | tail -n1
}

_assert_ws() {
  local label="$1" eff="$2" want="$3"
  grep -qxF "$(_ws_line "$want")" "$eff/cbox.conf" || _fail "$label: effective conf holds '$(_conf_ws "$eff")', want '$want'"
}

_assert_override_ws() {
  local label="$1" eff="$2" want="$3"
  grep -qxF "$(_ws_line "$want")" "$eff/cbox.override" || _fail "$label: override holds '$(grep '^CBOX_WORKSPACES=' "$eff/cbox.override" || true)', want '$want'"
}

_assert_no_override_ws() {
  if grep -q '^CBOX_WORKSPACES=' "$1/cbox.override" 2>/dev/null; then
    _fail "$2: the override must not hold CBOX_WORKSPACES, got: $(cat "$1/cbox.override")"
  fi
}

_assert_mounts() {
  local label="$1" eff="$2"
  shift 2
  local expect="" w line got
  for w in "$@"; do
    expect="$expect$w"$'\n'
  done
  got="$(grep -E '^      - [^ ]+:[^ ]+:rw$' "$eff/docker-compose.yml" | sed -E 's/^      - ([^:]+):.*/\1/' | grep -F "$TB/work/" || true)"
  [ "$got"$'\n' = "$expect" ] || _fail "$label: compose mounts under the work tree are [$(printf '%s' "$got" | tr '\n' ' ')], want [$(printf '%s' "$expect" | tr '\n' ' ')]"
  local ro
  ro="$(grep -E '^        source: ' "$eff/docker-compose.readonly.yml" | sed -E 's/^        source: //')"$'\n'
  [ "$ro" = "$expect" ] || _fail "$label: read-only compose mounts are [$(printf '%s' "$ro" | tr '\n' ' ')], want [$(printf '%s' "$expect" | tr '\n' ' ')]"
  local roots
  roots="$(grep -m1 'CODEX_GUARD_EXTRA_ROOTS=' "$eff/docker-compose.yml" | sed -E 's/^.*CODEX_GUARD_EXTRA_ROOTS=//')"
  [ "$roots" = "$(printf '%s' "${expect%$'\n'}" | tr '\n' ':')" ] || _fail "$label: guard roots are '$roots'"
}

echo "--- derive: root only, the global list never copied ---"

_cb "$ROOT" setup --local "$ROOT" --from-global
[ "$RC" = 0 ] || _fail "derive: rc=$RC: $(cat "$ERR")"
EFF="$(_eff_for "$ROOT")"
_assert_ws "derive" "$EFF" "$ROOT"
grep -qx "CBOX_WORKDIR=$ROOT" "$EFF/cbox.conf" || _fail "derive: the workdir must be the root"
_assert_no_override_ws "$EFF" "derive"
if grep -rq "$GL1\|$GL2" "$EFF/cbox.conf" "$EFF/cbox.base" "$EFF/docker-compose.yml" "$EFF/docker-compose.readonly.yml"; then
  _fail "derive: the global workspaces leaked into the isolated project"
fi
_assert_mounts "derive" "$EFF" "$ROOT"
_ok "derive from global: the project mounts its root alone, the global list never reaches conf, base or compose"

echo "--- config set CBOX_WORKSPACES inside a project ---"

_cb "$ROOT" config set CBOX_WORKSPACES="$X1 $X2"
[ "$RC" = 0 ] || _fail "set extras: rc=$RC: $(cat "$ERR")"
_assert_ws "set extras (root omitted)" "$EFF" "$ROOT $X1 $X2"
_assert_override_ws "set extras (root omitted)" "$EFF" "$ROOT $X1 $X2"
_assert_mounts "set extras" "$EFF" "$ROOT" "$X1" "$X2"
grep -qx 'workspaces=recreate' "$EFF/pending.apply" || _fail "set extras: pending.apply lacks workspaces=recreate"
_cb "$ROOT" config get CBOX_WORKSPACES
[ "$(cat "$OUT")" = "CBOX_WORKSPACES=$ROOT $X1 $X2" ] || _fail "get: $(cat "$OUT")"
_cb "$ROOT" config diff
grep -q "^CBOX_WORKSPACES=.*project-owned" "$OUT" || _fail "diff: the workspaces override must be reported as project-owned: $(cat "$OUT")"
if grep -q "global-now" "$OUT"; then
  _fail "diff: a project-owned key has no global counterpart and must not show a global-now value: $(cat "$OUT")"
fi
_ok "config set CBOX_WORKSPACES stores root-first extras in cbox.override, renders every mount, stages the apply class, diff marks it project-owned"

_cb "$ROOT" config set CBOX_WORKSPACES="$X2 $ROOT $X1 $X2 $X1"
[ "$RC" = 0 ] || _fail "set with root and duplicates: rc=$RC: $(cat "$ERR")"
_assert_ws "set with root, reordered, duplicated" "$EFF" "$ROOT $X2 $X1"
_assert_mounts "set with root" "$EFF" "$ROOT" "$X2" "$X1"
_ok "the root is accepted anywhere in the value, stored first, duplicates folded"

ln -s "$X1" "$TB/work/x1link"
_cb "$ROOT" config set CBOX_WORKSPACES="$TB/work/x1link"
[ "$RC" = 0 ] || _fail "symlinked extra: rc=$RC: $(cat "$ERR")"
_assert_ws "symlinked extra" "$EFF" "$ROOT $X1"
_ok "an extra given through a symlink is stored by its real path"

_cb "$ROOT" config set CBOX_WORKSPACES="$X1 $X2"
cp "$EFF/cbox.conf" "$TB/conf.before"
cp "$EFF/cbox.override" "$TB/override.before"
_expect_bad() {
  local label="$1" value="$2" want="$3"
  _cb "$ROOT" config set CBOX_WORKSPACES="$value"
  [ "$RC" != 0 ] || _fail "validation $label: expected failure"
  grep -qi "$want" "$ERR" || _fail "validation $label: message lacks '$want': $(cat "$ERR")"
  cmp -s "$EFF/cbox.conf" "$TB/conf.before" || _fail "validation $label: the effective conf changed"
  cmp -s "$EFF/cbox.override" "$TB/override.before" || _fail "validation $label: the override changed"
}
_expect_bad "relative" "relative/dir" "absolute"
_expect_bad "missing directory" "$TB/work/nonexistent" "does not exist"
_expect_bad "a file" "$TB/work/afile" "not a directory"
_expect_bad "colon" "$X1:/etc" "colon"
_expect_bad "dollar" "$X1/\$HOME" "dollar"
_expect_bad "inside the root" "$ROOT/sub" "overlap"
_expect_bad "containing the root" "$TB/work" "overlap"
_expect_bad "extras overlapping each other" "$X1 $X1/deep" "overlap"
_expect_bad "cbox config root" "$HOME/.config/cbox" "conflicts\|install/config tree"
_expect_bad "cbox install dir" "$FARM" "conflicts\|install/config tree"
_ok "invalid values are refused before anything is written (relative, missing, file, colon, dollar, overlaps, reserved paths); conf and override stay byte-identical"

_cb "$ROOT" config set CBOX_MODE=global
[ "$RC" != 0 ] || _fail "pinned: CBOX_MODE must not be settable in a project"
grep -q 'pinned' "$ERR" || _fail "pinned: message lacks the word pinned: $(cat "$ERR")"
_cb "$ROOT" config set CBOX_WORKDIR="$X1"
[ "$RC" != 0 ] || _fail "pinned: CBOX_WORKDIR must not be settable in a project"
grep -qx "CBOX_WORKDIR=$ROOT" "$EFF/cbox.conf" || _fail "pinned: the workdir changed"
_ok "pinned keys (mode, workdir) are refused in a project and stay as derived"

echo "--- extras survive every derive path ---"

_cb "$ROOT" setup --local "$ROOT" --from-global
[ "$RC" = 0 ] || _fail "re-derive: rc=$RC: $(cat "$ERR")"
_assert_ws "--from-global re-derive" "$EFF" "$ROOT $X1 $X2"
_assert_override_ws "--from-global re-derive" "$EFF" "$ROOT $X1 $X2"
_assert_mounts "--from-global re-derive" "$EFF" "$ROOT" "$X1" "$X2"
grep -qx "CBOX_WORKSPACES=$ROOT" "$EFF/cbox.base" || _fail "re-derive: the base must hold the root alone"
if grep -rq "$GL1\|$GL2" "$EFF/cbox.conf" "$EFF/cbox.base" "$EFF/cbox.override" "$EFF/docker-compose.yml"; then
  _fail "re-derive: the global list leaked"
fi
_ok "setup --local --from-global keeps the project's extras and still never copies the global list"

_write_global global wget
_cb "$ROOT" setup --local "$ROOT" --from-global
[ "$RC" = 0 ] || _fail "re-derive after a global change: rc=$RC: $(cat "$ERR")"
grep -qx 'CBOX_APT_EXTRA=wget' "$EFF/cbox.conf" || _fail "a global change must still flow into the project on a re-derive"
_assert_ws "re-derive after a global change" "$EFF" "$ROOT $X1 $X2"
_write_global global
_ok "a global change flows in on re-derive while the project's workspaces stay"

sed -i 's/^generators=.*/generators=deadbeef/' "$EFF/manifest.sha256"
_cb "$ROOT" config set CBOX_GPU=0
[ "$RC" = 0 ] || _fail "template re-bless via config set: rc=$RC: $(cat "$ERR")"
_assert_ws "template re-bless" "$EFF" "$ROOT $X1 $X2"
_assert_override_ws "template re-bless" "$EFF" "$ROOT $X1 $X2"
_ok "a template re-bless keeps the project's extras"

mv "$EFF/cbox.base" "$TB/removed.base"
mv "$EFF/cbox.override" "$TB/removed.override"
sed -i '/^base=/d;/^override=/d' "$EFF/manifest.sha256"
printf 'CBOX_WORKSPACES=%q\n' "$ROOT $X1 $X2" > "$TB/legacy.ws"
sed -i "s#^CBOX_WORKSPACES=.*#$(cat "$TB/legacy.ws" | sed 's/[#&\]/\\&/g')#" "$EFF/cbox.conf"
conf_sha="$(sha256sum "$EFF/cbox.conf" | cut -d' ' -f1)"
sed -i "s/^conf=.*/conf=$conf_sha/" "$EFF/manifest.sha256"
_cb "$ROOT" config set CBOX_GPU=0
[ "$RC" = 0 ] || _fail "bootstrap adopt of a project holding extras: rc=$RC: $(cat "$ERR")"
_assert_override_ws "bootstrap adopt" "$EFF" "$ROOT $X1 $X2"
_assert_ws "bootstrap adopt" "$EFF" "$ROOT $X1 $X2"
_ok "bootstrap adopt (a project with a conf but no base yet) turns the extras into a project-owned override"

_cb "$ROOT" setup --local "$ROOT" --from-global --reset
[ "$RC" = 0 ] || _fail "--reset: rc=$RC: $(cat "$ERR")"
_assert_ws "--reset" "$EFF" "$ROOT"
_assert_no_override_ws "$EFF" "--reset"
_assert_mounts "--reset" "$EFF" "$ROOT"
_ok "--reset drops every project override including the extra workspaces, by design"

echo "--- config unset ---"

_cb "$ROOT" config unset CBOX_WORKSPACES
[ "$RC" = 0 ] || _fail "unset without extras: rc=$RC: $(cat "$ERR")"
grep -q 'not a project override' "$OUT" || _fail "unset without extras: expected the nothing-to-unset note: $(cat "$OUT")"
_cb "$ROOT" config set CBOX_WORKSPACES="$X1"
_cb "$ROOT" config unset CBOX_WORKSPACES
[ "$RC" = 0 ] || _fail "unset: rc=$RC: $(cat "$ERR")"
_assert_ws "unset" "$EFF" "$ROOT"
_assert_no_override_ws "$EFF" "unset"
_assert_mounts "unset" "$EFF" "$ROOT"
_cb "$ROOT" config set CBOX_WORKSPACES="$X1"
_cb "$ROOT" config set CBOX_WORKSPACES="$ROOT"
[ "$RC" = 0 ] || _fail "set to the root alone: rc=$RC: $(cat "$ERR")"
_assert_ws "set to root alone" "$EFF" "$ROOT"
_assert_no_override_ws "$EFF" "set to root alone"
_cb "$ROOT" config set CBOX_WORKSPACES="$X1"
_cb "$ROOT" config set CBOX_WORKSPACES=
[ "$RC" = 0 ] || _fail "set empty: rc=$RC: $(cat "$ERR")"
_assert_ws "set empty" "$EFF" "$ROOT"
_assert_no_override_ws "$EFF" "set empty"
_ok "unset, setting the root alone and setting an empty value all return the project to its root and drop the override key"

echo "--- a second project and the global scope stay independent ---"

_cb "$ROOT2" setup --local "$ROOT2" --from-global
[ "$RC" = 0 ] || _fail "second project: rc=$RC: $(cat "$ERR")"
EFF2="$(_eff_for "$ROOT2")"
_cb "$ROOT" config set CBOX_WORKSPACES="$X1"
_assert_ws "second project" "$EFF2" "$ROOT2"
_cb "$ROOT2" config set CBOX_WORKSPACES="$X2"
_assert_ws "first project untouched" "$EFF" "$ROOT $X1"
_assert_ws "second project" "$EFF2" "$ROOT2 $X2"
grep -qxF "$(_ws_line "$GL1 $GL2")" "$FARM/cbox.conf" || _fail "the global workspaces list changed"
_ok "each project keeps its own extras and the global list is untouched"

echo "--- config --global ---"

_cb "$HOME" config --global get CBOX_WORKSPACES
[ "$RC" = 0 ] || _fail "--global get from home: rc=$RC: $(cat "$ERR")"
[ "$(cat "$OUT")" = "CBOX_WORKSPACES=$GL1 $GL2" ] || _fail "--global get from home: $(cat "$OUT")"
_cb "$ROOT" config --global get CBOX_WORKSPACES
[ "$(cat "$OUT")" = "CBOX_WORKSPACES=$GL1 $GL2" ] || _fail "--global get inside a project must read the global conf, got: $(cat "$OUT")"
_cb "$PLAIN" config --global get CBOX_WORKSPACES
[ "$(cat "$OUT")" = "CBOX_WORKSPACES=$GL1 $GL2" ] || _fail "--global get from a non-project dir: $(cat "$OUT")"
_cb "$ROOT" config get CBOX_WORKSPACES
[ "$(cat "$OUT")" = "CBOX_WORKSPACES=$ROOT $X1" ] || _fail "plain get inside a project must read the project, got: $(cat "$OUT")"
_ok "config --global get reads the global conf from home, a project and a non-project directory; plain get still reads the project"

_cb "$HOME" config --global set CBOX_WORKSPACES="$GL1 $GL2 $X2"
[ "$RC" = 0 ] || _fail "--global set from home: rc=$RC: $(cat "$ERR")"
grep -qxF "$(_ws_line "$GL1 $GL2 $X2")" "$FARM/cbox.conf" || _fail "--global set from home did not write the global conf"
_assert_ws "--global set leaves the project alone" "$EFF" "$ROOT $X1"
_cb "$ROOT" config --global set CBOX_WORKSPACES="$GL1 $GL2"
[ "$RC" = 0 ] || _fail "--global set inside a project: rc=$RC: $(cat "$ERR")"
grep -qxF "$(_ws_line "$GL1 $GL2")" "$FARM/cbox.conf" || _fail "--global set inside a project did not write the global conf"
_assert_ws "--global set inside a project leaves the project alone" "$EFF" "$ROOT $X1"
_cb "$HOME" config --global set CBOX_WORKSPACES="relative"
[ "$RC" != 0 ] || _fail "--global set must validate like every global edit"
_cb "$HOME" config --global set CBOX_NOPE=1
[ "$RC" != 0 ] || _fail "--global set must refuse a key outside the whitelist"
_cb "$ROOT" config --global unset CBOX_APT_EXTRA
[ "$RC" != 0 ] || _fail "--global unset has nothing to remove in the global conf and must say so"
grep -q 'config --global set' "$ERR" || _fail "--global unset: the message must point to config --global set: $(cat "$ERR")"
_cb "$ROOT" config --global diff
[ "$RC" != 0 ] || _fail "--global diff has nothing to diff"
_cb "$HOME" config --global pending
[ "$RC" = 0 ] || _fail "--global pending: rc=$RC: $(cat "$ERR")"
_cb "$HOME" config --global bogus
[ "$RC" != 0 ] || _fail "--global with an unknown verb must fail"
grep -q -- '--global' "$ERR" || _fail "the usage line must mention --global: $(cat "$ERR")"
_ok "config --global set validates and applies like every global edit, from home and from a project; unset/diff explain themselves"

_write_global isolated
_cb "$HOME" config set CBOX_APT_EXTRA=x
[ "$RC" != 0 ] || _fail "with an isolated global profile, plain config set from home has no target"
grep -q 'config --global set' "$ERR" || _fail "from home the error must point to config --global: $(cat "$ERR")"
_cb "$PLAIN" config set CBOX_APT_EXTRA=x
[ "$RC" != 0 ] || _fail "with an isolated global profile, plain config set from a non-project dir has no target"
grep -q 'config --global set' "$ERR" || _fail "from a non-project dir the error must point to config --global: $(cat "$ERR")"
_cb "$HOME" config --global set CBOX_APT_EXTRA=viaglobal
[ "$RC" = 0 ] || _fail "--global set must work with an isolated global profile: rc=$RC: $(cat "$ERR")"
grep -qx 'CBOX_APT_EXTRA=viaglobal' "$FARM/cbox.conf" || _fail "--global set did not reach the global conf"
_write_global global
_ok "with an isolated global profile, the errors from home and a non-project directory name config --global, which reaches the global conf"

echo "--- migration: projects written by the previous release keep working ---"

SNAP="$REAL/lib/fixtures/legacy_layered.snapshot"
[ -f "$SNAP" ] || _fail "fixture: $SNAP missing"

_legacy_project() {
  local flavor="$1" root="$2" eff f
  eff="$(_eff_for "$root")"
  mkdir -p "$eff"
  for f in cbox.conf cbox.base cbox.override; do
    awk -v want="=== $flavor $f ===" '
      /^=== / { on = ($0 == want); next }
      on { print }
    ' "$SNAP" | sed -e "s#@GWS2@#$GL1#g" -e "s#@GEX1@#$GL2#g" -e "s#@ROOT@#$root#g" -e "s#@HOME@#$HOME#g" -e "s#@INST@#$FARM#g" > "$eff/$f"
    [ -s "$eff/$f" ] || [ "$f" = cbox.override ] || _fail "fixture: $flavor $f is empty"
  done
  printf '%s\n' "$root" > "$eff/workspace"
  local tpl
  tpl="$(cat "$REAL/_common.sh" "$REAL/templates/generators.sh" | sha256sum | cut -d' ' -f1)"
  {
    printf 'schema=1\n'
    printf 'workspace=%s\n' "$root"
    printf 'conf=%s\n' "$(sha256sum "$eff/cbox.conf" | cut -d' ' -f1)"
    printf 'generators=%s\n' "${2:-$tpl}"
    printf 'base=%s\n' "$(sha256sum "$eff/cbox.base" | cut -d' ' -f1)"
    printf 'override=%s\n' "$(sha256sum "$eff/cbox.override" | cut -d' ' -f1)"
  } > "$eff/manifest.sha256"
  printf '%s' "$eff"
}

_assert_not_locked() {
  local label="$1"
  if grep -q 'drifted outside cbox\|edited outside cbox\|refusing' "$ERR"; then
    _fail "$label: a legacy project was refused: $(cat "$ERR")"
  fi
}

_write_global global

n=0
for flavor in derive override adopt; do
  for tplstate in current stale; do
    n=$((n + 1))
    LROOT="$(_mkrepo "$TB/legacy/$flavor-$tplstate")"
    gen=""
    [ "$tplstate" = stale ] && gen="deadbeefdeadbeef"
    LEFF="$(_legacy_project "$flavor" "$LROOT" "$gen")"
    _cb "$LROOT" config diff
    [ "$RC" = 0 ] || _fail "legacy $flavor/$tplstate: config diff rc=$RC: $(cat "$ERR")"
    _assert_not_locked "legacy $flavor/$tplstate diff"
    _cb "$LROOT" config set CBOX_WORKSPACES="$X1"
    [ "$RC" = 0 ] || _fail "legacy $flavor/$tplstate: config set workspaces rc=$RC: $(cat "$ERR")"
    _assert_not_locked "legacy $flavor/$tplstate set"
    _assert_ws "legacy $flavor/$tplstate" "$LEFF" "$LROOT $X1"
    _assert_override_ws "legacy $flavor/$tplstate" "$LEFF" "$LROOT $X1"
    case "$flavor" in
      override|adopt) grep -qx 'CBOX_APT_EXTRA=wget' "$LEFF/cbox.override" || _fail "legacy $flavor/$tplstate: the project's own override was lost" ;;
    esac
    _cb "$LROOT" setup --local "$LROOT" --from-global
    [ "$RC" = 0 ] || _fail "legacy $flavor/$tplstate: re-derive rc=$RC: $(cat "$ERR")"
    _assert_not_locked "legacy $flavor/$tplstate re-derive"
    _assert_ws "legacy $flavor/$tplstate re-derive" "$LEFF" "$LROOT $X1"
    case "$flavor" in
      override|adopt) grep -qx 'CBOX_APT_EXTRA=wget' "$LEFF/cbox.conf" || _fail "legacy $flavor/$tplstate: the project's own setting was lost on re-derive" ;;
    esac
    if grep -rq "$GL1\|$GL2" "$LEFF/cbox.conf" "$LEFF/cbox.override" "$LEFF/docker-compose.yml"; then
      _fail "legacy $flavor/$tplstate: the global list leaked into the project"
    fi
    if [ "$flavor" = adopt ]; then
      _cb "$LROOT" config unset CBOX_WORKSPACES
      [ "$RC" = 0 ] || _fail "legacy $flavor/$tplstate: unset rc=$RC: $(cat "$ERR")"
      _assert_ws "legacy $flavor/$tplstate unset" "$LEFF" "$LROOT"
    fi
  done
done
_ok "projects written by the previous release (fresh derive, derive plus override, adopted base; current and stale template sha) diff, accept a workspaces edit, re-derive (and unset, for the adopted ones) without any drifted/refused message ($n projects)"

LROOT="$(_mkrepo "$TB/legacy/plainset")"
LEFF="$(_legacy_project override "$LROOT")"
_cb "$LROOT" config set CBOX_APT_EXTRA=curl2
[ "$RC" = 0 ] || _fail "legacy project: an ordinary config set rc=$RC: $(cat "$ERR")"
_assert_not_locked "legacy ordinary set"
grep -qx 'CBOX_APT_EXTRA=curl2' "$LEFF/cbox.override" || _fail "legacy project: the ordinary override was not written"
_ok "an ordinary config set on a legacy project behaves as before"

echo "--- wiring ---"

SETUP_MAIN="$(awk '/^_cbox_setup_main\(\) \{/,/^}$/' "$REAL/lib/cbox-setup.sh")"
[ -n "$SETUP_MAIN" ] || _fail "wiring: cannot extract _cbox_setup_main"
REFUSAL="$(awk '/^_cbox_local_update_refusal\(\) \{/,/^}$/' "$REAL/lib/cbox-setup.sh")"
printf '%s\n' "$REFUSAL" | grep -q 'workspaces' && _fail "wiring: setup update workspaces --local must no longer be refused"
printf '%s\n' "$REFUSAL" | grep -q 'mode)' || _fail "wiring: mode must still be refused with --local"
_ok "wiring: only mode is refused with --local; workspaces is allowed"

GEN_BLOCK="$(awk '/^_gen_effective\(\) \{/,/^}$/' "$REAL/cbox")"
printf '%s\n' "$GEN_BLOCK" | grep -q 'gen_compose_readonly_isolated_into "\$eff/docker-compose.readonly.yml" "\$root"' \
  || _fail "wiring: _gen_effective must render the read-only compose through gen_compose_readonly_isolated_into"
printf '%s\n' "$GEN_BLOCK" | grep -q 'gen_compose_readonly_into' && _fail "wiring: _gen_effective must not use the global read-only renderer"
_ok "wiring: the isolated read-only compose goes through gen_compose_readonly_isolated_into"

BRIDGE_BLOCK="$(awk '/^_container_exec_bridge_start\(\) \{/,/^}$/' "$REAL/cbox")"
printf '%s\n' "$BRIDGE_BLOCK" | grep -q '_cbox_project_extra_workspaces' \
  || _fail "wiring: the exec bridge workspace guard must include the project's extra workspaces in isolated mode"
_ok "wiring: the exec bridge guard roots include the project's extras"

GLOBAL_SCOPE_BLOCK="$(awk '/^_cbox_root_in_global_scope\(\) \{/,/^}$/' "$REAL/cbox")"
printf '%s\n' "$GLOBAL_SCOPE_BLOCK" | grep -q '_cbox_global_workspaces' \
  || _fail "wiring: _cbox_root_in_global_scope must read the global list, not the ambient CBOX_WORKSPACES"
_ok "wiring: the global-scope test reads the global list"

PROFILE_BLOCK="$(awk '/^_run_isolated_profile\(\) \{/,/^}$/' "$REAL/cbox")"
printf '%s\n' "$PROFILE_BLOCK" | grep -q '\. "\$eff/cbox.conf"' \
  || _fail "wiring: a profile container must load its scope's cbox.conf (same workspaces as the scope)"
printf '%s\n' "$PROFILE_BLOCK" | grep -q '_gen_effective "\$eff_p" "\$root"' \
  || _fail "wiring: a profile container must render through _gen_effective"
_ok "wiring: a profile container renders from its scope's config, so it mounts the same workspaces"

grep -q 'cbox config --global set CBOX_WORKSPACES' "$REAL/cbox" || _fail "wiring: the global-container prompt must name cbox config --global set CBOX_WORKSPACES"
grep -q 'cbox setup update workspaces' "$REAL/cbox" || _fail "wiring: the global-container prompt must name cbox setup update workspaces"
grep -q 'derive settings from global config (isolated project)' "$REAL/cbox" || _fail "wiring: the first-run options must say the derived project is isolated"
_ok "wiring: prompts name the fixes and say a derived project is isolated"

echo "PASS: project workspaces (config set/unset, derive, migration, config --global)"
