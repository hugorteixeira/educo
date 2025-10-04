#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_PATH="$SCRIPT_DIR/robot_api/robot_api.cfg"
API_ONLY=false
UI_MODE="python"

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  -c, --config PATH   Use a specific configuration file (INI format).
      --api-only      Launch the API without the web UI.
      --ui MODE       Choose UI: python (default) or none.
  -h, --help          Show this help message.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)
      [[ $# -lt 2 ]] && { echo "Missing path after $1" >&2; exit 1; }
      CONFIG_PATH="$2"
      shift 2
      ;;
    --api-only)
      API_ONLY=true
      shift
      ;;
    --ui)
      [[ $# -lt 2 ]] && { echo "Missing mode after --ui" >&2; exit 1; }
      UI_MODE=$(echo "$2" | tr "[:upper:]" "[:lower:]")
      case "$UI_MODE" in
        python|none) ;;
        *) echo "Unknown UI mode: $2" >&2; exit 1 ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Configuration file not found: $CONFIG_PATH" >&2
  exit 1
fi

CONFIG_PATH=$(python3 -c "import os,sys; print(os.path.abspath(sys.argv[1]))" "$CONFIG_PATH")

export ROBOT_CFG_PATH="$CONFIG_PATH"
export ROBOT_API_CFG="$CONFIG_PATH"

readarray -t CFG_DATA < <(python3 - <<'PY'
import configparser, os
cfg_path = os.environ['ROBOT_CFG_PATH']
cfg = configparser.ConfigParser(inline_comment_prefixes=(';', '#'), strict=False)
cfg.read(cfg_path)
api_host = cfg.get('server', 'api_host', fallback='0.0.0.0').strip()
api_port = cfg.getint('server', 'api_port', fallback=8000)
api_base = cfg.get('server', 'api_base_url', fallback='').strip()
if not api_base:
    host_for_base = '127.0.0.1' if api_host in {'0.0.0.0', '::'} else api_host
    api_base = f"http://{host_for_base}:{api_port}"
ui_host = cfg.get('server', 'ui_host', fallback='0.0.0.0').strip()
ui_port = cfg.getint('server', 'ui_port', fallback=3838)
servo_driver = cfg.get('mode', 'servo_driver', fallback='soft').strip().lower()
print(api_host)
print(api_port)
print(api_base)
print(ui_host)
print(ui_port)
print(servo_driver)
PY
)

API_HOST="${CFG_DATA[0]:-0.0.0.0}"
API_PORT="${CFG_DATA[1]:-8000}"
API_BASE_URL="${CFG_DATA[2]:-http://127.0.0.1:8000}"
UI_HOST="${CFG_DATA[3]:-0.0.0.0}"
UI_PORT="${CFG_DATA[4]:-3838}"
SERVO_DRIVER="${CFG_DATA[5]:-soft}"

export ROBOT_API_BASE_URL="$API_BASE_URL"
export ROBOT_UI_HOST="$UI_HOST"
export ROBOT_UI_PORT="$UI_PORT"

PIDS=()

cleanup() {
  trap - INT TERM EXIT
  for pid in "${PIDS[@]}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}

trap cleanup INT TERM EXIT

pushd "$SCRIPT_DIR/robot_api" >/dev/null
PORT="$API_PORT" HOST="$API_HOST" ./run_robot_api.sh &
API_PID=$!
PIDS+=("$API_PID")
popd >/dev/null
echo "[run_robot] API started on $API_HOST:$API_PORT using driver '$SERVO_DRIVER' (pid $API_PID)"

if ! $API_ONLY && [[ "$UI_MODE" == "python" ]]; then
  echo "[run_robot] Python UI available at ${API_BASE_URL%/}/ui"
elif [[ "$UI_MODE" == "none" ]]; then
  echo "[run_robot] UI disabled (--ui none). API running on $API_HOST:$API_PORT"
fi

if [[ "${#PIDS[@]}" -eq 0 ]]; then
  echo "Nothing to run. Use --api-only or --ui-only to select a component." >&2
  cleanup
  exit 1
fi

set +e
if command -v wait >/dev/null 2>&1 && [[ ${#PIDS[@]} -gt 1 ]]; then
  # shellcheck disable=SC2046
  wait -n "${PIDS[@]}"
  EXIT_CODE=$?
  cleanup
  exit "$EXIT_CODE"
else
  wait "${PIDS[0]}"
  EXIT_CODE=$?
  cleanup
  exit "$EXIT_CODE"
fi
