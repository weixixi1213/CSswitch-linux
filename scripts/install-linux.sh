#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

PREFIX="${PREFIX:-/usr/local/bin}"

mkdir -p "$PREFIX"

ln -sfn "$SCRIPT_DIR/start-linux.sh" "$PREFIX/csswitch-linux-start"
ln -sfn "$SCRIPT_DIR/fetch-models-linux.sh" "$PREFIX/csswitch-linux-fetch-models"
ln -sfn "$SCRIPT_DIR/stop-linux.sh" "$PREFIX/csswitch-linux-stop"
ln -sfn "$SCRIPT_DIR/status-linux.sh" "$PREFIX/csswitch-linux-status"
ln -sfn "$SCRIPT_DIR/verify-proxy.sh" "$PREFIX/csswitch-linux-verify-proxy"

echo "Installed csswitch-linux commands into $PREFIX"
echo "Try: csswitch-linux-start --provider deepseek --api-key <your-key>"
