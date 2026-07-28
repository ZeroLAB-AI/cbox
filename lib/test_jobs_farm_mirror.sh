#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

FARM="$INSTALL_DIR/etc/hooks/session_scope_farm.py"
[ -f "$FARM" ] || _fail "farm hook missing at $FARM"

python3 - "$FARM" "$TMPBASE" <<'EOF'
import json
import os
import shutil
import subprocess
import sys
import time

farm_hook = sys.argv[1]
tmp = sys.argv[2]
cfg = os.path.join(tmp, ".claude-cbox")
hostj = os.path.join(cfg, ".host-jobs")
hostp = os.path.join(cfg, ".host-projects")
jobs = os.path.join(cfg, "jobs")
root = "/zerolab/proj"
slug = "-zerolab-proj"
old = time.time() - 3600
env = dict(os.environ, CLAUDE_CONFIG_DIR=cfg,
           CBOX_SCOPE_ROOT=root, CBOX_SCOPE_SLUG=slug)

fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)
    else:
        print("ok: " + msg)


def run_farm():
    r = subprocess.run([sys.executable, farm_hook, "--once"], env=env)
    if r.returncode != 0:
        fails.append("farm hook exited %d" % r.returncode)


def write_job(base, jid, sid, state="running", when=old):
    d = os.path.join(base, jid)
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "state.json")
    with open(p, "w") as fh:
        json.dump({"sessionId": sid, "state": state, "sessionKind": "bg"}, fh)
    os.utime(p, (when, when))
    return d


def write_transcript(sl, sid, when=old):
    d = os.path.join(hostp, sl)
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, sid + ".jsonl")
    with open(p, "w") as fh:
        fh.write(json.dumps({"cwd": root}) + "\n")
    os.utime(p, (when, when))


os.makedirs(hostj, exist_ok=True)
os.makedirs(jobs, exist_ok=True)
write_transcript(slug, "sid-mirror")
write_transcript(slug, "sid-legacy")
write_transcript(slug, "sid-local")
write_job(hostj, "job-mirror", "sid-mirror")
write_job(hostj, "job-legacy", "sid-legacy")

legacy = os.path.join(jobs, "job-legacy")
if not os.path.lexists(legacy):
    os.symlink("../.host-jobs/job-legacy", legacy)

run_farm()

m = os.path.join(jobs, "job-mirror")
check(os.path.isdir(m) and not os.path.islink(m),
      "host job is published as a real directory, not a symlink")
st = os.path.join(m, "state.json")
check(os.path.isfile(st) and not os.path.islink(st),
      "state.json inside it is a real regular file, not a symlink")
check(json.load(open(st)).get("sessionId") == "sid-mirror",
      "the mirrored state.json carries the host content")

check(os.path.isdir(legacy) and not os.path.islink(legacy),
      "a legacy symlinked job entry is migrated to a real directory")
check(os.path.isfile(os.path.join(legacy, "state.json"))
      and not os.path.islink(os.path.join(legacy, "state.json")),
      "the migrated entry gets a real state.json too")

newer = time.time() - 10
p = os.path.join(hostj, "job-mirror", "state.json")
with open(p, "w") as fh:
    json.dump({"sessionId": "sid-mirror", "state": "done", "sessionKind": "bg"}, fh)
os.utime(p, (newer, newer))
run_farm()
check(json.load(open(st)).get("state") == "done",
      "a newer host state.json is refreshed into the mirror")
check(os.path.isdir(m) and not os.path.islink(m),
      "a terminal in-scope mirror is not absorbed back into a symlink")
check(os.path.isfile(st) and not os.path.islink(st),
      "the terminal mirror keeps a real state.json")

back = time.time() - 7200
with open(p, "w") as fh:
    json.dump({"sessionId": "sid-mirror", "state": "kill", "sessionKind": "bg"}, fh)
os.utime(p, (back, back))
run_farm()
check(json.load(open(st)).get("state") == "kill",
      "a same-size host change with an older mtime still refreshes the mirror")

local = write_job(jobs, "job-local", "sid-local", state="running")
run_farm()
check(os.path.isdir(local) and not os.path.exists(os.path.join(local, ".cbox-mirror")),
      "a container-local job is left alone and never marked as a mirror")
check(json.load(open(os.path.join(local, "state.json"))).get("sessionId") == "sid-local",
      "the container-local job keeps its own state.json")

shutil.rmtree(os.path.join(hostj, "job-mirror"))
run_farm()
check(not os.path.exists(m), "a mirror whose host job vanished is pruned")
check(os.path.isdir(local), "pruning mirrors does not touch container-local jobs")

top = os.path.join(hostj, "order")
with open(top, "w") as fh:
    fh.write("[]\n")
os.utime(top, (old, old))
run_farm()
ftop = os.path.join(jobs, "order")
check(os.path.isfile(ftop) and not os.path.islink(ftop),
      "top-level job files are copied as real files, not symlinked")

if fails:
    for f in fails:
        print("FAIL: " + f, file=sys.stderr)
    sys.exit(1)
EOF

echo "PASS: jobs farm mirror"
