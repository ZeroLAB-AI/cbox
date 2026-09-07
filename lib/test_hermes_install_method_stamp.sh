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

STAMP_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _hermes_stamp_install_method)"
RHI_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _run_hermes_install)"
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

for _fn in STAMP_FN RHI_FN VRESET_FN BDIR_FN TREEOK_FN BMARKER_FN PREVREAL_FN BISCOMPLETE_FN BUNWIND_FN RECOVER_FN BTAKE_FN BCOMMIT_FN BRESTORE_FN; do
  [ -n "${!_fn}" ] || _fail "cannot extract install-bins function for $_fn"
done

grep -q '_hermes_stamp_install_method' <<< "$RHI_FN" \
  || _fail "_run_hermes_install no longer calls _hermes_stamp_install_method - the postinstall PyPI-skip stamp would silently stop being written"
_ok "_run_hermes_install still calls _hermes_stamp_install_method in its success chain"

REAL_PYTHON3="$(command -v python3)"
[ -n "$REAL_PYTHON3" ] || _fail "no python3 on PATH to build the fake venv fixture"

_make_fake_venv_python() {
  local target="$1" site
  site="$target/lib/python3.x/site-packages"
  mkdir -p "$target/bin" "$site/hermes_cli"
  : > "$site/hermes_cli/__init__.py"
  cat > "$target/bin/python" << EOF
#!/bin/sh
PYTHONPATH="$site" exec "$REAL_PYTHON3" "\$@"
EOF
  chmod 0755 "$target/bin/python"
  printf '%s\n' "$site"
}

echo "--- case a: _hermes_stamp_install_method writes docker next to the resolved hermes_cli package, not a hardcoded offset from HXROOT ---"
RA="$TMPBASE/case-a/opt-hermes"
site_a="$(_make_fake_venv_python "$RA")"
rc=0
HXROOT="$RA" bash -c '
  set -u
  '"$STAMP_FN"'
  _hxgosu() { "$@"; }
  _hermes_stamp_install_method
' >"$TMPBASE/a.out" 2>"$TMPBASE/a.err" || rc=$?
[ "$rc" = 0 ] || _fail "case a: _hermes_stamp_install_method must succeed against a well-formed fake venv: $(cat "$TMPBASE/a.err")"
[ -f "$site_a/.install_method" ] || _fail "case a: .install_method must be written next to hermes_cli's resolved parent directory ($site_a)"
[ -f "$RA/.install_method" ] && _fail "case a: .install_method must not be written directly under HXROOT (that would be a hardcoded-offset bug, not a resolved-package-location stamp)"
[ "$(cat "$site_a/.install_method")" = "docker" ] || _fail "case a: .install_method must contain exactly 'docker', got: $(cat "$site_a/.install_method")"
_ok "hermes install_method stamp: written at the resolved hermes_cli parent directory, content 'docker'"

echo "--- case b: a full successful _run_hermes_install leaves the real stamp (unstubbed) in place ---"
RB="$TMPBASE/case-b/opt-hermes"
mkdir -p "$RB"
SITE_B_LOG="$TMPBASE/site_b.path"
rc=0
CBOX_HERMES_VERSION=latest HXROOT="$RB" HOST_UID="$(id -u)" HOST_GID="$(id -g)" \
  REAL_PYTHON3="$REAL_PYTHON3" SITE_B_LOG="$SITE_B_LOG" bash -c '
  set -u
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
  '"$STAMP_FN"'
  '"$RHI_FN"'
  chown() { :; }
  _hxgosu() { "$@"; }
  python3() {
    shift; shift
    local target="$1" site="$1/lib/python3.x/site-packages"
    mkdir -p "$target/bin" "$site/hermes_cli"
    : > "$site/hermes_cli/__init__.py"
    printf "%s\n" "$site" > "$SITE_B_LOG"
    cat > "$target/bin/python" <<PYEOF
#!/bin/sh
PYTHONPATH="$site" exec "$REAL_PYTHON3" "\$@"
PYEOF
    chmod 0755 "$target/bin/python"
    printf "new-hermes\n" > "$target/bin/hermes"
    chmod 0755 "$target/bin/hermes"
    printf "#!/bin/sh\nexit 0\n" > "$target/bin/pip"
    chmod 0755 "$target/bin/pip"
  }
  _hermes_seed_delegate_home() { return 0; }
  _stamp_path() { printf "%s/.cbox-stamp" "$HXROOT"; }
  _want_string() { printf "latest"; }
  _verify_tool() { printf "%s/bin/hermes\nfakehash\n1.2.3\n" "$HXROOT"; }
  _stamp_write() { printf "%s\n%s\n%s\n%s\n" "$2" "$3" "$4" "$5" > "$1"; }
  _run_hermes_install
' >"$TMPBASE/b.out" 2>"$TMPBASE/b.err" || rc=$?
[ "$rc" = 0 ] || _fail "case b: _run_hermes_install must succeed end to end: $(cat "$TMPBASE/b.err")"
[ -f "$SITE_B_LOG" ] || _fail "case b: fake python3 -m venv stub never ran"
site_b="$(cat "$SITE_B_LOG")"
[ -f "$site_b/.install_method" ] || _fail "case b: a successful hermes install must leave .install_method next to hermes_cli ($site_b)"
[ "$(cat "$site_b/.install_method")" = "docker" ] || _fail "case b: .install_method must contain 'docker' after a successful install"
_ok "hermes install: a full successful _run_hermes_install run (real stamp step, unstubbed) writes .install_method=docker"

echo "--- case c: when the stamp step cannot resolve hermes_cli (broken install), the whole install fails instead of silently skipping the stamp ---"
RC_="$TMPBASE/case-c/opt-hermes"
mkdir -p "$RC_"
rc=0
CBOX_HERMES_VERSION=latest HXROOT="$RC_" HOST_UID="$(id -u)" HOST_GID="$(id -g)" \
  REAL_PYTHON3="$REAL_PYTHON3" bash -c '
  set -u
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
  '"$STAMP_FN"'
  '"$RHI_FN"'
  chown() { :; }
  _hxgosu() { "$@"; }
  python3() {
    shift; shift
    local target="$1"
    mkdir -p "$target/bin"
    cat > "$target/bin/python" <<PYEOF
#!/bin/sh
exec "$REAL_PYTHON3" "\$@"
PYEOF
    chmod 0755 "$target/bin/python"
    printf "new-hermes\n" > "$target/bin/hermes"
    chmod 0755 "$target/bin/hermes"
    printf "#!/bin/sh\nexit 0\n" > "$target/bin/pip"
    chmod 0755 "$target/bin/pip"
  }
  _hermes_seed_delegate_home() { echo "case c: must not run when the stamp step fails first" >> "'"$TMPBASE"'/c_seed.log"; return 0; }
  _stamp_path() { printf "%s/.cbox-stamp" "$HXROOT"; }
  _want_string() { printf "latest"; }
  _verify_tool() { printf "%s/bin/hermes\nfakehash\n1.2.3\n" "$HXROOT"; }
  _stamp_write() { printf "%s\n%s\n%s\n%s\n" "$2" "$3" "$4" "$5" > "$1"; }
  _run_hermes_install
' >"$TMPBASE/c.out" 2>"$TMPBASE/c.err" || rc=$?
[ "$rc" != 0 ] || _fail "case c: _run_hermes_install must fail when hermes_cli cannot be imported for the stamp step (no venv given, install would silently skip the PyPI-skip stamp otherwise)"
[ -f "$TMPBASE/c_seed.log" ] && _fail "case c: the delegate-home seed step must not run once the stamp step has failed"
_ok "hermes install: a stamp-step failure (hermes_cli unresolvable) fails the whole install instead of shipping an unstamped tree"

echo "ALL TESTS PASSED"
