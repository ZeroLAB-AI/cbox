#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

unset CBOX_CLAUDE_TARGET CBOX_CODEX_VERSION CBOX_CODEX_TARGET CBOX_HERMES CBOX_HERMES_VERSION \
  CBOX_INSTALL_FORCE CBOX_INSTALL_MODE CBOX_AUTOUPDATE CBOX_AUTOUPDATE_TTL_HOURS CBOX_BINS_SCOPE CBOX_BINS_HEALTH_GATE \
  CBOX_ROLLBACK_REASON CBOX_ROLLBACK_PREV_CLAUDE CBOX_ROLLBACK_PREV_CODEX CBOX_ROLLBACK_PREV_HERMES

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

_extract_fn() {
  awk -v fn="$2" '$0 == fn"() {" , $0 == "}"' "$1"
}

IB="$INSTALL_DIR/install-bins.sh"
RESOLVEBIN_FN="$(_extract_fn "$IB" _resolve_bin)"
RESOLVETOOLBIN_FN="$(_extract_fn "$IB" _resolve_tool_bin)"
BINHASH_FN="$(_extract_fn "$IB" _bin_hash)"
TOOLHASH_FN="$(_extract_fn "$IB" _tool_hash)"
LINKFOR_FN="$(_extract_fn "$IB" _link_for)"
STAMPPATH_FN="$(_extract_fn "$IB" _stamp_path)"
STAMPFIELD_FN="$(_extract_fn "$IB" _stamp_field)"
WANTCOMPAT_FN="$(_extract_fn "$IB" _want_compat)"
STAMPWRITE_FN="$(_extract_fn "$IB" _stamp_write)"
WANTSTRING_FN="$(_extract_fn "$IB" _want_string)"
VERSIONOK_FN="$(_extract_fn "$IB" _version_ok)"
VERIFYTOOL_FN="$(_extract_fn "$IB" _verify_tool)"
PREVROOT_FN="$(_extract_fn "$IB" _prev_root)"
PREVROOTRECOVER_FN="$(_extract_fn "$IB" _prev_root_recover)"
PREVMARKER_FN="$(_extract_fn "$IB" _prev_marker)"
PREVISREALDIR_FN="$(_extract_fn "$IB" _prev_is_real_dir)"
PREVTAKE_FN="$(_extract_fn "$IB" _prev_take)"
PREVCLAUDEZEROCOPY_FN="$(_extract_fn "$IB" _prev_claude_zero_copy)"
PREVRESTOREFALLBACK_FN="$(_extract_fn "$IB" _prev_restore_fallback)"
PREVRESTOREGENERIC_FN="$(_extract_fn "$IB" _prev_restore_generic)"
PREVRESTORE_FN="$(_extract_fn "$IB" _prev_restore)"
MAIN_FN="$(_extract_fn "$IB" main)"

for _fn in RESOLVEBIN_FN RESOLVETOOLBIN_FN BINHASH_FN TOOLHASH_FN LINKFOR_FN STAMPPATH_FN STAMPFIELD_FN \
  WANTCOMPAT_FN STAMPWRITE_FN WANTSTRING_FN VERSIONOK_FN VERIFYTOOL_FN PREVROOT_FN PREVMARKER_FN \
  PREVISREALDIR_FN PREVROOTRECOVER_FN PREVTAKE_FN PREVCLAUDEZEROCOPY_FN PREVRESTOREFALLBACK_FN PREVRESTOREGENERIC_FN \
  PREVRESTORE_FN MAIN_FN; do
  [ -n "${!_fn}" ] || _fail "cannot extract install-bins function for $_fn"
done

_COMMON_PREAMBLE='
HXROOT=""
_gosu() { "$@"; }
_parsed_version() {
  local n="$1" p="$2"
  case "$p" in
    *"/versions/1.0.0/"*) printf "1.0.0" ;;
    *"/versions/2.0.0/"*) printf "2.0.0" ;;
    *"/releases/1.0.0-hash/"*) printf "1.0.0" ;;
    *"/releases/2.0.0-hash/"*) printf "2.0.0" ;;
    *"/versions/9.9.9/"*) printf "9.9.9" ;;
    *) return 1 ;;
  esac
}
'

_make_elf() {
  printf '\177ELF' > "$1"
  printf '%s\n' "$2" >> "$1"
  chmod +x "$1"
}

echo "--- claude: _prev_take/_prev_restore round trip through the versions/<v> symlink chain ---"
HOME1="$TMPBASE/rt-claude"
CLROOT="$HOME1/.local"
mkdir -p "$CLROOT/versions/1.0.0" "$CLROOT/bin"
_make_elf "$CLROOT/versions/1.0.0/claude" v1-body
ln -s "$CLROOT/versions/1.0.0/claude" "$CLROOT/bin/claude"
HASH1="$(sha256sum "$CLROOT/versions/1.0.0/claude" | awk '{print $1}')"
printf 'stable\n%s\n%s\n1.0.0\n' "$CLROOT/versions/1.0.0/claude" "$HASH1" > "$CLROOT/.cbox-stamp"

HOST_HOME="$HOME1" CLROOT="$CLROOT" CBOX_CLAUDE_TARGET=stable bash -c '
  set -u
  '"$_COMMON_PREAMBLE"'
  '"$RESOLVEBIN_FN"'
  '"$RESOLVETOOLBIN_FN"'
  '"$BINHASH_FN"'
  '"$TOOLHASH_FN"'
  '"$LINKFOR_FN"'
  '"$STAMPPATH_FN"'
  '"$STAMPFIELD_FN"'
  '"$PREVROOT_FN"'
  '"$PREVROOTRECOVER_FN"'
  '"$PREVMARKER_FN"'
  '"$PREVISREALDIR_FN"'
  '"$PREVTAKE_FN"'
  _prev_take claude
' >"$TMPBASE/rt-claude-take.out" 2>"$TMPBASE/rt-claude-take.err" \
  || _fail "claude: _prev_take must succeed: $(cat "$TMPBASE/rt-claude-take.err")"
[ -f "$CLROOT/.cbox-prev/payload" ] || _fail "claude: _prev_take must leave a payload file behind"
cmp -s "$CLROOT/.cbox-prev/payload" "$CLROOT/versions/1.0.0/claude" \
  || _fail "claude: the backed-up payload must be byte-identical to the resolved ELF"
[ -f "$CLROOT/.cbox-prev/.cbox-backup-complete" ] || _fail "claude: _prev_take must write the completion marker"
cmp -s "$CLROOT/.cbox-prev/.cbox-stamp" "$CLROOT/.cbox-stamp" \
  || _fail "claude: _prev_take must copy the pre-install stamp verbatim"

mkdir -p "$CLROOT/versions/2.0.0"
_make_elf "$CLROOT/versions/2.0.0/claude" v2-body
ln -sfn "$CLROOT/versions/2.0.0/claude" "$CLROOT/bin/claude"
HASH2="$(sha256sum "$CLROOT/versions/2.0.0/claude" | awk '{print $1}')"
printf 'stable\n%s\n%s\n2.0.0\n' "$CLROOT/versions/2.0.0/claude" "$HASH2" > "$CLROOT/.cbox-stamp"

RESTORE_OUT="$(HOST_HOME="$HOME1" CLROOT="$CLROOT" CBOX_CLAUDE_TARGET=stable bash -c '
  set -u
  '"$_COMMON_PREAMBLE"'
  '"$RESOLVEBIN_FN"'
  '"$RESOLVETOOLBIN_FN"'
  '"$BINHASH_FN"'
  '"$TOOLHASH_FN"'
  '"$LINKFOR_FN"'
  '"$STAMPPATH_FN"'
  '"$STAMPFIELD_FN"'
  '"$WANTCOMPAT_FN"'
  '"$STAMPWRITE_FN"'
  '"$WANTSTRING_FN"'
  '"$PREVROOT_FN"'
  '"$PREVROOTRECOVER_FN"'
  '"$PREVMARKER_FN"'
  '"$PREVISREALDIR_FN"'
  '"$PREVCLAUDEZEROCOPY_FN"'
  '"$PREVRESTOREFALLBACK_FN"'
  '"$PREVRESTOREGENERIC_FN"'
  '"$PREVRESTORE_FN"'
  _prev_restore claude
')" || _fail "claude: _prev_restore must succeed"
printf '%s\n' "$RESTORE_OUT" | grep -Eq '^cbox-bins: claude 1\.0\.0 '"$HASH1"' rollback 2\.0\.0 manual$' \
  || _fail "claude: rollback output line malformed: $RESTORE_OUT"
[ "$(readlink -f "$CLROOT/bin/claude")" = "$CLROOT/versions/1.0.0/claude" ] \
  || _fail "claude: the live symlink must resolve back to the v1 binary after rollback"
[ "$(sed -n '1p' "$CLROOT/.cbox-stamp")" = stable ] || _fail "claude: stamp want must stay unchanged (channel never moves on rollback)"
[ "$(sed -n '2p' "$CLROOT/.cbox-stamp")" = "$CLROOT/versions/1.0.0/claude" ] || _fail "claude: stamp path must be the restored v1 path"
[ "$(sed -n '3p' "$CLROOT/.cbox-stamp")" = "$HASH1" ] || _fail "claude: stamp hash must be the restored v1 hash"
[ "$(sed -n '4p' "$CLROOT/.cbox-stamp")" = 1.0.0 ] || _fail "claude: stamp version must be the restored v1 version"
_ok "claude: _prev_take/_prev_restore round trip restores the versions/<v> symlink chain and rewrites only path/hash/version, not want"

echo "--- codex: _prev_take/_prev_restore round trip through standalone/current -> releases/<v> ---"
HOME2="$TMPBASE/rt-codex"
CLROOT2="$HOME2/.local"
CXPKG="$HOME2/.codex/packages"
mkdir -p "$CLROOT2/bin" "$CXPKG/standalone/releases/1.0.0-hash/bin" "$CXPKG/standalone/releases/1.0.0-hash/lib"
_make_elf "$CXPKG/standalone/releases/1.0.0-hash/bin/codex" codex-v1-body
printf 'v1-asset\n' > "$CXPKG/standalone/releases/1.0.0-hash/lib/asset.txt"
ln -s "$CXPKG/standalone/releases/1.0.0-hash" "$CXPKG/standalone/current"
ln -s "$CXPKG/standalone/current/bin/codex" "$CLROOT2/bin/codex"
CHASH1="$(sha256sum "$CXPKG/standalone/releases/1.0.0-hash/bin/codex" | awk '{print $1}')"
CODEXPATH1="$CXPKG/standalone/releases/1.0.0-hash/bin/codex"
printf 'latest\n%s\n%s\n1.0.0\n' "$CODEXPATH1" "$CHASH1" > "$CXPKG/.cbox-stamp"

HOST_HOME="$HOME2" CLROOT="$CLROOT2" CXPKG="$CXPKG" CBOX_CODEX_VERSION=latest bash -c '
  set -u
  '"$_COMMON_PREAMBLE"'
  '"$RESOLVEBIN_FN"'
  '"$RESOLVETOOLBIN_FN"'
  '"$BINHASH_FN"'
  '"$TOOLHASH_FN"'
  '"$LINKFOR_FN"'
  '"$STAMPPATH_FN"'
  '"$STAMPFIELD_FN"'
  '"$PREVROOT_FN"'
  '"$PREVROOTRECOVER_FN"'
  '"$PREVMARKER_FN"'
  '"$PREVISREALDIR_FN"'
  '"$PREVTAKE_FN"'
  _prev_take codex
' >"$TMPBASE/rt-codex-take.out" 2>"$TMPBASE/rt-codex-take.err" \
  || _fail "codex: _prev_take must succeed: $(cat "$TMPBASE/rt-codex-take.err")"
[ -d "$CXPKG/.cbox-prev/payload" ] || _fail "codex: _prev_take must back up the whole release directory"
cmp -s "$CXPKG/.cbox-prev/payload/bin/codex" "$CODEXPATH1" || _fail "codex: backed-up release dir must contain the original binary"
cmp -s "$CXPKG/.cbox-prev/payload/lib/asset.txt" "$CXPKG/standalone/releases/1.0.0-hash/lib/asset.txt" \
  || _fail "codex: backed-up release dir must contain non-binary release assets too"
[ -f "$CXPKG/.cbox-prev/.cbox-backup-complete" ] || _fail "codex: _prev_take must write the completion marker"

mkdir -p "$CXPKG/standalone/releases/2.0.0-hash/bin"
_make_elf "$CXPKG/standalone/releases/2.0.0-hash/bin/codex" codex-v2-body
ln -sfn "$CXPKG/standalone/releases/2.0.0-hash" "$CXPKG/standalone/current"
CHASH2="$(sha256sum "$CXPKG/standalone/releases/2.0.0-hash/bin/codex" | awk '{print $1}')"
printf 'latest\n%s\n%s\n2.0.0\n' "$CXPKG/standalone/releases/2.0.0-hash/bin/codex" "$CHASH2" > "$CXPKG/.cbox-stamp"

RESTORE_OUT2="$(HOST_HOME="$HOME2" CLROOT="$CLROOT2" CXPKG="$CXPKG" CBOX_CODEX_VERSION=latest bash -c '
  set -u
  '"$_COMMON_PREAMBLE"'
  '"$RESOLVEBIN_FN"'
  '"$RESOLVETOOLBIN_FN"'
  '"$BINHASH_FN"'
  '"$TOOLHASH_FN"'
  '"$LINKFOR_FN"'
  '"$STAMPPATH_FN"'
  '"$STAMPFIELD_FN"'
  '"$WANTCOMPAT_FN"'
  '"$STAMPWRITE_FN"'
  '"$WANTSTRING_FN"'
  '"$PREVROOT_FN"'
  '"$PREVROOTRECOVER_FN"'
  '"$PREVMARKER_FN"'
  '"$PREVISREALDIR_FN"'
  '"$PREVCLAUDEZEROCOPY_FN"'
  '"$PREVRESTOREFALLBACK_FN"'
  '"$PREVRESTOREGENERIC_FN"'
  '"$PREVRESTORE_FN"'
  _prev_restore codex
')" || _fail "codex: _prev_restore must succeed"
printf '%s\n' "$RESTORE_OUT2" | grep -Eq '^cbox-bins: codex 1\.0\.0 '"$CHASH1"' rollback 2\.0\.0 manual$' \
  || _fail "codex: rollback output line malformed: $RESTORE_OUT2"
[ "$(readlink -f "$CLROOT2/bin/codex")" = "$CODEXPATH1" ] \
  || _fail "codex: the live symlink chain must resolve back to the v1 release after rollback"
[ "$(readlink -f "$CXPKG/standalone/current")" = "$CXPKG/standalone/releases/1.0.0-hash" ] \
  || _fail "codex: standalone/current must be re-pointed at the restored release directory"
[ "$(sed -n '1p' "$CXPKG/.cbox-stamp")" = latest ] || _fail "codex: stamp want must stay unchanged"
[ "$(sed -n '4p' "$CXPKG/.cbox-stamp")" = 1.0.0 ] || _fail "codex: stamp version must be the restored v1 version"
_ok "codex: _prev_take/_prev_restore round trip backs up and restores the whole release directory and re-points standalone/current"

echo "--- claude: a .cbox-prev with no completion marker refuses the disk restore and falls back (no history to fall back to) ---"
HOME3="$TMPBASE/nomarker"
CLROOT3="$HOME3/.local"
mkdir -p "$CLROOT3/versions/2.0.0" "$CLROOT3/bin" "$CLROOT3/.cbox-prev"
_make_elf "$CLROOT3/versions/2.0.0/claude" v2-body
ln -s "$CLROOT3/versions/2.0.0/claude" "$CLROOT3/bin/claude"
printf 'orphan\n' > "$CLROOT3/.cbox-prev/orphan.txt"
rc=0
OUT3="$(HOST_HOME="$HOME3" CLROOT="$CLROOT3" CBOX_CLAUDE_TARGET=stable bash -c '
  set -u
  '"$_COMMON_PREAMBLE"'
  '"$RESOLVEBIN_FN"'
  '"$RESOLVETOOLBIN_FN"'
  '"$BINHASH_FN"'
  '"$TOOLHASH_FN"'
  '"$LINKFOR_FN"'
  '"$STAMPPATH_FN"'
  '"$STAMPFIELD_FN"'
  '"$PREVROOT_FN"'
  '"$PREVROOTRECOVER_FN"'
  '"$PREVMARKER_FN"'
  '"$PREVISREALDIR_FN"'
  '"$PREVCLAUDEZEROCOPY_FN"'
  '"$PREVRESTOREFALLBACK_FN"'
  '"$PREVRESTOREGENERIC_FN"'
  '"$PREVRESTORE_FN"'
  _prev_restore claude
')" 2>"$TMPBASE/nomarker.err" || rc=$?
[ "$rc" != 0 ] || _fail "claude: restore with no completion marker and no fallback version must fail"
printf '%s\n' "$OUT3" | grep -Eq '^cbox-bins: claude 2\.0\.0 - unhealthy no-history$' \
  || _fail "claude: unhealthy no-history line malformed: $OUT3"
[ -f "$CLROOT3/.cbox-prev/orphan.txt" ] || _fail "claude: the unmarked backup fragment must be left in place, not wiped"
_ok "claude: a .cbox-prev with no completion marker refuses the disk restore and reports unhealthy/no-history when there is no fallback version"

echo "--- claude: a symlinked .cbox-prev is refused outright, never followed ---"
HOME4="$TMPBASE/symlinked"
CLROOT4="$HOME4/.local"
mkdir -p "$CLROOT4/versions/2.0.0" "$CLROOT4/bin"
_make_elf "$CLROOT4/versions/2.0.0/claude" v2-body
ln -s "$CLROOT4/versions/2.0.0/claude" "$CLROOT4/bin/claude"
OUTSIDE4="$TMPBASE/symlinked/outside"
mkdir -p "$OUTSIDE4"
printf 'must-not-be-touched\n' > "$OUTSIDE4/sentinel.txt"
ln -s "$OUTSIDE4" "$CLROOT4/.cbox-prev"
rc=0
OUT4="$(HOST_HOME="$HOME4" CLROOT="$CLROOT4" CBOX_CLAUDE_TARGET=stable bash -c '
  set -u
  '"$_COMMON_PREAMBLE"'
  '"$RESOLVEBIN_FN"'
  '"$RESOLVETOOLBIN_FN"'
  '"$BINHASH_FN"'
  '"$TOOLHASH_FN"'
  '"$LINKFOR_FN"'
  '"$STAMPPATH_FN"'
  '"$STAMPFIELD_FN"'
  '"$PREVROOT_FN"'
  '"$PREVROOTRECOVER_FN"'
  '"$PREVMARKER_FN"'
  '"$PREVISREALDIR_FN"'
  '"$PREVCLAUDEZEROCOPY_FN"'
  '"$PREVRESTOREFALLBACK_FN"'
  '"$PREVRESTOREGENERIC_FN"'
  '"$PREVRESTORE_FN"'
  _prev_restore claude
')" 2>"$TMPBASE/symlinked.err" || rc=$?
[ "$rc" != 0 ] || _fail "claude: restore must refuse a symlinked .cbox-prev"
[ -L "$CLROOT4/.cbox-prev" ] || _fail "claude: the symlink itself must be left in place for inspection"
[ "$(cat "$OUTSIDE4/sentinel.txt")" = "must-not-be-touched" ] || _fail "claude: the symlink target must never be modified"
_ok "claude: a symlinked .cbox-prev is refused outright and never followed"

echo "--- claude: CBOX_INSTALL_MODE=rollback via main() restores from disk without ever invoking the vendor installer ---"
HOME5="$TMPBASE/rollback-mode"
CLROOT5="$HOME5/.local"
mkdir -p "$CLROOT5/versions/1.0.0" "$CLROOT5/versions/2.0.0" "$CLROOT5/bin"
_make_elf "$CLROOT5/versions/1.0.0/claude" v1-body
_make_elf "$CLROOT5/versions/2.0.0/claude" v2-body
ln -s "$CLROOT5/versions/2.0.0/claude" "$CLROOT5/bin/claude"
HASH1_5="$(sha256sum "$CLROOT5/versions/1.0.0/claude" | awk '{print $1}')"
HASH2_5="$(sha256sum "$CLROOT5/versions/2.0.0/claude" | awk '{print $1}')"
mkdir -p "$CLROOT5/.cbox-prev"
cp -p "$CLROOT5/versions/1.0.0/claude" "$CLROOT5/.cbox-prev/payload"
printf 'stable\n%s\n%s\n1.0.0\n' "$CLROOT5/versions/1.0.0/claude" "$HASH1_5" > "$CLROOT5/.cbox-prev/.cbox-stamp"
: > "$CLROOT5/.cbox-prev/.cbox-backup-complete"
printf 'stable\n%s\n%s\n2.0.0\n' "$CLROOT5/versions/2.0.0/claude" "$HASH2_5" > "$CLROOT5/.cbox-stamp"

rc=0
OUT5="$(HOST_HOME="$HOME5" CLROOT="$CLROOT5" CBOX_CLAUDE_TARGET=stable CBOX_INSTALL_MODE=rollback CBOX_INSTALL_TOOLS=claude bash -c '
  set -u
  '"$_COMMON_PREAMBLE"'
  '"$RESOLVEBIN_FN"'
  '"$RESOLVETOOLBIN_FN"'
  '"$BINHASH_FN"'
  '"$TOOLHASH_FN"'
  '"$LINKFOR_FN"'
  '"$STAMPPATH_FN"'
  '"$STAMPFIELD_FN"'
  '"$WANTCOMPAT_FN"'
  '"$STAMPWRITE_FN"'
  '"$WANTSTRING_FN"'
  '"$PREVROOT_FN"'
  '"$PREVROOTRECOVER_FN"'
  '"$PREVMARKER_FN"'
  '"$PREVISREALDIR_FN"'
  '"$PREVCLAUDEZEROCOPY_FN"'
  '"$PREVRESTOREFALLBACK_FN"'
  '"$PREVRESTOREGENERIC_FN"'
  '"$PREVRESTORE_FN"'
  '"$MAIN_FN"'
  _run_claude_install() { : > "'"$TMPBASE"'/vendor-called"; return 1; }
  _run_codex_install() { : > "'"$TMPBASE"'/vendor-called"; return 1; }
  _run_hermes_install() { : > "'"$TMPBASE"'/vendor-called"; return 1; }
  main
')" 2>"$TMPBASE/rollback-mode.err" || rc=$?
[ "$rc" = 0 ] || _fail "claude: rollback-mode main() must succeed: $(cat "$TMPBASE/rollback-mode.err")"
[ -f "$TMPBASE/vendor-called" ] && _fail "claude: rollback mode must never invoke a vendor installer"
printf '%s\n' "$OUT5" | grep -Eq '^cbox-bins: claude 1\.0\.0 '"$HASH1_5"' rollback 2\.0\.0 manual$' \
  || _fail "claude: rollback-mode output line malformed: $OUT5"
[ "$(readlink -f "$CLROOT5/bin/claude")" = "$CLROOT5/versions/1.0.0/claude" ] \
  || _fail "claude: rollback mode must restore the symlink to the backed-up version"
_ok "claude: CBOX_INSTALL_MODE=rollback restores entirely offline through main(), the vendor installer is never called"

echo "--- claude: the network fallback [G4] reinstalls the exact previous version when the local backup has nothing to offer ---"
HOME6="$TMPBASE/fallback-network"
CLROOT6="$HOME6/.local"
mkdir -p "$CLROOT6/versions/2.0.0" "$CLROOT6/bin"
_make_elf "$CLROOT6/versions/2.0.0/claude" v2-body
ln -s "$CLROOT6/versions/2.0.0/claude" "$CLROOT6/bin/claude"

rc=0
OUT6="$(HOST_HOME="$HOME6" CLROOT="$CLROOT6" CBOX_CLAUDE_TARGET=stable CBOX_ROLLBACK_PREV_CLAUDE=9.9.9 bash -c '
  set -u
  '"$_COMMON_PREAMBLE"'
  '"$RESOLVEBIN_FN"'
  '"$RESOLVETOOLBIN_FN"'
  '"$BINHASH_FN"'
  '"$TOOLHASH_FN"'
  '"$LINKFOR_FN"'
  '"$STAMPPATH_FN"'
  '"$STAMPFIELD_FN"'
  '"$WANTCOMPAT_FN"'
  '"$STAMPWRITE_FN"'
  '"$WANTSTRING_FN"'
  '"$VERSIONOK_FN"'
  '"$VERIFYTOOL_FN"'
  '"$PREVROOT_FN"'
  '"$PREVROOTRECOVER_FN"'
  '"$PREVMARKER_FN"'
  '"$PREVISREALDIR_FN"'
  '"$PREVCLAUDEZEROCOPY_FN"'
  '"$PREVRESTOREFALLBACK_FN"'
  '"$PREVRESTOREGENERIC_FN"'
  '"$PREVRESTORE_FN"'
  _run_claude_install() {
    printf "CBOX_CLAUDE_TARGET=%s\n" "$CBOX_CLAUDE_TARGET" > "'"$TMPBASE"'/fallback-pin-seen"
    mkdir -p "$CLROOT/versions/$CBOX_CLAUDE_TARGET"
    printf "\177ELF" > "$CLROOT/versions/$CBOX_CLAUDE_TARGET/claude"
    printf "fallback-body\n" >> "$CLROOT/versions/$CBOX_CLAUDE_TARGET/claude"
    chmod +x "$CLROOT/versions/$CBOX_CLAUDE_TARGET/claude"
    ln -sfn "$CLROOT/versions/$CBOX_CLAUDE_TARGET/claude" "$CLROOT/bin/claude"
    return 0
  }
  _prev_restore claude
')" 2>"$TMPBASE/fallback-network.err" || rc=$?
[ "$rc" = 0 ] || _fail "claude: network fallback must succeed: $(cat "$TMPBASE/fallback-network.err")"
[ "$(cat "$TMPBASE/fallback-pin-seen" 2>/dev/null)" = "CBOX_CLAUDE_TARGET=9.9.9" ] \
  || _fail "claude: the network fallback must reinstall pinned to the exact previous version from history, not the channel"
printf '%s\n' "$OUT6" | grep -Eq '^cbox-bins: claude 9\.9\.9 [0-9a-f]+ rollback 2\.0\.0 network-fallback$' \
  || _fail "claude: network-fallback rollback output line malformed: $OUT6"
[ "$(sed -n '1p' "$CLROOT6/.cbox-stamp")" = stable ] || _fail "claude: network fallback must still write want as the current channel, unchanged"
_ok "claude: network fallback [G4] reinstalls pinned to the exact previous version taken from history when no local backup validates"

echo "--- claude: the zero-copy fast path [G4] re-points to a vendor-retained versions/<prev> without any vendor call ---"
HOME7="$TMPBASE/fallback-zerocopy"
CLROOT7="$HOME7/.local"
mkdir -p "$CLROOT7/versions/2.0.0" "$CLROOT7/versions/1.0.0" "$CLROOT7/bin"
_make_elf "$CLROOT7/versions/2.0.0/claude" v2-body
_make_elf "$CLROOT7/versions/1.0.0/claude" v1-body
ln -s "$CLROOT7/versions/2.0.0/claude" "$CLROOT7/bin/claude"
HASH1_7="$(sha256sum "$CLROOT7/versions/1.0.0/claude" | awk '{print $1}')"

rc=0
OUT7="$(HOST_HOME="$HOME7" CLROOT="$CLROOT7" CBOX_CLAUDE_TARGET=stable CBOX_ROLLBACK_PREV_CLAUDE=1.0.0 bash -c '
  set -u
  '"$_COMMON_PREAMBLE"'
  '"$RESOLVEBIN_FN"'
  '"$RESOLVETOOLBIN_FN"'
  '"$BINHASH_FN"'
  '"$TOOLHASH_FN"'
  '"$LINKFOR_FN"'
  '"$STAMPPATH_FN"'
  '"$STAMPFIELD_FN"'
  '"$WANTCOMPAT_FN"'
  '"$STAMPWRITE_FN"'
  '"$WANTSTRING_FN"'
  '"$VERSIONOK_FN"'
  '"$VERIFYTOOL_FN"'
  '"$PREVROOT_FN"'
  '"$PREVROOTRECOVER_FN"'
  '"$PREVMARKER_FN"'
  '"$PREVISREALDIR_FN"'
  '"$PREVCLAUDEZEROCOPY_FN"'
  '"$PREVRESTOREFALLBACK_FN"'
  '"$PREVRESTOREGENERIC_FN"'
  '"$PREVRESTORE_FN"'
  _run_claude_install() { : > "'"$TMPBASE"'/zerocopy-vendor-called"; return 1; }
  _prev_restore claude
')" 2>"$TMPBASE/fallback-zerocopy.err" || rc=$?
[ "$rc" = 0 ] || _fail "claude: zero-copy fast path must succeed: $(cat "$TMPBASE/fallback-zerocopy.err")"
[ -f "$TMPBASE/zerocopy-vendor-called" ] && _fail "claude: the zero-copy fast path must never call the vendor installer"
[ "$(readlink -f "$CLROOT7/bin/claude")" = "$CLROOT7/versions/1.0.0/claude" ] \
  || _fail "claude: the zero-copy fast path must re-point directly at the vendor-retained versions/<prev> directory"
printf '%s\n' "$OUT7" | grep -Eq '^cbox-bins: claude 1\.0\.0 '"$HASH1_7"' rollback 2\.0\.0 network-fallback$' \
  || _fail "claude: zero-copy rollback output line malformed: $OUT7"
_ok "claude: the zero-copy fast path re-points to a vendor-retained versions/<prev> directory with no vendor call and no copy"

echo "--- claude: a crash-interrupted _prev_take rotation (root missing, .orphan left behind) is recovered and still restores ---"
HOME10="$TMPBASE/crash-orphan"
CLROOT10="$HOME10/.local"
mkdir -p "$CLROOT10/versions/1.0.0" "$CLROOT10/versions/2.0.0" "$CLROOT10/bin"
_make_elf "$CLROOT10/versions/1.0.0/claude" v1-body
_make_elf "$CLROOT10/versions/2.0.0/claude" v2-body
ln -s "$CLROOT10/versions/2.0.0/claude" "$CLROOT10/bin/claude"
HASH1_10="$(sha256sum "$CLROOT10/versions/1.0.0/claude" | awk '{print $1}')"
HASH2_10="$(sha256sum "$CLROOT10/versions/2.0.0/claude" | awk '{print $1}')"
mkdir -p "$CLROOT10/.cbox-prev.orphan"
cp -p "$CLROOT10/versions/1.0.0/claude" "$CLROOT10/.cbox-prev.orphan/payload"
printf 'stable\n%s\n%s\n1.0.0\n' "$CLROOT10/versions/1.0.0/claude" "$HASH1_10" > "$CLROOT10/.cbox-prev.orphan/.cbox-stamp"
: > "$CLROOT10/.cbox-prev.orphan/.cbox-backup-complete"
printf 'stable\n%s\n%s\n2.0.0\n' "$CLROOT10/versions/2.0.0/claude" "$HASH2_10" > "$CLROOT10/.cbox-stamp"

rc=0
OUT10="$(HOST_HOME="$HOME10" CLROOT="$CLROOT10" CBOX_CLAUDE_TARGET=stable bash -c '
  set -u
  '"$_COMMON_PREAMBLE"'
  '"$RESOLVEBIN_FN"'
  '"$RESOLVETOOLBIN_FN"'
  '"$BINHASH_FN"'
  '"$TOOLHASH_FN"'
  '"$LINKFOR_FN"'
  '"$STAMPPATH_FN"'
  '"$STAMPFIELD_FN"'
  '"$WANTCOMPAT_FN"'
  '"$STAMPWRITE_FN"'
  '"$WANTSTRING_FN"'
  '"$PREVROOT_FN"'
  '"$PREVROOTRECOVER_FN"'
  '"$PREVMARKER_FN"'
  '"$PREVISREALDIR_FN"'
  '"$PREVCLAUDEZEROCOPY_FN"'
  '"$PREVRESTOREFALLBACK_FN"'
  '"$PREVRESTOREGENERIC_FN"'
  '"$PREVRESTORE_FN"'
  _prev_restore claude
')" 2>"$TMPBASE/crash-orphan.err" || rc=$?
[ "$rc" = 0 ] || _fail "claude: restore must recover an orphaned pre-rotation backup left by a crash: $(cat "$TMPBASE/crash-orphan.err")"
[ ! -e "$CLROOT10/.cbox-prev.orphan" ] || _fail "claude: the orphan must be consumed once recovered"
[ "$(readlink -f "$CLROOT10/bin/claude")" = "$CLROOT10/versions/1.0.0/claude" ] \
  || _fail "claude: the live symlink must resolve back to the v1 binary after recovering from a crashed rotation"
printf '%s\n' "$OUT10" | grep -Eq '^cbox-bins: claude 1\.0\.0 '"$HASH1_10"' rollback 2\.0\.0 manual$' \
  || _fail "claude: crash-recovered rollback output line malformed: $OUT10"
_ok "claude: a crash between rm and mv during backup rotation leaves the old backup recoverable as .cbox-prev.orphan, and restore recovers it automatically"

echo "--- cbox: _bins_history_prev_version reads the from_version of the most recent history line for a tool ---"
HISTFN_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_history_prev_version)"
HISTFILEFN_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_history_file)"
[ -n "$HISTFN_FN" ] || _fail "cannot extract _bins_history_prev_version from cbox/cbox"
[ -n "$HISTFILEFN_FN" ] || _fail "cannot extract _bins_history_file from cbox/cbox"
HOME8="$TMPBASE/history-prev"
mkdir -p "$HOME8/.config/cbox"
printf '1000|vol-claude|claude|stable||1.0.0|ok|\n2000|vol-claude|claude|stable|1.0.0|2.0.0|ok|\n3000|vol-codex|codex|latest||5.0.0|ok|\n' \
  > "$HOME8/.config/cbox/bins.history"
PV_CLAUDE="$(HOME="$HOME8" bash -c '
  '"$HISTFILEFN_FN"'
  '"$HISTFN_FN"'
  _bins_history_prev_version claude
')"
[ "$PV_CLAUDE" = 1.0.0 ] || _fail "cbox: _bins_history_prev_version must return the from_version of the most recent claude history line, got '$PV_CLAUDE'"
PV_NONE="$(HOME="$HOME8" bash -c '
  '"$HISTFILEFN_FN"'
  '"$HISTFN_FN"'
  _bins_history_prev_version hermes
' || true)"
[ -z "$PV_NONE" ] || _fail "cbox: _bins_history_prev_version must return empty for a tool with no history"
_ok "cbox: _bins_history_prev_version reads the from_version of the tool's most recent history line, empty when there is none"

echo "--- cbox: _bins_history_prev_version returns the restored (to_version) of a chained rollback, never the bad version it rolled back from ---"
HOME9="$TMPBASE/history-prev-chained"
mkdir -p "$HOME9/.config/cbox"
printf '1000|vol-claude|claude|stable||1.0.0|ok|\n2000|vol-claude|claude|stable|1.0.0|2.0.0|ok|\n3000|vol-claude|claude|stable|2.0.0|1.0.0|rollback|manual\n' \
  > "$HOME9/.config/cbox/bins.history"
PV_CHAINED="$(HOME="$HOME9" bash -c '
  '"$HISTFILEFN_FN"'
  '"$HISTFN_FN"'
  _bins_history_prev_version claude
')"
[ "$PV_CHAINED" = 1.0.0 ] || _fail "cbox: _bins_history_prev_version after a rollback row must return the restored to_version, got '$PV_CHAINED'"
_ok "cbox: _bins_history_prev_version reads the to_version of a rollback row instead of surfacing the bad from_version as a fallback target"

echo "--- cbox: _bins_run_rollback_group parses a successful rollback line into cache/history and an unhealthy line into a refusal ---"
BRRG_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_run_rollback_group)"
CACHEFILE_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_cache_file)"
CACHEGET_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_cache_get)"
FIELDSANITIZE_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_field_sanitize)"
HOLDSAN2_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_hold_reason_sanitize)"
HOLDFILE2_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_hold_file)"
HOLDWRITE2_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_hold_write)"
CACHEPUT_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_cache_put)"
CACHEFIELD_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_cache_field)"
HISTFILE2_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_history_file)"
HISTAPP_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_history_append)"
WANT_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_want)"
HISTPREV_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_history_prev_version)"
for _fn in BRRG_FN CACHEFILE_FN CACHEGET_FN CACHEPUT_FN CACHEFIELD_FN HISTFILE2_FN HISTAPP_FN WANT_FN HISTPREV_FN; do
  [ -n "${!_fn}" ] || _fail "cannot extract function for $_fn"
done

run_rollback_group() {
  local home="$1" tools="$2" status_lines="$3"
  INSTALL_DIR="$INSTALL_DIR" bash -c '
    set -u
    HOME="$1"; export HOME
    tools="$2"
    status_lines="$3"
    source "$INSTALL_DIR/lib/portable.sh"
    '"$BRRG_FN"'
    '"$CACHEFILE_FN"'
    '"$CACHEGET_FN"'
    '"$FIELDSANITIZE_FN"'
  '"$CACHEPUT_FN"'
    '"$CACHEFIELD_FN"'
    '"$HISTFILE2_FN"'
    '"$HISTAPP_FN"'
    '"$WANT_FN"'
    '"$HISTPREV_FN"'
    '"$HOLDSAN2_FN"'
    '"$HOLDFILE2_FN"'
    '"$HOLDWRITE2_FN"'
    _cbox_bins_volume() { printf "vol-%s" "$1"; }
    id() { printf "u"; }
    docker() {
      case "$1" in
        volume) return 0 ;;
        run) printf "%s" "$status_lines" ;;
        *) return 0 ;;
      esac
    }
    _bins_run_rollback_group img "$tools"
  ' brrg "$home" "$tools" "$status_lines"
}

R1="$TMPBASE/r1"
mkdir -p "$R1/.config/cbox"
run_rollback_group "$R1" "claude codex" "cbox-bins: claude 1.0.0 abcd rollback 2.0.0 manual" >"$R1.out"
grep -Eq '^[0-9]+\|vol-claude\|claude\|stable\|2\.0\.0\|1\.0\.0\|rollback\|manual$' "$R1/.config/cbox/bins.history" \
  || _fail "cbox: a successful rollback line must append a history line with from=badver, to=restored version, status=rollback"
grep -q "vol-claude|claude|stable|1.0.0|" "$R1/.config/cbox/bins.stamp" \
  || _fail "cbox: a successful rollback must update the version cache to the restored version"
_ok "cbox: _bins_run_rollback_group records a successful rollback in both the cache and the append-only history"

[ -f "$R1/.config/cbox/bins.hold.vol-claude" ] \
  || _fail "cbox: a rollback must write a hold file, otherwise autoupdate reinstalls the version just rolled back"
grep -q '^version=1.0.0$' "$R1/.config/cbox/bins.hold.vol-claude" \
  || _fail "cbox: the hold must name the restored version as the good one"
grep -q '^bad=2.0.0$' "$R1/.config/cbox/bins.hold.vol-claude" \
  || _fail "cbox: the hold must name the version that was rolled back as bad"
_ok "cbox: a rollback holds the tool so autoupdate cannot silently reinstall the bad version"

R2="$TMPBASE/r2"
mkdir -p "$R2/.config/cbox"
rc=0
run_rollback_group "$R2" "claude codex" "cbox-bins: claude 2.0.0 - unhealthy no-history" >"$R2.out" 2>"$R2.err" || rc=$?
[ "$rc" != 0 ] || _fail "cbox: an unhealthy rollback outcome must be reported as a failure"
[ -f "$R2/.config/cbox/bins.history" ] && _fail "cbox: an unhealthy outcome must not fabricate a history line"
grep -q "rollback could not restore" "$R2.err" || _fail "cbox: an unhealthy outcome must print an operator-facing notice"
_ok "cbox: _bins_run_rollback_group surfaces an unhealthy outcome as a failure without touching cache or history"

echo "--- codex: a backup stamp whose path is too shallow is refused before any destructive delete ---"
HOME9="$TMPBASE/shallow-codex"
CLROOT9="$HOME9/.local"
CXPKG9="$HOME9/.codex/packages"
mkdir -p "$CXPKG9/standalone/releases/2.0.0-hash/bin" "$CLROOT9/bin"
_make_elf "$CXPKG9/standalone/releases/2.0.0-hash/bin/codex" v2-body
ln -s "$CXPKG9/standalone/releases/2.0.0-hash" "$CXPKG9/standalone/current"
ln -s "$CXPKG9/standalone/current/bin/codex" "$CLROOT9/bin/codex"
printf 'auth-must-survive\n' > "$HOME9/.codex/auth.json"
mkdir -p "$CXPKG9/.cbox-prev/payload/packages"
_make_elf "$CXPKG9/.cbox-prev/payload/packages/x" v1-body
HASH9="$(sha256sum "$CXPKG9/.cbox-prev/payload/packages/x" | awk '{print $1}')"
: > "$CXPKG9/.cbox-prev/.cbox-backup-complete"
printf 'latest\n%s\n%s\n1.0.0\n' "$CXPKG9/x" "$HASH9" > "$CXPKG9/.cbox-prev/.cbox-stamp"
rc=0
OUT9="$(HOST_HOME="$HOME9" CLROOT="$CLROOT9" CXPKG="$CXPKG9" CBOX_CODEX_VERSION=latest bash -c '
  set -u
  '"$_COMMON_PREAMBLE"'
  '"$RESOLVEBIN_FN"'
  '"$RESOLVETOOLBIN_FN"'
  '"$BINHASH_FN"'
  '"$TOOLHASH_FN"'
  '"$LINKFOR_FN"'
  '"$STAMPPATH_FN"'
  '"$STAMPFIELD_FN"'
  '"$PREVROOT_FN"'
  '"$PREVROOTRECOVER_FN"'
  '"$PREVMARKER_FN"'
  '"$PREVISREALDIR_FN"'
  '"$PREVCLAUDEZEROCOPY_FN"'
  '"$PREVRESTOREFALLBACK_FN"'
  '"$PREVRESTOREGENERIC_FN"'
  '"$PREVRESTORE_FN"'
  _prev_restore codex
')" 2>"$TMPBASE/shallow-codex.err" || rc=$?
[ "$rc" != 0 ] || _fail "codex: a shallow backup stamp path must refuse the disk restore"
[ -f "$HOME9/.codex/auth.json" ] || _fail "codex: refusing a shallow backup stamp must never delete the codex home tree"
[ "$(cat "$HOME9/.codex/auth.json")" = "auth-must-survive" ] || _fail "codex: the codex home tree must be left untouched"
[ -x "$CXPKG9/standalone/releases/2.0.0-hash/bin/codex" ] || _fail "codex: the live release must survive a refused restore"
_ok "codex: a backup stamp path shallower than the release layout is refused before the release directory delete"

echo "--- cbox: bins_cmd rollback refuses inside a container just like status/history ---"
BINSCMD_FN="$(_extract_fn "$INSTALL_DIR/cbox" bins_cmd)"
INCONTAINER_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_config_in_container)"
LOCKFILE2_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_lock_file)"
[ -n "$BINSCMD_FN" ] || _fail "cannot extract bins_cmd"
[ -n "$INCONTAINER_FN" ] || _fail "cannot extract _cbox_config_in_container"
[ -n "$LOCKFILE2_FN" ] || _fail "cannot extract _bins_lock_file"
R3="$TMPBASE/r3"
mkdir -p "$R3/.config/cbox"
rc=0
OUTR3="$(INSTALL_DIR="$INSTALL_DIR" HOME="$R3" CBOX_IN_CONTAINER=1 bash -c '
  set -u
  source "$INSTALL_DIR/lib/portable.sh"
  '"$LOCKFILE2_FN"'
  '"$BINSCMD_FN"'
  _cbox_config_in_container() { [ -n "${CBOX_IN_CONTAINER:-}" ]; }
  bins_cmd rollback claude
' 2>&1)" || rc=$?
[ "$rc" != 0 ] || _fail "cbox: bins rollback must refuse inside a container"
printf '%s\n' "$OUTR3" | grep -q "host-only" || _fail "cbox: bins rollback in-container refusal must name it host-only: $OUTR3"
_ok "cbox: bins_cmd rollback refuses to run inside a container with the same host-only message as status/history"

echo "--- protocol channel is not shared with vendor installers ---"

IBSRC="$INSTALL_DIR/install-bins.sh"
for _fn in _run_claude_install _run_codex_install; do
  _body="$(_extract_fn "$IBSRC" "$_fn")"
  [ -n "$_body" ] || _fail "protocol channel: cannot extract $_fn"
  printf '%s' "$_body" | grep -q '>&2' \
    || _fail "protocol channel: $_fn must send vendor installer output to stderr, otherwise a vendor line containing the cbox-bins marker is indistinguishable from a real protocol line"
done
_ok "protocol channel: vendor installers write to stderr, leaving stdout to the cbox-bins protocol alone"

ADOPT_BODY="$(_extract_fn "$IBSRC" _install_one)"
printf '%s' "$ADOPT_BODY" | grep -q '_protocol_field_ok' \
  || _fail "protocol channel: the adopt path must validate the stamp version and hash before printing them into a protocol line"
_ok "protocol channel: the adopt path refuses to emit a stamp field that is not a single plain token"

echo "ALL TESTS PASSED"
