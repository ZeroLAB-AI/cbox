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
  echo "PASS: $1"
}

_make_fake_install() {
  local dir="$1"
  mkdir -p "$dir/etc/mcp" "$dir/etc/hooks" "$dir/etc/claude" "$dir/etc/container" "$dir/lib" "$dir/templates" "$dir/generated"
  cp "$INSTALL_DIR/_common.sh" "$dir/_common.sh"
  cp "$INSTALL_DIR/lib/portable.sh" "$dir/lib/portable.sh"
  cp "$INSTALL_DIR/lib/cbox_host.py" "$dir/lib/cbox_host.py"
  cp "$INSTALL_DIR/lib/cbox_session_bridge.py" "$dir/lib/cbox_session_bridge.py"
  cp "$INSTALL_DIR/templates/generators.sh" "$dir/templates/generators.sh"
  cp "$INSTALL_DIR/etc/mcp/render_mcp.py" "$dir/etc/mcp/render_mcp.py"
  cp "$INSTALL_DIR/etc/mcp/delegates.json" "$dir/etc/mcp/delegates.json"
  cp "$INSTALL_DIR/etc/container/cbox-session-entry.py" "$dir/etc/container/cbox-session-entry.py"
  printf 'schema=1\nbase=ubuntu:24.04@sha256:deadbeef\n' > "$dir/image.inputs"
}

test_compose_nested_bind_all_four_variants() {
  local udir="$TMPBASE/udir_compose"
  mkdir -p "$udir/policies"
  printf '# policy\n' > "$udir/policies/team.md"

  local expected_bind="- $udir/policies:\${HOST_HOME}/.claude/policies/user:ro"
  local expected_etc_bind="- $udir:/etc/cbox/user:ro"

  local d1="$TMPBASE/gc_mount"
  local fi1="$d1/fi"
  _make_fake_install "$fi1"
  (
    fi="$fi1" udir="$udir"
    INSTALL_DIR="$fi"
    export INSTALL_DIR
    export HOME="$fi/home"
    export CBOX_CLAUDE_PATH="$fi/home/.claude"
    export CBOX_CODEX_PATH="$fi/home/.codex"
    export CBOX_WORKSPACES="$d1/ws"
    export CBOX_CLAUDE_MODE=mount
    export CBOX_USER_DIR="$udir"
    mkdir -p "$d1/ws" "$fi/home"
    source "$fi/_common.sh"
    source "$fi/templates/generators.sh"
    gen_compose
  )
  grep -qF -- "$expected_bind" "$fi1/docker-compose.yml" \
    || _fail "gen_compose (claude mode=mount) missing nested policies bind:
$(cat "$fi1/docker-compose.yml")"
  _ok "gen_compose claude_mode=mount: nested policies bind present"

  local d2="$TMPBASE/gc_volume"
  local fi2="$d2/fi"
  _make_fake_install "$fi2"
  (
    fi="$fi2" udir="$udir"
    INSTALL_DIR="$fi"
    export INSTALL_DIR
    export HOME="$fi/home"
    export CBOX_CLAUDE_PATH="$fi/home/.claude"
    export CBOX_CODEX_PATH="$fi/home/.codex"
    export CBOX_WORKSPACES="$d2/ws"
    export CBOX_CLAUDE_MODE=volume
    export CBOX_USER_DIR="$udir"
    mkdir -p "$d2/ws" "$fi/home"
    source "$fi/_common.sh"
    source "$fi/templates/generators.sh"
    gen_compose
  )
  grep -qF -- "$expected_bind" "$fi2/docker-compose.yml" \
    || _fail "gen_compose (claude mode=volume) missing nested policies bind:
$(cat "$fi2/docker-compose.yml")"
  grep -qF -- "$expected_etc_bind" "$fi2/docker-compose.yml" \
    || _fail "gen_compose missing /etc/cbox/user bind:
$(cat "$fi2/docker-compose.yml")"
  _ok "gen_compose claude_mode=volume: nested policies bind present, /etc/cbox/user bind present"

  local d3="$TMPBASE/gci_mount"
  local fi3="$d3/fi"
  local root3="$d3/root"
  _make_fake_install "$fi3"
  mkdir -p "$root3" "$fi3/eff"
  (
    fi="$fi3" udir="$udir"
    INSTALL_DIR="$fi"
    export INSTALL_DIR
    export HOME="$fi/home"
    export CBOX_CLAUDE_PATH="$fi/home/.claude"
    export CBOX_CODEX_PATH="$fi/home/.codex"
    export CBOX_CLAUDE_MODE=mount
    export CBOX_USER_DIR="$udir"
    mkdir -p "$fi/home"
    source "$fi/_common.sh"
    source "$fi/templates/generators.sh"
    gen_compose_isolated "$fi/eff" "$root3" "cbox-img:deadbeef" "deadbeef"
  )
  local compose3
  compose3="$(find "$fi3/eff" -maxdepth 1 -name 'docker-compose*.yml' | head -n1)"
  [ -n "$compose3" ] || _fail "gen_compose_isolated (claude mode=mount) did not write a docker-compose file under $fi3/eff"
  grep -qF -- "$expected_bind" "$compose3" \
    || _fail "gen_compose_isolated (claude mode=mount) missing nested policies bind:
$(cat "$compose3")"
  grep -qF -- "$expected_etc_bind" "$compose3" \
    || _fail "gen_compose_isolated missing /etc/cbox/user bind:
$(cat "$compose3")"
  _ok "gen_compose_isolated claude_mode=mount: nested policies bind present, /etc/cbox/user bind present"

  local d4="$TMPBASE/gci_volume"
  local fi4="$d4/fi"
  local root4="$d4/root"
  _make_fake_install "$fi4"
  mkdir -p "$root4" "$fi4/eff"
  (
    fi="$fi4" udir="$udir"
    INSTALL_DIR="$fi"
    export INSTALL_DIR
    export HOME="$fi/home"
    export CBOX_CLAUDE_PATH="$fi/home/.claude"
    export CBOX_CODEX_PATH="$fi/home/.codex"
    export CBOX_CLAUDE_MODE=volume
    export CBOX_USER_DIR="$udir"
    mkdir -p "$fi/home"
    source "$fi/_common.sh"
    source "$fi/templates/generators.sh"
    gen_compose_isolated "$fi/eff" "$root4" "cbox-img:deadbeef" "deadbeef"
  )
  local compose4
  compose4="$(find "$fi4/eff" -maxdepth 1 -name 'docker-compose*.yml' | head -n1)"
  [ -n "$compose4" ] || _fail "gen_compose_isolated (claude mode=volume) did not write a docker-compose file under $fi4/eff"
  grep -qF -- "$expected_bind" "$compose4" \
    || _fail "gen_compose_isolated (claude mode=volume) missing nested policies bind:
$(cat "$compose4")"
  _ok "gen_compose_isolated claude_mode=volume: nested policies bind present"

  local d5="$TMPBASE/no_userdir"
  local fi5="$d5/fi"
  _make_fake_install "$fi5"
  local missing_dir="$TMPBASE/does_not_exist_policies_dir"
  (
    fi="$fi5"
    INSTALL_DIR="$fi"
    export INSTALL_DIR
    export HOME="$fi/home"
    export CBOX_CLAUDE_PATH="$fi/home/.claude"
    export CBOX_CODEX_PATH="$fi/home/.codex"
    export CBOX_WORKSPACES="$d5/ws"
    export CBOX_CLAUDE_MODE=mount
    export CBOX_USER_DIR="$missing_dir"
    mkdir -p "$d5/ws" "$fi/home"
    source "$fi/_common.sh"
    source "$fi/templates/generators.sh"
    gen_compose
  )
  grep -q 'policies/user:ro' "$fi5/docker-compose.yml" \
    && _fail "gen_compose rendered a nested policies bind for a non-existent CBOX_USER_DIR (no-op contract violated):
$(cat "$fi5/docker-compose.yml")"
  grep -q '/etc/cbox/user:ro' "$fi5/docker-compose.yml" \
    && _fail "gen_compose rendered an /etc/cbox/user bind for a non-existent CBOX_USER_DIR (no-op contract violated):
$(cat "$fi5/docker-compose.yml")"
  _ok "gen_compose: non-existent CBOX_USER_DIR renders neither bind (no-op contract)"
}

test_codex_agents_order_and_budget() {
  local udir="$TMPBASE/udir_codex"
  mkdir -p "$udir/policies"
  printf 'alpha policy body\n' > "$udir/policies/a-alpha.md"
  printf 'beta policy body\n' > "$udir/policies/b-beta.md"
  local out="$TMPBASE/codex_out"
  mkdir -p "$out"
  local fake_home="$TMPBASE/codex_home"
  mkdir -p "$fake_home/.codex"
  printf '# host AGENTS override\nhost content here\n' > "$fake_home/.codex/AGENTS.override.md"
  (
    INSTALL_DIR="$INSTALL_DIR"
    export INSTALL_DIR
    export HOME="$fake_home"
    export CBOX_USER_DIR="$udir"
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    gen_codex_agents_into "$out"
  )
  local rendered="$out/AGENTS.override.md"
  [ -f "$rendered" ] || _fail "gen_codex_agents_into did not write $rendered"
  local l_fold l_userpol l_engine l_kernel l_boundary
  l_fold="$(grep -n 'folded in from host' "$rendered" | head -n1 | cut -d: -f1)"
  l_userpol="$(grep -n '===== cbox user policies =====' "$rendered" | head -n1 | cut -d: -f1)"
  l_engine="$(grep -n 'ENGINE NOTE: this file plays the role CLAUDE.md' "$rendered" | head -n1 | cut -d: -f1)"
  l_kernel="$(grep -n 'CONDUCT KERNEL' "$rendered" | head -n1 | cut -d: -f1)"
  l_boundary="$(grep -n 'DELEGATE WRITE BOUNDARY' "$rendered" | head -n1 | cut -d: -f1)"
  [ -n "$l_fold" ] || _fail "gen_codex_agents_into: host fold-in missing:
$(cat "$rendered")"
  [ -n "$l_userpol" ] || _fail "gen_codex_agents_into: user policies banner missing:
$(cat "$rendered")"
  [ -n "$l_engine" ] || _fail "gen_codex_agents_into: ENGINE NOTE preamble missing:
$(cat "$rendered")"
  [ -n "$l_kernel" ] || _fail "gen_codex_agents_into: kernel text missing:
$(cat "$rendered")"
  [ -n "$l_boundary" ] || _fail "gen_codex_agents_into: delegate boundary missing:
$(cat "$rendered")"
  [ "$l_fold" -lt "$l_userpol" ] \
    || _fail "gen_codex_agents_into: host fold-in must come before the user policies banner (fold=$l_fold userpol=$l_userpol)"
  [ "$l_userpol" -lt "$l_engine" ] \
    || _fail "gen_codex_agents_into: user policies banner must come before the ENGINE NOTE preamble (userpol=$l_userpol engine=$l_engine)"
  [ "$l_engine" -lt "$l_kernel" ] \
    || _fail "gen_codex_agents_into: ENGINE NOTE preamble must come before the kernel text (engine=$l_engine kernel=$l_kernel)"
  [ "$l_kernel" -lt "$l_boundary" ] \
    || _fail "gen_codex_agents_into: kernel text must come before the delegate boundary (kernel=$l_kernel boundary=$l_boundary)"
  grep -q 'alpha policy body' "$rendered" || _fail "gen_codex_agents_into: policy a-alpha.md content missing"
  grep -q 'beta policy body' "$rendered" || _fail "gen_codex_agents_into: policy b-beta.md content missing"
  _ok "gen_codex_agents_into: host fold-in < user policies banner < ENGINE NOTE preamble < kernel text < delegate boundary"

  local out2="$TMPBASE/codex_out_oversized"
  mkdir -p "$out2"
  local udir2="$TMPBASE/udir_codex_oversized"
  mkdir -p "$udir2/policies"
  python3 -c "open('$udir2/policies/huge.md','w').write('x'*70000)"
  local err2="$TMPBASE/codex_oversized.err"
  (
    INSTALL_DIR="$INSTALL_DIR"
    export INSTALL_DIR
    export HOME="$TMPBASE/codex_home_empty"
    mkdir -p "$HOME"
    export CBOX_USER_DIR="$udir2"
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    gen_codex_agents_into "$out2"
  ) 2>"$err2" || _fail "gen_codex_agents_into failed on an oversized user policy instead of skipping it:
$(cat "$err2")"
  [ -f "$out2/AGENTS.override.md" ] || _fail "gen_codex_agents_into did not write output when a policy was skipped for size"
  grep -q "huge.md.*skipped.*64000 byte cap" "$err2" \
    || _fail "gen_codex_agents_into: no cap-skip warning for oversized policy on stderr: $(cat "$err2")"
  ! grep -q "$(python3 -c "print('x'*100)")" "$out2/AGENTS.override.md" \
    || _fail "gen_codex_agents_into: oversized policy content leaked into the render despite the cap"
  _ok "gen_codex_agents_into: an oversized user policy is skipped with a stderr cap warning, render still succeeds"

  local out3="$TMPBASE/codex_out_empty"
  mkdir -p "$out3"
  (
    INSTALL_DIR="$INSTALL_DIR"
    export INSTALL_DIR
    export HOME="$TMPBASE/codex_home_empty2"
    mkdir -p "$HOME"
    unset CBOX_USER_DIR
    export CBOX_USER_DIR="$TMPBASE/does_not_exist_codex_udir"
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    gen_codex_agents_into "$out3"
  )
  grep -q '===== cbox user policies =====' "$out3/AGENTS.override.md" \
    && _fail "gen_codex_agents_into: user policies banner rendered despite an empty/missing user dir:
$(cat "$out3/AGENTS.override.md")"
  _ok "gen_codex_agents_into: no banners when the user policies dir is empty/missing"
}

test_hermes_preamble() {
  local entry_src="$INSTALL_DIR/entrypoint.sh"
  local extracted="$TMPBASE/hermes_preamble_func.sh"
  awk '
    /^_hermes_user_policies_preamble\(\) \{/ { grab=1 }
    grab { print }
    grab && /^\}/ { exit }
  ' "$entry_src" > "$extracted"
  [ -s "$extracted" ] || _fail "could not extract _hermes_user_policies_preamble from entrypoint.sh"

  local fixture_dir="$TMPBASE/hermes_fixture_a"
  local extracted_a="$TMPBASE/hermes_preamble_a.sh"
  sed "s#local dir=/etc/cbox/user/policies#local dir=$fixture_dir#" "$extracted" > "$extracted_a"

  local out_missing rc_missing=0
  out_missing="$(
    source "$extracted_a"
    _hermes_user_policies_preamble
  )" || rc_missing=$?
  [ "$rc_missing" = 0 ] || _fail "_hermes_user_policies_preamble non-zero rc on missing dir"
  [ -z "$out_missing" ] || _fail "_hermes_user_policies_preamble should render empty for a missing dir, got: $out_missing"
  _ok "_hermes_user_policies_preamble: missing dir renders empty output, rc 0"

  mkdir -p "$fixture_dir"
  printf 'z-last content\n' > "$fixture_dir/z-last.md"
  printf 'a-first content\n' > "$fixture_dir/a-first.md"
  printf 'bad content\n' > "$fixture_dir/_bad.md"
  local out_order
  out_order="$(
    source "$extracted_a"
    _hermes_user_policies_preamble
  )"
  local l_first l_last
  l_first="$(printf '%s\n' "$out_order" | grep -n 'a-first content' | head -n1 | cut -d: -f1)"
  l_last="$(printf '%s\n' "$out_order" | grep -n 'z-last content' | head -n1 | cut -d: -f1)"
  [ -n "$l_first" ] && [ -n "$l_last" ] || _fail "_hermes_user_policies_preamble: expected both fixture files in output:
$out_order"
  [ "$l_first" -lt "$l_last" ] || _fail "_hermes_user_policies_preamble: LC_ALL=C sort order violated (a-first should precede z-last):
$out_order"
  printf '%s\n' "$out_order" | grep -q 'bad content' \
    && _fail "_hermes_user_policies_preamble: bad filename _bad.md should have been skipped:
$out_order"
  printf '%s\n' "$out_order" | grep -q '===== cbox conduct kernel below' \
    || _fail "_hermes_user_policies_preamble: delimiter line missing when content is included:
$out_order"
  _ok "_hermes_user_policies_preamble: LC_ALL=C order, bad filename skipped, delimiter line present when content included"

  local fixture_newline="$TMPBASE/hermes_fixture_newline"
  mkdir -p "$fixture_newline"
  printf 'legit content\n' > "$fixture_newline/legit.md"
  local newline_name secret_name
  newline_name="$(printf 'x\nSECRET.md')"
  printf 'not really secret but should never appear\n' > "$fixture_newline/$newline_name"
  local newline_cwd="$TMPBASE/hermes_newline_cwd"
  mkdir -p "$newline_cwd"
  secret_name="SECRET.md"
  printf 'REAL SECRET DATA FROM CWD\n' > "$newline_cwd/$secret_name"
  local extracted_newline="$TMPBASE/hermes_preamble_newline.sh"
  sed "s#local dir=/etc/cbox/user/policies#local dir=$fixture_newline#" "$extracted" > "$extracted_newline"
  local out_newline err_newline
  out_newline="$(
    { cd "$newline_cwd"
      source "$extracted_newline"
      _hermes_user_policies_preamble
    } 2>"$TMPBASE/hermes_newline.err" )"
  err_newline="$(cat "$TMPBASE/hermes_newline.err")"
  printf '%s\n' "$out_newline" | grep -q 'REAL SECRET DATA FROM CWD' \
    && _fail "_hermes_user_policies_preamble: newline-split filename pulled an unrelated cwd file into the preamble:
$out_newline"
  printf '%s\n' "$out_newline" | grep -q 'legit content' \
    || _fail "_hermes_user_policies_preamble: legit fixture file missing from output despite the newline-name fixture present:
$out_newline"
  printf '%s\n' "$err_newline" | grep -q 'skipped - unsupported filename' \
    || _fail "_hermes_user_policies_preamble: newline-name fixture should have been warned+skipped on stderr, got: $err_newline"
  _ok "_hermes_user_policies_preamble: filename containing a newline is rejected, no cwd file leaks into the preamble"

  local fixture_cap="$TMPBASE/hermes_fixture_cap"
  mkdir -p "$fixture_cap"
  python3 -c "open('$fixture_cap/a-first.md','w').write('a'*10000)"
  python3 -c "open('$fixture_cap/b-second.md','w').write('b'*10000)"
  local extracted_cap="$TMPBASE/hermes_preamble_cap.sh"
  sed "s#local dir=/etc/cbox/user/policies#local dir=$fixture_cap#" "$extracted" > "$extracted_cap"
  local err_cap="$TMPBASE/hermes_cap.err"
  local out_cap
  out_cap="$( { source "$extracted_cap"; _hermes_user_policies_preamble; } 2>"$err_cap" )"
  printf '%s\n' "$out_cap" | grep -q 'aaaaaaaaaa' || _fail "_hermes_user_policies_preamble: first file under the 16384 cap should be included"
  printf '%s\n' "$out_cap" | grep -q 'bbbbbbbbbb' \
    && _fail "_hermes_user_policies_preamble: second file should have been skipped once cumulative size exceeds the 16384 cap:
$(printf '%s' "$out_cap" | head -c 200)"
  grep -q "b-second.md.*skipped.*hermes user policy cap 16384 bytes" "$err_cap" \
    || _fail "_hermes_user_policies_preamble: no cap-skip warning on stderr: $(cat "$err_cap")"
  _ok "_hermes_user_policies_preamble: cumulative 16384 byte cap enforced with a stderr warning"

  local fixture_postcheck="$TMPBASE/hermes_fixture_postcheck"
  mkdir -p "$fixture_postcheck"
  python3 -c "open('$fixture_postcheck/only.md','w').write('c'*16384)"
  local extracted_postcheck="$TMPBASE/hermes_preamble_postcheck.sh"
  sed "s#local dir=/etc/cbox/user/policies#local dir=$fixture_postcheck#" "$extracted" > "$extracted_postcheck"
  local err_postcheck_file="$TMPBASE/hermes_postcheck.err"
  local err_postcheck out_postcheck
  out_postcheck="$( { source "$extracted_postcheck"; _hermes_user_policies_preamble; } 2>"$err_postcheck_file" )"
  err_postcheck="$(cat "$err_postcheck_file")"
  printf '%s\n' "$out_postcheck" | grep -q 'ccccccccc' \
    || _fail "_hermes_user_policies_preamble: single file exactly at the 16384 cap should survive the post-assembly recheck:
$err_postcheck"
  printf '%s\n' "$out_postcheck" | grep -q '===== cbox conduct kernel below' \
    || _fail "_hermes_user_policies_preamble: post-assembly recheck should not have dropped a within-cap render"
  printf '%s\n' "$err_postcheck" | grep -q 'dropped' \
    && _fail "_hermes_user_policies_preamble: post-assembly recheck fired a drop warning for a within-cap render: $err_postcheck"
  _ok "_hermes_user_policies_preamble: post-assembly recheck (finding: TOCTOU between wc -c measurement and cat read) passes through a within-cap render intact; the mid-read grow race itself needs concurrent filesystem mutation and is not deterministically reproducible in this suite"

  local fixture_empty="$TMPBASE/hermes_fixture_empty"
  mkdir -p "$fixture_empty"
  local extracted_empty="$TMPBASE/hermes_preamble_empty.sh"
  sed "s#local dir=/etc/cbox/user/policies#local dir=$fixture_empty#" "$extracted" > "$extracted_empty"
  local out_empty
  out_empty="$(
    source "$extracted_empty"
    _hermes_user_policies_preamble
  )"
  [ -z "$out_empty" ] || _fail "_hermes_user_policies_preamble: empty dir should render empty output, got: $out_empty"
  _ok "_hermes_user_policies_preamble: empty policies dir renders empty output (no delimiter)"
}

test_hermes_compose_session_prompt() {
  local entry_src="$INSTALL_DIR/entrypoint.sh"
  local extracted="$TMPBASE/hermes_compose_func.sh"
  awk '
    /^_hermes_compose_session_prompt\(\) \{/ { grab=1 }
    grab { print }
    grab && /^\}/ { exit }
  ' "$entry_src" > "$extracted"
  [ -s "$extracted" ] || _fail "could not extract _hermes_compose_session_prompt from entrypoint.sh"

  local out
  out="$(
    source "$extracted"
    _hermes_compose_session_prompt "USER POLICY TEXT" "KERNEL TEXT"
  )"
  printf '%s' "$out" | grep -q 'USER POLICY TEXT' || _fail "_hermes_compose_session_prompt: user preamble missing when kernel is non-empty"
  printf '%s' "$out" | grep -q 'KERNEL TEXT' || _fail "_hermes_compose_session_prompt: kernel text missing"
  _ok "_hermes_compose_session_prompt: user preamble is prepended to a non-empty kernel"

  local out_empty_kernel
  out_empty_kernel="$(
    source "$extracted"
    _hermes_compose_session_prompt "USER POLICY TEXT" ""
  )"
  [ -z "$out_empty_kernel" ] || _fail "_hermes_compose_session_prompt: user preamble must not survive when the kernel is empty (fail-closed), got: $out_empty_kernel"
  printf '%s' "$out_empty_kernel" | grep -q 'USER POLICY TEXT' \
    && _fail "_hermes_compose_session_prompt: user policy text leaked into the session prompt with an empty kernel"
  printf '%s' "$out_empty_kernel" | grep -q 'cbox conduct kernel below' \
    && _fail "_hermes_compose_session_prompt: authoritative-kernel delimiter emitted despite an empty kernel"
  _ok "_hermes_compose_session_prompt: empty kernel yields empty session prompt, no user text, no misleading delimiter"

  local out_no_user
  out_no_user="$(
    source "$extracted"
    _hermes_compose_session_prompt "" "KERNEL TEXT"
  )"
  [ "$out_no_user" = "KERNEL TEXT" ] || _fail "_hermes_compose_session_prompt: kernel-only case should render exactly the kernel text, got: $out_no_user"
  _ok "_hermes_compose_session_prompt: no user preamble renders kernel text unchanged"
}

test_claude_md_layer() {
  local setup_src="$INSTALL_DIR/lib/cbox-setup.sh"
  local funcs="$TMPBASE/claude_md_funcs.sh"
  {
    awk '
      /^CLAUDE_MD_KERNEL_MARK_START=/,/^CLAUDE_MD_KERNEL_MARK_START=/ { print }
    ' "$setup_src"
    grep -m1 '^CLAUDE_MD_KERNEL_MARK_END=' "$setup_src"
    grep -m1 '^CLAUDE_MD_USERPOL_MARK_START=' "$setup_src"
    grep -m1 '^CLAUDE_MD_USERPOL_MARK_END=' "$setup_src"
    awk '
      /^claude_md_user_policies_block_file\(\) \{/ { grab=1 }
      grab { print }
      grab && /^\}/ { if (grab==1) { print ""; exit } }
    ' "$setup_src"
    awk '
      /^claude_md_merge_user_policies_block\(\) \{/ { grab=1; depth=0 }
      grab { print }
      grab && /\{/ { depth++ }
      grab && /\}/ { depth--; if (depth==0) { print ""; exit } }
    ' "$setup_src"
    awk '
      /^claude_user_policies_symlink\(\) \{/ { grab=1 }
      grab { print }
      grab && /^\}/ { exit }
    ' "$setup_src"
  } > "$funcs"
  [ -s "$funcs" ] || _fail "could not extract claude-md user-policies functions from setup.sh"
  grep -q 'claude_md_user_policies_block_file()' "$funcs" || _fail "extraction missing claude_md_user_policies_block_file body"
  grep -q 'claude_md_merge_user_policies_block()' "$funcs" || _fail "extraction missing claude_md_merge_user_policies_block body"
  grep -q 'claude_user_policies_symlink()' "$funcs" || _fail "extraction missing claude_user_policies_symlink body"

  (
    INSTALL_DIR="$INSTALL_DIR"
    export INSTALL_DIR
    export HOME="$TMPBASE/claude_md_home"
    mkdir -p "$HOME"
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    source "$funcs"

    local wdir="$TMPBASE/claude_md_work"
    mkdir -p "$wdir"
    local udir="$wdir/udir"
    mkdir -p "$udir/policies"
    printf 'user policy one\n' > "$udir/policies/one.md"
    printf 'user policy two\n' > "$udir/policies/two.md"

    local claude_md="$wdir/CLAUDE.md"
    {
      printf '# Project CLAUDE.md\n\nsome content here\n\n'
      printf '%s\n' "$CLAUDE_MD_KERNEL_MARK_START"
      printf 'KERNEL PLACEHOLDER\n'
      printf '%s\n' "$CLAUDE_MD_KERNEL_MARK_END"
    } > "$claude_md"
    local original_snapshot="$wdir/original.snapshot"
    cp "$claude_md" "$original_snapshot"

    claude_md_merge_user_policies_block "$claude_md" "$udir"
    grep -q "$CLAUDE_MD_USERPOL_MARK_START" "$claude_md" || { echo "FAIL: user policies block not inserted" >&2; exit 1; }
    local l_userpol l_kernel
    l_userpol="$(grep -n "$CLAUDE_MD_USERPOL_MARK_START" "$claude_md" | head -n1 | cut -d: -f1)"
    l_kernel="$(grep -n "$CLAUDE_MD_KERNEL_MARK_START" "$claude_md" | head -n1 | cut -d: -f1)"
    [ "$l_userpol" -lt "$l_kernel" ] || { echo "FAIL: user policies block must land above the kernel block (userpol=$l_userpol kernel=$l_kernel)" >&2; exit 1; }
    grep -q '@~/.claude/policies/user/one.md' "$claude_md" || { echo "FAIL: import line for one.md missing" >&2; exit 1; }
    grep -q '@~/.claude/policies/user/two.md' "$claude_md" || { echo "FAIL: import line for two.md missing" >&2; exit 1; }

    local after_first_snapshot="$wdir/after_first.snapshot"
    cp "$claude_md" "$after_first_snapshot"
    claude_md_merge_user_policies_block "$claude_md" "$udir"
    cmp -s "$claude_md" "$after_first_snapshot" || { echo "FAIL: double-merge is not idempotent (byte diff below)" >&2; diff -u "$after_first_snapshot" "$claude_md" >&2 || true; exit 1; }

    rm -f "$udir/policies/one.md" "$udir/policies/two.md"
    claude_md_merge_user_policies_block "$claude_md" "$udir"
    grep -q "$CLAUDE_MD_USERPOL_MARK_START" "$claude_md" && { echo "FAIL: user policies block should be removed once source files are gone" >&2; exit 1; }
    cmp -s "$claude_md" "$original_snapshot" || { echo "FAIL: removing source files and re-merging did not round-trip to the original CLAUDE.md bytes (byte diff below)" >&2; diff -u "$original_snapshot" "$claude_md" >&2 || true; exit 1; }

    printf 'user policy three\n' > "$udir/policies/three.md"
    local claude_md_reorder="$wdir/CLAUDE_reorder.md"
    {
      printf '# Project CLAUDE.md\n\nsome content here\n\n'
      printf '%s\n' "$CLAUDE_MD_KERNEL_MARK_START"
      printf 'KERNEL PLACEHOLDER\n'
      printf '%s\n' "$CLAUDE_MD_KERNEL_MARK_END"
      printf '\n'
      printf '%s\n' "$CLAUDE_MD_USERPOL_MARK_START"
      printf '@~/.claude/policies/user/stale.md\n'
      printf '%s\n' "$CLAUDE_MD_USERPOL_MARK_END"
    } > "$claude_md_reorder"
    claude_md_merge_user_policies_block "$claude_md_reorder" "$udir"
    local l_userpol_r l_kernel_r
    l_userpol_r="$(grep -n "$CLAUDE_MD_USERPOL_MARK_START" "$claude_md_reorder" | head -n1 | cut -d: -f1)"
    l_kernel_r="$(grep -n "$CLAUDE_MD_KERNEL_MARK_START" "$claude_md_reorder" | head -n1 | cut -d: -f1)"
    [ -n "$l_userpol_r" ] && [ -n "$l_kernel_r" ] || { echo "FAIL: reorder fixture lost a marker span after merge" >&2; exit 1; }
    [ "$l_userpol_r" -lt "$l_kernel_r" ] || { echo "FAIL: pre-existing userpol span below the kernel span was not reordered above it (userpol=$l_userpol_r kernel=$l_kernel_r)" >&2; exit 1; }
    grep -q '@~/.claude/policies/user/three.md' "$claude_md_reorder" || { echo "FAIL: reorder merge did not refresh the block content" >&2; exit 1; }
    grep -q '@~/.claude/policies/user/stale.md' "$claude_md_reorder" && { echo "FAIL: reorder merge kept stale content instead of refreshing it" >&2; exit 1; }
    local reorder_after_first="$wdir/CLAUDE_reorder.after_first"
    cp "$claude_md_reorder" "$reorder_after_first"
    claude_md_merge_user_policies_block "$claude_md_reorder" "$udir"
    cmp -s "$claude_md_reorder" "$reorder_after_first" || { echo "FAIL: reorder merge is not idempotent on the second pass (byte diff below)" >&2; diff -u "$reorder_after_first" "$claude_md_reorder" >&2 || true; exit 1; }

    local link_dir="$TMPBASE/claude_md_link_test"
    mkdir -p "$link_dir"
    CBOX_CLAUDE_PATH="$link_dir"
    CBOX_USER_DIR="$udir"
    mkdir -p "$udir/policies"
    claude_user_policies_symlink || { echo "FAIL: claude_user_policies_symlink failed on a clean path" >&2; exit 1; }
    [ -L "$link_dir/policies/user" ] || { echo "FAIL: claude_user_policies_symlink did not create a symlink" >&2; exit 1; }
    local target
    target="$(readlink "$link_dir/policies/user")"
    [ "$target" = "$udir/policies" ] || { echo "FAIL: symlink target wrong (got $target want $udir/policies)" >&2; exit 1; }

    local udir2="$TMPBASE/claude_md_udir2"
    mkdir -p "$udir2/policies"
    CBOX_USER_DIR="$udir2"
    claude_user_policies_symlink || { echo "FAIL: claude_user_policies_symlink failed to retarget an existing symlink" >&2; exit 1; }
    target="$(readlink "$link_dir/policies/user")"
    [ "$target" = "$udir2/policies" ] || { echo "FAIL: symlink retarget wrong (got $target want $udir2/policies)" >&2; exit 1; }

    local udir3_parent="$TMPBASE/claude_md_relative_parent"
    local udir3_name="claude_md_udir3"
    mkdir -p "$udir3_parent/$udir3_name/policies"
    rm -f "$link_dir/policies/user"
    (
      cd "$udir3_parent"
      CBOX_USER_DIR="$udir3_name"
      claude_user_policies_symlink || { echo "FAIL: claude_user_policies_symlink failed with a relative CBOX_USER_DIR" >&2; exit 1; }
    )
    target="$(readlink "$link_dir/policies/user")"
    case "$target" in
      /*) ;;
      *) echo "FAIL: claude_user_policies_symlink left a relative symlink target for a relative CBOX_USER_DIR (got $target)" >&2; exit 1 ;;
    esac
    [ "$target" = "$udir3_parent/$udir3_name/policies" ] || { echo "FAIL: relative CBOX_USER_DIR resolved to the wrong absolute target (got $target want $udir3_parent/$udir3_name/policies)" >&2; exit 1; }

    rm -f "$link_dir/policies/user"
    mkdir -p "$link_dir/policies/user"
    : > "$link_dir/policies/user/real-file-marker"
    if claude_user_policies_symlink 2>"$TMPBASE/symlink_collision.err"; then
      echo "FAIL: claude_user_policies_symlink should refuse when a real directory occupies the path" >&2
      exit 1
    fi
    [ -f "$link_dir/policies/user/real-file-marker" ] || { echo "FAIL: colliding real directory was touched despite the refusal" >&2; exit 1; }
    [ -s "$TMPBASE/symlink_collision.err" ] || { echo "FAIL: claude_user_policies_symlink refusal produced no stderr warning" >&2; exit 1; }
  )
  _ok "claude-md layer: block inserted above kernel block, idempotent double-merge, removal round-trips to original bytes, pre-existing span below kernel is reordered above it and stays idempotent, symlink create/retarget/relative-path-resolved/refuse-on-collision all correct"
}

test_helper_cbox_user_policies_files() {
  local udir="$TMPBASE/udir_helper"
  mkdir -p "$udir"
  printf 'z\n' > "$udir/z-policy.md"
  printf 'a\n' > "$udir/a-policy.md"
  printf 'bad\n' > "$udir/bad name.md"
  local out err
  out="$(
    INSTALL_DIR="$INSTALL_DIR"
    export INSTALL_DIR
    export HOME="$TMPBASE/helper_home"
    mkdir -p "$HOME"
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    _cbox_user_policies_files "$udir"
  )"
  err="$( {
    INSTALL_DIR="$INSTALL_DIR"
    export INSTALL_DIR
    export HOME="$TMPBASE/helper_home2"
    mkdir -p "$HOME"
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    _cbox_user_policies_files "$udir"
  } 2>&1 1>/dev/null )"
  local l1 l2
  l1="$(printf '%s\n' "$out" | sed -n '1p')"
  l2="$(printf '%s\n' "$out" | sed -n '2p')"
  [ "$l1" = "$udir/a-policy.md" ] || _fail "_cbox_user_policies_files: sorted output wrong first entry (got $l1)"
  [ "$l2" = "$udir/z-policy.md" ] || _fail "_cbox_user_policies_files: sorted output wrong second entry (got $l2)"
  printf '%s\n' "$out" | grep -q "bad name.md" && _fail "_cbox_user_policies_files: invalid basename 'bad name.md' should have been excluded from stdout"
  printf '%s' "$err" | grep -q "bad name.md" || _fail "_cbox_user_policies_files: no stderr warning for invalid basename: $err"
  _ok "_cbox_user_policies_files: sorted output, invalid basename warned+skipped"

  local missing="$TMPBASE/does_not_exist_helper_dir"
  local out_missing err_missing
  out_missing="$( {
    INSTALL_DIR="$INSTALL_DIR"
    export INSTALL_DIR
    export HOME="$TMPBASE/helper_home3"
    mkdir -p "$HOME"
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    _cbox_user_policies_files "$missing"
  } 2>"$TMPBASE/helper_missing.err" )"
  [ -z "$out_missing" ] || _fail "_cbox_user_policies_files: missing dir should produce empty stdout, got: $out_missing"
  [ ! -s "$TMPBASE/helper_missing.err" ] || _fail "_cbox_user_policies_files: missing dir should be silent, got stderr: $(cat "$TMPBASE/helper_missing.err")"
  _ok "_cbox_user_policies_files: missing dir is silent empty"
}

test_compose_nested_bind_all_four_variants
test_codex_agents_order_and_budget
test_hermes_preamble
test_hermes_compose_session_prompt
test_claude_md_layer
test_helper_cbox_user_policies_files
echo "PASS: all user policies layer checks"
