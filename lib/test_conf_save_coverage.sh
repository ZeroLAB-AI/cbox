#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() { echo "FAIL: $*" >&2; exit 1; }
_ok() { echo "ok: $*"; }

source "$INSTALL_DIR/templates/sections.sh"

CONF_LIB="$INSTALL_DIR/templates/conf_lib.sh"
[ -f "$CONF_LIB" ] || _fail "templates/conf_lib.sh not found (registry-generated writer/defaults library)"

awk '/^_cbox_reg_conf_write_legacy\(\) \{/,/^}$/' "$CONF_LIB" > "$TMPBASE/conf_save.txt"
[ -s "$TMPBASE/conf_save.txt" ] || _fail "could not extract _cbox_reg_conf_write_legacy from templates/conf_lib.sh"

awk '/^_cbox_reg_conf_defaults\(\) \{/,/^}$/' "$CONF_LIB" > "$TMPBASE/conf_defaults.txt"
[ -s "$TMPBASE/conf_defaults.txt" ] || _fail "could not extract _cbox_reg_conf_defaults from templates/conf_lib.sh"

missing_save=""
missing_default=""
for section in "${SECTIONS[@]}"; do
  vars="$(sec_get SEC_VARS "$section")"
  [ -n "$vars" ] || continue
  for var in $vars; do
    if ! grep -q "printf '$var=%q" "$TMPBASE/conf_save.txt"; then
      missing_save="$missing_save $section/$var"
    fi
    if ! grep -qE "(\\\$\{$var:?=|^[[:space:]]*$var=)" "$TMPBASE/conf_defaults.txt"; then
      missing_default="$missing_default $section/$var"
    fi
  done
done

[ -z "$missing_save" ] || _fail "declared in SEC_VARS but never persisted by the registry-driven writer (a wizard run would silently drop the value):$missing_save"
_ok "every SEC_VARS variable is persisted by the registry-driven writer"

[ -z "$missing_default" ] || _fail "declared in SEC_VARS but never defaulted by the registry-driven defaults:$missing_default"
_ok "every SEC_VARS variable has a registry-driven defaults entry"

dupes="$(
  for section in "${SECTIONS[@]}"; do
    for var in $(sec_get SEC_VARS "$section"); do
      printf '%s %s\n' "$var" "$section"
    done
  done | sort | awk '{count[$1]++; owners[$1]=owners[$1]" "$2} END {for (v in count) if (count[v] > 1) print v ":" owners[v]}'
)"
[ -z "$dupes" ] || _fail "variable claimed by more than one section: $dupes"
_ok "no variable is owned by two sections"

unknown=""
while IFS= read -r var; do
  found=0
  for section in "${SECTIONS[@]}"; do
    case " $(sec_get SEC_VARS "$section") " in
      *" $var "*) found=1; break ;;
    esac
  done
  [ "$found" = 1 ] || unknown="$unknown $var"
done < <(grep -o "printf '[A-Za-z0-9_]*=%q" "$TMPBASE/conf_save.txt" | sed "s/printf '//; s/=%q//" | sort -u)

if [ -n "$unknown" ]; then
  echo "note: persisted by the registry-driven writer but owned by no section (invisible to the wizard and to cbox config):$unknown" >&2
fi
_ok "shadow-setting census reported"

echo "PASS: all conf_save coverage tests"
