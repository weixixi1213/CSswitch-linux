#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
SCIENCE_BIN="${SCIENCE_BIN:-$(command -v claude-science)}"
PYTHON_DIR="$(dirname "$PYTHON_BIN")"
PROVIDER="deepseek"
API_KEY="${API_KEY:-}"
RELAY_BASE="${RELAY_BASE:-}"
RELAY_MODEL="${RELAY_MODEL:-}"
RELAY_AUTO_SELECT_MODEL="${CSSWITCH_RELAY_AUTO_SELECT_MODEL:-0}"
PROXY_PORT="${PROXY_PORT:-18991}"
SCIENCE_PORT="${SCIENCE_PORT:-8000}"
SCIENCE_BACKEND_PORT="${SCIENCE_BACKEND_PORT:-}"
SANDBOX_PORT="${SANDBOX_PORT:-8001}"
HOST="${HOST:-127.0.0.1}"
STATE_ROOT="${STATE_ROOT:-${HOME:-/root}/.csswitch-linux}"
EMAIL="${EMAIL:-virtual@localhost.invalid}"
UNSAFE_FULL_ACCESS=0
SKIP_ONBOARDING=1
AUTO_SELECTED_RELAY_MODEL=0
SCIENCE_PROXY_ENABLED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) PROVIDER="$2"; shift 2 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --relay-base) RELAY_BASE="$2"; shift 2 ;;
    --relay-model) RELAY_MODEL="$2"; shift 2 ;;
    --auto-relay-model) RELAY_AUTO_SELECT_MODEL=1; shift ;;
    --proxy-port) PROXY_PORT="$2"; shift 2 ;;
    --science-port) SCIENCE_PORT="$2"; shift 2 ;;
    --science-backend-port) SCIENCE_BACKEND_PORT="$2"; shift 2 ;;
    --sandbox-port) SANDBOX_PORT="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --state-root) STATE_ROOT="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --unsafe-full-access) UNSAFE_FULL_ACCESS=1; shift ;;
    --no-skip-onboarding) SKIP_ONBOARDING=0; shift ;;
    *)
      echo "unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SCIENCE_BIN" ]]; then
  echo "claude-science not found in PATH" >&2
  exit 1
fi
if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "python not found: $PYTHON_BIN" >&2
  exit 1
fi
export PATH="$PYTHON_DIR:$PATH"

case "$PROVIDER" in
  deepseek|qwen|relay) ;;
  *)
    echo "provider must be one of: deepseek, qwen, relay" >&2
    exit 1
    ;;
esac

if [[ "$PROVIDER" == "relay" ]]; then
  if [[ -z "$API_KEY" ]]; then
    API_KEY="${CSSWITCH_RELAY_KEY:-}"
  fi
  if [[ -z "$RELAY_BASE" ]]; then
    RELAY_BASE="${CSSWITCH_RELAY_BASE_URL:-}"
  fi
  if [[ -z "$API_KEY" || -z "$RELAY_BASE" ]]; then
    echo "relay mode needs --api-key and --relay-base" >&2
    exit 1
  fi
else
  if [[ -z "$API_KEY" ]]; then
    if [[ "$PROVIDER" == "deepseek" ]]; then
      API_KEY="${DEEPSEEK_API_KEY:-}"
    else
      API_KEY="${DASHSCOPE_API_KEY:-}"
    fi
  fi
  if [[ -z "$API_KEY" ]]; then
    echo "$PROVIDER mode needs --api-key (or matching env var)" >&2
    exit 1
  fi
fi

RUN_DIR="$STATE_ROOT/run"
LOG_DIR="$STATE_ROOT/logs"
SANDBOX_HOME="$STATE_ROOT/home"
DATA_DIR="$SANDBOX_HOME/.claude-science"
PROXY_PID_FILE="$RUN_DIR/proxy.pid"
PROXY_SECRET_FILE="$RUN_DIR/proxy.secret"
PROXY_LOG_FILE="$LOG_DIR/proxy.log"
PROXY_STDOUT_FILE="$LOG_DIR/proxy.stdout.log"
SCIENCE_STDOUT_FILE="$LOG_DIR/science-bootstrap.log"
SCIENCE_PUBLIC_PORT_FILE="$RUN_DIR/science.public_port"
SCIENCE_BACKEND_PORT_FILE="$RUN_DIR/science.backend_port"
mkdir -p "$RUN_DIR" "$LOG_DIR" "$SANDBOX_HOME"

if [[ ! -f "$PROXY_SECRET_FILE" ]]; then
  tr -dc 'a-f0-9' < /dev/urandom | head -c 32 > "$PROXY_SECRET_FILE"
fi
AUTH_SECRET="$(cat "$PROXY_SECRET_FILE")"
PROXY_URL="http://127.0.0.1:${PROXY_PORT}/${AUTH_SECRET}"
FASTFAIL_PROXY="http://127.0.0.1:${PROXY_PORT}"
NO_PROXY_LIST="127.0.0.1,localhost,::1"
MASKED_PROXY_URL="http://127.0.0.1:${PROXY_PORT}/****"
SCIENCE_URL=""
AUTH_STATUS_JSON=""

ensure_virtual_login() {
  "$PYTHON_BIN" "$SCRIPT_DIR/make-virtual-oauth.py" \
    --auth-dir "$DATA_DIR" \
    --sandbox-root "$SANDBOX_HOME" \
    --email "$EMAIL"
}

patch_preferences() {
  [[ "$SKIP_ONBOARDING" == "1" ]] || return 0
  "$PYTHON_BIN" - "$DATA_DIR/preferences.json" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
data = {}
if path.exists():
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        data = {}
for key in (
    "allowlistOnboardingSeen",
    "dashboardSeenSessionsBaselined",
    "firstRunOnboardingComplete",
):
    data[key] = True
fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=str(path.parent))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
}

discover_relay_model() {
  local tmp_json
  tmp_json="$(mktemp)"
  trap 'rm -f "$tmp_json"' RETURN
  "$SCRIPT_DIR/fetch-models-linux.sh" \
    --provider relay \
    --api-key "$API_KEY" \
    --relay-base "$RELAY_BASE" \
    --json \
    >"$tmp_json"
  RELAY_MODEL="$("$PYTHON_BIN" - "$tmp_json" <<'PY'
import json
import sys

data = json.loads(open(sys.argv[1], encoding="utf-8").read()).get("data") or []
print((data[0] or {}).get("id", "") if data else "")
PY
)"
  if [[ -z "$RELAY_MODEL" ]]; then
    echo "relay fetch-models returned no models" >&2
    exit 1
  fi
  AUTO_SELECTED_RELAY_MODEL=1
  rm -f "$tmp_json"
  trap - RETURN
}

if [[ "$PROVIDER" == "relay" && -z "$RELAY_MODEL" ]]; then
  if [[ "$RELAY_AUTO_SELECT_MODEL" == "1" ]]; then
    discover_relay_model
  fi
fi

SCIENCE_PUBLIC_PORT="$SCIENCE_PORT"
SCIENCE_RUNTIME_PORT="$SCIENCE_PORT"
SCIENCE_PROXY_HOST="$HOST"
SCIENCE_UPSTREAM_HOST="$HOST"
if [[ "$SCIENCE_UPSTREAM_HOST" == "0.0.0.0" || "$SCIENCE_UPSTREAM_HOST" == "::" ]]; then
  SCIENCE_UPSTREAM_HOST="127.0.0.1"
fi
if [[ "$PROVIDER" == "relay" ]]; then
  SCIENCE_PROXY_ENABLED=1
  if [[ -z "$SCIENCE_BACKEND_PORT" ]]; then
    SCIENCE_BACKEND_PORT="$((SCIENCE_PUBLIC_PORT + 2))"
  fi
  if [[ "$SCIENCE_BACKEND_PORT" == "$SCIENCE_PUBLIC_PORT" ]]; then
    echo "science backend port must differ from public science port in relay mode" >&2
    exit 1
  fi
  SCIENCE_RUNTIME_PORT="$SCIENCE_BACKEND_PORT"
fi

printf '%s\n' "$SCIENCE_PUBLIC_PORT" > "$SCIENCE_PUBLIC_PORT_FILE"
printf '%s\n' "$SCIENCE_RUNTIME_PORT" > "$SCIENCE_BACKEND_PORT_FILE"

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

browser_science_url() {
  local raw_url
  raw_url="$(HOME="$SANDBOX_HOME" "$SCIENCE_BIN" url --data-dir "$DATA_DIR" 2>/dev/null | head -n 1)"
  [[ -n "$raw_url" ]] || return 1
  if [[ "$SCIENCE_PUBLIC_PORT" != "$SCIENCE_RUNTIME_PORT" ]]; then
    rewrite_science_url_port "$raw_url" "$SCIENCE_PUBLIC_PORT"
  else
    printf '%s\n' "$raw_url"
  fi
}

stop_proxy_if_running() {
  if [[ -f "$PROXY_PID_FILE" ]]; then
    local pid
    pid="$(cat "$PROXY_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      for _ in {1..20}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
      done
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PROXY_PID_FILE"
  fi
}

proxy_health() {
  curl -fsS "${PROXY_URL}/health" >/dev/null 2>&1
}

start_proxy() {
  stop_proxy_if_running
  local -a proxy_cmd
  proxy_cmd=( "$PYTHON_BIN" "$REPO_ROOT/proxy/csswitch_proxy.py"
    --provider "$PROVIDER"
    --port "$PROXY_PORT"
    --log "$PROXY_LOG_FILE"
  )
  (
    export CSSWITCH_AUTH_TOKEN="$AUTH_SECRET"
    case "$PROVIDER" in
      deepseek)
        export DEEPSEEK_API_KEY="$API_KEY"
        ;;
      qwen)
        export DASHSCOPE_API_KEY="$API_KEY"
        ;;
      relay)
        export CSSWITCH_RELAY_KEY="$API_KEY"
        export CSSWITCH_RELAY_BASE_URL="$RELAY_BASE"
        if [[ -n "$RELAY_MODEL" ]]; then
          export CSSWITCH_RELAY_MODEL="$RELAY_MODEL"
        fi
        if [[ "$SCIENCE_PROXY_ENABLED" == "1" ]]; then
          export CSSWITCH_SCIENCE_SHIM_HOST="$SCIENCE_PROXY_HOST"
          export CSSWITCH_SCIENCE_SHIM_PORT="$SCIENCE_PUBLIC_PORT"
          export CSSWITCH_SCIENCE_UPSTREAM_HOST="$SCIENCE_UPSTREAM_HOST"
          export CSSWITCH_SCIENCE_UPSTREAM_PORT="$SCIENCE_RUNTIME_PORT"
          export CSSWITCH_SCIENCE_DEFAULT_MODEL="${RELAY_MODEL:-claude-opus-4-8}"
        fi
        ;;
    esac
    nohup "${proxy_cmd[@]}" >"$PROXY_STDOUT_FILE" 2>&1 &
    echo $! > "$PROXY_PID_FILE"
  )
  for _ in {1..40}; do
    proxy_health && return 0
    sleep 0.25
  done
  echo "proxy failed to become healthy; see $PROXY_STDOUT_FILE" >&2
  exit 1
}

start_science() {
  HOME="$SANDBOX_HOME" "$SCIENCE_BIN" stop --data-dir "$DATA_DIR" >/dev/null 2>&1 || true
  local -a extra_flags
  extra_flags=( --allow-ephemeral-data-dir )
  if [[ "$UNSAFE_FULL_ACCESS" == "1" ]]; then
    extra_flags+=( --dangerously-no-sandbox --dangerously-skip-approvals )
  elif ! command -v bwrap >/dev/null 2>&1; then
    echo "bubblewrap not found; starting with --dangerously-no-sandbox" >&2
    extra_flags+=( --dangerously-no-sandbox )
  fi
  HOME="$SANDBOX_HOME" \
  ANTHROPIC_BASE_URL="$PROXY_URL" \
  https_proxy="$FASTFAIL_PROXY" HTTPS_PROXY="$FASTFAIL_PROXY" \
  no_proxy="$NO_PROXY_LIST" NO_PROXY="$NO_PROXY_LIST" \
  "$SCIENCE_BIN" serve \
    --data-dir "$DATA_DIR" \
    --port "$SCIENCE_RUNTIME_PORT" \
    --sandbox-port "$SANDBOX_PORT" \
    --host "$HOST" \
    --no-browser \
    --detached \
    --no-auto-update \
    "${extra_flags[@]}" \
    >"$SCIENCE_STDOUT_FILE" 2>&1
}

verify_virtual_login() {
  local url cookie auth_json nonce
  url="$(browser_science_url)"
  nonce="$(printf '%s' "$url" | sed -n 's#.*[?&]nonce=\([^&]*\).*#\1#p')"
  [[ -n "$nonce" ]] || { echo "failed to extract login nonce" >&2; return 1; }
  cookie="$(mktemp)"
  trap 'rm -f "$cookie"' RETURN
  curl -fsS -c "$cookie" "$url" >/dev/null
  curl -fsS -b "$cookie" -c "$cookie" \
    -X POST \
    --data-urlencode "nonce=$nonce" \
    --data-urlencode "dest=/auth/status" \
    "http://localhost:${SCIENCE_PUBLIC_PORT}/api/auth/nonce" >/dev/null
  auth_json="$(curl -fsS -b "$cookie" "http://localhost:${SCIENCE_PUBLIC_PORT}/api/auth/status")"
  "$PYTHON_BIN" - <<'PY' "$auth_json" >/dev/null
import json
import sys
data = json.loads(sys.argv[1])
if not data.get("authenticated"):
    raise SystemExit("virtual login check failed: authenticated=false")
PY
  rm -f "$cookie"
  trap - RETURN
  AUTH_STATUS_JSON="$auth_json"
  # The nonce used for verification is single-use. Print a fresh browser URL.
  SCIENCE_URL="$(browser_science_url)"
}

echo "== ensure virtual login =="
ensure_virtual_login
patch_preferences

echo "== start proxy =="
start_proxy
echo "proxy: ${MASKED_PROXY_URL}"
if [[ "$PROVIDER" == "relay" ]]; then
  if [[ "$AUTO_SELECTED_RELAY_MODEL" == "1" ]]; then
    echo "relay model: $RELAY_MODEL (auto-selected)"
  elif [[ -n "$RELAY_MODEL" ]]; then
    echo "relay model: $RELAY_MODEL"
  else
    echo "relay model: dynamic (requests pass through, UI list comes from /api/models)"
  fi
  if [[ "$SCIENCE_PROXY_ENABLED" == "1" ]]; then
    echo "science ui proxy: ${SCIENCE_PROXY_HOST}:${SCIENCE_PUBLIC_PORT} -> ${SCIENCE_UPSTREAM_HOST}:${SCIENCE_RUNTIME_PORT}"
  fi
fi

echo "== start claude-science =="
start_science
patch_preferences

echo "== verify auth status =="
verify_virtual_login

echo "== status =="
HOME="$SANDBOX_HOME" "$SCIENCE_BIN" status --data-dir "$DATA_DIR"

echo "== auth =="
echo "$AUTH_STATUS_JSON" | "$PYTHON_BIN" -m json.tool

echo "== logs =="
echo "proxy log:   $PROXY_LOG_FILE"
echo "science log: $DATA_DIR/logs"
echo "state root:  $STATE_ROOT"
echo "url:         $SCIENCE_URL"
