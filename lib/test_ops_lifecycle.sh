#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$INSTALL_DIR"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

unset CBOX_CLAUDE_TARGET CBOX_CODEX_VERSION CBOX_CODEX_TARGET CBOX_HERMES CBOX_HERMES_VERSION CBOX_INSTALL_FORCE CBOX_AUTOUPDATE CBOX_AUTOUPDATE_TTL_HOURS CBOX_BINS_SCOPE

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

REAP_FN="$(_extract_fn "$INSTALL_DIR/cbox" _reap)"
AUP_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_autoupdate)"
CHAN_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_channel)"
EOFF_FN="$(_extract_fn "$INSTALL_DIR/cbox" _engine_autoupdate_off)"
HON_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_hermes_on)"
INST_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _install_one)"
WANT_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _want_string)"
SPATH_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _stamp_path)"
COMPAT_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _want_compat)"
RHB_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _resolve_hermes_bin)"
HHASH_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _hermes_hash)"
RHI_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _run_hermes_install)"
CUP_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_compose_up)"
CDIG_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_compose_files_digest)"
RIB_FN="$(_extract_fn "$INSTALL_DIR/cbox" reinstall_bins)"
BCR_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_conflict_report)"
[ -n "$HON_FN" ] || _fail "cannot extract _bins_hermes_on"
for _fn in WANT_FN SPATH_FN RHB_FN HHASH_FN RHI_FN; do
  [ -n "${!_fn}" ] || _fail "cannot extract install-bins function for $_fn"
done
[ -n "$REAP_FN" ] || _fail "cannot extract _reap"
[ -n "$AUP_FN" ] || _fail "cannot extract _bins_autoupdate"
[ -n "$CHAN_FN" ] || _fail "cannot extract _bins_channel"
[ -n "$EOFF_FN" ] || _fail "cannot extract _engine_autoupdate_off"
[ -n "$INST_FN" ] || _fail "cannot extract _install_one"
[ -n "$CUP_FN" ] || _fail "cannot extract _cbox_compose_up"
[ -n "$CDIG_FN" ] || _fail "cannot extract _cbox_compose_files_digest"
[ -n "$RIB_FN" ] || _fail "cannot extract reinstall_bins"
[ -n "$BCR_FN" ] || _fail "cannot extract _bins_conflict_report"

run_reap() {
  local probe1="$1" probe2="$2" out
  out="$(INSTALL_DIR="$INSTALL_DIR" bash -c '
    set -u
    eff="$1"; probe1="$2"; probe2="$3"
    source "$INSTALL_DIR/lib/portable.sh"
    '"$REAP_FN"'
    _compose_p() {
      if [ "$2" = ps ]; then printf "fakecid\n"; return 0; fi
      if [ "$2" = down ]; then echo DOWNED >> "$eff/actions"; return 0; fi
      return 0
    }
    : > "$eff/probe.count"
    _probe() {
      echo x >> "$eff/probe.count"
      if [ "$(wc -l < "$eff/probe.count")" = 1 ]; then printf "%s" "$probe1"; else printf "%s" "$probe2"; fi
    }
    sleep() { :; }
    _reap "$eff"
  ' reap "$TMPBASE/eff" "$probe1" "$probe2" 2>&1)" || true
  printf '%s' "$out"
}

mkdir -p "$TMPBASE/eff"
: > "$TMPBASE/eff/actions"
run_reap 0 0 >/dev/null
grep -q DOWNED "$TMPBASE/eff/actions" || _fail "reap: n=0 must down"
_ok "reap: n=0 downs the container"

: > "$TMPBASE/eff/actions"
run_reap garbage 0 >/dev/null
grep -q DOWNED "$TMPBASE/eff/actions" || _fail "reap: retry after bad probe must down on 0"
_ok "reap: bad probe retried, second 0 downs"

: > "$TMPBASE/eff/actions"
out="$(run_reap garbage garbage)"
grep -q DOWNED "$TMPBASE/eff/actions" && _fail "reap: persistent probe failure must not down"
printf '%s' "$out" | grep -q "probe failed" || _fail "reap: persistent probe failure must warn"
_ok "reap: persistent probe failure leaves container up and warns"

: > "$TMPBASE/eff/actions"
run_reap 2 2 >/dev/null
grep -q DOWNED "$TMPBASE/eff/actions" && _fail "reap: live processes must not down"
_ok "reap: live processes keep container up"

run_autoupdate() {
  INSTALL_DIR="$INSTALL_DIR" bash -c '
    set -u
    HOME="$1"; export HOME
    source "$INSTALL_DIR/lib/portable.sh"
    '"$AUP_FN"'
    '"$CHAN_FN"'
    '"$EOFF_FN"'
    '"$HON_FN"'
    _cbox_bins_volume() { printf "vol-%s" "$1"; }
    _bins_lock_file() { printf "%s/bins.lock" "$HOME"; }
    _bins_run_install() { printf "%s\n" "$2|$3" >> "$HOME/install.calls"; }
    _bins_autoupdate img
  ' aup "$1"
}

H="$TMPBASE/h1"
mkdir -p "$H/.config/cbox"
run_autoupdate "$H" >/dev/null
grep -q "claude codex|refresh" "$H/install.calls" || _fail "autoupdate: due tools must install with refresh"
grep -q "|1$" "$H/install.calls" && _fail "autoupdate: must never use force=1"
[ -f "$H/.config/cbox/autoupdate.vol-claude.stamp" ] || _fail "autoupdate: claude stamp missing"
_ok "autoupdate: overdue channels refresh without force wipe"

run_autoupdate "$H" >/dev/null
[ "$(wc -l < "$H/install.calls")" = 1 ] || _fail "autoupdate: fresh stamp must skip install"
_ok "autoupdate: fresh stamp skips within TTL"

H2="$TMPBASE/h2"
mkdir -p "$H2/.config/cbox" "$H2/.claude"
printf '{\n  "autoUpdates": false\n}\n' > "$H2/.claude/settings.json"
run_autoupdate "$H2" >/dev/null
grep -q "claude" "$H2/install.calls" 2>/dev/null && _fail "autoupdate: claude optout must skip claude"
grep -q "codex|refresh" "$H2/install.calls" || _fail "autoupdate: codex must still refresh"
_ok "autoupdate: engine opt-out respected"

H3="$TMPBASE/h3"
mkdir -p "$H3/.config/cbox"
CBOX_CLAUDE_TARGET=1.2.3 CBOX_CODEX_VERSION=0.1.0 INSTALL_DIR="$INSTALL_DIR" bash -c '
  set -u
  HOME="$1"; export HOME
  source "$INSTALL_DIR/lib/portable.sh"
  '"$AUP_FN"'
  '"$CHAN_FN"'
  '"$EOFF_FN"'
  '"$HON_FN"'
  _cbox_bins_volume() { printf "vol-%s" "$1"; }
  _bins_lock_file() { printf "%s/bins.lock" "$HOME"; }
  _bins_run_install() { printf "%s\n" "$2|$3" >> "$HOME/install.calls"; }
  _bins_autoupdate img
' aup "$H3" >/dev/null
[ -f "$H3/install.calls" ] && _fail "autoupdate: pinned versions must never refresh"
_ok "autoupdate: pinned versions never refresh"

run_autoupdate_hermes() {
  CBOX_HERMES="$2" CBOX_HERMES_VERSION="$3" INSTALL_DIR="$INSTALL_DIR" bash -c '
    set -u
    HOME="$1"; export HOME
    source "$INSTALL_DIR/lib/portable.sh"
    '"$AUP_FN"'
    '"$CHAN_FN"'
    '"$EOFF_FN"'
    '"$HON_FN"'
    _cbox_bins_volume() { printf "vol-%s" "$1"; }
    _bins_lock_file() { printf "%s/bins.lock" "$HOME"; }
    _bins_run_install() { printf "%s\n" "$2|$3" >> "$HOME/install.calls"; }
    _bins_autoupdate img
  ' aup "$1"
}

H4="$TMPBASE/h4"
mkdir -p "$H4/.config/cbox"
run_autoupdate_hermes "$H4" on latest >/dev/null
grep -q "claude codex hermes|refresh" "$H4/install.calls" || _fail "autoupdate: hermes on latest must refresh with the other channels"
[ -f "$H4/.config/cbox/autoupdate.vol-hermes.stamp" ] || _fail "autoupdate: hermes stamp missing"
_ok "autoupdate: hermes latest refreshes as a channel"

H5="$TMPBASE/h5"
mkdir -p "$H5/.config/cbox"
run_autoupdate_hermes "$H5" on 0.19.0 >/dev/null
grep -q "hermes" "$H5/install.calls" && _fail "autoupdate: pinned hermes must never refresh"
grep -q "claude codex|refresh" "$H5/install.calls" || _fail "autoupdate: pinned hermes must not block the other channels"
_ok "autoupdate: pinned hermes never refreshes"

H6="$TMPBASE/h6"
mkdir -p "$H6/.config/cbox"
run_autoupdate_hermes "$H6" off latest >/dev/null
grep -q "hermes" "$H6/install.calls" && _fail "autoupdate: hermes off must stay out of the refresh set"
_ok "autoupdate: hermes off stays out of the refresh set"

run_install_one() {
  bash -c '
    set -u
    force="$1"; marker="$2"
    CBOX_INSTALL_FORCE="$force"
    CLROOT=/nonexistent-clroot
    CXPKG=/nonexistent-cxpkg
    '"$INST_FN"'
    _want_string() { printf "stable"; }
    _stamp_path() { printf "%s/stamp" "$marker"; }
    _wipe_volume() { echo WIPED >> "$marker/actions"; }
    _adopt_check() { return 0; }
    _stamp_field() { printf "stable"; }
    _run_claude_install() { echo INSTALLED >> "$marker/actions"; }
    _run_codex_install() { echo INSTALLED >> "$marker/actions"; }
    _verify_tool() { printf "/p\nh\nv\n"; }
    _stamp_write() { :; }
    _install_one claude || true
  ' inst "$1" "$2"
}

M="$TMPBASE/inst"
mkdir -p "$M"
printf 'stable\n/p\nh\nv\n' > "$M/stamp"
: > "$M/actions"
run_install_one refresh "$M" >/dev/null 2>&1
grep -q WIPED "$M/actions" && _fail "install-one: refresh must not wipe the volume"
grep -q INSTALLED "$M/actions" || _fail "install-one: refresh must run the installer"
_ok "install-one: refresh reinstalls in place without wipe"

: > "$M/actions"
run_install_one 0 "$M" >/dev/null 2>&1
grep -q INSTALLED "$M/actions" && _fail "install-one: force=0 with matching stamp must adopt"
_ok "install-one: force=0 adopts without reinstall"

run_install_one_hermes() {
  CBOX_HERMES_VERSION="$3" bash -c '
    set -u
    force="$1"; marker="$2"
    CBOX_INSTALL_FORCE="$force"
    CLROOT=/nonexistent-clroot
    CXPKG=/nonexistent-cxpkg
    HXROOT="$marker/opt-hermes"
    '"$INST_FN"'
    '"$WANT_FN"'
    '"$SPATH_FN"'
    '"$COMPAT_FN"'
    _wipe_volume() { echo WIPED >> "$marker/actions"; }
    _adopt_check() { [ -f "$marker/adopts" ]; }
    _stamp_field() { sed -n "${2}p" "$1" 2>/dev/null; }
    _run_hermes_install() {
      echo INSTALLED >> "$marker/actions"
      _HERMES_INSTALL_VERIFIED="$marker/opt-hermes/bin/hermes"
      _HERMES_INSTALL_HASH="h"
      _HERMES_INSTALL_VER="0.19.0"
      printf "%s\n%s\n%s\n%s\n" "$(_want_string hermes)" "$_HERMES_INSTALL_VERIFIED" "$_HERMES_INSTALL_HASH" "$_HERMES_INSTALL_VER" > "$marker/stamp.written"
    }
    _install_one hermes || echo "RC=$?" >> "$marker/actions"
  ' inst "$1" "$2"
}

HM="$TMPBASE/inst-hermes"
mkdir -p "$HM/opt-hermes"
: > "$HM/actions"
printf 'latest\n/p\nh\n0.19.0\n' > "$HM/opt-hermes/.cbox-stamp"
run_install_one_hermes refresh "$HM" latest >/dev/null 2>&1
grep -q WIPED "$HM/actions" && _fail "install-one hermes: refresh must not wipe the volume"
grep -q INSTALLED "$HM/actions" || _fail "install-one hermes: refresh must run the installer"
[ "$(sed -n '1p' "$HM/stamp.written")" = latest ] || _fail "install-one hermes: stamp must record the want tuple"
_ok "install-one hermes: refresh reinstalls in place without wipe"

: > "$HM/actions"; : > "$HM/adopts"
run_install_one_hermes 0 "$HM" latest >/dev/null 2>&1
grep -q INSTALLED "$HM/actions" && _fail "install-one hermes: force=0 with a matching stamp must adopt"
_ok "install-one hermes: force=0 adopts without reinstall"
rm -f "$HM/adopts"

: > "$HM/actions"
run_install_one_hermes 1 "$HM" latest >/dev/null 2>&1
grep -q WIPED "$HM/actions" || _fail "install-one hermes: force=1 must wipe the volume"
grep -q INSTALLED "$HM/actions" || _fail "install-one hermes: force=1 must run the installer"
_ok "install-one hermes: force=1 wipes then reinstalls"

: > "$HM/actions"
printf 'latest\n/p\nh\n0.19.0\n' > "$HM/opt-hermes/.cbox-stamp"
run_install_one_hermes 0 "$HM" 0.19.0 >/dev/null 2>&1
grep -q INSTALLED "$HM/actions" && _fail "install-one hermes: pin mismatch must refuse before installing"
grep -q "RC=1" "$HM/actions" || _fail "install-one hermes: pin mismatch must fail loudly"
_ok "install-one hermes: stamped channel vs requested pin refuses"

run_install_one_codex() {
  CBOX_CODEX_VERSION="$3" bash -c '
    set -u
    force="$1"; marker="$2"
    CBOX_INSTALL_FORCE="$force"
    CLROOT=/nonexistent-clroot
    CXPKG="$marker/cx"
    HXROOT=/nonexistent-hxroot
    '"$INST_FN"'
    '"$WANT_FN"'
    '"$SPATH_FN"'
    '"$COMPAT_FN"'
    _wipe_volume() { echo WIPED >> "$marker/actions"; }
    _adopt_check() { [ -f "$marker/adopts" ]; }
    _stamp_field() { sed -n "${2}p" "$1" 2>/dev/null; }
    _run_codex_install() { echo INSTALLED >> "$marker/actions"; return 1; }
    _install_one codex >> "$marker/signal" 2>/dev/null || echo "RC=$?" >> "$marker/actions"
  ' inst "$1" "$2"
}

CX="$TMPBASE/inst-codex"
mkdir -p "$CX/cx"

: > "$CX/actions"; : > "$CX/signal"
printf 'latest|\n/p\nh\n1.0.0\n' > "$CX/cx/.cbox-stamp"
run_install_one_codex 0 "$CX" latest >/dev/null 2>&1
grep -q refuse "$CX/signal" && _fail "install-one codex: a legacy version|target stamp must not read as a pin mismatch against the same version"
grep -q INSTALLED "$CX/actions" || _fail "install-one codex: after a legacy stamp matches, the install must proceed"
_ok "install-one codex: legacy 'version|target' stamp still matches the bare version want"

: > "$CX/actions"; : > "$CX/signal"
printf 'latest|x86_64-unknown-linux-musl\n/p\nh\n1.0.0\n' > "$CX/cx/.cbox-stamp"
run_install_one_codex 0 "$CX" latest >/dev/null 2>&1
grep -q refuse "$CX/signal" && _fail "install-one codex: a legacy stamp carrying a real target must still match the bare version"
_ok "install-one codex: legacy stamp with a populated target also matches"

: > "$CX/actions"; : > "$CX/signal"
printf 'latest|\n/p\nh\n1.0.0\n' > "$CX/cx/.cbox-stamp"
run_install_one_codex 0 "$CX" 0.149.1 >/dev/null 2>&1
grep -q refuse "$CX/signal" || _fail "install-one codex: a genuinely different pin must still refuse, legacy stamp or not"
grep -q INSTALLED "$CX/actions" && _fail "install-one codex: a refused pin must not reach the installer"
_ok "install-one codex: a real version change still refuses"

: > "$CX/actions"; : > "$CX/signal"
printf 'latest\n/p\nh\n1.0.0\n' > "$CX/cx/.cbox-stamp"
run_install_one_codex 0 "$CX" latest >/dev/null 2>&1
grep -q refuse "$CX/signal" && _fail "install-one codex: a current-format stamp must keep matching"
_ok "install-one codex: current-format stamp is unaffected"

HV="$TMPBASE/venv/opt-hermes"
mkdir -p "$HV/bin" "$HV/lib/python3.12/site-packages/hermes_agent-0.19.0.dist-info"
printf '#!/bin/sh\n' > "$HV/bin/hermes"; chmod 0755 "$HV/bin/hermes"
printf '#!/bin/sh\n' > "$HV/bin/python"; chmod 0755 "$HV/bin/python"
printf 'hermes_agent/__init__.py,sha256=abc,10\n' > "$HV/lib/python3.12/site-packages/hermes_agent-0.19.0.dist-info/RECORD"
run_hermes_probe() {
  HXROOT="$HV" bash -c '
    set -u
    '"$RHB_FN"'
    '"$HHASH_FN"'
    p="$(_resolve_hermes_bin)" || { echo RESOLVE_FAIL; exit 0; }
    printf "%s %s\n" "$p" "$(_hermes_hash "$p")"
  ' probe
}
out="$(run_hermes_probe)"
case "$out" in
  "$HV/bin/hermes "*) ;;
  *) _fail "resolve_hermes_bin did not resolve the venv console script: $out" ;;
esac
h0="${out##* }"
printf 'stale\n' > "$HV/.cbox-stamp"
[ "$(run_hermes_probe)" = "$out" ] || _fail "hermes_hash must ignore its own stamp file"
printf 'hermes_agent/__init__.py,sha256=TAMPERED,10\n' > "$HV/lib/python3.12/site-packages/hermes_agent-0.19.0.dist-info/RECORD"
h1="$(run_hermes_probe)"; h1="${h1##* }"
[ "$h1" != "$h0" ] || _fail "hermes_hash must change when a package file changes"
printf '#!/bin/sh\nexec /bin/evil\n' > "$HV/bin/hermes"; chmod 0755 "$HV/bin/hermes"
h2="$(run_hermes_probe)"; h2="${h2##* }"
[ "$h2" != "$h1" ] || _fail "hermes_hash must change when the executed console script changes"
_ok "hermes probe: resolves the venv script and tree-hashes everything it executes"

mv "$HV/bin/python" "$HV/bin/python.off"
[ "$(run_hermes_probe)" = RESOLVE_FAIL ] || _fail "resolve_hermes_bin must reject a venv without an interpreter"
mv "$HV/bin/python.off" "$HV/bin/python"
ln -sf /bin/sh "$HV/bin/hermes"
[ "$(run_hermes_probe)" = RESOLVE_FAIL ] || _fail "resolve_hermes_bin must reject a console script escaping the volume"
_ok "hermes probe: rejects a missing interpreter and an out-of-volume symlink"

bad_out="$(CBOX_HERMES_VERSION='0.19.0; rm -rf /' HXROOT="$TMPBASE/never" bash -c '
  set -u
  '"$RHI_FN"'
  _hermes_seed_delegate_home() { echo SEEDED; }
  _run_hermes_install && echo UNEXPECTED_OK
' badpin 2>&1 || true)"
case "$bad_out" in
  *UNEXPECTED_OK*|*SEEDED*) _fail "run_hermes_install accepted a malformed version target: $bad_out" ;;
esac
! [ -d "$TMPBASE/never" ] || _fail "run_hermes_install must reject the pin before creating the venv root"
_ok "run_hermes_install: malformed version target rejected before any pip or mkdir"

SPLIT_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_run_install)"
[ -n "$SPLIT_FN" ] || _fail "cannot extract _bins_run_install"
split_out="$(bash -c '
  set -u
  '"$SPLIT_FN"'
  _bins_run_install_group() { printf "group:%s\n" "$2"; }
  _bins_run_install img "claude codex hermes" refresh
' split)"
[ "$(printf '%s\n' "$split_out" | wc -l)" = 2 ] \
  || _fail "bins_run_install must split hermes into its own install container: $split_out"
printf '%s\n' "$split_out" | grep -qx 'group:claude codex' \
  || _fail "bins_run_install must keep claude+codex in one vendor group: $split_out"
printf '%s\n' "$split_out" | grep -qx 'group:hermes' \
  || _fail "bins_run_install must run hermes alone: $split_out"
_ok "bins_run_install: hermes never shares an install container with the writable claude/codex volumes"

VRESET_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _hermes_venv_reset)"
[ -n "$VRESET_FN" ] || _fail "cannot extract _hermes_venv_reset"
VR="$TMPBASE/vreset"
mkdir -p "$VR/bin" "$VR/lib"
printf 'planted\n' > "$VR/bin/pip"
printf 'keep\n' > "$VR/.cbox-stamp"
HXROOT="$VR" HOST_UID="$(id -u)" HOST_GID="$(id -g)" bash -c '
  set -u
  '"$VRESET_FN"'
  _hxgosu() { echo "VENV:$*" >> "'"$VR"'.calls"; }
  chown() { :; }
  _hermes_venv_reset
' vreset >/dev/null 2>&1 || true
[ -f "$VR/bin/pip" ] && _fail "hermes_venv_reset must delete the previous venv, including its pip"
! [ -f "$VR/.cbox-stamp" ] || _fail "hermes_venv_reset must drop the stamp so it never outlives the tree"
grep -q 'VENV:python3 -m venv' "$VR.calls" || _fail "hermes_venv_reset must recreate the venv as the host user"
_ok "hermes_venv_reset: previous venv (and its pip) is never reused across installs"

DNSOUT="$TMPBASE/dns.yml"
( INSTALL_DIR="$TMPBASE" . "$INSTALL_DIR/templates/generators.sh" 2>/dev/null || true
  CBOX_DNS_MODE=public CBOX_DNS_SERVERS='1.1.1.1 8.8.8.8' _cbox_dns_into "$DNSOUT"
  CBOX_DNS_MODE=public CBOX_DNS_SERVERS="" _cbox_dns_into "$DNSOUT" 2>>"$TMPBASE/dns.warn"
  CBOX_DNS_MODE=stub CBOX_DNS_STUB_IP=172.17.0.1 _cbox_dns_into "$DNSOUT"
  CBOX_DNS_MODE=stub CBOX_DNS_STUB_IP="bad;x" _cbox_dns_into "$DNSOUT" 2>/dev/null
  CBOX_DNS_MODE=stub CBOX_DNS_STUB_IP="" _cbox_dns_into "$DNSOUT" 2>>"$TMPBASE/dns.warn"
  CBOX_DNS_MODE=docker _cbox_dns_into "$DNSOUT"
  CBOX_CLIPBOARD_MODE=bridge _cbox_clip_env_into "$DNSOUT"
  CBOX_CLIPBOARD_MODE=bridge XDG_RUNTIME_DIR=/run/user/7 _cbox_clip_mounts_into "$DNSOUT" pXYZ
  CBOX_CLIPBOARD_MODE=off _cbox_clip_mounts_into "$DNSOUT" pXYZ )
grep -qx '      - 1.1.1.1' "$DNSOUT" || _fail "dns: public servers missing"
grep -qx '      - 172.17.0.1' "$DNSOUT" || _fail "dns: stub ip missing"
grep -q 'bad' "$DNSOUT" && _fail "dns: invalid server leaked into yaml"
grep -q 'CBOX_DNS_STUB_IP is empty' "$TMPBASE/dns.warn" || _fail "dns: empty stub must warn"
grep -q 'CBOX_DNS_SERVERS is empty' "$TMPBASE/dns.warn" || _fail "dns: empty public servers must warn instead of silently falling back to public resolvers"
[ "$(grep -cx '    dns:' "$DNSOUT")" = 2 ] || _fail "dns: docker mode must emit nothing"
grep -qx '      - CBOX_CLIP_SOCK=/run/cbox-clip/clip.sock' "$DNSOUT" || _fail "clip: env missing"
grep -qx '      - /run/user/7/cbox-clip-pXYZ:/run/cbox-clip' "$DNSOUT" || _fail "clip: sock dir mount missing"
[ "$(grep -c 'wl_paste_shim.py' "$DNSOUT")" = 1 ] || _fail "clip: off mode must emit nothing"
_ok "generators: dns and clipboard emission correct"

MANAGED="$TMPBASE/managed"
mkdir -p "$MANAGED/etc/claude" "$MANAGED/etc/adapters" "$MANAGED/generated/managed-settings.json"
cp "$INSTALL_DIR/etc/claude/managed-settings.merge.json" "$MANAGED/etc/claude/managed-settings.merge.json"
cp "$INSTALL_DIR/etc/adapters/claude.py" "$MANAGED/etc/adapters/claude.py"
(
  INSTALL_DIR="$MANAGED"
  HOME=/home/x
  export INSTALL_DIR HOME
  source "$PROJECT_DIR/templates/generators.sh"
  gen_managed_settings
  [ "$CBOX_MANAGED_SETTINGS_REPAIRED" = 1 ] || exit 1
  [ -f "$INSTALL_DIR/generated/managed-settings.json" ]
  python3 -m json.tool "$INSTALL_DIR/generated/managed-settings.json" >/dev/null
) || _fail "managed settings: empty Docker-created directory must become valid JSON"
_ok "managed settings: replaces empty Docker-created directory"

FORCE_OUT="$TMPBASE/force.out"
FORCE_OUT="$FORCE_OUT" TMPBASE="$TMPBASE" INSTALL_DIR="$INSTALL_DIR" bash -c '
  set -euo pipefail
  source "$INSTALL_DIR/lib/portable.sh"
  '"$CDIG_FN"'
  '"$CUP_FN"'
  fake_compose() {
    case "$1" in
      ps) printf "cid\\n" ;;
      up) printf "%s\\n" "$*" > "$FORCE_OUT" ;;
    esac
  }
  CBOX_MANAGED_SETTINGS_REPAIRED=1
  _cbox_compose_up "$TMPBASE/force.stamp" fake_compose
' || _fail "compose: managed-settings repair must recreate"
grep -qx 'up -d --force-recreate' "$FORCE_OUT" || _fail "compose: managed-settings repair must force recreate"
_ok "compose: managed-settings repair forces recreation"

RIB_INST="$TMPBASE/rib-install"
mkdir -p "$RIB_INST"
: > "$RIB_INST/image.inputs"

run_reinstall() {
  local h="$1"; shift
  INSTALL_DIR="$RIB_INST" bash -c '
    set -u
    h="$1"; shift
    '"$RIB_FN"'
    _cbox_effective_mode() { printf global; }
    require_global_conf() { :; }
    _cbox_image_tag() { printf img; }
    _cbox_image_hash() { printf hash; }
    docker() { :; }
    _bins_want() { printf latest; }
    _bins_conflict_report() { :; }
    _bins_hermes_on() { return 1; }
    _cbox_bins_volume() { printf "vol-%s" "$1"; }
    _cbox_probe_exes_seed() { :; }
    die() { echo "DIE: $*" >&2; exit 1; }
    _ensure_bins() { printf "%s\n" "${2:-}" >> "$h/ensure.calls"; }
    reinstall_bins "$@"
  ' rib "$h" "$@"
}

RH="$TMPBASE/rib-h"
mkdir -p "$RH"
CBOX_INSTALL_FORCE= run_reinstall "$RH" >/dev/null 2>&1
[ "$(cat "$RH/ensure.calls")" = 0 ] || _fail "reinstall: default must not force"
_ok "reinstall: default keeps force off"

: > "$RH/ensure.calls"
CBOX_INSTALL_FORCE=1 run_reinstall "$RH" >/dev/null 2>&1
[ "$(cat "$RH/ensure.calls")" = 1 ] || _fail "reinstall: CBOX_INSTALL_FORCE=1 must pass force to the install"
_ok "reinstall: CBOX_INSTALL_FORCE=1 moves the shared tuple"

: > "$RH/ensure.calls"
CBOX_INSTALL_FORCE=1 run_reinstall "$RH" --if-stale >/dev/null 2>&1
[ "$(cat "$RH/ensure.calls")" = 0 ] || _fail "reinstall: --if-stale must win over CBOX_INSTALL_FORCE"
_ok "reinstall: --if-stale overrides the env force"

: > "$RH/ensure.calls"
CBOX_INSTALL_FORCE=yes run_reinstall "$RH" >/dev/null 2>&1
[ "$(cat "$RH/ensure.calls")" = 0 ] || _fail "reinstall: only literal 1 may force"
_ok "reinstall: non-literal force values stay off"

: > "$RH/ensure.calls"
CBOX_INSTALL_FORCE= run_reinstall "$RH" --fresh >/dev/null 2>&1
[ "$(cat "$RH/ensure.calls")" = 1 ] || _fail "reinstall: --fresh must force"
_ok "reinstall: --fresh still forces"

: > "$RH/ensure.calls"
CBOX_INSTALL_FORCE= run_reinstall "$RH" --force >/dev/null 2>&1
[ "$(cat "$RH/ensure.calls")" = 1 ] || _fail "reinstall: --force must force without the env var"
_ok "reinstall: --force flag forces"

: > "$RH/ensure.calls"
CBOX_INSTALL_FORCE=1 run_reinstall "$RH" --force >/dev/null 2>&1
[ "$(cat "$RH/ensure.calls")" = 1 ] || _fail "reinstall: --force with the env var must force exactly once"
_ok "reinstall: --force and env force compose"

run_reinstall_isolated() {
  local h="$1"; shift
  INSTALL_DIR="$RIB_INST" HOME="$h" bash -c '
    set -u
    h="$1"; shift
    '"$RIB_FN"'
    _cbox_effective_mode() { printf isolated; }
    _cbox_workspace_root() { printf "%s/ws" "$h"; }
    _cbox_path_hash() { printf "abc123"; }
    _cbox_image_tag() { printf img; }
    _cbox_image_hash() { printf hash; }
    docker() { :; }
    _bins_want() { printf latest; }
    _bins_conflict_report() { :; }
    _bins_hermes_on() { return 1; }
    _cbox_bins_volume() { printf "vol-%s" "$1"; }
    _cbox_probe_exes_seed() { :; }
    die() { echo "DIE: $*" >&2; exit 1; }
    _ensure_bins() { printf "%s\n" "${2:-}" >> "$h/ensure.calls"; }
    reinstall_bins "$@"
  ' rib "$h" "$@"
}

RHI="$TMPBASE/rib-iso"
mkdir -p "$RHI/ws" "$RHI/.config/cbox/projects/abc123"
printf 'CBOX_CLAUDE_TARGET=stable\n' > "$RHI/.config/cbox/projects/abc123/cbox.conf"
CBOX_INSTALL_FORCE=1 run_reinstall_isolated "$RHI" >/dev/null 2>&1
[ "$(cat "$RHI/ensure.calls")" = 1 ] || _fail "reinstall: isolated subshell must inherit the env force past conf sourcing"
_ok "reinstall: isolated mode inherits the env force"

: > "$RHI/ensure.calls"
CBOX_INSTALL_FORCE=1 run_reinstall_isolated "$RHI" --if-stale >/dev/null 2>&1
[ "$(cat "$RHI/ensure.calls")" = 0 ] || _fail "reinstall: isolated --if-stale must win over the env force"
_ok "reinstall: isolated --if-stale overrides the env force"

: > "$RHI/ensure.calls"
CBOX_INSTALL_FORCE= run_reinstall_isolated "$RHI" --force >/dev/null 2>&1
[ "$(cat "$RHI/ensure.calls")" = 1 ] || _fail "reinstall: isolated --force must survive conf sourcing"
_ok "reinstall: isolated --force forces past conf sourcing"

run_conflict_report() {
  bash -c '
    set -u
    '"$BCR_FN"'
    _bins_want() { printf latest; }
    _bins_hermes_on() { return 1; }
    _bins_conflict_scan() { printf "projA projB"; }
    _bins_conflict_report
  '
}

OUT="$(CBOX_BINS_SCOPE=pinned run_conflict_report 2>&1)"
[ -z "$OUT" ] || _fail "conflict report: pinned scope must stay silent (private volume moves nothing shared)"
_ok "conflict report: pinned scope skips the shared-tuple warning"

OUT="$(CBOX_BINS_SCOPE=global run_conflict_report 2>&1)"
printf '%s' "$OUT" | grep -q "moving the shared claude tuple will make these projects mismatch:projA projB" || _fail "conflict report: global scope must warn about mismatching projects"
printf '%s' "$OUT" | grep -q "moving the shared codex tuple" || _fail "conflict report: global scope must scan codex too"
_ok "conflict report: global scope warns about shared-tuple movers"

echo "PASS: ops lifecycle"
