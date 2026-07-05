#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
PROVIDER="relay"
API_KEY="${API_KEY:-}"
RELAY_BASE="${RELAY_BASE:-}"
JSON_OUTPUT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) PROVIDER="$2"; shift 2 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --relay-base) RELAY_BASE="$2"; shift 2 ;;
    --json) JSON_OUTPUT=1; shift ;;
    *)
      echo "unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "python not found: $PYTHON_BIN" >&2
  exit 1
fi

case "$PROVIDER" in
  deepseek|qwen|relay) ;;
  *)
    echo "provider must be one of: deepseek, qwen, relay" >&2
    exit 1
    ;;
esac

if [[ "$PROVIDER" == "relay" ]]; then
  [[ -n "$API_KEY" ]] || API_KEY="${CSSWITCH_RELAY_KEY:-}"
  [[ -n "$RELAY_BASE" ]] || RELAY_BASE="${CSSWITCH_RELAY_BASE_URL:-}"
  if [[ -z "$API_KEY" || -z "$RELAY_BASE" ]]; then
    echo "relay mode needs --api-key and --relay-base" >&2
    exit 1
  fi
elif [[ -z "$API_KEY" ]]; then
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

TMP_JSON="$(mktemp)"
trap 'rm -f "$TMP_JSON"' EXIT

"$PYTHON_BIN" - "$REPO_ROOT/proxy/csswitch_proxy.py" "$PROVIDER" "$API_KEY" "$RELAY_BASE" >"$TMP_JSON" <<'PY'
import importlib.util
import json
import os
import sys

proxy_path, provider, api_key, relay_base = sys.argv[1:5]
sys.path.insert(0, os.path.dirname(proxy_path))
spec = importlib.util.spec_from_file_location("csswitch_proxy_fetch", proxy_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

mod.PROV_NAME = provider
mod.PROV = dict(mod.PROVIDERS[provider])
mod.KEY = api_key
if provider == "relay":
    base = relay_base.strip().rstrip("/")
    mod.PROV["url"] = base + "/v1/messages"
    mod.PROV["models_url"] = base + "/v1/models"

data = mod.fetch_relay_models() if mod.PROV.get("models_url") else [
    {
        "type": "model",
        "id": mid,
        "display_name": disp,
        "supports_tools": None,
        "created_at": "2026-01-01T00:00:00Z",
    }
    for mid, disp in mod.PROV["models"]
]
print(json.dumps({"data": data}, ensure_ascii=False))
PY

if [[ "$JSON_OUTPUT" == "1" ]]; then
  cat "$TMP_JSON"
  exit 0
fi

"$PYTHON_BIN" - "$TMP_JSON" <<'PY'
import json
import sys

data = json.loads(open(sys.argv[1], encoding="utf-8").read()).get("data") or []
for idx, item in enumerate(data, 1):
    mid = item.get("id", "")
    disp = item.get("display_name") or mid
    tools = item.get("supports_tools")
    suffix = ""
    if tools is True:
        suffix = " [tools]"
    elif tools is False:
        suffix = " [no-tools]"
    print(f"{idx}. {mid}\t{disp}{suffix}")
PY
