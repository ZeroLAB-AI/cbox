#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
export TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT

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

BIN="$INSTALL_DIR/install-bins.sh"

PVER_FN="$(_extract_fn "$BIN" _parsed_version)"
RHI_FN="$(_extract_fn "$BIN" _run_hermes_install)"
RRESET_FN="$(_extract_fn "$BIN" _hermes_root_reset)"
BDIR_FN="$(_extract_fn "$BIN" _hermes_backup_dir)"
TREEOK_FN="$(_extract_fn "$BIN" _hermes_tree_complete)"
BMARKER_FN="$(_extract_fn "$BIN" _hermes_backup_marker)"
PREVREAL_FN="$(_extract_fn "$BIN" _hermes_prev_is_real_dir)"
BISCOMPLETE_FN="$(_extract_fn "$BIN" _hermes_backup_is_complete)"
BUNWIND_FN="$(_extract_fn "$BIN" _hermes_backup_take_unwind)"
RECOVER_FN="$(_extract_fn "$BIN" _hermes_recover_stale_backup)"
BTAKE_FN="$(_extract_fn "$BIN" _hermes_backup_take)"
BCOMMIT_FN="$(_extract_fn "$BIN" _hermes_backup_commit)"
BRESTORE_FN="$(_extract_fn "$BIN" _hermes_backup_restore)"
FETCH_FN="$(_extract_fn "$BIN" _hermes_fetch_artifact)"

for _fn in PVER_FN RHI_FN RRESET_FN BDIR_FN TREEOK_FN BMARKER_FN PREVREAL_FN BISCOMPLETE_FN BUNWIND_FN RECOVER_FN BTAKE_FN BCOMMIT_FN BRESTORE_FN FETCH_FN; do
  [ -n "${!_fn}" ] || _fail "cannot extract install-bins function for $_fn"
done

printf '%s\n' "$PVER_FN" > "$TMPBASE/pver.sh"

echo "--- case 1: _parsed_version on a main build with a release date ---"
P1="$TMPBASE/p1"
mkdir -p "$P1/bin" "$P1/src/hermes_cli"
ln -s "$(command -v python3)" "$P1/bin/python"
printf '{"commit": "085f562af53a6fedadac3681e2c498fc71316132"}\n' > "$P1/src/install-stamp.json"
printf '__release_date__ = "2026.9.24"\n' > "$P1/src/hermes_cli/__init__.py"
rc=0
HXROOT="$P1" HXSRC="$P1/src" bash -c 'set -u; . "$1"; _parsed_version hermes x' _ "$TMPBASE/pver.sh" > "$TMPBASE/p1.out" 2>/dev/null || rc=$?
[ "$rc" = 0 ] || _fail "case 1: expected rc 0, got $rc"
[ "$(cat "$TMPBASE/p1.out")" = "2026.9.24-g085f562af53a" ] || _fail "case 1: expected 2026.9.24-g085f562af53a, got: $(cat "$TMPBASE/p1.out")"
_ok "case 1: _parsed_version combines the stamp commit and the release date into 2026.9.24-g085f562af53a"

echo "--- case 2: _parsed_version without a release date falls back to 0.0.0 ---"
P2="$TMPBASE/p2"
mkdir -p "$P2/bin" "$P2/src/hermes_cli"
ln -s "$(command -v python3)" "$P2/bin/python"
printf '{"commit": "085f562af53a6fedadac3681e2c498fc71316132"}\n' > "$P2/src/install-stamp.json"
printf '# this build has no release date line\n' > "$P2/src/hermes_cli/__init__.py"
rc=0
HXROOT="$P2" HXSRC="$P2/src" bash -c 'set -u; . "$1"; _parsed_version hermes x' _ "$TMPBASE/pver.sh" > "$TMPBASE/p2.out" 2>/dev/null || rc=$?
[ "$rc" = 0 ] || _fail "case 2: expected rc 0, got $rc"
[ "$(cat "$TMPBASE/p2.out")" = "0.0.0-g085f562af53a" ] || _fail "case 2: expected 0.0.0-g085f562af53a, got: $(cat "$TMPBASE/p2.out")"
_ok "case 2: _parsed_version without a release date falls back to 0.0.0-g085f562af53a"

_run_case() {
  local tag="$1" version="$2" sha_stanza="$3"
  local base="$TMPBASE/$tag"
  local root="$base/opt-hermes"
  mkdir -p "$root/bin"
  printf 'old-hermes\n' > "$root/bin/hermes"
  printf 'old-python\n' > "$root/bin/python"
  chmod 0755 "$root/bin/hermes" "$root/bin/python"
  printf 'old-stamp\n' > "$root/.cbox-stamp"
  {
    printf '%s\n\n' "$RHI_FN" "$RRESET_FN" "$BDIR_FN" "$TREEOK_FN" "$BMARKER_FN" "$PREVREAL_FN" "$BISCOMPLETE_FN" "$BUNWIND_FN" "$RECOVER_FN" "$BTAKE_FN" "$BCOMMIT_FN" "$BRESTORE_FN"
    printf '%s\n' "$sha_stanza"
    cat <<'STUBS'
chown() { :; }
_hxgosu() { "$@"; }
_hermes_git_install() { echo "$1" > "$TMPBASE/git_sha.log"; mkdir -p "$HXROOT/bin"; printf x > "$HXROOT/bin/hermes"; printf x > "$HXROOT/bin/python"; chmod 0755 "$HXROOT/bin/hermes" "$HXROOT/bin/python"; }
_hermes_venv_reset() { echo called > "$TMPBASE/venv_reset.log"; return 1; }
_hermes_stamp_install_method() { return 0; }
_hermes_seed_delegate_home() { return 0; }
_stamp_path() { printf "%s/.cbox-stamp" "$HXROOT"; }
_want_string() { printf main; }
_verify_tool() { printf "%s/bin/hermes\nfakehash\n2026.9.24-g085f562af53a\n" "$HXROOT"; }
_stamp_write() { printf "%s\n%s\n%s\n%s\n" "$2" "$3" "$4" "$5" > "$1"; }
STUBS
  } > "$base/all.sh"
  CBOX_HERMES_VERSION="$version" \
    HXROOT="$root" \
    HXREPO="https://example.invalid/repo" \
    HXBRANCH=main \
    HOST_UID="$(id -u)" \
    HOST_GID="$(id -g)" \
    bash -c 'set -u; . "$1"; _run_hermes_install' _ "$base/all.sh" > "$base/out.txt" 2> "$base/err.txt"
}

echo "--- case 3: CBOX_HERMES_VERSION=main installs from the branch sha via git, not pip ---"
rc=0
_run_case p3 main '_hermes_main_sha() { printf 085f562af53a6fedadac3681e2c498fc71316132; }' || rc=$?
[ "$rc" = 0 ] || _fail "case 3: expected rc 0, got $rc; stderr: $(cat "$TMPBASE/p3/err.txt" 2>/dev/null)"
grep -q 085f562af53a6fedadac3681e2c498fc71316132 "$TMPBASE/git_sha.log" 2>/dev/null || _fail "case 3: git_sha.log does not hold the resolved sha: $(cat "$TMPBASE/git_sha.log" 2>/dev/null)"
[ ! -e "$TMPBASE/p3/venv_reset.log" ] || _fail "case 3: venv_reset.log exists - the pip path was taken"
S3="$TMPBASE/p3/opt-hermes/.cbox-stamp"
[ "$(sed -n 1p "$S3")" = "main" ] || _fail "case 3: new stamp first line is not main: $(sed -n 1p "$S3" 2>/dev/null)"
[ "$(sed -n 4p "$S3")" = "2026.9.24-g085f562af53a" ] || _fail "case 3: new stamp fourth line is not 2026.9.24-g085f562af53a: $(sed -n 4p "$S3" 2>/dev/null)"
[ -d "$TMPBASE/p3/opt-hermes/.prev" ] || _fail "case 3: .prev is missing after a successful main install"
[ "$(cat "$TMPBASE/p3/opt-hermes/.prev/.cbox-stamp")" = "old-stamp" ] || _fail "case 3: .prev/.cbox-stamp is not old-stamp: $(cat "$TMPBASE/p3/opt-hermes/.prev/.cbox-stamp" 2>/dev/null)"
_ok "case 3: CBOX_HERMES_VERSION=main resolves the sha, installs via git without pip, stamps main and keeps the old tree under .prev"

echo "--- case 4: main with an unresolvable sha fails before touching the old tree ---"
rc=0
_run_case p4 main '_hermes_main_sha() { return 1; }' || rc=$?
[ "$rc" != 0 ] || _fail "case 4: expected a non-zero rc"
grep -q "cannot resolve" "$TMPBASE/p4/err.txt" 2>/dev/null || _fail "case 4: stderr does not contain cannot resolve: $(cat "$TMPBASE/p4/err.txt" 2>/dev/null)"
[ "$(cat "$TMPBASE/p4/opt-hermes/.cbox-stamp")" = "old-stamp" ] || _fail "case 4: the old stamp was modified"
[ ! -e "$TMPBASE/p4/opt-hermes/.prev" ] || _fail "case 4: .prev was created on a failed main install"
_ok "case 4: main with an unresolvable sha fails with cannot resolve and leaves the old tree untouched"

echo "--- case 5: an explicit -g version is refused because it cannot be rebuilt from history ---"
rc=0
_run_case p5 2026.9.24-g085f562af53a '_hermes_main_sha() { printf 085f562af53a6fedadac3681e2c498fc71316132; }' || rc=$?
[ "$rc" != 0 ] || _fail "case 5: expected a non-zero rc"
grep -q "cannot be rebuilt from history" "$TMPBASE/p5/err.txt" 2>/dev/null || _fail "case 5: stderr does not contain cannot be rebuilt from history: $(cat "$TMPBASE/p5/err.txt" 2>/dev/null)"
[ "$(cat "$TMPBASE/p5/opt-hermes/.cbox-stamp")" = "old-stamp" ] || _fail "case 5: the old stamp was modified"
[ ! -e "$TMPBASE/p5/opt-hermes/.prev" ] || _fail "case 5: .prev was created for a refused version"
_ok "case 5: an explicit -g version is refused as not rebuildable from history and leaves the old tree untouched"

echo "--- case 6: _hermes_fetch_artifact platform, https, and digest checks ---"
F6="$TMPBASE/p6"
mkdir -p "$F6/src/pm"
SHA6="$(printf PAYLOAD | sha256sum | awk '{print $1}')"
[ -n "$SHA6" ] || _fail "case 6: cannot compute the sha256 of PAYLOAD"
printf '{"packages": {"uv": {"artifacts": {"linux-x64": {"url": "https://example.invalid/uv.tar.gz", "sha256": "%s"}}}}}\n' "$SHA6" > "$F6/src/pm/lock.json"
F6C="$TMPBASE/p6c"
mkdir -p "$F6C/src/pm"
printf '{"packages": {"uv": {"artifacts": {"linux-x64": {"url": "http://example.invalid/uv.tar.gz", "sha256": "%s"}}}}}\n' "$SHA6" > "$F6C/src/pm/lock.json"

_fetch_case() {
  local tag="$1" src="$2" body="$3" uname_stanza="$4"
  local base="$TMPBASE/$tag"
  mkdir -p "$base"
  {
    printf '%s\n' "$FETCH_FN"
    printf '%s\n' "$uname_stanza"
    cat <<'STUBS'
_hxgosu() { "$@"; }
curl() { local out=""; while [ $# -gt 0 ]; do if [ "$1" = -o ]; then out="$2"; shift; fi; shift; done; printf "%s" "$CURL_BODY" > "$out"; }
STUBS
  } > "$base/all.sh"
  HXSRC="$src" \
    CURL_BODY="$body" \
    bash -c 'set -u; . "$1"; _hermes_fetch_artifact uv "$2"' _ "$base/all.sh" "$base/uv.tar.gz" > "$base/out.txt" 2> "$base/err.txt"
}

rc=0
_fetch_case f6a "$F6/src" PAYLOAD 'uname() { echo x86_64; }' || rc=$?
[ "$rc" = 0 ] || _fail "case 6a: expected rc 0, got $rc; stderr: $(cat "$TMPBASE/f6a/err.txt" 2>/dev/null)"
[ -f "$TMPBASE/f6a/uv.tar.gz" ] || _fail "case 6a: the output file is missing"
[ "$(cat "$TMPBASE/f6a/uv.tar.gz")" = "PAYLOAD" ] || _fail "case 6a: the output file does not hold the payload"
_ok "case 6a: a pinned https uv artifact with a matching sha256 is downloaded and accepted"

rc=0
_fetch_case f6b "$F6/src" TAMPERED 'uname() { echo x86_64; }' || rc=$?
[ "$rc" != 0 ] || _fail "case 6b: expected a non-zero rc"
grep -q "digest mismatch" "$TMPBASE/f6b/err.txt" 2>/dev/null || _fail "case 6b: stderr does not contain digest mismatch: $(cat "$TMPBASE/f6b/err.txt" 2>/dev/null)"
_ok "case 6b: a tampered uv artifact fails the sha256 digest check"

rc=0
_fetch_case f6c "$F6C/src" PAYLOAD 'uname() { echo x86_64; }' || rc=$?
[ "$rc" != 0 ] || _fail "case 6c: expected a non-zero rc"
grep -q "not https" "$TMPBASE/f6c/err.txt" 2>/dev/null || _fail "case 6c: stderr does not contain not https: $(cat "$TMPBASE/f6c/err.txt" 2>/dev/null)"
_ok "case 6c: a non-https uv artifact URL is refused"

rc=0
_fetch_case f6d "$F6/src" PAYLOAD 'uname() { echo sparc64; }' || rc=$?
[ "$rc" != 0 ] || _fail "case 6d: expected a non-zero rc"
grep -q "pins no" "$TMPBASE/f6d/err.txt" 2>/dev/null || _fail "case 6d: stderr does not contain pins no: $(cat "$TMPBASE/f6d/err.txt" 2>/dev/null)"
_ok "case 6d: an unpinned architecture sparc64 is refused"

echo "ALL TESTS PASSED"
