#!/usr/bin/env bash

set -u

# Interactive PCA9685 joystick control for ESP32 API.
# Works in an SSH terminal (requires a TTY).

ESP_IP="${1:-${ESP_IP:-192.168.15.2}}"
PCA_ADDR="${PCA_ADDR:-0x40}"
PCA_SDA="${PCA_SDA:-7}"
PCA_SCL="${PCA_SCL:-8}"

# Default mapped channels (servo1..servo4). Override with CHANNELS="0,1,2,3"
CHANNELS_CSV="${CHANNELS:-0,4,12,8}"
MIN_US="${MIN_US:-1000}"
MAX_US="${MAX_US:-2000}"
STEP_US="${STEP_US:-20}"
BIG_STEP_US="${BIG_STEP_US:-80}"

# Profile persistence path (local machine where script runs)
PROFILE_PATH="${PROFILE_PATH:-$HOME/.config/esp32_pca9685_joystick.profile}"

# Hard safety clamps for SG90-style testing.
PULSE_MIN_HARD=100
PULSE_MAX_HARD=3000

BASE_URL="http://${ESP_IP}"
STATUS_MSG=""
SELECTED=0

IFS=',' read -r -a CHANNELS <<< "${CHANNELS_CSV}"
SERVO_COUNT="${#CHANNELS[@]}"

if [[ "${SERVO_COUNT}" -eq 0 ]]; then
  echo "No channels configured. Set CHANNELS (example: CHANNELS=0,4,12,8)."
  exit 1
fi

if [[ ! -t 0 ]]; then
  echo "This script needs an interactive terminal (TTY)."
  exit 1
fi

is_int() {
  [[ "${1:-}" =~ ^-?[0-9]+$ ]]
}

clamp_int() {
  local v="$1"
  local lo="$2"
  local hi="$3"
  if (( v < lo )); then
    echo "$lo"
  elif (( v > hi )); then
    echo "$hi"
  else
    echo "$v"
  fi
}

normalize_global_params() {
  if ! is_int "$MIN_US"; then MIN_US=1000; fi
  if ! is_int "$MAX_US"; then MAX_US=2000; fi
  if ! is_int "$STEP_US"; then STEP_US=20; fi
  if ! is_int "$BIG_STEP_US"; then BIG_STEP_US=80; fi

  MIN_US="$(clamp_int "$MIN_US" "$PULSE_MIN_HARD" $((PULSE_MAX_HARD - 1)))"
  MAX_US="$(clamp_int "$MAX_US" $((PULSE_MIN_HARD + 1)) "$PULSE_MAX_HARD")"

  if (( MIN_US >= MAX_US )); then
    MAX_US=$((MIN_US + 1))
    if (( MAX_US > PULSE_MAX_HARD )); then
      MAX_US=$PULSE_MAX_HARD
      MIN_US=$((MAX_US - 1))
    fi
  fi

  STEP_US="$(clamp_int "$STEP_US" 1 500)"
  BIG_STEP_US="$(clamp_int "$BIG_STEP_US" 1 2000)"
}

set_global_min() {
  local new="$1"
  if ! is_int "$new"; then return 1; fi
  new="$(clamp_int "$new" "$PULSE_MIN_HARD" $((PULSE_MAX_HARD - 1)))"
  if (( new >= MAX_US )); then
    new=$((MAX_US - 1))
  fi
  MIN_US="$new"
  return 0
}

set_global_max() {
  local new="$1"
  if ! is_int "$new"; then return 1; fi
  new="$(clamp_int "$new" $((PULSE_MIN_HARD + 1)) "$PULSE_MAX_HARD")"
  if (( new <= MIN_US )); then
    new=$((MIN_US + 1))
  fi
  MAX_US="$new"
  return 0
}

set_step() {
  local new="$1"
  if ! is_int "$new"; then return 1; fi
  STEP_US="$(clamp_int "$new" 1 500)"
  return 0
}

set_big_step() {
  local new="$1"
  if ! is_int "$new"; then return 1; fi
  BIG_STEP_US="$(clamp_int "$new" 1 2000)"
  return 0
}

validate_channels() {
  local ch
  for ch in "${CHANNELS[@]}"; do
    if ! is_int "$ch"; then
      echo "Invalid channel entry: $ch"
      exit 1
    fi
    if (( ch < 0 || ch > 15 )); then
      echo "Channel out of range: $ch (must be 0..15)"
      exit 1
    fi
  done
}

midpoint_for_index() {
  local idx="$1"
  echo $(( (SERVO_MIN_US[idx] + SERVO_MAX_US[idx]) / 2 ))
}

declare -a US_BY_INDEX
declare -a SERVO_MIN_US
declare -a SERVO_MAX_US

init_servo_arrays() {
  local i mid
  for ((i = 0; i < SERVO_COUNT; i++)); do
    SERVO_MIN_US[$i]="$MIN_US"
    SERVO_MAX_US[$i]="$MAX_US"
  done
  for ((i = 0; i < SERVO_COUNT; i++)); do
    mid="$(midpoint_for_index "$i")"
    US_BY_INDEX[$i]="$mid"
  done
}

normalize_servo_limit() {
  local idx="$1"
  local mn="${SERVO_MIN_US[$idx]}"
  local mx="${SERVO_MAX_US[$idx]}"

  if ! is_int "$mn"; then mn="$MIN_US"; fi
  if ! is_int "$mx"; then mx="$MAX_US"; fi

  mn="$(clamp_int "$mn" "$PULSE_MIN_HARD" $((PULSE_MAX_HARD - 1)))"
  mx="$(clamp_int "$mx" $((PULSE_MIN_HARD + 1)) "$PULSE_MAX_HARD")"

  if (( mn >= mx )); then
    mx=$((mn + 1))
    if (( mx > PULSE_MAX_HARD )); then
      mx=$PULSE_MAX_HARD
      mn=$((mx - 1))
    fi
  fi

  SERVO_MIN_US[$idx]="$mn"
  SERVO_MAX_US[$idx]="$mx"

  if ! is_int "${US_BY_INDEX[$idx]}"; then
    US_BY_INDEX[$idx]="$(midpoint_for_index "$idx")"
  fi
  US_BY_INDEX[$idx]="$(clamp_int "${US_BY_INDEX[$idx]}" "$mn" "$mx")"
}

normalize_all_servo_limits() {
  local i
  for ((i = 0; i < SERVO_COUNT; i++)); do
    normalize_servo_limit "$i"
  done
}

clamp_us_for_index() {
  local idx="$1"
  local v="$2"
  local mn="${SERVO_MIN_US[$idx]}"
  local mx="${SERVO_MAX_US[$idx]}"
  if (( v < mn )); then
    echo "$mn"
  elif (( v > mx )); then
    echo "$mx"
  else
    echo "$v"
  fi
}

join_array_csv() {
  local -n arr_ref="$1"
  local out=""
  local i
  for ((i = 0; i < ${#arr_ref[@]}; i++)); do
    if [[ -n "$out" ]]; then out+=","; fi
    out+="${arr_ref[$i]}"
  done
  echo "$out"
}

load_profile() {
  if [[ ! -f "$PROFILE_PATH" ]]; then
    STATUS_MSG="profile not found: $PROFILE_PATH"
    return 1
  fi

  local line key value
  local mins_csv=""
  local maxs_csv=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    [[ "$line" != *=* ]] && continue

    key="${line%%=*}"
    value="${line#*=}"

    case "$key" in
      MIN_US)
        if is_int "$value"; then MIN_US="$value"; fi
        ;;
      MAX_US)
        if is_int "$value"; then MAX_US="$value"; fi
        ;;
      STEP_US)
        if is_int "$value"; then STEP_US="$value"; fi
        ;;
      BIG_STEP_US)
        if is_int "$value"; then BIG_STEP_US="$value"; fi
        ;;
      SERVO_MINS)
        mins_csv="$value"
        ;;
      SERVO_MAXS)
        maxs_csv="$value"
        ;;
      PCA_ADDR)
        if [[ -n "$value" ]]; then PCA_ADDR="$value"; fi
        ;;
      PCA_SDA)
        if is_int "$value"; then PCA_SDA="$value"; fi
        ;;
      PCA_SCL)
        if is_int "$value"; then PCA_SCL="$value"; fi
        ;;
    esac
  done < "$PROFILE_PATH"

  normalize_global_params

  local parsed i
  if [[ -n "$mins_csv" ]]; then
    IFS=',' read -r -a parsed <<< "$mins_csv"
    for ((i = 0; i < SERVO_COUNT && i < ${#parsed[@]}; i++)); do
      if is_int "${parsed[$i]}"; then
        SERVO_MIN_US[$i]="${parsed[$i]}"
      fi
    done
  fi

  if [[ -n "$maxs_csv" ]]; then
    IFS=',' read -r -a parsed <<< "$maxs_csv"
    for ((i = 0; i < SERVO_COUNT && i < ${#parsed[@]}; i++)); do
      if is_int "${parsed[$i]}"; then
        SERVO_MAX_US[$i]="${parsed[$i]}"
      fi
    done
  fi

  normalize_all_servo_limits
  STATUS_MSG="profile loaded: $PROFILE_PATH"
  return 0
}

save_profile() {
  local dir mins_csv maxs_csv channels_csv

  dir="$(dirname "$PROFILE_PATH")"
  mkdir -p "$dir" || {
    STATUS_MSG="failed creating profile dir: $dir"
    return 1
  }

  mins_csv="$(join_array_csv SERVO_MIN_US)"
  maxs_csv="$(join_array_csv SERVO_MAX_US)"
  channels_csv="$(join_array_csv CHANNELS)"

  cat > "$PROFILE_PATH" <<PROFILE
# ESP32 PCA9685 joystick profile
# Generated automatically by esp32_pca9685_joystick.sh
PCA_ADDR=${PCA_ADDR}
PCA_SDA=${PCA_SDA}
PCA_SCL=${PCA_SCL}
CHANNELS=${channels_csv}
MIN_US=${MIN_US}
MAX_US=${MAX_US}
STEP_US=${STEP_US}
BIG_STEP_US=${BIG_STEP_US}
SERVO_MINS=${mins_csv}
SERVO_MAXS=${maxs_csv}
PROFILE

  STATUS_MSG="profile saved: $PROFILE_PATH"
  return 0
}

api_get() {
  local path="$1"
  curl -sS --max-time 3 "${BASE_URL}${path}" 2>&1
}

json_ok() {
  local body="$1"
  [[ "${body}" == *'"ok":true'* ]]
}

reinit_driver() {
  local body
  body="$(api_get "/api/pca/reinit?addr=${PCA_ADDR}&sda=${PCA_SDA}&scl=${PCA_SCL}")"
  if json_ok "${body}" && [[ "${body}" == *'"pca_ready":true'* ]]; then
    STATUS_MSG="reinit ok (${PCA_ADDR}, sda=${PCA_SDA}, scl=${PCA_SCL})"
    return 0
  fi
  STATUS_MSG="reinit failed: ${body}"
  return 1
}

move_index_to_us() {
  local idx="$1"
  local us="$2"
  local ch="${CHANNELS[$idx]}"
  local body

  us="$(clamp_us_for_index "$idx" "$us")"
  body="$(api_get "/api/pca/move?channel=${ch}&us=${us}")"
  if json_ok "${body}"; then
    US_BY_INDEX[$idx]="$us"
    STATUS_MSG="ch=${ch} us=${us}"
    return 0
  fi
  STATUS_MSG="move failed ch=${ch}: ${body}"
  return 1
}

center_selected() {
  local idx="$1"
  local mid
  mid="$(midpoint_for_index "$idx")"
  move_index_to_us "$idx" "$mid"
}

center_all() {
  local i
  for ((i = 0; i < SERVO_COUNT; i++)); do
    center_selected "$i" >/dev/null || return 1
    sleep 0.08
  done
  STATUS_MSG="all centered"
  return 0
}

sweep_index() {
  local idx="$1"
  local mn="${SERVO_MIN_US[$idx]}"
  local mx="${SERVO_MAX_US[$idx]}"

  move_index_to_us "${idx}" "${mn}" || return 1
  sleep 0.25
  move_index_to_us "${idx}" "${mx}" || return 1
  sleep 0.25
  move_index_to_us "${idx}" "${mn}" || return 1
  sleep 0.25
  move_index_to_us "${idx}" "${mx}" || return 1
  sleep 0.25
  center_selected "${idx}" || return 1
  STATUS_MSG="sweep done ch=${CHANNELS[$idx]}"
  return 0
}

sweep_all() {
  local i
  for ((i = 0; i < SERVO_COUNT; i++)); do
    sweep_index "$i" || return 1
    sleep 0.1
  done
  STATUS_MSG="sweep all done"
  return 0
}

set_selected_min_from_current() {
  local idx="$1"
  local cur="${US_BY_INDEX[$idx]}"
  local mx="${SERVO_MAX_US[$idx]}"
  if (( cur >= mx )); then
    cur=$((mx - 1))
  fi
  SERVO_MIN_US[$idx]="$cur"
  normalize_servo_limit "$idx"
  STATUS_MSG="servo $((idx + 1)) min set to ${SERVO_MIN_US[$idx]}"
}

set_selected_max_from_current() {
  local idx="$1"
  local cur="${US_BY_INDEX[$idx]}"
  local mn="${SERVO_MIN_US[$idx]}"
  if (( cur <= mn )); then
    cur=$((mn + 1))
  fi
  SERVO_MAX_US[$idx]="$cur"
  normalize_servo_limit "$idx"
  STATUS_MSG="servo $((idx + 1)) max set to ${SERVO_MAX_US[$idx]}"
}

adjust_selected_min() {
  local idx="$1"
  local delta="$2"
  local new=$((SERVO_MIN_US[idx] + delta))
  SERVO_MIN_US[$idx]="$new"
  normalize_servo_limit "$idx"
  STATUS_MSG="servo $((idx + 1)) min=${SERVO_MIN_US[$idx]}"
}

adjust_selected_max() {
  local idx="$1"
  local delta="$2"
  local new=$((SERVO_MAX_US[idx] + delta))
  SERVO_MAX_US[$idx]="$new"
  normalize_servo_limit "$idx"
  STATUS_MSG="servo $((idx + 1)) max=${SERVO_MAX_US[$idx]}"
}

apply_global_limits_to_selected() {
  local idx="$1"
  SERVO_MIN_US[$idx]="$MIN_US"
  SERVO_MAX_US[$idx]="$MAX_US"
  normalize_servo_limit "$idx"
  STATUS_MSG="servo $((idx + 1)) limits reset to global ${MIN_US}..${MAX_US}"
}

apply_global_limits_to_all() {
  local i
  for ((i = 0; i < SERVO_COUNT; i++)); do
    SERVO_MIN_US[$i]="$MIN_US"
    SERVO_MAX_US[$i]="$MAX_US"
    normalize_servo_limit "$i"
  done
  STATUS_MSG="all servo limits reset to global ${MIN_US}..${MAX_US}"
}

print_health() {
  local body
  body="$(api_get "/health")"
  STATUS_MSG="health: ${body}"
}

show_help() {
  clear
  echo "ESP32 PCA9685 Joystick"
  echo "Target: ${BASE_URL}  addr=${PCA_ADDR}  sda=${PCA_SDA} scl=${PCA_SCL}"
  echo "Global defaults: min=${MIN_US} max=${MAX_US} step=${STEP_US} big_step=${BIG_STEP_US}"
  echo "Profile: ${PROFILE_PATH}"
  echo
  echo "Select servo: keys 1..${SERVO_COUNT}"
  echo "Move selected servo:"
  echo "  Left/Right arrows : -/+ step"
  echo "  Up/Down arrows    : +/- big step"
  echo "  a/d               : -/+ step"
  echo "  w/s               : +/- big step"
  echo "  z/x               : selected min/max"
  echo "  c                 : center selected"
  echo "Calibration controls:"
  echo "  k                 : set selected MIN to current position"
  echo "  l                 : set selected MAX to current position"
  echo "  n/m               : selected MIN -/+ 10us"
  echo "  ,/.               : selected MAX -/+ 10us"
  echo "  y                 : reset selected limits to global defaults"
  echo "  Y                 : reset all servo limits to global defaults"
  echo "Global defaults controls:"
  echo "  u/j               : global MIN -/+ 10us"
  echo "  i/o               : global MAX -/+ 10us"
  echo "  [/]               : step -/+ 1us"
  echo "  { / }             : big_step -/+ 5us"
  echo "Actions:"
  echo "  t                 : sweep selected servo"
  echo "  g                 : sweep all mapped servos"
  echo "  C                 : center all mapped servos"
  echo "  r                 : reinit PCA"
  echo "  h                 : health check"
  echo "  v                 : save profile"
  echo "  b                 : load profile"
  echo "  q                 : quit"
  echo
  echo "Channels and limits:"
  local i mark
  for ((i = 0; i < SERVO_COUNT; i++)); do
    mark=" "
    if (( i == SELECTED )); then mark=">"; fi
    printf " %s servo%-2d ch=%-2s us=%-4s range=%s..%s\n" \
      "${mark}" "$((i + 1))" "${CHANNELS[$i]}" "${US_BY_INDEX[$i]}" "${SERVO_MIN_US[$i]}" "${SERVO_MAX_US[$i]}"
  done
  echo
  echo "Status: ${STATUS_MSG}"
}

read_key() {
  local key rest
  IFS= read -rsn1 key
  if [[ "${key}" == $'\x1b' ]]; then
    IFS= read -rsn2 -t 0.01 rest || true
    key+="${rest}"
  fi
  printf '%s' "${key}"
}

cleanup() {
  tput cnorm 2>/dev/null || true
  stty sane 2>/dev/null || true
}

validate_channels
normalize_global_params
init_servo_arrays
load_profile >/dev/null 2>&1 || true
normalize_all_servo_limits

trap cleanup EXIT
tput civis 2>/dev/null || true

reinit_driver >/dev/null || true
show_help

while true; do
  key="$(read_key)"
  case "${key}" in
    q|Q)
      break
      ;;
    h|H)
      print_health
      ;;
    r|R)
      reinit_driver >/dev/null || true
      ;;
    C)
      center_all >/dev/null || true
      ;;
    g|G)
      sweep_all >/dev/null || true
      ;;
    t|T)
      sweep_index "${SELECTED}" >/dev/null || true
      ;;
    c)
      center_selected "${SELECTED}" >/dev/null || true
      ;;
    z|Z)
      move_index_to_us "${SELECTED}" "${SERVO_MIN_US[$SELECTED]}" >/dev/null || true
      ;;
    x|X)
      move_index_to_us "${SELECTED}" "${SERVO_MAX_US[$SELECTED]}" >/dev/null || true
      ;;
    a|A|$'\x1b[D')
      current="${US_BY_INDEX[$SELECTED]}"
      move_index_to_us "${SELECTED}" "$((current - STEP_US))" >/dev/null || true
      ;;
    d|D|$'\x1b[C')
      current="${US_BY_INDEX[$SELECTED]}"
      move_index_to_us "${SELECTED}" "$((current + STEP_US))" >/dev/null || true
      ;;
    s|S|$'\x1b[B')
      current="${US_BY_INDEX[$SELECTED]}"
      move_index_to_us "${SELECTED}" "$((current - BIG_STEP_US))" >/dev/null || true
      ;;
    w|W|$'\x1b[A')
      current="${US_BY_INDEX[$SELECTED]}"
      move_index_to_us "${SELECTED}" "$((current + BIG_STEP_US))" >/dev/null || true
      ;;
    [1-9])
      idx=$((key - 1))
      if (( idx < SERVO_COUNT )); then
        SELECTED="${idx}"
        STATUS_MSG="selected servo $((idx + 1)) (ch=${CHANNELS[$idx]})"
      fi
      ;;
    u)
      set_global_min "$((MIN_US - 10))"
      STATUS_MSG="global min=${MIN_US}"
      ;;
    j)
      set_global_min "$((MIN_US + 10))"
      STATUS_MSG="global min=${MIN_US}"
      ;;
    i)
      set_global_max "$((MAX_US - 10))"
      STATUS_MSG="global max=${MAX_US}"
      ;;
    o)
      set_global_max "$((MAX_US + 10))"
      STATUS_MSG="global max=${MAX_US}"
      ;;
    '[')
      set_step "$((STEP_US - 1))"
      STATUS_MSG="step=${STEP_US}"
      ;;
    ']')
      set_step "$((STEP_US + 1))"
      STATUS_MSG="step=${STEP_US}"
      ;;
    '{')
      set_big_step "$((BIG_STEP_US - 5))"
      STATUS_MSG="big_step=${BIG_STEP_US}"
      ;;
    '}')
      set_big_step "$((BIG_STEP_US + 5))"
      STATUS_MSG="big_step=${BIG_STEP_US}"
      ;;
    n)
      adjust_selected_min "${SELECTED}" -10
      ;;
    m)
      adjust_selected_min "${SELECTED}" 10
      ;;
    ',')
      adjust_selected_max "${SELECTED}" -10
      ;;
    '.')
      adjust_selected_max "${SELECTED}" 10
      ;;
    k)
      set_selected_min_from_current "${SELECTED}"
      ;;
    l)
      set_selected_max_from_current "${SELECTED}"
      ;;
    y)
      apply_global_limits_to_selected "${SELECTED}"
      ;;
    Y)
      apply_global_limits_to_all
      ;;
    v|V)
      save_profile >/dev/null || true
      ;;
    b|B)
      load_profile >/dev/null || true
      ;;
    *)
      ;;
  esac
  show_help
done

echo "bye"
