#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$INSTALL_DIR"
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

REAP_FN="$(_extract_fn "$INSTALL_DIR/cbox" _reap)"
AUP_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_autoupdate)"
CHAN_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_channel)"
EOFF_FN="$(_extract_fn "$INSTALL_DIR/cbox" _engine_autoupdate_off)"
HON_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_hermes_on)"
INST_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _install_one)"
WANT_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _want_string)"
SPATH_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _stamp_path)"
RHB_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _resolve_hermes_bin)"
HHASH_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _hermes_hash)"
RHI_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _run_hermes_install)"
CUP_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_compose_up)"
CDIG_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_compose_files_digest)"
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

run_reap() {
  local probe1="$1" probe2="$2" out
  out="$(bash -c '
    set -u
    eff="$1"; probe1="$2"; probe2="$3"
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
  bash -c '
    set -u
    HOME="$1"; export HOME
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
CBOX_CLAUDE_TARGET=1.2.3 CBOX_CODEX_VERSION=0.1.0 bash -c '
  set -u
  HOME="$1"; export HOME
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
  CBOX_HERMES="$2" CBOX_HERMES_VERSION="$3" bash -c '
    set -u
    HOME="$1"; export HOME
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
    _wipe_volume() { echo WIPED >> "$marker/actions"; }
    _adopt_check() { [ -f "$marker/adopts" ]; }
    _stamp_field() { sed -n "${2}p" "$1" 2>/dev/null; }
    _run_hermes_install() { echo INSTALLED >> "$marker/actions"; }
    _verify_tool() { printf "%s/opt-hermes/bin/hermes\nh\n0.19.0\n" "$marker"; }
    _stamp_write() { printf "%s\n" "$2" > "$marker/stamp.written"; }
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
[ "$(cat "$HM/stamp.written")" = latest ] || _fail "install-one hermes: stamp must record the want tuple"
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
  CBOX_DNS_MODE=public _cbox_dns_into "$DNSOUT"
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
[ "$(grep -cx '    dns:' "$DNSOUT")" = 2 ] || _fail "dns: docker mode must emit nothing"
grep -qx '      - CBOX_CLIP_SOCK=/run/cbox-clip/clip.sock' "$DNSOUT" || _fail "clip: env missing"
grep -qx '      - /run/user/7/cbox-clip-pXYZ:/run/cbox-clip' "$DNSOUT" || _fail "clip: sock dir mount missing"
[ "$(grep -c 'wl_paste_shim.py' "$DNSOUT")" = 1 ] || _fail "clip: off mode must emit nothing"
_ok "generators: dns and clipboard emission correct"

MANAGED="$TMPBASE/managed"
mkdir -p "$MANAGED/etc/claude" "$MANAGED/generated/managed-settings.json"
cp "$INSTALL_DIR/etc/claude/managed-settings.merge.json" "$MANAGED/etc/claude/managed-settings.merge.json"
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
FORCE_OUT="$FORCE_OUT" TMPBASE="$TMPBASE" bash -c '
  set -euo pipefail
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

echo "PASS: ops lifecycle"
