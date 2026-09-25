#!/usr/bin/env bash
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"
MERGE_SRC="$REPO_ROOT/etc/claude/settings.merge.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

[ -f "$MERGE_SRC" ] || _fail "merge source not found at $MERGE_SRC"

source <(sed -n '/^merge_settings_json() {/,/^}/p' "$DIR/cbox-setup.sh")
type merge_settings_json >/dev/null 2>&1 \
  || _fail "could not extract merge_settings_json from cbox-setup.sh"

BARE="python3 /h/.claude/hooks/continuity_session_start.py"

merge_settings_json "$WORK/a_target.json" "$MERGE_SRC" /h "$WORK/a_out.json" \
  || _fail "case a: merge_settings_json exited non-zero on a fresh target"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
cmds = [h["command"] for e in d["hooks"]["SessionStart"] for h in e.get("hooks", [])]
bare = "python3 /h/.claude/hooks/continuity_session_start.py"
expected = [bare + " --section " + s for s in ["core", "memory", "ledger", "progress"]]
sys.exit(0 if cmds == expected else 1)
' "$WORK/a_out.json" \
  || _fail "case a: fresh-merge SessionStart is not exactly the four section commands in order"
_ok "case a: fresh target (no existing file) -> SessionStart is exactly the four section commands in order, nothing else"

printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"'"$BARE"'"},{"type":"command","command":"python3 /h/user_own_hook.py"}]}]}}' > "$WORK/b_target.json"
merge_settings_json "$WORK/b_target.json" "$MERGE_SRC" /h "$WORK/b_out.json" \
  || _fail "case b: merge_settings_json exited non-zero on the upgrade target"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
cmds = [h["command"] for e in d["hooks"]["SessionStart"] for h in e.get("hooks", [])]
bare = "python3 /h/.claude/hooks/continuity_session_start.py"
sections = [bare + " --section " + s for s in ["core", "memory", "ledger", "progress"]]
ok = bare not in cmds
ok = ok and "python3 /h/user_own_hook.py" in cmds
ok = ok and all(cmds.count(s) == 1 for s in sections)
sys.exit(0 if ok else 1)
' "$WORK/b_out.json" \
  || _fail "case b: upgrade merge kept the bare command, dropped the user hook, or did not land all four section commands exactly once"
_ok "case b: upgrade target -> bare command removed, user own hook kept, all four section commands present exactly once"

printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"compact","hooks":[{"type":"command","command":"'"$BARE"'"}]}]}}' > "$WORK/c_target.json"
merge_settings_json "$WORK/c_target.json" "$MERGE_SRC" /h "$WORK/c_out.json" \
  || _fail "case c: merge_settings_json exited non-zero on the compact target"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
entries = d["hooks"]["SessionStart"]
ok = all(len(e.get("hooks", [])) > 0 for e in entries)
ok = ok and all(e.get("matcher") != "compact" for e in entries)
cmds = [h["command"] for e in entries for h in e.get("hooks", [])]
bare = "python3 /h/.claude/hooks/continuity_session_start.py"
sections = [bare + " --section " + s for s in ["core", "memory", "ledger", "progress"]]
ok = ok and bare not in cmds and all(s in cmds for s in sections)
sys.exit(0 if ok else 1)
' "$WORK/c_out.json" \
  || _fail "case c: compact-only entry survived as an empty-hooks entry, or the section commands are missing"
_ok "case c: target whose only SessionStart entry is the bare-compact hook -> entry removed entirely (no empty-hooks survivor), sections merged in"

merge_settings_json "$WORK/b_out.json" "$MERGE_SRC" /h "$WORK/d_out.json" \
  || _fail "case d: merge_settings_json exited non-zero re-merging the case b output"
cmp -s "$WORK/b_out.json" "$WORK/d_out.json" \
  || _fail "case d: re-merging the case b output changed the file (not idempotent)"
_ok "case d: merging the case b output over itself is byte-identical (cmp clean)"

printf '%s\n' '{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}' > "$WORK/e_target.json"
merge_settings_json "$WORK/e_target.json" "$MERGE_SRC" /h "$WORK/e_out.json" \
  || _fail "case e: merge_settings_json exited non-zero on the unrelated-keys target"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
ok = d.get("model") == "x"
stop = d["hooks"].get("Stop")
ok = ok and stop == [{"hooks": [{"type": "command", "command": "echo hi"}]}]
cmds = [h["command"] for e in d["hooks"]["SessionStart"] for h in e.get("hooks", [])]
bare = "python3 /h/.claude/hooks/continuity_session_start.py"
sections = [bare + " --section " + s for s in ["core", "memory", "ledger", "progress"]]
ok = ok and all(s in cmds for s in sections)
sys.exit(0 if ok else 1)
' "$WORK/e_out.json" \
  || _fail "case e: unrelated model key or Stop hook was clobbered by the merge"
_ok "case e: unrelated model key and Stop hook survive the merge unchanged, sections still merged in"

printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"python3 /h/g.py --section a"}]}]}}' > "$WORK/f_merge.json"
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"python3 /h/g.py"}]},{"matcher":"Edit","hooks":[{"type":"command","command":"python3 /h/g.py"}]}]}}' > "$WORK/f_target.json"
merge_settings_json "$WORK/f_target.json" "$WORK/f_merge.json" /h "$WORK/f_out.json" \
  || _fail "case f: merge_settings_json exited non-zero on the pretooluse target"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
entries = d["hooks"]["PreToolUse"]
by_matcher = {}
for e in entries:
    by_matcher.setdefault(e.get("matcher"), []).extend(h.get("command") or "" for h in e.get("hooks", []))
bash_cmds = by_matcher.get("Bash", [])
edit_cmds = by_matcher.get("Edit", [])
ok = "python3 /h/g.py" in bash_cmds
ok = ok and "python3 /h/g.py --section a" in edit_cmds
ok = ok and "python3 /h/g.py" not in edit_cmds
sys.exit(0 if ok else 1)
' "$WORK/f_out.json" \
  || _fail "case f: Bash entry lost the bare command, Edit entry missing --section a, or Edit entry still has the bare command"
_ok "case f: sectioned command supersedes the bare one in its own matcher only - Bash keeps python3 /h/g.py, Edit has --section a and no bare command"

printf '%s\n' '{"hooks":{"SessionStart":["junk",{"hooks":[{"type":"command","command":"'"$BARE"'"}]}]}}' > "$WORK/g_target.json"
merge_settings_json "$WORK/g_target.json" "$MERGE_SRC" /h "$WORK/g_out.json" \
  || _fail "case g: merge_settings_json exited non-zero on the non-dict target"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
cmds = [h.get("command") for e in d["hooks"]["SessionStart"] if isinstance(e, dict) for h in e.get("hooks", [])]
bare = "python3 /h/.claude/hooks/continuity_session_start.py"
ok = bare not in cmds
sys.exit(0 if ok else 1)
' "$WORK/g_out.json" \
  || _fail "case g: the bare continuity command survived a merge over a list with a non-dict element"
_ok "case g: SessionStart list containing a non-dict element -> merge exits 0 and the bare command is replaced by section commands"
