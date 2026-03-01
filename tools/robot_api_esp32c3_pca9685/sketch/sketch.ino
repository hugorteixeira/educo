#include <WiFi.h>
#include <WebServer.h>
#include <Wire.h>
#include <ArduinoJson.h>
#include <math.h>
#include <stdlib.h>

// =========================
// Minimal ESP32-C3 + PCA9685 servo API
// =========================

// Wi-Fi (edit to your network)
static const char* WIFI_SSID = "HUGO&CAMILA";
static const char* WIFI_PASS = "cristalmilka123";

// Fallback AP if STA connection fails
static const char* AP_SSID = "ServoBridge";
static const char* AP_PASS = "12345678";

// I2C pins to try (ESP32-C3 board variants)
static const int I2C_CANDIDATE_PINS[][2] = {
  {7, 8},
  {8, 9},
  {9, 8},
  {6, 7},
  {7, 6},
  {4, 5},
  {5, 4}
};

// Default robot mapping (for compatibility with old pin-based clients)
static const int SERVO_COUNT = 4;
static const int SERVO_PINS[SERVO_COUNT] = {31, 33, 35, 37};
static const uint8_t SERVO_CHANNELS[SERVO_COUNT] = {0, 4, 12, 8};

// PCA9685 registers
static const uint8_t PCA_MODE1 = 0x00;
static const uint8_t PCA_MODE2 = 0x01;
static const uint8_t PCA_PRESCALE = 0xFE;
static const uint8_t PCA_LED0_ON_L = 0x06;

// Controller defaults
static const uint8_t PCA_DEFAULT_ADDR = 0x40;
static float g_pwmHz = 50.0f;

WebServer server(80);

static uint8_t g_pcaAddr = PCA_DEFAULT_ADDR;
static bool g_pcaReady = false;
static int g_activeSda = -1;
static int g_activeScl = -1;
static uint16_t g_lastCount[16];
static bool g_lastCountValid[16];
static float g_servoUs[SERVO_COUNT];
static bool g_servoEnabled[SERVO_COUNT];

// ---------- helpers ----------
static float clampf(float v, float lo, float hi) {
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

static int clampi(int v, int lo, int hi) {
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

static void jsonReply(int code, const String& body) {
  server.send(code, "application/json", body);
}

static void jsonError(int code, const char* message) {
  StaticJsonDocument<1024> doc;
  doc["ok"] = false;
  doc["error"] = message;
  String out;
  serializeJson(doc, out);
  jsonReply(code, out);
}

static bool parseStrictLong(const String& raw, long& out) {
  String s = raw;
  s.trim();
  if (s.length() == 0) return false;
  char* end = nullptr;
  long value = strtol(s.c_str(), &end, 10);
  if (end == s.c_str() || *end != '\0') return false;
  out = value;
  return true;
}

static bool parseStrictULong(const String& raw, unsigned long& out) {
  String s = raw;
  s.trim();
  if (s.length() == 0 || s.startsWith("-")) return false;
  char* end = nullptr;
  unsigned long value = strtoul(s.c_str(), &end, 10);
  if (end == s.c_str() || *end != '\0') return false;
  out = value;
  return true;
}

static bool parseStrictFloat(const String& raw, float& out) {
  String s = raw;
  s.trim();
  if (s.length() == 0) return false;
  char* end = nullptr;
  float value = strtof(s.c_str(), &end);
  if (end == s.c_str() || *end != '\0') return false;
  out = value;
  return true;
}

static bool parseFlexibleLong(const String& raw, long& out) {
  String s = raw;
  s.trim();
  if (s.length() == 0) return false;
  char* end = nullptr;
  long value = strtol(s.c_str(), &end, 0); // base 0 accepts 0xNN
  if (end == s.c_str() || *end != '\0') return false;
  out = value;
  return true;
}

static bool parseBoolValue(const String& raw, bool& out) {
  String s = raw;
  s.trim();
  s.toLowerCase();
  if (s == "1" || s == "true" || s == "yes" || s == "on") {
    out = true;
    return true;
  }
  if (s == "0" || s == "false" || s == "no" || s == "off") {
    out = false;
    return true;
  }
  return false;
}

static int parseJsonBody(JsonDocument& doc) {
  if (!server.hasArg("plain")) return 0;
  DeserializationError err = deserializeJson(doc, server.arg("plain"));
  return err ? -1 : 1;
}

static bool getLongArg(JsonDocument& body, const char* key, long& out) {
  if (body.containsKey(key)) {
    out = body[key].as<long>();
    return true;
  }
  if (server.hasArg(key)) return parseStrictLong(server.arg(key), out);
  return false;
}

static bool getULongArg(JsonDocument& body, const char* key, unsigned long& out) {
  if (body.containsKey(key)) {
    out = body[key].as<unsigned long>();
    return true;
  }
  if (server.hasArg(key)) return parseStrictULong(server.arg(key), out);
  return false;
}

static bool getFloatArg(JsonDocument& body, const char* key, float& out) {
  if (body.containsKey(key)) {
    out = body[key].as<float>();
    return true;
  }
  if (server.hasArg(key)) return parseStrictFloat(server.arg(key), out);
  return false;
}

static bool getBoolArg(JsonDocument& body, const char* key, bool& out) {
  if (body.containsKey(key)) {
    out = body[key].as<bool>();
    return true;
  }
  if (server.hasArg(key)) return parseBoolValue(server.arg(key), out);
  return false;
}

static bool i2cProbe(uint8_t addr) {
  Wire.beginTransmission(addr);
  return Wire.endTransmission() == 0;
}

static void serialScanCurrentBus() {
  Serial.print("I2C scan SDA=");
  Serial.print(g_activeSda);
  Serial.print(" SCL=");
  Serial.print(g_activeScl);
  Serial.print(" ->");
  bool any = false;
  for (uint8_t addr = 0x03; addr <= 0x77; addr++) {
    if (i2cProbe(addr)) {
      Serial.print(" 0x");
      if (addr < 0x10) Serial.print("0");
      Serial.print(addr, HEX);
      any = true;
    }
  }
  if (!any) Serial.print(" none");
  Serial.println();
}

static bool i2cRead8At(uint8_t addr, uint8_t reg, uint8_t& value) {
  Wire.beginTransmission(addr);
  Wire.write(reg);
  // Use STOP then separate read for better compatibility with some ESP32 I2C/device combos.
  if (Wire.endTransmission(true) != 0) return false;
  delayMicroseconds(50);
  int n = Wire.requestFrom((int)addr, 1);
  if (n != 1) return false;
  value = Wire.read();
  return true;
}

static bool i2cWrite8At(uint8_t addr, uint8_t reg, uint8_t value) {
  Wire.beginTransmission(addr);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

static bool pcaRead8(uint8_t reg, uint8_t& value) {
  return i2cRead8At(g_pcaAddr, reg, value);
}

static bool pcaWrite8(uint8_t reg, uint8_t value) {
  return i2cWrite8At(g_pcaAddr, reg, value);
}

static bool probePca9685At(uint8_t addr) {
  // Keep this as pure ACK check; final validation happens in pcaInitialize().
  if (addr == 0x70) return false; // all-call/group address
  return i2cProbe(addr);
}

static bool findPcaAddressOnBus(uint8_t& outAddr) {
  // Prefer configured address first.
  if (probePca9685At(g_pcaAddr)) {
    outAddr = g_pcaAddr;
    return true;
  }

  // Then scan PCA9685 address space (skip 0x70 ALLCALL group address).
  for (uint8_t addr = 0x40; addr <= 0x7F; addr++) {
    if (addr == 0x70) continue;
    if (addr == g_pcaAddr) continue;
    if (probePca9685At(addr)) {
      outAddr = addr;
      return true;
    }
  }
  return false;
}

static bool selectI2CBusForPca() {
  const size_t n = sizeof(I2C_CANDIDATE_PINS) / sizeof(I2C_CANDIDATE_PINS[0]);

  for (size_t i = 0; i < n; i++) {
    int sda = I2C_CANDIDATE_PINS[i][0];
    int scl = I2C_CANDIDATE_PINS[i][1];
    Wire.begin(sda, scl);
    Wire.setClock(100000);
    delay(5);

    g_activeSda = sda;
    g_activeScl = scl;
    Serial.print("Trying I2C pins SDA=");
    Serial.print(sda);
    Serial.print(" SCL=");
    Serial.println(scl);
    serialScanCurrentBus();

    uint8_t found = 0;
    if (findPcaAddressOnBus(found)) {
      g_activeSda = sda;
      g_activeScl = scl;
      g_pcaAddr = found;
      Serial.print("PCA9685 candidate detected at 0x");
      if (found < 0x10) Serial.print("0");
      Serial.print(found, HEX);
      Serial.print(" on SDA=");
      Serial.print(sda);
      Serial.print(" SCL=");
      Serial.println(scl);
      return true;
    }
  }

  Serial.println("No PCA9685 found on candidate I2C pins.");
  g_activeSda = -1;
  g_activeScl = -1;
  return false;
}

static bool pcaSetPwmFrequency(float hz) {
  if (hz < 24.0f) hz = 24.0f;
  if (hz > 1526.0f) hz = 1526.0f;

  float prescaleVal = 25000000.0f / (4096.0f * hz) - 1.0f;
  uint8_t prescale = (uint8_t)floorf(prescaleVal + 0.5f);
  if (!pcaWrite8(PCA_MODE1, 0x11)) return false; // sleep + all-call
  if (!pcaWrite8(PCA_PRESCALE, prescale)) return false;
  if (!pcaWrite8(PCA_MODE1, 0x01)) return false; // wake + all-call
  delay(5);
  if (!pcaWrite8(PCA_MODE1, 0x21)) return false; // AI + all-call

  g_pwmHz = hz;
  return true;
}

static bool pcaSetRaw(uint8_t channel, uint16_t on, uint16_t off) {
  if (channel > 15) return false;
  uint8_t base = (uint8_t)(PCA_LED0_ON_L + 4 * channel);
  if (!pcaWrite8(base + 0, (uint8_t)(on & 0xFF))) return false;
  if (!pcaWrite8(base + 1, (uint8_t)((on >> 8) & 0x0F))) return false;
  if (!pcaWrite8(base + 2, (uint8_t)(off & 0xFF))) return false;
  if (!pcaWrite8(base + 3, (uint8_t)((off >> 8) & 0x0F))) return false;
  return true;
}

static bool pcaSetFullOff(uint8_t channel) {
  if (channel > 15) return false;
  uint8_t base = (uint8_t)(PCA_LED0_ON_L + 4 * channel);
  if (!pcaWrite8(base + 0, (uint8_t)0x00)) return false; // ON_L
  if (!pcaWrite8(base + 1, (uint8_t)0x00)) return false; // ON_H
  if (!pcaWrite8(base + 2, (uint8_t)0x00)) return false; // OFF_L
  if (!pcaWrite8(base + 3, (uint8_t)0x10)) return false; // OFF_H FULL_OFF bit
  return true;
}

static bool pcaReadChannelRaw(uint8_t channel, uint16_t& on, uint16_t& off) {
  if (channel > 15) return false;
  uint8_t base = (uint8_t)(PCA_LED0_ON_L + 4 * channel);
  uint8_t onL = 0;
  uint8_t onH = 0;
  uint8_t offL = 0;
  uint8_t offH = 0;
  if (!pcaRead8(base + 0, onL)) return false;
  if (!pcaRead8(base + 1, onH)) return false;
  if (!pcaRead8(base + 2, offL)) return false;
  if (!pcaRead8(base + 3, offH)) return false;
  on = (uint16_t)onL | ((uint16_t)(onH & 0x0F) << 8);
  off = (uint16_t)offL | ((uint16_t)(offH & 0x0F) << 8);
  return true;
}

static bool pcaInitialize() {
  if (!i2cProbe(g_pcaAddr)) return false;
  Serial.print("Initializing PCA9685 at 0x");
  if (g_pcaAddr < 0x10) Serial.print("0");
  Serial.println(g_pcaAddr, HEX);
  if (!pcaWrite8(PCA_MODE1, 0x00)) return false; // reset
  delay(10);
  if (!pcaWrite8(PCA_MODE2, 0x04)) return false; // OUTDRV

  if (!pcaSetPwmFrequency(g_pwmHz)) return false;
  return true;
}

static bool ensurePcaReady() {
  if (g_pcaReady && i2cProbe(g_pcaAddr)) return true;

  if (g_pcaReady) {
    Serial.println("PCA lost, re-detecting...");
  }
  g_pcaReady = false;
  if (!selectI2CBusForPca()) {
    Serial.println("ensurePcaReady: detection failed");
    return false;
  }

  if (!pcaInitialize()) {
    Serial.println("ensurePcaReady: init failed");
    return false;
  }

  g_pcaReady = true;
  Serial.println("ensurePcaReady: ready");
  for (int i = 0; i < 16; i++) g_lastCountValid[i] = false;
  return true;
}

static uint16_t usToCounts(float pulseUs) {
  float counts = pulseUs * g_pwmHz * 4096.0f / 1000000.0f;
  counts = clampf(counts, 0.0f, 4095.0f);
  return (uint16_t)lroundf(counts);
}

static float angleToUs(float angleDeg, float minAngle, float maxAngle, float minUs, float maxUs) {
  float angle = clampf(angleDeg, minAngle, maxAngle);
  float spanAngle = maxAngle - minAngle;
  if (fabsf(spanAngle) < 1e-6f) return minUs;
  float t = (angle - minAngle) / spanAngle;
  return minUs + t * (maxUs - minUs);
}

static void updateMappedServoState(uint8_t channel, float us, bool enabled) {
  for (int i = 0; i < SERVO_COUNT; i++) {
    if (SERVO_CHANNELS[i] == channel) {
      g_servoUs[i] = us;
      g_servoEnabled[i] = enabled;
      return;
    }
  }
}

static bool writeChannelUs(uint8_t channel, float pulseUs, bool enabled) {
  if (!ensurePcaReady()) return false;
  if (channel > 15) return false;

  if (!enabled) {
    if (!(g_lastCountValid[channel] && g_lastCount[channel] == 0)) {
      if (!pcaSetFullOff(channel)) {
        g_pcaReady = false;
        Serial.print("writeChannelUs: FULL_OFF failed channel=");
        Serial.println(channel);
        return false;
      }
      g_lastCount[channel] = 0;
      g_lastCountValid[channel] = true;
    }
    updateMappedServoState(channel, pulseUs, false);
    return true;
  }

  float us = clampf(pulseUs, 100.0f, 3000.0f);
  uint16_t count = usToCounts(us);
  if (g_lastCountValid[channel] && g_lastCount[channel] == count) return true;

  if (!pcaSetRaw(channel, 0, count)) {
    g_pcaReady = false;
    Serial.print("writeChannelUs: setRaw failed channel=");
    Serial.print(channel);
    Serial.print(" us=");
    Serial.print(us, 1);
    Serial.print(" ticks=");
    Serial.println(count);
    return false;
  }

  g_lastCount[channel] = count;
  g_lastCountValid[channel] = true;
  updateMappedServoState(channel, us, true);
  return true;
}

static int indexFromServoId(int servoId) {
  if (servoId < 1 || servoId > SERVO_COUNT) return -1;
  return servoId - 1;
}

static int indexFromPin(int pin) {
  for (int i = 0; i < SERVO_COUNT; i++) {
    if (SERVO_PINS[i] == pin) return i;
  }
  return -1;
}

static bool resolveChannel(JsonDocument& body, uint8_t& outChannel, const char*& err) {
  // 1) explicit channel
  long ch = 0;
  if (getLongArg(body, "channel", ch)) {
    long base = 0;
    if (getLongArg(body, "channel_base", base) && !(base == 0 || base == 1)) {
      err = "invalid_channel_base";
      return false;
    }

    if (base == 1) {
      if (ch < 1 || ch > 16) {
        err = "invalid_channel";
        return false;
      }
      outChannel = (uint8_t)(ch - 1);
      return true;
    }

    if (ch < 0 || ch > 15) {
      err = "invalid_channel";
      return false;
    }
    outChannel = (uint8_t)ch;
    return true;
  }

  // 2) servo index (1..SERVO_COUNT)
  long servo = 0;
  if (getLongArg(body, "servo", servo)) {
    int idx = indexFromServoId((int)servo);
    if (idx < 0) {
      err = "invalid_servo";
      return false;
    }
    outChannel = SERVO_CHANNELS[idx];
    return true;
  }

  // 3) pin mapping (for compatibility with pin-based clients)
  long pin = 0;
  if (getLongArg(body, "pin", pin)) {
    int idx = indexFromPin((int)pin);
    if (idx < 0) {
      err = "unknown_pin";
      return false;
    }
    outChannel = SERVO_CHANNELS[idx];
    return true;
  }

  err = "missing_channel";
  return false;
}

static bool hasSelectorArg(JsonDocument& body) {
  return body.containsKey("channel") || body.containsKey("servo") || body.containsKey("pin")
      || server.hasArg("channel") || server.hasArg("servo") || server.hasArg("pin");
}

static void waitWithClient(uint32_t ms) {
  uint32_t t0 = millis();
  while (millis() - t0 < ms) {
    server.handleClient();
    delay(2);
  }
}

// ---------- API handlers ----------
static void handleRoot() {
  StaticJsonDocument<1024> doc;
  doc["ok"] = true;
  doc["name"] = "esp32c3-pca9685-servo-api";
  doc["endpoints"] = "GET /health, GET /api/pca/scan, POST|GET /api/pca/move, POST|GET /api/pca/test, POST|GET /servo/move, POST|GET /servo/center";

  JsonArray map = doc.createNestedArray("default_mapping");
  for (int i = 0; i < SERVO_COUNT; i++) {
    JsonObject row = map.createNestedObject();
    row["servo"] = i + 1;
    row["pin"] = SERVO_PINS[i];
    row["channel"] = SERVO_CHANNELS[i];
  }

  String out;
  serializeJson(doc, out);
  jsonReply(200, out);
}

static void handleHealth() {
  StaticJsonDocument<512> doc;
  bool ready = ensurePcaReady();

  doc["ok"] = true;
  doc["pca_ready"] = ready;
  doc["pca_address"] = g_pcaAddr;
  doc["pwm_hz"] = g_pwmHz;
  doc["i2c_sda_pin"] = g_activeSda;
  doc["i2c_scl_pin"] = g_activeScl;

  if (WiFi.status() == WL_CONNECTED) {
    doc["wifi_mode"] = "sta";
    doc["ip"] = WiFi.localIP().toString();
  } else {
    doc["wifi_mode"] = "ap";
    doc["ip"] = WiFi.softAPIP().toString();
  }

  String out;
  serializeJson(doc, out);
  jsonReply(200, out);
}

static void handlePcaScan() {
  if (g_activeSda < 0 || g_activeScl < 0) selectI2CBusForPca();

  StaticJsonDocument<1536> doc;
  doc["ok"] = true;
  doc["active_sda_pin"] = g_activeSda;
  doc["active_scl_pin"] = g_activeScl;
  doc["configured_pca_address"] = g_pcaAddr;

  JsonArray found = doc.createNestedArray("found_addresses");
  bool hasConfigured = false;

  for (uint8_t addr = 0x03; addr <= 0x77; addr++) {
    if (i2cProbe(addr)) {
      found.add(addr);
      if (addr == g_pcaAddr) hasConfigured = true;
    }
  }

  doc["pca_present_at_configured_address"] = hasConfigured;

  String out;
  serializeJson(doc, out);
  jsonReply(200, out);
}

static void handlePcaDebug() {
  StaticJsonDocument<1024> body;
  int bodyState = parseJsonBody(body);
  if (bodyState < 0) return jsonError(400, "invalid_json");

  StaticJsonDocument<2048> doc;
  bool ready = ensurePcaReady();
  doc["ok"] = ready;
  doc["pca_ready"] = ready;
  doc["pca_address"] = g_pcaAddr;
  doc["i2c_sda_pin"] = g_activeSda;
  doc["i2c_scl_pin"] = g_activeScl;

  JsonArray found = doc.createNestedArray("found_addresses");
  for (uint8_t addr = 0x03; addr <= 0x77; addr++) {
    if (i2cProbe(addr)) found.add(addr);
  }

  if (ready) {
    uint8_t mode1 = 0;
    uint8_t mode2 = 0;
    uint8_t prescale = 0;
    bool mode1Ok = pcaRead8(PCA_MODE1, mode1);
    bool mode2Ok = pcaRead8(PCA_MODE2, mode2);
    bool preOk = pcaRead8(PCA_PRESCALE, prescale);

    if (mode1Ok) doc["mode1"] = mode1;
    else doc["mode1_error"] = true;
    if (mode2Ok) doc["mode2"] = mode2;
    else doc["mode2_error"] = true;
    if (preOk) doc["prescale"] = prescale;
    else doc["prescale_error"] = true;

    long chLong = 0;
    if (!getLongArg(body, "channel", chLong)) chLong = 0;
    int ch = clampi((int)chLong, 0, 15);
    doc["channel"] = ch;

    uint16_t on = 0;
    uint16_t off = 0;
    if (pcaReadChannelRaw((uint8_t)ch, on, off)) {
      doc["channel_on"] = on;
      doc["channel_off"] = off;
    } else {
      doc["channel_read_error"] = true;
    }

    float us = 0.0f;
    if (getFloatArg(body, "us", us)) {
      us = clampf(us, 100.0f, 3000.0f);
      bool w = writeChannelUs((uint8_t)ch, us, true);
      doc["write_test_ok"] = w;
      if (w) {
        uint16_t on2 = 0;
        uint16_t off2 = 0;
        if (pcaReadChannelRaw((uint8_t)ch, on2, off2)) {
          doc["channel_on_after"] = on2;
          doc["channel_off_after"] = off2;
        } else {
          doc["channel_read_after_error"] = true;
        }
      }
    }
  }

  String out;
  serializeJson(doc, out);
  jsonReply(200, out);
}

static void handleServoStatus() {
  StaticJsonDocument<1024> doc;
  doc["ok"] = true;
  doc["pca_ready"] = ensurePcaReady();

  JsonArray servos = doc.createNestedArray("servos");
  for (int i = 0; i < SERVO_COUNT; i++) {
    JsonObject s = servos.createNestedObject();
    s["servo"] = i + 1;
    s["pin"] = SERVO_PINS[i];
    s["channel"] = SERVO_CHANNELS[i];
    s["us"] = g_servoUs[i];
    s["enabled"] = g_servoEnabled[i];
  }

  String out;
  serializeJson(doc, out);
  jsonReply(200, out);
}

static void handleRobotStatus() {
  StaticJsonDocument<1536> doc;
  JsonObject system = doc.createNestedObject("servo_system");
  system["driver"] = "pca9685-esp32c3";
  system["initialized"] = ensurePcaReady();
  system["pca_address"] = g_pcaAddr;
  system["i2c_sda_pin"] = g_activeSda;
  system["i2c_scl_pin"] = g_activeScl;

  JsonArray servos = system.createNestedArray("servos");
  for (int i = 0; i < SERVO_COUNT; i++) {
    JsonObject s = servos.createNestedObject();
    s["servo"] = i + 1;
    s["pin"] = SERVO_PINS[i];
    s["channel"] = SERVO_CHANNELS[i];
    s["us"] = g_servoUs[i];
    s["enabled"] = g_servoEnabled[i];
  }

  doc["timestamp"] = (double)millis() / 1000.0;

  String out;
  serializeJson(doc, out);
  jsonReply(200, out);
}

static void handlePcaMove() {
  StaticJsonDocument<512> body;
  int bodyState = parseJsonBody(body);
  if (bodyState < 0) return jsonError(400, "invalid_json");

  uint8_t channel = 0;
  const char* err = nullptr;
  if (!resolveChannel(body, channel, err)) return jsonError(400, err);

  bool enabled = true;
  bool bv = false;
  if (getBoolArg(body, "enabled", bv)) enabled = bv;

  float pulseUs = NAN;
  bool hasUs = getFloatArg(body, "us", pulseUs);

  float angleDeg = NAN;
  bool hasAngle = getFloatArg(body, "angle", angleDeg);
  if (!hasAngle) hasAngle = getFloatArg(body, "value", angleDeg); // compatibility with /servo/move

  if (!hasUs && !hasAngle) return jsonError(400, "missing_us_or_angle");

  if (!hasUs) {
    float minAngle = -90.0f;
    float maxAngle = 90.0f;
    float minUs = 500.0f;
    float maxUs = 2500.0f;

    getFloatArg(body, "angle_min", minAngle);
    getFloatArg(body, "angle_max", maxAngle);
    getFloatArg(body, "min_us", minUs);
    getFloatArg(body, "max_us", maxUs);

    if (maxAngle < minAngle) {
      float t = minAngle;
      minAngle = maxAngle;
      maxAngle = t;
    }
    if (maxUs < minUs) {
      float t = minUs;
      minUs = maxUs;
      maxUs = t;
    }

    minUs = clampf(minUs, 100.0f, 3000.0f);
    maxUs = clampf(maxUs, 100.0f, 3000.0f);
    pulseUs = angleToUs(angleDeg, minAngle, maxAngle, minUs, maxUs);
  }

  pulseUs = clampf(pulseUs, 100.0f, 3000.0f);
  Serial.print("API move channel=");
  Serial.print(channel);
  Serial.print(" enabled=");
  Serial.print(enabled ? "true" : "false");
  Serial.print(" us=");
  Serial.println(pulseUs, 1);

  if (!writeChannelUs(channel, pulseUs, enabled)) return jsonError(503, "pca_write_failed");

  StaticJsonDocument<384> doc;
  doc["ok"] = true;
  doc["channel"] = channel;
  doc["enabled"] = enabled;
  doc["us"] = pulseUs;
  doc["ticks"] = usToCounts(pulseUs);
  doc["pca_address"] = g_pcaAddr;

  String out;
  serializeJson(doc, out);
  jsonReply(200, out);
}

static void handlePcaTest() {
  StaticJsonDocument<768> body;
  int bodyState = parseJsonBody(body);
  if (bodyState < 0) return jsonError(400, "invalid_json");

  uint8_t channel = 0;
  const char* err = nullptr;
  if (!resolveChannel(body, channel, err)) return jsonError(400, err);

  float minUs = 1000.0f;
  float centerUs = 1500.0f;
  float maxUs = 2000.0f;
  unsigned long holdMsUL = 300;
  unsigned long repeatsUL = 2;

  getFloatArg(body, "min_us", minUs);
  getFloatArg(body, "center_us", centerUs);
  getFloatArg(body, "max_us", maxUs);
  getULongArg(body, "hold_ms", holdMsUL);
  getULongArg(body, "repeats", repeatsUL);

  if (maxUs < minUs) {
    float t = minUs;
    minUs = maxUs;
    maxUs = t;
  }

  minUs = clampf(minUs, 100.0f, 3000.0f);
  maxUs = clampf(maxUs, 100.0f, 3000.0f);
  centerUs = clampf(centerUs, minUs, maxUs);

  uint32_t holdMs = (uint32_t)clampi((int)holdMsUL, 20, 10000);
  int repeats = clampi((int)repeatsUL, 1, 50);

  for (int i = 0; i < repeats; i++) {
    if (!writeChannelUs(channel, minUs, true)) return jsonError(503, "pca_write_failed");
    waitWithClient(holdMs);

    if (!writeChannelUs(channel, centerUs, true)) return jsonError(503, "pca_write_failed");
    waitWithClient(holdMs);

    if (!writeChannelUs(channel, maxUs, true)) return jsonError(503, "pca_write_failed");
    waitWithClient(holdMs);

    if (!writeChannelUs(channel, centerUs, true)) return jsonError(503, "pca_write_failed");
    waitWithClient(holdMs);
  }

  StaticJsonDocument<384> doc;
  doc["ok"] = true;
  doc["channel"] = channel;
  doc["min_us"] = minUs;
  doc["center_us"] = centerUs;
  doc["max_us"] = maxUs;
  doc["hold_ms"] = holdMs;
  doc["repeats"] = repeats;

  String out;
  serializeJson(doc, out);
  jsonReply(200, out);
}

static void handleServoCenter() {
  StaticJsonDocument<256> body;
  int bodyState = parseJsonBody(body);
  if (bodyState < 0) return jsonError(400, "invalid_json");

  float centerUs = 1500.0f;
  getFloatArg(body, "center_us", centerUs);
  centerUs = clampf(centerUs, 100.0f, 3000.0f);

  bool allChannels = false;
  bool bv = false;
  if (getBoolArg(body, "all", bv)) allChannels = bv;

  if (!ensurePcaReady()) return jsonError(503, "pca9685_not_detected");

  StaticJsonDocument<768> doc;
  doc["ok"] = true;
  doc["center_us"] = centerUs;

  JsonArray moved = doc.createNestedArray("channels");

  if (allChannels) {
    for (uint8_t ch = 0; ch < 16; ch++) {
      if (!writeChannelUs(ch, centerUs, true)) return jsonError(503, "pca_write_failed");
      moved.add(ch);
    }
  } else {
    for (int i = 0; i < SERVO_COUNT; i++) {
      uint8_t ch = SERVO_CHANNELS[i];
      if (!writeChannelUs(ch, centerUs, true)) return jsonError(503, "pca_write_failed");
      moved.add(ch);
    }
  }

  String out;
  serializeJson(doc, out);
  jsonReply(200, out);
}

static void handleServoTestChannels() {
  // Compatibility alias for old endpoint.
  // If channel/servo/pin is provided, test one channel.
  // If none is provided, test default mapped channels.
  StaticJsonDocument<512> body;
  int bodyState = parseJsonBody(body);
  if (bodyState < 0) return jsonError(400, "invalid_json");

  float minUs = 1200.0f;
  float centerUs = 1500.0f;
  float maxUs = 1800.0f;
  unsigned long holdMsUL = 300;

  getFloatArg(body, "min_us", minUs);
  getFloatArg(body, "center_us", centerUs);
  getFloatArg(body, "max_us", maxUs);
  getULongArg(body, "hold_ms", holdMsUL);

  if (maxUs < minUs) {
    float t = minUs;
    minUs = maxUs;
    maxUs = t;
  }
  minUs = clampf(minUs, 100.0f, 3000.0f);
  maxUs = clampf(maxUs, 100.0f, 3000.0f);
  centerUs = clampf(centerUs, minUs, maxUs);
  uint32_t holdMs = (uint32_t)clampi((int)holdMsUL, 20, 10000);

  if (!ensurePcaReady()) return jsonError(503, "pca9685_not_detected");

  StaticJsonDocument<1024> doc;
  doc["ok"] = true;
  JsonArray tested = doc.createNestedArray("tested_channels");

  uint8_t oneChannel = 0;
  const char* err = nullptr;
  bool hasSelector = hasSelectorArg(body);
  bool hasSingle = resolveChannel(body, oneChannel, err);
  if (hasSelector && !hasSingle) return jsonError(400, err ? err : "invalid_channel");

  if (hasSingle) {
    if (!writeChannelUs(oneChannel, centerUs, true)) return jsonError(503, "pca_write_failed");
    waitWithClient(holdMs);
    if (!writeChannelUs(oneChannel, minUs, true)) return jsonError(503, "pca_write_failed");
    waitWithClient(holdMs);
    if (!writeChannelUs(oneChannel, centerUs, true)) return jsonError(503, "pca_write_failed");
    waitWithClient(holdMs);
    if (!writeChannelUs(oneChannel, maxUs, true)) return jsonError(503, "pca_write_failed");
    waitWithClient(holdMs);
    if (!writeChannelUs(oneChannel, centerUs, true)) return jsonError(503, "pca_write_failed");
    tested.add(oneChannel);
  } else {
    for (int i = 0; i < SERVO_COUNT; i++) {
      uint8_t ch = SERVO_CHANNELS[i];
      if (!writeChannelUs(ch, centerUs, true)) return jsonError(503, "pca_write_failed");
      waitWithClient(holdMs);
      if (!writeChannelUs(ch, minUs, true)) return jsonError(503, "pca_write_failed");
      waitWithClient(holdMs);
      if (!writeChannelUs(ch, centerUs, true)) return jsonError(503, "pca_write_failed");
      waitWithClient(holdMs);
      if (!writeChannelUs(ch, maxUs, true)) return jsonError(503, "pca_write_failed");
      waitWithClient(holdMs);
      if (!writeChannelUs(ch, centerUs, true)) return jsonError(503, "pca_write_failed");
      tested.add(ch);
    }
  }

  doc["min_us"] = minUs;
  doc["center_us"] = centerUs;
  doc["max_us"] = maxUs;
  doc["hold_ms"] = holdMs;

  String out;
  serializeJson(doc, out);
  jsonReply(200, out);
}

static void handleReinit() {
  bool manualAddr = false;
  bool manualPins = false;
  long lv = 0;

  if (server.hasArg("addr")) {
    if (!parseFlexibleLong(server.arg("addr"), lv)) return jsonError(400, "invalid_addr");
    if (lv < 0x03 || lv > 0x77) return jsonError(400, "invalid_addr");
    g_pcaAddr = (uint8_t)lv;
    manualAddr = true;
  }

  int forcedSda = -1;
  int forcedScl = -1;
  if (server.hasArg("sda") || server.hasArg("scl")) {
    if (!(server.hasArg("sda") && server.hasArg("scl"))) return jsonError(400, "provide_sda_and_scl");
    if (!parseFlexibleLong(server.arg("sda"), lv)) return jsonError(400, "invalid_sda");
    forcedSda = (int)lv;
    if (!parseFlexibleLong(server.arg("scl"), lv)) return jsonError(400, "invalid_scl");
    forcedScl = (int)lv;
    manualPins = true;
  }

  g_pcaReady = false;
  bool ready = false;

  if (manualPins) {
    Wire.begin(forcedSda, forcedScl);
    Wire.setClock(100000);
    delay(5);
    g_activeSda = forcedSda;
    g_activeScl = forcedScl;
    serialScanCurrentBus();

    if (!manualAddr) {
      uint8_t found = 0;
      if (findPcaAddressOnBus(found)) g_pcaAddr = found;
    }

    if (probePca9685At(g_pcaAddr)) {
      ready = pcaInitialize();
      g_pcaReady = ready;
    }
  } else {
    ready = ensurePcaReady();
  }

  StaticJsonDocument<1024> doc;
  doc["ok"] = ready;
  doc["pca_ready"] = ready;
  doc["pca_address"] = g_pcaAddr;
  doc["i2c_sda_pin"] = g_activeSda;
  doc["i2c_scl_pin"] = g_activeScl;
  doc["manual_addr"] = manualAddr;
  doc["manual_pins"] = manualPins;

  JsonArray found = doc.createNestedArray("found_addresses");
  for (uint8_t addr = 0x03; addr <= 0x77; addr++) {
    if (i2cProbe(addr)) found.add(addr);
  }

  String out;
  serializeJson(doc, out);
  if (ready) {
    jsonReply(200, out);
  } else {
    jsonReply(503, out);
  }
}

static void handleNotFound() {
  jsonError(404, "not_found");
}

static void startWiFi() {
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);

  uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED && (millis() - start) < 12000) {
    delay(300);
  }

  if (WiFi.status() == WL_CONNECTED) {
    Serial.print("WiFi STA connected. IP: ");
    Serial.println(WiFi.localIP());
    return;
  }

  WiFi.mode(WIFI_AP);
  bool apOk = WiFi.softAP(AP_SSID, AP_PASS);
  if (apOk) {
    Serial.print("WiFi AP started. IP: ");
    Serial.println(WiFi.softAPIP());
  } else {
    Serial.println("WiFi AP start failed");
  }
}

void setup() {
  Serial.begin(115200);
  delay(400);

  for (int i = 0; i < 16; i++) {
    g_lastCountValid[i] = false;
    g_lastCount[i] = 0;
  }
  for (int i = 0; i < SERVO_COUNT; i++) {
    g_servoUs[i] = 1500.0f;
    g_servoEnabled[i] = true;
  }

  g_pcaReady = ensurePcaReady();

  Serial.println();
  Serial.println("=== ESP32-C3 PCA9685 Servo API ===");
  if (g_pcaReady) {
    Serial.print("PCA9685 ready at 0x");
    Serial.print(g_pcaAddr, HEX);
    Serial.print(" on SDA=");
    Serial.print(g_activeSda);
    Serial.print(" SCL=");
    Serial.println(g_activeScl);

    // Start centered for mapped channels.
    for (int i = 0; i < SERVO_COUNT; i++) {
      writeChannelUs(SERVO_CHANNELS[i], 1500.0f, true);
    }
  } else {
    Serial.println("PCA9685 not detected. Check power, GND, SDA/SCL, and address.");
  }

  startWiFi();

  server.on("/", HTTP_GET, handleRoot);
  server.on("/health", HTTP_GET, handleHealth);
  server.on("/api/pca/scan", HTTP_GET, handlePcaScan);
  server.on("/api/pca/debug", HTTP_GET, handlePcaDebug);
  server.on("/api/pca/debug", HTTP_POST, handlePcaDebug);
  server.on("/api/pca/reinit", HTTP_POST, handleReinit);
  server.on("/api/pca/reinit", HTTP_GET, handleReinit);
  server.on("/servo/status", HTTP_GET, handleServoStatus);
  server.on("/robot/status", HTTP_GET, handleRobotStatus);
  server.on("/api/list_servos", HTTP_GET, handleServoStatus);

  server.on("/api/pca/move", HTTP_POST, handlePcaMove);
  server.on("/api/pca/move", HTTP_GET, handlePcaMove);
  server.on("/api/pca/test", HTTP_POST, handlePcaTest);
  server.on("/api/pca/test", HTTP_GET, handlePcaTest);

  // Compatibility aliases
  server.on("/servo/move", HTTP_POST, handlePcaMove);
  server.on("/servo/move", HTTP_GET, handlePcaMove);
  server.on("/servo/center", HTTP_POST, handleServoCenter);
  server.on("/servo/center", HTTP_GET, handleServoCenter);
  server.on("/servo/test-channels", HTTP_POST, handleServoTestChannels);
  server.on("/servo/test-channels", HTTP_GET, handleServoTestChannels);

  server.onNotFound(handleNotFound);
  server.begin();

  Serial.println("HTTP server started");
}

void loop() {
  server.handleClient();
}
