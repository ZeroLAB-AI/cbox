#!/usr/bin/env python3
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import settings_registry as reg


def _sq(val):
    return "'" + val.replace("'", "'\\''") + "'"


def render(data):
    sections = reg.sections_in_order(data)
    section_ids = [s["id"] for s in sections]
    lines = []

    lines.append("SECTIONS=(%s)" % " ".join(section_ids))
    lines.append("")
    lines.append("declare -g -A SEC_TITLE SEC_DESC SEC_VARS SEC_APPLY SEC_PROFILE SEC_SCOPE SEC_DEPS SEC_DEP_TEXT SEC_DOCTOR_ROWS")
    lines.append("")

    for s in sections:
        lines.append("SEC_TITLE[%s]=%s" % (s["id"], _sq(s["title"])))
    lines.append("")

    for s in sections:
        lines.append("SEC_DESC[%s]=%s" % (s["id"], _sq(s["description"])))
    lines.append("")

    for s in sections:
        vars_for_sec = reg.variables_for_section(data, s["id"])
        keys = " ".join(v["key"] for v in vars_for_sec if v["role"] == "setting")
        lines.append("SEC_VARS[%s]=%s" % (s["id"], _sq(keys)))
    lines.append("")

    for s in sections:
        lines.append("SEC_APPLY[%s]=%s" % (s["id"], _sq(s["apply_class"])))
    lines.append("")

    for s in sections:
        lines.append("SEC_PROFILE[%s]=%s" % (s["id"], _sq(s["profile"])))
    lines.append("")

    lines.append('for _cbox_sec_scope_s in "${SECTIONS[@]}"; do')
    lines.append("  SEC_SCOPE[$_cbox_sec_scope_s]='project'")
    lines.append("done")
    lines.append("unset _cbox_sec_scope_s")
    for s in sections:
        if s["scope"] == "machine":
            lines.append("SEC_SCOPE[%s]='machine'" % s["id"])
    lines.append("")

    for s in sections:
        if not s["dependencies"]:
            continue
        tokens = ["%s:%s" % (dep["kind"], dep["reason"]) for dep in s["dependencies"]]
        lines.append("SEC_DEPS[%s]=%s" % (s["id"], _sq(" ".join(tokens))))
    lines.append("")

    dep_text = reg.dependency_text(data)
    seen_tokens = []
    for s in sections:
        for dep in s["dependencies"]:
            token = "%s:%s" % (dep["kind"], dep["reason"])
            if token not in seen_tokens:
                seen_tokens.append(token)
    for token in seen_tokens:
        lines.append("SEC_DEP_TEXT[%s]=%s" % (token, _sq(dep_text[token])))
    lines.append("")

    for s in sections:
        if s["doctor_rows"] is not None:
            lines.append("SEC_DOCTOR_ROWS[%s]=%s" % (s["id"], _sq(" ".join(s["doctor_rows"]))))
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
