_cbox_val_no_ctrl() {
  local val="$1" c i
  case "$val" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  for ((i = 0; i < ${#val}; i++)); do
    c="${val:i:1}"
    case "$c" in
      $'\x00'|$'\x01'|$'\x02'|$'\x03'|$'\x04'|$'\x05'|$'\x06'|$'\x07'|$'\x08'|\
      $'\x0b'|$'\x0c'|$'\x0e'|$'\x0f'|$'\x10'|$'\x11'|$'\x12'|$'\x13'|$'\x14'|\
      $'\x15'|$'\x16'|$'\x17'|$'\x18'|$'\x19'|$'\x1a'|$'\x1b'|$'\x1c'|$'\x1d'|\
      $'\x1e'|$'\x1f')
        return 1
        ;;
    esac
  done
  return 0
}

_cbox_val_enum() {
  local val="$1"; shift
  local a
  for a in "$@"; do
    [ "$val" = "$a" ] && return 0
  done
  return 1
}

_cbox_val_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

_cbox_val_path() {
  case "$1" in
    ''|*[!\ -~]*) return 1 ;;
    *' '*) return 1 ;;
    /*) return 0 ;;
    '~'|'~/'*) return 0 ;;
  esac
  return 1
}

_cbox_val_url() {
  case "$1" in
    http://*|https://*) return 0 ;;
  esac
  return 1
}

_cbox_val_kind_enum() {
  local val="$1"; shift
  _cbox_val_enum "$val" "$@" || { printf 'expected one of: %s' "$*"; return 1; }
}

_cbox_val_kind_enum_or_empty() {
  local val="$1"; shift
  [ -z "$val" ] || _cbox_val_enum "$val" "$@" || { printf 'expected one of: %s (or empty)' "$*"; return 1; }
}

_cbox_val_kind_uint() {
  local val="$1"
  _cbox_val_uint "$val" || { printf 'expected a non-negative integer'; return 1; }
}

_cbox_val_kind_uint_or_empty() {
  local val="$1"
  [ -z "$val" ] || _cbox_val_uint "$val" || { printf 'expected a non-negative integer (or empty)'; return 1; }
}

_cbox_val_kind_uint_min() {
  local val="$1" min="$2"
  _cbox_val_uint "$val" || { printf 'expected a non-negative integer'; return 1; }
  [ "$val" -ge "$min" ] || { printf 'expected an integer of at least %s' "$min"; return 1; }
}

_cbox_val_kind_uint_range() {
  local val="$1" min="$2" max="$3"
  _cbox_val_uint "$val" || { printf 'expected a non-negative integer'; return 1; }
  { [ "$val" -ge "$min" ] && [ "$val" -le "$max" ]; } || { printf 'expected integer %s..%s' "$min" "$max"; return 1; }
}

_cbox_val_kind_port() {
  local val="$1"
  _cbox_val_uint "$val" || { printf 'expected a non-negative integer (port)'; return 1; }
  { [ "$val" -ge 1 ] && [ "$val" -le 65535 ]; } || { printf 'expected port 1..65535'; return 1; }
}

_cbox_val_kind_path() {
  local val="$1"
  _cbox_val_path "$val" || { printf 'expected an absolute path'; return 1; }
}

_cbox_val_kind_path_or_empty() {
  local val="$1"
  [ -z "$val" ] || _cbox_val_path "$val" || { printf 'expected an absolute path (or empty)'; return 1; }
}

_cbox_val_kind_url_or_empty() {
  local val="$1"
  [ -z "$val" ] || _cbox_val_url "$val" || { printf 'expected an http(s):// URL (or empty)'; return 1; }
}

_cbox_val_kind_nonempty_string() {
  local val="$1"
  [ -n "$val" ] || { printf 'must not be empty'; return 1; }
}

_cbox_val_kind_string() {
  return 0
}

_cbox_val_path_list_expand() {
  case "$1" in
    '~') printf '%s' "${HOME:-}" ;;
    '~/'*) printf '%s/%s' "${HOME:-}" "${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

_cbox_val_path_list_protected() {
  local w="$1" p
  while [ "${w%/}" != "$w" ] && [ -n "${w%/}" ]; do w="${w%/}"; done
  [ "$w" = "/" ] && return 0
  for p in "${INSTALL_DIR:-}" "${HOME:-}/.config/cbox"; do
    [ -n "$p" ] || continue
    while [ "${p%/}" != "$p" ] && [ -n "${p%/}" ]; do p="${p%/}"; done
    case "$w" in
      "$p")
        return 0
        ;;
      "$p"/*)
        return 0
        ;;
    esac
    case "$p" in
      "$w"/*)
        return 0
        ;;
    esac
  done
  return 1
}

_cbox_val_kind_path_list() {
  local val="$1" w x
  for w in $val; do
    _cbox_val_path "$w" || { printf 'workspace entries must be absolute paths: %s' "$w"; return 1; }
    x="$(_cbox_val_path_list_expand "$w")"
    _cbox_val_path_list_protected "$x" && { printf 'workspace entries must not be or contain the cbox install/config tree: %s' "$w"; return 1; }
  done
  return 0
}

_cbox_val_kind_network_name_list() {
  local val="$1" n
  for n in $val; do
    case "$n" in
      [A-Za-z0-9]*) ;;
      *) printf 'invalid network name: %s' "$n"; return 1 ;;
    esac
    case "$n" in
      *[!A-Za-z0-9_.-]*) printf 'invalid network name: %s' "$n"; return 1 ;;
    esac
  done
  return 0
}

_cbox_val_kind_cidr_list() {
  local val="$1" min_prefix="${2:-0}" c
  command -v _cbox_is_ipv4_cidr >/dev/null 2>&1 || . "$INSTALL_DIR/templates/generators.sh"
  for c in $val; do
    if ! _cbox_is_ipv4_cidr "$c" || [ "${c%/*}" = "0.0.0.0" ]; then
      printf 'invalid IPv4 CIDR: %s' "$c"; return 1
    fi
    if [ "${c#*/}" -lt "$min_prefix" ]; then
      printf 'prefix too broad (minimum /%s): %s' "$min_prefix" "$c"; return 1
    fi
  done
  return 0
}

_cbox_val_kind_apt_package_list() {
  local val="$1" p
  for p in $val; do
    case "$p" in
      *[!A-Za-z0-9.+-]*|[.+-]*) printf 'invalid package name: %s' "$p"; return 1 ;;
    esac
  done
  return 0
}

_cbox_val_kind_canonical_name_list() {
  return 0
}

_cbox_val_named_no_validator() {
  return 0
}

_cbox_val_named_hermes_version() {
  local val="$1"
  [ "$val" = latest ] || printf '%s' "$val" | grep -Eq '^[0-9]+([.][0-9]+){1,3}$' \
    || { printf 'expected latest or a plain x.y[.z[.w]] version'; return 1; }
}

_cbox_val_named_claude_target() {
  local val="$1"
  printf '%s' "$val" | grep -Eq '^(stable|latest|[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?)$' || { printf 'expected stable, latest, or x.y.z'; return 1; }
}

_cbox_val_named_codex_version() {
  local val="$1"
  printf '%s' "$val" | grep -Eq '^(latest|[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta)(\.[0-9]+)?)?)$' || { printf 'expected latest or x.y.z'; return 1; }
}

_cbox_val_named_ollama_image() {
  local val="$1"
  [ -n "$val" ] || { printf 'must not be empty'; return 1; }
  printf '%s' "$val" | grep -Eq '^[A-Za-z0-9._:/@-]+$' || { printf 'expected an image reference matching [A-Za-z0-9._:/@-]+'; return 1; }
}

_cbox_val_named_wg_address_cidr() {
  local val="$1" min_prefix="${2:-8}"
  command -v _cbox_is_ipv4_cidr >/dev/null 2>&1 || . "$INSTALL_DIR/templates/generators.sh"
  [ -z "$val" ] || _cbox_is_ipv4_cidr "$val" || { printf 'expected an IPv4 address with a prefix length (e.g. 10.90.0.1/24), or empty'; return 1; }
  [ -z "$val" ] || [ "${val#*/}" -ge "$min_prefix" ] || { printf 'expected a prefix length of /%s or narrower - a wider prefix would install a broad or default route on the tunnel interface' "$min_prefix"; return 1; }
}

_cbox_val_named_wg_peer_address_cidr() {
  local val="$1"
  command -v _cbox_is_ipv4_cidr >/dev/null 2>&1 || . "$INSTALL_DIR/templates/generators.sh"
  [ -z "$val" ] || _cbox_is_ipv4_cidr "$val" || { printf 'expected an IPv4 address with a prefix length, or empty'; return 1; }
  [ -z "$val" ] || [ "${val#*/}" -eq 32 ] || { printf 'expected a single host address (/32) - a wider AllowedIPs would route more than the remote endpoint over the tunnel'; return 1; }
}

_cbox_val_named_wg_hostport_or_empty() {
  local val="$1"
  command -v _cbox_wg_hostport_ok >/dev/null 2>&1 || . "$INSTALL_DIR/templates/generators.sh"
  [ -z "$val" ] || _cbox_wg_hostport_ok "$val" || { printf 'expected host:port'; return 1; }
}

_cbox_val_named_wg_pubkey_or_empty() {
  local val="$1"
  command -v _cbox_wg_pubkey_ok >/dev/null 2>&1 || . "$INSTALL_DIR/templates/generators.sh"
  [ -z "$val" ] || _cbox_wg_pubkey_ok "$val" || { printf 'expected a 44-character base64 WireGuard public key, or empty'; return 1; }
}

_cbox_val_named_ipv4_or_empty() {
  local val="$1"
  command -v _cbox_is_ipv4 >/dev/null 2>&1 || . "$INSTALL_DIR/templates/generators.sh"
  [ -z "$val" ] || _cbox_is_ipv4 "$val" || { printf 'expected a literal IPv4 address, or empty for all addresses'; return 1; }
}

_cbox_val_named_path_slash_or_empty() {
  local val="$1"
  [ -z "$val" ] || case "$val" in
    /*) : ;;
    *) printf 'expected an absolute path (or empty)'; return 1 ;;
  esac
}

_cbox_val_named_unvalidated_legacy_gap() {
  local key="$1"
  printf 'no validator registered for %s' "$key"; return 1
}

_cbox_val_kind_wg_forward_list() {
  local val="$1" entry listen_port target_host target_port rest seen=' ' rc=0 msg=''
  command -v _cbox_is_ipv4 >/dev/null 2>&1 || . "$INSTALL_DIR/templates/generators.sh"
  set -f
  for entry in $val; do
    case "$entry" in
      *:*:*) ;;
      *) msg="invalid forward entry (want listen_port:target_host:target_port): $entry"; rc=1; break ;;
    esac
    listen_port="${entry%%:*}"
    rest="${entry#*:}"
    target_host="${rest%:*}"
    target_port="${rest##*:}"
    case "$listen_port" in
      ''|*[!0-9]*) msg="invalid forward listen_port: $entry"; rc=1; break ;;
    esac
    { [ "${#listen_port}" -le 5 ] && [ "$listen_port" -ge 1 ] && [ "$listen_port" -le 65535 ]; } \
      || { msg="forward listen_port out of range 1..65535: $entry"; rc=1; break; }
    case "$target_port" in
      ''|*[!0-9]*) msg="invalid forward target_port: $entry"; rc=1; break ;;
    esac
    { [ "${#target_port}" -le 5 ] && [ "$target_port" -ge 1 ] && [ "$target_port" -le 65535 ]; } \
      || { msg="forward target_port out of range 1..65535: $entry"; rc=1; break; }
    if _cbox_is_ipv4 "$target_host" 2>/dev/null; then
      msg="forward target_host must be a docker service name, not a LAN IPv4 literal: $entry"; rc=1; break
    fi
    case "$target_host" in
      [A-Za-z0-9]*) ;;
      *) msg="invalid forward target_host: $entry"; rc=1; break ;;
    esac
    case "$target_host" in
      *[!A-Za-z0-9_.-]*) msg="invalid forward target_host: $entry"; rc=1; break ;;
    esac
    [ "${#target_host}" -le 63 ] || { msg="forward target_host too long (max 63): $entry"; rc=1; break; }
    case "$seen" in
      *" $listen_port "*) msg="duplicate forward listen_port: $listen_port"; rc=1; break ;;
    esac
    seen="$seen$listen_port "
  done
  set +f
  [ "$rc" -eq 0 ] || printf '%s' "$msg"
  return "$rc"
}

_cbox_val_named_ipv4_list() {
  local val="$1" a
  command -v _cbox_is_ipv4 >/dev/null 2>&1 || . "$INSTALL_DIR/templates/generators.sh"
  for a in $val; do
    _cbox_is_ipv4 "$a" || { printf 'invalid IPv4 address: %s' "$a"; return 1; }
  done
}

_cbox_val_named_kernel_lang() {
  local val="$1"
  [ -z "$val" ] && return 0
  [ "${#val}" -le 64 ] || { printf 'must be at most 64 characters'; return 1; }
  case "$val" in
    *[!\ -~]*) printf 'must be plain ASCII (a rendered instruction line, no non-ASCII characters)'; return 1 ;;
  esac
  case "$val" in
    *'{'*|*'}'*) printf 'must not contain { or }'; return 1 ;;
    *'\'*) printf 'must not contain a backslash (awk would expand it as an escape sequence)'; return 1 ;;
    ' '*|*' ') printf 'must not have leading or trailing spaces'; return 1 ;;
  esac
  return 0
}
