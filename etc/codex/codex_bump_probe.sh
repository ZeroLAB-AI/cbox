#!/usr/bin/env bash
set -euo pipefail

FAIL=0
PROBE_HOME="$(mktemp -d)"
export CODEX_HOME="$PROBE_HOME"

cleanup() {
  rm -rf "$PROBE_HOME"
}
trap cleanup EXIT

pass() {
  printf 'PROBE %s PASS %s\n' "$1" "${2:-}"
}

fail() {
  printf 'PROBE %s FAIL %s\n' "$1" "${2:-}"
  FAIL=1
}

note() {
  printf 'PROBE %s NOTE %s\n' "$1" "${2:-}"
}

if ! command -v codex >/dev/null 2>&1; then
  fail no-codex-binary "codex not found on PATH"
  exit 1
fi

cat > "$PROBE_HOME/config.toml" <<'EOF'
model = "base-model-x"
model_provider = "dead"
approval_policy = "never"
sandbox_mode = "danger-full-access"

[model_providers.dead]
name = "dead"
base_url = "http://127.0.0.1:9/v1"
wire_api = "responses"
EOF

version_output="$(codex --version 2>/dev/null || true)"
if [ -n "$version_output" ]; then
  pass version "$version_output"
else
  fail version "codex --version produced no output"
fi

percall_result="$(timeout 20 python3 - "$PROBE_HOME" <<'PYEOF'
import json
import os
import sys
import subprocess
import threading
import time

codex_home = sys.argv[1]
env = dict(os.environ)
env["CODEX_HOME"] = codex_home

proc = subprocess.Popen(
    ["codex", "mcp-server"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    env=env, text=True, bufsize=1,
)

found_model = [None]

def send(obj):
    proc.stdin.write(json.dumps(obj) + "\n")
    proc.stdin.flush()

def reader():
    try:
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if m.get("method") == "codex/event":
                msg = m.get("params", {}).get("msg", {})
                if msg.get("type") == "session_configured":
                    found_model[0] = msg.get("model")
                    return
    except Exception:
        pass

t = threading.Thread(target=reader, daemon=True)
t.start()

try:
    send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2024-11-05", "capabilities": {},
        "clientInfo": {"name": "cbox-bump-probe", "version": "0.0.1"}}})
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    send({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
        "name": "codex", "arguments": {
            "prompt": "hi", "model": "probe-model-x",
            "config": {"model_reasoning_effort": "low"},
            "approval-policy": "never", "sandbox": "danger-full-access",
            "cwd": codex_home}}})
    t.join(timeout=15)
finally:
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except Exception:
        proc.kill()

print(found_model[0] or "")
PYEOF
)"

if [ "$percall_result" = "probe-model-x" ]; then
  pass percall-injection "session model = $percall_result"
else
  fail percall-injection "session model = '$percall_result' (expected probe-model-x)"
fi

cat > "$PROBE_HOME/probe.config.toml" <<'EOF'
model = "probe-profile-model"
model_reasoning_effort = "low"
EOF

profile_output="$(timeout 15 codex exec --strict-config --profile probe --ephemeral --skip-git-repo-check "hi" < /dev/null 2>&1 || true)"

if printf '%s\n' "$profile_output" | grep -qE "unknown configuration field|legacy config (selector|profile)"; then
  fail profile-v2 "config rejected: $(printf '%s' "$profile_output" | grep -m1 -E 'unknown configuration field|legacy config (selector|profile)')"
elif printf '%s\n' "$profile_output" | grep -qF "model: probe-profile-model" ||
     printf '%s\n' "$profile_output" | grep -qF "probe-profile-model"; then
  pass profile-v2 "banner/session shows probe-profile-model"
else
  fail profile-v2 "profile model not observed in output"
fi

codex_bin="$(command -v codex)"
if command -v perl >/dev/null 2>&1; then
  strings_out="$(perl -ne 'print "$1\n" while /([ -~]{6,})/g' "$codex_bin")"
  has_override="$(printf '%s\n' "$strings_out" | grep -cF "AGENTS.override.md" || true)"
  has_base="$(printf '%s\n' "$strings_out" | grep -cF "AGENTS.md" || true)"
  if [ "${has_override:-0}" -gt 0 ] && [ "${has_base:-0}" -gt 0 ]; then
    pass agents-override "AGENTS.override.md and AGENTS.md both present in binary"
  else
    fail agents-override "AGENTS.override.md=${has_override:-0} AGENTS.md=${has_base:-0}"
  fi
else
  fail agents-override "perl not available for printable-string scan"
fi

cat > "$PROBE_HOME/probe.config.toml" <<'EOF'
model = "probe-profile-model"
model_reasoning_effort = "low"
notify = ["/bin/true"]
EOF

notify_output="$(timeout 15 codex exec --strict-config --profile probe --ephemeral --skip-git-repo-check "hi" < /dev/null 2>&1 || true)"

if printf '%s\n' "$notify_output" | grep -qE "unknown configuration field"; then
  fail notify-parse "notify key rejected: $(printf '%s' "$notify_output" | grep -m1 -E 'unknown configuration field')"
else
  pass notify-parse "notify key accepted by --strict-config"
fi

rm -f "$PROBE_HOME/probe.config.toml"

cflag_result="$(timeout 20 python3 - "$PROBE_HOME" <<'PYEOF'
import json
import os
import sys
import subprocess
import threading

codex_home = sys.argv[1]
env = dict(os.environ)
env["CODEX_HOME"] = codex_home

proc = subprocess.Popen(
    ["codex", "mcp-server", "-c", "model=cflag-model"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    env=env, text=True, bufsize=1,
)

found_model = [None]

def send(obj):
    proc.stdin.write(json.dumps(obj) + "\n")
    proc.stdin.flush()

def reader():
    try:
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if m.get("method") == "codex/event":
                msg = m.get("params", {}).get("msg", {})
                if msg.get("type") == "session_configured":
                    found_model[0] = msg.get("model")
                    return
    except Exception:
        pass

t = threading.Thread(target=reader, daemon=True)
t.start()

try:
    send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2024-11-05", "capabilities": {},
        "clientInfo": {"name": "cbox-bump-probe", "version": "0.0.1"}}})
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    send({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
        "name": "codex", "arguments": {"prompt": "hi", "cwd": codex_home}}})
    t.join(timeout=15)
finally:
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except Exception:
        proc.kill()

print(found_model[0] or "")
PYEOF
)"

if [ "$cflag_result" = "cflag-model" ]; then
  note cflag "alive - session model = cflag-model (-c model= now works for mcp-server)"
elif [ -n "$cflag_result" ]; then
  note cflag "dead - session model = $cflag_result (config default, -c model= still ignored)"
else
  note cflag "no session event observed"
fi

oss_mock_port=11577
oss_mock_pid=""
oss_mock_log="$PROBE_HOME/oss_mock.log"

oss_mock_cleanup() {
  if [ -n "$oss_mock_pid" ]; then
    kill "$oss_mock_pid" >/dev/null 2>&1 || true
    wait "$oss_mock_pid" 2>/dev/null || true
  fi
}

cat > "$PROBE_HOME/oss_mock.py" <<'PYEOF'
import http.server
import json
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 11577


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("HIT " + (fmt % args) + "\n")

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/api/tags", "/v1/models"):
            self._json({"models": [{"name": "gpt-oss:20b", "model": "gpt-oss:20b"}]})
            return
        self._json({"error": "not found"}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        try:
            payload = json.loads(raw) if raw else {}
        except Exception:
            payload = {}
        if self.path in ("/responses", "/v1/responses"):
            model = payload.get("model", "gpt-oss:20b")
            resp_obj = {
                "id": "resp-probe1", "object": "response", "model": model,
                "status": "completed",
                "output": [{
                    "type": "message", "role": "assistant", "id": "msg-probe1",
                    "content": [{"type": "output_text", "text": "probe ok"}]
                }],
            }
            events = [
                ("response.created", {"type": "response.created", "response": resp_obj}),
                ("response.completed", {"type": "response.completed", "response": resp_obj}),
            ]
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            for name, obj in events:
                self.wfile.write(("event: %s\ndata: %s\n\n" % (name, json.dumps(obj))).encode("utf-8"))
                self.wfile.flush()
            self.close_connection = True
            return
        self._json({"error": "unhandled path " + self.path}, 404)


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PYEOF

python3 "$PROBE_HOME/oss_mock.py" "$oss_mock_port" > "$oss_mock_log" 2>&1 &
oss_mock_pid=$!
trap 'oss_mock_cleanup; cleanup' EXIT

oss_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -s --max-time 1 "http://127.0.0.1:$oss_mock_port/api/tags" >/dev/null 2>&1; then
    oss_ready=1
    break
  fi
  sleep 0.3
done

if [ "$oss_ready" != "1" ]; then
  fail oss-base-url "mock ollama server on :$oss_mock_port did not come up"
else
  oss_home="$(mktemp -d)"
  oss_output="$(CODEX_HOME="$oss_home" CODEX_OSS_BASE_URL="http://127.0.0.1:$oss_mock_port" \
    timeout 20 codex exec --oss --local-provider ollama -m gpt-oss:20b \
    --skip-git-repo-check --ephemeral --sandbox danger-full-access \
    "say hi" < /dev/null 2>&1 || true)"
  rm -rf "$oss_home"

  if grep -qE "GET /(api/tags|v1/models)" "$oss_mock_log" 2>/dev/null || \
     printf '%s\n' "$oss_output" | grep -qF "probe ok"; then
    pass oss-base-url "CODEX_OSS_BASE_URL honored - mock at :$oss_mock_port received requests"
  elif printf '%s\n' "$oss_output" | grep -qF "No running Ollama server detected"; then
    fail oss-base-url "CODEX_OSS_BASE_URL ignored - codex tried default localhost:11434 instead of :$oss_mock_port"
  else
    fail oss-base-url "inconclusive - no mock hits and no clear default-dial error; output: $(printf '%s' "$oss_output" | tail -3 | tr '\n' ' ')"
  fi
fi

oss_mock_cleanup

exit "$FAIL"
