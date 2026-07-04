#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
SCIENCE_BIN="${SCIENCE_BIN:-$(command -v claude-science)}"
STATE_ROOT="${STATE_ROOT:-${HOME:-/root}/.csswitch-linux}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
RUN_DIR="$STATE_ROOT/run"
SANDBOX_HOME="$STATE_ROOT/home"
DATA_DIR="$SANDBOX_HOME/.claude-science"
PROXY_PID_FILE="$RUN_DIR/proxy.pid"
PROXY_SECRET_FILE="$RUN_DIR/proxy.secret"
PROXY_PORT="${PROXY_PORT:-18991}"
SCIENCE_PORT="${SCIENCE_PORT:-8000}"

echo "== proxy process =="
if [[ -f "$PROXY_PID_FILE" ]]; then
  PID="$(cat "$PROXY_PID_FILE" 2>/dev/null || true)"
  if [[ -n "${PID:-}" ]] && kill -0 "$PID" 2>/dev/null; then
    echo "running pid=$PID"
  else
    echo "stale pid file"
  fi
else
  echo "not tracked"
fi

if [[ -f "$PROXY_SECRET_FILE" ]]; then
  SECRET="$(cat "$PROXY_SECRET_FILE")"
  echo "== proxy health =="
  curl -fsS "http://127.0.0.1:${PROXY_PORT}/${SECRET}/health" || true
  echo
fi

echo "== claude-science status =="
HOME="$SANDBOX_HOME" "$SCIENCE_BIN" status --data-dir "$DATA_DIR" || true

echo "== auth status =="
URL="$(HOME="$SANDBOX_HOME" "$SCIENCE_BIN" url --data-dir "$DATA_DIR" 2>/dev/null | tail -n 1 || true)"
if [[ -n "$URL" ]]; then
  COOKIE="$(mktemp)"
  trap 'rm -f "$COOKIE"' EXIT
  NONCE="$(printf '%s' "$URL" | sed -n 's#.*[?&]nonce=\([^&]*\).*#\1#p')"
  if [[ -n "$NONCE" ]] && curl -fsS -c "$COOKIE" "$URL" >/dev/null 2>&1; then
    curl -fsS -b "$COOKIE" -c "$COOKIE" \
      -X POST \
      --data-urlencode "nonce=$NONCE" \
      --data-urlencode "dest=/auth/status" \
      "http://localhost:${SCIENCE_PORT}/api/auth/nonce" >/dev/null 2>&1 || true
    AUTH_JSON="$(curl -fsS -b "$COOKIE" "http://localhost:${SCIENCE_PORT}/api/auth/status" 2>/dev/null || true)"
    if [[ -n "$AUTH_JSON" ]]; then
      "$PYTHON_BIN" - <<'PY' "$AUTH_JSON"
import json
import sys
print(json.dumps(json.loads(sys.argv[1]), indent=2))
PY
    fi
  fi
fi
