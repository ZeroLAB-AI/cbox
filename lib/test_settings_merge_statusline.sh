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

python3 -c "
import json
d = json.load(open('$MERGE_SRC'))
sl = d.get('statusLine')
assert isinstance(sl, dict), 'settings.merge.json has no statusLine block'
assert sl.get('type') == 'command'
assert 'usage_statusline.py' in sl.get('command', '')
assert sl.get('refreshInterval') == 60, sl
" || _fail "settings.merge.json statusLine block is missing or malformed"
_ok "settings.merge.json declares a command statusLine pointing at usage_statusline.py with refreshInterval 60"

source <(sed -n '/^merge_settings_json() {/,/^}/p' "$DIR/cbox-setup.sh")
type merge_settings_json >/dev/null 2>&1 \
  || _fail "could not extract merge_settings_json from cbox-setup.sh"

merge_settings_json "$WORK/fresh_target.json" "$MERGE_SRC" /h "$WORK/fresh_out.json" \
  || _fail "case fresh: merge_settings_json exited non-zero on a fresh target"
python3 -c "
import json
d = json.load(open('$WORK/fresh_out.json'))
sl = d.get('statusLine')
assert isinstance(sl, dict)
assert sl.get('command') == 'python3 /h/.claude/hooks/usage_statusline.py'
assert sl.get('refreshInterval') == 60, sl
" || _fail "case fresh: statusLine was not installed when the target had none"
_ok "case fresh: no existing statusLine -> cbox's statusLine is installed"

printf '%s\n' '{"statusLine":{"type":"command","command":"python3 /h/my_own_statusline.py"}}' \
  > "$WORK/user_target.json"
merge_settings_json "$WORK/user_target.json" "$MERGE_SRC" /h "$WORK/user_out.json" \
  || _fail "case user: merge_settings_json exited non-zero over a user-owned statusLine"
python3 -c "
import json
d = json.load(open('$WORK/user_out.json'))
sl = d.get('statusLine')
assert sl.get('command') == 'python3 /h/my_own_statusline.py', sl
" || _fail "case user: an existing user statusLine was overwritten by the merge"
_ok "case user: an existing user statusLine is left untouched by the merge"

printf '%s\n' '{"statusLine":{}}' > "$WORK/empty_target.json"
merge_settings_json "$WORK/empty_target.json" "$MERGE_SRC" /h "$WORK/empty_out.json" \
  || _fail "case empty: merge_settings_json exited non-zero over an empty statusLine block"
python3 -c "
import json
d = json.load(open('$WORK/empty_out.json'))
sl = d.get('statusLine')
assert sl.get('command') == 'python3 /h/.claude/hooks/usage_statusline.py', sl
" || _fail "case empty: an empty (falsy) existing statusLine block was not treated as absent"
_ok "case empty: an empty existing statusLine block is treated as absent and filled in"

printf '%s\n' '{"statusLine":{"type":"command","command":"python3 /h/.claude/hooks/usage_statusline.py"}}' \
  > "$WORK/legacy_target.json"
merge_settings_json "$WORK/legacy_target.json" "$MERGE_SRC" /h "$WORK/legacy_out.json" \
  || _fail "case legacy: merge_settings_json exited non-zero over an older cbox statusLine"
python3 -c "
import json
d = json.load(open('$WORK/legacy_out.json'))
sl = d.get('statusLine')
assert sl.get('command') == 'python3 /h/.claude/hooks/usage_statusline.py', sl
assert sl.get('refreshInterval') == 60, sl
" || _fail "case legacy: an older cbox statusLine did not gain refreshInterval"
_ok "case legacy: an older cbox statusLine without refreshInterval gains it"

printf '%s\n' '{"statusLine":{"type":"command","command":"python3 /h/.claude/hooks/usage_statusline.py","refreshInterval":15}}' \
  > "$WORK/tuned_target.json"
merge_settings_json "$WORK/tuned_target.json" "$MERGE_SRC" /h "$WORK/tuned_out.json" \
  || _fail "case tuned: merge_settings_json exited non-zero over a tuned cbox statusLine"
python3 -c "
import json
d = json.load(open('$WORK/tuned_out.json'))
assert d['statusLine'].get('refreshInterval') == 15, d['statusLine']
" || _fail "case tuned: a user-set refreshInterval was overwritten"
_ok "case tuned: a user-set refreshInterval is kept"

printf '%s\n' '{"statusLine":{"type":"command","command":"python3 /h/my_own_statusline.py"}}' \
  > "$WORK/user_target2.json"
merge_settings_json "$WORK/user_target2.json" "$MERGE_SRC" /h "$WORK/user_out2.json" \
  || _fail "case user2: merge_settings_json failed"
python3 -c "
import json
d = json.load(open('$WORK/user_out2.json'))
assert 'refreshInterval' not in d['statusLine'], d['statusLine']
" || _fail "case user2: refreshInterval leaked into a user-owned statusLine"
_ok "case user2: a user-owned statusLine gains no refreshInterval"

echo "PASS: settings merge statusLine only-when-absent rule"
