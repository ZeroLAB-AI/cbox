#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_DIR="$INSTALL_DIR"
TMPBASE="$(cd "$(mktemp -d)" && pwd -P)"
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

GUARD="$REAL_DIR/lib/cbox_bind_guard.py"
NEWGEN="$REAL_DIR/templates/generators.sh"

H="$TMPBASE/home"
RUNDIR="$TMPBASE/run"
ROOT="$TMPBASE/proj"
WSX="$TMPBASE/wsx"
SCOPE="$TMPBASE/scope"
EFFP="$SCOPE/profiles/work"
STORE="$H/.config/cbox/profiles/work"
OTHER="$H/.config/cbox/profiles/other"
mkdir -p "$H/.claude" "$H/.codex" "$H/.ssh" "$H/.gnupg" "$H/.docker" "$RUNDIR" "$ROOT" "$WSX" "$SCOPE/claude-config" "$EFFP" "$STORE" "$OTHER/claude" "$H/.config/cbox/user/policies"
chmod 0700 "$STORE"
printf '{"userID":"u"}\n' > "$SCOPE/claude-config/.claude.json"
printf '{"userID":"u"}\n' > "$H/.claude.json"
printf 'default-token\n' > "$H/.claude/.credentials.json"
printf 'other-token\n' > "$OTHER/claude/.credentials.json"

_render() {
  local eff="$1" prof="$2"
  shift 2
  mkdir -p "$eff"
  (
    export HOME="$H" INSTALL_DIR XDG_RUNTIME_DIR="$RUNDIR"
    export CBOX_CLAUDE_MODE=mount CBOX_CODEX_MODE=mount CBOX_SESSION_SCOPE=isolated
    export CBOX_CLAUDE_PATH="${CLAUDE_PATH_OVERRIDE:-$H/.claude}" CBOX_CODEX_PATH="$H/.codex"
    export CBOX_CLIPBOARD_MODE=bridge CBOX_WORKSPACES="$ROOT $WSX"
    export CBOX_SSH_MODE=host-agent CBOX_SSH_AGENT_DIR="$RUNDIR/cbox-ssh"
    local kv
    for kv in "$@"; do export "$kv"; done
    if [ "$prof" != default ]; then export CBOX_RENDER_PROFILE="$prof"; fi
    . "$REAL_DIR/_common.sh"
    . "$NEWGEN"
    gen_compose_isolated "$eff" "$ROOT" testimg testhash123456
  )
}

_guard() {
  local eff="$1" roots="-"
  [ ! -f "$eff/bind-roots" ] || roots="$eff/bind-roots"
  python3 -I "$GUARD" check "$H" "$RUNDIR" "$roots" "$eff/docker-compose.yml"
}

_expect_refused() {
  local label="$1" needle="$2"
  shift 2
  if "$@" >"$TMPBASE/g.out" 2>"$TMPBASE/g.err"; then
    _fail "$label: guard accepted"
  fi
  grep -qF -- "$needle" "$TMPBASE/g.err" || _fail "$label: message lacks '$needle': $(cat "$TMPBASE/g.err")"
  _ok "$label"
}

_has_root() {
  local kind="$1" path="$2" file="$3" line
  while IFS= read -r line; do
    case "$line" in "$kind"$'\t'"$path"$'\t'*) return 0 ;; esac
  done < "$file"
  return 1
}

DEFEFF="$TMPBASE/defeff"
_render "$DEFEFF" default >/dev/null 2>"$TMPBASE/r.err" || _fail "default render failed: $(cat "$TMPBASE/r.err")"
[ -f "$DEFEFF/bind-roots" ] || _fail "render wrote no bind roots sidecar"
_has_root root "$H/.claude" "$DEFEFF/bind-roots" || _fail "sidecar lacks the claude root"
_has_root zone "$DEFEFF" "$DEFEFF/bind-roots" || _fail "sidecar lacks the eff dir"
_guard "$DEFEFF" || _fail "default isolated render refused by the guard: $(cat "$TMPBASE/g.err" 2>/dev/null)"
_ok "default isolated render (mirrored layout: claude, codex, workspaces, bridges, agent dir, user dir) passes with no false positive"

PROFEFF="$EFFP"
_render "$PROFEFF" work >/dev/null 2>"$TMPBASE/r.err" || _fail "profile render failed: $(cat "$TMPBASE/r.err")"
_has_root deny "$H/.claude/.credentials.json" "$PROFEFF/bind-roots" || _fail "profile sidecar lacks the credentials deny entry"
_has_root deny "$H/.claude/backups" "$PROFEFF/bind-roots" || _fail "profile sidecar lacks the backups deny entry"
_has_root deny "$H/.codex/auth.json" "$PROFEFF/bind-roots" || _fail "profile sidecar lacks the codex auth deny entry"
_guard "$PROFEFF" || _fail "profile render refused by the guard: $(cat "$TMPBASE/g.err" 2>/dev/null)"
_ok "profile render passes the guard and declares the credential deny paths"

_swap() {
  local path="$1" target="$2"
  mv "$path" "$path.orig"
  ln -s "$target" "$path"
}
_unswap() {
  local path="$1"
  rm -f "$path"
  mv "$path.orig" "$path"
}

mkdir -p "$H/.claude/rules" "$H/.claude/projects"
_swap "$H/.claude/rules" "$H/.config/cbox/profiles/work"
_expect_refused "default container: rules swapped to a profile store is refused" "$H/.claude/rules" _guard "$DEFEFF"
_expect_refused "profile container: rules swapped to a profile store is refused" "outside its declared root" _guard "$PROFEFF"
_unswap "$H/.claude/rules"

_swap "$H/.claude/rules" "$RUNDIR"
_expect_refused "rules swapped into the XDG runtime dir (docker socket) is refused" "resolves to $RUNDIR" _guard "$DEFEFF"
_unswap "$H/.claude/rules"

_swap "$H/.claude/rules" "$H/.ssh"
_expect_refused "rules swapped to ~/.ssh is refused" "$H/.ssh" _guard "$DEFEFF"
_unswap "$H/.claude/rules"
for z in .gnupg .docker; do
  _swap "$H/.claude/rules" "$H/$z"
  _expect_refused "rules swapped to ~/$z is refused" "$H/$z" _guard "$DEFEFF"
  _unswap "$H/.claude/rules"
done

_swap "$H/.claude/rules" "$H/.config/cbox"
_expect_refused "rules swapped to the cbox config root is refused" "$H/.config/cbox" _guard "$DEFEFF"
_unswap "$H/.claude/rules"

SLUGDIR="$(grep -o "$H/.claude/projects/[^:]*:" "$DEFEFF/docker-compose.yml" | head -n1 | tr -d ':')"
[ -n "$SLUGDIR" ] && [ -d "$SLUGDIR" ] || _fail "fixture: project slug dir not found"
_swap "$SLUGDIR" "$H/.ssh"
_expect_refused "a nested bind source (projects/<slug>) swapped to a symlink is refused" "$SLUGDIR" _guard "$DEFEFF"
_unswap "$SLUGDIR"

_swap "$H/.claude/rules" "$H/.claude"
_expect_refused "profile container: a source resolving to the claude root exposes the credentials and is refused" "protected path" _guard "$PROFEFF"
_unswap "$H/.claude/rules"
mkdir -p "$H/.claude/backups"
_swap "$H/.claude/rules" "$H/.claude/backups"
_expect_refused "profile container: a source resolving to backups is refused" "protected path" _guard "$PROFEFF"
_unswap "$H/.claude/rules"
mkdir -p "$H/.claude/plans2"
_swap "$H/.claude/plans" "$H/.claude/plans2"
_guard "$PROFEFF" || _fail "a symlink that stays inside the claude root must pass: $(cat "$TMPBASE/g.err")"
_unswap "$H/.claude/plans"
_ok "a symlink staying inside its declared root passes"

_swap "$WSX" "$H/.ssh"
_expect_refused "a workspace swapped to a symlink is refused" "$WSX" _guard "$DEFEFF"
_unswap "$WSX"

_swap "$H/.codex/config.toml" "$H/.ssh"
_expect_refused "codex pin swapped to ~/.ssh is refused" "$H/.codex/config.toml" _guard "$DEFEFF"
_unswap "$H/.codex/config.toml"

BRIDGE="$(grep -o "$RUNDIR/cbox-clip-[^:]*" "$DEFEFF/docker-compose.yml" | head -n1)"
[ -n "$BRIDGE" ] || _fail "fixture: clip bridge dir not found"
mkdir -p "$BRIDGE"
_guard "$DEFEFF" || _fail "a real bridge dir under the XDG runtime dir must pass: $(cat "$TMPBASE/g.err")"
_swap "$BRIDGE" "$H/.ssh"
_expect_refused "the bridge dir swapped to ~/.ssh is refused" "$BRIDGE" _guard "$DEFEFF"
_unswap "$BRIDGE"
_ok "bridge dir under the XDG runtime dir passes while it stays put"

REALCLAUDE="$TMPBASE/data/claude_real"
mkdir -p "$REALCLAUDE"
cp -a "$H/.claude/." "$REALCLAUDE/"
LINKEFF="$TMPBASE/linkeff"
ln -s "$REALCLAUDE" "$TMPBASE/claude_link"
( CLAUDE_PATH_OVERRIDE="$TMPBASE/claude_link" _render "$LINKEFF" default ) >/dev/null 2>"$TMPBASE/r.err" || _fail "render with a symlinked claude path failed: $(cat "$TMPBASE/r.err")"
_guard "$LINKEFF" || _fail "a symlinked claude root must keep working: $(cat "$TMPBASE/g.err")"
LINKPROF="$SCOPE/profiles/linkp"
mkdir -p "$LINKPROF" "$H/.config/cbox/profiles/linkp"
chmod 0700 "$H/.config/cbox/profiles/linkp"
( CLAUDE_PATH_OVERRIDE="$TMPBASE/claude_link" _render "$LINKPROF" linkp ) >/dev/null 2>"$TMPBASE/r.err" || _fail "profile render with a symlinked claude path failed: $(cat "$TMPBASE/r.err")"
_guard "$LINKPROF" || _fail "a symlinked claude root must keep working for a profile: $(cat "$TMPBASE/g.err")"
mv "$REALCLAUDE/rules" "$REALCLAUDE/rules.orig"
ln -s "$H/.ssh" "$REALCLAUDE/rules"
_expect_refused "a symlinked claude root still refuses an escaping nested source" "$TMPBASE/claude_link/rules" _guard "$LINKEFF"
rm -f "$REALCLAUDE/rules"
mv "$REALCLAUDE/rules.orig" "$REALCLAUDE/rules"
_ok "a user whose whole claude path is a symlink keeps working (compared against the resolved root)"

NOROOTS="$TMPBASE/noroots"
mkdir -p "$NOROOTS"
cp "$DEFEFF/docker-compose.yml" "$NOROOTS/docker-compose.yml"
_guard "$NOROOTS" || _fail "a compose without a sidecar must still pass when nothing escapes: $(cat "$TMPBASE/g.err")"
_swap "$H/.claude/rules" "$H/.ssh"
_expect_refused "no sidecar: a symlink into a protected area is still refused" "$H/.ssh" _guard "$NOROOTS"
_unswap "$H/.claude/rules"
_ok "legacy compose without a sidecar: zone rule only"

UNDECL="$TMPBASE/undecl"
mkdir -p "$UNDECL"
cp "$DEFEFF/bind-roots" "$UNDECL/bind-roots"
{
  printf 'services:\n  cbox:\n    volumes:\n'
  printf '      - %s/anything:/x:rw\n' "$H/.config/cbox"
} > "$UNDECL/docker-compose.yml"
_expect_refused "a source in the cbox config root outside every declared root is refused" "protected area" _guard "$UNDECL"
{
  printf 'services:\n  cbox:\n    volumes:\n'
  printf '      - type: bind\n        source: %s\n        target: /x\n' "$RUNDIR/stray"
} > "$UNDECL/docker-compose.yml"
_expect_refused "long-form source in the XDG runtime dir outside every declared root is refused" "protected area" _guard "$UNDECL"
{
  printf 'services:\n  cbox:\n    volumes:\n'
  printf '      - %s/with space/x:/x:rw\n' "$H/.config/cbox"
} > "$UNDECL/docker-compose.yml"
_expect_refused "a source path containing a space is parsed whole and checked" "with space" _guard "$UNDECL"
_ok "undeclared sources inside protected areas are refused (short and long syntax, spaces in paths)"

TMPDOCKER="$TMPBASE/bin"
mkdir -p "$TMPDOCKER"
cat > "$TMPDOCKER/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DOCKER_LOG"
exit 0
EOF
chmod +x "$TMPDOCKER/docker"
export PATH="$TMPDOCKER:$PATH"
export STUB_DOCKER_LOG="$TMPBASE/docker.log"
: > "$STUB_DOCKER_LOG"

_extract_fn() {
  awk -v fn="$2" '$0 == fn"() {" , $0 == "}"' "$1"
}
export HOME="$H"
export XDG_RUNTIME_DIR="$RUNDIR"
. "$REAL_DIR/_common.sh"
. "$NEWGEN"
for _fn in _cbox_bind_guard _cbox_compose_stopped_dead_network _cbox_compose_up _cbox_compose_files_digest _cbox_compose_removing_ids _cbox_compose_up_wait_removed; do
  _body="$(_extract_fn "$REAL_DIR/cbox" "$_fn")"
  [ -n "$_body" ] || _fail "cannot extract $_fn from cbox"
  eval "$_body"
done

COMPOSE_ARGV=(docker compose --project-directory "$DEFEFF" -f "$DEFEFF/docker-compose.yml")
: > "$STUB_DOCKER_LOG"
_cbox_compose_up "$DEFEFF/.compose.up.stamp" "${COMPOSE_ARGV[@]}" >/dev/null 2>&1 || _fail "compose up refused a clean render"
grep -q ' up -d' "$STUB_DOCKER_LOG" || _fail "compose up did not reach docker for a clean render"
_swap "$H/.claude/rules" "$H/.ssh"
: > "$STUB_DOCKER_LOG"
if _cbox_compose_up "$DEFEFF/.compose.up.stamp" "${COMPOSE_ARGV[@]}" >/dev/null 2>"$TMPBASE/up.err"; then
  _fail "compose up ran with a swapped bind source"
fi
grep -q ' up ' "$STUB_DOCKER_LOG" && _fail "docker up was called despite the guard refusal"
grep -qF "$H/.claude/rules" "$TMPBASE/up.err" || _fail "refusal does not name the path: $(cat "$TMPBASE/up.err")"
_unswap "$H/.claude/rules"
PROF_ARGV=(docker compose --project-directory "$PROFEFF" -f "$PROFEFF/docker-compose.yml")
_swap "$H/.claude/skills" "$H/.config/cbox/profiles/other"
if _cbox_compose_up "$PROFEFF/.compose.up.stamp" "${PROF_ARGV[@]}" >/dev/null 2>"$TMPBASE/up2.err"; then
  _fail "profile compose up ran with a bind source resolving into another profile store"
fi
grep -q ' up ' "$STUB_DOCKER_LOG" && _fail "docker up was called for the profile despite the guard refusal"
_unswap "$H/.claude/skills"
_ok "_cbox_compose_up (default and profile) refuses before docker up and names the path; clean renders reach docker up"

_swap "$H/.claude/rules" "$H/.ssh"
for _call in 'compose_ps_probe' ; do :; done
body_run="$(_extract_fn "$REAL_DIR/cbox" _cbox_netaccess_shell_ensure)"
case "$body_run" in *'_cbox_bind_guard "${COMPOSE[@]}"'*) ;; *) _fail "the stopped-proxy start in _cbox_netaccess_shell_ensure is not guarded" ;; esac
case "$(cat "$REAL_DIR/lib/cbox-ai.sh")" in *'_cbox_bind_guard "${runcmd[@]}"'*) ;; *) _fail "the read-only compose run in cbox-ai.sh is not guarded" ;; esac
_unswap "$H/.claude/rules"
_ok "every other compose create path (proxy start, read-only run) calls the guard"

GL="$TMPBASE/gl"
mkdir -p "$GL/generated/state" "$GL/generated/claude-config" "$GL/generated/hooks" "$GL/home"
cp -r "$REAL_DIR/etc" "$REAL_DIR/templates" "$REAL_DIR/lib" "$GL/"
cp "$REAL_DIR/_common.sh" "$REAL_DIR/entrypoint.sh" "$REAL_DIR/install-bins.sh" "$GL/"
: > "$GL/image.inputs"
(
  export HOME="$H" INSTALL_DIR="$GL" XDG_RUNTIME_DIR="$RUNDIR"
  export CBOX_CLAUDE_MODE=mount CBOX_CODEX_MODE=mount CBOX_WORKSPACES="$ROOT $WSX"
  export CBOX_USER_DIR="$H/.config/cbox/user" CBOX_NAME=cboxg
  . "$GL/_common.sh"
  . "$GL/templates/generators.sh"
  gen_compose
) >/dev/null 2>"$TMPBASE/gl.err" || _fail "global render failed: $(cat "$TMPBASE/gl.err")"
[ -f "$GL/generated/bind-roots" ] || _fail "global render wrote no sidecar"
python3 -I "$GUARD" check "$H" "$RUNDIR" "$GL/generated/bind-roots" "$GL/docker-compose.yml" || _fail "global default render refused by the guard"
GCOMPOSE=(docker compose -f "$GL/docker-compose.yml")
_swap "$H/.claude/rules" "$H/.ssh"
if INSTALL_DIR="$GL" _cbox_bind_guard "${GCOMPOSE[@]}" >/dev/null 2>"$TMPBASE/g2.err"; then
  _fail "the global compose guard accepted a swapped source"
fi
_unswap "$H/.claude/rules"
INSTALL_DIR="$GL" _cbox_bind_guard "${GCOMPOSE[@]}" || _fail "the global compose guard refused the clean render"
_ok "global render: sidecar written under generated/, clean render passes, a swapped source is refused"

for f in "$GUARD"; do python3 -m py_compile "$f" || _fail "py_compile $f"; done
bash -n "$0" || _fail "bash -n"
echo "PASS: all bind guard checks"
