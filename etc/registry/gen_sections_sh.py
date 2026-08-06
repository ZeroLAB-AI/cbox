#!/usr/bin/env python3
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import settings_registry as reg


def _sq(val):
    return "'" + val.replace("'", "'\\''") + "'"


def _case_block(array_name, entries):
    lines = []
    lines.append("    %s)" % array_name)
    lines.append('      case "$2" in')
    for key, value in entries:
        lines.append("        %s)" % key)
        lines.append("          printf '%%s\\n' %s" % _sq(value))
        lines.append("          ;;")
    lines.append("        *)")
    lines.append("          return 0")
    lines.append("          ;;")
    lines.append("      esac")
    lines.append("      ;;")
    return lines


def _has_block(array_name, keys):
    lines = []
    lines.append("    %s)" % array_name)
    lines.append('      case "$2" in')
    if keys:
        lines.append("        %s)" % "|".join(keys))
        lines.append("          return 0")
        lines.append("          ;;")
    lines.append("        *)")
    lines.append("          return 1")
    lines.append("          ;;")
    lines.append("      esac")
    lines.append("      ;;")
    return lines


def _keys_block(array_name, keys):
    lines = []
    lines.append("    %s)" % array_name)
    lines.append("      printf '%%s\\n' %s" % " ".join(_sq(k) for k in keys))
    lines.append("      ;;")
    return lines


def render(data):
    sections = reg.sections_in_order(data)
    section_ids = [s["id"] for s in sections]
    lines = []

    lines.append("SECTIONS=(%s)" % " ".join(section_ids))
    lines.append("")

    sec_title = [(s["id"], s["title"]) for s in sections]
    sec_desc = [(s["id"], s["description"]) for s in sections]

    sec_vars = []
    for s in sections:
        vars_for_sec = reg.variables_for_section(data, s["id"])
        keys = " ".join(v["key"] for v in vars_for_sec if v["role"] == "setting")
        sec_vars.append((s["id"], keys))

    sec_apply = [(s["id"], s["apply_class"]) for s in sections]
    sec_profile = [(s["id"], s["profile"]) for s in sections]

    sec_scope = []
    for s in sections:
        sec_scope.append((s["id"], "machine" if s["scope"] == "machine" else "project"))

    sec_deps = []
    for s in sections:
        if not s["dependencies"]:
            continue
        tokens = ["%s:%s" % (dep["kind"], dep["reason"]) for dep in s["dependencies"]]
        sec_deps.append((s["id"], " ".join(tokens)))

    dep_text = reg.dependency_text(data)
    seen_tokens = []
    for s in sections:
        for dep in s["dependencies"]:
            token = "%s:%s" % (dep["kind"], dep["reason"])
            if token not in seen_tokens:
                seen_tokens.append(token)
    sec_dep_text = [(token, dep_text[token]) for token in seen_tokens]

    sec_doctor_rows = []
    for s in sections:
        if s["doctor_rows"] is not None:
            sec_doctor_rows.append((s["id"], " ".join(s["doctor_rows"])))

    arrays = [
        ("SEC_TITLE", sec_title),
        ("SEC_DESC", sec_desc),
        ("SEC_VARS", sec_vars),
        ("SEC_APPLY", sec_apply),
        ("SEC_PROFILE", sec_profile),
        ("SEC_SCOPE", sec_scope),
        ("SEC_DEPS", sec_deps),
        ("SEC_DEP_TEXT", sec_dep_text),
        ("SEC_DOCTOR_ROWS", sec_doctor_rows),
    ]

    lines.append("sec_get() {")
    lines.append('  case "$1" in')
    for array_name, entries in arrays:
        lines.extend(_case_block(array_name, entries))
    lines.append("    *)")
    lines.append("      return 0")
    lines.append("      ;;")
    lines.append("  esac")
    lines.append("}")
    lines.append("")

    lines.append("sec_has() {")
    lines.append('  case "$1" in')
    for array_name, entries in arrays:
        keys = [k for k, _ in entries]
        lines.extend(_has_block(array_name, keys))
    lines.append("    *)")
    lines.append("      return 1")
    lines.append("      ;;")
    lines.append("  esac")
    lines.append("}")
    lines.append("")

    lines.append("sec_keys() {")
    lines.append('  case "$1" in')
    for array_name, entries in arrays:
        keys = [k for k, _ in entries]
        lines.extend(_keys_block(array_name, keys))
    lines.append("    *)")
    lines.append("      return 0")
    lines.append("      ;;")
    lines.append("  esac")
    lines.append("}")
    lines.append("")

    lines.append("DOCTOR_EXTRA_ROWS=%s" % _sq(" ".join(reg.doctor_extra_rows(data))))

    return "\n".join(lines) + "\n"


def main(argv):
    if len(argv) not in (1, 2):
        print("usage: gen_sections_sh.py <registry.json> [out_path]", file=sys.stderr)
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
