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
INST_FN="$(_extract_fn "$INSTALL_DIR/install-bins.sh" _install_one)"
CUP_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_compose_up)"
CDIG_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_compose_files_digest)"
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
  _cbox_bins_volume() { printf "vol-%s" "$1"; }
  _bins_lock_file() { printf "%s/bins.lock" "$HOME"; }
  _bins_run_install() { printf "%s\n" "$2|$3" >> "$HOME/install.calls"; }
  _bins_autoupdate img
' aup "$H3" >/dev/null
[ -f "$H3/install.calls" ] && _fail "autoupdate: pinned versions must never refresh"
_ok "autoupdate: pinned versions never refresh"

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
