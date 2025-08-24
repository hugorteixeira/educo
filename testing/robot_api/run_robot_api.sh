#!/usr/bin/env bash
set -euo pipefail
export ROBOT_API_CFG="${ROBOT_API_CFG:-$(pwd)/robot_api.cfg}"
export PYTHONUNBUFFERED=1
exec python3 -m uvicorn app.main:app --host 0.0.0.0 --port "${PORT:-8000}"
