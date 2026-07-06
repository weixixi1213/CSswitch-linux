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
SCIENCE_PUBLIC_PORT_FILE="$RUN_DIR/science.public_port"
SCIENCE_BACKEND_PORT_FILE="$RUN_DIR/science.backend_port"
PROXY_PORT="${PROXY_PORT:-18991}"
SCIENCE_PORT="${SCIENCE_PORT:-8000}"
SCIENCE_PUBLIC_PORT="$SCIENCE_PORT"
SCIENCE_BACKEND_PORT="$SCIENCE_PORT"

if [[ -f "$SCIENCE_PUBLIC_PORT_FILE" ]]; then
  SCIENCE_PUBLIC_PORT="$(cat "$SCIENCE_PUBLIC_PORT_FILE" 2>/dev/null || printf '%s' "$SCIENCE_PORT")"
fi
if [[ -f "$SCIENCE_BACKEND_PORT_FILE" ]]; then
  SCIENCE_BACKEND_PORT="$(cat "$SCIENCE_BACKEND_PORT_FILE" 2>/dev/null || printf '%s' "$SCIENCE_PUBLIC_PORT")"
fi

rewrite_science_url_port() {
  local raw_url="$1"
  local target_port="$2"
  "$PYTHON_BIN" - "$raw_url" "$target_port" <<'PY'
from urllib.parse import urlsplit, urlunsplit
import sys

raw_url, port_text = sys.argv[1:3]
port = int(port_text)
parts = urlsplit(raw_url)
host = parts.hostname or "localhost"
if ":" in host and not host.startswith("["):
    host = f"[{host}]"
default_port = 443 if parts.scheme == "https" else 80
netloc = host if port == default_port else f"{host}:{port}"
print(urlunsplit((parts.scheme, netloc, parts.path, parts.query, parts.fragment)))
PY
}

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
if [[ "$SCIENCE_PUBLIC_PORT" != "$SCIENCE_BACKEND_PORT" ]]; then
  echo "public port:  $SCIENCE_PUBLIC_PORT"
  echo "backend port: $SCIENCE_BACKEND_PORT"
fi

echo "== auth status =="
URL="$(HOME="$SANDBOX_HOME" "$SCIENCE_BIN" url --data-dir "$DATA_DIR" 2>/dev/null | tail -n 1 || true)"
if [[ -n "$URL" ]]; then
  if [[ "$SCIENCE_PUBLIC_PORT" != "$SCIENCE_BACKEND_PORT" ]]; then
    URL="$(rewrite_science_url_port "$URL" "$SCIENCE_PUBLIC_PORT")"
  fi
  COOKIE="$(mktemp)"
  trap 'rm -f "$COOKIE"' EXIT
  NONCE="$(printf '%s' "$URL" | sed -n 's#.*[?&]nonce=\([^&]*\).*#\1#p')"
  if [[ -n "$NONCE" ]] && curl -fsS -c "$COOKIE" "$URL" >/dev/null 2>&1; then
    curl -fsS -b "$COOKIE" -c "$COOKIE" \
      -X POST \
      --data-urlencode "nonce=$NONCE" \
      --data-urlencode "dest=/auth/status" \
      "http://localhost:${SCIENCE_PUBLIC_PORT}/api/auth/nonce" >/dev/null 2>&1 || true
    AUTH_JSON="$(curl -fsS -b "$COOKIE" "http://localhost:${SCIENCE_PUBLIC_PORT}/api/auth/status" 2>/dev/null || true)"
    if [[ -n "$AUTH_JSON" ]]; then
      "$PYTHON_BIN" - <<'PY' "$AUTH_JSON"
import json
import sys
print(json.dumps(json.loads(sys.argv[1]), indent=2))
PY
    fi
  fi
fi

echo "== access url =="
URL="$(HOME="$SANDBOX_HOME" "$SCIENCE_BIN" url --data-dir "$DATA_DIR" 2>/dev/null | tail -n 1 || true)"
if [[ -n "$URL" && "$SCIENCE_PUBLIC_PORT" != "$SCIENCE_BACKEND_PORT" ]]; then
  URL="$(rewrite_science_url_port "$URL" "$SCIENCE_PUBLIC_PORT")"
fi
printf '%s\n' "$URL"
