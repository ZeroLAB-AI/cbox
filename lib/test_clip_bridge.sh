#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE="$INSTALL_DIR/etc/clipboard/clip_bridge.py"
SHIM="$INSTALL_DIR/etc/clipboard/wl_paste_shim.py"
TMPBASE="$(mktemp -d)"
BRIDGE_PID=""

cleanup() {
  if [ -n "$BRIDGE_PID" ] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
    kill "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
  fi
  rm -rf "$TMPBASE"
}
trap cleanup EXIT

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

[ -x "$BRIDGE" ] || _fail "clip_bridge.py not executable"
[ -x "$SHIM" ] || _fail "wl_paste_shim.py not executable"

FIXTURE="$TMPBASE/fixture.png"
python3 - "$FIXTURE" <<'PY'
import sys
path = sys.argv[1]
data = bytes((i * 37 + 11) % 256 for i in range(400))
with open(path, "wb") as fh:
    fh.write(data)
PY

FAKEBIN="$TMPBASE/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/wl-paste" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "--list-types" ]; then
  printf 'image/png\ntext/plain\n'
  exit 0
fi
if [ "\$1" = "--no-newline" ] && [ "\$2" = "--type" ] && [ "\$3" = "image/png" ]; then
  cat "$FIXTURE"
  exit 0
fi
exit 2
EOF
chmod +x "$FAKEBIN/wl-paste"

export PATH="$FAKEBIN:$PATH"
export WAYLAND_DISPLAY="test"
unset DISPLAY || true

SOCKDIR="$TMPBASE/clip"
python3 "$BRIDGE" --sock-dir "$SOCKDIR" --parent-pid "$$" >"$TMPBASE/bridge.log" 2>&1 &
BRIDGE_PID=$!

i=0
while [ ! -S "$SOCKDIR/clip.sock" ]; do
  i=$((i + 1))
  if [ "$i" -gt 50 ]; then
    _fail "bridge socket did not appear within 5s"
  fi
  sleep 0.1
done
_ok "bridge: socket appeared"

export CBOX_CLIP_SOCK="$SOCKDIR/clip.sock"

OUT="$(python3 "$SHIM" --list-types)"
echo "$OUT" | grep -q '^image/png$' || _fail "list-types: missing image/png"
if echo "$OUT" | grep -q '^text/plain$'; then
  _fail "list-types: text/plain leaked through allowlist"
fi
_ok "shim: list-types filtered to image/png only"

READBACK="$TMPBASE/readback.png"
python3 "$SHIM" --type image/png > "$READBACK"
cmp -s "$READBACK" "$FIXTURE" || _fail "shim: image/png payload not byte-identical to fixture"
_ok "shim: image/png read byte-identical to fixture"

if python3 "$SHIM" --type text/plain >/dev/null 2>&1; then
  _fail "shim: text/plain request should have failed"
fi
_ok "shim: text/plain refused"

if python3 "$SHIM" --frobnicate >/dev/null 2>&1; then
  _fail "shim: unknown flag should have failed"
fi
_ok "shim: unsupported flag refused"

python3 - "$SOCKDIR/clip.sock" <<'PY'
import socket
import struct
import sys

path = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect(path)
s.sendall(struct.pack(">I", 9999))
try:
    s.sendall(b"x" * 16)
except OSError:
    pass
try:
    data = s.recv(1)
except OSError:
    data = b""
s.close()
if data:
    status = data[0]
    if status not in (0x00, 0x01):
        sys.exit(1)
PY
_ok "bridge: oversize request rejected without crashing"

if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
  _fail "bridge: process died after oversize request"
fi

OUT2="$(python3 "$SHIM" --list-types)"
echo "$OUT2" | grep -q '^image/png$' || _fail "bridge: list-types broken after oversize request"
_ok "bridge: survives oversize request, still serving"

kill "$BRIDGE_PID" 2>/dev/null || true
wait "$BRIDGE_PID" 2>/dev/null || true
BRIDGE_PID=""

ELSEWHERE="$TMPBASE/elsewhere"
mkdir -p "$ELSEWHERE"
LINKDIR="$TMPBASE/link-sockdir"
ln -s "$ELSEWHERE" "$LINKDIR"

set +e
python3 "$BRIDGE" --sock-dir "$LINKDIR" --parent-pid "$$" >"$TMPBASE/bridge-symlink.log" 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] || _fail "bridge: symlinked sock-dir should have been refused"
_ok "bridge: symlinked sock-dir refused"

echo "PASS: clip bridge"
