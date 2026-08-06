#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() { echo "FAIL: $*" >&2; exit 1; }
_ok() { echo "ok: $*"; }

. "$INSTALL_DIR/lib/portable.sh"

OLD_SETUP="$INSTALL_DIR/lib/fixtures/setup.sh.pre_conf_writer_snapshot"
OLD_CBOX="$INSTALL_DIR/lib/fixtures/cbox.pre_conf_writer_snapshot"
OLD_SECTIONS_SH="$INSTALL_DIR/lib/fixtures/sections.sh.pre_registry_snapshot"
[ -f "$OLD_SETUP" ] || _fail "pre-conf-writer setup.sh snapshot fixture not found at $OLD_SETUP"
[ -f "$OLD_CBOX" ] || _fail "pre-conf-writer cbox snapshot fixture not found at $OLD_CBOX"
[ -f "$OLD_SECTIONS_SH" ] || _fail "pre-registry sections.sh snapshot fixture not found at $OLD_SECTIONS_SH"

NEW_SETUP="$INSTALL_DIR/setup.sh"
SECTIONS_SH="$INSTALL_DIR/templates/sections.sh"
CONF_LIB="$INSTALL_DIR/templates/conf_lib.sh"
[ -f "$SECTIONS_SH" ] || _fail "templates/sections.sh missing"
[ -f "$CONF_LIB" ] || _fail "templates/conf_lib.sh missing"

FIXDIR="$TMPBASE/fixtures"
mkdir -p "$FIXDIR"

: > "$FIXDIR/default.sh"

cat > "$FIXDIR/full.sh" << 'EOF'
CBOX_NAME='myprofile'
CBOX_CLAUDE_MODE='volume'
CBOX_CLAUDE_PATH='/home/user/.claude'
CBOX_CLAUDE_BACKUP='y'
CBOX_CODEX_MODE='volume'
CBOX_CODEX_PATH='/home/user/.codex'
CBOX_CODEX_BACKUP='c'
CBOX_WORKSPACES='/home/user/proj1 /home/user/proj2'
CBOX_VENV_MODE='volume'
CBOX_VENV_PATH='/home/user/.venvs/custom'
CBOX_GPU='1'
CBOX_EGRESS_MODE='allowlist'
CBOX_EGRESS_APPLIED='1'
CBOX_NETACCESS_MODE='socks'
CBOX_NETACCESS_APPLIED='1'
CBOX_NETACCESS_SCOPE='list'
CBOX_NETACCESS_NETWORKS='net-a net-b'
CBOX_NETACCESS_CIDRS='10.0.0.0/8'
CBOX_NETACCESS_SOCKS_PORT='1090'
CBOX_NETACCESS_EXEC_MODE='scoped'
CBOX_NETACCESS_EXEC_WORKSPACE_GUARD='on'
CBOX_NETACCESS_EXEC_TIMEOUT='600'
CBOX_NETACCESS_EXEC_MAX_BYTES='2048000'
CBOX_HOST_ROUTE_MODE='host-proxy'
CBOX_HOST_ROUTE_APPLIED='1'
CBOX_HOST_PROXY_URL='http://host.docker.internal:3128'
CBOX_HOST_PROXY_ADDR_MODE='explicit'
CBOX_HOST_GATEWAY_ALIAS='on'
CBOX_SSH_MODE='mixed'
CBOX_SSH_AGENT_DIR='/run/user/1000/cbox-ssh'
CBOX_BASHRC='0'
CBOX_MCP_SERVERS='alpha beta'
CBOX_CODEX_PROGRESS_MODE='shim'
CBOX_LOCAL_MODEL='on'
CBOX_LOCAL_MODEL_URL='http://localhost:11434/v1'
CBOX_LOCAL_MODEL_NAME='qwen2.5:7b'
CBOX_HERMES='on'
CBOX_HERMES_VERSION='0.20.0'
CBOX_HERMES_PROVIDER='openai'
CBOX_HERMES_MODEL_URL='http://localhost:8000'
CBOX_HERMES_MODEL_NAME='hermes-4'
CBOX_HERMES_DELEGATE='on'
CBOX_HERMES_DELEGATE_PROVIDER='local'
CBOX_HERMES_DELEGATE_BASE_URL='http://localhost:11434'
CBOX_HERMES_DELEGATE_MODEL='qwen2.5:7b'
CBOX_HERMES_DELEGATE_MAX_CONCURRENCY='4'
CBOX_HERMES_DELEGATE_QUEUE_WAIT_SEC='600'
CBOX_HERMES_DELEGATE_LOCK_DIR='/tmp/locks'
OLLAMA_NUM_PARALLEL='4'
CBOX_HERMES_DELEGATE_MODE='qa'
CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS='terminal,file,web'
CBOX_OLLAMA_MODE='on'
CBOX_OLLAMA_IMAGE='ollama/ollama:0.33.0'
CBOX_OLLAMA_GPU='cdi'
CBOX_OLLAMA_STORE='shared'
CBOX_OLLAMA_STORE_PATH='/home/user/.ollama'
CBOX_OLLAMA_PORT='11500'
CBOX_OLLAMA_NUM_PARALLEL='2'
CBOX_WG_MODE='both'
CBOX_WG_IMPL='kernel'
CBOX_WG_ADDRESS='10.90.0.1/24'
CBOX_WG_LISTEN_PORT='51821'
CBOX_WG_PUBLISH_ADDR='192.168.1.5'
CBOX_WG_PEER_ENDPOINT='example.com:51820'
CBOX_WG_PEER_PUBKEY='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
CBOX_WG_PEER_ADDRESS='10.90.0.2/32'
CBOX_WG_KEEPALIVE='15'
CBOX_LIMIT_AUTORESUME='on'
CBOX_SESSION_MULTIPLEX='on'
CBOX_SESSION_BROKER_MODE='viewer'
CBOX_SSHD_LISTEN_ADDR='10.90.0.1'
CBOX_SSHD_PORT='2222'
CBOX_LIMIT_RESUME_DELAY='120'
CBOX_LIMIT_RESUME_PROMPT='pokracuj prosim'
CBOX_LIMIT_RESUME_STAGGER='10'
CBOX_LIMIT_RESUME_MAX_PER_DAY='20'
CBOX_AGENTS='worker debugger'
CBOX_CODEX_MCP='1'
CBOX_GITCONFIG='1'
CBOX_APT_EXTRA='jq ripgrep'
CBOX_CLAUDE_TARGET='1.2.3'
CBOX_CODEX_VERSION='1.0.0'
CBOX_CODEX_TARGET='custom-target'
CBOX_BINS_SCOPE='pinned'
CBOX_AUTOUPDATE='off'
CBOX_AUTOUPDATE_TTL_HOURS='48'
CBOX_DNS_MODE='host'
CBOX_DNS_SERVERS='9.9.9.9'
CBOX_DNS_STUB_IP='127.0.0.53'
CBOX_CLIPBOARD_MODE='bridge'
CBOX_RESTART_POLICY='unless-stopped'
CBOX_TPL_SHA='deadbeefcafe'
CBOX_MODE='isolated'
CBOX_SESSION_SCOPE='global'
CBOX_BASE_DIGEST_TTL='7200'
CBOX_HISTORY='0'
CBOX_GIT='0'
CBOX_DIARY='0'
CBOX_OPEN_QUESTIONS='0'
CBOX_CONTEXT_PROFILE='light'
CBOX_WORKDIR='/home/user/proj1'
EOF

cat > "$FIXDIR/isolated.sh" << 'EOF'
CBOX_MODE='isolated'
CBOX_SESSION_SCOPE='isolated'
CBOX_WORKSPACES='/home/user/only-project'
CBOX_WORKDIR='/home/user/only-project'
CBOX_RESTART_POLICY='no'
CBOX_GPU='0'
CBOX_HERMES='off'
EOF

python3 - "$FIXDIR/special_chars.sh" << 'PYEOF'
import sys
out = sys.argv[1]
rows = {
    "CBOX_NAME": "my profile with spaces",
    "CBOX_WORKSPACES": "/home/user/my proj/sub dir",
    "CBOX_LIMIT_RESUME_PROMPT": "pokracuj \"now\" $HOME `echo hi` \\ back'quote'",
    "CBOX_APT_EXTRA": "pkg1 pkg2",
    "CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS": "terminal,file",
}
with open(out, "w") as f:
    for k, v in rows.items():
        f.write("%s=%s\n" % (k, "'" + v.replace("'", "'\\''") + "'"))
PYEOF

_run_old_conf_save() {
  local fixture="$1" out="$2" fixedhome="$3"
  local work="$TMPBASE/old_work_$$_$RANDOM"
  mkdir -p "$work"
  awk '/^conf_defaults\(\) \{/,/^}$/' "$OLD_SETUP" > "$work/defaults.sh"
  awk '/^conf_save\(\) \{/,/^}$/' "$OLD_SETUP" > "$work/save.sh"
  [ -s "$work/defaults.sh" ] || _fail "extract old conf_defaults failed"
  [ -s "$work/save.sh" ] || _fail "extract old conf_save failed"
  (
    export HOME="$fixedhome"
    mkdir -p "$HOME"
    if [ -s "$fixture" ]; then . "$fixture"; fi
    . "$work/defaults.sh"
    . "$work/save.sh"
    conf_defaults
    conf_save "$out"
  )
}

_run_new_conf_save() {
  local fixture="$1" out="$2" fixedhome="$3"
  local work="$TMPBASE/new_work_$$_$RANDOM"
  mkdir -p "$work"
  awk '/^conf_defaults\(\) \{/,/^}$/' "$NEW_SETUP" > "$work/defaults.sh"
  awk '/^conf_save\(\) \{/,/^}$/' "$NEW_SETUP" > "$work/save.sh"
  [ -s "$work/defaults.sh" ] || _fail "extract new conf_defaults failed"
  [ -s "$work/save.sh" ] || _fail "extract new conf_save failed"
  (
    export HOME="$fixedhome"
    mkdir -p "$HOME"
    . "$SECTIONS_SH"
    . "$CONF_LIB"
    if [ -s "$fixture" ]; then . "$fixture"; fi
    . "$work/defaults.sh"
    . "$work/save.sh"
    conf_defaults
    conf_save "$out"
  )
}

_strip_container_exec_tool_line() {
  local src="$1" out="$2"
  grep -v '^CBOX_CONTAINER_EXEC_TOOL=' "$src" \
    | grep -v "^CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG=" \
    | grep -v '^CBOX_SESSION_MULTIPLEX=' \
    | grep -v '^CBOX_SESSION_BROKER_MODE=' \
    | grep -v '^CBOX_SSHD_LISTEN_ADDR=' \
    | grep -v '^CBOX_SSHD_PORT=' \
    | grep -v '^CBOX_WG_FORWARDS=' \
    | grep -v '^CBOX_KERNEL_LANG_OUTPUT=' \
    | grep -v '^CBOX_KERNEL_LANG_REASONING=' \
    | grep -v '^CBOX_USER_DIR=' > "$out"
}

for fx in default full isolated special_chars; do
  fixedhome="$TMPBASE/home_$fx"
  mkdir -p "$fixedhome"
  _run_old_conf_save "$FIXDIR/$fx.sh" "$TMPBASE/old_$fx.conf" "$fixedhome"
  _run_new_conf_save "$FIXDIR/$fx.sh" "$TMPBASE/new_$fx.conf" "$fixedhome"
  grep -qx 'CBOX_CONTAINER_EXEC_TOOL=off' "$TMPBASE/new_$fx.conf" \
    || _fail "conf_save output for fixture '$fx' is missing the new CBOX_CONTAINER_EXEC_TOOL=off line"
  grep -qx "CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG=''" "$TMPBASE/new_$fx.conf" \
    || _fail "conf_save output for fixture '$fx' is missing the new CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG='' line"
  grep -q '^CBOX_SESSION_MULTIPLEX=' "$TMPBASE/new_$fx.conf" \
    || _fail "conf_save output for fixture '$fx' is missing the new CBOX_SESSION_MULTIPLEX= line"
  grep -q '^CBOX_WG_FORWARDS=' "$TMPBASE/new_$fx.conf" \
    || _fail "conf_save output for fixture '$fx' is missing the new CBOX_WG_FORWARDS= line"
  grep -q '^CBOX_SESSION_BROKER_MODE=' "$TMPBASE/new_$fx.conf" \
    || _fail "conf_save output for fixture '$fx' is missing the new CBOX_SESSION_BROKER_MODE= line"
  grep -q '^CBOX_SSHD_LISTEN_ADDR=' "$TMPBASE/new_$fx.conf" \
    || _fail "conf_save output for fixture '$fx' is missing the new CBOX_SSHD_LISTEN_ADDR= line"
  grep -q '^CBOX_SSHD_PORT=' "$TMPBASE/new_$fx.conf" \
    || _fail "conf_save output for fixture '$fx' is missing the new CBOX_SSHD_PORT= line"
  grep -qx "CBOX_KERNEL_LANG_OUTPUT=''" "$TMPBASE/new_$fx.conf" \
    || _fail "conf_save output for fixture '$fx' is missing the new CBOX_KERNEL_LANG_OUTPUT='' line"
  grep -q '^CBOX_KERNEL_LANG_REASONING=' "$TMPBASE/new_$fx.conf" \
    || _fail "conf_save output for fixture '$fx' is missing the new CBOX_KERNEL_LANG_REASONING= line"
  grep -q '^CBOX_USER_DIR=' "$TMPBASE/new_$fx.conf" \
    || _fail "conf_save output for fixture '$fx' is missing the new CBOX_USER_DIR= line"
  _strip_container_exec_tool_line "$TMPBASE/new_$fx.conf" "$TMPBASE/new_stripped_$fx.conf"
  cmp -s "$TMPBASE/old_$fx.conf" "$TMPBASE/new_stripped_$fx.conf" \
    || _fail "conf_save output diverged for fixture '$fx' beyond the new CBOX_CONTAINER_EXEC_TOOL/CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG/CBOX_SESSION_MULTIPLEX/CBOX_WG_FORWARDS/CBOX_SESSION_BROKER_MODE/CBOX_SSHD_LISTEN_ADDR/CBOX_SSHD_PORT/CBOX_KERNEL_LANG_OUTPUT/CBOX_KERNEL_LANG_REASONING lines:
$(diff -u "$TMPBASE/old_$fx.conf" "$TMPBASE/new_stripped_$fx.conf" || true)"
  _ok "conf_save (setup.sh, legacy key order): byte-identical to pre-registry output for fixture '$fx' aside from the new CBOX_CONTAINER_EXEC_TOOL/CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG/CBOX_SESSION_MULTIPLEX/CBOX_WG_FORWARDS/CBOX_SESSION_BROKER_MODE/CBOX_SSHD_LISTEN_ADDR/CBOX_SSHD_PORT/CBOX_KERNEL_LANG_OUTPUT/CBOX_KERNEL_LANG_REASONING lines"
done

_run_old_whitelist_writer() {
  local fixture="$1" out="$2" skip_machine="$3" preserve_from="$4"
  local work="$TMPBASE/oldw_$$_$RANDOM"
  mkdir -p "$work"
  awk '
    /^_cbox_config_load_sections\(\) \{/ { infunc=1 }
    /^_cbox_config_whitelist\(\) \{/ { infunc=1 }
    /^_cbox_config_is_whitelisted\(\) \{/ { infunc=1 }
    /^_cbox_config_preserve_extra_lines\(\) \{/ { infunc=1 }
    /^_cbox_machine_scoped_vars\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$OLD_CBOX" > "$work/funcs.sh"
  [ -s "$work/funcs.sh" ] || _fail "extract old whitelist writer helpers failed"
  (
    INSTALL_DIR="$INSTALL_DIR"
    die() { echo "die: $*" >&2; exit 1; }
    . "$OLD_SECTIONS_SH"
    . "$work/funcs.sh"
    if [ -s "$fixture" ]; then . "$fixture"; fi
    {
      local v machine_scoped=""
      if [ "$skip_machine" = 1 ]; then
        machine_scoped=" $(_cbox_machine_scoped_vars | tr '\n' ' ') "
      fi
      for v in $(_cbox_config_whitelist); do
        if [ "$skip_machine" = 1 ]; then
          case "$machine_scoped" in
            *" $v "*) continue ;;
          esac
        fi
        printf '%s=%q\n' "$v" "${!v-}"
      done
      if [ -n "$preserve_from" ]; then
        _cbox_config_preserve_extra_lines "$preserve_from"
      fi
    } > "$out"
  )
}

_run_new_whitelist_writer() {
  local fixture="$1" out="$2" skip_machine="$3" preserve_from="$4"
  local work="$TMPBASE/neww_$$_$RANDOM"
  mkdir -p "$work"
  (
    . "$SECTIONS_SH"
    . "$CONF_LIB"
    _cbox_config_preserve_extra_lines() {
      local conf="$1" key
      [ -f "$conf" ] || return 0
      while IFS= read -r line; do
        case "$line" in
          [A-Z]*=*)
            key="${line%%=*}"
            local w found=0
            while IFS= read -r w; do
              [ "$w" = "$key" ] && { found=1; break; }
            done < <(_cbox_config_whitelist 2>/dev/null || true)
            [ "$found" = 1 ] || printf '%s\n' "$line"
            ;;
        esac
      done < "$conf"
    }
    _cbox_config_whitelist() {
      local s v
      for s in "${SECTIONS[@]}"; do
        for v in $(sec_get SEC_VARS "$s"); do
          printf '%s\n' "$v"
        done
      done
    }
    if [ -s "$fixture" ]; then . "$fixture"; fi
    _cbox_reg_conf_write_whitelist "$out" "$skip_machine" "$preserve_from"
  )
}

ADOPTED_KEYS=(CBOX_AUTOUPDATE CBOX_AUTOUPDATE_TTL_HOURS CBOX_DNS_MODE CBOX_DNS_SERVERS CBOX_DNS_STUB_IP CBOX_CLIPBOARD_MODE)

_expected_adopted_block() {
  local fixture="$1" out="$2"
  (
    if [ -s "$fixture" ]; then . "$fixture"; fi
    local k
    { for k in "${ADOPTED_KEYS[@]}"; do printf '%s=%q\n' "$k" "${!k-}"; done; } > "$out"
  )
}

_strip_adopted_block() {
  local new="$1" block="$2" remainder="$3"
  python3 - "$new" "$block" "$remainder" << 'PYEOF'
import sys
new = open(sys.argv[1]).read().splitlines(keepends=True)
block = open(sys.argv[2]).read().splitlines(keepends=True)
anchors = [i for i, l in enumerate(new) if l.startswith("CBOX_RESTART_POLICY=")]
if len(anchors) != 1:
    sys.stderr.write("expected exactly one CBOX_RESTART_POLICY line, found %d\n" % len(anchors))
    sys.exit(1)
i = anchors[0] + 1
if new[i:i + len(block)] != block:
    sys.stderr.write("the six adopted lines right after CBOX_RESTART_POLICY do not match the expected block:\n")
    sys.stderr.write("expected: %r\n" % block)
    sys.stderr.write("found:    %r\n" % new[i:i + len(block)])
    sys.exit(1)
open(sys.argv[3], "w").write("".join(new[:i] + new[i + len(block):]))
PYEOF
}

for fx in default full isolated special_chars; do
  for skip in 0 1; do
    _run_old_whitelist_writer "$FIXDIR/$fx.sh" "$TMPBASE/oldw_${fx}_${skip}.conf" "$skip" ""
    _run_new_whitelist_writer "$FIXDIR/$fx.sh" "$TMPBASE/neww_${fx}_${skip}.conf" "$skip" ""
    grep -q '^CBOX_CONTAINER_EXEC_TOOL=' "$TMPBASE/neww_${fx}_${skip}.conf" \
      || _fail "whitelist writer output for fixture '$fx' skip_machine=$skip is missing the new CBOX_CONTAINER_EXEC_TOOL line"
    grep -q '^CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG=' "$TMPBASE/neww_${fx}_${skip}.conf" \
      || _fail "whitelist writer output for fixture '$fx' skip_machine=$skip is missing the new CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG line"
    _strip_container_exec_tool_line "$TMPBASE/neww_${fx}_${skip}.conf" "$TMPBASE/neww_stripped_${fx}_${skip}.conf"
    _expected_adopted_block "$FIXDIR/$fx.sh" "$TMPBASE/block_${fx}_${skip}.conf"
    _strip_adopted_block "$TMPBASE/neww_stripped_${fx}_${skip}.conf" "$TMPBASE/block_${fx}_${skip}.conf" "$TMPBASE/rem_${fx}_${skip}.conf" \
      || _fail "whitelist writer: adopted six-line block malformed for fixture '$fx' skip_machine=$skip"
    cmp -s "$TMPBASE/oldw_${fx}_${skip}.conf" "$TMPBASE/rem_${fx}_${skip}.conf" \
      || _fail "whitelist writer output diverged beyond the adopted block for fixture '$fx' skip_machine=$skip:
$(diff -u "$TMPBASE/oldw_${fx}_${skip}.conf" "$TMPBASE/rem_${fx}_${skip}.conf" || true)"
    _ok "cbox config-set whitelist writer: pre-registry output plus exactly the adopted autoupdate/dns/clipboard block for fixture '$fx' skip_machine=$skip"
  done
done

UNKNOWN_SRC="$TMPBASE/with_unknown.conf"
{
  printf 'CBOX_NAME=myprofile\n'
  printf 'CBOX_TPL_SHA=deadbeef\n'
  printf 'SOME_FUTURE_KEY=future-value\n'
  printf 'CBOX_MODE=global\n'
} > "$UNKNOWN_SRC"

_run_old_whitelist_writer "$FIXDIR/default.sh" "$TMPBASE/oldw_preserve.conf" "0" "$UNKNOWN_SRC"
_run_new_whitelist_writer "$FIXDIR/default.sh" "$TMPBASE/neww_preserve.conf" "0" "$UNKNOWN_SRC"
_strip_container_exec_tool_line "$TMPBASE/neww_preserve.conf" "$TMPBASE/neww_preserve_stripped.conf"
_expected_adopted_block "$FIXDIR/default.sh" "$TMPBASE/block_preserve.conf"
_strip_adopted_block "$TMPBASE/neww_preserve_stripped.conf" "$TMPBASE/block_preserve.conf" "$TMPBASE/rem_preserve.conf" \
  || _fail "unknown-line preservation: adopted six-line block malformed"
cmp -s "$TMPBASE/oldw_preserve.conf" "$TMPBASE/rem_preserve.conf" \
  || _fail "unknown-line preservation diverged beyond the adopted block:
$(diff -u "$TMPBASE/oldw_preserve.conf" "$TMPBASE/rem_preserve.conf" || true)"
grep -qx 'SOME_FUTURE_KEY=future-value' "$TMPBASE/neww_preserve.conf" \
  || _fail "new whitelist writer dropped an unknown line it should have preserved"
grep -qx 'CBOX_NAME=myprofile' "$TMPBASE/neww_preserve.conf" \
  || _fail "new whitelist writer dropped the internal CBOX_NAME line it should have preserved"
grep -qx 'CBOX_TPL_SHA=deadbeef' "$TMPBASE/neww_preserve.conf" \
  || _fail "new whitelist writer dropped the internal CBOX_TPL_SHA line it should have preserved"
_ok "cbox config-set whitelist writer: unknown/newer-version and internal lines are preserved verbatim; only the adopted block was added over pre-registry behavior"

LEGACY_SRC="$TMPBASE/position_legacy.conf"
fixedhome3="$TMPBASE/home_position"
mkdir -p "$fixedhome3"
_run_new_conf_save "$FIXDIR/full.sh" "$LEGACY_SRC" "$fixedhome3"
_run_old_whitelist_writer "$LEGACY_SRC" "$TMPBASE/pos_old.conf" 0 "$LEGACY_SRC"
_run_new_whitelist_writer "$LEGACY_SRC" "$TMPBASE/pos_new.conf" 0 "$LEGACY_SRC"
_strip_container_exec_tool_line "$TMPBASE/pos_old.conf" "$TMPBASE/pos_old_stripped.conf"
_strip_container_exec_tool_line "$TMPBASE/pos_new.conf" "$TMPBASE/pos_new_stripped.conf"
python3 - "$TMPBASE/pos_old_stripped.conf" "$TMPBASE/pos_new_stripped.conf" "${ADOPTED_KEYS[@]}" << 'PYEOF' \
  || _fail "adoption position gate failed: rewriting a legacy-layout cbox.conf moved more than the documented CBOX_NAME relocation"
import sys
old = open(sys.argv[1]).read().splitlines()
new = open(sys.argv[2]).read().splitlines()
ADOPTED = sys.argv[3:]
assert len(ADOPTED) == 6, "expected the six adopted keys on argv, got %r" % ADOPTED


def key(line):
    return line.split("=", 1)[0]


def anchor(lines):
    hits = [i for i, l in enumerate(lines) if l.startswith("CBOX_RESTART_POLICY=")]
    assert len(hits) == 1, "expected one CBOX_RESTART_POLICY line, got %d" % len(hits)
    return hits[0]


i_old, i_new = anchor(old), anchor(new)
assert i_old == i_new, "known-line head length changed: %d vs %d" % (i_old, i_new)
assert old[:i_old + 1] == new[:i_new + 1], "lines before the tail changed"

old_tail, new_tail = old[i_old + 1:], new[i_new + 1:]
assert [key(l) for l in old_tail] == ["CBOX_NAME"] + ADOPTED + ["CBOX_TPL_SHA"], \
    "old writer tail order unexpected: %r" % [key(l) for l in old_tail]
assert [key(l) for l in new_tail] == ADOPTED + ["CBOX_NAME", "CBOX_TPL_SHA"], \
    "new writer tail order unexpected: %r" % [key(l) for l in new_tail]
assert old_tail[1:7] == new_tail[0:6], \
    "the six adopted lines changed content or relative order:\nold %r\nnew %r" % (old_tail[1:7], new_tail[0:6])
assert old_tail[0] == new_tail[6], "CBOX_NAME line content changed"
assert old_tail[7] == new_tail[7], "CBOX_TPL_SHA line content changed"
PYEOF
_ok "adoption position gate: on a legacy-layout cbox.conf the six adopted lines keep byte content and relative order (shifted up one slot); the only relocation is internal CBOX_NAME dropping behind them; every whitelist write happens inside config set which re-stamps the manifest in the same transaction, so no stale-stamp drift path exists"

_run_new_whitelist_writer "$TMPBASE/pos_new.conf" "$TMPBASE/pos_new2.conf" 0 "$TMPBASE/pos_new.conf"
cmp -s "$TMPBASE/pos_new.conf" "$TMPBASE/pos_new2.conf" \
  || _fail "whitelist writer is not a fixpoint on its own output:
$(diff -u "$TMPBASE/pos_new.conf" "$TMPBASE/pos_new2.conf" || true)"
_ok "adoption fixpoint gate: rewriting an already-adopted cbox.conf is byte-identical (stable layout from the second write on)"

ROUNDTRIP_SRC="$FIXDIR/full.sh"
fixedhome="$TMPBASE/home_roundtrip"
mkdir -p "$fixedhome"
_run_new_conf_save "$ROUNDTRIP_SRC" "$TMPBASE/roundtrip1.conf" "$fixedhome"
(
  export HOME="$fixedhome"
  . "$SECTIONS_SH"
  . "$CONF_LIB"
  . "$TMPBASE/roundtrip1.conf"
  awk '/^conf_defaults\(\) \{/,/^}$/' "$NEW_SETUP" > "$TMPBASE/rt_defaults.sh"
  awk '/^conf_save\(\) \{/,/^}$/' "$NEW_SETUP" > "$TMPBASE/rt_save.sh"
  . "$TMPBASE/rt_defaults.sh"
  . "$TMPBASE/rt_save.sh"
  conf_defaults
  conf_save "$TMPBASE/roundtrip2.conf"
)
cmp -s "$TMPBASE/roundtrip1.conf" "$TMPBASE/roundtrip2.conf" \
  || _fail "load-save-load round trip lost or changed data:
$(diff -u "$TMPBASE/roundtrip1.conf" "$TMPBASE/roundtrip2.conf" || true)"
_ok "round trip: load(full fixture)+save -> load+save again is byte-identical (no loss)"

BYTELAYOUT_SRC="$FIXDIR/isolated.sh"
fixedhome2="$TMPBASE/home_bytelayout"
mkdir -p "$fixedhome2"
_run_old_conf_save "$BYTELAYOUT_SRC" "$TMPBASE/bytelayout_old.conf" "$fixedhome2"
_run_new_conf_save "$BYTELAYOUT_SRC" "$TMPBASE/bytelayout_new.conf" "$fixedhome2"
_strip_container_exec_tool_line "$TMPBASE/bytelayout_new.conf" "$TMPBASE/bytelayout_new_stripped.conf"
old_hash="$(sha256sum "$TMPBASE/bytelayout_old.conf" | awk '{print $1}')"
new_hash="$(sha256sum "$TMPBASE/bytelayout_new_stripped.conf" | awk '{print $1}')"
[ "$old_hash" = "$new_hash" ] \
  || _fail "byte layout of an isolated-project cbox.conf changed beyond the new CBOX_CONTAINER_EXEC_TOOL/CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG/CBOX_SESSION_MULTIPLEX/CBOX_WG_FORWARDS/CBOX_SESSION_BROKER_MODE/CBOX_SSHD_LISTEN_ADDR/CBOX_SSHD_PORT/CBOX_KERNEL_LANG_OUTPUT/CBOX_KERNEL_LANG_REASONING lines (this would be hashed into the manifest and would make existing isolated projects report drift): old=$old_hash new=$new_hash"
_ok "manifest-hash safety: isolated-project cbox.conf sha256 unchanged aside from the new CBOX_CONTAINER_EXEC_TOOL/CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG/CBOX_SESSION_MULTIPLEX/CBOX_WG_FORWARDS/CBOX_SESSION_BROKER_MODE/CBOX_SSHD_LISTEN_ADDR/CBOX_SSHD_PORT/CBOX_KERNEL_LANG_OUTPUT/CBOX_KERNEL_LANG_REASONING lines ($old_hash) for a realistic isolated fixture; every real bless re-stamps the manifest against the current cbox.conf in the same transaction, so this new line does not itself cause drift reports on upgrade"

echo "PASS: all conf_writer parity tests"
