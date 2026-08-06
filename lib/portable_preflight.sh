_CBOX_BASH_FLOOR_MAJOR=3
_CBOX_BASH_FLOOR_MINOR=2

_cbox_preflight_version_ge() {
  _cbox_preflight_have_major="$1"
  _cbox_preflight_have_minor="$2"
  _cbox_preflight_need_major="$3"
  _cbox_preflight_need_minor="$4"
  if [ "$_cbox_preflight_have_major" -gt "$_cbox_preflight_need_major" ]; then
    return 0
  fi
  if [ "$_cbox_preflight_have_major" -lt "$_cbox_preflight_need_major" ]; then
    return 1
  fi
  if [ "$_cbox_preflight_have_minor" -ge "$_cbox_preflight_need_minor" ]; then
    return 0
  fi
  return 1
}

_cbox_preflight_bash_version() {
  if [ -n "${BASH_VERSINFO:-}" ]; then
    printf '%s %s' "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"
    return 0
  fi
  _cbox_preflight_ver="$("$1" -c 'echo "${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}"' 2>/dev/null)"
  [ -n "$_cbox_preflight_ver" ] || _cbox_preflight_ver="0 0"
  printf '%s' "$_cbox_preflight_ver"
}

_cbox_preflight_uname() {
  if [ -n "${1:-}" ]; then
    printf '%s' "$1"
    return 0
  fi
  if command -v uname >/dev/null 2>&1; then
    uname -s
    return 0
  fi
  printf 'unknown'
}

cbox_preflight_check() {
  _cbox_preflight_prog="$1"
  _cbox_preflight_uname_override="${2:-}"
  _cbox_preflight_have_python3="${3:-auto}"
  _cbox_preflight_have_docker="${4:-auto}"

  set -- $(_cbox_preflight_bash_version "$_cbox_preflight_prog")
  _cbox_preflight_bash_major="$1"
  _cbox_preflight_bash_minor="$2"

  _cbox_preflight_os="$(_cbox_preflight_uname "$_cbox_preflight_uname_override")"

  if [ "$_cbox_preflight_os" = Darwin ]; then
    printf 'cbox: warning: macOS support is EXPERIMENTAL. The host layer is bash-3.2-clean with darwin branches for the process-liveness, peer-credential and stat paths, but the darwin-specific code (ps lstart parsing, LOCAL_PEERCRED/xucred layout, BSD flock) has not been verified on real macOS hardware - treat failures as expected and report them. See cbox/docs/MULTIPLATFORM_DESIGN.md.\n' >&2
  fi

  if ! _cbox_preflight_version_ge "$_cbox_preflight_bash_major" "$_cbox_preflight_bash_minor" "$_CBOX_BASH_FLOOR_MAJOR" "$_CBOX_BASH_FLOOR_MINOR"; then
    printf 'cbox: bash %s.%s or newer is required (found %s.%s). Upgrade bash and retry.\n' \
      "$_CBOX_BASH_FLOOR_MAJOR" "$_CBOX_BASH_FLOOR_MINOR" "$_cbox_preflight_bash_major" "$_cbox_preflight_bash_minor" >&2
    return 1
  fi

  if [ "$_cbox_preflight_have_python3" = auto ]; then
    if command -v python3 >/dev/null 2>&1; then
      _cbox_preflight_have_python3=yes
    else
      _cbox_preflight_have_python3=no
    fi
  fi
  if [ "$_cbox_preflight_have_python3" != yes ]; then
    printf 'cbox: warning: python3 was not found on PATH - most cbox operations will fail until it is installed. On a fresh macOS install, running "python3" for the first time pops an Install Command Line Tools dialog instead of running - accept that dialog (or install Xcode Command Line Tools / a python3 from python.org or brew).\n' >&2
  fi

  if [ "$_cbox_preflight_have_docker" = auto ]; then
    if command -v docker >/dev/null 2>&1; then
      _cbox_preflight_have_docker=yes
    else
      _cbox_preflight_have_docker=no
    fi
  fi
  if [ "$_cbox_preflight_have_docker" != yes ]; then
    printf 'cbox: warning: docker was not found on PATH - container operations will fail until it is installed (Docker Desktop, OrbStack, or the docker engine).\n' >&2
  fi

  return 0
}
