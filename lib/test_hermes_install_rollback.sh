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

_extract_fn() {
  awk -v fn="$2" '$0 == fn"() {" , $0 == "}"' "$1"
}

VRESET_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _hermes_venv_reset)"
BDIR_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _hermes_backup_dir)"
TREEOK_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _hermes_tree_complete)"
BMARKER_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _hermes_backup_marker)"
PREVREAL_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _hermes_prev_is_real_dir)"
BISCOMPLETE_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _hermes_backup_is_complete)"
BUNWIND_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _hermes_backup_take_unwind)"
RECOVER_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _hermes_recover_stale_backup)"
BTAKE_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _hermes_backup_take)"
BCOMMIT_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _hermes_backup_commit)"
BRESTORE_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _hermes_backup_restore)"
RHI_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _run_hermes_install)"
WIPE_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _wipe_volume)"

for _fn in VRESET_FN BDIR_FN TREEOK_FN BMARKER_FN PREVREAL_FN BISCOMPLETE_FN BUNWIND_FN RECOVER_FN BTAKE_FN BCOMMIT_FN BRESTORE_FN RHI_FN WIPE_FN; do
  [ -n "${!_fn}" ] || _fail "cannot extract install-bins function for $_fn"
done

_seed_old_venv() {
  local root="$1"
  mkdir -p "$root/bin" "$root/lib/marker-pkg"
  printf 'old-pip\n' > "$root/bin/pip"
  printf 'old-python\n' > "$root/bin/python"
  printf 'old-hermes\n' > "$root/bin/hermes"
  printf 'old-marker-contents\n' > "$root/lib/marker-pkg/data.txt"
  printf 'old-stamp\n' > "$root/.cbox-stamp"
  chmod 0755 "$root/bin/pip" "$root/bin/python" "$root/bin/hermes"
}

_snapshot() {
  local root="$1"
  ( cd "$root" && find . -mindepth 1 ! -name '.prev' ! -path './.prev/*' -type f -exec sha256sum {} + 2>/dev/null \
    | LC_ALL=C sort ) > "$TMPBASE/snap_$2"
}

_common_preamble() {
  printf '%s\n' \
    "$VRESET_FN" "$BDIR_FN" "$TREEOK_FN" "$BMARKER_FN" "$PREVREAL_FN" "$BISCOMPLETE_FN" \
    "$BUNWIND_FN" "$RECOVER_FN" \
    "$BTAKE_FN" "$BCOMMIT_FN" "$BRESTORE_FN" "$RHI_FN" \
    'chown() { :; }' \
    '_hxgosu() { "$@"; }' \
    '_hermes_stamp_install_method() { echo STAMPED >> "'"$TMPBASE"'/install_method.log"; return 0; }'
}

_run_install() {
  local root="$1" pip_mode="$2" version="$3" verify_mode="${4:-ok}" stamp_mode="${5:-ok}"
  CBOX_HERMES_VERSION="$version" HXROOT="$root" HOST_UID="$(id -u)" HOST_GID="$(id -g)" \
    PIP_MODE="$pip_mode" VERIFY_MODE="$verify_mode" STAMP_MODE="$stamp_mode" bash -c '
    set -u
    '"$(_common_preamble)"'
    python3() {
      shift
      shift
      local target="$1"
      mkdir -p "$target/bin" "$target/lib/marker-pkg"
      printf "new-python\n" > "$target/bin/python"
      printf "new-hermes\n" > "$target/bin/hermes"
      chmod 0755 "$target/bin/python" "$target/bin/hermes"
      cat > "$target/bin/pip" <<EOF
#!/bin/sh
if [ "\$PIP_MODE" = fail ]; then
  echo "pip: transient network failure" >&2
  exit 1
fi
echo "new-marker-contents" > "$target/lib/marker-pkg/data.txt"
exit 0
EOF
      chmod 0755 "$target/bin/pip"
    }
    export PIP_MODE
    _hermes_seed_delegate_home() { echo SEEDED >> "'"$TMPBASE"'/seed.log"; return 0; }
    _stamp_path() { printf "%s/.cbox-stamp" "$HXROOT"; }
    _want_string() { printf "latest"; }
    _verify_tool() {
      if [ "$VERIFY_MODE" = fail ]; then
        echo "verify: injected failure" >&2
        return 1
      fi
      printf "%s/bin/hermes\nfakehash\n1.2.3\n" "$HXROOT"
    }
    _stamp_write() {
      if [ "$STAMP_MODE" = fail ]; then
        echo "stamp: injected failure" >&2
        return 1
      fi
      printf "%s\n%s\n%s\n%s\n" "$2" "$3" "$4" "$5" > "$1"
    }
    _run_hermes_install
  ' install
}

echo "--- case a: transient pip failure restores the previous tree bytewise ---"
RA="$TMPBASE/case-a/opt-hermes"
mkdir -p "$RA"
_seed_old_venv "$RA"
_snapshot "$RA" before_a
rc=0
_run_install "$RA" fail latest >"$TMPBASE/a.out" 2>"$TMPBASE/a.err" || rc=$?
[ "$rc" != 0 ] || _fail "case a: _run_hermes_install must fail when pip fails"
[ -f "$RA/.prev" ] && _fail "case a: .prev must never be a file"
[ -d "$RA/.prev" ] && _fail "case a: .prev must not survive a failed refresh"
_snapshot "$RA" after_a
diff "$TMPBASE/snap_before_a" "$TMPBASE/snap_after_a" >/dev/null \
  || _fail "case a: restored tree does not match the pre-refresh tree bytewise"
[ "$(cat "$RA/.cbox-stamp")" = "old-stamp" ] || _fail "case a: old .cbox-stamp must be restored"
[ "$(cat "$RA/bin/pip")" = "old-pip" ] || _fail "case a: old pip binary must be restored"
_ok "hermes install rollback: transient pip failure restores the previous tree bytewise, no .prev left"

echo "--- case b: successful refresh leaves the new tree with no .prev ---"
RB="$TMPBASE/case-b/opt-hermes"
mkdir -p "$RB"
_seed_old_venv "$RB"
rc=0
_run_install "$RB" ok latest >"$TMPBASE/b.out" 2>"$TMPBASE/b.err" || rc=$?
[ "$rc" = 0 ] || _fail "case b: _run_hermes_install must succeed when pip succeeds: $(cat "$TMPBASE/b.err")"
[ -e "$RB/.prev" ] && _fail "case b: .prev must not survive a successful refresh"
[ "$(cat "$RB/bin/python")" = "new-python" ] || _fail "case b: new venv binaries must be in place"
[ "$(cat "$RB/lib/marker-pkg/data.txt")" = "new-marker-contents" ] || _fail "case b: new package contents must be in place"
grep -q SEEDED "$TMPBASE/seed.log" || _fail "case b: seed step must have run"
[ "$(sed -n '1p' "$RB/.cbox-stamp" 2>/dev/null)" = "latest" ] || _fail "case b: stamp must be written on full success"
_ok "hermes install rollback: successful refresh leaves the new tree with no .prev"

echo "--- case c: fresh empty-volume install still works with no .prev ---"
RC_="$TMPBASE/case-c/opt-hermes"
rc=0
_run_install "$RC_" ok latest >"$TMPBASE/c.out" 2>"$TMPBASE/c.err" || rc=$?
[ "$rc" = 0 ] || _fail "case c: fresh empty-volume install must succeed: $(cat "$TMPBASE/c.err")"
[ -e "$RC_/.prev" ] && _fail "case c: fresh install must never create .prev"
[ "$(cat "$RC_/bin/python")" = "new-python" ] || _fail "case c: fresh install must produce a new venv"
_ok "hermes install rollback: fresh empty-volume install behaves as a plain install with no backup"

echo "--- case d: backup_take itself fails partway through (mv error) still triggers restore ---"
RD="$TMPBASE/case-d/opt-hermes"
mkdir -p "$RD"
_seed_old_venv "$RD"
_snapshot "$RD" before_d
rc=0
CBOX_HERMES_VERSION=latest HXROOT="$RD" HOST_UID="$(id -u)" HOST_GID="$(id -g)" bash -c '
  set -u
  '"$(_common_preamble)"'
  MV_CALLS=0
  mv() {
    MV_CALLS=$((MV_CALLS + 1))
    if [ "$MV_CALLS" -eq 2 ]; then
      echo "mv: injected failure on call 2" >&2
      return 1
    fi
    command mv "$@"
  }
  python3() { :; }
  _hermes_seed_delegate_home() { :; }
  _stamp_path() { printf "%s/.cbox-stamp" "$HXROOT"; }
  _want_string() { printf "latest"; }
  _verify_tool() { printf "%s/bin/hermes\nfakehash\n1.2.3\n" "$HXROOT"; }
  _stamp_write() { printf "%s\n%s\n%s\n%s\n" "$2" "$3" "$4" "$5" > "$1"; }
  _run_hermes_install
' >"$TMPBASE/d.out" 2>"$TMPBASE/d.err" || rc=$?
[ "$rc" != 0 ] || _fail "case d: _run_hermes_install must fail when backup_take mv fails"
[ -d "$RD/.prev" ] && _fail "case d: partial backup must have been restored, .prev must not survive"
_snapshot "$RD" after_d
diff "$TMPBASE/snap_before_d" "$TMPBASE/snap_after_d" >/dev/null \
  || _fail "case d: tree left inconsistent after a mid-backup mv failure: $(cat "$TMPBASE/d.err")"
_ok "hermes install rollback: a mid-backup_take mv failure still restores the previous tree"

echo "--- case e: verification failure after a successful pip+seed still restores the previous tree ---"
RE="$TMPBASE/case-e/opt-hermes"
mkdir -p "$RE"
_seed_old_venv "$RE"
_snapshot "$RE" before_e
rc=0
_run_install "$RE" ok latest fail ok >"$TMPBASE/e.out" 2>"$TMPBASE/e.err" || rc=$?
[ "$rc" != 0 ] || _fail "case e: _run_hermes_install must fail when post-install verification fails"
[ -d "$RE/.prev" ] && _fail "case e: .prev must not survive a verification failure"
_snapshot "$RE" after_e
diff "$TMPBASE/snap_before_e" "$TMPBASE/snap_after_e" >/dev/null \
  || _fail "case e: tree left inconsistent after a verification failure: $(cat "$TMPBASE/e.err")"
[ "$(cat "$RE/.cbox-stamp")" = "old-stamp" ] || _fail "case e: old .cbox-stamp must be restored on verify failure"
_ok "hermes install rollback: verification failure restores the previous tree, old stamp intact"

echo "--- case f: stamp-write failure after a successful pip+seed+verify still restores the previous tree ---"
RF="$TMPBASE/case-f/opt-hermes"
mkdir -p "$RF"
_seed_old_venv "$RF"
_snapshot "$RF" before_f
rc=0
_run_install "$RF" ok latest ok fail >"$TMPBASE/f.out" 2>"$TMPBASE/f.err" || rc=$?
[ "$rc" != 0 ] || _fail "case f: _run_hermes_install must fail when the stamp write fails"
[ -d "$RF/.prev" ] && _fail "case f: .prev must not survive a stamp-write failure"
_snapshot "$RF" after_f
diff "$TMPBASE/snap_before_f" "$TMPBASE/snap_after_f" >/dev/null \
  || _fail "case f: tree left inconsistent after a stamp-write failure: $(cat "$TMPBASE/f.err")"
[ "$(cat "$RF/.cbox-stamp")" = "old-stamp" ] || _fail "case f: old .cbox-stamp must be restored on stamp-write failure"
_ok "hermes install rollback: stamp-write failure restores the previous tree, old stamp intact"

echo "--- case g: a stale .prev from an interrupted previous run is recovered when the live tree is incomplete ---"
RG="$TMPBASE/case-g/opt-hermes"
mkdir -p "$RG/.prev"
_seed_old_venv "$RG/.prev"
: > "$RG/.prev/.cbox-backup-complete"
mkdir -p "$RG/bin"
printf 'half-written\n' > "$RG/bin/pip"
rc=0
_run_install "$RG" ok latest >"$TMPBASE/g.out" 2>"$TMPBASE/g.err" || rc=$?
[ "$rc" = 0 ] || _fail "case g: install after stale .prev recovery must succeed: $(cat "$TMPBASE/g.err")"
[ -e "$RG/.prev" ] && _fail "case g: .prev must not survive after recovery and a fresh successful install"
[ "$(cat "$RG/bin/python")" = "new-python" ] || _fail "case g: recovered tree must have been used as the base for the new install"
grep -q SEEDED "$TMPBASE/seed.log" || _fail "case g: seed step must have run after recovery"
_ok "hermes install rollback: stale .prev from an interrupted run is recovered as the last good install, not destroyed"

echo "--- case g2: a .prev with no completion marker (crash mid-backup_take) is never combined with an incomplete live tree ---"
RG2="$TMPBASE/case-g2/opt-hermes"
mkdir -p "$RG2/.prev/bin" "$RG2/.prev/lib/marker-pkg"
printf 'fragment-a\n' > "$RG2/.prev/bin/pip"
printf 'fragment-b\n' > "$RG2/.prev/lib/marker-pkg/data.txt"
mkdir -p "$RG2/bin"
printf 'half-written\n' > "$RG2/bin/pip"
_snapshot "$RG2" before_g2
rc=0
_run_install "$RG2" ok latest >"$TMPBASE/g2.out" 2>"$TMPBASE/g2.err" || rc=$?
[ "$rc" != 0 ] || _fail "case g2: install must refuse when .prev has no completion marker and the live tree is incomplete"
grep -q "missing completion marker" "$TMPBASE/g2.err" || _fail "case g2: refusal must name the missing completion marker: $(cat "$TMPBASE/g2.err")"
[ -d "$RG2/.prev" ] || _fail "case g2: the unmarked .prev fragment must be left in place, not wiped"
_snapshot "$RG2" after_g2
diff "$TMPBASE/snap_before_g2" "$TMPBASE/snap_after_g2" >/dev/null \
  || _fail "case g2: refusing to combine fragments must not touch either fragment: $(cat "$TMPBASE/g2.err")"
_ok "hermes install rollback: a .prev with no completion marker fails closed instead of silently combining fragments with an incomplete live tree"

echo "--- case h: a stale .prev is discarded when the live tree is already complete ---"
RH="$TMPBASE/case-h/opt-hermes"
mkdir -p "$RH/.prev"
printf 'orphan-marker\n' > "$RH/.prev/orphan.txt"
_seed_old_venv "$RH"
rc=0
_run_install "$RH" ok latest >"$TMPBASE/h.out" 2>"$TMPBASE/h.err" || rc=$?
[ "$rc" = 0 ] || _fail "case h: install with a stale .prev beside a complete live tree must succeed: $(cat "$TMPBASE/h.err")"
[ -e "$RH/.prev" ] && _fail "case h: stale .prev beside a complete live tree must not survive"
[ "$(cat "$RH/bin/python")" = "new-python" ] || _fail "case h: the complete live tree must have been used as the base for the new install"
_ok "hermes install rollback: a stale .prev beside a complete live tree is discarded, live tree wins"

echo "--- case h2: a symlinked .prev is refused, never followed, live tree left untouched ---"
RH2="$TMPBASE/case-h2/opt-hermes"
mkdir -p "$RH2"
_seed_old_venv "$RH2"
OUTSIDE="$TMPBASE/case-h2/outside-target"
mkdir -p "$OUTSIDE"
printf 'should-never-be-touched\n' > "$OUTSIDE/sentinel.txt"
ln -s "$OUTSIDE" "$RH2/.prev"
_snapshot "$RH2" before_h2
rc=0
_run_install "$RH2" ok latest >"$TMPBASE/h2.out" 2>"$TMPBASE/h2.err" || rc=$?
[ "$rc" != 0 ] || _fail "case h2: install must refuse when .prev is a symlink, even beside a complete live tree"
grep -q "is a symlink, not a real directory" "$TMPBASE/h2.err" || _fail "case h2: refusal must name the symlink: $(cat "$TMPBASE/h2.err")"
[ -L "$RH2/.prev" ] || _fail "case h2: the symlink itself must be left in place for the operator to inspect"
[ "$(cat "$OUTSIDE/sentinel.txt")" = "should-never-be-touched" ] || _fail "case h2: the symlink target must never be modified"
_snapshot "$RH2" after_h2
diff "$TMPBASE/snap_before_h2" "$TMPBASE/snap_after_h2" >/dev/null \
  || _fail "case h2: refusing a symlinked .prev must not touch the live tree: $(cat "$TMPBASE/h2.err")"
_ok "hermes install rollback: a symlinked .prev is refused outright, never followed or wiped"

echo "--- case i: force mode does not wipe the volume before the install lock is held ---"
RI="$TMPBASE/case-i/opt-hermes"
mkdir -p "$RI"
_seed_old_venv "$RI"
HXROOT="$RI" HOST_UID="$(id -u)" HOST_GID="$(id -g)" bash -c '
  set -u
  '"$WIPE_FN"'
  (
    exec 9< "'"$RI"'"
    flock 9
    echo HOLDER_ACQUIRED >> "'"$TMPBASE"'/lock.log"
    sleep 0.4
    echo HOLDER_RELEASING >> "'"$TMPBASE"'/lock.log"
  ) &
  HOLDER_PID=$!
  while ! grep -q HOLDER_ACQUIRED "'"$TMPBASE"'/lock.log" 2>/dev/null; do sleep 0.02; done
  _wipe_volume "$HXROOT"
  echo WIPE_RETURNED >> "'"$TMPBASE"'/lock.log"
  wait "$HOLDER_PID"
' >"$TMPBASE/i.out" 2>"$TMPBASE/i.err"
[ -f "$TMPBASE/lock.log" ] || _fail "case i: lock log missing: $(cat "$TMPBASE/i.err")"
grep -qx HOLDER_ACQUIRED "$TMPBASE/lock.log" || _fail "case i: lock holder never acquired the lock"
release_line="$(grep -n '^HOLDER_RELEASING$' "$TMPBASE/lock.log" | head -1 | cut -d: -f1)"
wipe_line="$(grep -n '^WIPE_RETURNED$' "$TMPBASE/lock.log" | head -1 | cut -d: -f1)"
[ -n "$release_line" ] && [ -n "$wipe_line" ] || _fail "case i: missing release/wipe markers: $(cat "$TMPBASE/lock.log")"
[ "$wipe_line" -gt "$release_line" ] || _fail "case i: _wipe_volume returned before the install lock was released - it wiped without waiting for the lock"
[ "$(cat "$RI/bin/pip" 2>/dev/null)" != "old-pip" ] || _fail "case i: wipe must have run (old tree must be gone) once the lock was free"
_ok "hermes install rollback: force wipe of the hermes volume waits for the install lock instead of racing it"

echo "ALL TESTS PASSED"
