#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
SCIENCE_BIN="${SCIENCE_BIN:-$(command -v claude-science)}"
STATE_ROOT="${STATE_ROOT:-${HOME:-/root}/.csswitch-linux}"
RUN_DIR="$STATE_ROOT/run"
SANDBOX_HOME="$STATE_ROOT/home"
DATA_DIR="$SANDBOX_HOME/.claude-science"
PROXY_PID_FILE="$RUN_DIR/proxy.pid"
SCIENCE_PUBLIC_PORT_FILE="$RUN_DIR/science.public_port"
SCIENCE_BACKEND_PORT_FILE="$RUN_DIR/science.backend_port"

if [[ -n "${SCIENCE_BIN:-}" ]]; then
  HOME="$SANDBOX_HOME" "$SCIENCE_BIN" stop --data-dir "$DATA_DIR" >/dev/null 2>&1 || true
fi

if [[ -f "$PROXY_PID_FILE" ]]; then
  PID="$(cat "$PROXY_PID_FILE" 2>/dev/null || true)"
  if [[ -n "${PID:-}" ]] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "$PID" 2>/dev/null || break
      sleep 0.25
    done
    kill -9 "$PID" 2>/dev/null || true
  fi
  rm -f "$PROXY_PID_FILE"
fi

rm -f "$SCIENCE_PUBLIC_PORT_FILE" "$SCIENCE_BACKEND_PORT_FILE"

echo "stopped csswitch linux stack"
