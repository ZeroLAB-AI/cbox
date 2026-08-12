#!/usr/bin/env python3
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import settings_registry as reg

SHADOW_VARS = (
    "CBOX_TPL_SHA",
)

LEGACY_WRITE_ORDER = (
    "CBOX_NAME",
    "CBOX_WORKDIR",
    "CBOX_CLAUDE_MODE",
    "CBOX_CLAUDE_PATH",
    "CBOX_CLAUDE_BACKUP",
    "CBOX_CODEX_MODE",
    "CBOX_CODEX_PATH",
    "CBOX_CODEX_BACKUP",
    "CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG",
    "CBOX_WORKSPACES",
    "CBOX_VENV_MODE",
    "CBOX_VENV_PATH",
    "CBOX_GPU",
    "CBOX_EGRESS_MODE",
    "CBOX_EGRESS_APPLIED",
    "CBOX_NETACCESS_MODE",
    "CBOX_NETACCESS_APPLIED",
    "CBOX_NETACCESS_SCOPE",
    "CBOX_NETACCESS_NETWORKS",
    "CBOX_NETACCESS_CIDRS",
    "CBOX_NETACCESS_SOCKS_PORT",
    "CBOX_NETACCESS_EXEC_MODE",
    "CBOX_NETACCESS_EXEC_WORKSPACE_GUARD",
    "CBOX_NETACCESS_EXEC_TIMEOUT",
    "CBOX_NETACCESS_EXEC_MAX_BYTES",
    "CBOX_CONTAINER_EXEC_TOOL",
    "CBOX_HOST_ROUTE_MODE",
    "CBOX_HOST_ROUTE_APPLIED",
    "CBOX_HOST_PROXY_URL",
    "CBOX_HOST_PROXY_ADDR_MODE",
    "CBOX_HOST_GATEWAY_ALIAS",
    "CBOX_SSH_MODE",
    "CBOX_SSH_AGENT_DIR",
    "CBOX_BASHRC",
    "CBOX_BASHRC_COMMANDS",
    "CBOX_MCP_SERVERS",
    "CBOX_CODEX_PROGRESS_MODE",
    "CBOX_LOCAL_MODEL",
    "CBOX_LOCAL_MODEL_URL",
    "CBOX_LOCAL_MODEL_NAME",
    "CBOX_HERMES",
    "CBOX_HERMES_VERSION",
    "CBOX_HERMES_PROVIDER",
    "CBOX_HERMES_MODEL_URL",
    "CBOX_HERMES_MODEL_NAME",
    "CBOX_HERMES_HOOKS",
    "CBOX_HERMES_DELEGATE",
    "CBOX_HERMES_DELEGATE_PROVIDER",
    "CBOX_HERMES_DELEGATE_BASE_URL",
    "CBOX_HERMES_DELEGATE_MODEL",
    "CBOX_HERMES_DELEGATE_MAX_CONCURRENCY",
    "CBOX_HERMES_DELEGATE_QUEUE_WAIT_SEC",
    "CBOX_HERMES_DELEGATE_LOCK_DIR",
    "OLLAMA_NUM_PARALLEL",
    "CBOX_HERMES_DELEGATE_MODE",
    "CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS",
    "CBOX_OLLAMA_MODE",
    "CBOX_OLLAMA_IMAGE",
    "CBOX_OLLAMA_GPU",
    "CBOX_OLLAMA_STORE",
    "CBOX_OLLAMA_STORE_PATH",
    "CBOX_OLLAMA_PORT",
    "CBOX_OLLAMA_NUM_PARALLEL",
    "CBOX_WG_MODE",
    "CBOX_WG_IMPL",
    "CBOX_WG_ADDRESS",
    "CBOX_WG_LISTEN_PORT",
    "CBOX_WG_PUBLISH_ADDR",
    "CBOX_WG_PEER_ENDPOINT",
    "CBOX_WG_PEER_PUBKEY",
    "CBOX_WG_PEER_ADDRESS",
    "CBOX_WG_KEEPALIVE",
    "CBOX_WG_FORWARDS",
    "CBOX_LIMIT_AUTORESUME",
    "CBOX_SESSION_MULTIPLEX",
    "CBOX_SAFEGUARD_AUTOCONFIRM",
    "CBOX_SESSION_BROKER_MODE",
    "CBOX_SSHD_LISTEN_ADDR",
    "CBOX_SSHD_PORT",
    "CBOX_LIMIT_RESUME_DELAY",
    "CBOX_LIMIT_RESUME_PROMPT",
    "CBOX_LIMIT_RESUME_STAGGER",
    "CBOX_LIMIT_RESUME_MAX_PER_DAY",
    "CBOX_AGENTS",
    "CBOX_CODEX_MCP",
    "CBOX_CODEX_HOOKS",
    "CBOX_GITCONFIG",
    "CBOX_APT_EXTRA",
    "CBOX_CLAUDE_TARGET",
    "CBOX_CODEX_VERSION",
    "CBOX_CODEX_TARGET",
    "CBOX_BINS_SCOPE",
    "CBOX_AUTOUPDATE",
    "CBOX_AUTOUPDATE_TTL_HOURS",
    "CBOX_DNS_MODE",
    "CBOX_DNS_SERVERS",
    "CBOX_DNS_STUB_IP",
    "CBOX_CLIPBOARD_MODE",
    "CBOX_RESTART_POLICY",
    "CBOX_TPL_SHA",
    "CBOX_MODE",
    "CBOX_SESSION_SCOPE",
    "CBOX_BASE_DIGEST_TTL",
    "CBOX_HISTORY",
    "CBOX_GIT",
    "CBOX_DIARY",
    "CBOX_OPEN_QUESTIONS",
    "CBOX_CONTEXT_PROFILE",
    "CBOX_KERNEL_LANG_OUTPUT",
    "CBOX_KERNEL_LANG_REASONING",
    "CBOX_USER_DIR",
)


def _sq(val):
    return "'" + val.replace("'", "'\\''") + "'"


def _default_expr(var):
    default = var["default"]
    if isinstance(default, dict):
        if default["kind"] == "literal":
            return str(default["value"])
        if default["kind"] == "resolver":
            return None
        raise ValueError("unknown default kind for %s" % var["key"])
    return str(default)


def _emit_defaults(data, lines):
    lines.append("_cbox_reg_conf_defaults() {")
    for var in reg.variables_in_section_order(data):
        key = var["key"]
        default = var["default"]
        if isinstance(default, dict) and default["kind"] == "resolver":
            name = default["name"]
            if name == "workdir_from_first_workspace":
                continue
            if name == "ssh_agent_dir_default":
                lines.append(
                    '  : "${%s:=$(_cbox_xdg_runtime_dir)/cbox-ssh}"' % key
                )
                continue
            raise ValueError("unbound resolver %s for %s" % (name, key))
        expr = _default_expr(var)
        lines.append('  : "${%s:=%s}"' % (key, expr))
    lines.append('  if [ -z "${CBOX_WORKDIR:-}" ]; then')
    lines.append('    CBOX_WORKDIR="${CBOX_WORKSPACES%% *}"')
    lines.append('    [ -n "$CBOX_WORKDIR" ] || CBOX_WORKDIR="$HOME"')
    lines.append("  fi")
    lines.append("}")


def _emit_write_whitelist(data, lines):
    lines.append("_cbox_reg_conf_write_whitelist() {")
    lines.append('  local out="$1" skip_machine="${2:-0}" preserve_from="${3:-}" tmp outdir')
    lines.append('  outdir="$(dirname "$out")"')
    lines.append('  mkdir -p "$outdir"')
    lines.append('  tmp="$(mktemp "$outdir/.cbox.XXXXXX")"')
    lines.append("  {")
    for s in reg.sections_in_order(data):
        vars_for_sec = [v for v in reg.variables_for_section(data, s["id"]) if v["role"] == "setting"]
        if not vars_for_sec:
            continue
        machine = s["scope"] == "machine"
        for var in vars_for_sec:
            key = var["key"]
            if machine:
                lines.append('    if [ "$skip_machine" != 1 ]; then')
                lines.append('      printf %s "${%s-}"' % (_sq("%s=%%q\\n" % key), key))
                lines.append("    fi")
            else:
                lines.append('    printf %s "${%s-}"' % (_sq("%s=%%q\\n" % key), key))
    lines.append('    if [ -n "$preserve_from" ]; then')
    lines.append('      _cbox_config_preserve_extra_lines "$preserve_from"')
    lines.append("    fi")
    lines.append("  } > \"$tmp\"")
    lines.append('  chmod 0644 "$tmp"')
    lines.append('  mv "$tmp" "$out"')
    lines.append("}")


def _emit_export_vars(data, lines):
    keys = [v["key"] for v in data["variables"] if v["export"]]
    lines.append("_cbox_reg_export_vars() {")
    lines.append("  export %s" % " ".join(keys))
    lines.append("}")


def _emit_write_legacy(data, lines):
    known = set(v["key"] for v in data["variables"])
    lines.append("_cbox_reg_conf_write_legacy() {")
    lines.append('  local out="${1:-$CONF_FILE}" tmp outdir')
    lines.append('  outdir="$(dirname "$out")"')
    lines.append('  mkdir -p "$outdir"')
    lines.append('  tmp="$(mktemp "$outdir/.cbox.XXXXXX")"')
    lines.append("  {")
    for key in LEGACY_WRITE_ORDER:
        if key not in known and key not in SHADOW_VARS:
            raise ValueError("legacy order references unknown var %s" % key)
        lines.append('    printf %s "$%s"' % (_sq("%s=%%q\\n" % key), key))
    lines.append("  } > \"$tmp\"")
    lines.append('  chmod 0644 "$tmp"')
    lines.append('  mv "$tmp" "$out"')
    lines.append("}")


def render(data):
    reg_keys = set(v["key"] for v in data["variables"])
    legacy_keys = set(LEGACY_WRITE_ORDER)
    missing_in_legacy = reg_keys - legacy_keys
    if missing_in_legacy:
        raise ValueError("registry vars missing from LEGACY_WRITE_ORDER: %s" % sorted(missing_in_legacy))
    extra_in_legacy = legacy_keys - reg_keys - set(SHADOW_VARS)
    if extra_in_legacy:
        raise ValueError("LEGACY_WRITE_ORDER has unknown vars: %s" % sorted(extra_in_legacy))

    lines = []
    _emit_defaults(data, lines)
    lines.append("")
    _emit_write_whitelist(data, lines)
    lines.append("")
    _emit_write_legacy(data, lines)
    lines.append("")
    _emit_export_vars(data, lines)
    return "\n".join(lines) + "\n"


def main(argv):
    if len(argv) not in (1, 2):
        print("usage: gen_conf_lib.py <registry.json> [out_path]", file=sys.stderr)
        return 2
    reg_path = argv[0]
    data = reg.load(reg_path)
    out = render(data)
    if len(argv) == 2:
        with open(argv[1], "w", encoding="utf-8") as f:
            f.write(out)
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
