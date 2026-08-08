#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$INSTALL_DIR/etc/hooks/code_hygiene_guard.py"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() { echo "FAIL: $1" >&2; exit 1; }
_ok() { echo "ok: $1"; }

[ -f "$HOOK" ] || _fail "code_hygiene_guard.py not found"
python3 -c "import py_compile; py_compile.compile('$HOOK', doraise=True)" || _fail "hook does not py_compile"
_ok "code_hygiene_guard.py py_compiles"

_decision() {
  python3 "$HOOK" <<PYIN 2>/dev/null | python3 -c 'import json,sys
raw=sys.stdin.read().strip()
if not raw:
    print("allow"); sys.exit(0)
d=json.loads(raw)
print(d.get("hookSpecificOutput",{}).get("permissionDecision","allow"))'
$1
PYIN
}

EMDASH="$(printf '\xe2\x80\x94')"

r="$(_decision "$(python3 -c 'import json; print(json.dumps({"tool_name":"Write","tool_input":{"file_path":"/x/f.py","content":"x = 1  '"$EMDASH"' note"}}))')")"
[ "$r" = deny ] || _fail "non-ASCII in a .py file must be denied, got $r"
_ok "non-ASCII denied in code (.py)"

r="$(_decision "$(python3 -c 'import json; print(json.dumps({"tool_name":"Write","tool_input":{"file_path":"/x/doc.md","content":"heading '"$EMDASH"' dash"}}))')")"
[ "$r" = deny ] || _fail "non-ASCII in a .md doc must now be denied (the reported bug), got $r"
_ok "non-ASCII denied in docs (.md) - closes the doc ASCII gap"

r="$(_decision '{"tool_name":"Write","tool_input":{"file_path":"/x/k.txt","content":"kernel '"$EMDASH"' rule"}}')"
[ "$r" = deny ] || _fail "non-ASCII in a .txt file must be denied, got $r"
_ok "non-ASCII denied in .txt"

r="$(_decision '{"tool_name":"Write","tool_input":{"file_path":"/x/doc.md","content":"# A Markdown Heading"}}')"
[ "$r" = allow ] || _fail "a markdown heading (# ...) in a .md file must be allowed, not treated as a code comment, got $r"
_ok "markdown heading in .md is allowed (not a code-comment deny)"

r="$(_decision '{"tool_name":"Write","tool_input":{"file_path":"/x/f.py","content":"# a python comment"}}')"
[ "$r" = deny ] || _fail "a code comment in a .py file must still be denied, got $r"
_ok "code comment still denied in .py"

r="$(_decision '{"tool_name":"Write","tool_input":{"file_path":"/x/plain.log","content":"anything '"$EMDASH"' here"}}')"
[ "$r" = allow ] || _fail "a non-text extension (.log) must be ignored, got $r"
_ok "non-text extensions are ignored (only code + docs are checked)"

echo "PASS: all code hygiene guard checks"
