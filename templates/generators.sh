#!/usr/bin/env bash
set -euo pipefail

_cbox_tpl_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$_cbox_tpl_dir/_common.sh" ]; then
  . "$_cbox_tpl_dir/_common.sh"
fi
unset _cbox_tpl_dir

_cbox_write() {
  local target="$1" dir tmp
  dir="$(dirname "$target")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.cbox.XXXXXX")"
  cat > "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$target"
}

_cbox_egress_active() {
  [ "${CBOX_EGRESS_MODE:-off}" != "off" ] && [ "${CBOX_EGRESS_APPLIED:-0}" = "1" ]
}

_cbox_toml_string() {
  python3 -c 'import json, sys; sys.stdout.write(json.dumps(sys.argv[1]))' "$1"
}

_cbox_apply_name_substitution() {
  local src="$1" dst="$2" u name
  u="$(id -un)"
  name="${u^}"
  name="${name//\\/\\\\}"
  name="${name//\//\\/}"
  name="${name//&/\\&}"
  sed "s/{NAME}/$name/g" "$src" > "$dst"
}

_cbox_codex_precreate_ro_pins() {
  local codex_path="$1"
  [ "${CBOX_CODEX_MODE:-mount}" = "mount" ] || return 0
  mkdir -p "$codex_path"
  local f
  for f in AGENTS.override.md cbox-container.config.toml cbox-host.config.toml config.toml AGENTS.md hooks.json; do
    [ -e "$codex_path/$f" ] || : > "$codex_path/$f"
  done
}

_cbox_tz_env_into() {
  local tmp="$1" tzname=""
  if [ -L /etc/localtime ]; then
    tzname="$(readlink /etc/localtime 2>/dev/null)" || tzname=""
    case "$tzname" in
      */zoneinfo/*) tzname="${tzname##*/zoneinfo/}" ;;
      *) tzname="" ;;
    esac
  fi
  if [ -z "$tzname" ] && [ -f /etc/timezone ]; then
    IFS= read -r tzname < /etc/timezone || tzname=""
  fi
  tzname="${tzname#"${tzname%%[!/]*}"}"
  case "$tzname" in
    ''|*[!A-Za-z0-9_+/-]*) return 0 ;;
  esac
  case "$tzname" in
    *[A-Za-z]*) ;;
    *) return 0 ;;
  esac
  printf '      - TZ=%s\n' "$tzname" >> "$tmp"
}

_cbox_tz_mounts_into() {
  local tmp="$1"
  if [ -e /etc/localtime ]; then
    printf '      - /etc/localtime:/etc/localtime:ro\n' >> "$tmp"
  fi
  if [ -f /etc/timezone ]; then
    printf '      - /etc/timezone:/etc/timezone:ro\n' >> "$tmp"
  fi
}

_cbox_netaccess_active() {
  [ "${CBOX_NETACCESS_MODE:-off}" != "off" ] && [ "${CBOX_NETACCESS_APPLIED:-0}" = "1" ]
}

_cbox_proxy_active() {
  _cbox_egress_active || _cbox_netaccess_active
}

_cbox_ere_escape() {
  local s="$1" out="" i=0 c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      '.'|'^'|'$'|'*'|'+'|'?'|'('|')'|'['|']'|'{'|'}'|'|'|"\\")
        out="$out\\$c"
        ;;
      *)
        out="$out$c"
        ;;
    esac
  done
  printf '%s' "$out"
}

_cbox_workdir() {
  local -a ws=()
  read -r -a ws <<< "${CBOX_WORKSPACES:-}"
  if [ -n "${CBOX_WORKDIR:-}" ]; then
    printf '%s' "$CBOX_WORKDIR"
  elif [ "${#ws[@]}" -gt 0 ]; then
    printf '%s' "${ws[0]}"
  else
    printf '%s' "$HOME"
  fi
}

_cbox_managed_dirs() {
  local managed=""
  if [ "${CBOX_CLAUDE_MODE:-mount}" = "volume" ]; then
    managed="$managed"':${HOST_HOME}/.claude'
  fi
  if [ "${CBOX_CLAUDE_MODE:-mount}" = "mount" ]; then
    managed="$managed"':${HOST_HOME}/.claude-cbox'
  fi
  if [ "${CBOX_CODEX_MODE:-mount}" = "volume" ]; then
    managed="$managed"':${HOST_HOME}/.codex'
  fi
  if [ "${CBOX_VENV_MODE:-none}" = "volume" ]; then
    managed="$managed:/opt/venv"
  fi
  case "${CBOX_SSH_MODE:-none}" in
    container-keys|mixed)
      managed="$managed"':${HOST_HOME}/.ssh'
      ;;
  esac
  printf '%s' "${managed#:}"
}

gen_env_file_into() {
  local effdir="$1"
  {
    printf 'HOST_USER=%s\n' "$(id -un)"
    printf 'HOST_UID=%s\n' "$(id -u)"
    printf 'HOST_GID=%s\n' "$(id -g)"
    printf 'HOST_HOME=%s\n' "$HOME"
  } | _cbox_write "$effdir/.env"
}

gen_env_file() {
  gen_env_file_into "$INSTALL_DIR"
}

_cbox_bins_volume() {
  local tool="$1" scope="${CBOX_BINS_SCOPE:-global}" claude_target codex_version codex_target h8
  case "$tool" in
    claude|codex) ;;
    *) die "_cbox_bins_volume: unknown tool $tool" ;;
  esac
  if [ "$scope" != "pinned" ]; then
    printf 'cbox-bins-%s' "$tool"
    return 0
  fi
  claude_target="${CBOX_CLAUDE_TARGET:-stable}"
  codex_version="${CBOX_CODEX_VERSION:-latest}"
  codex_target="${CBOX_CODEX_TARGET:-}"
  case "$tool" in
    claude)
      h8="$(printf 'claude|%s' "$claude_target" | sha256sum | awk '{print substr($1,1,8)}')"
      ;;
    codex)
      h8="$(printf 'codex|%s|%s' "$codex_version" "$codex_target" | sha256sum | awk '{print substr($1,1,8)}')"
      ;;
  esac
  printf 'cbox-bins-%s-%s' "$tool" "$h8"
}

_cbox_validate_targets() {
  local claude_target="${CBOX_CLAUDE_TARGET:-stable}"
  local codex_version="${CBOX_CODEX_VERSION:-latest}"
  printf '%s' "$claude_target" | grep -Eq '^(stable|latest|[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?)$' \
    || die "invalid CBOX_CLAUDE_TARGET '$claude_target' (expected stable, latest, or x.y.z)"
  printf '%s' "$codex_version" | grep -Eq '^(latest|[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta)(\.[0-9]+)?)?)$' \
    || die "invalid CBOX_CODEX_VERSION '$codex_version' (expected latest or x.y.z)"
}

gen_dockerfile_into() {
  local effdir="$1" digest="$2"
  local pkgs claude_target codex_version codex_target workdir tmp
  pkgs="$(_cbox_final_pkgs)"
  _cbox_validate_targets
  claude_target="${CBOX_CLAUDE_TARGET:-stable}"
  codex_version="${CBOX_CODEX_VERSION:-latest}"
  codex_target="${CBOX_CODEX_TARGET:-}"
  workdir="$(_cbox_workdir)"
  tmp="$(mktemp "$effdir/.cbox.XXXXXX")"
  cat > "$tmp" <<EOF
FROM ubuntu:24.04@$digest
RUN userdel -r ubuntu 2>/dev/null || true
RUN apt-get update \\
 && apt-get install -y --no-install-recommends \\
      $pkgs \\
 && rm -rf /var/lib/apt/lists/*
ENV COLORTERM=truecolor
ENV TERM=xterm-256color
ENV LANG=C.UTF-8
ENV CBOX_CLAUDE_TARGET=$claude_target
ENV CBOX_CODEX_VERSION=$codex_version
ENV CBOX_CODEX_TARGET=$codex_target
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh
COPY install-bins.sh /opt/cbox/install-bins.sh
RUN chmod 755 /opt/cbox/install-bins.sh
WORKDIR $workdir
ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
EOF
  chmod 0644 "$tmp"
  mv "$tmp" "$effdir/Dockerfile"
}

gen_dockerfile() {
  local digest
  digest="$(_cbox_resolve_base_digest ubuntu:24.04)" || die "cannot resolve base image digest and no local image - network required for first build"
  gen_dockerfile_into "$INSTALL_DIR" "$digest"
}

_cbox_path_within() {
  local a="$1" b="$2"
  [ "$a" = "$b" ] && return 0
  case "$a" in
    "$b"/*) return 0 ;;
  esac
  return 1
}

_cbox_check_workspace_overlap() {
  local -a ws=("$@")
  local w reserved_label reserved_path w_real reserved_real
  for w in "${ws[@]}"; do
    [ -n "$w" ] || continue
    w_real="$(realpath -m "$w")"
    for reserved_label in INSTALL_DIR CBOX_CLAUDE_PATH CBOX_CODEX_PATH CBOX_VENV_PATH; do
      reserved_path="${!reserved_label:-}"
      [ -n "$reserved_path" ] || continue
      reserved_real="$(realpath -m "$reserved_path")"
      if _cbox_path_within "$w_real" "$reserved_real" || _cbox_path_within "$reserved_real" "$w_real"; then
        die "workspace path conflicts with $reserved_label ($reserved_real): $w_real"
      fi
    done
  done
}

_cbox_selftest_path_primitives() {
  local fail=0 tmp out

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$tmp/root/sub"
  ( cd "$tmp/root/sub" && git init -q && git config user.email t@t && git config user.name t \
    && touch f && git add f && git commit -q -m init ) >/dev/null 2>&1 || true
  if out="$(cd "$tmp/root/sub" 2>/dev/null && _cbox_workspace_root)"; then
    [ "$out" = "$(realpath "$tmp/root/sub")" ] || { echo "selftest: subdir root mismatch: $out" >&2; fail=1; }
  else
    echo "selftest: subdir root resolution failed" >&2
    fail=1
  fi

  ln -s "$tmp/root/sub" "$tmp/root-link"
  if out="$(cd "$tmp/root-link" 2>/dev/null && _cbox_workspace_root)"; then
    [ "$out" = "$(realpath "$tmp/root/sub")" ] || { echo "selftest: symlink root not resolved: $out" >&2; fail=1; }
  else
    echo "selftest: symlink root resolution failed" >&2
    fail=1
  fi

  if out="$(cd "$HOME" 2>/dev/null && _cbox_workspace_root)"; then
    echo "selftest: HOME was not rejected: $out" >&2
    fail=1
  fi

  if out="$(cd / 2>/dev/null && _cbox_workspace_root)"; then
    echo "selftest: / was not rejected: $out" >&2
    fail=1
  fi

  return "$fail"
}

_cbox_manifest_write() {
  local eff="$1" root="$2" conf="$3"
  local conf_sha gen_sha
  conf_sha="$(sha256sum "$conf" | awk '{print $1}')"
  gen_sha="$(_cbox_tpl_sha)"
  {
    printf 'schema=1\n'
    printf 'workspace=%s\n' "$root"
    printf 'conf=%s\n' "$conf_sha"
    printf 'generators=%s\n' "$gen_sha"
  } | _cbox_write "$eff/manifest.sha256"
  printf '%s\n' "$root" | _cbox_write "$eff/workspace"
}

_cbox_manifest_field() {
  local file="$1" key="$2" line
  [ -f "$file" ] || return 1
  line="$(grep -m1 "^$key=" "$file")" || return 1
  printf '%s' "${line#"$key"=}"
}

_cbox_manifest_verify_conf() {
  local eff="$1" root="$2" conf mf
  conf="$eff/cbox.conf"; mf="$eff/manifest.sha256"
  local want_ws want_conf want_gen have_conf have_gen
  [ -f "$conf" ] || die "no effective config in $eff"
  [ -f "$mf" ] || die "effective config drifted (manifest missing) - re-bless with setup.sh --local $root"
  want_ws="$(_cbox_manifest_field "$mf" workspace)" || die "effective config drifted (manifest malformed) - re-bless with setup.sh --local $root"
  [ "$want_ws" = "$root" ] || die "path-hash collision or moved project for $root (effective dir claims $want_ws); remove $eff after review"
  want_conf="$(_cbox_manifest_field "$mf" conf)" || die "effective config drifted (manifest malformed) - re-bless with setup.sh --local $root"
  want_gen="$(_cbox_manifest_field "$mf" generators)" || die "effective config drifted (manifest malformed) - re-bless with setup.sh --local $root"
  have_conf="$(sha256sum "$conf" | awk '{print $1}')"
  have_gen="$(_cbox_tpl_sha)"
  [ "$have_conf" = "$want_conf" ] || die "effective config drifted - re-bless with setup.sh --local $root"
  [ "$have_gen" = "$want_gen" ] || die "templates changed since last generation - re-bless with setup.sh --local $root"
}

_cbox_manifest_status() {
  local eff="$1" root="$2" conf mf want_ws want_conf want_gen have_conf have_gen
  conf="$eff/cbox.conf"; mf="$eff/manifest.sha256"
  [ -f "$conf" ] || { printf 'missing'; return 0; }
  [ -f "$mf" ] || { printf 'missing'; return 0; }
  want_ws="$(_cbox_manifest_field "$mf" workspace)" || { printf 'malformed'; return 0; }
  want_conf="$(_cbox_manifest_field "$mf" conf)" || { printf 'malformed'; return 0; }
  want_gen="$(_cbox_manifest_field "$mf" generators)" || { printf 'malformed'; return 0; }
  [ "$want_ws" = "$root" ] || { printf 'collision'; return 0; }
  have_conf="$(sha256sum "$conf" | awk '{print $1}')"
  have_gen="$(_cbox_tpl_sha)"
  if [ "$have_conf" != "$want_conf" ] || [ "$have_gen" != "$want_gen" ]; then
    printf 'drifted'; return 0
  fi
  printf 'ok'
}

_cbox_manifest_write_generated() {
  local eff="$1"
  local -a names=(compose dockerfile entrypoint env)
  local -a files=(docker-compose.yml Dockerfile entrypoint.sh .env)
  local tmp i n f sha
  tmp="$(mktemp "$eff/.cbox.XXXXXX")"
  if [ -f "$eff/manifest.sha256" ]; then
    grep -Ev '^(compose|dockerfile|entrypoint|env)=' "$eff/manifest.sha256" > "$tmp" || true
  fi
  for i in "${!names[@]}"; do
    n="${names[$i]}"; f="${files[$i]}"
    [ -f "$eff/$f" ] || continue
    sha="$(sha256sum "$eff/$f" | awk '{print $1}')"
    printf '%s=%s\n' "$n" "$sha" >> "$tmp"
  done
  chmod 0644 "$tmp"
  mv "$tmp" "$eff/manifest.sha256"
}

_cbox_manifest_verify_generated() {
  local eff="$1" mf
  mf="$eff/manifest.sha256"
  local -a names=(compose dockerfile entrypoint env)
  local -a files=(docker-compose.yml Dockerfile entrypoint.sh .env)
  local i n f want have
  [ -f "$mf" ] || die "effective config drifted (manifest missing) - regenerate with cbox run"
  for i in "${!names[@]}"; do
    n="${names[$i]}"; f="${files[$i]}"
    [ -f "$eff/$f" ] || continue
    want="$(_cbox_manifest_field "$mf" "$n")" || die "effective config drifted (manifest malformed) - regenerate with cbox run"
    have="$(sha256sum "$eff/$f" | awk '{print $1}')"
    [ "$have" = "$want" ] || die "effective config drifted ($f changed outside cbox) - regenerate with cbox run"
  done
}

_cbox_have_buildx() {
  docker buildx version >/dev/null 2>&1
}

_cbox_resolve_base_digest() {
  local tag="$1" cache="$HOME/.config/cbox/base-digest.cache"
  local ttl="${CBOX_BASE_DIGEST_TTL:-3600}" now line d t r
  mkdir -p "$(dirname "$cache")"
  now="$(date +%s)"
  line="$(grep "^$tag|" "$cache" 2>/dev/null | tail -n1)" || true
  d="${line#*|}"; d="${d%%|*}"; t="${line##*|}"
  if [ -n "$line" ] && [ "$ttl" -gt 0 ] && [ $((now - t)) -lt "$ttl" ]; then
    printf '%s' "$d"
    return 0
  fi
  r=""
  if _cbox_have_buildx; then
    r="$(timeout 5 docker buildx imagetools inspect "$tag" --format '{{println .Manifest.Digest}}' 2>/dev/null | head -n1)" || r=""
  fi
  if [ -z "$r" ]; then
    r="$(timeout 5 docker manifest inspect -v "$tag" 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if isinstance(data, list):
    data = data[0]
d = data.get("Descriptor", {}).get("digest", "")
if d:
    print(d)
' 2>/dev/null)" || r=""
  fi
  if [ -n "$r" ]; then
    { grep -v "^$tag|" "$cache" 2>/dev/null; printf '%s|%s|%s\n' "$tag" "$r" "$now"; } > "$cache.tmp" && mv "$cache.tmp" "$cache"
    printf '%s' "$r"
    return 0
  fi
  if [ -n "$d" ]; then
    echo "cbox: offline - base digest freshness unverified, using last known $d" >&2
    printf '%s' "$d"
    return 0
  fi
  if r="$(docker image inspect "$tag" --format '{{index .RepoDigests 0}}' 2>/dev/null)" && [ -n "$r" ]; then
    printf '%s' "${r#*@}"
    return 0
  fi
  return 1
}

_cbox_final_pkgs() {
  local pkgs="python3 python3-venv git curl socat ca-certificates jq gosu ripgrep tmux xclip xsel wl-clipboard"
  if [ "${CBOX_SSH_MODE:-none}" != "none" ]; then
    pkgs="$pkgs openssh-client"
  fi
  if [ -n "${CBOX_APT_EXTRA:-}" ]; then
    pkgs="$pkgs ${CBOX_APT_EXTRA}"
  fi
  printf '%s\n' "$pkgs" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

gen_image_inputs() {
  local eff="$1" digest="$2"
  local pkgs claude_target codex_version codex_target entrypoint_sha install_bins_sha tpl_sha
  pkgs="$(_cbox_final_pkgs)"
  claude_target="${CBOX_CLAUDE_TARGET:-stable}"
  codex_version="${CBOX_CODEX_VERSION:-latest}"
  codex_target="${CBOX_CODEX_TARGET:-}"
  entrypoint_sha="$(sha256sum "$eff/entrypoint.sh" | awk '{print $1}')"
  install_bins_sha="$(sha256sum "$eff/install-bins.sh" | awk '{print $1}')"
  tpl_sha="$(_cbox_tpl_sha)"
  {
    printf 'schema=1\n'
    printf 'base=ubuntu:24.04@%s\n' "$digest"
    printf 'pkgs=%s\n' "$pkgs"
    printf 'python=1\n'
    printf 'gpu=%s\n' "${CBOX_GPU:-0}"
    printf 'egress=%s\n' "${CBOX_EGRESS_MODE:-off}"
    printf 'claude_target=%s\n' "$claude_target"
    printf 'codex_version=%s\n' "$codex_version"
    printf 'codex_target=%s\n' "$codex_target"
    printf 'copy.entrypoint.sh=%s\n' "$entrypoint_sha"
    printf 'copy.install-bins.sh=%s\n' "$install_bins_sha"
    printf 'tpl_sha=%s\n' "$tpl_sha"
  } | _cbox_write "$eff/image.inputs"
}

_cbox_image_hash() {
  local eff="$1"
  sha256sum "$eff/image.inputs" | awk '{print $1}'
}

_cbox_image_tag() {
  local hash="$1"
  printf 'cbox-img:%s' "${hash:0:12}"
}

gen_compose() {
  local name="${CBOX_NAME:-cbox}"
  local policy="${CBOX_RESTART_POLICY:-no}"
  local claude_mode="${CBOX_CLAUDE_MODE:-mount}"
  local codex_mode="${CBOX_CODEX_MODE:-mount}"
  local claude_path="${CBOX_CLAUDE_PATH:-$HOME/.claude}"
  local codex_path="${CBOX_CODEX_PATH:-$HOME/.codex}"
  local venv_mode="${CBOX_VENV_MODE:-none}"
  local venv_path="${CBOX_VENV_PATH:-$HOME/.venvs/cuda-py312}"
  local ssh_mode="${CBOX_SSH_MODE:-none}"
  local agent_dir="${CBOX_SSH_AGENT_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/cbox-ssh}"
  local workdir managed tmp w
  workdir="$(_cbox_workdir)"
  managed="$(_cbox_managed_dirs)"
  local -a ws=()
  read -r -a ws <<< "${CBOX_WORKSPACES:-}"
  _cbox_check_workspace_overlap "${ws[@]-}"
  local guard_roots
  guard_roots="$(IFS=:; printf '%s' "${ws[*]-}")"
  local img_tag
  img_tag="$(_cbox_image_tag "$(_cbox_image_hash "$INSTALL_DIR")")"
  tmp="$(mktemp "$INSTALL_DIR/.cbox.XXXXXX")"
  cat > "$tmp" <<EOF
name: $name
services:
  cbox:
    image: $img_tag
    init: true
    stdin_open: true
    tty: true
    restart: "$policy"
    working_dir: $workdir
    environment:
      - HOST_USER=\${HOST_USER}
      - HOST_UID=\${HOST_UID}
      - HOST_GID=\${HOST_GID}
      - HOST_HOME=\${HOST_HOME}
      - CODEX_GUARD_CONFIG=\${HOST_HOME}/.claude/hooks/codex_scope.container.json
      - CODEX_GUARD_AUDIT=\${HOST_HOME}/.claude/codex_guard_audit.container.jsonl
      - CODEX_GUARD_EXTRA_ROOTS=$guard_roots
      - CBOX_MANAGED_DIRS=$managed
      - CBOX_RUNTIME=container
      - CBOX_CONTEXT_PROFILE=${CBOX_CONTEXT_PROFILE:-full}
      - DISABLE_AUTOUPDATER=1
EOF
  if [ "$claude_mode" = "mount" ]; then
    printf '      - CLAUDE_CONFIG_DIR=${HOST_HOME}/.claude-cbox\n' >> "$tmp"
    printf '      - CLAUDE_SECURESTORAGE_CONFIG_DIR=${HOST_HOME}/.claude\n' >> "$tmp"
  fi
  _cbox_tz_env_into "$tmp"
  case "$ssh_mode" in
    host-agent|mixed)
      printf '      - SSH_AUTH_SOCK=/run/cbox-ssh/agent.sock\n' >> "$tmp"
      ;;
  esac
  if _cbox_egress_active; then
    cat >> "$tmp" <<'EOF'
      - HTTP_PROXY=http://proxy:8888
      - HTTPS_PROXY=http://proxy:8888
      - http_proxy=http://proxy:8888
      - https_proxy=http://proxy:8888
      - NO_PROXY=localhost,127.0.0.1,::1
      - no_proxy=localhost,127.0.0.1,::1
EOF
  fi
  printf '    volumes:\n' >> "$tmp"
  _cbox_tz_mounts_into "$tmp"
  for w in "${ws[@]}"; do
    printf '      - %s:%s:rw\n' "$w" "$w" >> "$tmp"
  done
  if [ "$claude_mode" = "mount" ]; then
    gen_claude_config_into "$INSTALL_DIR/generated/claude-config" "$claude_path"
    mkdir -p "$claude_path/hooks" "$claude_path/agents" "$claude_path/policies" "$claude_path/templates" "$claude_path/projects" "$claude_path/tasks" "$claude_path/session-env" "$claude_path/plugins" "$claude_path/file-history" "$claude_path/plans" "$claude_path/shell-snapshots" "$claude_path/agent-memory" "$claude_path/commands" "$claude_path/skills" "$claude_path/rules"
    [ -f "$claude_path/settings.json" ] || printf '{}\n' > "$claude_path/settings.json"
    [ -f "$HOME/.claude.json" ] || printf '{}\n' > "$HOME/.claude.json"
    [ -f "$claude_path/CLAUDE.md" ] || : > "$claude_path/CLAUDE.md"
    gen_claude_cbox_json_seed_into "$INSTALL_DIR/generated/claude-config/.claude.json" "$INSTALL_DIR/generated/state/claude-cbox.json"
    cat >> "$tmp" <<EOF
      - $claude_path:\${HOST_HOME}/.claude:rw
      - $claude_path/hooks:\${HOST_HOME}/.claude/hooks:ro
      - $claude_path/settings.json:\${HOST_HOME}/.claude/settings.json:rw
      - $INSTALL_DIR/generated/managed-settings.json:/etc/claude-code/managed-settings.json:ro
      - $HOME/.claude.json:\${HOST_HOME}/.claude.json:ro
      - $claude_path/CLAUDE.md:\${HOST_HOME}/.claude/CLAUDE.md:ro
      - $claude_path/agents:\${HOST_HOME}/.claude/agents:ro
      - $claude_path/policies:\${HOST_HOME}/.claude/policies:ro
      - $claude_path/templates:\${HOST_HOME}/.claude/templates:ro
      - $INSTALL_DIR/generated/claude-config:\${HOST_HOME}/.claude-cbox:rw
      - $claude_path/projects:\${HOST_HOME}/.claude-cbox/projects:rw
      - $claude_path/jobs:\${HOST_HOME}/.claude-cbox/jobs:rw
      - $claude_path/tasks:\${HOST_HOME}/.claude-cbox/tasks:rw
      - $claude_path/commands:\${HOST_HOME}/.claude-cbox/commands:ro
      - $claude_path/skills:\${HOST_HOME}/.claude-cbox/skills:ro
      - $claude_path/rules:\${HOST_HOME}/.claude-cbox/rules:ro
      - $claude_path/session-env:\${HOST_HOME}/.claude-cbox/session-env:rw
      - $claude_path/plugins:\${HOST_HOME}/.claude-cbox/plugins:rw
      - $claude_path/file-history:\${HOST_HOME}/.claude-cbox/file-history:rw
      - $claude_path/plans:\${HOST_HOME}/.claude-cbox/plans:rw
      - $claude_path/shell-snapshots:\${HOST_HOME}/.claude-cbox/shell-snapshots:rw
      - $claude_path/agent-memory:\${HOST_HOME}/.claude-cbox/agent-memory:rw
      - $claude_path/hooks:\${HOST_HOME}/.claude-cbox/hooks:ro
      - $claude_path/settings.json:\${HOST_HOME}/.claude-cbox/settings.json:rw
      - $claude_path/CLAUDE.md:\${HOST_HOME}/.claude-cbox/CLAUDE.md:ro
      - $claude_path/agents:\${HOST_HOME}/.claude-cbox/agents:ro
      - $claude_path/policies:\${HOST_HOME}/.claude-cbox/policies:ro
      - $claude_path/templates:\${HOST_HOME}/.claude-cbox/templates:ro
EOF
  else
    cat >> "$tmp" <<EOF
      - claude:\${HOST_HOME}/.claude
      - $INSTALL_DIR/generated/hooks:\${HOST_HOME}/.claude/hooks:ro
      - $INSTALL_DIR/generated/settings.json:\${HOST_HOME}/.claude/settings.json:rw
      - $INSTALL_DIR/generated/managed-settings.json:/etc/claude-code/managed-settings.json:ro
      - $INSTALL_DIR/generated/state/claude.json:\${HOST_HOME}/.claude.json:rw
      - $INSTALL_DIR/generated/claude/CLAUDE.md:\${HOST_HOME}/.claude/CLAUDE.md:ro
      - $INSTALL_DIR/generated/claude/agents:\${HOST_HOME}/.claude/agents:ro
      - $INSTALL_DIR/generated/claude/policies:\${HOST_HOME}/.claude/policies:ro
      - $INSTALL_DIR/generated/claude/templates:\${HOST_HOME}/.claude/templates:ro
EOF
  fi
  if [ "$codex_mode" = "mount" ]; then
    _cbox_codex_precreate_ro_pins "$codex_path"
    cat >> "$tmp" <<EOF
      - $codex_path:\${HOST_HOME}/.codex:rw
      - $codex_path/config.toml:\${HOST_HOME}/.codex/config.toml:ro
      - $codex_path/AGENTS.md:\${HOST_HOME}/.codex/AGENTS.md:ro
      - $codex_path/cbox-host.config.toml:\${HOST_HOME}/.codex/cbox-host.config.toml:ro
EOF
  else
    cat >> "$tmp" <<'EOF'
      - codex:${HOST_HOME}/.codex
EOF
  fi
  cat >> "$tmp" <<EOF
      - claude-local:\${HOST_HOME}/.local:ro
      - codex-packages:\${HOST_HOME}/.codex/packages:ro
      - $INSTALL_DIR/generated/codex/cbox-container.config.toml:\${HOST_HOME}/.codex/cbox-container.config.toml:ro
      - $INSTALL_DIR/generated/codex/AGENTS.override.md:\${HOST_HOME}/.codex/AGENTS.override.md:ro
      - $INSTALL_DIR/generated/codex/hooks.json:\${HOST_HOME}/.codex/hooks.json:ro
EOF
  case "$venv_mode" in
    host)
      printf '      - %s:%s:ro\n' "$venv_path" "$venv_path" >> "$tmp"
      ;;
    volume)
      printf '      - venv:/opt/venv\n' >> "$tmp"
      ;;
  esac
  case "$ssh_mode" in
    host-agent)
      cat >> "$tmp" <<EOF
      - $agent_dir:/run/cbox-ssh:ro
      - $INSTALL_DIR/generated/ssh/config:\${HOST_HOME}/.ssh/config:ro
EOF
      ;;
    container-keys)
      cat >> "$tmp" <<'EOF'
      - ssh:${HOST_HOME}/.ssh
EOF
      ;;
    mixed)
      cat >> "$tmp" <<EOF
      - ssh:\${HOST_HOME}/.ssh
      - $agent_dir:/run/cbox-ssh:ro
EOF
      ;;
  esac
  if [ "${CBOX_GITCONFIG:-0}" = "1" ] && [ -f "$HOME/.gitconfig" ]; then
    cat >> "$tmp" <<EOF
      - $HOME/.gitconfig:\${HOST_HOME}/.gitconfig:ro
EOF
  fi
  if _cbox_proxy_active; then
    cat >> "$tmp" <<EOF
    networks:
      - internal
    depends_on:
      - proxy
  proxy:
    build:
      context: .
      dockerfile: Dockerfile.egress
    image: cbox-proxy:$name
    restart: "$policy"
    networks:
      - internal
      - egress
    volumes:
      - $INSTALL_DIR/generated/proxy:/etc/cbox-generated:ro
    healthcheck:
      test: ["CMD-SHELL", "ip=127.0.0.1; [ -f /etc/cbox-generated/internal-ip ] && ip=\$\$(cat /etc/cbox-generated/internal-ip); nc -z -w 2 \"\$\$ip\" 8888 || nc -z -w 2 \"\$\$ip\" 1080"]
      interval: 10s
      timeout: 3s
      start_period: 10s
      retries: 3
EOF
  fi
  cat >> "$tmp" <<EOF
volumes:
  claude-local:
    external: true
    name: $(_cbox_bins_volume claude)
  codex-packages:
    external: true
    name: $(_cbox_bins_volume codex)
EOF
  if [ "$claude_mode" = "volume" ]; then
    cat >> "$tmp" <<EOF
  claude:
    name: $name-claude
EOF
  fi
  if [ "$codex_mode" = "volume" ]; then
    cat >> "$tmp" <<EOF
  codex:
    name: $name-codex
EOF
  fi
  if [ "$venv_mode" = "volume" ]; then
    cat >> "$tmp" <<EOF
  venv:
    name: $name-venv
EOF
  fi
  case "$ssh_mode" in
    container-keys|mixed)
      cat >> "$tmp" <<EOF
  ssh:
    name: $name-ssh
EOF
      ;;
  esac
  if _cbox_proxy_active; then
    cat >> "$tmp" <<'EOF'
networks:
  internal:
    internal: true
  egress: {}
EOF
  fi
  chmod 0644 "$tmp"
  mv "$tmp" "$INSTALL_DIR/docker-compose.yml"
}

gen_compose_isolated() {
  local eff="$1" root="$2" img_tag="$3" img_hash="$4"
  local policy="no"
  local p_hash slug session_scope
  local claude_mode="${CBOX_CLAUDE_MODE:-mount}"
  local codex_mode="${CBOX_CODEX_MODE:-mount}"
  local claude_path="${CBOX_CLAUDE_PATH:-$HOME/.claude}"
  local codex_path="${CBOX_CODEX_PATH:-$HOME/.codex}"
  local venv_mode="${CBOX_VENV_MODE:-none}"
  local venv_path="${CBOX_VENV_PATH:-$HOME/.venvs/cuda-py312}"
  local ssh_mode="${CBOX_SSH_MODE:-none}"
  local agent_dir="${CBOX_SSH_AGENT_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/cbox-ssh}"
  local managed tmp i_short

  p_hash="$(_cbox_path_hash "$root")"
  slug="$(_cbox_slug "$root")"
  session_scope="${CBOX_SESSION_SCOPE:-isolated}"
  i_short="${img_hash:0:12}"

  managed="$(_cbox_managed_dirs)"
  if [ "$session_scope" = "isolated" ]; then
    managed="${managed:+$managed:}"'${HOST_HOME}/.claude/projects/'"$slug"
  fi

  _cbox_check_workspace_overlap "$root"

  if _cbox_proxy_active; then
    gen_dockerfile_egress_into "$eff"
    gen_supervisord_conf_into "$eff"
    gen_tinyproxy_conf_into "$eff/proxy"
    gen_egress_filter_into "$eff/proxy"
  fi

  tmp="$(mktemp "$eff/.cbox.XXXXXX")"
  cat > "$tmp" <<EOF
name: cbox-p$p_hash
services:
  cbox:
    image: $img_tag
    init: true
    stdin_open: true
    tty: true
    restart: "$policy"
    working_dir: $root
    labels:
      cbox.kind: isolated
      cbox.root: "$root"
      cbox.effdir: "$eff"
      cbox.phash: "$p_hash"
      cbox.imghash: "$img_hash"
    environment:
      - HOST_USER=\${HOST_USER}
      - HOST_UID=\${HOST_UID}
      - HOST_GID=\${HOST_GID}
      - HOST_HOME=\${HOST_HOME}
      - CODEX_GUARD_CONFIG=\${HOST_HOME}/.claude/hooks/codex_scope.container.json
      - CODEX_GUARD_AUDIT=\${HOST_HOME}/.claude/codex_guard_audit.container.jsonl
      - CODEX_GUARD_EXTRA_ROOTS=$root
      - CBOX_MANAGED_DIRS=$managed
      - CBOX_RUNTIME=container
      - CBOX_CONTEXT_PROFILE=${CBOX_CONTEXT_PROFILE:-full}
      - DISABLE_AUTOUPDATER=1
EOF
  if [ "$claude_mode" = "mount" ]; then
    printf '      - CLAUDE_CONFIG_DIR=${HOST_HOME}/.claude-cbox\n' >> "$tmp"
    printf '      - CLAUDE_SECURESTORAGE_CONFIG_DIR=${HOST_HOME}/.claude\n' >> "$tmp"
  fi
  if [ "$claude_mode" = "mount" ] && [ "$session_scope" = "isolated" ]; then
    local resume_prompt="${CBOX_LIMIT_RESUME_PROMPT:-pokracuj}"
    resume_prompt="${resume_prompt//$'\n'/ }"
    resume_prompt="${resume_prompt//$'\r'/ }"
    printf '      - CBOX_SCOPE_ROOT=%s\n' "$root" >> "$tmp"
    printf '      - CBOX_SCOPE_SLUG=%s\n' "$slug" >> "$tmp"
    printf '      - CBOX_LIMIT_AUTORESUME=%s\n' "${CBOX_LIMIT_AUTORESUME:-off}" >> "$tmp"
    printf '      - CBOX_LIMIT_RESUME_DELAY=%s\n' "${CBOX_LIMIT_RESUME_DELAY:-300}" >> "$tmp"
    printf '      - CBOX_LIMIT_RESUME_PROMPT=%s\n' "$resume_prompt" >> "$tmp"
    printf '      - CBOX_LIMIT_RESUME_STAGGER=%s\n' "${CBOX_LIMIT_RESUME_STAGGER:-30}" >> "$tmp"
    printf '      - CBOX_LIMIT_RESUME_MAX_PER_DAY=%s\n' "${CBOX_LIMIT_RESUME_MAX_PER_DAY:-10}" >> "$tmp"
  fi
  _cbox_tz_env_into "$tmp"
  case "$ssh_mode" in
    host-agent|mixed)
      printf '      - SSH_AUTH_SOCK=/run/cbox-ssh/agent.sock\n' >> "$tmp"
      ;;
  esac
  if _cbox_egress_active; then
    cat >> "$tmp" <<'EOF'
      - HTTP_PROXY=http://proxy:8888
      - HTTPS_PROXY=http://proxy:8888
      - http_proxy=http://proxy:8888
      - https_proxy=http://proxy:8888
      - NO_PROXY=localhost,127.0.0.1,::1
      - no_proxy=localhost,127.0.0.1,::1
EOF
  fi
  printf '    volumes:\n' >> "$tmp"
  _cbox_tz_mounts_into "$tmp"
  printf '      - %s:%s:rw\n' "$root" "$root" >> "$tmp"

  if [ "$claude_mode" = "mount" ]; then
    gen_claude_config_into "$eff/claude-config" "$claude_path"
    mkdir -p "$claude_path/hooks" "$claude_path/agents" "$claude_path/policies" "$claude_path/templates" "$claude_path/projects" "$claude_path/tasks" "$claude_path/session-env" "$claude_path/plugins" "$claude_path/file-history" "$claude_path/plans" "$claude_path/shell-snapshots" "$claude_path/agent-memory" "$claude_path/commands" "$claude_path/skills" "$claude_path/rules"
    [ -f "$claude_path/settings.json" ] || printf '{}\n' > "$claude_path/settings.json"
    [ -f "$HOME/.claude.json" ] || printf '{}\n' > "$HOME/.claude.json"
    [ -f "$claude_path/CLAUDE.md" ] || : > "$claude_path/CLAUDE.md"
    gen_claude_cbox_json_seed_into "$eff/claude-config/.claude.json" "$eff/state/claude-cbox.json"
    cat >> "$tmp" <<EOF
      - $claude_path:\${HOST_HOME}/.claude:rw
      - $claude_path/hooks:\${HOST_HOME}/.claude/hooks:ro
      - $claude_path/settings.json:\${HOST_HOME}/.claude/settings.json:rw
      - $INSTALL_DIR/generated/managed-settings.json:/etc/claude-code/managed-settings.json:ro
      - $HOME/.claude.json:\${HOST_HOME}/.claude.json:ro
      - $claude_path/CLAUDE.md:\${HOST_HOME}/.claude/CLAUDE.md:ro
      - $claude_path/agents:\${HOST_HOME}/.claude/agents:ro
      - $claude_path/policies:\${HOST_HOME}/.claude/policies:ro
      - $claude_path/templates:\${HOST_HOME}/.claude/templates:ro
      - $eff/claude-config:\${HOST_HOME}/.claude-cbox:rw
      - $claude_path/commands:\${HOST_HOME}/.claude-cbox/commands:ro
      - $claude_path/skills:\${HOST_HOME}/.claude-cbox/skills:ro
      - $claude_path/rules:\${HOST_HOME}/.claude-cbox/rules:ro
      - $claude_path/session-env:\${HOST_HOME}/.claude-cbox/session-env:rw
      - $claude_path/plugins:\${HOST_HOME}/.claude-cbox/plugins:rw
      - $claude_path/file-history:\${HOST_HOME}/.claude-cbox/file-history:rw
      - $claude_path/plans:\${HOST_HOME}/.claude-cbox/plans:rw
      - $claude_path/shell-snapshots:\${HOST_HOME}/.claude-cbox/shell-snapshots:rw
      - $claude_path/agent-memory:\${HOST_HOME}/.claude-cbox/agent-memory:rw
      - $claude_path/hooks:\${HOST_HOME}/.claude-cbox/hooks:ro
      - $claude_path/settings.json:\${HOST_HOME}/.claude-cbox/settings.json:rw
      - $claude_path/CLAUDE.md:\${HOST_HOME}/.claude-cbox/CLAUDE.md:ro
      - $claude_path/agents:\${HOST_HOME}/.claude-cbox/agents:ro
      - $claude_path/policies:\${HOST_HOME}/.claude-cbox/policies:ro
      - $claude_path/templates:\${HOST_HOME}/.claude-cbox/templates:ro
EOF
  else
    cat >> "$tmp" <<EOF
      - claude:\${HOST_HOME}/.claude
      - $INSTALL_DIR/generated/hooks:\${HOST_HOME}/.claude/hooks:ro
      - $INSTALL_DIR/generated/settings.json:\${HOST_HOME}/.claude/settings.json:rw
      - $INSTALL_DIR/generated/managed-settings.json:/etc/claude-code/managed-settings.json:ro
      - $INSTALL_DIR/generated/state/claude.json:\${HOST_HOME}/.claude.json:rw
      - $INSTALL_DIR/generated/claude/CLAUDE.md:\${HOST_HOME}/.claude/CLAUDE.md:ro
      - $INSTALL_DIR/generated/claude/agents:\${HOST_HOME}/.claude/agents:ro
      - $INSTALL_DIR/generated/claude/policies:\${HOST_HOME}/.claude/policies:ro
      - $INSTALL_DIR/generated/claude/templates:\${HOST_HOME}/.claude/templates:ro
EOF
  fi

  if [ "$session_scope" = "isolated" ]; then
    mkdir -p "$claude_path/projects/$slug"
    cat >> "$tmp" <<EOF
      - $claude_path/projects/$slug:\${HOST_HOME}/.claude/projects/$slug:rw
EOF
    if [ "$claude_mode" = "mount" ]; then
      if [ -L "$eff/claude-config/projects/$slug" ] || { [ -e "$eff/claude-config/projects/$slug" ] && [ ! -d "$eff/claude-config/projects/$slug" ]; }; then
        rm -f "$eff/claude-config/projects/$slug"
      fi
      mkdir -p "$eff/claude-config/projects/$slug"
      cat >> "$tmp" <<EOF
      - $claude_path/projects:\${HOST_HOME}/.claude-cbox/.host-projects:rw
      - $claude_path/tasks:\${HOST_HOME}/.claude-cbox/.host-tasks:rw
      - $claude_path/jobs:\${HOST_HOME}/.claude-cbox/.host-jobs:rw
      - $claude_path/projects/$slug:\${HOST_HOME}/.claude-cbox/projects/$slug:rw
EOF
    fi
  else
    cat >> "$tmp" <<EOF
      - $claude_path/projects:\${HOST_HOME}/.claude/projects:rw
EOF
    if [ "$claude_mode" = "mount" ]; then
      cat >> "$tmp" <<EOF
      - $claude_path/projects:\${HOST_HOME}/.claude-cbox/projects:rw
      - $claude_path/jobs:\${HOST_HOME}/.claude-cbox/jobs:rw
      - $claude_path/tasks:\${HOST_HOME}/.claude-cbox/tasks:rw
EOF
    fi
  fi

  if [ "$codex_mode" = "mount" ]; then
    _cbox_codex_precreate_ro_pins "$codex_path"
    cat >> "$tmp" <<EOF
      - $codex_path:\${HOST_HOME}/.codex:rw
      - $codex_path/config.toml:\${HOST_HOME}/.codex/config.toml:ro
      - $codex_path/AGENTS.md:\${HOST_HOME}/.codex/AGENTS.md:ro
      - $codex_path/cbox-host.config.toml:\${HOST_HOME}/.codex/cbox-host.config.toml:ro
EOF
  else
    cat >> "$tmp" <<'EOF'
      - codex:${HOST_HOME}/.codex
EOF
  fi
  cat >> "$tmp" <<EOF
      - claude-local:\${HOST_HOME}/.local:ro
      - codex-packages:\${HOST_HOME}/.codex/packages:ro
      - $eff/codex/cbox-container.config.toml:\${HOST_HOME}/.codex/cbox-container.config.toml:ro
      - $eff/codex/AGENTS.override.md:\${HOST_HOME}/.codex/AGENTS.override.md:ro
      - $eff/codex/hooks.json:\${HOST_HOME}/.codex/hooks.json:ro
EOF
  case "$venv_mode" in
    host)
      printf '      - %s:%s:ro\n' "$venv_path" "$venv_path" >> "$tmp"
      ;;
    volume)
      printf '      - venv:/opt/venv\n' >> "$tmp"
      ;;
  esac
  case "$ssh_mode" in
    host-agent)
      cat >> "$tmp" <<EOF
      - $agent_dir:/run/cbox-ssh:ro
      - $INSTALL_DIR/generated/ssh/config:\${HOST_HOME}/.ssh/config:ro
EOF
      ;;
    container-keys)
      cat >> "$tmp" <<'EOF'
      - ssh:${HOST_HOME}/.ssh
EOF
      ;;
    mixed)
      cat >> "$tmp" <<EOF
      - ssh:\${HOST_HOME}/.ssh
      - $agent_dir:/run/cbox-ssh:ro
EOF
      ;;
  esac
  if [ "${CBOX_GITCONFIG:-0}" = "1" ] && [ -f "$HOME/.gitconfig" ]; then
    cat >> "$tmp" <<EOF
      - $HOME/.gitconfig:\${HOST_HOME}/.gitconfig:ro
EOF
  fi
  if _cbox_proxy_active; then
    cat >> "$tmp" <<EOF
    networks:
      - internal
    depends_on:
      - proxy
  proxy:
    build:
      context: $eff
      dockerfile: Dockerfile.egress
    image: cbox-proxy-img:$(cat "$eff/Dockerfile.egress" "$eff/supervisord.conf" 2>/dev/null | sha256sum | awk '{print substr($1,1,12)}')
    restart: "$policy"
    networks:
      - internal
      - egress
    volumes:
      - $eff/proxy:/etc/cbox-generated:ro
    healthcheck:
      test: ["CMD-SHELL", "ip=127.0.0.1; [ -f /etc/cbox-generated/internal-ip ] && ip=\$\$(cat /etc/cbox-generated/internal-ip); nc -z -w 2 \"\$\$ip\" 8888 || nc -z -w 2 \"\$\$ip\" 1080"]
      interval: 10s
      timeout: 3s
      start_period: 10s
      retries: 3
EOF
  fi
  cat >> "$tmp" <<EOF
volumes:
  claude-local:
    external: true
    name: $(_cbox_bins_volume claude)
  codex-packages:
    external: true
    name: $(_cbox_bins_volume codex)
EOF
  if [ "$claude_mode" = "volume" ]; then
    cat >> "$tmp" <<EOF
  claude:
    name: cbox-p$p_hash-claude
EOF
  fi
  if [ "$codex_mode" = "volume" ]; then
    cat >> "$tmp" <<EOF
  codex:
    name: cbox-p$p_hash-codex
EOF
  fi
  if [ "$venv_mode" = "volume" ]; then
    cat >> "$tmp" <<EOF
  venv:
    name: cbox-p$p_hash-venv
EOF
  fi
  case "$ssh_mode" in
    container-keys|mixed)
      cat >> "$tmp" <<EOF
  ssh:
    name: cbox-p$p_hash-ssh
EOF
      ;;
  esac
  if _cbox_proxy_active; then
    cat >> "$tmp" <<'EOF'
networks:
  internal:
    internal: true
  egress: {}
EOF
  fi
  chmod 0644 "$tmp"
  mv "$tmp" "$eff/docker-compose.yml"
}

gen_compose_readonly_into() {
  local target="$1"; shift
  local w tmp
  tmp="$(mktemp "$(dirname "$target")/.cbox.XXXXXX")"
  {
    printf 'services:\n'
    printf '  cbox:\n'
    printf '    environment:\n'
    printf '      - CBOX_WORKSPACE_READONLY=1\n'
    printf '    volumes:\n'
    for w in "$@"; do
      [ -n "$w" ] || continue
      printf '      - type: bind\n'
      printf '        source: %s\n' "$w"
      printf '        target: %s\n' "$w"
      printf '        read_only: true\n'
    done
  } > "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$target"
}

gen_dockerignore() {
  {
    printf 'generated/\n'
    printf 'backups/\n'
    printf 'etc/\n'
    printf '.env\n'
    printf 'cbox.conf\n'
    printf '*.log\n'
    printf '.gitignore\n'
    printf 'README.md\n'
    printf 'LICENSE\n'
  } | _cbox_write "$INSTALL_DIR/.dockerignore"
}

gen_compose_gpu() {
  if [ "${CBOX_GPU:-0}" != "1" ]; then
    rm -f "$INSTALL_DIR/docker-compose.gpu.yml"
    return 0
  fi
  _cbox_write "$INSTALL_DIR/docker-compose.gpu.yml" <<'EOF'
services:
  cbox:
    deploy:
      resources:
        reservations:
          devices:
            - driver: cdi
              device_ids:
                - nvidia.com/gpu=all
EOF
}

gen_dockerfile_egress_into() {
  local effdir="$1"
  if ! _cbox_proxy_active; then
    rm -f "$effdir/Dockerfile.egress"
    return 0
  fi
  _cbox_write "$effdir/Dockerfile.egress" <<'EOF'
FROM alpine:3.20
RUN apk add --no-cache tinyproxy dante-server supervisor netcat-openbsd
RUN addgroup -S cboxsockd && adduser -S -D -H -G cboxsockd cboxsockd
RUN mkdir -p /etc/cbox-generated /run/cbox
COPY supervisord.conf /etc/supervisord.conf
ENTRYPOINT ["supervisord","-n","-c","/etc/supervisord.conf"]
EOF
}

gen_dockerfile_egress() {
  gen_dockerfile_egress_into "$INSTALL_DIR"
}

gen_supervisord_conf_into() {
  local effdir="$1"
  if ! _cbox_proxy_active; then
    rm -f "$effdir/supervisord.conf"
    return 0
  fi
  {
    printf '[supervisord]\n'
    printf 'nodaemon=true\n'
    printf 'logfile=/dev/null\n'
    printf 'logfile_maxbytes=0\n'
    printf 'pidfile=/run/supervisord.pid\n'
    if _cbox_egress_active; then
      printf '\n[program:tinyproxy]\n'
      printf 'command=tinyproxy -d -c /etc/cbox-generated/tinyproxy.conf\n'
      printf 'autorestart=true\n'
      printf 'startretries=3\n'
      printf 'stdout_logfile=/dev/stdout\n'
      printf 'stdout_logfile_maxbytes=0\n'
      printf 'stderr_logfile=/dev/stderr\n'
      printf 'stderr_logfile_maxbytes=0\n'
    fi
    if _cbox_netaccess_active; then
      printf '\n[program:sockd]\n'
      printf 'command=/usr/sbin/sockd -D -f /etc/cbox-generated/sockd.conf\n'
      printf 'autorestart=true\n'
      printf 'startretries=3\n'
      printf 'stdout_logfile=/dev/stdout\n'
      printf 'stdout_logfile_maxbytes=0\n'
      printf 'stderr_logfile=/dev/stderr\n'
      printf 'stderr_logfile_maxbytes=0\n'
    fi
  } | _cbox_write "$effdir/supervisord.conf"
}

gen_supervisord_conf() {
  gen_supervisord_conf_into "$INSTALL_DIR"
}

gen_tinyproxy_conf_into() {
  local effdir="$1"
  if ! _cbox_egress_active; then
    rm -f "$effdir/tinyproxy.conf"
    return 0
  fi
  local deny="No"
  if [ "${CBOX_EGRESS_MODE:-off}" = "allowlist" ]; then
    deny="Yes"
  fi
  {
    printf 'Port 8888\n'
    printf 'Listen 0.0.0.0\n'
    printf 'Timeout 3600\n'
    printf 'LogLevel Notice\n'
    printf 'MaxClients 64\n'
    printf 'FilterType ere\n'
    printf 'FilterDefaultDeny %s\n' "$deny"
    printf 'Filter "/etc/cbox-generated/egress-filter"\n'
    printf 'ConnectPort 443\n'
    if [ "${CBOX_SSH_MODE:-none}" != "none" ]; then
      printf 'ConnectPort 22\n'
    fi
  } | _cbox_write "$effdir/tinyproxy.conf"
}

gen_tinyproxy_conf() {
  gen_tinyproxy_conf_into "$INSTALL_DIR/generated/proxy"
}

gen_egress_filter_into() {
  local effdir="$1"
  if ! _cbox_egress_active; then
    rm -f "$effdir/egress-filter"
    return 0
  fi
  local mode="${CBOX_EGRESS_MODE:-off}" src line d esc have_ssh_github=0
  if [ "$mode" = "allowlist" ]; then
    src="$INSTALL_DIR/etc/egress-allowlist.txt"
  else
    src="$INSTALL_DIR/etc/egress-blocklist.txt"
  fi
  local -a domains=()
  while IFS=$' \t\r' read -r line _ || [ -n "$line" ]; do
    case "$line" in
      ""|'#'*) continue ;;
    esac
    domains+=("$line")
    if [ "$line" = "ssh.github.com" ]; then
      have_ssh_github=1
    fi
  done < "$src"
  if [ "$mode" = "allowlist" ] && [ "${CBOX_SSH_MODE:-none}" != "none" ] && [ "$have_ssh_github" = "0" ]; then
    domains+=("ssh.github.com")
  fi
  {
    for d in "${domains[@]}"; do
      esc="$(_cbox_ere_escape "$d")"
      printf '^([a-zA-Z0-9-]+\\.)*%s$\n' "$esc"
    done
  } | _cbox_write "$effdir/egress-filter"
}

gen_egress_filter() {
  gen_egress_filter_into "$INSTALL_DIR/generated/proxy"
}

_cbox_is_ipv4() {
  local ip="$1" IFS=. o1 o2 o3 o4
  case "$ip" in
    *[!0-9.]*|""|*..*|.*|*.) return 1 ;;
  esac
  read -r o1 o2 o3 o4 <<<"$ip"
  [ -n "$o4" ] || return 1
  for o in "$o1" "$o2" "$o3" "$o4"; do
    case "$o" in
      ""|*[!0-9]*) return 1 ;;
    esac
    [ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1
  done
  return 0
}

_cbox_is_ipv4_cidr() {
  local cidr="$1" ip prefix
  case "$cidr" in
    */*) ;;
    *) return 1 ;;
  esac
  ip="${cidr%/*}"
  prefix="${cidr#*/}"
  _cbox_is_ipv4 "$ip" || return 1
  case "$prefix" in
    ""|*[!0-9]*) return 1 ;;
  esac
  [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ]
}

gen_sockd_conf_into() {
  local effdir="$1" internal_ip="$2" internal_cidr="$3" targets_spec="${4:-}"
  local port="${CBOX_NETACCESS_SOCKS_PORT:-1080}"
  case "$port" in
    ""|*[!0-9]*) port=1080 ;;
    *) { [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; } || port=1080 ;;
  esac
  if ! _cbox_is_ipv4 "$internal_ip" || [ "$internal_ip" = "0.0.0.0" ]; then
    echo "cbox: gen_sockd_conf_into: invalid internal_ip '$internal_ip'" >&2
    return 1
  fi
  if ! _cbox_is_ipv4_cidr "$internal_cidr" || [ "${internal_cidr#*/}" -eq 0 ]; then
    echo "cbox: gen_sockd_conf_into: invalid internal_cidr '$internal_cidr'" >&2
    return 1
  fi
  local -a target_ips=() target_cidrs=()
  local entry ep cidr
  for entry in $targets_spec; do
    case "$entry" in
      *,*)
        ep="${entry%%,*}"
        cidr="${entry#*,}"
        if [ -z "$ep" ] || [ -z "$cidr" ] || ! _cbox_is_ipv4 "$ep" || [ "$ep" = "0.0.0.0" ] || ! _cbox_is_ipv4_cidr "$cidr" || [ "${cidr#*/}" -eq 0 ]; then
          echo "cbox: gen_sockd_conf_into: skipping malformed target '$entry'" >&2
          continue
        fi
        target_ips+=("$ep")
        target_cidrs+=("$cidr")
        ;;
      *)
        if ! _cbox_is_ipv4_cidr "$entry" || [ "${entry#*/}" -lt 8 ] || [ "${entry%/*}" = "0.0.0.0" ]; then
          echo "cbox: gen_sockd_conf_into: skipping malformed target '$entry'" >&2
          continue
        fi
        target_cidrs+=("$entry")
        ;;
    esac
  done
  {
    printf 'logoutput: stderr\n'
    printf 'internal: %s port = %s\n' "$internal_ip" "$port"
    if [ "${#target_ips[@]}" -gt 0 ]; then
      for ep in "${target_ips[@]}"; do
        printf 'external: %s\n' "$ep"
      done
      printf 'external.rotation: route\n'
    else
      printf 'external: %s\n' "$internal_ip"
    fi
    printf 'socksmethod: none\n'
    printf 'clientmethod: none\n'
    printf 'user.privileged: root\n'
    printf 'user.notprivileged: cboxsockd\n'
    printf '\n'
    printf 'client pass {\n'
    printf '  from: %s to: %s/32\n' "$internal_cidr" "$internal_ip"
    printf '  log: error\n'
    printf '}\n'
    printf 'client block {\n'
    printf '  from: 0.0.0.0/0 to: 0.0.0.0/0\n'
    printf '  log: error\n'
    printf '}\n'
    printf '\n'
    if [ "${#target_cidrs[@]}" -gt 0 ]; then
      for cidr in "${target_cidrs[@]}"; do
        printf 'socks pass {\n'
        printf '  from: %s to: %s\n' "$internal_cidr" "$cidr"
        printf '  command: connect\n'
        printf '  log: connect disconnect error\n'
        printf '}\n'
      done
    fi
    printf 'socks block {\n'
    printf '  from: 0.0.0.0/0 to: 0.0.0.0/0\n'
    printf '  log: error\n'
    printf '}\n'
  } | _cbox_write "$effdir/sockd.conf"
  printf '%s\n' "$internal_ip" | _cbox_write "$effdir/internal-ip"
}

_cbox_proxy_net_ip() {
  local container_id="$1" network_name="$2" out
  [ -n "$container_id" ] && [ -n "$network_name" ] || { printf ''; return 0; }
  case "$network_name" in
    [A-Za-z0-9]*) ;;
    *) printf ''; return 0 ;;
  esac
  case "$network_name" in
    *[!A-Za-z0-9_.-]*) printf ''; return 0 ;;
  esac
  out="$(docker inspect -f "{{with index .NetworkSettings.Networks \"$network_name\"}}{{.IPAddress}}{{end}}" "$container_id" 2>/dev/null)" || out=""
  printf '%s' "$out"
}

gen_ssh_config() {
  if [ "${CBOX_SSH_MODE:-none}" = "none" ]; then
    rm -f "$INSTALL_DIR/generated/ssh/config"
    return 0
  fi
  {
    printf 'Host github.com\n'
    printf '  HostName ssh.github.com\n'
    printf '  Port 443\n'
    printf '  User git\n'
    if _cbox_egress_active; then
      printf '  ProxyCommand socat - PROXY:proxy:%%h:%%p,proxyport=8888\n'
    fi
    printf '  ServerAliveInterval 60\n'
    printf '  ServerAliveCountMax 3\n'
    printf '  StrictHostKeyChecking accept-new\n'
  } | _cbox_write "$INSTALL_DIR/generated/ssh/config"
}

gen_claude_json_seed() {
  local target="$INSTALL_DIR/generated/state/claude.json" out
  if [ -e "$target" ]; then
    return 0
  fi
  local shim_mode="${CBOX_CODEX_PROGRESS_MODE:-off}"
  [ "${CBOX_CLAUDE_MODE:-mount}" = mount ] || shim_mode=off
  local progress_flag="off"
  [ "$shim_mode" = shim ] && progress_flag="on"
  local servers_file="$INSTALL_DIR/etc/mcp/delegates.json"
  local expanded hooks_dir="$HOME/.claude/hooks" mcp_json
  expanded="$(canonical_expand "${CBOX_MCP_SERVERS:-all}" "$(mcp_all_names)")"
  mcp_json="$(python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$servers_file" "$expanded" "$hooks_dir" "$progress_flag" claude)"
  out="$(python3 - "$mcp_json" <<'PY'
import json
import sys

mcp = json.loads(sys.argv[1])
sys.stdout.write(json.dumps({"hasCompletedOnboarding": True, "mcpServers": mcp}, separators=(",", ":")))
PY
)"
  printf '%s\n' "$out" | _cbox_write "$target"
}

_cbox_seed_adopt_nofollow() {
  python3 - "$1" "$2" <<'PY'
import errno
import json
import os
import sys

migrate, target = sys.argv[1], sys.argv[2]
try:
    fd = os.open(migrate, os.O_RDONLY | os.O_NOFOLLOW)
except OSError:
    sys.exit(0)
try:
    with os.fdopen(fd, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError):
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
body = json.dumps(data, separators=(",", ":")).encode("utf-8")
try:
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
except OSError as e:
    if e.errno == errno.ELOOP:
        sys.exit(0)
    sys.exit(0)
with os.fdopen(fd, "wb") as fh:
    fh.write(body)
PY
}

gen_claude_cbox_json_seed_into() {
  local target="$1" legacy="${2:-}" lock lockdir
  lockdir="$(dirname "$(dirname "$target")")/state"
  mkdir -p "$lockdir" 2>/dev/null || true
  lock="$lockdir/.claude.json.lock"
  if command -v flock >/dev/null 2>&1 && [ ! -L "$lock" ] && ( : 9> "$lock" ) 2>/dev/null; then
    (
      exec 9> "$lock"
      flock -w 10 9 || true
      _gen_claude_cbox_json_seed_render "$target" "$legacy"
    )
  else
    _gen_claude_cbox_json_seed_render "$target" "$legacy"
  fi
}

_gen_claude_cbox_json_seed_render() {
  local target="$1" legacy="${2:-}" migrate out
  migrate="$(dirname "$target")/.claude.json.migrate"
  if [ -e "$migrate" ] || [ -L "$migrate" ]; then
    _cbox_seed_adopt_nofollow "$migrate" "$target"
    rm -f "$migrate" 2>/dev/null || true
  elif [ ! -e "$target" ] && [ ! -L "$target" ] && [ -n "$legacy" ] && [ -f "$legacy" ] && [ ! -L "$legacy" ]; then
    cp "$legacy" "$target" 2>/dev/null || true
  fi
  local shim_mode="${CBOX_CODEX_PROGRESS_MODE:-off}"
  [ "${CBOX_CLAUDE_MODE:-mount}" = mount ] || shim_mode=off
  local progress_flag="off"
  [ "$shim_mode" = shim ] && progress_flag="on"
  local servers_file="$INSTALL_DIR/etc/mcp/delegates.json"
  local expanded hooks_dir="$HOME/.claude/hooks" mcp_json
  expanded="$(canonical_expand "${CBOX_MCP_SERVERS:-all}" "$(mcp_all_names)")"
  mcp_json="$(python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$servers_file" "$expanded" "$hooks_dir" "$progress_flag" claude)"
  out="$(python3 - "$mcp_json" "$target" <<'PY'
import json
import sys

import os

mcp = json.loads(sys.argv[1])
cur = {}
try:
    fd = os.open(sys.argv[2], os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "r", encoding="utf-8") as fh:
        cur = json.load(fh)
except (OSError, ValueError):
    cur = {}
if not isinstance(cur, dict):
    cur = {}
cur["hasCompletedOnboarding"] = True
cur["mcpServers"] = mcp
sys.stdout.write(json.dumps(cur, separators=(",", ":")))
PY
)"
  printf '%s\n' "$out" | _cbox_write "$target"
}

gen_claude_config_into() {
  local statedir="$1" claude_path="$2" j b
  mkdir -p "$statedir" "$claude_path/jobs"
  chmod 700 "$statedir"
  if [ -d "$statedir/jobs" ]; then
    for j in "$statedir/jobs"/*; do
      [ -e "$j" ] || continue
      [ -L "$j" ] && continue
      b="$(basename "$j")"
      [ "$b" = settled ] && continue
      if [ ! -e "$claude_path/jobs/$b" ]; then
        mv "$j" "$claude_path/jobs/" 2>/dev/null || { cp -a "$j" "$claude_path/jobs/$b" 2>/dev/null && rm -rf "$j"; } || true
      fi
    done
    if [ -d "$statedir/jobs/settled" ] && [ ! -L "$statedir/jobs/settled" ]; then
      mkdir -p "$claude_path/jobs/settled"
      for j in "$statedir/jobs/settled"/*; do
        [ -e "$j" ] || continue
        [ -L "$j" ] && continue
        b="$(basename "$j")"
        if [ ! -e "$claude_path/jobs/settled/$b" ]; then
          mv "$j" "$claude_path/jobs/settled/" 2>/dev/null || { cp -a "$j" "$claude_path/jobs/settled/$b" 2>/dev/null && rm -rf "$j"; } || true
        fi
      done
      rmdir "$statedir/jobs/settled" 2>/dev/null || true
    fi
    rmdir "$statedir/jobs" 2>/dev/null || true
  fi
  mkdir -p "$statedir/projects" "$statedir/tasks" "$statedir/jobs" "$statedir/limit-watch"
  rm -f "$statedir/.credentials.json.new" 2>/dev/null || true
  ln -s "$HOME/.claude/.credentials.json" "$statedir/.credentials.json.new" 2>/dev/null || true
  if [ -L "$statedir/.credentials.json.new" ]; then
    mv -T "$statedir/.credentials.json.new" "$statedir/.credentials.json" 2>/dev/null || rm -f "$statedir/.credentials.json.new"
  fi
  if [ ! -e "$statedir/history.jsonl" ] && [ ! -L "$statedir/history.jsonl" ]; then
    ln -s "$HOME/.claude/history.jsonl" "$statedir/history.jsonl" 2>/dev/null || true
  fi
}

gen_settings_volume() {
  local src="$INSTALL_DIR/etc/claude/settings.merge.json" out
  if [ ! -f "$src" ]; then
    echo "gen_settings_volume: missing $src" >&2
    return 1
  fi
  out="$(python3 - "$src" "$HOME" <<'PY'
import json
import sys

src, home = sys.argv[1], sys.argv[2]
with open(src) as fh:
    text = fh.read()
text = text.replace("@HOME@", home)
settings = json.loads(text)
sys.stdout.write(json.dumps(settings, separators=(",", ":")))
PY
)"
  printf '%s\n' "$out" | _cbox_write "$INSTALL_DIR/generated/settings.json"
}

gen_managed_settings() {
  local src="$INSTALL_DIR/etc/claude/managed-settings.merge.json" out
  if [ ! -f "$src" ]; then
    echo "gen_managed_settings: missing $src" >&2
    return 1
  fi
  out="$(python3 - "$src" "$HOME" <<'PY'
import json
import sys

src, home = sys.argv[1], sys.argv[2]
with open(src) as fh:
    text = fh.read()
text = text.replace("@HOME@", home)
settings = json.loads(text)
sys.stdout.write(json.dumps(settings, separators=(",", ":")))
PY
)"
  printf '%s\n' "$out" | _cbox_write "$INSTALL_DIR/generated/managed-settings.json"
}

gen_scope_json() {
  local out
  out="$(python3 - "${CBOX_WORKSPACES:-}" <<'PY'
import json
import sys

roots = [w for w in sys.argv[1].split() if w]
sys.stdout.write(json.dumps({"allowed_roots": roots, "allow_danger_full_access": True}, separators=(",", ":")))
PY
)"
  printf '%s\n' "$out" | _cbox_write "$INSTALL_DIR/generated/hooks/codex_scope.container.json"
}

gen_claude_assets() {
  mkdir -p "$INSTALL_DIR/generated/claude/agents" "$INSTALL_DIR/generated/claude/policies" "$INSTALL_DIR/generated/claude/templates"
  if [ ! -e "$INSTALL_DIR/generated/claude/CLAUDE.md" ]; then
    if [ -f "$INSTALL_DIR/etc/claude/CLAUDE.md" ]; then
      cp "$INSTALL_DIR/etc/claude/CLAUDE.md" "$INSTALL_DIR/generated/claude/CLAUDE.md"
    else
      : > "$INSTALL_DIR/generated/claude/CLAUDE.md"
    fi
  fi
}

_cbox_codex_profile_workspaces() {
  local mode="${1:-global}" root="${2:-}"
  if [ "$mode" = isolated ]; then
    [ -n "$root" ] && printf '%s\n' "$root"
    return 0
  fi
  local -a ws=()
  read -r -a ws <<< "${CBOX_WORKSPACES:-}"
  local w
  for w in "${ws[@]}"; do
    [ -n "$w" ] || continue
    printf '%s\n' "$w"
  done
}

_cbox_codex_mcp_claude_entry() {
  local hooks_path="$1"
  local delegates_file="$INSTALL_DIR/etc/mcp/delegates.json"
  [ -f "$delegates_file" ] || return 0
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$delegates_file" all "$hooks_path" off codex
}

_cbox_codex_mcp_toml_blocks() {
  local rendered="$1"
  [ -n "$rendered" ] || return 0
  python3 -c '
import json
import sys

rendered = json.loads(sys.argv[1])


def toml_string(v):
    return json.dumps(v)


def toml_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, str):
        return toml_string(v)
    if isinstance(v, list):
        return "[" + ", ".join(toml_value(item) for item in v) + "]"
    if isinstance(v, dict):
        pairs = ", ".join(
            "%s = %s" % (toml_string(k), toml_value(val))
            for k, val in v.items()
        )
        return "{ " + pairs + " }"
    raise SystemExit(
        "gen_codex_profile_into: delegate field of unsupported type %r"
        % type(v).__name__
    )


table_key_overrides = {"ask-claude": "claude"}
for name in sorted(rendered.keys()):
    spec = rendered[name]
    table = table_key_overrides.get(name, name)
    print()
    print("[mcp_servers.%s]" % table)
    for field in ("command", "args", "env", "startup_timeout_sec", "tool_timeout_sec"):
        if field in spec:
            print("%s = %s" % (field, toml_value(spec[field])))
' "$rendered"
}

gen_codex_profile_into() {
  local outdir="$1" mode="${2:-global}" root="${3:-}"
  local hooks_path="$HOME/.claude/hooks"
  local codex_model="gpt-5.6-terra"
  mkdir -p "$outdir"
  local tmp
  tmp="$(mktemp "$outdir/.cbox.XXXXXX")"
  {
    printf 'model = "%s"\n' "$codex_model"
    printf 'model_reasoning_effort = "xhigh"\n'
    printf 'approval_policy = "never"\n'
    printf 'sandbox_mode = "danger-full-access"\n'
    printf 'hide_agent_reasoning = true\n'
    printf 'check_for_update_on_startup = false\n'
    printf 'project_doc_max_bytes = 65536\n'
    printf 'notify = ["python3", %s]\n' "$(_cbox_toml_string "$hooks_path/codex_notify.py")"
    printf '\n[analytics]\n'
    printf 'enabled = false\n'
    printf '\n[otel]\n'
    printf 'log_user_prompt = false\n'
    local w
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      printf '\n[projects.%s]\n' "$(_cbox_toml_string "$w")"
      printf 'trust_level = "trusted"\n'
    done < <(_cbox_codex_profile_workspaces "$mode" "$root")
    if [ "${CBOX_CODEX_MCP:-0}" = 1 ]; then
      local codex_delegates
      codex_delegates="$(_cbox_codex_mcp_claude_entry "$hooks_path")"
      _cbox_codex_mcp_toml_blocks "$codex_delegates"
    fi
  } > "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$outdir/cbox-container.config.toml"
}

gen_codex_hooks_json_into() {
  local outdir="$1"
  local hooks_path="$HOME/.claude/hooks"
  mkdir -p "$outdir"
  local tmp
  tmp="$(mktemp "$outdir/.cbox.XXXXXX")"
  python3 -c '
import json
import sys

hooks_path = sys.argv[1]
command = "python3 " + hooks_path + "/continuity_session_start.py"
doc = {
    "hooks": {
        "SessionStart": [
            {"hooks": [{"type": "command", "command": command}]}
        ]
    }
}
sys.stdout.write(json.dumps(doc, indent=2) + "\n")
' "$hooks_path" > "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$outdir/hooks.json"
}

_cbox_codex_agents_preamble() {
  cat <<'EOF'
ENGINE NOTE: this file plays the role CLAUDE.md plays for Claude Code - the
same global guidance, rendered for the codex engine. Where the source
material below refers to "Claude subagents" or the Agent tool, no such
mechanism exists here: your delegate for handing off a task is the
ask-claude MCP tool (model haiku, sonnet, opus, or fable; effort low,
medium, high, or max). Workflow and ledger/continuity conventions
(LEDGER.md, PROGRESS_YYYY_MM_DD.md, CHANGELOG.md) are identical across
engines.
EOF
}

_cbox_codex_agents_delegate_boundary() {
  cat <<'EOF'
DELEGATE WRITE BOUNDARY (codex wording): when you are the delegated side of
an ask-claude or codex-* relay call, do not write .cbox brain files
(LEDGER.md, PROGRESS_YYYY_MM_DD.md, CHANGELOG.md, OPEN_QUESTIONS.md,
DIARY.md) directly - return a distillate in your final message; the driver
that invoked you decides what is durable and writes it.
EOF
}

gen_codex_agents_into() {
  local outdir="$1" src tmp size
  local kernel_src="$INSTALL_DIR/etc/hooks/conduct-kernel.txt"
  [ -f "$kernel_src" ] || die "gen_codex_agents_into: missing conduct-kernel source $kernel_src"
  mkdir -p "$outdir"
  tmp="$(mktemp "$outdir/.cbox.XXXXXX")"
  if [ -s "$HOME/.codex/AGENTS.override.md" ]; then
    src="$HOME/.codex/AGENTS.override.md"
  elif [ -s "$HOME/.codex/AGENTS.md" ]; then
    src="$HOME/.codex/AGENTS.md"
  else
    src=""
  fi
  if [ -n "$src" ]; then
    printf '===== folded in from host %s =====\n\n' "$src" >> "$tmp"
    cat "$src" >> "$tmp"
    printf '\n\n===== end fold-in from host %s =====\n\n' "$src" >> "$tmp"
  fi
  _cbox_codex_agents_preamble >> "$tmp"
  printf '\n' >> "$tmp"
  local kernel_rendered
  kernel_rendered="$(mktemp "$outdir/.cbox.XXXXXX")"
  _cbox_apply_name_substitution "$kernel_src" "$kernel_rendered"
  cat "$kernel_rendered" >> "$tmp"
  rm -f "$kernel_rendered"
  printf '\n' >> "$tmp"
  _cbox_codex_agents_delegate_boundary >> "$tmp"
  size="$(wc -c < "$tmp")"
  if [ "$size" -ge 64000 ]; then
    rm -f "$tmp"
    die "gen_codex_agents_into: rendered AGENTS.override.md is $size bytes (>= 64000 limit)"
  fi
  chmod 0644 "$tmp"
  mv "$tmp" "$outdir/AGENTS.override.md"
}

gen_hooks_dir() {
  local kernel_rendered
  _cbox_write "$INSTALL_DIR/generated/hooks/codex_mode_guard.py" < "$INSTALL_DIR/etc/hooks/codex_mode_guard.py"
  _cbox_write "$INSTALL_DIR/generated/hooks/agent_label_guard.py" < "$INSTALL_DIR/etc/hooks/agent_label_guard.py"
  _cbox_write "$INSTALL_DIR/generated/hooks/code_hygiene_guard.py" < "$INSTALL_DIR/etc/hooks/code_hygiene_guard.py"
  _cbox_write "$INSTALL_DIR/generated/hooks/commit_guard.py" < "$INSTALL_DIR/etc/hooks/commit_guard.py"
  _cbox_write "$INSTALL_DIR/generated/hooks/continuity_commit_log.py" < "$INSTALL_DIR/etc/hooks/continuity_commit_log.py"
  _cbox_write "$INSTALL_DIR/generated/hooks/continuity_ledger_sweep.py" < "$INSTALL_DIR/etc/hooks/continuity_ledger_sweep.py"
  _cbox_write "$INSTALL_DIR/generated/hooks/continuity_session_digest.py" < "$INSTALL_DIR/etc/hooks/continuity_session_digest.py"
  _cbox_write "$INSTALL_DIR/generated/hooks/continuity_session_start.py" < "$INSTALL_DIR/etc/hooks/continuity_session_start.py"
  _cbox_write "$INSTALL_DIR/generated/hooks/orchestrator-global.txt" < "$INSTALL_DIR/etc/hooks/orchestrator-global.txt"
  kernel_rendered="$(mktemp "$INSTALL_DIR/generated/hooks/.cbox.XXXXXX")"
  _cbox_apply_name_substitution "$INSTALL_DIR/etc/hooks/conduct-kernel.txt" "$kernel_rendered"
  _cbox_write "$INSTALL_DIR/generated/hooks/conduct-kernel.txt" < "$kernel_rendered"
  rm -f "$kernel_rendered"
  _cbox_write "$INSTALL_DIR/generated/hooks/session-core.txt" < "$INSTALL_DIR/etc/hooks/session-core.txt"
  _cbox_write "$INSTALL_DIR/generated/hooks/ask_claude_mcp.py" < "$INSTALL_DIR/etc/codex/ask_claude_mcp.py"
  _cbox_write "$INSTALL_DIR/generated/hooks/codex_notify.py" < "$INSTALL_DIR/etc/codex/codex_notify.py"
  _cbox_write "$INSTALL_DIR/generated/hooks/codex_bump_probe.sh" < "$INSTALL_DIR/etc/codex/codex_bump_probe.sh"
  _cbox_write "$INSTALL_DIR/generated/hooks/codex_mcp_shim.py" < "$INSTALL_DIR/etc/mcp/codex_mcp_shim.py"
  _cbox_write "$INSTALL_DIR/generated/hooks/session_scope_farm.py" < "$INSTALL_DIR/etc/hooks/session_scope_farm.py"
  _cbox_write "$INSTALL_DIR/generated/hooks/limit_watchdog.py" < "$INSTALL_DIR/etc/hooks/limit_watchdog.py"
  _cbox_write "$INSTALL_DIR/generated/hooks/session_pane_map.py" < "$INSTALL_DIR/etc/hooks/session_pane_map.py"
  gen_scope_json
}

gen_bashrc() {
  printf 'export CBOX_DIR="%s"\n' "$INSTALL_DIR"
  printf 'export CBOX_SERVICE="cbox"\n\n'
  cat <<'EOF'
claude() {
  "$CBOX_DIR/cbox" run claude "$@"
}

codex() {
  "$CBOX_DIR/cbox" run codex "$@"
}

cbox-stop() {
  "$CBOX_DIR/cbox" down
}

cbox-shell() {
  "$CBOX_DIR/cbox" run bash "$@"
}
EOF
}

CBOX_CONTEXT_MANIFEST_VERSION=1

_cbox_context_manifest_sha() {
  local f="$1"
  [ -f "$f" ] || { printf ''; return 0; }
  sha256sum "$f" | awk '{print $1}'
}

gen_context_manifest_into() {
  local outdir="$1"
  mkdir -p "$outdir"
  local kernel_src="$INSTALL_DIR/etc/hooks/conduct-kernel.txt"
  local core_src="$INSTALL_DIR/etc/hooks/session-core.txt"
  local claude_md_src="$INSTALL_DIR/etc/claude/CLAUDE.md"
  local loader_src="$INSTALL_DIR/etc/hooks/continuity_session_start.py"
  local codex_agents="$INSTALL_DIR/generated/codex/AGENTS.override.md"
  local shim_src="$INSTALL_DIR/etc/mcp/codex_mcp_shim.py"
  local hooks_json="$INSTALL_DIR/etc/claude/settings.merge.json"
  local profile="${CBOX_CONTEXT_PROFILE:-full}"
  local tmp
  tmp="$(mktemp "$outdir/.cbox.XXXXXX")"
  {
    printf '{\n'
    printf '  "version": %s,\n' "$CBOX_CONTEXT_MANIFEST_VERSION"
    printf '  "profile": "%s",\n' "$profile"
    printf '  "digests": {\n'
    printf '    "conduct_kernel": "%s",\n' "$(_cbox_context_manifest_sha "$kernel_src")"
    printf '    "session_core": "%s",\n' "$(_cbox_context_manifest_sha "$core_src")"
    printf '    "claude_md_source": "%s",\n' "$(_cbox_context_manifest_sha "$claude_md_src")"
    printf '    "loader": "%s",\n' "$(_cbox_context_manifest_sha "$loader_src")"
    printf '    "codex_agents_render": "%s",\n' "$(_cbox_context_manifest_sha "$codex_agents")"
    printf '    "codex_shim": "%s",\n' "$(_cbox_context_manifest_sha "$shim_src")"
    printf '    "settings_merge": "%s"\n' "$(_cbox_context_manifest_sha "$hooks_json")"
    printf '  }\n'
    printf '}\n'
  } > "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$outdir/context-manifest.json"
}

_cbox_context_manifest_verify() {
  local outdir="${1:-$INSTALL_DIR/generated}"
  local mf="$outdir/context-manifest.json"
  [ -f "$mf" ] || die "context manifest missing at $mf - run regen"
  local kernel_src="$INSTALL_DIR/etc/hooks/conduct-kernel.txt"
  local core_src="$INSTALL_DIR/etc/hooks/session-core.txt"
  local claude_md_src="$INSTALL_DIR/etc/claude/CLAUDE.md"
  local loader_src="$INSTALL_DIR/etc/hooks/continuity_session_start.py"
  local codex_agents="$INSTALL_DIR/generated/codex/AGENTS.override.md"
  local shim_src="$INSTALL_DIR/etc/mcp/codex_mcp_shim.py"
  local hooks_json="$INSTALL_DIR/etc/claude/settings.merge.json"
  python3 -c '
import json
import sys

mf = sys.argv[1]
pairs = [
    ("conduct_kernel", sys.argv[2]),
    ("session_core", sys.argv[3]),
    ("claude_md_source", sys.argv[4]),
    ("loader", sys.argv[5]),
    ("codex_agents_render", sys.argv[6]),
    ("codex_shim", sys.argv[7]),
    ("settings_merge", sys.argv[8]),
]
try:
    with open(mf, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as exc:
    sys.stderr.write("context manifest malformed: %s\n" % exc)
    sys.exit(1)
digests = data.get("digests", {})
mismatches = []
for key, have in pairs:
    want = digests.get(key)
    if want is None:
        mismatches.append("%s: missing from manifest" % key)
        continue
    if want != have:
        mismatches.append("%s: manifest=%s actual=%s" % (key, want, have))
if mismatches:
    sys.stderr.write("context manifest drift:\n" + "\n".join(mismatches) + "\n")
    sys.exit(1)
sys.exit(0)
' "$mf" \
    "$(_cbox_context_manifest_sha "$kernel_src")" \
    "$(_cbox_context_manifest_sha "$core_src")" \
    "$(_cbox_context_manifest_sha "$claude_md_src")" \
    "$(_cbox_context_manifest_sha "$loader_src")" \
    "$(_cbox_context_manifest_sha "$codex_agents")" \
    "$(_cbox_context_manifest_sha "$shim_src")" \
    "$(_cbox_context_manifest_sha "$hooks_json")" \
    || die "context manifest drifted - regenerate with ./setup.sh update claude-md (or the relevant section)"
}

_cbox_conf_set_tpl_sha() {
  local conf="${1:-$INSTALL_DIR/cbox.conf}" sha tmp confdir
  sha="$(_cbox_tpl_sha)"
  confdir="$(dirname "$conf")"
  tmp="$(mktemp "$confdir/.cbox.XXXXXX")"
  if [ -f "$conf" ] && grep -q '^CBOX_TPL_SHA=' "$conf"; then
    sed "s|^CBOX_TPL_SHA=.*|CBOX_TPL_SHA=$sha|" "$conf" > "$tmp"
  elif [ -f "$conf" ]; then
    cat "$conf" > "$tmp"
    if [ -s "$tmp" ] && [ -n "$(tail -c1 "$tmp")" ]; then
      printf '\n' >> "$tmp"
    fi
    printf 'CBOX_TPL_SHA=%s\n' "$sha" >> "$tmp"
  else
    printf 'CBOX_TPL_SHA=%s\n' "$sha" > "$tmp"
  fi
  chmod 0644 "$tmp"
  mv "$tmp" "$conf"
}

regen_all() {
  mkdir -p "$INSTALL_DIR/generated/hooks" "$INSTALL_DIR/generated/state" "$INSTALL_DIR/generated/ssh" "$INSTALL_DIR/generated/proxy" "$INSTALL_DIR/backups"
  gen_env_file
  local _digest
  _digest="$(_cbox_resolve_base_digest ubuntu:24.04)" || die "cannot resolve base image digest and no local image - network required for first build"
  gen_dockerfile_into "$INSTALL_DIR" "$_digest"
  gen_image_inputs "$INSTALL_DIR" "$_digest"
  gen_dockerignore
  gen_compose
  local -a _ro_ws=()
  read -r -a _ro_ws <<< "${CBOX_WORKSPACES:-}"
  gen_compose_readonly_into "$INSTALL_DIR/docker-compose.readonly.yml" "${_ro_ws[@]}"
  gen_compose_gpu
  gen_dockerfile_egress
  gen_supervisord_conf
  gen_tinyproxy_conf
  gen_egress_filter
  gen_ssh_config
  gen_hooks_dir
  gen_settings_volume
  gen_managed_settings
  gen_codex_profile_into "$INSTALL_DIR/generated/codex" global
  gen_codex_agents_into "$INSTALL_DIR/generated/codex"
  gen_codex_hooks_json_into "$INSTALL_DIR/generated/codex"
  if [ "${CBOX_CLAUDE_MODE:-mount}" = "volume" ]; then
    gen_claude_assets
    gen_claude_json_seed
  fi
  gen_context_manifest_into "$INSTALL_DIR/generated"
  _cbox_conf_set_tpl_sha
}
