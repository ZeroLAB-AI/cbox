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

while IFS='=' read -r _cbox_env_name _; do
  case "$_cbox_env_name" in
    CBOX_*|OLLAMA_*|HERMES_*|CODEX_GUARD_*|HOST_HOME|XDG_RUNTIME_DIR) unset "$_cbox_env_name" ;;
  esac
done < <(env)
unset CBOX_PROFILE CBOX_RENDER_PROFILE CBOX_WORKSPACES

BASE_REV="35eef5d"
NEWGEN="$INSTALL_DIR/templates/generators.sh"
FIX="$INSTALL_DIR/lib/fixtures/render_baselines"
_need_fixture() {
  [ -f "$FIX/$1" ] || _fail "missing baseline fixture $FIX/$1 - the byte-identity baselines must ship with the package"
}

TB="$(cd "$TMPBASE" && pwd -P)"
H="$TB/home"
RUNDIR="$TB/run"
PW="$TB/pw"
ROOT="$PW/root"
ROOT2="$PW/root2"
WSA="$TB/wsa"
WSB="$TB/wsb"
STORE="$H/.config/cbox/profiles/work"
SCOPE="$TB/scope"
EFFP="$SCOPE/profiles/work"
mkdir -p "$H/.claude" "$H/.codex" "$RUNDIR" "$ROOT/inner" "$ROOT2" "$WSA/deep" "$WSB" "$STORE" "$SCOPE/claude-config" "$EFFP" "$H/.config/cbox"
chmod 0700 "$STORE"
printf '{"userID":"u"}\n' > "$SCOPE/claude-config/.claude.json"
printf '{"userID":"u"}\n' > "$H/.claude.json"
: > "$TB/plainfile"
ln -s "$ROOT" "$TB/rootlink"

_render() {
  local eff="$1" prof="$2" gen="$3" ws="$4"
  mkdir -p "$eff"
  (
    export HOME="$H" INSTALL_DIR XDG_RUNTIME_DIR="$RUNDIR"
    export CBOX_CLAUDE_MODE=mount CBOX_CODEX_MODE=mount CBOX_SESSION_SCOPE=isolated
    export CBOX_CLAUDE_PATH="$H/.claude" CBOX_CODEX_PATH="$H/.codex"
    export CBOX_USER_DIR="$TB/nouser" CBOX_CLIPBOARD_MODE=bridge
    if [ "$ws" != "-unset-" ]; then export CBOX_WORKSPACES="$ws"; fi
    if [ "$prof" != default ]; then export CBOX_RENDER_PROFILE="$prof"; fi
    . "$INSTALL_DIR/_common.sh"
    . "$gen"
    gen_compose_isolated "$eff" "$ROOT" testimg testhash123456 || exit 1
    gen_codex_profile_into "$eff/codex" isolated "$ROOT" || exit 1
  )
}

_with_review() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
out = []
for line in open(p).read().split("\n"):
    out.append(line)
    if line == "      - CBOX_CONTEXT_PROFILE=full":
        out.append("      - CBOX_REVIEW=ask")
        out.append("      - CBOX_BUDGET_MODE=on")
        out.append("      - CBOX_BUDGET_LOW_5H=15")
        out.append("      - CBOX_BUDGET_LOW_7D=20")
        out.append("      - CBOX_BUDGET_PACE_WINDOW_H=3")
        out.append("      - CBOX_BUDGET_PACE_SLACK_H=8")
open(p, "w").write("\n".join(out))
PY
}

FAILN=0
_expect_fail() {
  local label="$1" needle="$2" ws="$3" eff
  FAILN=$((FAILN + 1))
  eff="$TB/eff_fail_$FAILN"
  if _render "$eff" default "$NEWGEN" "$ws" >/dev/null 2>"$TB/fail.err"; then
    _fail "$label: render succeeded"
  fi
  grep -qF -- "$needle" "$TB/fail.err" || _fail "$label: message lacks '$needle': $(cat "$TB/fail.err")"
  [ ! -f "$eff/docker-compose.yml" ] || _fail "$label: compose file written despite failure"
  _ok "$label: render refused ($needle)"
}

_binds() {
  grep -E '^      - [^ ]+:[^ ]+:rw$' "$1" | sed -E 's/^      - //' | awk -F: '$1==$2 {print $1}'
}

_ws_binds() {
  _binds "$1" | grep -F -x -e "$ROOT" -e "$ROOT2" -e "$WSA" -e "$WSB" | tr '\n' ' '
}

ROOTHASH="$(. "$INSTALL_DIR/_common.sh"; _cbox_path_hash "$ROOT")"
TBSLUG="$(printf '%s' "$TB" | sed 's|[/.]|-|g')"
_norm() {
  sed -e "s|$TBSLUG|@TMPSLUG@|g" -e "s|$TB|@TMP@|g" -e "s|$INSTALL_DIR|@INSTALL@|g" -e "s/$ROOTHASH/@ROOTHASH@/g"
}

if true; then
  n=0
  EID="$TB/eff_id"
  for ws in "$ROOT" "-unset-" ""; do
    n=$((n + 1))
    _render "$EID" default "$NEWGEN" "$ws" >/dev/null 2>"$TB/n.err" || _fail "new render failed: $(cat "$TB/n.err")"
    _norm < "$EID/docker-compose.yml" > "$TB/new_compose_$n.yml"
    _norm < "$EID/codex/cbox-container.config.toml" > "$TB/new_codex_$n.toml"
    _need_fixture "workspaces_root_only_compose_$n.yml"
    _need_fixture "workspaces_root_only_codex_$n.toml"
    cp "$FIX/workspaces_root_only_compose_$n.yml" "$TB/base_compose_$n.yml"
    _with_review "$TB/base_compose_$n.yml"
    cmp -s "$TB/new_compose_$n.yml" "$TB/base_compose_$n.yml" || _fail "root-only compose differs from $BASE_REV for ws='$ws':
$(diff "$TB/base_compose_$n.yml" "$TB/new_compose_$n.yml")"
    cmp -s "$TB/new_codex_$n.toml" "$FIX/workspaces_root_only_codex_$n.toml" || _fail "root-only codex profile differs from $BASE_REV for ws='$ws'"
  done
  _ok "root-only render byte-identical to the baseline fixtures from $BASE_REV (CBOX_WORKSPACES equal root, unset, empty): compose and codex profile"
fi

E1="$TB/eff1"
_render "$E1" default "$NEWGEN" "$ROOT $WSA $WSB" >/dev/null 2>"$TB/e1.err" || _fail "multi render failed: $(cat "$TB/e1.err")"
C1="$E1/docker-compose.yml"
[ "$(_ws_binds "$C1")" = "$ROOT $WSA $WSB " ] || _fail "workspace binds wrong or out of order: $(_binds "$C1" | tr '\n' ' ')"
_ok "two extra dirs mounted 1:1 rw in order after root"

grep -qxF "    working_dir: $ROOT" "$C1" || _fail "working_dir is not root"
grep -qxF "      - CBOX_SCOPE_ROOT=$ROOT" "$C1" || _fail "CBOX_SCOPE_ROOT is not root"
grep -qxF "      cbox.root: \"$ROOT\"" "$C1" || _fail "cbox.root label is not root"
SLUG="$(. "$INSTALL_DIR/_common.sh"; _cbox_slug "$ROOT")"
grep -qE "^      - CBOX_MANAGED_DIRS=.*/projects/$SLUG\$" "$C1" || _fail "managed dirs changed: $(grep CBOX_MANAGED_DIRS "$C1")"
_ok "working_dir, CBOX_SCOPE_ROOT, cbox.root label and managed dirs stay root"

GR="$(sed -n 's/^      - CODEX_GUARD_EXTRA_ROOTS=//p' "$C1")"
[ "$GR" = "$ROOT:$WSA:$WSB" ] || _fail "guard roots value is '$GR'"
PARSED="$(CODEX_GUARD_EXTRA_ROOTS="$GR" python3 -I - "$INSTALL_DIR/etc/hooks/codex_mode_guard.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("guard_under_test", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
for r in mod._allowed_roots({}):
    print(r)
PY
)"
[ "$PARSED" = "$ROOT
$WSA
$WSB" ] || _fail "real guard parser read: $PARSED"
_ok "guard roots value ($GR) parsed by the real guard parser into root plus both extras"

CP="$E1/codex/cbox-container.config.toml"
for d in "$ROOT" "$WSA" "$WSB"; do
  grep -qxF "[projects.\"$d\"]" "$CP" || _fail "codex profile does not trust $d"
done
_ok "isolated codex profile trusts every workspace"

E2="$TB/eff2"
_render "$E2" default "$NEWGEN" "$ROOT $WSA $ROOT $WSA $TB/rootlink $WSB $WSB/" >/dev/null 2>"$TB/e2.err" || _fail "dedup render failed: $(cat "$TB/e2.err")"
[ "$(_ws_binds "$E2/docker-compose.yml")" = "$ROOT $WSA $WSB " ] || _fail "dedup binds wrong: $(_binds "$E2/docker-compose.yml" | tr '\n' ' ')"
[ "$(grep -cxF "      - $ROOT:$ROOT:rw" "$E2/docker-compose.yml")" = 1 ] || _fail "root mounted more than once"
[ "$(sed -n 's/^      - CODEX_GUARD_EXTRA_ROOTS=//p' "$E2/docker-compose.yml")" = "$ROOT:$WSA:$WSB" ] || _fail "dedup guard roots wrong"
_ok "root, repeats, a symlink to root and a trailing-slash twin are de-duplicated with order kept"

E3="$TB/eff3"
_render "$E3" default "$NEWGEN" "$ROOT2 $WSA" >/dev/null 2>"$TB/e3.err" || _fail "sibling-prefix render failed: $(cat "$TB/e3.err")"
grep -qxF "      - $ROOT2:$ROOT2:rw" "$E3/docker-compose.yml" || _fail "sibling dir sharing a name prefix with root was not mounted"
_ok "a sibling sharing a name prefix with root is not treated as nested"

_expect_fail "relative entry" "not an absolute path: rel/dir" "$ROOT rel/dir"
_expect_fail "dot-relative entry" "not an absolute path: ./x" "$ROOT ./x"
_expect_fail "missing entry" "does not exist or is not a directory: $TB/nowhere" "$ROOT $WSA $TB/nowhere"
_expect_fail "non-directory entry" "does not exist or is not a directory: $TB/plainfile" "$ROOT $TB/plainfile"
_expect_fail "entry with colon" "cannot be mounted" "$ROOT /a:b"
mkdir -p "$TB/has:colon" "$TB/has\$dollar" "$TB/has space" "$TB/nl_target" "$H/.ssh" "$H/.gnupg" "$H/.docker" "$RUNDIR/sub"
NLDIR="$TB/nl"$'\n'"dir"
mkdir -p "$NLDIR"
ln -s "$TB/has:colon" "$TB/lnk_colon"
ln -s "$TB/has\$dollar" "$TB/lnk_dollar"
ln -s "$TB/has space" "$TB/lnk_space"
ln -s "$NLDIR" "$TB/lnk_newline"
_expect_fail "symlink whose real path has a colon" "resolves to a path that cannot be mounted" "$ROOT $TB/lnk_colon"
_expect_fail "symlink whose real path has a dollar sign" "resolves to a path that cannot be mounted" "$ROOT $TB/lnk_dollar"
_expect_fail "symlink whose real path has a newline" "resolves to a path that cannot be mounted" "$ROOT $TB/lnk_newline"
_expect_fail "symlink whose real path has whitespace" "whitespace" "$ROOT $TB/lnk_space"
_expect_fail "XDG runtime dir" "conflicts with the XDG runtime dir" "$ROOT $RUNDIR/sub"
_expect_fail "parent of the XDG runtime dir" "conflicts with the XDG runtime dir" "$ROOT $TB/run"
_expect_fail "ssh dir" "conflicts with ~/.ssh" "$ROOT $H/.ssh"
_expect_fail "gnupg dir" "conflicts with ~/.gnupg" "$ROOT $H/.gnupg"
_expect_fail "docker config dir" "conflicts with ~/.docker" "$ROOT $H/.docker"
for _badroot in "$TB/a:b" "$TB/a\$b" "$TB/a\"b" "$TB/a #b"; do
  mkdir -p "$_badroot"
  if ( export HOME="$H" INSTALL_DIR XDG_RUNTIME_DIR="$RUNDIR" CBOX_CLAUDE_MODE=mount CBOX_CODEX_MODE=mount CBOX_SESSION_SCOPE=isolated CBOX_CLAUDE_PATH="$H/.claude" CBOX_CODEX_PATH="$H/.codex" CBOX_USER_DIR="$TB/nouser"
       . "$INSTALL_DIR/_common.sh"; . "$NEWGEN"; mkdir -p "$TB/eff_badroot"; gen_compose_isolated "$TB/eff_badroot" "$_badroot" testimg testhash123456 ) >/dev/null 2>"$TB/br.err"; then
    _fail "project root '$_badroot' was accepted"
  fi
  grep -qF "project root cannot be mounted" "$TB/br.err" || _fail "bad root message: $(cat "$TB/br.err")"
done
_ok "project root with a colon, dollar sign, quote or ' #' is refused like a workspace entry"
_expect_fail "install dir" "conflicts with INSTALL_DIR" "$ROOT $INSTALL_DIR"
_expect_fail "inside install dir" "conflicts with INSTALL_DIR" "$ROOT $INSTALL_DIR/lib"
_expect_fail "claude dir" "conflicts with CBOX_CLAUDE_PATH" "$ROOT $H/.claude"
_expect_fail "codex dir" "conflicts with CBOX_CODEX_PATH" "$ROOT $H/.codex"
_expect_fail "cbox config root" "conflicts with the cbox config root" "$ROOT $H/.config/cbox"
_expect_fail "nested in root" "project workspaces overlap" "$ROOT $ROOT/inner"
_expect_fail "parent of root" "project workspaces overlap" "$ROOT $PW"
_expect_fail "nested in another entry" "project workspaces overlap" "$ROOT $WSA $WSA/deep"
_expect_fail "parent of another entry" "project workspaces overlap" "$ROOT $WSA/deep $WSA"

VENV="$TB/venv"
mkdir -p "$VENV" "$TB/eff_venv"
if ( export CBOX_VENV_PATH="$VENV"; _render "$TB/eff_venv" default "$NEWGEN" "$ROOT $VENV" ) >/dev/null 2>"$TB/v.err"; then
  _fail "venv path entry accepted"
fi
grep -qF "conflicts with CBOX_VENV_PATH" "$TB/v.err" || _fail "venv conflict message missing: $(cat "$TB/v.err")"
_ok "venv path entry refused"

_render "$EFFP" work "$NEWGEN" "$ROOT $WSA $WSB" >/dev/null 2>"$TB/p.err" || _fail "profile render failed: $(cat "$TB/p.err")"
CPF="$EFFP/docker-compose.yml"
grep -qxF '      cbox.profile: "work"' "$CPF" || _fail "profile label missing"
[ "$(_ws_binds "$CPF")" = "$ROOT $WSA $WSB " ] || _fail "profile workspace binds wrong: $(_binds "$CPF" | tr '\n' ' ')"
[ "$(sed -n 's/^      - CODEX_GUARD_EXTRA_ROOTS=//p' "$CPF")" = "$ROOT:$WSA:$WSB" ] || _fail "profile guard roots wrong"
grep -qxF "    working_dir: $ROOT" "$CPF" || _fail "profile working_dir is not root"
_ok "profile render carries the same workspace binds and guard roots"

ER="$TB/eff_ro"
mkdir -p "$ER"
(
  export HOME="$H" INSTALL_DIR
  export CBOX_WORKSPACES="$ROOT $WSA"
  . "$INSTALL_DIR/_common.sh"
  . "$NEWGEN"
  gen_compose_readonly_isolated_into "$ER/docker-compose.readonly.yml" "$ROOT"
) >/dev/null 2>"$TB/ro.err" || _fail "readonly isolated render failed: $(cat "$TB/ro.err")"
[ "$(grep -c 'read_only: true' "$ER/docker-compose.readonly.yml")" = 2 ] || _fail "readonly override does not cover root plus extra"
grep -qxF "        source: $WSA" "$ER/docker-compose.readonly.yml" || _fail "readonly override lacks the extra workspace"
_ok "readonly isolated override covers every workspace"

(
  export HOME="$H" INSTALL_DIR
  . "$INSTALL_DIR/_common.sh"
  . "$NEWGEN"
  . "$INSTALL_DIR/lib/cbox-ai.sh"
  git init -q "$WSA" >/dev/null 2>&1
  ph="$(_cbox_path_hash "$ROOT")"
  mkdir -p "$H/.config/cbox/projects/$ph"
  printf 'CBOX_WORKSPACES=%q\n' "$ROOT $WSA $TB/nowhere" > "$H/.config/cbox/projects/$ph/cbox.conf"
  export CBOX_WORKSPACES="$WSB"
  _cbox_effective_mode() { printf isolated; }
  got="$(_cbox_ai_fingerprint_roots "$ROOT" | tr '\n' ' ')"
  [ "$got" = "$ROOT $WSA " ] || { echo "isolated fingerprint roots: got '$got'" >&2; exit 1; }
  _cbox_effective_mode() { printf global; }
  got="$(_cbox_ai_fingerprint_roots "$ROOT" | tr '\n' ' ')"
  [ "$got" = "$ROOT $WSB " ] || { echo "global fingerprint roots: got '$got'" >&2; exit 1; }
) || _fail "read-only fingerprint roots do not follow the project workspace list"
_ok "read-only fingerprint roots: the project list (root plus existing extras) in an isolated project, the global list otherwise"

echo "ALL PASS"
