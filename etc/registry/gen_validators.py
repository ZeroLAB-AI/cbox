#!/usr/bin/env python3
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import settings_registry as reg

NAMED_DISPATCH = {
    "no-validator": "_cbox_val_named_no_validator \"$val\"",
    "hermes-version": "_cbox_val_named_hermes_version \"$val\"",
    "claude-target": "_cbox_val_named_claude_target \"$val\"",
    "codex-version": "_cbox_val_named_codex_version \"$val\"",
    "ollama-image": "_cbox_val_named_ollama_image \"$val\"",
    "ollama-keep-alive": "_cbox_val_named_ollama_keep_alive \"$val\"",
    "ipv4-or-empty": "_cbox_val_named_ipv4_or_empty \"$val\"",
    "wg-peer-address-cidr": "_cbox_val_named_wg_peer_address_cidr \"$val\"",
    "wg-hostport-or-empty": "_cbox_val_named_wg_hostport_or_empty \"$val\"",
    "wg-pubkey-or-empty": "_cbox_val_named_wg_pubkey_or_empty \"$val\"",
    "path-slash-or-empty": "_cbox_val_named_path_slash_or_empty \"$val\"",
    "unvalidated-legacy-gap": "_cbox_val_named_unvalidated_legacy_gap \"$key\"",
    "ipv4-list": "_cbox_val_named_ipv4_list \"$val\"",
    "kernel-lang": "_cbox_val_named_kernel_lang \"$val\"",
    "codex-model-slug": "_cbox_val_named_codex_model_slug \"$val\"",
}


def _sq(val):
    return "'" + str(val).replace("'", "'\\''") + "'"


def _dispatch_for(var):
    type_spec = var["type"]
    kind = type_spec["kind"]
    eh = type_spec.get("escape_hatch")

    if eh == "wg-address-cidr":
        min_prefix = type_spec.get("min_prefix", 8)
        return "_cbox_val_named_wg_address_cidr \"$val\" %s" % min_prefix
    if eh is not None:
        return NAMED_DISPATCH[eh]

    if kind == "enum":
        return "_cbox_val_kind_enum \"$val\" %s" % " ".join(_sq(v) for v in type_spec["values"])
    if kind == "enum-or-empty":
        return "_cbox_val_kind_enum_or_empty \"$val\" %s" % " ".join(_sq(v) for v in type_spec["values"])
    if kind == "uint":
        return "_cbox_val_kind_uint \"$val\""
    if kind == "uint-or-empty":
        return "_cbox_val_kind_uint_or_empty \"$val\""
    if kind == "uint-min":
        return "_cbox_val_kind_uint_min \"$val\" %s" % type_spec["min"]
    if kind == "uint-range":
        return "_cbox_val_kind_uint_range \"$val\" %s %s" % (type_spec["min"], type_spec["max"])
    if kind == "port":
        return "_cbox_val_kind_port \"$val\""
    if kind == "path":
        return "_cbox_val_kind_path \"$val\""
    if kind == "path-or-empty":
        return "_cbox_val_kind_path_or_empty \"$val\""
    if kind == "url-or-empty":
        return "_cbox_val_kind_url_or_empty \"$val\""
    if kind == "string":
        return "_cbox_val_kind_string \"$val\""
    if kind == "nonempty-string":
        return "_cbox_val_kind_nonempty_string \"$val\""
    if kind == "path-list":
        return "_cbox_val_kind_path_list \"$val\""
    if kind == "network-name-list":
        return "_cbox_val_kind_network_name_list \"$val\""
    if kind == "cidr-list":
        return "_cbox_val_kind_cidr_list \"$val\" %s" % type_spec.get("min_prefix", 0)
    if kind == "wg-forward-list":
        return "_cbox_val_kind_wg_forward_list \"$val\""
    if kind == "apt-package-list":
        return "_cbox_val_kind_apt_package_list \"$val\""
    if kind == "canonical-name-list":
        return "_cbox_val_kind_canonical_name_list \"$val\""

    raise ValueError("no generic dispatch for type.kind %r (variable needs an escape_hatch)" % kind)


def render(data):
    lines = []
    lines.append("_cbox_reg_validate_var() {")
    lines.append("  local _cbox_val_had_f=0 _cbox_val_rc=0")
    lines.append("  case $- in *f*) _cbox_val_had_f=1 ;; esac")
    lines.append("  set -f")
    lines.append("  _cbox_reg_validate_var_dispatch \"$@\" || _cbox_val_rc=$?")
    lines.append("  [ \"$_cbox_val_had_f\" = 1 ] || set +f")
    lines.append("  return \"$_cbox_val_rc\"")
    lines.append("}")
    lines.append("")
    lines.append("_cbox_reg_validate_var_dispatch() {")
    lines.append("  local key=\"$1\" val=\"$2\"")
    lines.append("  _cbox_val_no_ctrl \"$val\" || { printf 'contains a control character'; return 1; }")
    lines.append("  case \"$key\" in")
    for var in data["variables"]:
        lines.append("    %s)" % var["key"])
        lines.append("      %s || return 1" % _dispatch_for(var))
        lines.append("      ;;")
    lines.append("    *)")
    lines.append("      printf 'no validator registered for %s' \"$key\"; return 1")
    lines.append("      ;;")
    lines.append("  esac")
    lines.append("  return 0")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main(argv):
    if len(argv) not in (1, 2):
        print("usage: gen_validators.py <registry.json> [out_path]", file=sys.stderr)
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
