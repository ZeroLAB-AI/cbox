#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$EUID" -eq 0 ] || { echo "cbox: bind_egpu.sh must run as root - use sudo"; exit 1; }
[ -n "${SUDO_USER:-}" ] || { echo "cbox: SUDO_USER is not set - run this script via sudo from your user session, not as a direct root login"; exit 1; }
nvidia-smi -L >/dev/null 2>&1 || { echo "cbox: no NVIDIA device visible (nvidia-smi -L failed) - connect the eGPU and load the driver, then retry"; exit 1; }
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
echo "cbox: CDI spec written to /etc/cdi/nvidia.yaml - restarting container with GPU"
exec sudo -u "$SUDO_USER" "$DIR/cbox" restart --gpu
