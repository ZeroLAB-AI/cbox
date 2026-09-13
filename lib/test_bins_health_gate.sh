#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

unset CBOX_CLAUDE_TARGET CBOX_CODEX_VERSION CBOX_CODEX_TARGET CBOX_HERMES CBOX_HERMES_VERSION \
  CBOX_INSTALL_FORCE CBOX_INSTALL_MODE CBOX_AUTOUPDATE CBOX_AUTOUPDATE_TTL_HOURS CBOX_BINS_SCOPE \
  CBOX_BINS_HEALTH_GATE CBOX_ROLLBACK_REASON CBOX_ROLLBACK_PREV_CLAUDE CBOX_ROLLBACK_PREV_CODEX \
  CBOX_ROLLBACK_PREV_HERMES CBOX_PROBE_CODEX_ARGV CBOX_HEALTH_PROBE_TIMEOUT CBOX_HEALTH_SH \
  _CBOX_HEALTH_SH

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

IB="$INSTALL_DIR/cbox"

HEALTHGATE_FN="$(_extract_fn "$IB" _bins_health_gate)"
HEALTHGATETOOL_FN="$(_extract_fn "$IB" _bins_health_gate_tool)"
HEALTHGATEPROBE_FN="$(_extract_fn "$IB" _bins_health_gate_probe)"
HEALTHGATEROLLBACK_FN="$(_extract_fn "$IB" _bins_health_gate_rollback)"
FIELDSANITIZE_FN="$(_extract_fn "$IB" _bins_field_sanitize)"
HEALTHFILE_FN="$(_extract_fn "$IB" _bins_health_file)"
PROBESHA_FN="$(_extract_fn "$IB" _bins_probe_sha)"
HEALTHPUT_FN="$(_extract_fn "$IB" _bins_health_put)"
HEALTHGET_FN="$(_extract_fn "$IB" _bins_health_get)"
HEALTHFIELD_FN="$(_extract_fn "$IB" _bins_health_field)"
CACHEFILE_FN="$(_extract_fn "$IB" _bins_cache_file)"
CACHEGET_FN="$(_extract_fn "$IB" _bins_cache_get)"
CACHEPUT_FN="$(_extract_fn "$IB" _bins_cache_put)"
CACHEFIELD_FN="$(_extract_fn "$IB" _bins_cache_field)"
WANT_FN="$(_extract_fn "$IB" _bins_want)"
HERMESON_FN="$(_extract_fn "$IB" _bins_hermes_on)"
LOCKFILE_FN="$(_extract_fn "$IB" _bins_lock_file)"
HISTFILE_FN="$(_extract_fn "$IB" _bins_history_file)"
HISTAPP_FN="$(_extract_fn "$IB" _bins_history_append)"
HISTPREV_FN="$(_extract_fn "$IB" _bins_history_prev_version)"
HOLDSANITIZE_FN="$(_extract_fn "$IB" _bins_hold_reason_sanitize)"
HOLDFILE_FN="$(_extract_fn "$IB" _bins_hold_file)"
HOLDWRITE_FN="$(_extract_fn "$IB" _bins_hold_write)"
HOLDREAD_FN="$(_extract_fn "$IB" _bins_hold_read)"
HOLDFIELD_FN="$(_extract_fn "$IB" _bins_hold_field)"
HOLDEXISTS_FN="$(_extract_fn "$IB" _bins_hold_exists)"
HOLDREMOVE_FN="$(_extract_fn "$IB" _bins_hold_remove)"
RBGROUP_FN="$(_extract_fn "$IB" _bins_run_rollback_group)"

for _fn in HEALTHGATE_FN HEALTHGATETOOL_FN HEALTHGATEPROBE_FN HEALTHGATEROLLBACK_FN HEALTHFILE_FN \
  PROBESHA_FN HEALTHPUT_FN HEALTHGET_FN HEALTHFIELD_FN CACHEFILE_FN CACHEGET_FN CACHEPUT_FN \
  CACHEFIELD_FN WANT_FN HERMESON_FN LOCKFILE_FN HISTFILE_FN HISTAPP_FN HISTPREV_FN HOLDSANITIZE_FN \
  HOLDFILE_FN HOLDWRITE_FN HOLDREAD_FN HOLDFIELD_FN HOLDEXISTS_FN HOLDREMOVE_FN RBGROUP_FN; do
  [ -n "${!_fn}" ] || _fail "cannot extract function for $_fn"
done

GATE_SCRIPT="$TMPBASE/gate_driver.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'source "%s/lib/portable.sh"\n' "$INSTALL_DIR"
  printf '%s\n' "$HEALTHGATE_FN"
  printf '%s\n' "$HEALTHGATETOOL_FN"
  printf '%s\n' "$HEALTHGATEPROBE_FN"
  printf '%s\n' "$HEALTHGATEROLLBACK_FN"
  printf '%s\n' "$FIELDSANITIZE_FN"
  printf '%s\n' "$HEALTHFILE_FN"
  printf '%s\n' "$PROBESHA_FN"
  printf '%s\n' "$HEALTHPUT_FN"
  printf '%s\n' "$HEALTHGET_FN"
  printf '%s\n' "$HEALTHFIELD_FN"
  printf '%s\n' "$CACHEFILE_FN"
  printf '%s\n' "$CACHEGET_FN"
  printf '%s\n' "$CACHEPUT_FN"
  printf '%s\n' "$CACHEFIELD_FN"
  printf '%s\n' "$WANT_FN"
  printf '%s\n' "$HERMESON_FN"
  printf '%s\n' "$LOCKFILE_FN"
  printf '%s\n' "$HISTFILE_FN"
  printf '%s\n' "$HISTAPP_FN"
  printf '%s\n' "$HISTPREV_FN"
  printf '%s\n' "$HOLDSANITIZE_FN"
  printf '%s\n' "$HOLDFILE_FN"
  printf '%s\n' "$HOLDWRITE_FN"
  printf '%s\n' "$HOLDREAD_FN"
  printf '%s\n' "$HOLDFIELD_FN"
  printf '%s\n' "$HOLDEXISTS_FN"
  printf '%s\n' "$HOLDREMOVE_FN"
  printf '%s\n' "$RBGROUP_FN"
  cat << 'STUB'
_cbox_bins_volume() { printf 'vol-%s' "$1"; }
_cbox_probe_codex_argv() { printf 'mcp-server'; }
id() { printf 'u'; }
docker() {
  printf '%s\n' "docker $*" >> "$CALLLOG"
  case "$1" in
    volume)
      case "$2" in
        inspect) [ "${VOL_OK:-1}" = 1 ] && return 0 || return 1 ;;
        *) return 0 ;;
      esac
      ;;
    run)
      local entry="" prev="" a
      for a in "$@"; do
        if [ "$prev" = "--entrypoint" ]; then entry="$a"; fi
        prev="$a"
      done
      case "$entry" in
        sh)
          printf '%s' "${PROBE_OUT:-}"
          return "${PROBE_RC:-0}"
          ;;
        /opt/cbox/install-bins.sh)
          printf '%s\n' "${ROLLBACK_LINES:-}"
          return "${ROLLBACK_RC:-0}"
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    *)
      return 0
      ;;
  esac
}
_bins_health_gate "$1"
STUB
} > "$GATE_SCRIPT"

run_gate() {
  local home="$1" img="$2"
  env HOME="$home" CALLLOG="$home/calllog.txt" \
    VOL_OK="${VOL_OK:-1}" PROBE_RC="${PROBE_RC:-0}" PROBE_OUT="${PROBE_OUT:-}" \
    ROLLBACK_LINES="${ROLLBACK_LINES:-}" ROLLBACK_RC="${ROLLBACK_RC:-0}" \
    CBOX_BINS_HEALTH_GATE="${CBOX_BINS_HEALTH_GATE:-}" _CBOX_HEALTH_SH="${_CBOX_HEALTH_SH:-}" \
    bash "$GATE_SCRIPT" "$img"
}

_run_probe_count() {
  grep -c -- '--entrypoint sh' "$1" 2>/dev/null || true
}

_run_rollback_count() {
  grep -c -- '--entrypoint /opt/cbox/install-bins.sh' "$1" 2>/dev/null || true
}

echo "--- cache round trip: two gate calls with a matching (version, probe_sha) run docker exactly once ---"
H1="$TMPBASE/h1"
mkdir -p "$H1/.config/cbox"
printf 'vol-claude|claude|stable|1.0.0|1000\n' > "$H1/.config/cbox/bins.stamp"
CBOX_BINS_HEALTH_GATE=on _CBOX_HEALTH_SH="" VOL_OK=1 PROBE_RC=0 run_gate "$H1" img >/dev/null
CBOX_BINS_HEALTH_GATE=on _CBOX_HEALTH_SH="" VOL_OK=1 PROBE_RC=0 run_gate "$H1" img >/dev/null
CALLS="$(_run_probe_count "$H1/calllog.txt")"
[ "$CALLS" = 1 ] || _fail "cache round trip: expected exactly 1 probe docker run across two gate calls, got $CALLS"
grep -q '^vol-claude|1\.0\.0|' "$H1/.config/cbox/bins.health" \
  || _fail "cache round trip: bins.health must record an ok verdict for vol-claude 1.0.0"
_ok "cache round trip: second gate call with the same (version, probe_sha) costs zero docker runs"

echo "--- a changed probe_sha invalidates the cached verdict and forces a re-probe ---"
H2="$TMPBASE/h2"
mkdir -p "$H2/.config/cbox"
printf 'vol-claude|claude|stable|1.0.0|1000\n' > "$H2/.config/cbox/bins.stamp"
CBOX_BINS_HEALTH_GATE=on _CBOX_HEALTH_SH="probe-v1" VOL_OK=1 PROBE_RC=0 run_gate "$H2" img >/dev/null
CBOX_BINS_HEALTH_GATE=on _CBOX_HEALTH_SH="probe-v2" VOL_OK=1 PROBE_RC=0 run_gate "$H2" img >/dev/null
CALLS2="$(_run_probe_count "$H2/calllog.txt")"
[ "$CALLS2" = 2 ] || _fail "probe_sha change: expected 2 probe docker runs (one per distinct probe_sha), got $CALLS2"
_ok "probe_sha change: a changed probe body invalidates the cached verdict and triggers a fresh probe"

echo "--- docker daemon down (volume inspect fails) yields skip, never a rollback ---"
H3="$TMPBASE/h3"
mkdir -p "$H3/.config/cbox"
printf 'vol-claude|claude|stable|1.0.0|1000\n' > "$H3/.config/cbox/bins.stamp"
CBOX_BINS_HEALTH_GATE=on _CBOX_HEALTH_SH="" VOL_OK=0 PROBE_RC=2 ROLLBACK_LINES="cbox-bins: claude 1.0.0 abcd1234 rollback 2.0.0 should-not-run" \
  run_gate "$H3" img >/dev/null
RBCALLS3="$(_run_rollback_count "$H3/calllog.txt")"
[ "$RBCALLS3" = 0 ] || _fail "docker-down: a failed volume inspect must never trigger a rollback, got $RBCALLS3 rollback invocation(s)"
[ -f "$H3/.config/cbox/bins.health" ] && _fail "docker-down: no health verdict should be cached when the probe could not run"
_ok "docker-down (volume inspect fails): probe-skip, no rollback, no cached verdict"

echo "--- rc 2 triggers rollback mode exactly once under the flock ---"
H4="$TMPBASE/h4"
mkdir -p "$H4/.config/cbox"
printf 'vol-claude|claude|stable|1.0.0|1000\n' > "$H4/.config/cbox/bins.stamp"
CBOX_BINS_HEALTH_GATE=on _CBOX_HEALTH_SH="" VOL_OK=1 PROBE_RC=2 \
  ROLLBACK_LINES="cbox-bins: claude 1.0.0 abcd1234 rollback 2.0.0 handshake-failed" \
  run_gate "$H4" img >/dev/null
RBCALLS4="$(_run_rollback_count "$H4/calllog.txt")"
[ "$RBCALLS4" = 1 ] || _fail "rc 2: expected exactly 1 rollback-mode docker run, got $RBCALLS4"
grep -q 'rollback' "$H4/.config/cbox/bins.history" \
  || _fail "rc 2: the rollback must be recorded in bins.history"
grep -q '^vol-claude|claude|stable|1\.0\.0|' "$H4/.config/cbox/bins.stamp" \
  || _fail "rc 2: bins.stamp (cache) must end at the restored version"
grep -q 'CBOX_ROLLBACK_REASON=health-gate' "$H4/calllog.txt" \
  || _fail "rc 2: an automatic start-gate rollback must be tagged health-gate, not manual"
_ok "rc 2 (definitive failure): triggers install-bins.sh rollback mode exactly once under the bins lock"
_ok "rc 2: the rollback is tagged health-gate so it is distinguishable from a manual rollback"

echo "--- rc 3 (inconclusive) prints a warning, caches nothing, and re-probes next time ---"
H6="$TMPBASE/h6"
mkdir -p "$H6/.config/cbox"
printf 'vol-claude|claude|stable|1.0.0|1000\n' > "$H6/.config/cbox/bins.stamp"
OUT6="$(CBOX_BINS_HEALTH_GATE=on _CBOX_HEALTH_SH="" VOL_OK=1 PROBE_RC=3 run_gate "$H6" img 2>&1)"
CALLS6="$(_run_probe_count "$H6/calllog.txt")"
[ "$CALLS6" = 1 ] || _fail "rc 3: expected exactly 1 probe docker run, got $CALLS6"
[ -f "$H6/.config/cbox/bins.health" ] && _fail "rc 3: an inconclusive probe must not cache a verdict"
printf '%s' "$OUT6" | grep -q 'inconclusive' \
  || _fail "rc 3: expected an inconclusive warning on stderr, got: $OUT6"
CBOX_BINS_HEALTH_GATE=on _CBOX_HEALTH_SH="" VOL_OK=1 PROBE_RC=3 run_gate "$H6" img >/dev/null 2>&1
CALLS6B="$(_run_probe_count "$H6/calllog.txt")"
[ "$CALLS6B" = 2 ] || _fail "rc 3: a second gate call must re-probe (nothing was cached), got $CALLS6B total probe runs"
_ok "rc 3 (inconclusive): warns, caches nothing, and re-probes on the next start"

echo "--- a rollback already applied by a concurrent session is not repeated ---"
RACE_SCRIPT="$TMPBASE/race_driver.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'source "%s/lib/portable.sh"\n' "$INSTALL_DIR"
  printf '%s\n' "$LOCKFILE_FN"
  printf '%s\n' "$CACHEFILE_FN"
  printf '%s\n' "$CACHEGET_FN"
  printf '%s\n' "$CACHEFIELD_FN"
  printf '%s\n' "$WANT_FN"
  printf '%s\n' "$HISTFILE_FN"
  printf '%s\n' "$HISTAPP_FN"
  printf '%s\n' "$HISTPREV_FN"
  printf '%s\n' "$RBGROUP_FN"
  printf '%s\n' "$HEALTHGATEROLLBACK_FN"
  cat << 'STUB'
_cbox_bins_volume() { printf 'vol-%s' "$1"; }
docker() {
  printf '%s\n' "docker $*" >> "$CALLLOG"
  case "$1" in
    volume) return 0 ;;
    run) printf '%s\n' "${ROLLBACK_LINES:-}"; return "${ROLLBACK_RC:-0}" ;;
    *) return 0 ;;
  esac
}
_bins_health_gate_rollback "$1" "$2" "$3"
STUB
} > "$RACE_SCRIPT"

H7="$TMPBASE/h7"
mkdir -p "$H7/.config/cbox"
printf 'vol-claude|claude|stable|2.0.0|1000\n' > "$H7/.config/cbox/bins.stamp"
: > "$H7/calllog.txt"
env HOME="$H7" CALLLOG="$H7/calllog.txt" \
  ROLLBACK_LINES="cbox-bins: claude 1.0.0 abcd1234 rollback 3.0.0 handshake-failed" ROLLBACK_RC=0 \
  bash "$RACE_SCRIPT" img claude 3.0.0 >/dev/null
RBCALLS7="$(_run_rollback_count "$H7/calllog.txt")"
[ "$RBCALLS7" = 0 ] || _fail "race: a version already changed by another session must skip the redundant rollback, got $RBCALLS7 rollback invocation(s)"
_ok "race: a gate call whose observed bad version no longer matches the current cache skips its rollback"

echo "--- CBOX_BINS_HEALTH_GATE=off (the default) performs zero docker runs ---"
H5="$TMPBASE/h5"
mkdir -p "$H5/.config/cbox"
printf 'vol-claude|claude|stable|1.0.0|1000\n' > "$H5/.config/cbox/bins.stamp"
CBOX_BINS_HEALTH_GATE="" _CBOX_HEALTH_SH="" VOL_OK=1 PROBE_RC=0 run_gate "$H5" img >/dev/null
[ -f "$H5/calllog.txt" ] && _fail "gate off: expected zero docker invocations, but calllog.txt exists: $(cat "$H5/calllog.txt")"
_ok "CBOX_BINS_HEALTH_GATE=off (default): the gate makes no docker calls at all"

echo "PASS: bins health gate"
