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

while IFS='=' read -r _cbox_env_name _; do
  case "$_cbox_env_name" in
    CBOX_*|OLLAMA_*|HERMES_*|HOST_HOME|XDG_RUNTIME_DIR) unset "$_cbox_env_name" ;;
  esac
done < <(env)
unset CBOX_PROFILE CBOX_RENDER_PROFILE

BASE_REV="a3b1864"
REG="$INSTALL_DIR/etc/engines/engines.json"
REGPY="$INSTALL_DIR/etc/engines/engines_registry.py"

H="$TMPBASE/home"
ROOT="$TMPBASE/proj"
SCOPE="$TMPBASE/scope"
RUNDIR="$TMPBASE/run"
STORE="$H/.config/cbox/profiles/work"
EFFP="$SCOPE/profiles/work"
mkdir -p "$H/.claude" "$H/.codex" "$ROOT" "$SCOPE/claude-config" "$EFFP" "$RUNDIR" "$STORE"
chmod 0700 "$STORE"

ACCOUNT_JSON='{"oauthAccount":{"emailAddress":"default@example.test"},"userID":"u-default","modelAccessCache":{"a":1},"cachedUsageUtilization":{"b":2},"cachedExtraUsageDisabledReason":"x","hasCompletedOnboarding":true,"projects":{"/q":{"hasTrustDialogAccepted":true}}}'
printf '%s\n' "$ACCOUNT_JSON" > "$SCOPE/claude-config/.claude.json"
printf '%s\n' "$ACCOUNT_JSON" > "$H/.claude.json"
printf 'default-token\n' > "$H/.claude/.credentials.json"

_render() {
  local eff="$1" prof="$2" gen="$3"
  shift 3
  (
    export HOME="$H" INSTALL_DIR XDG_RUNTIME_DIR="$RUNDIR"
    export CBOX_CLAUDE_MODE=mount CBOX_CODEX_MODE=mount CBOX_SESSION_SCOPE=isolated
    export CBOX_CLAUDE_PATH="$H/.claude" CBOX_CODEX_PATH="$H/.codex"
    export CBOX_USER_DIR="$TMPBASE/nouser"
    export CBOX_CLIPBOARD_MODE=bridge
    local kv
    for kv in "$@"; do export "$kv"; done
    if [ "$prof" != default ]; then export CBOX_RENDER_PROFILE="$prof"; fi
    . "$INSTALL_DIR/_common.sh"
    . "$gen"
    gen_compose_isolated "$eff" "$ROOT" testimg testhash123456
  )
}

_with_review() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
out = []
for line in open(p).read().split("\n"):
    out.append(line)
    if line == "      - CBOX_CONTEXT_PROFILE=full":
        out.append("      - CBOX_REVIEW=ask")
        out.append("      - CBOX_BUDGET_MODE=on")
        out.append("      - CBOX_SUBSCRIPTION_PROFILE=high")
        out.append("      - CBOX_BUDGET_LOW_5H=15")
        out.append("      - CBOX_BUDGET_LOW_7D=20")
        out.append("      - CBOX_BUDGET_PACE_WINDOW_H=3")
        out.append("      - CBOX_BUDGET_PACE_SLACK_H=8")
    if line.startswith("      - CBOX_HERMES_DELEGATE="):
        out.append("      - CBOX_HERMES_DELEGATE_CONTEXT_LENGTH=65536")
open(p, "w").write("\n".join(out))
PY
}

NEWGEN="$INSTALL_DIR/templates/generators.sh"
FIX="$INSTALL_DIR/lib/fixtures/render_baselines"
_need_fixture() {
  [ -f "$FIX/$1" ] || _fail "missing baseline fixture $FIX/$1 - the byte-identity baselines must ship with the package"
}
ROOTHASH="$(. "$INSTALL_DIR/_common.sh"; _cbox_path_hash "$ROOT")"
TMPSLUG="$(printf '%s' "$TMPBASE" | sed 's|[/.]|-|g')"
_norm() {
  sed -e "s|$TMPSLUG|@TMPSLUG@|g" -e "s|$TMPBASE|@TMP@|g" -e "s|$INSTALL_DIR|@INSTALL@|g" -e "s/$ROOTHASH/@ROOTHASH@/g"
}
_baseline_with_review() {
  _need_fixture "$1"
  cp "$FIX/$1" "$2"
  _with_review "$2"
}

DEFEFF="$TMPBASE/defeff"
mkdir -p "$DEFEFF"
_render "$DEFEFF" default "$NEWGEN" >/dev/null 2>"$TMPBASE/def.err" || _fail "default render failed: $(cat "$TMPBASE/def.err")"
cp "$DEFEFF/docker-compose.yml" "$TMPBASE/def_new.yml"
grep -qF 'CBOX_PROFILE=default' "$TMPBASE/def_new.yml" || _fail "default render lost the CBOX_PROFILE=default line"
if grep -qF 'cbox.profile' "$TMPBASE/def_new.yml"; then _fail "default render carries a cbox.profile label"; fi
if grep -qF "$H/.config/cbox/profiles" "$TMPBASE/def_new.yml"; then _fail "default render references the profile store"; fi
if grep -qF 'credentials-mask' "$TMPBASE/def_new.yml"; then _fail "default render carries a credentials mask"; fi
grep -qxF -- "      - $H/.claude:\${HOST_HOME}/.claude:rw" "$TMPBASE/def_new.yml" || _fail "default render lost the whole claude dir bind"
grep -qxF -- "      - $H/.codex:\${HOST_HOME}/.codex:rw" "$TMPBASE/def_new.yml" || _fail "default render lost the whole codex dir bind"
grep -qxF -- '      - CBOX_REVIEW=ask' "$TMPBASE/def_new.yml" || _fail "default render lacks the CBOX_REVIEW env line"
grep -qxF -- '      - CBOX_BUDGET_MODE=on' "$TMPBASE/def_new.yml" || _fail "default render lacks the CBOX_BUDGET_MODE=on env line"
grep -qxF -- '      - CBOX_SUBSCRIPTION_PROFILE=high' "$TMPBASE/def_new.yml" || _fail "default render lacks the CBOX_SUBSCRIPTION_PROFILE=high env line"
for kv in CBOX_BUDGET_LOW_5H=15 CBOX_BUDGET_LOW_7D=20 CBOX_BUDGET_PACE_WINDOW_H=3 CBOX_BUDGET_PACE_SLACK_H=8; do
  grep -qxF -- "      - $kv" "$TMPBASE/def_new.yml" || _fail "default render lacks the $kv env line"
done
BEFF="$TMPBASE/defeff_budget_off"
mkdir -p "$BEFF"
_render "$BEFF" default "$NEWGEN" CBOX_BUDGET_MODE=off >/dev/null 2>"$TMPBASE/boff.err" || _fail "budget off render failed: $(cat "$TMPBASE/boff.err")"
grep -qxF -- '      - CBOX_BUDGET_MODE=off' "$BEFF/docker-compose.yml" || _fail "isolated render with CBOX_BUDGET_MODE=off lacks the off env line"
if grep -qxF -- '      - CBOX_BUDGET_MODE=on' "$BEFF/docker-compose.yml"; then _fail "isolated render with CBOX_BUDGET_MODE=off still carries the on line"; fi
[ "$(grep -c 'CBOX_BUDGET_MODE=' "$BEFF/docker-compose.yml")" = 1 ] || _fail "isolated render must carry exactly one CBOX_BUDGET_MODE line"
[ "$(grep -c 'CBOX_SUBSCRIPTION_PROFILE=' "$BEFF/docker-compose.yml")" = 1 ] || _fail "isolated render must carry exactly one CBOX_SUBSCRIPTION_PROFILE line"
_ok "isolated render: CBOX_BUDGET_MODE=on by default, off renders the off line exactly once"
BTUNE="$TMPBASE/defeff_budget_tuned"
mkdir -p "$BTUNE"
_render "$BTUNE" default "$NEWGEN" CBOX_BUDGET_LOW_5H=10 CBOX_BUDGET_LOW_7D=25 CBOX_BUDGET_PACE_WINDOW_H=6 CBOX_BUDGET_PACE_SLACK_H=12 >/dev/null 2>"$TMPBASE/btune.err" || _fail "budget tuned render failed: $(cat "$TMPBASE/btune.err")"
for kv in CBOX_BUDGET_LOW_5H=10 CBOX_BUDGET_LOW_7D=25 CBOX_BUDGET_PACE_WINDOW_H=6 CBOX_BUDGET_PACE_SLACK_H=12; do
  grep -qxF -- "      - $kv" "$BTUNE/docker-compose.yml" || _fail "isolated render lacks the tuned $kv env line"
  [ "$(grep -c "${kv%%=*}=" "$BTUNE/docker-compose.yml")" = 1 ] || _fail "isolated render must carry exactly one ${kv%%=*} line"
done
_ok "isolated render: the regulator thresholds default to 15/20/3/8 and follow the configured values exactly once"
grep -qxF -- '      - CODEX_GUARD_AUDIT=${HOST_HOME}/.claude/codex_guard_audit.container.jsonl' "$TMPBASE/def_new.yml" || _fail "default render changed the codex guard audit path"
if grep -qF 'cbox-audit' "$TMPBASE/def_new.yml"; then _fail "default render carries the profile audit dir"; fi
grep -qF "name: cbox-p$(. "$INSTALL_DIR/_common.sh"; _cbox_path_hash "$ROOT")" "$TMPBASE/def_new.yml" || _fail "default compose name changed"
grep -qF -- "- $H/.claude.json:\${HOST_HOME}/.claude.json:ro" "$TMPBASE/def_new.yml" || _fail "default render lost the host .claude.json seed bind"
_ok "default render: no profile label, store, or mask; host .claude.json seed bind kept"

if true; then
  _norm < "$TMPBASE/def_new.yml" > "$TMPBASE/def_new.norm.yml"
  _baseline_with_review profile_default_compose.yml "$TMPBASE/def_base.yml"
  cmp -s "$TMPBASE/def_new.norm.yml" "$TMPBASE/def_base.yml" \
    || _fail "default render differs from baseline $BASE_REV:
$(diff "$TMPBASE/def_new.norm.yml" "$TMPBASE/def_base.yml")"
  _ok "default render is byte-identical to the baseline fixtures from $BASE_REV except the CBOX_REVIEW and CBOX_BUDGET_MODE env lines (and the CBOX_HERMES_DELEGATE_CONTEXT_LENGTH line next to the delegate env line when hermes is on)"

  HEFF="$TMPBASE/defeff_h"
  mkdir -p "$HEFF"
  _render "$HEFF" default "$NEWGEN" CBOX_HERMES=on CBOX_GPU=1 >/dev/null 2>"$TMPBASE/h.err" || _fail "default hermes render failed: $(cat "$TMPBASE/h.err")"
  cp "$HEFF/docker-compose.yml" "$TMPBASE/def_h_new.yml"
  _norm < "$TMPBASE/def_h_new.yml" > "$TMPBASE/def_h_new.norm.yml"
  _baseline_with_review profile_hermes_gpu_compose.yml "$TMPBASE/def_h_base.yml"
  cmp -s "$TMPBASE/def_h_new.norm.yml" "$TMPBASE/def_h_base.yml" \
    || _fail "default hermes+gpu render differs from baseline $BASE_REV:
$(diff "$TMPBASE/def_h_new.norm.yml" "$TMPBASE/def_h_base.yml")"
  grep -qF 'name: cbox-p' "$TMPBASE/def_h_new.yml" && grep -q 'hermes-home:' "$TMPBASE/def_h_new.yml" || _fail "hermes variant did not render the hermes volume"
  _ok "default render with hermes and gpu is byte-identical to the baseline fixtures from $BASE_REV except the CBOX_REVIEW and CBOX_BUDGET_MODE env lines (and the CBOX_HERMES_DELEGATE_CONTEXT_LENGTH line next to the delegate env line when hermes is on)"
  GLI="$TMPBASE/glinstall"
  mkdir -p "$GLI/generated/state" "$GLI/generated/claude-config" "$GLI/generated/hooks" "$GLI/home"
  cp -r "$INSTALL_DIR/etc" "$INSTALL_DIR/templates" "$INSTALL_DIR/lib" "$GLI/"
  cp "$INSTALL_DIR/_common.sh" "$INSTALL_DIR/entrypoint.sh" "$INSTALL_DIR/install-bins.sh" "$GLI/"
  : > "$GLI/image.inputs"
  _render_global() {
    local gen="$1"
    (
      export HOME="$H" INSTALL_DIR="$GLI" XDG_RUNTIME_DIR="$RUNDIR"
      export CBOX_CLAUDE_MODE=mount CBOX_CODEX_MODE=mount CBOX_WORKSPACES="$ROOT" CBOX_USER_DIR="$TMPBASE/nouser" CBOX_NAME=cboxg
      . "$GLI/_common.sh"
      . "$gen"
      gen_compose
    )
  }
  _render_global "$GLI/templates/generators.sh" >/dev/null 2>"$TMPBASE/gn.err" || _fail "global render failed: $(cat "$TMPBASE/gn.err")"
  cp "$GLI/docker-compose.yml" "$TMPBASE/glob_new.yml"
  _norm < "$TMPBASE/glob_new.yml" > "$TMPBASE/glob_new.norm.yml"
  _baseline_with_review profile_global_compose.yml "$TMPBASE/glob_base.yml"
  cmp -s "$TMPBASE/glob_new.norm.yml" "$TMPBASE/glob_base.yml" \
    || _fail "global default render differs from baseline $BASE_REV:
$(diff "$TMPBASE/glob_new.norm.yml" "$TMPBASE/glob_base.yml")"
  grep -qxF -- '      - CBOX_REVIEW=ask' "$TMPBASE/glob_new.yml" || _fail "global render lacks the CBOX_REVIEW env line"
  grep -qxF -- '      - CBOX_BUDGET_MODE=on' "$TMPBASE/glob_new.yml" || _fail "global render lacks the CBOX_BUDGET_MODE=on env line"
  grep -qxF -- '      - CBOX_SUBSCRIPTION_PROFILE=high' "$TMPBASE/glob_new.yml" || _fail "global render lacks the CBOX_SUBSCRIPTION_PROFILE=high env line"
  for kv in CBOX_BUDGET_LOW_5H=15 CBOX_BUDGET_LOW_7D=20 CBOX_BUDGET_PACE_WINDOW_H=3 CBOX_BUDGET_PACE_SLACK_H=8; do
    grep -qxF -- "      - $kv" "$TMPBASE/glob_new.yml" || _fail "global render lacks the $kv env line"
  done
  CBOX_BUDGET_LOW_5H=10 CBOX_BUDGET_PACE_SLACK_H=12 _render_global "$GLI/templates/generators.sh" >/dev/null 2>"$TMPBASE/gbtune.err" || _fail "global budget tuned render failed: $(cat "$TMPBASE/gbtune.err")"
  grep -qxF -- '      - CBOX_BUDGET_LOW_5H=10' "$GLI/docker-compose.yml" || _fail "global render lacks the tuned CBOX_BUDGET_LOW_5H line"
  grep -qxF -- '      - CBOX_BUDGET_PACE_SLACK_H=12' "$GLI/docker-compose.yml" || _fail "global render lacks the tuned CBOX_BUDGET_PACE_SLACK_H line"
  _ok "global render: the regulator thresholds default to 15/20/3/8 and follow the configured values"
  CBOX_BUDGET_MODE=off _render_global "$GLI/templates/generators.sh" >/dev/null 2>"$TMPBASE/gboff.err" || _fail "global budget off render failed: $(cat "$TMPBASE/gboff.err")"
  grep -qxF -- '      - CBOX_BUDGET_MODE=off' "$GLI/docker-compose.yml" || _fail "global render with CBOX_BUDGET_MODE=off lacks the off env line"
  [ "$(grep -c 'CBOX_BUDGET_MODE=' "$GLI/docker-compose.yml")" = 1 ] || _fail "global render must carry exactly one CBOX_BUDGET_MODE line"
  grep -qxF -- '      - CBOX_SUBSCRIPTION_PROFILE=high' "$GLI/docker-compose.yml" || _fail "global render with CBOX_BUDGET_MODE=off lost the default CBOX_SUBSCRIPTION_PROFILE=high line"
  [ "$(grep -c 'CBOX_SUBSCRIPTION_PROFILE=' "$GLI/docker-compose.yml")" = 1 ] || _fail "global render must carry exactly one CBOX_SUBSCRIPTION_PROFILE line"
  _ok "global render: CBOX_BUDGET_MODE=off renders the off line exactly once"
  _ok "global default render is byte-identical to the baseline fixtures from $BASE_REV except the CBOX_REVIEW and CBOX_BUDGET_MODE env lines (and the CBOX_HERMES_DELEGATE_CONTEXT_LENGTH line next to the delegate env line when hermes is on)"
fi

PHASH="$(. "$INSTALL_DIR/_common.sh"; _cbox_path_hash "$ROOT")"
_render "$EFFP" work "$NEWGEN" CBOX_HERMES=on >/dev/null 2>"$TMPBASE/p.err" || _fail "profile render failed: $(cat "$TMPBASE/p.err")"
C="$EFFP/docker-compose.yml"
[ -f "$C" ] || _fail "profile render wrote no compose file"

head -1 "$C" | grep -qxF "name: cbox-p$PHASH-work" || _fail "profile compose name wrong: $(head -1 "$C")"
_ok "profile compose project name is cbox-p<hash>-<profile>"

grep -qxF '      cbox.profile: "work"' "$C" || _fail "cbox.profile label missing or not quoted"
grep -qxF "      cbox.effdir: \"$EFFP\"" "$C" || _fail "cbox.effdir label is not the profile eff"
grep -qxF "      cbox.phash: \"$PHASH\"" "$C" || _fail "cbox.phash label changed"
_ok "profile service labels: cbox.profile plus unchanged effdir and phash"

grep -qxF '      - CBOX_PROFILE=work' "$C" || _fail "CBOX_PROFILE env line wrong"
grep -qxF "      - CBOX_USAGE_DIR=$STORE/usage" "$C" || _fail "CBOX_USAGE_DIR env line wrong"
grep -qxF "      - CLAUDE_SECURESTORAGE_CONFIG_DIR=$STORE/claude" "$C" || _fail "CLAUDE_SECURESTORAGE_CONFIG_DIR not switched to the store"
if grep -qF 'CLAUDE_SECURESTORAGE_CONFIG_DIR=${HOST_HOME}/.claude' "$C"; then _fail "default securestorage dir still rendered"; fi
_ok "profile env: CBOX_PROFILE, CBOX_USAGE_DIR, CLAUDE_SECURESTORAGE_CONFIG_DIR point at the store"

grep -qF -- "$RUNDIR/cbox-clip-p$PHASH-work:/run/cbox-clip" "$C" || _fail "clip mount does not use the p<hash>-<profile> suffix: $(grep cbox-clip "$C")"
if grep -qF -- "$RUNDIR/cbox-clip-p$PHASH:" "$C"; then _fail "profile compose still mounts the default clip dir"; fi
_ok "clip bridge mount uses suffix p<hash>-<profile>"

LINK="$EFFP/claude-config/.credentials.json"
[ -L "$LINK" ] || _fail "statedir .credentials.json is not a symlink"
[ "$(readlink "$LINK")" = "$STORE/claude/.credentials.json" ] || _fail "statedir credentials symlink target is $(readlink "$LINK")"
[ "$(readlink "$EFFP/claude-config/history.jsonl")" = "$H/.claude/history.jsonl" ] || _fail "history.jsonl is not the shared host symlink"
_ok "statedir credentials symlink targets the store; history.jsonl stays shared"

[ ! -e "$EFFP/state/credentials-mask" ] || _fail "a credentials mask file is still rendered"
if grep -qF 'credentials-mask' "$C"; then _fail "profile compose still carries a credentials mask"; fi
if grep -qxF -- "      - $H/.claude:\${HOST_HOME}/.claude:rw" "$C"; then _fail "profile compose still binds the whole host claude dir"; fi
if grep -qF -- "      - $H/.claude:" "$C"; then _fail "profile compose binds the claude dir itself"; fi
if grep -qF -- "      - $H/.codex:" "$C"; then _fail "profile compose binds the whole host codex dir"; fi
if grep -qF 'credentials.json' "$C"; then _fail "profile compose mentions a credentials file: $(grep -F credentials.json "$C")"; fi
if grep -qF 'backups' "$C"; then _fail "profile compose reaches the claude backups dir"; fi
if grep -qF 'auth.json' "$C"; then _fail "profile compose mentions a codex auth file"; fi
python3 - "$C" "$H" "$STORE" "$EFFP" <<'PY' || _fail "profile compose bind sources outside the allowlist"
import re, sys
compose, home, store, effp = sys.argv[1:5]
claude = home + "/.claude"
allowed_claude = {
    "history.jsonl", "tasks", "jobs", "session-env", "plugins", "file-history", "plans",
    "shell-snapshots", "agent-memory", "commands", "skills", "rules", "hooks", "settings.json",
    "CLAUDE.md", "agents", "policies", "templates",
}
seen = set()
for line in open(compose):
    m = re.match(r"^      - (/[^:]+):(\S+?)(:(rw|ro))?$", line.rstrip("\n"))
    if not m:
        continue
    src, dst = m.group(1), m.group(2)
    if src == claude or src.startswith(claude + "/"):
        rel = src[len(claude) + 1:]
        first = rel.split("/")[0]
        assert first in allowed_claude or first == "projects", line
        assert ".credentials" not in rel and first != "backups", line
        seen.add(first)
assert allowed_claude <= seen, sorted(allowed_claude - seen)
PY
for d in history.jsonl:rw tasks:rw jobs:rw session-env:rw plugins:rw file-history:rw plans:rw shell-snapshots:rw agent-memory:rw commands:ro skills:ro rules:ro hooks:ro settings.json:rw CLAUDE.md:ro agents:ro policies:ro templates:ro; do
  grep -qxF -- "      - $H/.claude/${d%%:*}:\${HOST_HOME}/.claude/${d%%:*}:${d##*:}" "$C" || _fail "profile compose lacks the shared bind ${d%%:*} (${d##*:})"
done
grep -qxF -- "      - $EFFP/audit:\${HOST_HOME}/.claude/cbox-audit:rw" "$C" || _fail "profile audit dir bind missing"
grep -qxF -- '      - CODEX_GUARD_AUDIT=${HOST_HOME}/.claude/cbox-audit/codex_guard_audit.container.jsonl' "$C" || _fail "profile codex guard audit path"
grep -qxF -- '      - ASK_CLAUDE_AUDIT=${HOST_HOME}/.claude/cbox-audit/ask_claude_audit.container.jsonl' "$C" || _fail "profile ask-claude audit path"
grep -qxF -- '      - CBOX_LOCAL_MODEL_AUDIT=${HOST_HOME}/.claude/cbox-audit/local_model_audit.container.jsonl' "$C" || _fail "profile local model audit path"
grep -qxF -- '      - CBOX_HERMES_DELEGATE_AUDIT=${HOST_HOME}/.claude/cbox-audit/hermes_delegate_audit.container.jsonl' "$C" || _fail "profile hermes delegate audit path"
grep -F 'CBOX_MANAGED_DIRS=' "$C" | grep -qF '${HOST_HOME}/.claude:' || _fail "profile managed dirs must own the intermediate claude dir"
grep -qxF -- '      - CBOX_REVIEW=ask' "$C" || _fail "profile render lacks the CBOX_REVIEW env line"
grep -qxF -- '      - CBOX_BUDGET_MODE=on' "$C" || _fail "profile render lacks the CBOX_BUDGET_MODE=on env line"
for kv in CBOX_BUDGET_LOW_5H=15 CBOX_BUDGET_LOW_7D=20 CBOX_BUDGET_PACE_WINDOW_H=3 CBOX_BUDGET_PACE_SLACK_H=8; do
  grep -qxF -- "      - $kv" "$C" || _fail "profile render lacks the $kv env line"
done
_ok "profile claude binds: explicit shared subpaths only - no whole-dir bind, no credentials file, no backups, no mask; audit logs per profile"

grep -qxF -- "      - $STORE/claude:$STORE/claude:rw" "$C" || _fail "store claude dir bind missing"
grep -qxF -- "      - $STORE/usage:$STORE/usage:rw" "$C" || _fail "store usage dir bind missing"
grep -qxF -- "      - $STORE/codex:\${HOST_HOME}/.codex:rw" "$C" || _fail "profile codex home must be the store codex dir"
grep -qxF -- "      - $H/.codex/config.toml:\${HOST_HOME}/.codex/config.toml:ro" "$C" || _fail "shared codex config bind missing"
[ -d "$STORE/codex/packages" ] && [ -f "$STORE/codex/config.toml" ] || _fail "store codex mountpoints not precreated"
for d in claude codex usage; do
  [ "$(stat -c %a "$STORE/$d")" = 700 ] || _fail "store dir $d mode is $(stat -c %a "$STORE/$d")"
done
[ -f "$STORE/codex/auth.json" ] && [ "$(stat -c %a "$STORE/codex/auth.json")" = 600 ] || _fail "store codex auth.json missing or not 0600"
_ok "store binds: claude and usage dirs at identical paths, the store codex dir is the profile codex home (no host codex auth in reach)"

grep -qxF -- '  hermes-home:' "$C" || _fail "hermes-home volume key missing"
grep -qxF "    name: cbox-p$PHASH-work-hermes-home" "$C" || _fail "hermes volume not per profile"
grep -qxF -- '      - hermes-home:${HOST_HOME}/.hermes-cbox' "$C" || _fail "hermes volume mount missing"
grep -qxF "    name: $(. "$INSTALL_DIR/_common.sh"; . "$NEWGEN"; _cbox_bins_volume hermes)" "$C" || _fail "hermes bins volume lost its shared name"
_ok "hermes home volume is per profile; bins volumes keep shared names"

if grep -qF -- "$H/.claude.json:" "$C"; then _fail "profile compose still binds the host .claude.json"; fi
grep -qxF -- "      - $EFFP/state/host-claude.json:\${HOST_HOME}/.claude.json:ro" "$C" || _fail "profile host seed bind missing"
for f in "$EFFP/claude-config/.claude.json" "$EFFP/state/host-claude.json"; do
  python3 - "$f" <<'PY' || _fail "seed $f carries account fields or lost onboarding state"
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("oauthAccount", "userID", "modelAccessCache", "cachedUsageUtilization", "cachedExtraUsageDisabledReason"):
    assert k not in d, k
assert d["hasCompletedOnboarding"] is True, d
assert d["projects"]["/q"]["hasTrustDialogAccepted"] is True, d
PY
done
[ "$(stat -c %a "$EFFP/state/host-claude.json")" = 600 ] || _fail "host seed mode is $(stat -c %a "$EFFP/state/host-claude.json")"
[ "$(stat -c %a "$EFFP/claude-config")" = 700 ] || _fail "profile statedir mode is $(stat -c %a "$EFFP/claude-config")"
python3 - "$EFFP/claude-config/.claude.json" <<'PY' || _fail "standard mcp seed merge missing from the profile .claude.json"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["mcpServers"], d
PY
if grep -qF 'default@example.test' "$EFFP/state/host-claude.json" "$EFFP/claude-config/.claude.json"; then _fail "default account email leaked into the profile"; fi
_ok "profile seeds strip account fields, keep onboarding state, take the mcp merge; no host .claude.json bind"

python3 - "$EFFP/claude-config/.claude.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["oauthAccount"] = {"emailAddress": "work@example.test"}
d["marker"] = 7
json.dump(d, open(p, "w"))
PY
printf '{"oauthAccount":{"emailAddress":"changed@example.test"},"hasCompletedOnboarding":true,"projects":{"/q":{"hasTrustDialogAccepted":true},"/fresh":{"hasTrustDialogAccepted":true}}}\n' > "$H/.claude.json"
_render "$EFFP" work "$NEWGEN" CBOX_HERMES=on >/dev/null 2>"$TMPBASE/p2.err" || _fail "profile re-render failed: $(cat "$TMPBASE/p2.err")"
python3 - "$EFFP/claude-config/.claude.json" <<'PY' || _fail "re-render overwrote the profile .claude.json"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["marker"] == 7, d
assert d["oauthAccount"]["emailAddress"] == "work@example.test", d
PY
python3 - "$EFFP/state/host-claude.json" <<'PY' || _fail "re-render did not refresh the host seed"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["projects"]["/fresh"]["hasTrustDialogAccepted"] is True, d
assert "oauthAccount" not in d, d
PY
if grep -qF 'changed@example.test' "$EFFP/state/host-claude.json"; then _fail "host seed refresh leaked the account"; fi
[ "$(stat -c %a "$EFFP/state/host-claude.json")" = 600 ] || _fail "refreshed host seed mode is $(stat -c %a "$EFFP/state/host-claude.json")"
[ "$(readlink "$LINK")" = "$STORE/claude/.credentials.json" ] || _fail "re-render changed the credentials symlink"
_ok "re-render keeps the seeded profile .claude.json (seed only if missing) and refreshes the host seed from the current host file"
printf '%s\n' "$ACCOUNT_JSON" > "$H/.claude.json"

printf 'rotated-token\n' > "$LINK.regular"
rm -f "$LINK"
mv "$LINK.regular" "$LINK"
_render "$EFFP" work "$NEWGEN" >/dev/null 2>"$TMPBASE/p3.err" || _fail "profile render with a replaced credentials file failed: $(cat "$TMPBASE/p3.err")"
[ -L "$LINK" ] || _fail "adopt-guard: statedir credentials not restored to a symlink"
[ "$(cat "$STORE/claude/.credentials.json")" = "rotated-token" ] || _fail "adopt-guard: regular file not moved into the store"
[ "$(stat -c %a "$STORE/claude/.credentials.json")" = 600 ] || _fail "adopt-guard: store credentials mode is $(stat -c %a "$STORE/claude/.credentials.json")"
_ok "adopt-guard (profile): regular statedir credentials moved into the store as 0600, symlink restored"

printf 'older\n' > "$STORE/claude/.credentials.json"
touch -d '2001-01-01' "$STORE/claude/.credentials.json"
rm -f "$LINK"
printf 'fresher\n' > "$LINK"
_render "$EFFP" work "$NEWGEN" >/dev/null 2>&1 || _fail "profile render failed on an older store target"
[ "$(cat "$STORE/claude/.credentials.json")" = "fresher" ] || _fail "adopt-guard: newer regular file did not replace the older target"
_ok "adopt-guard: a newer regular file replaces an older target"

printf 'store-newer\n' > "$STORE/claude/.credentials.json"
rm -f "$LINK"
printf 'stale\n' > "$LINK"
touch -d '2001-01-01' "$LINK"
_render "$EFFP" work "$NEWGEN" >/dev/null 2>&1 || _fail "profile render failed on a newer store target"
[ "$(cat "$STORE/claude/.credentials.json")" = "store-newer" ] || _fail "adopt-guard: stale regular file clobbered a newer target"
[ -L "$LINK" ] || _fail "adopt-guard: stale file was not replaced by the symlink"
_ok "adopt-guard: a stale regular file never clobbers a newer target"

(
  export HOME="$H" INSTALL_DIR
  . "$INSTALL_DIR/_common.sh"
  . "$NEWGEN"
  SD="$TMPBASE/sd_default"
  CT="$TMPBASE/ct_default/.credentials.json"
  mkdir -p "$SD" "$TMPBASE/ct_default" "$TMPBASE/jobs_default"
  printf 'fresh-default\n' > "$SD/.credentials.json"
  gen_claude_config_into "$SD" "$TMPBASE/jobs_default" "$CT"
  [ -L "$SD/.credentials.json" ] && [ "$(readlink "$SD/.credentials.json")" = "$CT" ] || exit 11
  [ "$(cat "$CT")" = "fresh-default" ] || exit 12
  printf 'tok\n' > "$CT"
  touch -d '2001-01-01' "$CT"
  rm -f "$SD/.credentials.json"
  printf 'newer-than-target\n' > "$SD/.credentials.json"
  gen_claude_config_into "$SD" "$TMPBASE/jobs_default" "$CT"
  [ "$(cat "$CT")" = "newer-than-target" ] || exit 13
  printf 'target-newest\n' > "$CT"
  rm -f "$SD/.credentials.json"
  printf 'old-statedir\n' > "$SD/.credentials.json"
  touch -d '2001-01-01' "$SD/.credentials.json"
  gen_claude_config_into "$SD" "$TMPBASE/jobs_default" "$CT"
  [ "$(cat "$CT")" = "target-newest" ] || exit 14
  VICTIM="$TMPBASE/victim"
  printf 'secret\n' > "$VICTIM"
  rm -f "$SD/.credentials.json"
  ln -s "$VICTIM" "$SD/.credentials.json"
  gen_claude_config_into "$SD" "$TMPBASE/jobs_default" "$CT"
  [ "$(cat "$VICTIM")" = "secret" ] || exit 15
  [ "$(readlink "$SD/.credentials.json")" = "$CT" ] || exit 16
  [ ! -L "$CT" ] || exit 17
  gen_claude_config_into "$SD" "$TMPBASE/jobs_default"
  [ "$(readlink "$SD/.credentials.json")" = "$H/.claude/.credentials.json" ] || exit 18
) || _fail "adopt-guard unit scenarios failed with exit $?"
_ok "adopt-guard unit: moves a regular file, leaves symlinks alone, newer-target rule holds, default target unchanged"

(
  export HOME="$H" INSTALL_DIR
  . "$INSTALL_DIR/_common.sh"
  . "$NEWGEN"
  SD="$TMPBASE/sd_symtarget"
  mkdir -p "$SD" "$TMPBASE/sd_symtarget_t" "$TMPBASE/jobs_symtarget"
  printf 'victim\n' > "$TMPBASE/sd_symtarget_t/real"
  ln -s "$TMPBASE/sd_symtarget_t/real" "$TMPBASE/sd_symtarget_t/.credentials.json"
  printf 'token\n' > "$SD/.credentials.json"
  gen_claude_config_into "$SD" "$TMPBASE/jobs_symtarget" "$TMPBASE/sd_symtarget_t/.credentials.json" 2>/dev/null
  [ "$(cat "$TMPBASE/sd_symtarget_t/real")" = "victim" ] || exit 21
  [ -f "$SD/.credentials.json" ] && [ ! -L "$SD/.credentials.json" ] || exit 22
  [ "$(cat "$SD/.credentials.json")" = "token" ] || exit 23
) || _fail "adopt-guard symlinked-target scenario failed with exit $?"
_ok "adopt-guard: a symlinked credentials target is never followed and the regular file is kept"

_expect_refusal() {
  local label="$1" msg="$2"
  shift 2
  if "$@" >"$TMPBASE/ref.out" 2>"$TMPBASE/ref.err"; then
    _fail "$label: render succeeded"
  fi
  grep -qF -- "$msg" "$TMPBASE/ref.err" || _fail "$label: wrong message: $(cat "$TMPBASE/ref.err")"
  _ok "$label"
}

REFEFF="$SCOPE/profiles/refuse"
mkdir -p "$REFEFF" "$H/.config/cbox/profiles/refuse"
_expect_refusal "volume claude mode refuses a profile" "needs claude and codex mode mount" _render "$REFEFF" refuse "$NEWGEN" CBOX_CLAUDE_MODE=volume
_expect_refusal "volume codex mode refuses a profile" "needs claude and codex mode mount" _render "$REFEFF" refuse "$NEWGEN" CBOX_CODEX_MODE=volume
[ ! -e "$REFEFF/docker-compose.yml" ] || _fail "a refused render left a compose file"

_expect_refusal "mismatched container home refuses a profile" "container home to equal the host home" _render "$REFEFF" refuse "$NEWGEN" HOST_HOME=/elsewhere

BADEFF="$TMPBASE/not-a-profile-eff"
mkdir -p "$BADEFF"
_expect_refusal "eff outside <scope>/profiles/<profile> refused" "must render into" _render "$BADEFF" refuse "$NEWGEN"

NOSTORE="$SCOPE/profiles/ghost"
mkdir -p "$NOSTORE"
_expect_refusal "profile without a store refused" "missing or a symlink" _render "$NOSTORE" ghost "$NEWGEN"

LNSTORE="$SCOPE/profiles/linked"
mkdir -p "$LNSTORE" "$TMPBASE/elsewhere"
ln -s "$TMPBASE/elsewhere" "$H/.config/cbox/profiles/linked"
_expect_refusal "symlinked store refused" "missing or a symlink" _render "$LNSTORE" linked "$NEWGEN"

mkdir -p "$SCOPE/profiles/sub" "$H/.config/cbox/profiles/sub" "$TMPBASE/elsewhere2"
ln -s "$TMPBASE/elsewhere2" "$H/.config/cbox/profiles/sub/claude"
_expect_refusal "symlinked store subdirectory refused" "not a plain directory" _render "$SCOPE/profiles/sub" sub "$NEWGEN"

_expect_refusal "invalid profile name refused" "invalid CBOX_RENDER_PROFILE" _render "$REFEFF" "Bad_Name" "$NEWGEN"

GLOBAL_OUT="$TMPBASE/global"
mkdir -p "$GLOBAL_OUT/etc/mcp" "$GLOBAL_OUT/generated"
(
  export HOME="$H" INSTALL_DIR CBOX_RENDER_PROFILE=work CBOX_CLAUDE_MODE=mount CBOX_CODEX_MODE=mount
  . "$INSTALL_DIR/_common.sh"
  . "$NEWGEN"
  gen_compose
) >"$TMPBASE/g.out" 2>"$TMPBASE/g.err" && _fail "global gen_compose accepted a profile"
grep -qF 'not supported in the global scope' "$TMPBASE/g.err" || _fail "global refusal message wrong: $(cat "$TMPBASE/g.err")"
_ok "global gen_compose refuses a profile before writing anything"

for _yaml_name in true null off; do
  mkdir -p "$SCOPE/profiles/$_yaml_name" "$H/.config/cbox/profiles/$_yaml_name"
  chmod 0700 "$H/.config/cbox/profiles/$_yaml_name"
  _render "$SCOPE/profiles/$_yaml_name" "$_yaml_name" "$NEWGEN" >/dev/null 2>"$TMPBASE/y.err" || _fail "render of profile $_yaml_name failed: $(cat "$TMPBASE/y.err")"
  grep -qxF "      cbox.profile: \"$_yaml_name\"" "$SCOPE/profiles/$_yaml_name/docker-compose.yml" || _fail "label of profile $_yaml_name is not a quoted string"
  python3 - "$SCOPE/profiles/$_yaml_name/docker-compose.yml" "$_yaml_name" <<'PY' || _fail "profile $_yaml_name label does not parse to a string"
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'^      cbox\.profile: (.*)$', text, re.M)
assert m and m.group(1) == '"%s"' % sys.argv[2], m
PY
done
_ok "label quoting: profile names that YAML reads as booleans or null (true, null, off) render as quoted strings"


check_descriptor() {
  local claude_kind claude_file claude_mask codex_kind codex_file codex_home hermes_kind hermes_vol
  claude_kind="$(python3 "$REGPY" get "$REG" claude credentials.kind)"
  claude_file="$(python3 "$REGPY" get "$REG" claude credentials.file)"
  claude_mask="$(python3 "$REGPY" get "$REG" claude credentials.mask)"
  codex_kind="$(python3 "$REGPY" get "$REG" codex credentials.kind)"
  codex_file="$(python3 "$REGPY" get "$REG" codex credentials.file)"
  codex_home="$(python3 "$REGPY" get "$REG" codex credentials.home)"
  hermes_kind="$(python3 "$REGPY" get "$REG" hermes credentials.kind)"
  hermes_vol="$(python3 "$REGPY" get "$REG" hermes credentials.volume)"
  [ "$claude_kind" = statedir-symlink ] || _fail "descriptor: claude kind $claude_kind has no render implementation"
  [ "$codex_kind" = engine-home-file ] || _fail "descriptor: codex kind $codex_kind has no render implementation"
  [ "$hermes_kind" = volume ] || _fail "descriptor: hermes kind $hermes_kind has no render implementation"
  [ -L "$EFFP/claude-config/$claude_file" ] || _fail "descriptor: render has no statedir symlink named $claude_file"
  if grep -qF -- "${claude_mask#\~/}" "$C"; then _fail "descriptor: the claude credentials path $claude_mask must be absent from the profile container, not masked"; fi
  grep -qxF -- "      - $STORE/codex:\${HOST_HOME}/${codex_home#\~/}:rw" "$C" || _fail "descriptor: codex home $codex_home is not the store codex dir"
  if grep -qF -- "/$codex_file" "$C"; then _fail "descriptor: codex $codex_file must not be bound from the host"; fi
  [ -f "$STORE/codex/$codex_file" ] || _fail "descriptor: store has no codex $codex_file"
  grep -qxF -- "      - $hermes_vol:\${HOST_HOME}/.hermes-cbox" "$C" || _fail "descriptor: hermes volume $hermes_vol mount not rendered"
  grep -qxF "    name: cbox-p$PHASH-work-$hermes_vol" "$C" || _fail "descriptor: hermes volume $hermes_vol not renamed per profile"
}
_render "$EFFP" work "$NEWGEN" CBOX_HERMES=on >/dev/null 2>&1 || _fail "final profile render failed"
C="$EFFP/docker-compose.yml"
check_descriptor
_ok "ratchet: the engines.json credentials descriptors agree with the profile render (claude file absent, codex home = store dir)"

_render "$EFFP" work "$NEWGEN" CBOX_HERMES=on CBOX_BUDGET_MODE=off >/dev/null 2>"$TMPBASE/pboff.err" || _fail "profile budget off render failed: $(cat "$TMPBASE/pboff.err")"
grep -qxF -- '      - CBOX_BUDGET_MODE=off' "$EFFP/docker-compose.yml" || _fail "profile render with CBOX_BUDGET_MODE=off lacks the off env line"
[ "$(grep -c 'CBOX_BUDGET_MODE=' "$EFFP/docker-compose.yml")" = 1 ] || _fail "profile render must carry exactly one CBOX_BUDGET_MODE line"
_ok "profile render: CBOX_BUDGET_MODE=off renders the off line exactly once"

echo "PASS: all profile render checks"
