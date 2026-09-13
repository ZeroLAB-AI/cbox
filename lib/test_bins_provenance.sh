#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

unset CBOX_CLAUDE_TARGET CBOX_CODEX_VERSION CBOX_CODEX_TARGET CBOX_HERMES CBOX_HERMES_VERSION \
  CBOX_INSTALL_FORCE CBOX_AUTOUPDATE CBOX_AUTOUPDATE_TTL_HOURS CBOX_BINS_SCOPE CBOX_BINS_HEALTH_GATE

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

BRIG_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_run_install_group)"
CACHEFILE_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_cache_file)"
CACHEGET_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_cache_get)"
FIELDSANITIZE_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_field_sanitize)"
CACHEPUT_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_cache_put)"
CACHEFIELD_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_cache_field)"
HISTFILE_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_history_file)"
HISTAPP_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_history_append)"
HISTPREV_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_history_prev_version)"
HOLDSANITIZE_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_hold_reason_sanitize)"
HOLDFILE_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_hold_file)"
HOLDWRITE_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_hold_write)"
HOLDREAD_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_hold_read)"
HOLDFIELD_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_hold_field)"
HOLDEXISTS_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_hold_exists)"
HEALTHFILE_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_health_file)"
HEALTHPUT_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_health_put)"
PROBESHA_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_probe_sha)"
WANT_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_want)"
STALE_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_stale)"
HERMESON_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_hermes_on)"
CHAN_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_channel)"
EOFF_FN="$(_extract_fn "$INSTALL_DIR/cbox" _engine_autoupdate_off)"
DOCUTC_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_doctor_utc)"
DOCLAST_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_doctor_last_refresh)"
DOCNEXT_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_doctor_next_check)"
STATUSPRINT_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_status_print)"
HISTCMD_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_history_cmd)"
BINSCMD_FN="$(_extract_fn "$INSTALL_DIR/cbox" bins_cmd)"
LOCKFILE_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_lock_file)"
DOCROW_BLOCK="$(python3 - "$INSTALL_DIR/cbox" <<'PYEOF'
import sys
text = open(sys.argv[1]).read()
marker = 'HOST-CHECK "claude/codex/hermes version pins and installs are host-side'
i = text.index(marker)
line_start = text.rfind('\n', 0, i) + 1
line_start = text.rfind('\n', 0, line_start - 1) + 1
j = text.index('\n  fi\n', i)
print(text[line_start:j + len('\n  fi')])
PYEOF
)"

for _fn in BRIG_FN CACHEFILE_FN CACHEGET_FN CACHEPUT_FN CACHEFIELD_FN HISTFILE_FN HISTAPP_FN \
  HISTPREV_FN HOLDSANITIZE_FN HOLDFILE_FN HOLDWRITE_FN HOLDREAD_FN HOLDFIELD_FN HOLDEXISTS_FN \
  HEALTHFILE_FN HEALTHPUT_FN PROBESHA_FN \
  WANT_FN STALE_FN HERMESON_FN CHAN_FN EOFF_FN DOCUTC_FN DOCLAST_FN DOCNEXT_FN \
  STATUSPRINT_FN HISTCMD_FN BINSCMD_FN LOCKFILE_FN; do
  [ -n "${!_fn}" ] || _fail "cannot extract function for $_fn"
done
[ -n "$DOCROW_BLOCK" ] || _fail "cannot extract doctor binaries-row block"

run_install_group() {
  local home="$1" tools="$2" status_lines="$3"
  INSTALL_DIR="$INSTALL_DIR" bash -c '
    set -u
    HOME="$1"; export HOME
    tools="$2"
    status_lines="$3"
    source "$INSTALL_DIR/lib/portable.sh"
    _CBOX_HEALTH_SH=""
    '"$BRIG_FN"'
    '"$CACHEFILE_FN"'
    '"$CACHEGET_FN"'
    '"$FIELDSANITIZE_FN"'
  '"$CACHEPUT_FN"'
    '"$CACHEFIELD_FN"'
    '"$HISTFILE_FN"'
    '"$HISTAPP_FN"'
    '"$HISTPREV_FN"'
    '"$HOLDSANITIZE_FN"'
    '"$HOLDFILE_FN"'
    '"$HOLDWRITE_FN"'
    '"$HOLDREAD_FN"'
    '"$HOLDFIELD_FN"'
    '"$HEALTHFILE_FN"'
    '"$FIELDSANITIZE_FN"'
  '"$HEALTHPUT_FN"'
    '"$PROBESHA_FN"'
    '"$WANT_FN"'
    _cbox_bins_volume() { printf "vol-%s" "$1"; }
    _cbox_probe_codex_argv() { printf "mcp-server"; }
    id() { printf "u"; }
    docker() {
      case "$1" in
        run) printf "%s" "$status_lines" ;;
        *) return 0 ;;
      esac
    }
    _bins_run_install_group img "$tools" 0
  ' brig "$home" "$tools" "$status_lines"
}

H1="$TMPBASE/h1"
mkdir -p "$H1/.config/cbox"
run_install_group "$H1" "claude codex" "cbox-bins: claude 1.0.0 abcd ok" >/dev/null
grep -Eq '^[0-9]+\|vol-claude\|claude\|stable\|\|1\.0\.0\|ok\|$' "$H1/.config/cbox/bins.history" \
  || _fail "history: a fresh ok install must record an empty from_version and the new version"
_ok "history: fresh ok install recorded with empty from_version"

H2="$TMPBASE/h2"
mkdir -p "$H2/.config/cbox"
printf 'vol-claude|claude|stable|1.0.0|1000\n' > "$H2/.config/cbox/bins.stamp"
run_install_group "$H2" "claude codex" "cbox-bins: claude 2.0.0 efgh ok" >/dev/null
grep -Eq '^[0-9]+\|vol-claude\|claude\|stable\|1\.0\.0\|2\.0\.0\|ok\|$' "$H2/.config/cbox/bins.history" \
  || _fail "history: a real version change must record the correct from_version and to_version"
_ok "history: version change recorded with correct from_version and to_version"

H3="$TMPBASE/h3"
mkdir -p "$H3/.config/cbox"
run_install_group "$H3" "claude codex" "cbox-bins: codex 3.0.0 hijk adopt" >/dev/null
grep -Eq '^[0-9]+\|vol-codex\|codex\|latest\|\|3\.0\.0\|adopt\|$' "$H3/.config/cbox/bins.history" \
  || _fail "history: an adopt status must be recorded like a fresh ok install"
_ok "history: adopt status recorded in history"

H4="$TMPBASE/h4"
mkdir -p "$H4/.config/cbox"
printf 'vol-claude|claude|stable|1.0.0|1000\n' > "$H4/.config/cbox/bins.stamp"
run_install_group "$H4" claude "cbox-bins: claude 1.0.0 abcd ok" >/dev/null
[ -f "$H4/.config/cbox/bins.history" ] && _fail "history: an unchanged version must not append a redundant history line"
_ok "history: unchanged version installs stay silent (no redundant history line)"

H5="$TMPBASE/h5"
mkdir -p "$H5/.config/cbox"
printf 'vol-codex|codex|latest|0.154.0|1000\n' > "$H5/.config/cbox/bins.stamp"
run_install_group "$H5" "claude codex" 'cbox-bins: codex 0.153.4 abcd1234 rollback 0.154.0 mcp-server handshake: no developer-instructions' >"$H5.out" 2>"$H5.err"
grep -Eq '^[0-9]+\|vol-codex\|codex\|latest\|0\.154\.0\|0\.153\.4\|rollback\|mcp-server handshake: no developer-instructions$' "$H5/.config/cbox/bins.history" \
  || _fail "parser: a rollback status_word must append a history line with from=badver, to=restored, status=rollback, note=reason: $(cat "$H5/.config/cbox/bins.history" 2>/dev/null)"
grep -q 'vol-codex|codex|latest|0.153.4|' "$H5/.config/cbox/bins.stamp" \
  || _fail "parser: a rollback status_word must cache_put the restored version"
[ -f "$H5/.config/cbox/bins.hold.vol-codex" ] || _fail "parser: a rollback status_word must write a hold file"
grep -q '^version=0.153.4$' "$H5/.config/cbox/bins.hold.vol-codex" || _fail "parser: hold file must record the good (restored) version"
grep -q '^bad=0.154.0$' "$H5/.config/cbox/bins.hold.vol-codex" || _fail "parser: hold file must record the bad version"
grep -q '^reason=mcp-server handshake: no developer-instructions$' "$H5/.config/cbox/bins.hold.vol-codex" || _fail "parser: hold file must record the reason"
grep -q 'rolled back to 0.153.4 and held there' "$H5.err" || _fail "parser: a rollback status_word must print an operator-facing hold notice"
_ok "parser: a rollback status_word writes history + cache + hold + stderr notice"

H6="$TMPBASE/h6"
mkdir -p "$H6/.config/cbox"
printf 'vol-codex|codex|latest|0.153.4|1000\n' > "$H6/.config/cbox/bins.stamp"
run_install_group "$H6" "claude codex" 'cbox-bins: codex 0.154.0 ffffeeee unreliable probe unreliable on both candidates, kept the new install' >"$H6.out" 2>"$H6.err"
grep -Eq '^[0-9]+\|vol-codex\|codex\|latest\|0\.153\.4\|0\.154\.0\|unreliable\|' "$H6/.config/cbox/bins.history" \
  || _fail "parser: an unreliable status_word must append a history line recording the kept version: $(cat "$H6/.config/cbox/bins.history" 2>/dev/null)"
grep -q 'vol-codex|codex|latest|0.154.0|' "$H6/.config/cbox/bins.stamp" \
  || _fail "parser: an unreliable status_word must cache_put the kept (new) version"
[ -f "$H6/.config/cbox/bins.hold.vol-codex" ] && _fail "parser: an unreliable status_word must never write a hold file"
grep -q 'health probe was unreliable' "$H6.err" || _fail "parser: an unreliable status_word must print an operator-facing notice"
_ok "parser: an unreliable status_word writes history + cache, never a hold"

H7="$TMPBASE/h7"
mkdir -p "$H7/.config/cbox"
run_install_group "$H7" "claude codex" 'cbox-bins: codex 0.154.0 - unhealthy no-history' >"$H7.out" 2>"$H7.err"
[ -f "$H7/.config/cbox/bins.hold.vol-codex" ] && _fail "parser: an unhealthy status_word must never write a hold file"
grep -q 'failed its health check and could not be rolled back' "$H7.err" || _fail "parser: an unhealthy status_word must print an operator-facing notice"
_ok "parser: an unhealthy status_word never writes a hold and prints an operator-facing notice"

echo "--- pipe-delimited field sanitization ---"

PIPEHOME="$TMPBASE/pipe-fields"
mkdir -p "$PIPEHOME/.config/cbox"
HOME="$PIPEHOME" bash -c '
  '"$FIELDSANITIZE_FN"'
  '"$CACHEFILE_FN"'
  '"$CACHEPUT_FN"'
  '"$HISTFILE_FN"'
  '"$HISTAPP_FN"'
  _bins_cache_put vol-codex codex latest "1.0|forged|9.9.9"
  _bins_history_append vol-codex codex latest "0.1" "2.0|forged" ok "note|forged"
'
CACHELINE="$(cat "$PIPEHOME/.config/cbox/bins.stamp")"
FIELDS="$(printf '%s' "$CACHELINE" | awk -F'|' '{print NF}')"
[ "$FIELDS" -eq 5 ] || _fail "cache: a version carrying a pipe must never add fields to bins.stamp, got $FIELDS: $CACHELINE"
HISTLINE="$(cat "$PIPEHOME/.config/cbox/bins.history")"
HFIELDS="$(printf '%s' "$HISTLINE" | awk -F'|' '{print NF}')"
[ "$HFIELDS" -eq 8 ] || _fail "history: pipes in version or note must never add fields, got $HFIELDS: $HISTLINE"
_ok "pipe-delimited state files keep their field count when a version or note carries a pipe"

echo "--- hold sanitization ---"

HOLDTEST_HOME="$TMPBASE/hold-sanitize"
mkdir -p "$HOLDTEST_HOME/.config/cbox"
MALICIOUS_REASON="$(printf 'evil\x01\x1b[31mreason\nversion=FORGED\nbad=FORGED\nreason=FORGED\nsince=0\n')"
HOME="$HOLDTEST_HOME" bash -c '
  '"$HOLDSANITIZE_FN"'
  '"$HOLDFILE_FN"'
  '"$HOLDWRITE_FN"'
  _bins_hold_write vol-codex 0.153.4 0.154.0 "$1"
' _ "$MALICIOUS_REASON"
LINES="$(wc -l < "$HOLDTEST_HOME/.config/cbox/bins.hold.vol-codex")"
[ "$LINES" -eq 4 ] || _fail "hold sanitize: a malicious reason must never expand the hold file beyond 4 lines, got $LINES lines"
grep -q '^version=0.153.4$' "$HOLDTEST_HOME/.config/cbox/bins.hold.vol-codex" \
  || _fail "hold sanitize: the version line must survive untouched by an attempted forged reason"
grep -q '^bad=0.154.0$' "$HOLDTEST_HOME/.config/cbox/bins.hold.vol-codex" \
  || _fail "hold sanitize: the bad line must survive untouched by an attempted forged reason"
VERSION_LINE_COUNT="$(grep -c '^version=' "$HOLDTEST_HOME/.config/cbox/bins.hold.vol-codex")"
[ "$VERSION_LINE_COUNT" -eq 1 ] || _fail "hold sanitize: a forged newline must never inject a second version= line, got $VERSION_LINE_COUNT"
BAD_LINE_COUNT="$(grep -c '^bad=' "$HOLDTEST_HOME/.config/cbox/bins.hold.vol-codex")"
[ "$BAD_LINE_COUNT" -eq 1 ] || _fail "hold sanitize: a forged newline must never inject a second bad= line, got $BAD_LINE_COUNT"
REASON_LINE="$(grep '^reason=' "$HOLDTEST_HOME/.config/cbox/bins.hold.vol-codex")"
case "$REASON_LINE" in *$'\x01'*|*$'\x1b'*) _fail "hold sanitize: control/escape bytes must be stripped from the reason" ;; esac
_ok "hold sanitize: control characters and a forged newline in the reason are stripped, the hold file stays exactly 4 lines"

HOLDTEST2_HOME="$TMPBASE/hold-sanitize-versions"
mkdir -p "$HOLDTEST2_HOME/.config/cbox"
MALICIOUS_GOOD="$(printf '0.153.4\x1b[31m\x01')"
MALICIOUS_BAD="$(printf '0.154.0\rbad=FORGED')"
HOME="$HOLDTEST2_HOME" bash -c '
  '"$HOLDSANITIZE_FN"'
  '"$HOLDFILE_FN"'
  '"$HOLDWRITE_FN"'
  _bins_hold_write vol-codex "$1" "$2" "a plain reason"
' _ "$MALICIOUS_GOOD" "$MALICIOUS_BAD"
HOLDF2="$HOLDTEST2_HOME/.config/cbox/bins.hold.vol-codex"
LINES2="$(wc -l < "$HOLDF2")"
[ "$LINES2" -eq 4 ] || _fail "hold sanitize: hostile version fields must never change the 4-line shape, got $LINES2 lines"
if LC_ALL=C grep -q '[^ -~]' "$HOLDF2"; then
  _fail "hold sanitize: control or escape bytes from the version fields must never reach the hold file"
fi
_ok "hold sanitize: control and escape bytes in the good/bad version fields are stripped like the reason is"

echo "--- autoupdate skips a held tool ---"
AUTOUPD_FN="$(_extract_fn "$INSTALL_DIR/cbox" _bins_autoupdate)"
[ -n "$AUTOUPD_FN" ] || _fail "cannot extract _bins_autoupdate"
AUTOHOME="$TMPBASE/autoupdate-hold"
mkdir -p "$AUTOHOME/.config/cbox"
HOME="$AUTOHOME" bash -c '
  '"$HOLDFILE_FN"'
  '"$HOLDWRITE_FN"'
  '"$HOLDSANITIZE_FN"'
  _bins_hold_write vol-codex 0.153.4 0.154.0 "held for the test"
'
RAN_FILE="$AUTOHOME/ran-tools"
HOME="$AUTOHOME" INSTALL_DIR="$INSTALL_DIR" bash -c '
  set -u
  HOME="$1"; export HOME
  source "$INSTALL_DIR/lib/portable.sh"
  '"$AUTOUPD_FN"'
  '"$HOLDFILE_FN"'
  '"$HOLDEXISTS_FN"'
  '"$CACHEFILE_FN"'
  '"$CACHEGET_FN"'
  '"$CACHEFIELD_FN"'
  _cbox_bins_volume() { printf "vol-%s" "$1"; }
  _bins_channel() { [ "$1" = codex ] || [ "$1" = claude ]; }
  _engine_autoupdate_off() { return 1; }
  _cbox_flock() { return 0; }
  _bins_run_install() { printf "%s" "$2" >> "'"$RAN_FILE"'"; return 0; }
  _bins_autoupdate img
' _ "$AUTOHOME"
[ -f "$RAN_FILE" ] || : > "$RAN_FILE"
case "$(cat "$RAN_FILE")" in
  *codex*) _fail "autoupdate: a held tool must never be selected as due for autoupdate" ;;
esac
grep -q claude "$RAN_FILE" || _fail "autoupdate: an unheld tool (claude) must still be selected as due"
_ok "autoupdate: a held tool is skipped, an unheld tool still runs"

DUTC_OUT="$(bash -c '
  '"$DOCUTC_FN"'
  _bins_doctor_utc 0
')"
[ "$DUTC_OUT" = "1970-01-01T00:00:00Z" ] \
  || _fail "doctor: _bins_doctor_utc must format epoch 0 as the UTC epoch string (got $DUTC_OUT)"
_ok "doctor: _bins_doctor_utc formats an epoch as UTC ISO-8601"

H5="$TMPBASE/h5"
mkdir -p "$H5/.config/cbox"
printf 'vol-claude|claude|stable|1.0.0|100\nvol-codex|codex|latest|2.0.0|200\n' > "$H5/.config/cbox/bins.stamp"
LR_OUT="$(INSTALL_DIR="$INSTALL_DIR" HOME="$H5" bash -c '
  set -u
  '"$CACHEFILE_FN"'
  '"$CACHEGET_FN"'
  '"$CACHEFIELD_FN"'
  '"$HERMESON_FN"'
  '"$DOCUTC_FN"'
  '"$DOCLAST_FN"'
  _cbox_bins_volume() { printf "vol-%s" "$1"; }
  _bins_doctor_last_refresh
')"
[ "$LR_OUT" = "1970-01-01T00:03:20Z" ] \
  || _fail "doctor: last-refresh must report the max cache epoch across tools (got $LR_OUT)"
_ok "doctor: last-refresh reports the most recent cache epoch"

H5B="$TMPBASE/h5b"
mkdir -p "$H5B/.config/cbox"
LR_NONE="$(INSTALL_DIR="$INSTALL_DIR" HOME="$H5B" bash -c '
  set -u
  '"$CACHEFILE_FN"'
  '"$CACHEGET_FN"'
  '"$CACHEFIELD_FN"'
  '"$HERMESON_FN"'
  '"$DOCUTC_FN"'
  '"$DOCLAST_FN"'
  _cbox_bins_volume() { printf "vol-%s" "$1"; }
  _bins_doctor_last_refresh
')"
[ "$LR_NONE" = never ] \
  || _fail "doctor: last-refresh with an empty cache must report never (got $LR_NONE)"
_ok "doctor: last-refresh reports never when no cache entries exist"

NC_OFF="$(CBOX_AUTOUPDATE=off bash -c '
  '"$CHAN_FN"'
  '"$EOFF_FN"'
  '"$HERMESON_FN"'
  '"$DOCUTC_FN"'
  '"$DOCNEXT_FN"'
  _cbox_bins_volume() { printf "vol-%s" "$1"; }
  _bins_doctor_next_check
')"
[ "$NC_OFF" = "autoupdate off" ] \
  || _fail "doctor: next-check must report autoupdate off when CBOX_AUTOUPDATE=off (got $NC_OFF)"
_ok "doctor: next-check reports autoupdate off"

H6="$TMPBASE/h6"
mkdir -p "$H6/.config/cbox"
printf '1000\n' > "$H6/.config/cbox/autoupdate.vol-claude.stamp"
printf '5000\n' > "$H6/.config/cbox/autoupdate.vol-codex.stamp"
NC_OUT="$(CBOX_AUTOUPDATE_TTL_HOURS=1 HOME="$H6" bash -c '
  '"$CHAN_FN"'
  '"$EOFF_FN"'
  '"$HERMESON_FN"'
  '"$DOCUTC_FN"'
  '"$DOCNEXT_FN"'
  _cbox_bins_volume() { printf "vol-%s" "$1"; }
  _bins_doctor_next_check
')"
[ "$NC_OUT" = "1970-01-01T01:16:40Z" ] \
  || _fail "doctor: next-check must report the soonest per-tool TTL deadline (got $NC_OUT)"
_ok "doctor: next-check reports the soonest per-tool autoupdate deadline"

run_status_print() {
  local home="$1"
  INSTALL_DIR="$INSTALL_DIR" bash -c '
    set -u
    HOME="$1"; export HOME
    '"$CACHEFILE_FN"'
    '"$CACHEGET_FN"'
    '"$CACHEFIELD_FN"'
    '"$WANT_FN"'
    '"$STALE_FN"'
    '"$HERMESON_FN"'
    '"$STATUSPRINT_FN"'
    _cbox_bins_volume() { printf "vol-%s" "$1"; }
    docker() { return 0; }
    _bins_status_print
  ' sp "$home"
}

SPA="$TMPBASE/sp_a"
mkdir -p "$SPA/.config/cbox"
printf 'vol-claude|claude|stable|1.2.3|1000\n' > "$SPA/.config/cbox/bins.stamp"
SP_OUT="$(run_status_print "$SPA")"
printf '%s\n' "$SP_OUT" | grep -Eq '^claude +volume=vol-claude want=stable installed=1\.2\.3 fresh$' \
  || _fail "bins status: an installed tool whose cache matches its want string must render fresh (got: $SP_OUT)"
printf '%s\n' "$SP_OUT" | grep -Eq '^codex +volume=vol-codex want=latest installed=unknown stale$' \
  || _fail "bins status: a tool with no cache entry must render unknown/stale (got: $SP_OUT)"
printf '%s\n' "$SP_OUT" | grep -Eq '^hermes +off$' \
  || _fail "bins status: hermes must render off when CBOX_HERMES is not on (got: $SP_OUT)"
_ok "bins status: per-tool volume/want/installed/staleness renders correctly"

run_history_cmd() {
  local home="$1" tool="${2:-}"
  INSTALL_DIR="$INSTALL_DIR" HOME="$home" bash -c '
    '"$HISTFILE_FN"'
    '"$HISTCMD_FN"'
    _bins_history_cmd "$1"
  ' hc "$tool"
}

HH="$TMPBASE/hist_cmd"
mkdir -p "$HH/.config/cbox"
cat > "$HH/.config/cbox/bins.history" << 'EOF'
100|vol-claude|claude|stable||1.0.0|ok|
200|vol-codex|codex|latest||2.0.0|ok|
300|vol-claude|claude|stable|1.0.0|1.1.0|ok|
EOF

ALL_OUT="$(run_history_cmd "$HH")"
[ "$(printf '%s\n' "$ALL_OUT" | wc -l)" = 3 ] \
  || _fail "bins history: an unfiltered dump must print every recorded line"
CLAUDE_OUT="$(run_history_cmd "$HH" claude)"
[ "$(printf '%s\n' "$CLAUDE_OUT" | wc -l)" = 2 ] \
  || _fail "bins history: filtering by tool must return only matching lines"
printf '%s\n' "$CLAUDE_OUT" | grep -q '^300|' \
  || _fail "bins history: the claude filter must include the version-change line"
CODEX_OUT="$(run_history_cmd "$HH" codex)"
[ "$(printf '%s\n' "$CODEX_OUT" | wc -l)" = 1 ] \
  || _fail "bins history: the codex filter must return exactly one line"
_ok "bins history: unfiltered dump and per-tool filtering both work"

HH2="$TMPBASE/hist_cmd_empty"
mkdir -p "$HH2/.config/cbox"
EMPTY_OUT="$(run_history_cmd "$HH2" 2>&1)"
[ -n "$EMPTY_OUT" ] || _fail "bins history: a missing history file must still emit a diagnostic message"
printf '%s\n' "$EMPTY_OUT" | grep -q "no bins history recorded" \
  || _fail "bins history: the missing-file message must explain there is no history yet"
_ok "bins history: a missing history file yields an explanatory message rather than an error"

run_bins_cmd() {
  local home="$1"; shift
  INSTALL_DIR="$INSTALL_DIR" HOME="$home" bash -c '
    source "$INSTALL_DIR/lib/portable.sh"
    '"$LOCKFILE_FN"'
    '"$BINSCMD_FN"'
    _cbox_config_in_container() { return 1; }
    _bins_status_cmd() { echo STATUS_CALLED; }
    _bins_history_cmd() { echo "HISTORY_CALLED:$*"; }
    _bins_check_cmd() { echo "CHECK_CALLED:$*"; }
    _bins_unhold_cmd() { echo "UNHOLD_CALLED:$*"; }
    bins_cmd "$@"
  ' bc "$@"
}

run_bins_cmd_in_container() {
  local home="$1"; shift
  INSTALL_DIR="$INSTALL_DIR" HOME="$home" bash -c '
    source "$INSTALL_DIR/lib/portable.sh"
    '"$LOCKFILE_FN"'
    '"$BINSCMD_FN"'
    _cbox_config_in_container() { return 0; }
    _bins_status_cmd() { echo STATUS_CALLED; }
    _bins_history_cmd() { echo "HISTORY_CALLED:$*"; }
    _bins_check_cmd() { echo "CHECK_CALLED:$*"; }
    _bins_unhold_cmd() { echo "UNHOLD_CALLED:$*"; }
    bins_cmd "$@"
  ' bc "$@"
}

BC="$TMPBASE/bc"
mkdir -p "$BC"
OUT="$(run_bins_cmd "$BC" status)"
[ "$OUT" = STATUS_CALLED ] || _fail "bins_cmd: the status subcommand must dispatch to _bins_status_cmd"
_ok "bins_cmd: status dispatch"

OUT="$(run_bins_cmd "$BC" history claude)"
[ "$OUT" = "HISTORY_CALLED:claude" ] \
  || _fail "bins_cmd: the history subcommand must pass its tool argument through"
_ok "bins_cmd: history dispatch passes the tool filter through"

run_bins_cmd "$BC" bogus >/dev/null 2>&1 && _fail "bins_cmd: an unknown subcommand must be refused"
_ok "bins_cmd: unknown subcommand refused"

run_bins_cmd_in_container "$BC" status >/dev/null 2>&1 \
  && _fail "bins_cmd: status must be refused inside a container"
IN_CONTAINER_MSG="$(run_bins_cmd_in_container "$BC" status 2>&1 >/dev/null || true)"
printf '%s\n' "$IN_CONTAINER_MSG" | grep -q 'host-only' \
  || _fail "bins_cmd: the in-container refusal must explain it is host-only (got: $IN_CONTAINER_MSG)"
_ok "bins_cmd: status/history refuse to run inside a container with a clear message"

OUT="$(run_bins_cmd "$BC" check codex)"
[ "$OUT" = "CHECK_CALLED:codex" ] || _fail "bins_cmd: the check subcommand must dispatch to _bins_check_cmd with its tool argument"
_ok "bins_cmd: check dispatch passes the tool filter through"

OUT="$(run_bins_cmd "$BC" unhold codex)"
[ "$OUT" = "UNHOLD_CALLED:codex" ] || _fail "bins_cmd: the unhold subcommand must dispatch to _bins_unhold_cmd with its tool argument"
_ok "bins_cmd: unhold dispatch passes the tool argument through"

run_bins_cmd_in_container "$BC" check >/dev/null 2>&1 \
  && _fail "bins_cmd: check must be refused inside a container"
run_bins_cmd_in_container "$BC" unhold codex >/dev/null 2>&1 \
  && _fail "bins_cmd: unhold must be refused inside a container"
_ok "bins_cmd: check/unhold refuse to run inside a container just like status/history/rollback"

run_doctor_binaries_row() {
  local claude_hit="$1" codex_hit="$2" hermes_on="$3" hermes_hit="$4"
  bash -c '
    in_container=0
    _cbox_bins_volume() { echo "vol-$1"; }
    _bins_cache_get() {
      case "$1" in
        vol-claude) [ "'"$claude_hit"'" = 1 ] && { echo "line|claude|hash|ok"; return 0; }; return 1 ;;
        vol-codex) [ "'"$codex_hit"'" = 1 ] && { echo "line|codex|hash|ok"; return 0; }; return 1 ;;
        vol-hermes) [ "'"$hermes_hit"'" = 1 ] && { echo "line|hermes|hash|ok"; return 0; }; return 1 ;;
      esac
      return 1
    }
    _bins_cache_field() { echo "$2-of-$1"; }
    _bins_hermes_on() { [ "'"$hermes_on"'" = 1 ]; }
    _bins_doctor_last_refresh() { echo "refresh"; }
    _bins_doctor_last_probe() { echo "probe"; }
    _bins_doctor_next_check() { echo "next"; }
    _bins_doctor_lock_suffix() { :; }
    _cbox_doctor_row() { printf "%s|%s|%s\n" "$1" "$2" "$3"; }
    doctor_binaries_row() {
      '"$DOCROW_BLOCK"'
    }
    doctor_binaries_row
  '
}

ROW="$(run_doctor_binaries_row 0 0 1 1)"
printf '%s\n' "$ROW" | grep -q '^binaries|ACTIVE|' \
  || _fail "doctor binaries row: hermes-only active with claude/codex missing must still report ACTIVE (got: $ROW)"
_ok "doctor binaries row: hermes-only active reports ACTIVE, not MISSING"

ROW="$(run_doctor_binaries_row 0 0 1 0)"
printf '%s\n' "$ROW" | grep -q '^binaries|MISSING|' \
  || _fail "doctor binaries row: nothing cached anywhere must report MISSING (got: $ROW)"
_ok "doctor binaries row: nothing active reports MISSING"

ROW="$(run_doctor_binaries_row 1 0 0 0)"
printf '%s\n' "$ROW" | grep -q '^binaries|ACTIVE|' \
  || _fail "doctor binaries row: claude-only active must report ACTIVE (got: $ROW)"
_ok "doctor binaries row: claude-only active reports ACTIVE"

run_doctor_binaries_row_locked() {
  bash -c '
    in_container=0
    _cbox_bins_volume() { echo "vol-$1"; }
    _bins_cache_get() {
      case "$1" in
        vol-codex) echo "line|codex|hash|ok"; return 0 ;;
      esac
      return 1
    }
    _bins_cache_field() { echo "0.153.4"; }
    _bins_hermes_on() { return 1; }
    _bins_doctor_last_refresh() { echo "refresh"; }
    _bins_doctor_last_probe() { echo "2026-09-13T00:00:00Z"; }
    _bins_doctor_next_check() { echo "next"; }
    _bins_doctor_lock_suffix() {
      case "$1" in
        codex) printf " [LOCKED 0.153.4 (bad 0.154.0: mcp-server handshake: no developer-instructions)]" ;;
      esac
    }
    _cbox_doctor_row() { printf "%s|%s|%s\n" "$1" "$2" "$3"; }
    doctor_binaries_row() {
      '"$DOCROW_BLOCK"'
    }
    doctor_binaries_row
  '
}

ROW="$(run_doctor_binaries_row_locked)"
printf '%s\n' "$ROW" | grep -qF 'codex=0.153.4 [LOCKED 0.153.4 (bad 0.154.0: mcp-server handshake: no developer-instructions)]' \
  || _fail "doctor binaries row: LOCKED marker must be inserted after the held tool's version (got: $ROW)"
printf '%s\n' "$ROW" | grep -qF 'last probe 2026-09-13T00:00:00Z' \
  || _fail "doctor binaries row: last-probe timestamp must be present (got: $ROW)"
_ok "doctor binaries row: a held tool carries the LOCKED marker and the row reports a last-probe timestamp"

echo "PASS: bins provenance"
