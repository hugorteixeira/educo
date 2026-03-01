#!/usr/bin/env bash

set -euo pipefail

ESP_IP="${1:-${ESP_IP:-192.168.15.2}}"
PCA_ADDR="${PCA_ADDR:-0x40}"
PCA_SDA="${PCA_SDA:-7}"
PCA_SCL="${PCA_SCL:-8}"
TEST_CHANNEL="${TEST_CHANNEL:-0}"
TEST_MIN_US="${TEST_MIN_US:-1000}"
TEST_MAX_US="${TEST_MAX_US:-2000}"
TEST_CENTER_US="${TEST_CENTER_US:-1500}"

BASE_URL="http://${ESP_IP}"

run() {
  local label="$1"
  local path="$2"
  echo
  echo "== ${label} =="
  echo "GET ${BASE_URL}${path}"
  curl -sS --max-time 5 "${BASE_URL}${path}"
  echo
}

echo "ESP32 PCA9685 setup/check"
echo "target=${BASE_URL} addr=${PCA_ADDR} sda=${PCA_SDA} scl=${PCA_SCL}"
echo "test channel=${TEST_CHANNEL} pulses=${TEST_MIN_US}/${TEST_CENTER_US}/${TEST_MAX_US}"

run "Reinit" "/api/pca/reinit?addr=${PCA_ADDR}&sda=${PCA_SDA}&scl=${PCA_SCL}"
run "Health" "/health"
run "I2C scan" "/api/pca/scan"
run "Debug (write center)" "/api/pca/debug?channel=${TEST_CHANNEL}&us=${TEST_CENTER_US}"
run "Move min" "/api/pca/move?channel=${TEST_CHANNEL}&us=${TEST_MIN_US}"
sleep 0.4
run "Move max" "/api/pca/move?channel=${TEST_CHANNEL}&us=${TEST_MAX_US}"
sleep 0.4
run "Move center" "/api/pca/move?channel=${TEST_CHANNEL}&us=${TEST_CENTER_US}"

echo
echo "done"
