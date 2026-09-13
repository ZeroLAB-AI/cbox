#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

unset CBOX_CLAUDE_TARGET CBOX_CODEX_VERSION CBOX_CODEX_TARGET CBOX_HERMES CBOX_HERMES_VERSION \
  CBOX_INSTALL_FORCE CBOX_INSTALL_MODE CBOX_AUTOUPDATE CBOX_AUTOUPDATE_TTL_HOURS CBOX_BINS_SCOPE CBOX_BINS_HEALTH_GATE \
  CBOX_ROLLBACK_REASON CBOX_ROLLBACK_PREV_CLAUDE CBOX_ROLLBACK_PREV_CODEX CBOX_ROLLBACK_PREV_HERMES \
  CBOX_PROBE_CODEX_ARGV CBOX_HEALTH_PROBE_TIMEOUT CBOX_HEALTH_SH

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

HEALTH_SH="$(sed -n "/^_CBOX_HEALTH_SH='\$/,/^'\$/p" "$INSTALL_DIR/cbox" | sed '1d;$d')"
[ -n "$HEALTH_SH" ] || _fail "cannot extract _CBOX_HEALTH_SH from cbox"

_mkstub() {
  local path="$1" body="$2"
  printf '#!/bin/sh\n%s\n' "$body" > "$path"
  chmod +x "$path"
}

_run_probe() {
  local tool="$1" path="$2" argv="${3:-mcp-server}" to="${4:-2}"
  CBOX_PROBE_CODEX_ARGV="$argv" CBOX_HEALTH_PROBE_TIMEOUT="$to" sh -c "$HEALTH_SH" cbox-health-probe health "$tool" "$path"
}

echo "--- codex: a good binary (help ok, handshake emits developer-instructions) probes healthy ---"
GOOD_CODEX="$TMPBASE/good-codex"
_mkstub "$GOOD_CODEX" '
case "$1" in
  mcp-server)
    shift
    if [ "$1" = "--help" ]; then
      echo "usage: mcp-server"
      exit 0
    fi
    cat >/dev/null
    printf "{\"result\":{\"text\":\"...developer-instructions...\"}}\n"
    exit 0
    ;;
esac
exit 1
'
rc=0
OUT="$(_run_probe codex "$GOOD_CODEX")" || rc=$?
[ "$rc" = 0 ] || _fail "codex: good binary must probe healthy (rc 0), got $rc: $OUT"
_ok "codex: good binary (help ok + developer-instructions in handshake) probes healthy (exit 0)"

echo "--- codex: a 0.154-style binary (help rc=0, handshake produces nothing) is a definitive failure ---"
BAD154_CODEX="$TMPBASE/bad154-codex"
_mkstub "$BAD154_CODEX" '
case "$1" in
  mcp-server)
    shift
    if [ "$1" = "--help" ]; then
      echo "usage: mcp-server"
      exit 0
    fi
    cat >/dev/null
    exit 0
    ;;
esac
exit 1
'
rc=0
OUT="$(_run_probe codex "$BAD154_CODEX")" || rc=$?
[ "$rc" = 2 ] || _fail "codex: 0.154-style binary must probe as a definitive failure (rc 2), got $rc: $OUT"
printf '%s\n' "$OUT" | grep -qF "no developer-instructions" \
  || _fail "codex: 0.154-style failure must name the missing developer-instructions handshake, got: $OUT"
_ok "codex: 0.154-style binary (help rc=0 but empty handshake) is a definitive failure (exit 2) - proves --help alone is never the trigger"

echo "--- codex: a binary whose --help itself fails is a definitive failure before any handshake is attempted ---"
BADHELP_CODEX="$TMPBASE/badhelp-codex"
_mkstub "$BADHELP_CODEX" '
case "$1" in
  mcp-server)
    shift
    if [ "$1" = "--help" ]; then
      exit 1
    fi
    exit 0
    ;;
esac
exit 1
'
rc=0
OUT="$(_run_probe codex "$BADHELP_CODEX")" || rc=$?
[ "$rc" = 2 ] || _fail "codex: a failing --help precondition must be a definitive failure (rc 2), got $rc: $OUT"
_ok "codex: a failing --help precondition is a definitive failure (exit 2)"

echo "--- codex: a hanging handshake is inconclusive, never a rollback trigger ---"
HANG_CODEX="$TMPBASE/hang-codex"
_mkstub "$HANG_CODEX" '
case "$1" in
  mcp-server)
    shift
    if [ "$1" = "--help" ]; then
      echo ok
      exit 0
    fi
    cat >/dev/null
    sleep 100
    exit 0
    ;;
esac
exit 1
'
rc=0
start="$(date +%s)"
OUT="$(_run_probe codex "$HANG_CODEX" mcp-server 1)" || rc=$?
elapsed=$(( $(date +%s) - start ))
[ "$rc" = 3 ] || _fail "codex: a hanging handshake must be inconclusive (rc 3), got $rc: $OUT"
[ "$elapsed" -lt 10 ] || _fail "codex: the probe must honor the shortened timeout, took ${elapsed}s"
_ok "codex: a hanging handshake times out inconclusive (exit 3), never rollback - and the test itself ran in low single-digit seconds"

echo "--- claude: version probes ---"
GOOD_CLAUDE="$TMPBASE/good-claude"
_mkstub "$GOOD_CLAUDE" '
case "$1" in
  --version) echo "1.2.3 (Claude Code)"; exit 0 ;;
esac
exit 1
'
rc=0
_run_probe claude "$GOOD_CLAUDE" >/dev/null || rc=$?
[ "$rc" = 0 ] || _fail "claude: a well-formed version string must probe healthy, got $rc"
_ok "claude: --version matching the expected shape probes healthy (exit 0)"

BAD_CLAUDE="$TMPBASE/bad-claude"
_mkstub "$BAD_CLAUDE" '
case "$1" in
  --version) echo "not-a-version"; exit 0 ;;
esac
exit 1
'
rc=0
_run_probe claude "$BAD_CLAUDE" >/dev/null || rc=$?
[ "$rc" = 2 ] || _fail "claude: a malformed version string must be a definitive failure, got $rc"
_ok "claude: --version not matching the expected shape is a definitive failure (exit 2)"

HANG_CLAUDE="$TMPBASE/hang-claude"
_mkstub "$HANG_CLAUDE" '
case "$1" in
  --version) sleep 100; exit 0 ;;
esac
exit 1
'
rc=0
_run_probe claude "$HANG_CLAUDE" claude-argv-unused 1 >/dev/null || rc=$?
[ "$rc" = 3 ] || _fail "claude: a hanging --version must be inconclusive, got $rc"
_ok "claude: a hanging --version is inconclusive (exit 3)"

echo "--- hermes: version probes via the sibling python binary ---"
HERMES_BIN_DIR="$TMPBASE/hermes-good/bin"
mkdir -p "$HERMES_BIN_DIR"
: > "$HERMES_BIN_DIR/hermes"
chmod +x "$HERMES_BIN_DIR/hermes"
_mkstub "$HERMES_BIN_DIR/python" '
echo "3.4.5"
'
rc=0
_run_probe hermes "$HERMES_BIN_DIR/hermes" >/dev/null || rc=$?
[ "$rc" = 0 ] || _fail "hermes: a well-formed version from the sibling python must probe healthy, got $rc"
_ok "hermes: sibling python emitting a well-formed version probes healthy (exit 0)"

HERMES_BAD_DIR="$TMPBASE/hermes-bad/bin"
mkdir -p "$HERMES_BAD_DIR"
: > "$HERMES_BAD_DIR/hermes"
chmod +x "$HERMES_BAD_DIR/hermes"
_mkstub "$HERMES_BAD_DIR/python" '
echo "not-a-version"
'
rc=0
_run_probe hermes "$HERMES_BAD_DIR/hermes" >/dev/null || rc=$?
[ "$rc" = 2 ] || _fail "hermes: a malformed version must be a definitive failure, got $rc"
_ok "hermes: sibling python emitting a malformed version is a definitive failure (exit 2)"

echo "--- probe: a missing or non-executable path is a definitive failure, never a crash ---"
rc=0
_run_probe codex "$TMPBASE/does-not-exist" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || _fail "probe: a missing path must be a definitive failure, got $rc"
_ok "probe: a missing/non-executable path is a definitive failure (exit 2)"

echo "--- _install_one/_install_health_gate integration (stub vendor install, stubbed _health_check) ---"

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
ADOPTCHECK_FN="$(_extract_fn "$IB" _adopt_check)"
PREVROOT_FN="$(_extract_fn "$IB" _prev_root)"
PREVROOTRECOVER_FN="$(_extract_fn "$IB" _prev_root_recover)"
PREVMARKER_FN="$(_extract_fn "$IB" _prev_marker)"
PREVISREALDIR_FN="$(_extract_fn "$IB" _prev_is_real_dir)"
PREVTAKE_FN="$(_extract_fn "$IB" _prev_take)"
PREVCLAUDEZEROCOPY_FN="$(_extract_fn "$IB" _prev_claude_zero_copy)"
PREVRESTOREFALLBACK_FN="$(_extract_fn "$IB" _prev_restore_fallback)"
PREVRESTOREGENERIC_FN="$(_extract_fn "$IB" _prev_restore_generic)"
PREVRESTORE_FN="$(_extract_fn "$IB" _prev_restore)"
HEALTHROLLFORWARD_FN="$(_extract_fn "$IB" _health_rollforward)"
INSTALLHEALTHGATE_FN="$(_extract_fn "$IB" _install_health_gate)"
INSTALLONE_FN="$(_extract_fn "$IB" _install_one)"

for _fn in RESOLVEBIN_FN RESOLVETOOLBIN_FN BINHASH_FN TOOLHASH_FN LINKFOR_FN STAMPPATH_FN STAMPFIELD_FN \
  WANTCOMPAT_FN STAMPWRITE_FN WANTSTRING_FN VERSIONOK_FN VERIFYTOOL_FN ADOPTCHECK_FN PREVROOT_FN PREVMARKER_FN \
  PREVISREALDIR_FN PREVROOTRECOVER_FN PREVTAKE_FN PREVCLAUDEZEROCOPY_FN PREVRESTOREFALLBACK_FN PREVRESTOREGENERIC_FN \
  PREVRESTORE_FN HEALTHROLLFORWARD_FN INSTALLHEALTHGATE_FN INSTALLONE_FN; do
  [ -n "${!_fn}" ] || _fail "cannot extract install-bins function for $_fn"
done

_IB_PREAMBLE='
HXROOT=""
_gosu() { "$@"; }
_parsed_version() {
  local n="$1" p="$2"
  case "$p" in
    *"/versions/1.0.0/"*) printf "1.0.0" ;;
    *"/versions/2.0.0/"*) printf "2.0.0" ;;
    *"/versions/9.9.9/"*) printf "9.9.9" ;;
    *) return 1 ;;
  esac
}
'

_ib_make_elf() {
  printf '\177ELF' > "$1"
  printf '%s\n' "$2" >> "$1"
  chmod +x "$1"
}

echo "--- claude: a health probe that fails on the new version but passes on the restored backup reports rollback, stamp ends at the restored version ---"
HOMEA="$TMPBASE/gate-rollback"
CLROOTA="$HOMEA/.local"
mkdir -p "$CLROOTA/versions/1.0.0" "$CLROOTA/bin"
_ib_make_elf "$CLROOTA/versions/1.0.0/claude" v1-body
ln -s "$CLROOTA/versions/1.0.0/claude" "$CLROOTA/bin/claude"
HASH1A="$(sha256sum "$CLROOTA/versions/1.0.0/claude" | awk '{print $1}')"
printf 'stable\n%s\n%s\n1.0.0\n' "$CLROOTA/versions/1.0.0/claude" "$HASH1A" > "$CLROOTA/.cbox-stamp"

rc=0
OUTA="$(HOST_HOME="$HOMEA" CLROOT="$CLROOTA" CBOX_CLAUDE_TARGET=stable CBOX_INSTALL_TOOLS=claude CBOX_INSTALL_FORCE=refresh bash -c '
  set -u
  '"$_IB_PREAMBLE"'
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
  '"$ADOPTCHECK_FN"'
  '"$PREVROOT_FN"'
  '"$PREVROOTRECOVER_FN"'
  '"$PREVMARKER_FN"'
  '"$PREVISREALDIR_FN"'
  '"$PREVTAKE_FN"'
  '"$PREVCLAUDEZEROCOPY_FN"'
  '"$PREVRESTOREFALLBACK_FN"'
  '"$PREVRESTOREGENERIC_FN"'
  '"$PREVRESTORE_FN"'
  '"$HEALTHROLLFORWARD_FN"'
  '"$INSTALLHEALTHGATE_FN"'
  '"$INSTALLONE_FN"'
  _health_check() {
    case "$2" in
      *"/versions/2.0.0/"*) _HEALTH_CHECK_NOTE="mcp-server handshake: no developer-instructions"; return 2 ;;
      *) _HEALTH_CHECK_NOTE=""; return 0 ;;
    esac
  }
  _run_claude_install() {
    mkdir -p "$CLROOT/versions/2.0.0"
    printf "\177ELF" > "$CLROOT/versions/2.0.0/claude"
    printf "v2-body\n" >> "$CLROOT/versions/2.0.0/claude"
    chmod +x "$CLROOT/versions/2.0.0/claude"
    ln -sfn "$CLROOT/versions/2.0.0/claude" "$CLROOT/bin/claude"
    return 0
  }
  _install_one claude
')" || rc=$?
[ "$rc" = 0 ] || _fail "claude: _install_one must succeed even when the health gate triggers a rollback: $OUTA"
printf '%s\n' "$OUTA" | grep -Eq '^cbox-bins: claude 1\.0\.0 '"$HASH1A"' rollback 2\.0\.0 ' \
  || _fail "claude: expected a rollback cbox-bins line, got: $OUTA"
[ "$(sed -n '4p' "$CLROOTA/.cbox-stamp")" = 1.0.0 ] || _fail "claude: stamp must end at the restored (prev) version"
[ "$(readlink -f "$CLROOTA/bin/claude")" = "$CLROOTA/versions/1.0.0/claude" ] \
  || _fail "claude: the live symlink must resolve back to the restored version"
_ok "claude: a health probe failing on the new version but passing on the restored backup yields a rollback line and stamp=prev"

echo "--- claude: a health probe that fails on BOTH the new version and the restored backup rolls forward, keeps the new version, no hold ---"
HOMEB="$TMPBASE/gate-both-fail"
CLROOTB="$HOMEB/.local"
mkdir -p "$CLROOTB/versions/1.0.0" "$CLROOTB/bin"
_ib_make_elf "$CLROOTB/versions/1.0.0/claude" v1-body
ln -s "$CLROOTB/versions/1.0.0/claude" "$CLROOTB/bin/claude"
HASH1B="$(sha256sum "$CLROOTB/versions/1.0.0/claude" | awk '{print $1}')"
printf 'stable\n%s\n%s\n1.0.0\n' "$CLROOTB/versions/1.0.0/claude" "$HASH1B" > "$CLROOTB/.cbox-stamp"

rc=0
OUTB="$(HOST_HOME="$HOMEB" CLROOT="$CLROOTB" CBOX_CLAUDE_TARGET=stable CBOX_INSTALL_TOOLS=claude CBOX_INSTALL_FORCE=refresh bash -c '
  set -u
  '"$_IB_PREAMBLE"'
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
  '"$ADOPTCHECK_FN"'
  '"$PREVROOT_FN"'
  '"$PREVROOTRECOVER_FN"'
  '"$PREVMARKER_FN"'
  '"$PREVISREALDIR_FN"'
  '"$PREVTAKE_FN"'
  '"$PREVCLAUDEZEROCOPY_FN"'
  '"$PREVRESTOREFALLBACK_FN"'
  '"$PREVRESTOREGENERIC_FN"'
  '"$PREVRESTORE_FN"'
  '"$HEALTHROLLFORWARD_FN"'
  '"$INSTALLHEALTHGATE_FN"'
  '"$INSTALLONE_FN"'
  _health_check() {
    _HEALTH_CHECK_NOTE="probe always fails in this fixture"
    return 2
  }
  _run_claude_install() {
    mkdir -p "$CLROOT/versions/2.0.0"
    printf "\177ELF" > "$CLROOT/versions/2.0.0/claude"
    printf "v2-body\n" >> "$CLROOT/versions/2.0.0/claude"
    chmod +x "$CLROOT/versions/2.0.0/claude"
    ln -sfn "$CLROOT/versions/2.0.0/claude" "$CLROOT/bin/claude"
    return 0
  }
  _install_one claude
')" || rc=$?
[ "$rc" = 0 ] || _fail "claude: _install_one must succeed (fail-open) even when both candidates fail health: $OUTB"
printf '%s\n' "$OUTB" | grep -q '^cbox-bins: claude 2\.0\.0 .* unreliable ' \
  || _fail "claude: expected an unreliable cbox-bins line naming the kept (new) version, got: $OUTB"
[ "$(sed -n '4p' "$CLROOTB/.cbox-stamp")" = 2.0.0 ] || _fail "claude: stamp must roll forward to the new version, not stay on the restored one"
[ "$(readlink -f "$CLROOTB/bin/claude")" = "$CLROOTB/versions/2.0.0/claude" ] \
  || _fail "claude: the live symlink must roll forward to the new version"
_ok "claude: a health probe failing identically on both candidates rolls forward to the new version, reports unreliable, never rollback"

echo "--- claude: a health probe failing on a first-ever install with no backup and no history is unhealthy, fail-open (install still reports success) ---"
HOMEC="$TMPBASE/gate-no-backup"
CLROOTC="$HOMEC/.local"
mkdir -p "$CLROOTC/bin"

rc=0
OUTC="$(HOST_HOME="$HOMEC" CLROOT="$CLROOTC" CBOX_CLAUDE_TARGET=stable CBOX_INSTALL_TOOLS=claude CBOX_INSTALL_FORCE=refresh bash -c '
  set -u
  '"$_IB_PREAMBLE"'
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
  '"$ADOPTCHECK_FN"'
  '"$PREVROOT_FN"'
  '"$PREVROOTRECOVER_FN"'
  '"$PREVMARKER_FN"'
  '"$PREVISREALDIR_FN"'
  '"$PREVTAKE_FN"'
  '"$PREVCLAUDEZEROCOPY_FN"'
  '"$PREVRESTOREFALLBACK_FN"'
  '"$PREVRESTOREGENERIC_FN"'
  '"$PREVRESTORE_FN"'
  '"$HEALTHROLLFORWARD_FN"'
  '"$INSTALLHEALTHGATE_FN"'
  '"$INSTALLONE_FN"'
  _health_check() {
    _HEALTH_CHECK_NOTE="claude --version did not match the expected format"
    return 2
  }
  _run_claude_install() {
    mkdir -p "$CLROOT/versions/9.9.9"
    printf "\177ELF" > "$CLROOT/versions/9.9.9/claude"
    printf "v9-body\n" >> "$CLROOT/versions/9.9.9/claude"
    chmod +x "$CLROOT/versions/9.9.9/claude"
    ln -sfn "$CLROOT/versions/9.9.9/claude" "$CLROOT/bin/claude"
    return 0
  }
  _install_one claude
')" || rc=$?
[ "$rc" = 0 ] || _fail "claude: a first-ever install with a failing health probe must still be fail-open (rc 0): $OUTC"
printf '%s\n' "$OUTC" | grep -q '^cbox-bins: claude 9\.9\.9 - unhealthy no-history' \
  || _fail "claude: expected an unhealthy no-history cbox-bins line when there is no backup and no history, got: $OUTC"
[ "$(sed -n '4p' "$CLROOTC/.cbox-stamp")" = 9.9.9 ] || _fail "claude: the stamp must still reflect the (unhealthy) installed version, fail-open"
_ok "claude: no local backup and no history to fall back to reports unhealthy and fails open (the bad install keeps running with a notice)"

echo "--- hermes: a health probe that fails on the fresh install but passes on the restored .prev backup reports rollback ---"

VRESET_FN="$(_extract_fn "$IB" _hermes_venv_reset)"
BDIR_FN="$(_extract_fn "$IB" _hermes_backup_dir)"
TREEOK_FN="$(_extract_fn "$IB" _hermes_tree_complete)"
BMARKER_FN="$(_extract_fn "$IB" _hermes_backup_marker)"
PREVREAL_FN="$(_extract_fn "$IB" _hermes_prev_is_real_dir)"
BISCOMPLETE_FN="$(_extract_fn "$IB" _hermes_backup_is_complete)"
BUNWIND_FN="$(_extract_fn "$IB" _hermes_backup_take_unwind)"
RECOVER_FN="$(_extract_fn "$IB" _hermes_recover_stale_backup)"
BTAKE_FN="$(_extract_fn "$IB" _hermes_backup_take)"
BCOMMIT_FN="$(_extract_fn "$IB" _hermes_backup_commit)"
BRESTORE_FN="$(_extract_fn "$IB" _hermes_backup_restore)"
RHI_FN="$(_extract_fn "$IB" _run_hermes_install)"
PREVRESTOREHERMES_FN="$(_extract_fn "$IB" _prev_restore_hermes)"
RESOLVEHERMESBIN_FN="$(_extract_fn "$IB" _resolve_hermes_bin)"

for _fn in VRESET_FN BDIR_FN TREEOK_FN BMARKER_FN PREVREAL_FN BISCOMPLETE_FN BUNWIND_FN RECOVER_FN BTAKE_FN \
  BCOMMIT_FN BRESTORE_FN RHI_FN PREVRESTOREHERMES_FN RESOLVEHERMESBIN_FN PREVRESTORE_FN; do
  [ -n "${!_fn}" ] || _fail "cannot extract hermes install-bins function for $_fn"
done

HXROOT_H="$TMPBASE/hermes-gate"
mkdir -p "$HXROOT_H/bin" "$HXROOT_H/lib/marker-pkg"
printf 'old-python\n' > "$HXROOT_H/bin/python"
printf 'old-hermes\n' > "$HXROOT_H/bin/hermes"
chmod 0755 "$HXROOT_H/bin/python" "$HXROOT_H/bin/hermes"
printf 'old-marker\n' > "$HXROOT_H/lib/marker-pkg/data.txt"
printf 'latest\n%s/bin/hermes\noldhash\n1.2.3\n' "$HXROOT_H" > "$HXROOT_H/.cbox-stamp"

HCALLS="$TMPBASE/hcalls"
rm -f "$HCALLS"
rc=0
OUTH="$(HXROOT="$HXROOT_H" HOST_UID="$(id -u)" HOST_GID="$(id -g)" CBOX_HERMES_VERSION=latest \
  CBOX_INSTALL_TOOLS=hermes CBOX_INSTALL_FORCE=refresh HOST_HOME="$TMPBASE/hermes-gate-home" bash -c '
  set -u
  chown() { :; }
  _hxgosu() { "$@"; }
  _hermes_stamp_install_method() { return 0; }
  _hermes_seed_delegate_home() { return 0; }
  '"$VRESET_FN"'
  '"$BDIR_FN"'
  '"$TREEOK_FN"'
  '"$BMARKER_FN"'
  '"$PREVREAL_FN"'
  '"$BISCOMPLETE_FN"'
  '"$BUNWIND_FN"'
  '"$RECOVER_FN"'
  '"$BTAKE_FN"'
  '"$BCOMMIT_FN"'
  '"$BRESTORE_FN"'
  '"$RHI_FN"'
  '"$PREVRESTOREHERMES_FN"'
  '"$PREVRESTORE_FN"'
  '"$STAMPPATH_FN"'
  '"$STAMPFIELD_FN"'
  '"$STAMPWRITE_FN"'
  '"$WANTCOMPAT_FN"'
  '"$WANTSTRING_FN"'
  '"$RESOLVEHERMESBIN_FN"'
  '"$RESOLVETOOLBIN_FN"'
  '"$ADOPTCHECK_FN"'
  '"$INSTALLHEALTHGATE_FN"'
  '"$INSTALLONE_FN"'
  python3() {
    shift; shift
    local target="$1"
    mkdir -p "$target/bin" "$target/lib/marker-pkg"
    printf "new-python\n" > "$target/bin/python"
    printf "new-hermes\n" > "$target/bin/hermes"
    printf "#!/bin/sh\nexit 0\n" > "$target/bin/pip"
    chmod 0755 "$target/bin/python" "$target/bin/hermes" "$target/bin/pip"
    printf "new-marker\n" > "$target/lib/marker-pkg/data.txt"
  }
  _verify_tool() {
    printf "%s/bin/hermes\nnewhash\n2.0.0\n" "$HXROOT"
  }
  _parsed_version() {
    case "$1" in
      hermes) printf "2.0.0" ;;
      *) return 1 ;;
    esac
  }
  _health_check() {
    local n
    n="$(cat "'"$HCALLS"'" 2>/dev/null || echo 0)"
    n=$((n + 1))
    echo "$n" > "'"$HCALLS"'"
    if [ "$n" = 1 ]; then
      _HEALTH_CHECK_NOTE="hermes version probe did not match the expected format"
      return 2
    fi
    _HEALTH_CHECK_NOTE=""
    return 0
  }
  _install_one hermes
')" || rc=$?
[ "$rc" = 0 ] || _fail "hermes: _install_one must succeed when the health gate restores a good backup: $OUTH"
printf '%s\n' "$OUTH" | grep -Eq '^cbox-bins: hermes 1\.2\.3 oldhash rollback 2\.0\.0 ' \
  || _fail "hermes: expected a rollback cbox-bins line restoring the old version, got: $OUTH"
[ "$(sed -n '4p' "$HXROOT_H/.cbox-stamp")" = 1.2.3 ] || _fail "hermes: stamp must end at the restored version"
[ "$(cat "$HXROOT_H/bin/hermes")" = old-hermes ] || _fail "hermes: the live tree must be the restored (old) content"
_ok "hermes: a health probe failing on the fresh install but passing on the restored .prev backup reports rollback and restores the old tree"

echo "--- _health_check: an unexpected probe exit code (neither 0, 2, nor 3) normalizes to inconclusive (3), never falls through to rollback ---"
HEALTHCHECK_FN="$(_extract_fn "$IB" _health_check)"
[ -n "$HEALTHCHECK_FN" ] || _fail "cannot extract install-bins function for _health_check"
rc=0
CBOX_HEALTH_SH='exit 9' bash -c '
  set -u
  _gosu() { "$@"; }
  '"$HEALTHCHECK_FN"'
  _health_check codex /bin/true
' >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] || _fail "_health_check: an unrecognized probe exit code must normalize to inconclusive (3), got $rc"
_ok "_health_check: an unexpected probe exit code (e.g. an outer-timeout or exec failure) normalizes to inconclusive (3), not a silent rollback trigger"

echo "--- claude: a health probe failing on both candidates AND a failing roll-forward reports the actual live (restored) version, not the never-adopted new one ---"
HOMED="$TMPBASE/gate-rollforward-fails"
CLROOTD="$HOMED/.local"
mkdir -p "$CLROOTD/versions/1.0.0" "$CLROOTD/bin"
_ib_make_elf "$CLROOTD/versions/1.0.0/claude" v1-body
ln -s "$CLROOTD/versions/1.0.0/claude" "$CLROOTD/bin/claude"
HASH1D="$(sha256sum "$CLROOTD/versions/1.0.0/claude" | awk '{print $1}')"
printf 'stable\n%s\n%s\n1.0.0\n' "$CLROOTD/versions/1.0.0/claude" "$HASH1D" > "$CLROOTD/.cbox-stamp"

rc=0
OUTD="$(HOST_HOME="$HOMED" CLROOT="$CLROOTD" CBOX_CLAUDE_TARGET=stable CBOX_INSTALL_TOOLS=claude CBOX_INSTALL_FORCE=refresh bash -c '
  set -u
  '"$_IB_PREAMBLE"'
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
  '"$ADOPTCHECK_FN"'
  '"$PREVROOT_FN"'
  '"$PREVROOTRECOVER_FN"'
  '"$PREVMARKER_FN"'
  '"$PREVISREALDIR_FN"'
  '"$PREVTAKE_FN"'
  '"$PREVCLAUDEZEROCOPY_FN"'
  '"$PREVRESTOREFALLBACK_FN"'
  '"$PREVRESTOREGENERIC_FN"'
  '"$PREVRESTORE_FN"'
  '"$INSTALLHEALTHGATE_FN"'
  '"$INSTALLONE_FN"'
  _health_rollforward() { return 1; }
  _health_check() {
    _HEALTH_CHECK_NOTE="probe always fails in this fixture"
    return 2
  }
  _run_claude_install() {
    mkdir -p "$CLROOT/versions/2.0.0"
    printf "\177ELF" > "$CLROOT/versions/2.0.0/claude"
    printf "v2-body\n" >> "$CLROOT/versions/2.0.0/claude"
    chmod +x "$CLROOT/versions/2.0.0/claude"
    ln -sfn "$CLROOT/versions/2.0.0/claude" "$CLROOT/bin/claude"
    return 0
  }
  _install_one claude
')" || rc=$?
[ "$rc" = 0 ] || _fail "claude: _install_one must succeed (fail-open) even when roll-forward itself fails: $OUTD"
printf '%s\n' "$OUTD" | grep -q '^cbox-bins: claude 1\.0\.0 - unhealthy rollforward-failed' \
  || _fail "claude: expected the unhealthy rollforward-failed line to report the actual live (restored) version 1.0.0, got: $OUTD"
[ "$(readlink -f "$CLROOTD/bin/claude")" = "$CLROOTD/versions/1.0.0/claude" ] \
  || _fail "claude: the live symlink must still be the restored version when roll-forward fails"
_ok "claude: when both candidates fail health and roll-forward itself fails, the reported version matches the actually-live restored binary, not the never-adopted new one"

echo "ALL TESTS PASSED"
