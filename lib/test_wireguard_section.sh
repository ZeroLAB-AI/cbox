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

source "$INSTALL_DIR/lib/portable.sh"
source "$INSTALL_DIR/templates/sections.sh"
source "$INSTALL_DIR/templates/conf_lib.sh"

WG_VARS="CBOX_WG_MODE CBOX_WG_IMPL CBOX_WG_ADDRESS CBOX_WG_LISTEN_PORT CBOX_WG_PUBLISH_ADDR CBOX_WG_PEER_ENDPOINT CBOX_WG_PEER_PUBKEY CBOX_WG_PEER_ADDRESS CBOX_WG_KEEPALIVE CBOX_WG_FORWARDS"

case " ${SECTIONS[*]} " in
  *" wireguard "*) ;;
  *) _fail "registry: 'wireguard' missing from SECTIONS" ;;
esac
_ok "registry: SECTIONS includes wireguard"

[ -n "$(sec_get SEC_TITLE wireguard)" ] || _fail "registry: SEC_TITLE[wireguard] missing"
[ -n "$(sec_get SEC_DESC wireguard)" ] || _fail "registry: SEC_DESC[wireguard] missing"
_ok "registry: SEC_TITLE/SEC_DESC set for wireguard"

[ -n "$(sec_get SEC_VARS wireguard)" ] || _fail "registry: SEC_VARS[wireguard] missing"
for v in $WG_VARS; do
  case " $(sec_get SEC_VARS wireguard) " in
    *" $v "*) ;;
    *) _fail "registry: SEC_VARS[wireguard] missing $v" ;;
  esac
done
_ok "registry: SEC_VARS[wireguard] lists every required var"

got_count="$(printf '%s\n' $(sec_get SEC_VARS wireguard) | wc -l)"
want_count="$(printf '%s\n' $WG_VARS | wc -l)"
[ "$got_count" -eq "$want_count" ] || _fail "registry: SEC_VARS[wireguard] has extra/unexpected entries (got $got_count want $want_count): $(sec_get SEC_VARS wireguard)"
_ok "registry: SEC_VARS[wireguard] has exactly the 10 required vars, no more"

[ "$(sec_get SEC_APPLY wireguard)" = infra-reconcile ] || _fail "registry: SEC_APPLY[wireguard] should be infra-reconcile, got $(sec_get SEC_APPLY wireguard)"
_ok "registry: SEC_APPLY[wireguard]=infra-reconcile (reuses the ollama owner-project apply class)"

[ -n "$(sec_get SEC_PROFILE wireguard)" ] || _fail "registry: SEC_PROFILE[wireguard] missing"
_ok "registry: SEC_PROFILE[wireguard] set"

sec_has SEC_DOCTOR_ROWS wireguard || _fail "registry: SEC_DOCTOR_ROWS[wireguard] not declared"
[ "$(sec_get SEC_DOCTOR_ROWS wireguard)" = wireguard ] || _fail "registry: SEC_DOCTOR_ROWS[wireguard] should declare exactly the 'wireguard' row, got: $(sec_get SEC_DOCTOR_ROWS wireguard)"
_ok "registry: SEC_DOCTOR_ROWS[wireguard] declares the wireguard doctor row"

[ -n "$(sec_get SEC_SCOPE wireguard)" ] || _fail "registry: SEC_SCOPE[wireguard] missing"
[ "$(sec_get SEC_SCOPE wireguard)" = machine ] || _fail "registry: SEC_SCOPE[wireguard] should be machine, got $(sec_get SEC_SCOPE wireguard)"
_ok "registry: SEC_SCOPE[wireguard]=machine"

other_bad=""
for s in "${SECTIONS[@]}"; do
  case "$s" in
    wireguard|ollama|local-model) continue ;;
  esac
  [ -n "$(sec_get SEC_SCOPE "$s")" ] || { other_bad="$other_bad missing:$s"; continue; }
  [ "$(sec_get SEC_SCOPE "$s")" = project ] || other_bad="$other_bad wrong:$s=$(sec_get SEC_SCOPE "$s")"
done
[ -z "$other_bad" ] || _fail "registry: SEC_SCOPE should default to project for every section except ollama/wireguard/local-model:$other_bad"
_ok "registry: SEC_SCOPE defaults to project for every non-machine-scoped section"

_load_cbox_config_block() {
  awk '/^_cbox_config_load_sections\(\) \{/{f=1} f{print} f && /^config_cmd\(\) \{/{exit}' "$INSTALL_DIR/cbox" > "$TMPBASE/cbox_config_block.sh"
  sed -i '$ d' "$TMPBASE/cbox_config_block.sh"
  awk '/^config_cmd\(\) \{/{f=1} f{print} f && /^}$/{exit}' "$INSTALL_DIR/cbox" >> "$TMPBASE/cbox_config_block.sh"
  awk '
    /^_cbox_local_effdir_for\(\) \{/ { infunc=1 }
    /^_cbox_machine_scoped_vars\(\) \{/ { infunc=1 }
    /^_cbox_load_machine_scoped_vars\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$INSTALL_DIR/cbox" > "$TMPBASE/cbox_helpers.sh"
  source "$TMPBASE/cbox_helpers.sh"
  source "$TMPBASE/cbox_config_block.sh"
}
_load_cbox_config_block
source "$INSTALL_DIR/templates/generators.sh"

declare -f _cbox_config_whitelist >/dev/null || _fail "extraction failed: _cbox_config_whitelist not defined"
declare -f _cbox_config_validate_var >/dev/null || _fail "extraction failed: _cbox_config_validate_var not defined"
declare -f _cbox_machine_scoped_vars >/dev/null || _fail "extraction failed: _cbox_machine_scoped_vars not defined (cbox copy)"

for v in $WG_VARS; do
  _cbox_config_is_whitelisted "$v" || _fail "whitelist: $v should be in the cbox config whitelist"
done
_ok "whitelist: every wireguard var is settable via cbox config set"

_cbox_config_validate_var CBOX_WG_MODE off || _fail "validator: CBOX_WG_MODE=off should be valid"
_cbox_config_validate_var CBOX_WG_MODE server || _fail "validator: CBOX_WG_MODE=server should be valid"
_cbox_config_validate_var CBOX_WG_MODE client || _fail "validator: CBOX_WG_MODE=client should be valid"
_cbox_config_validate_var CBOX_WG_MODE both || _fail "validator: CBOX_WG_MODE=both should be valid"
_cbox_config_validate_var CBOX_WG_MODE bogus >/dev/null 2>&1 && _fail "validator: CBOX_WG_MODE=bogus should be rejected"
_ok "validator: CBOX_WG_MODE"

_cbox_config_validate_var CBOX_WG_IMPL auto || _fail "validator: CBOX_WG_IMPL=auto should be valid"
_cbox_config_validate_var CBOX_WG_IMPL kernel || _fail "validator: CBOX_WG_IMPL=kernel should be valid"
_cbox_config_validate_var CBOX_WG_IMPL userspace || _fail "validator: CBOX_WG_IMPL=userspace should be valid"
_cbox_config_validate_var CBOX_WG_IMPL bogus >/dev/null 2>&1 && _fail "validator: CBOX_WG_IMPL=bogus should be rejected"
_ok "validator: CBOX_WG_IMPL"

_cbox_config_validate_var CBOX_WG_ADDRESS "" || _fail "validator: empty CBOX_WG_ADDRESS should be valid"
_cbox_config_validate_var CBOX_WG_ADDRESS "10.90.0.1/24" || _fail "validator: 10.90.0.1/24 should be valid"
_cbox_config_validate_var CBOX_WG_ADDRESS "10.90.0.1" >/dev/null 2>&1 && _fail "validator: address without prefix length should be rejected"
_cbox_config_validate_var CBOX_WG_ADDRESS "not-an-ip/24" >/dev/null 2>&1 && _fail "validator: garbage address should be rejected"
_cbox_config_validate_var CBOX_WG_ADDRESS "10.90.0.1/33" >/dev/null 2>&1 && _fail "validator: out-of-range prefix length should be rejected"
_ok "validator: CBOX_WG_ADDRESS"

_cbox_config_validate_var CBOX_WG_LISTEN_PORT 51820 || _fail "validator: port 51820 should be valid"
_cbox_config_validate_var CBOX_WG_LISTEN_PORT 0 >/dev/null 2>&1 && _fail "validator: port 0 should be rejected"
_cbox_config_validate_var CBOX_WG_LISTEN_PORT 99999 >/dev/null 2>&1 && _fail "validator: out-of-range port should be rejected"
_ok "validator: CBOX_WG_LISTEN_PORT"

_cbox_config_validate_var CBOX_WG_PUBLISH_ADDR "" || _fail "validator: empty CBOX_WG_PUBLISH_ADDR should be valid (all addresses)"
_cbox_config_validate_var CBOX_WG_PUBLISH_ADDR "203.0.113.5" || _fail "validator: literal IPv4 should be valid"
_cbox_config_validate_var CBOX_WG_PUBLISH_ADDR "not-an-ip" >/dev/null 2>&1 && _fail "validator: non-IPv4 should be rejected"
_cbox_config_validate_var CBOX_WG_PUBLISH_ADDR "203.0.113.5/24" >/dev/null 2>&1 && _fail "validator: CIDR (not a literal address) should be rejected"
_ok "validator: CBOX_WG_PUBLISH_ADDR"

_cbox_config_validate_var CBOX_WG_PEER_ENDPOINT "" || _fail "validator: empty CBOX_WG_PEER_ENDPOINT should be valid"
_cbox_config_validate_var CBOX_WG_PEER_ENDPOINT "example.com:51820" || _fail "validator: host:port should be valid"
_cbox_config_validate_var CBOX_WG_PEER_ENDPOINT "10.0.0.5:51820" || _fail "validator: ip:port should be valid"
_cbox_config_validate_var CBOX_WG_PEER_ENDPOINT "example.com" >/dev/null 2>&1 && _fail "validator: missing port should be rejected"
_cbox_config_validate_var CBOX_WG_PEER_ENDPOINT "example.com:notaport" >/dev/null 2>&1 && _fail "validator: non-numeric port should be rejected"
_ok "validator: CBOX_WG_PEER_ENDPOINT"

VALID_PUBKEY="aRcYqQIm9uH5B9V0IEQKddz3nO2FnHOEcYcQ0YQnMBs="
_cbox_config_validate_var CBOX_WG_PEER_PUBKEY "" || _fail "validator: empty CBOX_WG_PEER_PUBKEY should be valid"
_cbox_config_validate_var CBOX_WG_PEER_PUBKEY "$VALID_PUBKEY" || _fail "validator: canonical wireguard pubkey shape should be valid"
_cbox_config_validate_var CBOX_WG_PEER_PUBKEY "short" >/dev/null 2>&1 && _fail "validator: too-short key should be rejected"
_cbox_config_validate_var CBOX_WG_PEER_PUBKEY "${VALID_PUBKEY%=}X" >/dev/null 2>&1 && _fail "validator: key without trailing = should be rejected"
_cbox_config_validate_var CBOX_WG_PEER_PUBKEY "not a valid key at all here padding!!" >/dev/null 2>&1 && _fail "validator: non-base64 characters should be rejected"
_ok "validator: CBOX_WG_PEER_PUBKEY"

_cbox_config_validate_var CBOX_WG_PEER_ADDRESS "" || _fail "validator: empty CBOX_WG_PEER_ADDRESS should be valid"
_cbox_config_validate_var CBOX_WG_PEER_ADDRESS "10.90.0.2/32" || _fail "validator: 10.90.0.2/32 should be valid"
_cbox_config_validate_var CBOX_WG_PEER_ADDRESS "not-an-ip" >/dev/null 2>&1 && _fail "validator: garbage should be rejected"
_ok "validator: CBOX_WG_PEER_ADDRESS"

_cbox_config_validate_var CBOX_WG_KEEPALIVE 25 || _fail "validator: keepalive 25 should be valid"
_cbox_config_validate_var CBOX_WG_KEEPALIVE 0 || _fail "validator: keepalive 0 should be valid (disables)"
_cbox_config_validate_var CBOX_WG_KEEPALIVE -1 >/dev/null 2>&1 && _fail "validator: negative keepalive should be rejected"
_cbox_config_validate_var CBOX_WG_KEEPALIVE abc >/dev/null 2>&1 && _fail "validator: non-numeric keepalive should be rejected"
_ok "validator: CBOX_WG_KEEPALIVE"

_load_setup_functions() {
  awk '
    /^conf_defaults\(\) \{/ { infunc=1 }
    /^conf_load\(\) \{/ { infunc=1 }
    /^conf_save\(\) \{/ { infunc=1 }
    /^_cbox_machine_scoped_vars\(\) \{/ { infunc=1 }
    /^_cbox_strip_machine_scoped_vars\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$INSTALL_DIR/lib/cbox-setup.sh" > "$TMPBASE/setup_functions.sh"
  source "$TMPBASE/setup_functions.sh"
}
_load_setup_functions

declare -f conf_defaults >/dev/null || _fail "extraction failed: conf_defaults not defined (setup.sh)"
declare -f conf_save >/dev/null || _fail "extraction failed: conf_save not defined (setup.sh)"
declare -f _cbox_strip_machine_scoped_vars >/dev/null || _fail "extraction failed: _cbox_strip_machine_scoped_vars not defined (setup.sh)"

CBOX_NAME=cbox
CBOX_WORKSPACES=""
conf_defaults

[ "$CBOX_WG_MODE" = off ] || _fail "conf_defaults: CBOX_WG_MODE should default to off, got $CBOX_WG_MODE"
_ok "off-default: CBOX_WG_MODE=off is inert by construction (no interface/key/port/container/network/image-build var is set to anything but its off-safe default)"
[ "$CBOX_WG_IMPL" = auto ] || _fail "conf_defaults: CBOX_WG_IMPL should default to auto, got $CBOX_WG_IMPL"
[ -z "$CBOX_WG_ADDRESS" ] || _fail "conf_defaults: CBOX_WG_ADDRESS should default to empty, got $CBOX_WG_ADDRESS"
[ "$CBOX_WG_LISTEN_PORT" = 51820 ] || _fail "conf_defaults: CBOX_WG_LISTEN_PORT should default to 51820, got $CBOX_WG_LISTEN_PORT"
[ -z "$CBOX_WG_PUBLISH_ADDR" ] || _fail "conf_defaults: CBOX_WG_PUBLISH_ADDR should default to empty, got $CBOX_WG_PUBLISH_ADDR"
[ -z "$CBOX_WG_PEER_ENDPOINT" ] || _fail "conf_defaults: CBOX_WG_PEER_ENDPOINT should default to empty, got $CBOX_WG_PEER_ENDPOINT"
[ -z "$CBOX_WG_PEER_PUBKEY" ] || _fail "conf_defaults: CBOX_WG_PEER_PUBKEY should default to empty, got $CBOX_WG_PEER_PUBKEY"
[ -z "$CBOX_WG_PEER_ADDRESS" ] || _fail "conf_defaults: CBOX_WG_PEER_ADDRESS should default to empty, got $CBOX_WG_PEER_ADDRESS"
[ "$CBOX_WG_KEEPALIVE" = 25 ] || _fail "conf_defaults: CBOX_WG_KEEPALIVE should default to 25, got $CBOX_WG_KEEPALIVE"
_ok "conf_defaults: every new var has the documented default"

CONFFILE="$TMPBASE/roundtrip.conf"
CBOX_WG_MODE=both
CBOX_WG_IMPL=userspace
CBOX_WG_ADDRESS="10.90.0.1/24"
CBOX_WG_LISTEN_PORT=51821
CBOX_WG_PUBLISH_ADDR="203.0.113.9"
CBOX_WG_PEER_ENDPOINT="remote.example:51820"
CBOX_WG_PEER_PUBKEY="$VALID_PUBKEY"
CBOX_WG_PEER_ADDRESS="10.90.0.2/32"
CBOX_WG_KEEPALIVE=15
conf_save "$CONFFILE"

for v in $WG_VARS; do
  grep -q "^${v}=" "$CONFFILE" || _fail "conf_save: $v missing from saved conf"
done
_ok "conf_save: every new var has an explicit printf line"

(
  unset CBOX_WG_MODE CBOX_WG_IMPL CBOX_WG_ADDRESS CBOX_WG_LISTEN_PORT CBOX_WG_PUBLISH_ADDR CBOX_WG_PEER_ENDPOINT CBOX_WG_PEER_PUBKEY CBOX_WG_PEER_ADDRESS CBOX_WG_KEEPALIVE
  . "$CONFFILE"
  [ "$CBOX_WG_MODE" = both ] || exit 1
  [ "$CBOX_WG_IMPL" = userspace ] || exit 1
  [ "$CBOX_WG_ADDRESS" = "10.90.0.1/24" ] || exit 1
  [ "$CBOX_WG_LISTEN_PORT" = 51821 ] || exit 1
  [ "$CBOX_WG_PUBLISH_ADDR" = "203.0.113.9" ] || exit 1
  [ "$CBOX_WG_PEER_ENDPOINT" = "remote.example:51820" ] || exit 1
  [ "$CBOX_WG_PEER_PUBKEY" = "$VALID_PUBKEY" ] || exit 1
  [ "$CBOX_WG_PEER_ADDRESS" = "10.90.0.2/32" ] || exit 1
  [ "$CBOX_WG_KEEPALIVE" = 15 ] || exit 1
) || _fail "round-trip: values written by conf_save do not read back identically"
_ok "round-trip: every new var survives conf_save -> disk -> source unchanged"

STRIPCONF="$TMPBASE/strip.conf"
{
  for v in $WG_VARS CBOX_GPU CBOX_MODE; do
    printf '%s=set-value\n' "$v"
  done
  printf 'CBOX_NAME=myprofile\n'
} > "$STRIPCONF"

_cbox_strip_machine_scoped_vars "$STRIPCONF"

for v in $WG_VARS; do
  grep -q "^${v}=" "$STRIPCONF" && _fail "isolated-derivation skip: $v should have been stripped from the per-project cbox.conf, still present"
done
grep -q '^CBOX_GPU=set-value' "$STRIPCONF" || _fail "isolated-derivation skip: an unrelated project-scoped var (CBOX_GPU) should survive the strip"
_ok "isolated-derivation skip: _cbox_strip_machine_scoped_vars removes exactly the wireguard lines too, leaves everything else"

run_local_wizard_subset="$(awk '/^run_local_wizard_subset\(\) \{/,/^}$/' "$INSTALL_DIR/lib/cbox-setup.sh")"
case "$run_local_wizard_subset" in
  *step_wireguard*) _fail "wiring: run_local_wizard_subset (isolated per-project wizard) must never call step_wireguard" ;;
esac
_ok "wiring: the isolated per-project wizard never calls step_wireguard (machine-scoped section is never asked per-project)"

step_wireguard_body="$(awk '/^step_wireguard\(\) \{/,/^}$/' "$INSTALL_DIR/lib/cbox-setup.sh")"
[ -n "$step_wireguard_body" ] || _fail "wiring: step_wireguard function not found in setup.sh"
_ok "wiring: step_wireguard wizard function exists in setup.sh"

case "$step_wireguard_body" in
  *'mkdir'*|*'docker '*|*'docker-compose'*|*'wg genkey'*)
    _fail "off-default: step_wireguard performs a filesystem/docker/key-generation side effect directly (should defer to 'cbox ollama reconcile' / explicit key commands)"
    ;;
esac
_ok "off-default: step_wireguard never touches the filesystem or docker directly - it only stages cbox.conf values"

case "$(sec_get SEC_APPLY wireguard)" in
  infra-reconcile) ;;
  *) _fail "off-default: SEC_APPLY[wireguard] changed unexpectedly" ;;
esac
apply_cmd="$(_cbox_config_apply_cmd_for infra-reconcile)"
case "$apply_cmd" in
  *"cbox ollama reconcile"*) ;;
  *) _fail "off-default: infra-reconcile apply command should name 'cbox ollama reconcile', got: $apply_cmd" ;;
esac
_ok "off-default: applying wireguard config changes is opt-in via 'cbox ollama reconcile' (the shared owner project), never automatic"

CBOX_WG_MODE=off
case "$step_wireguard_body" in
  *'ask_choice "setup: wireguard implementation'*)
    case "$step_wireguard_body" in
      *'CBOX_WG_MODE" != off'*) ;;
      *) _fail "off-default: step_wireguard should gate its follow-up prompts behind CBOX_WG_MODE != off" ;;
    esac
    ;;
esac
_ok "off-default: step_wireguard's follow-up prompts are gated behind CBOX_WG_MODE != off"

_load_doc_coverage_block() {
  awk '
    /^v_t\(\) \{/ { infunc=1 }
    /^v_ok\(\) \{/ { infunc=1 }
    /^v_fail\(\) \{/ { infunc=1 }
    /^v_skip\(\) \{/ { infunc=1 }
    /^_cbox_verify_doc_coverage\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$INSTALL_DIR/cbox" > "$TMPBASE/doc_coverage.sh"
  source "$TMPBASE/doc_coverage.sh"
}
_load_doc_coverage_block

declare -f _cbox_verify_doc_coverage >/dev/null || _fail "extraction failed: _cbox_verify_doc_coverage not defined"

VN=0
VOK=0
VFAIL=0
VSKIP=0
DOC_COVERAGE_OUT="$(_cbox_verify_doc_coverage)"
[ "$VFAIL" -eq 0 ] || _fail "cbox verify doc-coverage guard failed: $DOC_COVERAGE_OUT"
case "$DOC_COVERAGE_OUT" in
  *"coverage gaps"*) _fail "cbox verify doc-coverage guard reported gaps: $DOC_COVERAGE_OUT" ;;
esac
_ok "cbox verify doc-coverage guard: sections in MANUAL, dep-text complete, doctor rows match both ways (wireguard included)"

grep -qiE '^### +wireguard *$' "$INSTALL_DIR/MANUAL.md" || _fail "MANUAL.md: missing '### wireguard' heading required by the doc-coverage guard"
_ok "MANUAL.md: '### wireguard' heading present"

WGHOME="$TMPBASE/wghome"
mkdir -p "$WGHOME/bin"
cat > "$WGHOME/bin/wg" <<'WGEOF'
#!/bin/sh
case "$1" in
  genkey) echo "cGwWRIbAQD8FKgYYs8gyRcgJelPeQ7WPfFdBIRO4EEo=" ;;
  pubkey) echo "aRcYqQIm9uH5B9V0IEQKddz3nO2FnHOEcYcQ0YQnMBs=" ;;
esac
WGEOF
chmod +x "$WGHOME/bin/wg"

declare -f _cbox_wg_keygen >/dev/null || _fail "extraction failed: _cbox_wg_keygen not defined (templates/generators.sh)"
declare -f _cbox_wg_peer_add >/dev/null || _fail "extraction failed: _cbox_wg_peer_add not defined (templates/generators.sh)"

(
  HOME="$WGHOME/home"
  export HOME
  PATH="$WGHOME/bin:$PATH"
  export PATH
  mkdir -p "$HOME"
  _cbox_wg_keygen || exit 1
  priv="$(_cbox_wg_privkey_file)"
  pub="$(_cbox_wg_pubkey_file)"
  [ -f "$priv" ] || { echo "private key file missing" >&2; exit 1; }
  [ -f "$pub" ] || { echo "public key file missing" >&2; exit 1; }
  privperm="$(stat -c '%a' "$priv")"
  [ "$privperm" = "600" ] || { echo "private key perms: got $privperm want 600" >&2; exit 1; }
  [ "$(cat "$priv")" = "cGwWRIbAQD8FKgYYs8gyRcgJelPeQ7WPfFdBIRO4EEo=" ] || { echo "private key content mismatch" >&2; exit 1; }
  [ "$(cat "$pub")" = "aRcYqQIm9uH5B9V0IEQKddz3nO2FnHOEcYcQ0YQnMBs=" ] || { echo "public key content mismatch" >&2; exit 1; }
) || _fail "key material: _cbox_wg_keygen did not produce a 0600 private key and matching public key"
_ok "key material: _cbox_wg_keygen creates privatekey (0600) and publickey from the wg CLI"

(
  HOME="$WGHOME/home2"
  export HOME
  PATH="/usr/bin:/bin"
  export PATH
  mkdir -p "$HOME"
  if _cbox_wg_keygen 2>"$TMPBASE/wgkeygen.err"; then
    echo "keygen unexpectedly succeeded without wg installed" >&2
    exit 1
  fi
  grep -qi "wireguard-tools" "$TMPBASE/wgkeygen.err" || { echo "error message did not name the wireguard-tools package: $(cat "$TMPBASE/wgkeygen.err")" >&2; exit 1; }
  [ -e "$(_cbox_wg_privkey_file)" ] && { echo "a placeholder private key was written despite missing tools" >&2; exit 1; }
  exit 0
) || _fail "key material: missing wg tooling should fail naming the package, never write a placeholder key"
_ok "key material: missing wireguard-tools fails cleanly, names the package, writes nothing"

ALPHA_PUBKEY="fRcYqQIm9uH5B9V0IEQKddz3nO2FnHOEcYcQ0YQnMBs="
(
  HOME="$WGHOME/peerhome"
  unset CBOX_WG_PEER_PUBKEY CBOX_WG_PEER_ADDRESS
  export HOME
  mkdir -p "$HOME"
  _cbox_wg_peer_add alpha "$ALPHA_PUBKEY" "10.90.0.12/32" || exit 1
  out="$(_cbox_wg_peer_list)"
  [ "$out" = "alpha|$ALPHA_PUBKEY|10.90.0.12/32||ollama" ] || { echo "peer list mismatch: $out" >&2; exit 1; }
  perm="$(stat -c '%a' "$(_cbox_wg_peers_file)")"
  [ "$perm" = "600" ] || { echo "peers file perms: got $perm want 600" >&2; exit 1; }
) || _fail "peer store: add + list round-trip failed"
_ok "peer store: add + list round-trip (name|pubkey|allowed-address|endpoint|capability), file mode 0600, new peer defaults to capability=ollama"

(
  HOME="$WGHOME/peerhome"
  export HOME
  _cbox_wg_peer_add alpha "bRcYqQIm9uH5B9V0IEQKddz3nO2FnHOEcYcQ0YQnMBs=" "10.90.0.3/32" 2>/dev/null && exit 1
  exit 0
) || _fail "peer store: duplicate name should be refused"
_ok "peer store: refuses a duplicate peer name"

(
  HOME="$WGHOME/peerhome"
  export HOME
  _cbox_wg_peer_add beta "$ALPHA_PUBKEY" "10.90.0.4/32" 2>/dev/null && exit 1
  exit 0
) || _fail "peer store: duplicate public key should be refused"
_ok "peer store: refuses a duplicate public key"

(
  HOME="$WGHOME/peerhome"
  export HOME
  _cbox_wg_peer_add wideopen "cRcYqQIm9uH5B9V0IEQKddz3nO2FnHOEcYcQ0YQnMBs=" "10.90.0.0/24" 2>/dev/null && exit 1
  exit 0
) || _fail "peer store: non-host (wider than /32) allowed address should be refused"
_ok "peer store: refuses a non-host allowed address"

(
  HOME="$WGHOME/peerhome"
  export HOME
  _cbox_wg_peer_add "bad name" "dRcYqQIm9uH5B9V0IEQKddz3nO2FnHOEcYcQ0YQnMBs=" "10.90.0.5/32" 2>/dev/null && exit 1
  exit 0
) || _fail "peer store: invalid peer name should be refused"
_ok "peer store: refuses an invalid peer name"

(
  HOME="$WGHOME/peerhome"
  export HOME
  _cbox_wg_peer_add gamma "not-a-valid-key" "10.90.0.6/32" 2>/dev/null && exit 1
  exit 0
) || _fail "peer store: invalid public key should be refused"
_ok "peer store: refuses an invalid public key"

(
  HOME="$WGHOME/peerhome"
  export HOME
  _cbox_wg_peer_add gamma "eRcYqQIm9uH5B9V0IEQKddz3nO2FnHOEcYcQ0YQnMBs=" "10.90.0.7/32" || exit 1
  _cbox_wg_peer_remove alpha || exit 1
  out="$(_cbox_wg_peer_list)"
  case "$out" in
    *alpha*) echo "alpha still present after removal" >&2; exit 1 ;;
  esac
  case "$out" in
    *gamma*) ;;
    *) echo "gamma missing after removing alpha" >&2; exit 1 ;;
  esac
  _cbox_wg_peer_remove ghost 2>/dev/null && { echo "removing a nonexistent peer unexpectedly succeeded" >&2; exit 1; }
  exit 0
) || _fail "peer store: remove deletes exactly the named peer and leaves the rest, refuses unknown names"
_ok "peer store: remove deletes exactly the named peer, leaves the rest, refuses an unknown name"

echo "PASS: all wireguard section tests"
