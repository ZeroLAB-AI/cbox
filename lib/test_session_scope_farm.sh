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

FARM="$INSTALL_DIR/etc/hooks/session_scope_farm.py"
[ -f "$FARM" ] || _fail "farm hook missing at $FARM"

python3 - "$FARM" "$TMPBASE" <<'EOF'
import json
import os
import subprocess
import sys
import time

farm_hook = sys.argv[1]
tmp = sys.argv[2]
cfg = os.path.join(tmp, ".claude-cbox")
hostp = os.path.join(cfg, ".host-projects")
root = "/zerolab/proj"
slug = "-zerolab-proj"
wslug = slug + "--claude-worktrees-x"
old = time.time() - 3600
env = dict(os.environ, CLAUDE_CONFIG_DIR=cfg,
           CBOX_SCOPE_ROOT=root, CBOX_SCOPE_SLUG=slug)


def run_farm():
    r = subprocess.run([sys.executable, farm_hook, "--once"], env=env)
    assert r.returncode == 0, "farm hook exited %d" % r.returncode


def ok(label):
    print("ok: %s" % label)


os.makedirs(os.path.join(hostp, wslug))
os.makedirs(os.path.join(cfg, "projects"))
with open(os.path.join(hostp, wslug, "s1.jsonl"), "w") as fh:
    fh.write(json.dumps({"cwd": root + "/.claude/worktrees/x"}) + "\n")
os.utime(os.path.join(hostp, wslug, "s1.jsonl"), (old, old))
os.symlink("../.host-projects/" + wslug, os.path.join(cfg, "projects", wslug))

lsl = os.path.join(cfg, "projects", slug + "--local")
os.makedirs(lsl)
with open(os.path.join(lsl, "loc.jsonl"), "w") as fh:
    fh.write(json.dumps({"cwd": root + "/sub"}) + "\n")
os.utime(os.path.join(lsl, "loc.jsonl"), (old, old))

run_farm()

wdir = os.path.join(cfg, "projects", wslug)
assert os.path.isdir(wdir) and not os.path.islink(wdir), \
    "in-scope host slug must become a real directory"
ok("symlink slug migrated to real dir")

f1 = os.path.join(wdir, "s1.jsonl")
assert os.path.islink(f1) and os.path.exists(f1), \
    "host transcript must appear as per-file symlink"
ok("per-file symlink for host transcript")

lf = os.path.join(lsl, "loc.jsonl")
assert os.path.islink(lf) and os.path.exists(lf), \
    "settled local transcript must be absorbed and re-linked"
assert os.path.isfile(os.path.join(hostp, slug + "--local", "loc.jsonl")), \
    "absorbed transcript must land in .host-projects"
ok("settled local transcript absorbed to host")

os.unlink(os.path.join(hostp, wslug, "s1.jsonl"))
run_farm()
assert not os.path.lexists(f1), "dangling per-file symlink must be pruned"
ok("dangling per-file symlink pruned")

fresh = os.path.join(lsl, "fresh.jsonl")
with open(fresh, "w") as fh:
    fh.write(json.dumps({"cwd": root}) + "\n")
run_farm()
assert os.path.isfile(fresh) and not os.path.islink(fresh), \
    "recently written local transcript must stay local"
ok("fresh local transcript kept local")

out_slug = "-other-project"
os.makedirs(os.path.join(hostp, out_slug))
with open(os.path.join(hostp, out_slug, "o.jsonl"), "w") as fh:
    fh.write(json.dumps({"cwd": "/other/project"}) + "\n")
run_farm()
assert not os.path.lexists(os.path.join(cfg, "projects", out_slug)), \
    "out-of-scope slug must not enter the farm"
ok("out-of-scope slug excluded")

local_out = os.path.join(cfg, "projects", slug + "-outside")
os.makedirs(local_out)
with open(os.path.join(local_out, "x.jsonl"), "w") as fh:
    fh.write(json.dumps({"cwd": "/elsewhere"}) + "\n")
os.utime(os.path.join(local_out, "x.jsonl"), (old, old))
run_farm()
assert os.path.isfile(os.path.join(local_out, "x.jsonl")), \
    "out-of-scope local dir must not be absorbed to host"
assert not os.path.lexists(os.path.join(hostp, slug + "-outside", "x.jsonl")), \
    "out-of-scope local transcript must not leak to .host-projects"
ok("out-of-scope local dir stays container-local")
EOF

echo "PASS: session scope farm"
