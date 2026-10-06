#!/usr/bin/env bash
set -euo pipefail

unset CBOX_PROFILE CBOX_RENDER_PROFILE
for _cbox_live_var in $(compgen -v CBOX_); do
  unset "$_cbox_live_var"
done
unset _cbox_live_var

REAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

export HOME="$TMPBASE/home"
mkdir -p "$HOME"
INSTALL_DIR="$TMPBASE/install"
mkdir -p "$INSTALL_DIR"
CONF="$INSTALL_DIR/cbox.conf"

STUBBIN="$TMPBASE/bin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DOCKER_LOG"
[ "${STUB_DOCKER_RC:-0}" = 0 ] || exit "$STUB_DOCKER_RC"
case "${1:-}" in
  ps)
    if [ -n "${STUB_DOCKER_PS:-}" ]; then
      printf '%s\n' "$STUB_DOCKER_PS"
    fi
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$STUBBIN/docker"
export PATH="$STUBBIN:$PATH"
export STUB_DOCKER_LOG="$TMPBASE/docker.log"
: > "$STUB_DOCKER_LOG"

. "$REAL_DIR/_common.sh"
. "$REAL_DIR/templates/generators.sh"
. "$REAL_DIR/templates/validator_lib.sh"
. "$REAL_DIR/templates/validator_dispatch.sh"
. "$REAL_DIR/lib/cbox-profile.sh"

_cbox_config_in_container() { return 1; }

STORE_ROOT="$HOME/.config/cbox/profiles"

_mode() {
  python3 -c 'import os, sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$1"
}

_run() {
  RUN_RC=0
  RUN_OUT="$("$@" 2> "$TMPBASE/stderr")" || RUN_RC=$?
  RUN_ERR="$(cat "$TMPBASE/stderr")"
}

for good in a work work-2 a1-b2-c3 abcdefghijklmnop default; do
  _cbox_profile_name_valid "$good" || _fail "name validation: '$good' should be valid"
done
LONG33="abcdefghijklmnopqrstuvwxyzabcdefg"
LONG17="abcdefghijklmnopq"
LONG32="abcdefghijklmnopqrstuvwxyzabcdef"
for bad in "" Work 1abc -a a_b "a b" "$LONG17" "$LONG32" "$LONG33" "a.b" "ab/c" "../x" "$(printf 'a\nb')" "a*"; do
  if _cbox_profile_name_valid "$bad"; then
    _fail "name validation: '$bad' should be invalid"
  fi
done
_ok "name validation: ^[a-z][a-z0-9-]{0,15}\$ accepted and rejected as specified"

_run _cbox_profile_require_custom default
[ "$RUN_RC" -ne 0 ] || _fail "default must be refused as a custom profile name"
case "$RUN_ERR" in *reserved*) ;; *) _fail "default refusal must say reserved, got: $RUN_ERR" ;; esac
_run _cbox_profile_require_custom "$LONG17"
[ "$RUN_RC" -ne 0 ] || _fail "a 17 character name must be refused"
case "$RUN_ERR" in *"at most 16"*) ;; *) _fail "17 character refusal must name the limit, got: $RUN_ERR" ;; esac
_run _cbox_profile_add "$LONG17"
[ "$RUN_RC" -ne 0 ] || _fail "add of a 17 character name must be refused"
[ ! -e "$STORE_ROOT/$LONG17" ] || _fail "a refused long name must not create a store"
_run _cbox_profile_require_custom Bad_Name
[ "$RUN_RC" -ne 0 ] || _fail "an invalid name must be refused"
case "$RUN_ERR" in *"invalid profile name"*) ;; *) _fail "invalid name message missing, got: $RUN_ERR" ;; esac
_ok "reserved default and invalid names produce named errors"

_run _cbox_profile_add default
[ "$RUN_RC" -ne 0 ] || _fail "add default must be refused"
_run _cbox_profile_add Bad
[ "$RUN_RC" -ne 0 ] || _fail "add of an invalid name must be refused"
_run _cbox_profile_add
[ "$RUN_RC" -ne 0 ] || _fail "add without a name must be a usage error"
[ ! -e "$STORE_ROOT" ] || _fail "refused adds must not create the store root"
_ok "add refuses default, invalid names and a missing name without touching the disk"

umask 022
_run _cbox_profile_add work
[ "$RUN_RC" -eq 0 ] || _fail "add work failed: $RUN_ERR"
[ -z "$RUN_OUT" ] || _fail "add must print nothing on stdout, got: $RUN_OUT"
case "$RUN_ERR" in *"profile work created"*) ;; *) _fail "the created message must go to stderr, got: $RUN_ERR" ;; esac
umask 077
[ "$(_mode "$STORE_ROOT")" = 700 ] || _fail "profiles root mode must be 0700"
[ "$(_mode "$STORE_ROOT/work")" = 700 ] || _fail "profile dir mode must be 0700"
[ "$(_mode "$STORE_ROOT/work/profile.json")" = 600 ] || _fail "profile.json mode must be 0600"
for sub in claude codex usage; do
  [ -d "$STORE_ROOT/work/$sub" ] || _fail "missing $sub directory"
  [ "$(_mode "$STORE_ROOT/work/$sub")" = 700 ] || _fail "$sub directory mode must be 0700"
done
[ -f "$STORE_ROOT/work/codex/auth.json" ] || _fail "codex/auth.json must exist"
[ ! -s "$STORE_ROOT/work/codex/auth.json" ] || _fail "codex/auth.json must be empty"
[ "$(_mode "$STORE_ROOT/work/codex/auth.json")" = 600 ] || _fail "codex/auth.json mode must be 0600"
[ ! -e "$STORE_ROOT/work/claude/.credentials.json" ] || _fail "add must not create claude credentials"
python3 - "$STORE_ROOT/work/profile.json" <<'PY' || _fail "profile.json content is wrong"
import json, re, sys
d = json.load(open(sys.argv[1]))
assert d["schema"] == 1, d
assert d["name"] == "work", d
assert re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$", d["created_at"]), d
assert d["engines"] == {"claude": {"status": "empty"}, "codex": {"status": "empty"}}, d
assert sorted(d) == ["created_at", "engines", "name", "schema"], d
PY
[ "$(ls -A "$STORE_ROOT/work" | sort | tr '\n' ' ')" = "claude codex profile.json usage " ] \
  || _fail "profile dir must hold exactly claude codex profile.json usage (no temp leftovers), got: $(ls -A "$STORE_ROOT/work")"
_ok "add: layout, modes (0700 dirs, 0600 files, empty codex auth.json) and profile.json content, independent of caller umask"

printf 'keep\n' > "$STORE_ROOT/work/claude/.credentials.json"
_run _cbox_profile_add work
[ "$RUN_RC" -ne 0 ] || _fail "adding an existing profile must be refused"
[ "$(cat "$STORE_ROOT/work/claude/.credentials.json")" = keep ] || _fail "a refused add must leave the existing profile untouched"
rm -f "$STORE_ROOT/work/claude/.credentials.json"
_ok "add refuses an existing name and leaves it untouched"

_run _cbox_profile_add other
[ "$RUN_RC" -eq 0 ] || _fail "add other failed: $RUN_ERR"
_run _cbox_profile_list
[ "$RUN_RC" -eq 0 ] || _fail "list failed: $RUN_ERR"
printf '%s\n' "$RUN_OUT" | grep -Eq '^\* default +claude=host codex=host$' || _fail "list must star default with no conf, got: $RUN_OUT"
printf '%s\n' "$RUN_OUT" | grep -Eq '^  work +claude=empty codex=empty$' || _fail "list must show work with engine status, got: $RUN_OUT"
printf '%s\n' "$RUN_OUT" | grep -Eq '^  other +claude=empty codex=empty$' || _fail "list must show other, got: $RUN_OUT"
[ "$(printf '%s\n' "$RUN_OUT" | grep -c '^\*')" -eq 1 ] || _fail "list must carry exactly one star"
_cbox_profile_cmd ls > "$TMPBASE/ls.out" 2>/dev/null
[ "$(cat "$TMPBASE/ls.out")" = "$RUN_OUT" ] || _fail "ls must be an alias of list"
_ok "list: default plus store dirs, star on default without conf, ls alias"

printf 'CBOX_PROFILE=work\n' > "$CONF"
_run _cbox_profile_list
printf '%s\n' "$RUN_OUT" | grep -Eq '^\* work ' || _fail "list must star work when the global conf says work, got: $RUN_OUT"
printf '%s\n' "$RUN_OUT" | grep -Eq '^  default ' || _fail "default must lose the star, got: $RUN_OUT"
[ "$(printf '%s\n' "$RUN_OUT" | grep -c '^\*')" -eq 1 ] || _fail "list must carry exactly one star"
printf 'CBOX_PROFILE=ghost\n' > "$CONF"
_run _cbox_profile_list
[ "$RUN_RC" -eq 0 ] || _fail "list must not fail on a conf naming a missing profile: $RUN_ERR"
printf '%s\n' "$RUN_OUT" | grep -Eq '^\* ghost +missing' || _fail "list must flag a configured but missing profile, got: $RUN_OUT"
rm -f "$CONF"
_ok "list: star follows the global conf; a configured missing profile is flagged"

_cbox_effective_mode() { printf 'isolated'; }
PROJ="$TMPBASE/proj"
mkdir -p "$PROJ"
PROOT="$(cd "$PROJ" && _cbox_workspace_root)"
PEFF="$HOME/.config/cbox/projects/$(_cbox_path_hash "$PROOT")"
mkdir -p "$PEFF"
PCONF="$PEFF/cbox.conf"

_resolve_in_proj() {
  ( cd "$PROJ" && _cbox_profile_resolve "$@" && printf '%s|%s' "$CBOX_PROFILE_EFFECTIVE" "$CBOX_PROFILE_SOURCE" )
}

_resolve_files() {
  _cbox_profile_resolve_from "${1-}" "$PCONF" "$CONF" 1 && printf '%s|%s' "$CBOX_PROFILE_EFFECTIVE" "$CBOX_PROFILE_SOURCE"
}

_run _resolve_in_proj
[ "$RUN_RC" -eq 0 ] && [ "$RUN_OUT" = "default|default" ] || _fail "no conf anywhere must resolve to default|default, got rc=$RUN_RC '$RUN_OUT' $RUN_ERR"

printf "CBOX_PROFILE=other\n" > "$CONF"
_run _resolve_files
[ "$RUN_OUT" = "other|global" ] || _fail "global conf alone must resolve to other|global, got '$RUN_OUT' $RUN_ERR"

printf "CBOX_PROFILE=work\n" > "$PCONF"
_run _resolve_in_proj
[ "$RUN_OUT" = "work|project" ] || _fail "project conf must beat global conf, got '$RUN_OUT' $RUN_ERR"

_run _resolve_files other
[ "$RUN_OUT" = "other|flag" ] || _fail "flag must beat project and global conf, got '$RUN_OUT' $RUN_ERR"

_run _resolve_files default
[ "$RUN_OUT" = "default|flag" ] || _fail "an explicit default flag must beat configured profiles, got '$RUN_OUT' $RUN_ERR"

printf "CBOX_PROFILE=''\n" > "$PCONF"
_run _resolve_files
[ "$RUN_OUT" = "other|global" ] || _fail "an empty project value must fall through to the global conf, got '$RUN_OUT' $RUN_ERR"

printf "CBOX_MODE=isolated\n" > "$PCONF"
_run _resolve_files
[ "$RUN_OUT" = "other|global" ] || _fail "a project conf without the key must fall through to the global conf, got '$RUN_OUT' $RUN_ERR"

printf "CBOX_PROFILE=work\n" > "$PCONF"
_cbox_effective_mode() { printf 'global'; }
_run _resolve_in_proj
[ "$RUN_OUT" = "other|global" ] || _fail "a project conf must be ignored when the effective mode is global, got '$RUN_OUT' $RUN_ERR"
_cbox_effective_mode() { printf 'isolated'; }

rm -f "$CONF"
_run _resolve_in_proj
[ "$RUN_OUT" = "work|project" ] || _fail "project conf without a global conf must still win, got '$RUN_OUT' $RUN_ERR"
_ok "precedence: flag > project conf > global conf > default, with the source reported; empty or missing keys fall through"

_run _resolve_files ghost
[ "$RUN_RC" -ne 0 ] || _fail "a flag naming an unknown profile must be an error"
case "$RUN_ERR" in *"does not exist"*ghost*|*ghost*"does not exist"*) ;; *) _fail "unknown flag profile message wrong: $RUN_ERR" ;; esac
printf "CBOX_PROFILE=ghost\n" > "$PCONF"
_run _resolve_files
[ "$RUN_RC" -ne 0 ] || _fail "a project conf naming an unknown profile must be an error"
case "$RUN_ERR" in *project*) ;; *) _fail "the error must name the project conf as the source: $RUN_ERR" ;; esac
printf "CBOX_PROFILE=work\n" > "$PCONF"
printf "CBOX_PROFILE=ghost\n" > "$CONF"
rm -f "$PCONF"
_run _resolve_files
[ "$RUN_RC" -ne 0 ] || _fail "a global conf naming an unknown profile must be an error"
case "$RUN_ERR" in *global*) ;; *) _fail "the error must name the global conf as the source: $RUN_ERR" ;; esac
printf "CBOX_PROFILE=Bad_Name\n" > "$CONF"
_run _resolve_files
[ "$RUN_RC" -ne 0 ] || _fail "a conf with an invalid profile name must be an error"
case "$RUN_ERR" in *"invalid profile name"*) ;; *) _fail "invalid conf value message wrong: $RUN_ERR" ;; esac
_run _resolve_files Bad_Name
[ "$RUN_RC" -ne 0 ] || _fail "an invalid flag value must be an error"
rm -f "$CONF"
_cbox_profile_resolve_from "" "" "" 1
[ "$CBOX_PROFILE_EFFECTIVE|$CBOX_PROFILE_SOURCE" = "default|default" ] || _fail "resolve_from with no inputs must give default|default"
if _cbox_profile_resolve_from ghost "" "" 1 2>/dev/null; then
  _fail "resolve_from must fail for an unknown flag profile"
fi
[ -z "$CBOX_PROFILE_EFFECTIVE" ] && [ -z "$CBOX_PROFILE_SOURCE" ] || _fail "a failed resolve must leave the result variables empty"
_cbox_profile_resolve_from ghost "" "" 0
[ "$CBOX_PROFILE_EFFECTIVE" = ghost ] || _fail "resolve_from with the existence check off must accept an unknown name"
_ok "resolver: unknown and invalid profile names are errors before any render, naming the source"

[ "$(_cbox_profile_store_dir work)" = "$STORE_ROOT/work" ] || _fail "store dir helper wrong"
if _cbox_profile_store_dir default >/dev/null 2>&1; then _fail "store dir of default must be refused"; fi
if _cbox_profile_store_dir "../x" >/dev/null 2>&1; then _fail "store dir of an invalid name must be refused"; fi
if _cbox_profile_eff_dir work >/dev/null 2>&1; then _fail "eff dir helper must refuse a missing project eff dir (no install dir fallback)"; fi
[ "$(_cbox_profile_eff_dir work "$PEFF")" = "$PEFF/profiles/work" ] || _fail "isolated eff dir helper wrong"
if _cbox_profile_eff_dir default >/dev/null 2>&1; then _fail "eff dir of default must be refused"; fi
[ "$(_cbox_profile_project_eff "$PROOT")" = "$PEFF" ] || _fail "project eff helper must match the hash layout"
_ok "path helpers: store dir, global and isolated eff dirs, project eff dir"

_run _cbox_profile_rm default --yes
[ "$RUN_RC" -ne 0 ] || _fail "rm default must be refused"
case "$RUN_ERR" in *reserved*) ;; *) _fail "rm default must say reserved: $RUN_ERR" ;; esac
_run _cbox_profile_rm ghost --yes
[ "$RUN_RC" -ne 0 ] || _fail "rm of an unknown profile must fail"
_run _cbox_profile_rm
[ "$RUN_RC" -ne 0 ] || _fail "rm without a name must be a usage error"
_run _cbox_profile_rm work --bogus
[ "$RUN_RC" -ne 0 ] || _fail "rm with an unknown option must be a usage error"
[ -d "$STORE_ROOT/work" ] || _fail "refused rms must keep the store"

printf "CBOX_PROFILE=work\n" > "$CONF"
_run _cbox_profile_rm work --yes
[ "$RUN_RC" -ne 0 ] || _fail "rm must refuse a profile named by the global conf"
case "$RUN_ERR" in *global*) ;; *) _fail "global refusal must name the global conf: $RUN_ERR" ;; esac
rm -f "$CONF"
printf "CBOX_PROFILE=work\n" > "$PCONF"
_rm_in_proj() { ( cd "$PROJ" && _cbox_profile_rm "$@" ); }
_run _rm_in_proj work --yes
[ "$RUN_RC" -ne 0 ] || _fail "rm must refuse a profile named by the current project conf"
case "$RUN_ERR" in *project*) ;; *) _fail "project refusal must name the project conf: $RUN_ERR" ;; esac
[ -d "$STORE_ROOT/work" ] || _fail "configured refusals must keep the store"
printf "CBOX_PROFILE=other\n" > "$PCONF"
_ok "rm refuses default, unknown names, usage errors and a profile configured in the global or project conf"

: > "$STUB_DOCKER_LOG"
STUB_DOCKER_PS="abc123def456"
export STUB_DOCKER_PS
_run _cbox_profile_rm work --yes
[ "$RUN_RC" -ne 0 ] || _fail "rm must refuse a profile with a running container"
case "$RUN_ERR" in *running*) ;; *) _fail "running refusal message wrong: $RUN_ERR" ;; esac
grep -qF 'ps -q --filter label=cbox.profile=work' "$STUB_DOCKER_LOG" || _fail "rm must ask docker for label cbox.profile=work, log: $(cat "$STUB_DOCKER_LOG")"
[ -d "$STORE_ROOT/work" ] || _fail "a running refusal must keep the store"
STUB_DOCKER_PS=""
STUB_DOCKER_RC=1
export STUB_DOCKER_PS STUB_DOCKER_RC
_run _cbox_profile_rm work --yes
[ "$RUN_RC" -ne 0 ] || _fail "rm must refuse when docker ps cannot be verified"
case "$RUN_ERR" in *"cannot verify"*) ;; *) _fail "unverifiable docker message wrong: $RUN_ERR" ;; esac
STUB_DOCKER_RC=0
export STUB_DOCKER_RC
_ok "rm refuses a profile with a running container and when docker cannot be asked (docker stubbed)"

_run _cbox_profile_rm work
[ "$RUN_RC" -ne 0 ] || _fail "rm without --yes and without a TTY must refuse"
case "$RUN_ERR" in *"--yes"*) ;; *) _fail "no-TTY refusal must point at --yes: $RUN_ERR" ;; esac
[ -d "$STORE_ROOT/work" ] || _fail "a no-TTY refusal must keep the store"
_ok "rm without --yes and without a TTY refuses"

mkdir -p "$INSTALL_DIR/profiles/work/claude-config" "$INSTALL_DIR/profiles/other"
mkdir -p "$PEFF/profiles/work/claude-config" "$PEFF/profiles/other"
mkdir -p "$HOME/.config/cbox/projects/zzz999/profiles/work"
mkdir -p "$HOME/.config/cbox/projects/yyy888/profiles/keepme"
printf 'x\n' > "$INSTALL_DIR/profiles/work/claude-config/f"
printf 'x\n' > "$PEFF/profiles/work/claude-config/f"
_run _cbox_profile_rm work --yes
[ "$RUN_RC" -eq 0 ] || _fail "rm work --yes failed: $RUN_ERR"
[ ! -e "$STORE_ROOT/work" ] || _fail "rm must delete the store dir"
[ -d "$INSTALL_DIR/profiles/work" ] || _fail "rm must not touch the install dir profiles directory"
[ ! -e "$PEFF/profiles/work" ] || _fail "rm must delete the isolated eff dir"
[ ! -e "$HOME/.config/cbox/projects/zzz999/profiles/work" ] || _fail "rm must delete the eff dir in every project"
[ -d "$STORE_ROOT/other" ] || _fail "rm must not touch another profile's store"
[ -d "$INSTALL_DIR/profiles/other" ] || _fail "rm must not touch the install dir profiles of another profile"
[ -d "$PEFF/profiles/other" ] || _fail "rm must not touch another profile's isolated eff dir"
[ -d "$HOME/.config/cbox/projects/yyy888/profiles/keepme" ] || _fail "rm must not touch unrelated project profile dirs"
[ -f "$STORE_ROOT/other/profile.json" ] || _fail "rm must not touch another profile's files"
_run _cbox_profile_rm work --yes
[ "$RUN_RC" -ne 0 ] || _fail "removing the same profile twice must report it missing"
_ok "rm --yes deletes the store and every project eff dir of that profile only and never touches the install dir"

_cbox_config_in_container() { return 0; }
_run _cbox_profile_add third
[ "$RUN_RC" -ne 0 ] || _fail "add must be host-only"
case "$RUN_ERR" in *host-only*) ;; *) _fail "host-only message wrong: $RUN_ERR" ;; esac
[ ! -e "$STORE_ROOT/third" ] || _fail "host-only refusal must not create anything"
_run _cbox_profile_rm other --yes
[ "$RUN_RC" -ne 0 ] || _fail "rm must be host-only"
[ -d "$STORE_ROOT/other" ] || _fail "host-only refusal must keep the store"
_cbox_config_in_container() { return 1; }
_ok "add and rm refuse inside the container"

SYM_HOME="$TMPBASE/symhome"
mkdir -p "$SYM_HOME/.config/cbox" "$TMPBASE/elsewhere"
ln -s "$TMPBASE/elsewhere" "$SYM_HOME/.config/cbox/profiles"
_symhome_add() { ( HOME="$SYM_HOME"; _cbox_profile_add evil ); }
_run _symhome_add
[ "$RUN_RC" -ne 0 ] || _fail "add must refuse a symlinked profiles root"
case "$RUN_ERR" in *symlink*) ;; *) _fail "symlink refusal message wrong: $RUN_ERR" ;; esac
[ -z "$(ls -A "$TMPBASE/elsewhere")" ] || _fail "a symlinked root must not be written through"
_symhome_list() { ( HOME="$SYM_HOME"; _cbox_profile_list ); }
_run _symhome_list
[ "$RUN_RC" -ne 0 ] || _fail "list must refuse a symlinked profiles root"
ln -s "$TMPBASE/elsewhere" "$STORE_ROOT/linked"
_run _cbox_profile_add linked
[ "$RUN_RC" -ne 0 ] || _fail "add must refuse a name that is a symlink"
_run _cbox_profile_list
printf '%s\n' "$RUN_OUT" | grep -q 'linked' && _fail "list must not show a symlinked store entry as a profile"
case "$RUN_ERR" in *linked*) ;; *) _fail "list must warn about the symlinked entry: $RUN_ERR" ;; esac
_run _cbox_profile_rm linked --yes
[ "$RUN_RC" -ne 0 ] || _fail "rm must refuse a symlinked store entry"
[ -d "$TMPBASE/elsewhere" ] || _fail "rm must never follow a symlink"
rm -f "$STORE_ROOT/linked"
_ok "store path guard: a symlinked root or entry is refused and never followed"

if [ "$(id -u)" = 0 ]; then
  chown 4242 "$STORE_ROOT/other"
  _run _cbox_profile_rm other --yes
  [ "$RUN_RC" -ne 0 ] || _fail "rm must refuse a store dir owned by another user"
  case "$RUN_ERR" in *"another user"*) ;; *) _fail "foreign owner message wrong: $RUN_ERR" ;; esac
  chown 0 "$STORE_ROOT/other"
  _ok "store path guard: a foreign owner is refused"
else
  _ok "store path guard: foreign owner check skipped (needs root to chown)"
fi

_cbox_profile_rmtree "/tmp/whatever/work" work && _fail "rmtree must refuse a path whose parent is not profiles"
_cbox_profile_rmtree "profiles/work" work && _fail "rmtree must refuse a relative path"
_cbox_profile_rmtree "$STORE_ROOT/other" work && _fail "rmtree must refuse a name mismatch"
_cbox_profile_rmtree "$STORE_ROOT/../profiles/other" other && _fail "rmtree must refuse dot-dot paths"
_cbox_profile_rmtree "$STORE_ROOT/default" default && _fail "rmtree must refuse the reserved name"
_cbox_profile_rmtree "$STORE_ROOT/" "" && _fail "rmtree must refuse an empty name"
[ -d "$STORE_ROOT/other" ] || _fail "refused rmtree calls must delete nothing"
_ok "rmtree only accepts validated literal profile paths"

PROJ_ROOT="$HOME/.config/cbox/projects"
mkdir -p "$TMPBASE/outside/profiles/work" "$PROJ_ROOT/real/profiles/work"
printf 'precious\n' > "$TMPBASE/outside/profiles/work/f"
ln -s "$TMPBASE/outside" "$PROJ_ROOT/linkmid"
_cbox_profile_rmtree "$PROJ_ROOT/linkmid/profiles/work" work 2>/dev/null && _fail "rmtree must refuse a path with a symlinked middle component"
[ -f "$TMPBASE/outside/profiles/work/f" ] || _fail "rmtree must not delete through a symlinked middle component"
unlink "$PROJ_ROOT/linkmid"
mkdir -p "$TMPBASE/outside2/profiles/other"
ln -s "$TMPBASE/outside2" "$PROJ_ROOT/linkmid2"
_run _cbox_profile_rm other --yes
[ "$RUN_RC" -ne 0 ] || _fail "rm must refuse when a project dir is a symlink holding the profile"
case "$RUN_ERR" in *symlink*) ;; *) _fail "the symlinked project dir refusal must say symlink, got: $RUN_ERR" ;; esac
[ -d "$TMPBASE/outside2/profiles/other" ] || _fail "rm must not follow a symlinked project dir"
[ -d "$STORE_ROOT/other" ] || _fail "a refused rm must keep the store"
unlink "$PROJ_ROOT/linkmid2"
_ok "rmtree and rm check every path component for symlinks and never delete through one"

mkdir -p "$PROJ_ROOT/a..b/profiles/work" "$PROJ_ROOT/real2/profiles/work"
printf 'x\n' > "$PROJ_ROOT/a..b/profiles/work/f"
_cbox_profile_rmtree "$PROJ_ROOT/a..b/profiles/work" work || _fail "rmtree must accept a directory name containing two dots"
[ ! -e "$PROJ_ROOT/a..b/profiles/work" ] || _fail "rmtree must delete a path whose segment merely contains two dots"
_cbox_profile_rmtree "$PROJ_ROOT/real2/../real2/profiles/work" work 2>/dev/null && _fail "rmtree must refuse a dot-dot segment"
_cbox_profile_rmtree "$PROJ_ROOT/real2/profiles/.." work 2>/dev/null && _fail "rmtree must refuse a trailing dot-dot segment"
[ -d "$PROJ_ROOT/real2/profiles/work" ] || _fail "refused dot-dot paths must delete nothing"
_cbox_profile_rmtree "$PROJ_ROOT/real2/profiles/work" work || _fail "rmtree must delete a clean real path"
[ ! -e "$PROJ_ROOT/real2/profiles/work" ] || _fail "rmtree left a clean real path behind"
_ok "rmtree rejects a dot-dot path segment but accepts a name containing two dots"

mkdir -p "$INSTALL_DIR/lib" "$TMPBASE/hv/eff/claude-config" "$TMPBASE/hv/store"
cp "$REAL_DIR/lib/cbox_profile_seed.py" "$INSTALL_DIR/lib/cbox_profile_seed.py"
printf '{"name":"p"}\n' > "$TMPBASE/hv/store/profile.json"
printf '{"oauthAccount":{"emailAddress":"v@example.test","accessToken":"SECRET-TOKEN"}}\n' > "$TMPBASE/hv/real-state.json"
ln -s "$TMPBASE/hv/real-state.json" "$TMPBASE/hv/eff/claude-config/.claude.json"
_cbox_profile_harvest "$TMPBASE/hv/eff" "$TMPBASE/hv/store"
grep -q 'engines' "$TMPBASE/hv/store/profile.json" && _fail "harvest must not follow a symlinked statedir json"
unlink "$TMPBASE/hv/eff/claude-config/.claude.json"
cp "$TMPBASE/hv/real-state.json" "$TMPBASE/hv/eff/claude-config/.claude.json"
_cbox_profile_harvest "$TMPBASE/hv/eff" "$TMPBASE/hv/store"
grep -q 'v@example.test' "$TMPBASE/hv/store/profile.json" || _fail "harvest must record the allowlisted account fields"
grep -q 'SECRET-TOKEN' "$TMPBASE/hv/store/profile.json" && _fail "harvest must drop non-allowlisted account fields"
_ok "harvest: a symlinked statedir json is ignored; only allowlisted account fields are stored"

_render_global() {
  local dir="$1" extra_env="${2:-}" ws
  ws="${dir}-ws"
  mkdir -p "$dir/generated/state" "$dir/generated/claude-config" "$ws"
  : > "$dir/image.inputs"
  (
    set -e
    INSTALL_DIR="$dir"
    HOME="$dir/home"
    mkdir -p "$HOME"
    export CBOX_CLAUDE_MODE=volume CBOX_CODEX_MODE=volume CBOX_WORKSPACES="$ws"
    if [ -n "$extra_env" ]; then eval "$extra_env"; fi
    gen_compose
  )
}

_render_isolated() {
  local dir="$1" extra_env="${2:-}"
  mkdir -p "$dir/eff" "$dir/root" "$dir/home"
  (
    set -e
    HOME="$dir/home"
    export CBOX_CLAUDE_MODE=volume CBOX_CODEX_MODE=volume
    if [ -n "$extra_env" ]; then eval "$extra_env"; fi
    gen_compose_isolated "$dir/eff" "$dir/root" "cbox-img:test" "abcdef123456"
  )
}

_render_global "$TMPBASE/g_default" >/dev/null 2>&1
[ "$(grep -cxF '      - CBOX_PROFILE=default' "$TMPBASE/g_default/docker-compose.yml")" -eq 1 ] \
  || _fail "global default compose must carry exactly one CBOX_PROFILE=default line"
[ "$(grep -c 'CBOX_PROFILE' "$TMPBASE/g_default/docker-compose.yml")" -eq 1 ] \
  || _fail "global default compose must mention CBOX_PROFILE exactly once"
grep -A1 -xF '      - CBOX_SESSION_MULTIPLEX=off' "$TMPBASE/g_default/docker-compose.yml" | grep -qxF '      - CBOX_PROFILE=default' \
  || _fail "the CBOX_PROFILE line must directly follow CBOX_SESSION_MULTIPLEX"
_render_isolated "$TMPBASE/i_default" >/dev/null 2>&1
[ "$(grep -cxF '      - CBOX_PROFILE=default' "$TMPBASE/i_default/eff/docker-compose.yml")" -eq 1 ] \
  || _fail "isolated default compose must carry exactly one CBOX_PROFILE=default line"
[ "$(grep -c 'CBOX_PROFILE' "$TMPBASE/i_default/eff/docker-compose.yml")" -eq 1 ] \
  || _fail "isolated default compose must mention CBOX_PROFILE exactly once"
_ok "compose: default renders (global and isolated) carry exactly one CBOX_PROFILE=default env line"

_render_global "$TMPBASE/g_conf" 'export CBOX_PROFILE=work' >/dev/null 2>&1
grep -qxF '      - CBOX_PROFILE=default' "$TMPBASE/g_conf/docker-compose.yml" \
  || _fail "the conf default profile must not change what the default-profile container reports"
if _render_global "$TMPBASE/g_work" 'export CBOX_RENDER_PROFILE=work' >/dev/null 2>&1; then
  _fail "a global render must refuse a non-default profile"
fi
if _render_isolated "$TMPBASE/i_work" 'export CBOX_RENDER_PROFILE=work' >/dev/null 2>&1; then
  _fail "a volume mode isolated render must refuse a non-default profile"
fi
if _render_global "$TMPBASE/g_bad" 'export CBOX_RENDER_PROFILE="x
  - evil=1"' >/dev/null 2>&1; then
  _fail "an invalid CBOX_RENDER_PROFILE must fail the render"
fi
if _render_isolated "$TMPBASE/i_bad" 'export CBOX_RENDER_PROFILE=Bad' >/dev/null 2>&1; then
  _fail "an invalid CBOX_RENDER_PROFILE must fail the isolated render"
fi
_ok "compose: non-default profiles are refused in global and volume renders and an invalid name fails the render"

python3 - "$REAL_DIR/etc/registry/settings.json" <<'PY' || _fail "registry entry for CBOX_PROFILE is wrong"
import json, sys
d = json.load(open(sys.argv[1]))
v = [x for x in d["variables"] if x["key"] == "CBOX_PROFILE"]
assert len(v) == 1, v
v = v[0]
assert v["section"] == "mode", v
assert v["default"] == "default", v
assert v["prompt"] is None, v
assert v["role"] == "setting", v
assert v["export"] is False, v
assert v["validator"] == "profile-name", v
assert "profile" in d["doctor_extra_rows"], d["doctor_extra_rows"]
sec = [s for s in d["sections"] if s["id"] == "mode"][0]
assert sec["scope"] == "project", sec
PY
. "$REAL_DIR/templates/sections.sh"
case " $(sec_get SEC_VARS mode) " in *" CBOX_PROFILE "*) ;; *) _fail "sections.sh must list CBOX_PROFILE in the mode section" ;; esac
case " $DOCTOR_EXTRA_ROWS " in *" profile "*) ;; *) _fail "sections.sh must list the profile doctor row" ;; esac
grep -qF '_cbox_doctor_row "profile"' "$REAL_DIR/cbox" || _fail "doctor() must carry a literal _cbox_doctor_row \"profile\""
grep -q 'CBOX_PROFILE=%q' "$REAL_DIR/templates/conf_lib.sh" || _fail "conf_lib.sh must persist CBOX_PROFILE"
grep -qF ': "${CBOX_PROFILE=default}"' "$REAL_DIR/templates/conf_lib.sh" || _fail "conf_lib.sh must default CBOX_PROFILE to default"
_ok "registry: CBOX_PROFILE is a project-scoped mode-section setting with no wizard prompt, regenerated into sections.sh and conf_lib.sh, with a profile doctor row"

for good in default work a1; do
  _cbox_reg_validate_var CBOX_PROFILE "$good" >/dev/null || _fail "config validator: CBOX_PROFILE=$good must be accepted"
done
for bad in "" Work 1a a_b "$LONG33" "../x" "$(printf 'a\nb')"; do
  if _cbox_reg_validate_var CBOX_PROFILE "$bad" >/dev/null 2>&1; then
    _fail "config validator: CBOX_PROFILE='$bad' must be rejected"
  fi
done
_ok "config validator: CBOX_PROFILE accepts valid names and rejects the rest"

_dispatch() {
  ( cd "$PROJ" && HOME="$TMPBASE/disphome" bash "$REAL_DIR/cbox" profile "$@" )
}
mkdir -p "$TMPBASE/disphome"
_run _dispatch ls
[ "$RUN_RC" -eq 0 ] || _fail "cbox profile ls through the real dispatch failed: rc=$RUN_RC $RUN_ERR"
printf '%s\n' "$RUN_OUT" | grep -Eq '^[* ] default ' || _fail "dispatch ls must list default, got: $RUN_OUT"
_run _dispatch add dispatched
if [ "$RUN_RC" -eq 0 ]; then
  [ -f "$TMPBASE/disphome/.config/cbox/profiles/dispatched/profile.json" ] || _fail "dispatch add must create the store"
  _run _dispatch list
  printf '%s\n' "$RUN_OUT" | grep -Eq '^[* ] dispatched ' || _fail "dispatch list must show the new profile, got: $RUN_OUT"
else
  case "$RUN_ERR" in *host-only*) ;; *) _fail "dispatch add failed for an unexpected reason: rc=$RUN_RC $RUN_ERR" ;; esac
fi
_run _dispatch add Bad_Name
[ "$RUN_RC" -ne 0 ] || _fail "dispatch add of an invalid name must fail"
case "$RUN_ERR" in *"invalid profile name"*) ;; *) _fail "dispatch must surface the validation error: $RUN_ERR" ;; esac
_run _dispatch bogus
[ "$RUN_RC" -ne 0 ] || _fail "an unknown profile verb must fail"
_run _dispatch add default
[ "$RUN_RC" -ne 0 ] || _fail "dispatch add default must fail"
_ok "the real cbox dispatch routes profile add, list, ls and refuses bad verbs"

echo "PASS: all profile tests"
