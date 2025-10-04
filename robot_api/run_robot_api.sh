#!/usr/bin/env bash
set -euo pipefail

CFG_PATH="${ROBOT_CFG_PATH:-${ROBOT_API_CFG:-$(pwd)/robot_api.cfg}}"
export CFG_PATH
readarray -t CFG_INFO < <(python3 - <<'PY'
import configparser
import os
cfg_path = os.environ['CFG_PATH']
cfg = configparser.ConfigParser(inline_comment_prefixes=(';', '#'), strict=False)
cfg.read(cfg_path)
api_host = cfg.get('server', 'api_host', fallback='0.0.0.0').strip()
api_port = cfg.getint('server', 'api_port', fallback=8000)
print(api_host)
print(api_port)
PY
)
HOST="${CFG_INFO[0]:-0.0.0.0}"
PORT_FROM_CFG="${CFG_INFO[1]:-8000}"
export ROBOT_API_CFG="$CFG_PATH"
export ROBOT_CFG_PATH="$CFG_PATH"
export PYTHONUNBUFFERED=1
exec python3 -m uvicorn app.main:app --host "${HOST}" --port "${PORT:-$PORT_FROM_CFG}"
