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

PROBE_BIN="$TMPBASE/probebin"
mkdir -p "$PROBE_BIN"
for tool in wl-paste xclip; do
  printf '#!/bin/sh\nexit 0\n' > "$PROBE_BIN/$tool"
  chmod +x "$PROBE_BIN/$tool"
done

BASEBIN="$TMPBASE/basebin"
mkdir -p "$BASEBIN"
ln -s "$(command -v python3)" "$BASEBIN/python3"
PYTHON3_BIN="$(command -v python3)"
BASH_BIN="${BASH:-/bin/bash}"

_probe() {
  env -i PATH="$1:$BASEBIN" WAYLAND_DISPLAY="${2:-}" DISPLAY="${3:-}" "$PYTHON3_BIN" "$BRIDGE" --probe
}

[ "$(_probe "$PROBE_BIN" wayland-0 "")" = wayland ] || _fail "probe: wayland session with wl-paste must report wayland"
[ "$(_probe "$PROBE_BIN" "" :0)" = x11 ] || _fail "probe: x11 session with xclip must report x11"
[ "$(_probe "$TMPBASE/nonexistent" wayland-0 :0)" = none ] || _fail "probe: no tool on PATH must report none"
[ "$(_probe "$PROBE_BIN" "" "")" = none ] || _fail "probe: no display env must report none"
_ok "probe: backend verdict matches the bridge's own per-connection decision"

XONLY="$TMPBASE/xonly"
mkdir -p "$XONLY"
cp "$PROBE_BIN/xclip" "$XONLY/xclip"
[ "$(_probe "$XONLY" wayland-0 :0)" = x11 ] || _fail "probe: wayland session without wl-paste must fall through to x11"
_ok "probe: wayland session falls through to xclip when wl-paste is absent"

INSTALL_FN="$(awk '$0 == "_clip_install_cmd() {" , $0 == "}"' "$INSTALL_DIR/lib/cbox-setup.sh")"
PKG_FN="$(awk '$0 == "_clip_missing_pkg() {" , $0 == "}"' "$INSTALL_DIR/lib/cbox-setup.sh")"
[ -n "$INSTALL_FN" ] || _fail "cannot extract _clip_install_cmd"
[ -n "$PKG_FN" ] || _fail "cannot extract _clip_missing_pkg"

_mgr_case() {
  local mgr="$1" want="$2" bin="$TMPBASE/mgr-$1" got
  mkdir -p "$bin"
  printf '#!/bin/sh\nexit 0\n' > "$bin/$mgr"
  chmod +x "$bin/$mgr"
  got="$(PATH="$bin" "$BASH_BIN" -c "$INSTALL_FN"'
_clip_install_cmd wl-clipboard')"
  [ "$got" = "$want" ] || _fail "install cmd for $mgr: got '$got' want '$want'"
}

_mgr_case apt-get "apt-get install -y wl-clipboard"
_mgr_case dnf "dnf install -y wl-clipboard"
_mgr_case pacman "pacman -S --noconfirm wl-clipboard"
_mgr_case zypper "zypper install -y wl-clipboard"
_mgr_case apk "apk add wl-clipboard"
EMPTYBIN="$TMPBASE/nomgr"
mkdir -p "$EMPTYBIN"
[ -z "$(PATH="$EMPTYBIN" "$BASH_BIN" -c "$INSTALL_FN"'
_clip_install_cmd wl-clipboard')" ] || _fail "install cmd must be empty with no known package manager"
_ok "setup: install command per package manager, empty when none is known"

[ "$(WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 "$BASH_BIN" -c "$PKG_FN"'
_clip_missing_pkg')" = wl-clipboard ] || _fail "package pick: wayland session must ask for wl-clipboard"
[ "$(WAYLAND_DISPLAY= DISPLAY=:0 "$BASH_BIN" -c "$PKG_FN"'
_clip_missing_pkg')" = xclip ] || _fail "package pick: x11 session must ask for xclip"
[ -z "$(WAYLAND_DISPLAY= DISPLAY= "$BASH_BIN" -c "$PKG_FN"'
_clip_missing_pkg')" ] || _fail "package pick: headless session must ask for nothing"
_ok "setup: package pick follows the session type"

WARN_FN="$(awk '$0 == "_clip_backend_warn() {" , $0 == "}"' "$INSTALL_DIR/lib/cbox-setup.sh")"
[ -n "$WARN_FN" ] || _fail "cannot extract _clip_backend_warn"
awk '$0 == "run_rebless() {" , $0 == "}"' "$INSTALL_DIR/lib/cbox-setup.sh" | grep -q '_clip_backend_warn' || _fail "re-bless must report a missing host backend"
if awk '$0 == "run_rebless() {" , $0 == "}"' "$INSTALL_DIR/lib/cbox-setup.sh" | grep -q '_clip_host_preflight'; then
  _fail "re-bless must never run the interactive install offer"
fi
_ok "setup: re-bless reports a missing backend without installing anything"

grep -q -- '--probe' "$INSTALL_DIR/cbox" || _fail "cbox up must probe the host backend before starting the bridge"
grep -q "no host clipboard backend" "$INSTALL_DIR/cbox" || _fail "cbox up must warn when the bridge starts without a host backend"
_ok "cbox: bridge start warns instead of failing silently at the first paste"

echo "PASS: clip bridge"
