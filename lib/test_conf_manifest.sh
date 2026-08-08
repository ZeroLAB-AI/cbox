#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() { echo "FAIL: $1" >&2; exit 1; }
_ok() { echo "ok: $1"; }

set +eu
. "$INSTALL_DIR/_common.sh" >/dev/null 2>&1
. "$INSTALL_DIR/templates/generators.sh" >/dev/null 2>&1
set -eu

C="$TMPBASE/cbox.conf"
MF="$TMPBASE/.cbox-conf-manifest"

printf 'CBOX_MODE=global\nCBOX_TPL_SHA=abc\n' > "$C"

[ "$(_cbox_conf_manifest_status "$C")" = unstamped ] || _fail "a conf with no manifest must read 'unstamped', not $(_cbox_conf_manifest_status "$C")"
_ok "status: unstamped when no manifest exists (fail-safe for pre-existing global installs)"

_cbox_conf_write_manifest "$C"
[ -f "$MF" ] || _fail "manifest not written"
grep -q '^conf=' "$MF" || _fail "manifest has no conf line"
[ "$(_cbox_conf_manifest_status "$C")" = ok ] || _fail "freshly stamped conf must read 'ok'"
_ok "write + status: a stamped, unmodified conf reads 'ok'"

printf 'CBOX_EXTRA=tampered\n' >> "$C"
[ "$(_cbox_conf_manifest_status "$C")" = drifted ] || _fail "an edited conf must read 'drifted', got $(_cbox_conf_manifest_status "$C")"
_ok "status: a conf edited out of band reads 'drifted'"

_cbox_conf_write_manifest "$C"
[ "$(_cbox_conf_manifest_status "$C")" = ok ] || _fail "re-stamping a drifted conf must clear it to 'ok'"
_ok "re-stamp: writing the manifest after a change clears drift"

rm -f "$C"
[ "$(_cbox_conf_manifest_status "$C")" = missing ] || _fail "absent conf must read 'missing'"
_ok "status: absent conf reads 'missing'"

printf 'CBOX_MODE=global\n' > "$C"
printf 'garbage-no-conf-line\n' > "$MF"
[ "$(_cbox_conf_manifest_status "$C")" = malformed ] || _fail "manifest without a conf= line must read 'malformed', got $(_cbox_conf_manifest_status "$C")"
_ok "status: a malformed manifest reads 'malformed', never a false 'ok'"

echo "PASS: all conf manifest checks"
