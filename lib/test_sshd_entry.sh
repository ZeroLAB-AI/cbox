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

bash -n "$INSTALL_DIR/cbox" || _fail "cbox fails bash -n"
bash -n "$INSTALL_DIR/templates/generators.sh" || _fail "generators.sh fails bash -n"
bash -n "$INSTALL_DIR/entrypoint.sh" || _fail "entrypoint.sh fails bash -n"
_ok "bash -n clean on cbox, templates/generators.sh, entrypoint.sh"

python3 -c "import py_compile; py_compile.compile('$INSTALL_DIR/etc/container/cbox-session-entry.py', doraise=True)" \
  || _fail "cbox-session-entry.py does not py_compile"
_ok "cbox-session-entry.py py_compiles cleanly"

[ ! -f "$INSTALL_DIR/etc/container/session_broker.py" ] \
  || _fail "etc/container/session_broker.py still present - the custom broker protocol was supposed to be deleted"
[ ! -f "$INSTALL_DIR/etc/container/cbox-session-remote" ] \
  || _fail "etc/container/cbox-session-remote still present - the custom broker client was supposed to be deleted"
_ok "old session broker and its remote client are deleted"

grep -q 'openssh-server' "$INSTALL_DIR/templates/generators.sh" \
  || _fail "openssh-server missing from _cbox_final_pkgs"
_ok "openssh-server is in the rendered package list"

grep -q 'session-broker) shift; session_broker_cmd "\$@";;' "$INSTALL_DIR/cbox" \
  || _fail "session-broker verb not wired into the dispatcher"
grep -q 'session-broker {status|access {disabled|viewer|full-attach}|window {off|<minutes>}|key {add <pubkey-file> \[comment\]|rm <fingerprint>|fingerprints}}' "$INSTALL_DIR/cbox" \
  || _fail "session-broker missing from usage text"
grep -q 'HUB_ROWS+=("session-broker")' "$INSTALL_DIR/cbox" \
  || _fail "session-broker row missing from the hub"
grep -q 'session-broker) _hub_session_broker_submenu' "$INSTALL_DIR/cbox" \
  || _fail "session-broker row not dispatched in the hub"
_ok "wiring: dispatcher, usage, hub row and hub dispatch all present"

grep -q '_cbox_session_broker_key_add_cmd' "$INSTALL_DIR/cbox" \
  || _fail "key add subcommand missing"
grep -q '_cbox_session_broker_key_rm_cmd' "$INSTALL_DIR/cbox" \
  || _fail "key rm subcommand missing"
grep -q '_cbox_session_broker_key_fingerprints_cmd' "$INSTALL_DIR/cbox" \
  || _fail "key fingerprints subcommand missing"
_ok "wiring: key add/rm/fingerprints subcommands present"

awk '/^session_broker_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q '_cbox_config_in_container' \
  || _fail "session_broker_cmd does not refuse to run inside a container"
_ok "guard: session-broker CLI is host-only"

grep -q '"CBOX_SESSION_BROKER_MODE"' "$INSTALL_DIR/etc/registry/settings.json" \
  || _fail "CBOX_SESSION_BROKER_MODE missing from the registry"
grep -q '"CBOX_SSHD_LISTEN_ADDR"' "$INSTALL_DIR/etc/registry/settings.json" \
  || _fail "CBOX_SSHD_LISTEN_ADDR missing from the registry"
grep -q '"CBOX_SSHD_PORT"' "$INSTALL_DIR/etc/registry/settings.json" \
  || _fail "CBOX_SSHD_PORT missing from the registry"
_ok "registry: CBOX_SESSION_BROKER_MODE, CBOX_SSHD_LISTEN_ADDR, CBOX_SSHD_PORT declared"

render_isolated() {
  local eff="$1" root="$2" home="$3" mode="$4" addr="$5" port="$6"
  mkdir -p "$eff" "$root" "$home"
  ( set -e
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    export HOME="$home"
    export CBOX_CLAUDE_MODE=volume
    export CBOX_CODEX_MODE=volume
    export CBOX_SESSION_BROKER_MODE="$mode"
    export CBOX_SSHD_LISTEN_ADDR="$addr"
    export CBOX_SSHD_PORT="$port"
    gen_compose_isolated "$eff" "$root" "cbox-img:test" "abcdef123456"
  )
}

OFF="$TMPBASE/off"
render_isolated "$OFF/eff" "$OFF/root" "$OFF/home" disabled "" 2222
COMPOSE_OFF="$OFF/eff/docker-compose.yml"
[ -f "$COMPOSE_OFF" ] || _fail "disabled: docker-compose.yml missing"
! grep -qi 'sshd' "$COMPOSE_OFF" \
  || _fail "disabled: compose still mentions sshd with CBOX_SESSION_BROKER_MODE=disabled:
$(grep -i 'sshd' "$COMPOSE_OFF")"
! grep -q '^    ports:' "$COMPOSE_OFF" \
  || _fail "disabled: compose publishes a port with CBOX_SESSION_BROKER_MODE=disabled"
[ ! -f "$OFF/eff/sshd_config" ] || _fail "disabled: sshd_config was rendered"
[ ! -d "$OFF/eff/sshd-hostkeys" ] || _fail "disabled: host keys were generated"
[ ! -f "$OFF/eff/sshd-authorized_keys" ] || _fail "disabled: authorized_keys file was created"
[ ! -d "$OFF/eff/sshd-access" ] || _fail "disabled: access-level directory was created"
_ok "inert default: CBOX_SESSION_BROKER_MODE=disabled renders nothing - no compose reference, no port, no config, no keys, no access dir"

REFUSE_EMPTY="$TMPBASE/refuse_empty"
mkdir -p "$REFUSE_EMPTY"
if render_isolated "$REFUSE_EMPTY/eff" "$REFUSE_EMPTY/root" "$REFUSE_EMPTY/home" viewer "" 2222 2>"$REFUSE_EMPTY/err.log"; then
  _fail "render did not refuse an empty CBOX_SSHD_LISTEN_ADDR while active"
fi
grep -q 'refusing to render sshd_config' "$REFUSE_EMPTY/err.log" \
  || _fail "refusal message missing for empty CBOX_SSHD_LISTEN_ADDR"
_ok "refusal: active tier with empty CBOX_SSHD_LISTEN_ADDR refuses to render"

REFUSE_WILD="$TMPBASE/refuse_wild"
mkdir -p "$REFUSE_WILD"
if render_isolated "$REFUSE_WILD/eff" "$REFUSE_WILD/root" "$REFUSE_WILD/home" viewer "0.0.0.0" 2222 2>"$REFUSE_WILD/err.log"; then
  _fail "render did not refuse a wildcard CBOX_SSHD_LISTEN_ADDR"
fi
grep -q 'wildcard' "$REFUSE_WILD/err.log" \
  || _fail "refusal message missing for wildcard CBOX_SSHD_LISTEN_ADDR"
_ok "refusal: 0.0.0.0 (wildcard) CBOX_SSHD_LISTEN_ADDR is refused"

VIEWER="$TMPBASE/viewer"
render_isolated "$VIEWER/eff" "$VIEWER/root" "$VIEWER/home" viewer "10.90.0.5" 2222
COMPOSE_VIEWER="$VIEWER/eff/docker-compose.yml"
[ -f "$VIEWER/eff/sshd_config" ] || _fail "viewer: sshd_config not rendered"
[ -f "$VIEWER/eff/sshd-hostkeys/ssh_host_ed25519_key" ] || _fail "viewer: ed25519 host key not generated"
[ -f "$VIEWER/eff/sshd-hostkeys/ssh_host_rsa_key" ] || _fail "viewer: rsa host key not generated"
[ -f "$VIEWER/eff/sshd-authorized_keys" ] || _fail "viewer: authorized_keys file not created"
[ ! -s "$VIEWER/eff/sshd-authorized_keys" ] || _fail "viewer: authorized_keys was not empty on first render (must never be generated silently)"
[ -f "$VIEWER/eff/sshd-access/level" ] || _fail "viewer: access level file not created"
[ "$(cat "$VIEWER/eff/sshd-access/level")" = disabled ] \
  || _fail "viewer: access level file must default to disabled even though the registry tier is viewer (fail closed until the operator flips it explicitly)"
! grep -q '^    ports:' "$COMPOSE_VIEWER" \
  || _fail "viewer: the sshd port is published into the HOST namespace - it must only ever be reachable inside the container netns, through the wireguard forward:
$(grep -A2 '^    ports:' "$COMPOSE_VIEWER")"
grep -q '/etc/cbox-sshd/sshd_config:ro' "$COMPOSE_VIEWER" || _fail "viewer: sshd_config not mounted read-only"
grep -q '/etc/cbox-sshd/hostkeys:ro' "$COMPOSE_VIEWER" || _fail "viewer: host keys not mounted read-only"
grep -q '/etc/cbox-sshd/authorized_keys:ro' "$COMPOSE_VIEWER" || _fail "viewer: authorized_keys not mounted read-only"
grep -q '/etc/cbox-sshd/access.level:ro' "$COMPOSE_VIEWER" || _fail "viewer: access.level not mounted read-only"
grep -q '/etc/cbox-sshd/access.window:ro' "$COMPOSE_VIEWER" || _fail "viewer: access.window not mounted read-only"
! grep -q 'TMUX_TMPDIR' "$COMPOSE_VIEWER" \
  || _fail "viewer: TMUX_TMPDIR appears in compose - the tmux socket path must never be caller-influenced"
_ok "viewer: sshd_config, host keys, empty authorized_keys, access files and read-only mounts render correctly, and no host port is published"

HOSTKEY_BEFORE="$(sha256sum "$VIEWER/eff/sshd-hostkeys/ssh_host_ed25519_key" | awk '{print $1}')"
render_isolated "$VIEWER/eff" "$VIEWER/root" "$VIEWER/home" full-attach "10.90.0.5" 2222
HOSTKEY_AFTER="$(sha256sum "$VIEWER/eff/sshd-hostkeys/ssh_host_ed25519_key" | awk '{print $1}')"
[ "$HOSTKEY_BEFORE" = "$HOSTKEY_AFTER" ] \
  || _fail "host key changed across a re-render/recreate - the peer would see a changed-host-key warning"
_ok "host keys are stable across a re-render (recreate does not rotate them)"

SSHD_CONFIG="$VIEWER/eff/sshd_config"
for directive in \
  'PasswordAuthentication no' \
  'KbdInteractiveAuthentication no' \
  'PermitEmptyPasswords no' \
  'PermitRootLogin no' \
  'AllowTcpForwarding no' \
  'AllowAgentForwarding no' \
  'AllowStreamLocalForwarding no' \
  'X11Forwarding no' \
  'PermitTunnel no' \
  'GatewayPorts no' \
  'PermitOpen none' \
  'ForceCommand /opt/cbox/cbox-session-entry.py'; do
  grep -qF -- "$directive" "$SSHD_CONFIG" || _fail "sshd_config missing hardening directive: $directive"
done
grep -q '^ListenAddress 10.90.0.5$' "$SSHD_CONFIG" || _fail "sshd_config ListenAddress not the scoped address"
! grep -q '^ListenAddress 0.0.0.0$' "$SSHD_CONFIG" || _fail "sshd_config binds a wildcard address"
grep -q "^AllowUsers $(id -un)\$" "$SSHD_CONFIG" || _fail "sshd_config AllowUsers is not limited to the single host user"
_ok "sshd_config carries every required hardening directive, asserted by name"

python3 - "$SSHD_CONFIG" << 'PYEOF'
import sys
path = sys.argv[1]
lines = [l.split()[0] for l in open(path) if l.strip()]
if lines.count("ListenAddress") != 1:
    sys.stderr.write("expected exactly one ListenAddress directive, found %d\n" % lines.count("ListenAddress"))
    sys.exit(1)
if lines.count("Port") != 1:
    sys.stderr.write("expected exactly one Port directive\n")
    sys.exit(1)
PYEOF
_ok "sshd_config has exactly one ListenAddress and one Port directive"

FULL="$TMPBASE/full"
render_isolated "$FULL/eff" "$FULL/root" "$FULL/home" full-attach "10.90.0.6" 2200
! grep -q '^    ports:' "$FULL/eff/docker-compose.yml" \
  || _fail "full-attach: the sshd port must never be published into the host namespace"
grep -q '^Port 2200$' "$FULL/eff/sshd_config" || _fail "full-attach: custom port not honored in sshd_config"
_ok "full-attach: a custom CBOX_SSHD_PORT reaches sshd_config and is never published on the host"

KEYFUNCS="$TMPBASE/key_funcs.sh"
{
  awk '/^_cbox_session_broker_key_add_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox"
  awk '/^_cbox_session_broker_key_rm_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox"
  awk '/^_cbox_session_broker_key_fingerprints_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox"
} > "$KEYFUNCS"
[ -s "$KEYFUNCS" ] || _fail "could not extract key add/rm/fingerprints function bodies from cbox"

KEYEFF="$TMPBASE/keyeff"
mkdir -p "$KEYEFF"
: > "$KEYEFF/sshd-authorized_keys"
chmod 0600 "$KEYEFF/sshd-authorized_keys"

ssh-keygen -q -t ed25519 -N '' -C 'phone' -f "$TMPBASE/id_phone" || _fail "could not generate a test keypair"

(
  set -e
  _cbox_sshd_target_effdir() { printf '%s' "$KEYEFF"; }
  . "$KEYFUNCS"
  _cbox_session_broker_key_add_cmd "$TMPBASE/id_phone.pub" "phone" || exit 1
) || _fail "key add failed on a freshly rendered empty authorized_keys"
grep -q '^restrict,pty ssh-ed25519 ' "$KEYEFF/sshd-authorized_keys" \
  || _fail "added key line missing the restrict,pty option prefix"
grep -q ' phone$' "$KEYEFF/sshd-authorized_keys" \
  || _fail "added key line missing the trailing comment"
_ok "key add: appends restrict,pty-prefixed line with comment to authorized_keys"

(
  set -e
  _cbox_sshd_target_effdir() { printf '%s' "$KEYEFF"; }
  . "$KEYFUNCS"
  _cbox_session_broker_key_add_cmd "$TMPBASE/id_phone.pub" "phone-again" && exit 1
  exit 0
) || _fail "key add did not refuse a duplicate key"
[ "$(grep -c '^restrict,pty' "$KEYEFF/sshd-authorized_keys")" = 1 ] \
  || _fail "duplicate key add mutated authorized_keys despite refusing"
_ok "key add: refuses a key already present, file left with exactly one entry"

FP="$(ssh-keygen -lf "$TMPBASE/id_phone.pub" | awk '{print $2}')"
(
  set -e
  _cbox_sshd_target_effdir() { printf '%s' "$KEYEFF"; }
  . "$KEYFUNCS"
  _cbox_session_broker_key_fingerprints_cmd
) > "$TMPBASE/fp_out.log" || _fail "key fingerprints failed"
grep -qF "$FP" "$TMPBASE/fp_out.log" || _fail "key fingerprints did not list the added key's fingerprint"
_ok "key fingerprints: lists the fingerprint of a trusted key"

(
  set -e
  _cbox_sshd_target_effdir() { printf '%s' "$KEYEFF"; }
  . "$KEYFUNCS"
  _cbox_session_broker_key_rm_cmd "$FP" || exit 1
) || _fail "key rm failed to remove a present fingerprint"
[ ! -s "$KEYEFF/sshd-authorized_keys" ] || _fail "key rm left authorized_keys non-empty after removing the only key"
_ok "key rm: removes the matching fingerprint, authorized_keys empty again"

(
  set -e
  _cbox_sshd_target_effdir() { printf '%s' "$KEYEFF"; }
  . "$KEYFUNCS"
  _cbox_session_broker_key_rm_cmd "SHA256:doesnotexist" && exit 1
  exit 0
) || _fail "key rm did not refuse an unknown fingerprint"
_ok "key rm: refuses a fingerprint that is not present"

GLOBALSTATE="$TMPBASE/globalstate"
mkdir -p "$GLOBALSTATE"
GLOBAL_BASE="$(
  INSTALL_DIR="$GLOBALSTATE" HOME="$TMPBASE/fakehome" \
  bash -c 'source "'"$INSTALL_DIR/templates/generators.sh"'" >/dev/null 2>&1 || true
           _cbox_sshd_hostkeys_dir_into "$INSTALL_DIR"' 2>/dev/null
)"
case "$GLOBAL_BASE" in
  "$GLOBALSTATE"/*) _fail "global mode writes sshd private state into the package tree ($GLOBAL_BASE) - it is rsync-published, so a host private key would leave the machine" ;;
esac
_ok "global mode keeps sshd host keys and authorized_keys out of the package tree"

echo "PASS: all sshd render/wiring checks"
