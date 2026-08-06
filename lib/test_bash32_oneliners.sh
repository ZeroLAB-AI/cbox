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

. "$INSTALL_DIR/lib/portable.sh"

_array_eq() {
  local a_name="$1" b_name="$2"
  local a_len_var="${a_name}[@]" b_len_var="${b_name}[@]"
  local -a a=("${!a_len_var}") b=("${!b_len_var}")
  [ "${#a[@]}" = "${#b[@]}" ] || return 1
  local i
  for ((i = 0; i < ${#a[@]}; i++)); do
    [ "${a[$i]}" = "${b[$i]}" ] || return 1
  done
  return 0
}

if (mapfile -t _cbox_test_mf_probe < /dev/null) 2>/dev/null; then
  MAPFILE_AVAILABLE=1
else
  MAPFILE_AVAILABLE=0
fi

_gen_empty() { :; }
_gen_one() { printf '%s\n' "hello"; }
_gen_multi() { printf '%s\n' "a" "b" "c"; }
_gen_spaces() { printf '%s\n' "has space" "  leading" "trailing  "; }
_gen_no_trailing_nl() { printf 'a\nb\nc'; }

if [ "$MAPFILE_AVAILABLE" = 1 ]; then
  for case_name in empty one multi spaces no_trailing_nl; do
    gen="_gen_${case_name}"
    old=()
    mapfile -t old < <("$gen")
    new=()
    _cbox_readarray new < <("$gen")
    if _array_eq old new; then
      _ok "mapfile/$case_name: _cbox_readarray matches mapfile -t (count=${#old[@]})"
    else
      _fail "mapfile/$case_name: mismatch old=(${old[*]-}) new=(${new[*]-})"
    fi
  done

  old_off=(claude)
  mapfile -t -O "${#old_off[@]}" old_off < <(_gen_multi)
  new_off=(claude)
  _cbox_readarray new_off < <(_gen_multi)
  if _array_eq old_off new_off; then
    _ok "mapfile/offset_append: _cbox_readarray onto a pre-seeded array matches mapfile -t -O"
  else
    _fail "mapfile/offset_append: mismatch old=(${old_off[*]}) new=(${new_off[*]})"
  fi
else
  echo "SKIP: mapfile not available in this bash - the mapfile oracle needs it as counterparty, this run proves nothing about mapfile parity"
fi

_up_old() {
  local u="$1"
  if [ "$MAPFILE_AVAILABLE" = 1 ]; then
    printf '%s' "${u^}"
  fi
}

_up_new() {
  local u="$1" first rest
  first="$(printf '%s' "$u" | cut -c1 | tr '[:lower:]' '[:upper:]')"
  rest="${u#?}"
  printf '%s' "${first}${rest}"
}

if [ "$MAPFILE_AVAILABLE" = 1 ]; then
  for input in marek Marek MAREK m M "" 1abc abc123 under_score "with space name"; do
    o="$(_up_old "$input")"
    n="$(_up_new "$input")"
    if [ "$o" = "$n" ]; then
      _ok "caret_expansion/[$input]: matches \${var^} -> [$o]"
    else
      _fail "caret_expansion/[$input]: mismatch old=[$o] new=[$n]"
    fi
  done
else
  echo "SKIP: this bash lacks \${var^} caret expansion - the caret oracle needs it as counterparty, this run proves nothing about caret parity"
fi

if command -v sed >/dev/null 2>&1; then
  _old_strip() {
    local conf="$1" tmp v
    tmp="$(mktemp "$(dirname "$conf")/.cbox.old.XXXXXX")"
    cp "$conf" "$tmp"
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      sed -i "/^${v}=/d" "$tmp"
    done < <(printf '%s\n' "FOO" "BAR")
    chmod 0644 "$tmp"
    cat "$tmp"
    rm -f "$tmp"
  }

  _new_strip() {
    local conf="$1" tmp tmp2 v
    tmp="$(mktemp "$(dirname "$conf")/.cbox.new.XXXXXX")"
    cp "$conf" "$tmp"
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      tmp2="$(mktemp "$(dirname "$tmp")/.cbox.new2.XXXXXX")"
      sed "/^${v}=/d" "$tmp" > "$tmp2"
      mv "$tmp2" "$tmp"
    done < <(printf '%s\n' "FOO" "BAR")
    chmod 0644 "$tmp"
    cat "$tmp"
    rm -f "$tmp"
  }

  printf 'FOO=1\nBAZ=2\nBAR=3\nQUX=4\n' > "$TMPBASE/conf_full_a"
  printf 'FOO=1\nBAZ=2\nBAR=3\nQUX=4\n' > "$TMPBASE/conf_full_b"
  o="$(_old_strip "$TMPBASE/conf_full_a")"
  n="$(_new_strip "$TMPBASE/conf_full_b")"
  [ "$o" = "$n" ] && _ok "sed_i/multi_line: portable strip matches sed -i (result: $(printf '%s' "$o" | tr '\n' '|'))" \
    || _fail "sed_i/multi_line: mismatch old=[$o] new=[$n]"

  : > "$TMPBASE/conf_empty_a"
  : > "$TMPBASE/conf_empty_b"
  o="$(_old_strip "$TMPBASE/conf_empty_a")"
  n="$(_new_strip "$TMPBASE/conf_empty_b")"
  [ "$o" = "$n" ] && _ok "sed_i/empty: portable strip matches sed -i on empty file" \
    || _fail "sed_i/empty: mismatch old=[$o] new=[$n]"

  printf 'NOMATCH=1\n' > "$TMPBASE/conf_nomatch_a"
  printf 'NOMATCH=1\n' > "$TMPBASE/conf_nomatch_b"
  o="$(_old_strip "$TMPBASE/conf_nomatch_a")"
  n="$(_new_strip "$TMPBASE/conf_nomatch_b")"
  [ "$o" = "$n" ] && _ok "sed_i/no_match: portable strip matches sed -i when no line matches" \
    || _fail "sed_i/no_match: mismatch old=[$o] new=[$n]"
else
  echo "SKIP: sed not found on PATH - the sed_i oracle needs it as counterparty, this run proves nothing about sed_i parity"
fi

if command -v xargs >/dev/null 2>&1; then
  _xargs_old_rc() {
    local input="$1"
    printf '%s' "$input" | xargs -r true
    echo $?
  }
  _xargs_new_rc() {
    local input="$1" ids
    ids="$(printf '%s' "$input")"
    local rc=0
    if [ -n "$ids" ]; then
      printf '%s' "$ids" | xargs true
      rc=$?
    fi
    echo "$rc"
  }

  o="$(_xargs_old_rc "")"
  n="$(_xargs_new_rc "")"
  [ "$o" = "$n" ] && _ok "xargs_r/empty: guarded pipeline matches xargs -r exit code ($o), and the command does not run" \
    || _fail "xargs_r/empty: exit code mismatch old=$o new=$n"

  o="$(_xargs_old_rc "abc123"$'\n')"
  n="$(_xargs_new_rc "abc123"$'\n')"
  [ "$o" = "$n" ] && _ok "xargs_r/single_line: guarded pipeline matches xargs -r exit code ($o)" \
    || _fail "xargs_r/single_line: exit code mismatch old=$o new=$n"

  o="$(_xargs_old_rc "abc"$'\n'"def"$'\n')"
  n="$(_xargs_new_rc "abc"$'\n'"def"$'\n')"
  [ "$o" = "$n" ] && _ok "xargs_r/multi_line: guarded pipeline matches xargs -r exit code ($o)" \
    || _fail "xargs_r/multi_line: exit code mismatch old=$o new=$n"

  _xargs_old_output() {
    local input="$1"
    printf '%s' "$input" | xargs -r echo MARK
  }
  _xargs_new_output() {
    local input="$1" ids
    ids="$(printf '%s' "$input")"
    if [ -n "$ids" ]; then
      printf '%s' "$ids" | xargs echo MARK
    fi
  }
  o="$(_xargs_old_output "abc"$'\n'"def"$'\n')"
  n="$(_xargs_new_output "abc"$'\n'"def"$'\n')"
  [ "$o" = "$n" ] && _ok "xargs_r/output: guarded pipeline matches xargs -r output on nonempty input ([$o])" \
    || _fail "xargs_r/output: output mismatch old=[$o] new=[$n]"

  o="$(_xargs_old_output "")"
  n="$(_xargs_new_output "")"
  [ "$o" = "$n" ] && _ok "xargs_r/output_empty: guarded pipeline matches xargs -r output on empty input (both empty)" \
    || _fail "xargs_r/output_empty: output mismatch old=[$o] new=[$n]"
else
  echo "SKIP: xargs not found on PATH - the xargs_r oracle needs it as counterparty, this run proves nothing about xargs_r parity"
fi

DENYLIST_PY="$INSTALL_DIR/lib/portability_denylist.py"
if [ -f "$DENYLIST_PY" ]; then
  hits="$(python3 - "$DENYLIST_PY" "$INSTALL_DIR" << 'PYEOF'
import importlib.util
import sys

denylist_path, install_dir = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("portability_denylist", denylist_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

targets = {
    "lib/cbox-ai.sh": {"mapfile"},
    "setup.sh": {"mapfile", "caret_expansion", "sed_i"},
    "templates/generators.sh": {"caret_expansion"},
    "cbox": {"xargs_r"},
}
problems = []
for rel, forbidden in targets.items():
    hits = mod.count_file(rel)
    for name in forbidden:
        if hits.get(name, 0) != 0:
            problems.append("%s still has %d %s occurrence(s)" % (rel, hits[name], name))
print("\n".join(problems))
PYEOF
)"
  if [ -n "$hits" ]; then
    _fail "converted sites still trip the denylist:\n$hits"
  fi
  _ok "denylist: mapfile/caret_expansion/sed_i/xargs_r are gone from the converted sites (cbox, setup.sh, lib/cbox-ai.sh, templates/generators.sh)"
else
  echo "SKIP: lib/portability_denylist.py not found"
fi

echo "PASS: bash-3.2 one-liner conversions (mapfile, caret_expansion, sed_i, xargs_r)"
