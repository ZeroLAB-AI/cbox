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

FN_FILE="$TMPBASE/sidecars_fn.sh"
awk '/^_cbox_stop_with_sidecars\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" > "$FN_FILE"
[ -s "$FN_FILE" ] || _fail "could not extract _cbox_stop_with_sidecars() from cbox"

_write_docker_stub() {
  local bindir="$1" project="$2" ids="$3"
  mkdir -p "$bindir"
  cat > "$bindir/docker" << EOF
#!/usr/bin/env bash
LOG="\$STUB_LOG"
case "\$1" in
  inspect)
    echo "inspect \$*" >> "\$LOG"
    printf '%s\n' "$project"
    ;;
  ps)
    echo "ps \$*" >> "\$LOG"
    printf '%s\n' "$ids" | tr ' ' '\n'
    ;;
  stop)
    echo "stop \$*" >> "\$LOG"
    ;;
  *)
    echo "unknown \$*" >> "\$LOG"
    ;;
esac
EOF
  chmod +x "$bindir/docker"
}

test_stops_every_container_in_the_compose_project() {
  local bindir="$TMPBASE/bin_project" log="$TMPBASE/log_project.txt"
  : > "$log"
  _write_docker_stub "$bindir" "cbox-pdeadbeef0011" "idA idB idC"
  (
    PATH="$bindir:$PATH"
    STUB_LOG="$log"
    export PATH STUB_LOG
    . "$FN_FILE"
    _cbox_stop_with_sidecars "cidX"
  )
  grep -q '^inspect inspect --format .* cidX$' "$log" \
    || _fail "expected an inspect call for cidX, log was:
$(cat "$log")"
  grep -q '^ps ps -q --filter label=com.docker.compose.project=cbox-pdeadbeef0011 --filter label=cbox.kind$' "$log" \
    || _fail "expected a ps -q --filter label=com.docker.compose.project=cbox-pdeadbeef0011 --filter label=cbox.kind call, log was:
$(cat "$log")"
  grep -q '^stop stop idA idB idC$' "$log" \
    || _fail "expected docker stop to be called with every sidecar id (idA idB idC), log was:
$(cat "$log")"
  grep -q '^stop stop cidX$' "$log" \
    && _fail "must not also fall back to a direct docker stop cidX once the project branch handled it:
$(cat "$log")"
  _ok "compose project label present: stops every container id returned for that project, not just the given id"
}

test_stops_the_proxy_sidecar_carrying_cbox_kind_proxy_label() {
  local bindir="$TMPBASE/bin_proxy" log="$TMPBASE/log_proxy.txt"
  : > "$log"
  _write_docker_stub "$bindir" "cbox-pdeadbeef0033" "cidMain cidProxy"
  (
    PATH="$bindir:$PATH"
    STUB_LOG="$log"
    export PATH STUB_LOG
    . "$FN_FILE"
    _cbox_stop_with_sidecars "cidMain"
  )
  grep -q '^ps ps -q --filter label=com.docker.compose.project=cbox-pdeadbeef0033 --filter label=cbox.kind$' "$log" \
    || _fail "expected the project-wide cbox.kind filter query, log was:
$(cat "$log")"
  grep -q '^stop stop cidMain cidProxy$' "$log" \
    || _fail "expected the proxy sidecar (cbox.kind=proxy) to be stopped alongside the main container, log was:
$(cat "$log")"
  _ok "proxy container carrying cbox.kind=proxy is matched by the label-present filter and stopped as a sidecar"
}

test_forged_foreign_project_name_stops_only_given_id() {
  local bindir="$TMPBASE/bin_forged" log="$TMPBASE/log_forged.txt"
  : > "$log"
  _write_docker_stub "$bindir" "evil-unrelated-project" "otherA otherB"
  (
    PATH="$bindir:$PATH"
    STUB_LOG="$log"
    export PATH STUB_LOG
    . "$FN_FILE"
    _cbox_stop_with_sidecars "cidF"
  )
  grep -q '^ps ' "$log" \
    && _fail "must not query docker ps for a project name outside the cbox naming convention, log was:
$(cat "$log")"
  grep -q '^stop stop cidF$' "$log" \
    || _fail "expected a direct docker stop cidF fallback for a forged/foreign project name, log was:
$(cat "$log")"
  grep -q '^stop stop otherA otherB$' "$log" \
    && _fail "must never stop sibling ids from a project name outside the cbox naming convention, log was:
$(cat "$log")"
  _ok "forged/foreign project name (not cbox or cbox-p<hash>): stops only the given container id"
}

test_stops_only_the_given_id_without_a_project_label() {
  local bindir="$TMPBASE/bin_noproject" log="$TMPBASE/log_noproject.txt"
  : > "$log"
  _write_docker_stub "$bindir" "<no value>" ""
  (
    PATH="$bindir:$PATH"
    STUB_LOG="$log"
    export PATH STUB_LOG
    . "$FN_FILE"
    _cbox_stop_with_sidecars "cidY"
  )
  grep -q '^inspect inspect --format .* cidY$' "$log" \
    || _fail "expected an inspect call for cidY, log was:
$(cat "$log")"
  grep -q '^ps ' "$log" \
    && _fail "must not query docker ps when the container has no compose project label:
$(cat "$log")"
  grep -q '^stop stop cidY$' "$log" \
    || _fail "expected a direct docker stop cidY fallback, log was:
$(cat "$log")"
  _ok "no compose project label: stops only the given container id"
}

test_stops_only_the_given_id_when_no_other_container_shares_the_project() {
  local bindir="$TMPBASE/bin_empty" log="$TMPBASE/log_empty.txt"
  : > "$log"
  _write_docker_stub "$bindir" "cbox-pfeedface0022" ""
  (
    PATH="$bindir:$PATH"
    STUB_LOG="$log"
    export PATH STUB_LOG
    . "$FN_FILE"
    _cbox_stop_with_sidecars "cidZ"
  )
  grep -q '^ps ps -q --filter label=com.docker.compose.project=cbox-pfeedface0022 --filter label=cbox.kind$' "$log" \
    || _fail "expected a ps -q --filter call for the project even when it returns no ids, log was:
$(cat "$log")"
  grep -q '^stop stop cidZ$' "$log" \
    || _fail "expected a direct docker stop cidZ fallback when the project query returns no ids, log was:
$(cat "$log")"
  _ok "compose project label present but query returns no ids: falls back to stopping only the given id"
}

test_stops_every_container_in_the_compose_project
test_stops_the_proxy_sidecar_carrying_cbox_kind_proxy_label
test_forged_foreign_project_name_stops_only_given_id
test_stops_only_the_given_id_without_a_project_label
test_stops_only_the_given_id_when_no_other_container_shares_the_project
echo "all gc sidecars tests passed"
