#!/bin/sh
set -eu
exec "${CBOX_CODEX_ACP_BIN:?}" --strict-config --dangerously-bypass-hook-trust "$@"
