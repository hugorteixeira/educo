const cfg = window.robotUiConfig || {};
const driver = (cfg.servoDriver || "").toLowerCase();
document.body.dataset.driver = driver || "soft";
const driverIsPca = driver === "pca9685";
const statusRefreshMs = cfg.statusRefreshMs ?? 2000;
let keyRepeatMs = cfg.keyRepeatMs ?? 120;
let steps = cfg.step ? { ...cfg.step } : {};
let defaultStep = steps.default ?? 0.15;
let loggingState = cfg.logging || { enabled: false, log_count: 0 };
const LOG_DISPLAY_LIMIT = 20;

const statusEl = document.getElementById("status-json");
const mapEl = document.getElementById("part-map");
const toastEl = document.getElementById("toast");
const streamImg = document.getElementById("camera-stream");
const rawStreamLink = document.getElementById("raw-stream");
const snapshotBtn = document.getElementById("refresh-frame");
const centerBtn = document.getElementById("center-servos");
const demoBtn = document.getElementById("run-demo");
const loggingToggle = document.getElementById("logging-toggle");
const loggingCountEl = document.getElementById("logging-count");
const configForm = document.getElementById("config-form");
const reloadConfigBtn = document.getElementById("reload-config");
const cameraIpInput = document.getElementById("camera-ip");
const cameraCaptureInput = document.getElementById("camera-capture");
const cameraStreamInput = document.getElementById("camera-stream-port");
const stepDefaultInput = document.getElementById("step-default");
const stepPartsContainer = document.getElementById("step-parts");
const servoTableBody = document.getElementById("servo-table");
const configSection = document.getElementById("settings-card");
const configToggleBtn = document.getElementById("config-toggle");
const logStreamEl = document.getElementById("log-stream");
const logExportBtn = document.getElementById("logs-export");
const testChannelsBtn = document.getElementById("test-channels");

const partState = {};
const servoMetaByPart = new Map();
const pinToPart = new Map();
let statusErrorShown = false;
let logErrorShown = false;
let logEntries = [];

(cfg.servos || []).forEach((servo) => {
  const partName = servo.part || `pin-${servo.pin}`;
  const partKey = partName.toLowerCase();
  const min = Array.isArray(servo.range) ? servo.range[0] : -270;
  const max = Array.isArray(servo.range) ? servo.range[1] : 270;
  partState[partKey] = {
    part: partName,
    pin: servo.pin,
    channel: servo.channel,
    type: servo.type,
    min,
    max,
    value: null,
  };
  servoMetaByPart.set(partKey, {
    part: partName,
    pin: servo.pin,
    channel: servo.channel,
  });
  if (typeof servo.pin === "number") {
    pinToPart.set(servo.pin, partKey);
  }
});

if (rawStreamLink && cfg.camera?.raw?.stream) {
  rawStreamLink.href = cfg.camera.raw.stream;
}

renderMap();
renderLogs();
updateLoggingUI();
initializeConfigForm();
refreshLoggingState();
refreshLogs();
pollLoop();

function toast(message, type = "info") {
  if (!toastEl) return;
  toastEl.textContent = message;
  toastEl.classList.toggle("error", type === "error");
  toastEl.hidden = false;
  requestAnimationFrame(() => {
    toastEl.classList.add("show");
  });
  clearTimeout(toastEl._hideTimer);
  toastEl._hideTimer = setTimeout(() => {
    toastEl.classList.remove("show");
    toastEl._hideTimer = setTimeout(() => {
      toastEl.hidden = true;
      toastEl.textContent = "";
    }, 320);
  }, 2600);
}

function updateLoggingUI() {
  if (loggingToggle) {
    loggingToggle.checked = !!loggingState.enabled;
  }
  if (loggingCountEl) {
    if (loggingState.enabled) {
      const count = loggingState.log_count ?? 0;
      loggingCountEl.textContent = `Logging enabled · ${count} entries`;
    } else {
      loggingCountEl.textContent = "Logging disabled";
    }
  }
}

async function refreshLoggingState() {
  try {
    const data = await fetchJSON("/ui/logging");
    if (data && typeof data === "object") {
      loggingState = { ...loggingState, ...data };
      updateLoggingUI();
    }
  } catch (err) {
    // ignore
  }
}

async function setLogging(enabled) {
  loggingToggle.disabled = true;
  try {
    const data = await fetchJSON("/ui/logging", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ enabled }),
    });
    loggingState = data;
    updateLoggingUI();
    toast(enabled ? "Logging enabled" : "Logging disabled");
    await refreshLogs();
  } catch (err) {
    toast(`Logging update failed: ${err.message}`, "error");
    loggingToggle.checked = !enabled;
  } finally {
    loggingToggle.disabled = false;
  }
}

function renderMap() {
  if (!mapEl) return;
  const items = (cfg.servos || [])
    .map((servo) => {
      const partName = servo.part || `pin-${servo.pin}`;
      const partKey = partName.toLowerCase();
      const state = partState[partKey];
      if (!state) return "";
      const stepPct = Math.round(((steps[partKey] ?? steps[partName] ?? defaultStep) || defaultStep) * 100);
      const value = state.value ?? "–";
      const signal = driverIsPca
        ? state.channel === undefined || state.channel === null
          ? "channel —"
          : `channel ${state.channel}`
        : state.pin === undefined || state.pin === null
          ? "pin —"
          : `pin ${state.pin}`;
      return `
        <div class="map-pill" data-part="${partKey}">
          <strong>${partName.toUpperCase()}</strong>
          <span>${signal}</span>
          <span>${state.min}:${state.max}</span>
          <span>val ${value}</span>
          <span>${stepPct}% step</span>
        </div>
      `;
    })
    .filter(Boolean);
  mapEl.innerHTML = items.join("") || '<span class="map-pill">No servos configured.</span>';
}

function renderLogs() {
  if (!logStreamEl) return;
  if (!logEntries.length) {
    const message = loggingState.enabled
      ? 'No moves logged yet. Send a move to capture history.'
      : 'Enable logging to capture move history.';
    logStreamEl.innerHTML = `<p class="log-empty">${message}</p>`;
    return;
  }
  const items = logEntries.slice(0, LOG_DISPLAY_LIMIT).map((entry) => {
    const partKey = (entry.part || "").toLowerCase();
    const info = servoMetaByPart.get(partKey);
    const signalValue = driverIsPca ? info?.channel : (info?.pin ?? entry.pin);
    const signalLabel = driverIsPca
      ? signalValue === undefined || signalValue === null
        ? ""
        : `Channel ${signalValue}`
      : signalValue === undefined || signalValue === null
        ? ""
        : `Pin ${signalValue}`;
    const smoothLabel = entry.smooth ? "Smooth" : "Direct";
    let targetValue = entry.target_value;
    if (typeof targetValue !== "number") {
      if (typeof entry.target === "number") {
        targetValue = entry.target;
      } else if (typeof entry.value === "number") {
        targetValue = entry.value;
      }
    }
    const targetLabel = typeof targetValue === "number" ? targetValue : "–";
    const timestamp = formatTimestamp(entry.timestamp);
    const partLabel = entry.part
      ? entry.part.toUpperCase()
      : info?.part?.toUpperCase() || (entry.pin !== undefined ? `PIN ${entry.pin}` : "UNKNOWN");
    const hasSnapshots = entry.camera?.pre_image || entry.camera?.post_image;
    return `
      <div class="log-entry">
        <div class="log-entry-header">
          <span>${partLabel}</span>
          <span>${timestamp}</span>
        </div>
        <div class="log-entry-meta">
          <span>Target ${targetLabel}</span>
          ${signalLabel ? `<span>${signalLabel}</span>` : ""}
          <span>${smoothLabel}</span>
          ${hasSnapshots ? '<span>Snapshots ✓</span>' : ""}
        </div>
      </div>
    `;
  });
  logStreamEl.innerHTML = items.join("");
}

async function refreshLogs() {
  if (!cfg.api?.logs) return;
  try {
    const data = await fetchJSON(`${cfg.api.logs}?limit=25`, { cache: "no-store" });
    if (Array.isArray(data?.entries)) {
      logEntries = data.entries;
      if (typeof data.count === "number") {
        loggingState.log_count = data.count;
        updateLoggingUI();
      }
      renderLogs();
      if (logErrorShown) {
        toast("Log stream restored", "info");
        logErrorShown = false;
      }
    }
  } catch (err) {
    if (!logErrorShown) {
      toast(`Log fetch failed: ${err.message}`, "error");
      logErrorShown = true;
    }
    if (!logEntries.length && logStreamEl) {
      logStreamEl.innerHTML = `<p class="log-error">Unable to load logs: ${err.message}</p>`;
    }
  }
}

async function fetchJSON(url, options) {
  const response = await fetch(url, options);
  if (!response.ok) {
    const text = await response.text();
    throw new Error(text || `${response.status} ${response.statusText}`);
  }
  if (response.status === 204) return null;
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

async function refreshStatus() {
  try {
    const data = await fetchJSON(cfg.api.status, { cache: "no-store" });
    updateStatus(data);
    if (statusErrorShown) {
      toast("Status link restored", "info");
      statusErrorShown = false;
    }
  } catch (err) {
    statusErrorShown = true;
    toast(`Status error: ${err.message}`, "error");
    if (statusEl) {
      statusEl.textContent = `// status error: ${err.message}`;
    }
  }
}

function updateStatus(payload) {
  if (!payload || typeof payload !== "object") return;
  if (statusEl) {
    statusEl.textContent = JSON.stringify(payload, null, 2);
  }
  const servos = payload?.servo_system?.servos;
  if (Array.isArray(servos)) {
    servos.forEach((servo) => {
      const partKey = servo.part ? servo.part.toLowerCase() : pinToPart.get(servo.pin);
      if (!partKey || !partState[partKey]) return;
      const info = partState[partKey];
      if (typeof servo.pin === "number") {
        info.pin = servo.pin;
        pinToPart.set(servo.pin, partKey);
        const meta = servoMetaByPart.get(partKey) || { part: info.part };
        meta.pin = servo.pin;
        servoMetaByPart.set(partKey, meta);
      }
      const value = typeof servo.value === "number" ? Math.round(servo.value) : null;
      info.value = value;
      if (typeof servo.range === "string" && servo.range.includes(":")) {
        const [mn, mx] = servo.range.split(":").map((v) => Number(v));
        if (!Number.isNaN(mn) && !Number.isNaN(mx)) {
          info.min = Math.min(mn, mx);
          info.max = Math.max(mn, mx);
        }
      }
    });
    renderMap();
  }
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

async function moveServo(partKey, target) {
  const info = partState[partKey];
  if (!info) return;
  const body = {
    pin: info.pin,
    value: target,
    smooth: false,
  };
  try {
    await fetchJSON(cfg.api.move, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    info.value = target;
    renderMap();
  } catch (err) {
    toast(`Move failed: ${err.message}`, "error");
  }
}

function stepServo(partKey, dir) {
  const info = partState[partKey];
  if (!info) return;
  const span = (info.max ?? 90) - (info.min ?? -90);
  const stepPct = steps[partKey] ?? steps[info.part] ?? defaultStep;
  const step = Math.max(1, Math.round(span * stepPct));
  const current = typeof info.value === "number" ? info.value : 0;
  const target = clamp(current + dir * step, info.min, info.max);
  if (target === current) return;
  moveServo(partKey, target);
}

const KEY_BINDINGS = {
  ArrowLeft: { part: "claw", dir: -1 },
  ArrowRight: { part: "claw", dir: 1 },
  ArrowUp: { part: "height", dir: 1 },
  ArrowDown: { part: "height", dir: -1 },
  KeyA: { part: "base", dir: 1 },
  KeyD: { part: "base", dir: -1 },
  KeyW: { part: "reach", dir: 1 },
  KeyS: { part: "reach", dir: -1 },
};

const activeKeys = new Map();

function setKeyActive(code, flag) {
  const binding = KEY_BINDINGS[code];
  if (!binding) return;
  const btn = document.querySelector(`[data-key="${code}"]`);
  if (flag) {
    if (activeKeys.has(code)) return;
    btn?.classList.add("active");
    stepServo(binding.part, binding.dir);
    const timer = setInterval(() => stepServo(binding.part, binding.dir), keyRepeatMs);
    activeKeys.set(code, timer);
  } else {
    const timer = activeKeys.get(code);
    if (timer) clearInterval(timer);
    activeKeys.delete(code);
    btn?.classList.remove("active");
  }
}

document.addEventListener("keydown", (event) => {
  if (!KEY_BINDINGS[event.code]) return;
  event.preventDefault();
  setKeyActive(event.code, true);
});

document.addEventListener("keyup", (event) => {
  if (!KEY_BINDINGS[event.code]) return;
  event.preventDefault();
  setKeyActive(event.code, false);
});

window.addEventListener("blur", () => {
  [...activeKeys.keys()].forEach((code) => setKeyActive(code, false));
});

const padButtons = document.querySelectorAll(".pad-btn[data-key]");
padButtons.forEach((btn) => {
  const key = btn.dataset.key;
  btn.addEventListener("pointerdown", (event) => {
    event.preventDefault();
    if (btn.setPointerCapture) {
      btn.setPointerCapture(event.pointerId);
    }
    setKeyActive(key, true);
  });
  btn.addEventListener("pointerup", (event) => {
    event.preventDefault();
    if (btn.releasePointerCapture) {
      try {
        btn.releasePointerCapture(event.pointerId);
      } catch (err) {
        // ignore
      }
    }
    setKeyActive(key, false);
  });
  btn.addEventListener("pointerleave", () => setKeyActive(key, false));
  btn.addEventListener(
    "touchstart",
    (event) => {
      event.preventDefault();
      setKeyActive(key, true);
    },
    { passive: false },
  );
  btn.addEventListener(
    "touchend",
    (event) => {
      event.preventDefault();
      setKeyActive(key, false);
    },
    { passive: false },
  );
  btn.addEventListener("touchcancel", () => setKeyActive(key, false));
});

if (snapshotBtn) {
  snapshotBtn.addEventListener("click", async () => {
    snapshotBtn.disabled = true;
    try {
      const data = await fetchJSON(`${cfg.camera.capture}?max_width=640&jpeg_quality=35`, {
        method: "GET",
        cache: "no-store",
      });
      if (data?.image_url) {
        window.open(data.image_url, "_blank", "noopener");
      }
    } catch (err) {
      toast(`Snapshot failed: ${err.message}`, "error");
    } finally {
      snapshotBtn.disabled = false;
    }
  });
}

async function postAction(url, button, label) {
  if (button) button.disabled = true;
  try {
    await fetchJSON(url, { method: "POST" });
    toast(`${label} request sent`);
    setTimeout(refreshStatus, 400);
    if (loggingState.enabled) {
      refreshLoggingState();
      refreshLogs();
    }
  } catch (err) {
    toast(`${label} failed: ${err.message}`, "error");
  } finally {
    if (button) button.disabled = false;
  }
}

if (centerBtn) {
  centerBtn.addEventListener("click", () => postAction(cfg.api.center, centerBtn, "Center"));
}
if (demoBtn) {
  demoBtn.addEventListener("click", () => postAction(cfg.api.demo, demoBtn, "Demo"));
}

if (loggingToggle) {
  loggingToggle.addEventListener("change", (event) => setLogging(event.target.checked));
}

if (reloadConfigBtn) {
  reloadConfigBtn.addEventListener("click", () => window.location.reload());
}

if (configToggleBtn && configSection) {
  const applyToggleState = () => {
    const isHidden = configSection.hasAttribute("hidden");
    configToggleBtn.textContent = isHidden ? "Show configuration" : "Hide configuration";
    configToggleBtn.setAttribute("aria-expanded", String(!isHidden));
  };

  applyToggleState();

  configToggleBtn.addEventListener("click", () => {
    if (configSection.hasAttribute("hidden")) {
      configSection.removeAttribute("hidden");
    } else {
      configSection.setAttribute("hidden", "");
    }
    applyToggleState();
  });
}

if (logExportBtn && cfg.api?.logsExport) {
  logExportBtn.addEventListener("click", () => {
    const url = `${cfg.api.logsExport}?ts=${Date.now()}`;
    window.open(url, "_blank", "noopener");
  });
} else if (logExportBtn) {
  logExportBtn.disabled = true;
}

if (testChannelsBtn) {
  if (!driverIsPca || !cfg.api?.testChannels) {
    testChannelsBtn.disabled = true;
  } else {
    const originalLabel = testChannelsBtn.textContent || "Test channels";
    testChannelsBtn.addEventListener("click", async () => {
      testChannelsBtn.disabled = true;
      testChannelsBtn.textContent = "Testing...";
      try {
        const result = await fetchJSON(cfg.api.testChannels, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({}),
        });
        const tested = result?.tested ?? 0;
        toast(`Tested ${tested} channel${tested === 1 ? "" : "s"}.`, "info");
      } catch (err) {
        toast(`Channel test failed: ${err.message}`, "error");
      } finally {
        testChannelsBtn.textContent = originalLabel;
        testChannelsBtn.disabled = false;
      }
    });
  }
}

if (configForm) {
  configForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const payload = buildConfigPayload();
    const submitBtn = configForm.querySelector("button[type='submit']");
    if (submitBtn) submitBtn.disabled = true;
    try {
      await fetchJSON(cfg.api?.config || "/ui/config", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      toast("Configuration saved. Reloading...");
      setTimeout(() => window.location.reload(), 900);
    } catch (err) {
      toast(`Config save failed: ${err.message}`, "error");
    } finally {
      if (submitBtn) submitBtn.disabled = false;
    }
  });
}

function buildConfigPayload() {
  const payload = {
    camera: {
      ip: cameraIpInput?.value?.trim() || undefined,
      capture_port: cameraCaptureInput?.value ? Number(cameraCaptureInput.value) : undefined,
      stream_port: cameraStreamInput?.value ? Number(cameraStreamInput.value) : undefined,
    },
    ui: {
      default_step_pct: stepDefaultInput?.value ? Number(stepDefaultInput.value) : undefined,
      part_step_pct: {},
    },
    servos: [],
  };

  if (stepPartsContainer) {
    const partInputs = stepPartsContainer.querySelectorAll("input[data-part]");
    partInputs.forEach((input) => {
      const part = input.dataset.part;
      if (!part) return;
      const value = input.value ? Number(input.value) : undefined;
      if (value && !Number.isNaN(value)) {
        payload.ui.part_step_pct[part] = value;
      }
    });
    if (!Object.keys(payload.ui.part_step_pct).length) {
      delete payload.ui.part_step_pct;
    }
  }

  if (servoTableBody) {
    const rows = servoTableBody.querySelectorAll("tr");
    rows.forEach((row) => {
      const part = row.dataset.part;
      if (!part) return;
      const minInput = row.querySelector("input[data-role='min']");
      const maxInput = row.querySelector("input[data-role='max']");
      const pinInput = row.querySelector("input[data-role='pin']");
      const channelInput = row.querySelector("input[data-role='channel']");
      const servoUpdate = { part };
      if (minInput && maxInput) {
        const minRaw = minInput.value;
        const maxRaw = maxInput.value;
        if (minRaw !== "" && maxRaw !== "") {
          const minVal = Number(minRaw);
          const maxVal = Number(maxRaw);
          if (!Number.isNaN(minVal) && !Number.isNaN(maxVal)) {
            servoUpdate.range = [minVal, maxVal];
          }
        }
      }
      if (pinInput && pinInput.value !== "") {
        const val = Number(pinInput.value);
        if (!Number.isNaN(val)) {
          servoUpdate.pin = val;
        }
      }
      if (channelInput && channelInput.value !== "") {
        const val = Number(channelInput.value);
        if (!Number.isNaN(val)) {
          servoUpdate.channel = val;
        }
      }
      if (servoUpdate.range || servoUpdate.pin !== undefined || servoUpdate.channel !== undefined) {
        payload.servos.push(servoUpdate);
      }
    });
  }

  return payload;
}

function initializeConfigForm() {
  const cameraSettings = cfg.cameraSettings || {};
  const uiSettings = cfg.uiSettings || {};
  if (cameraIpInput) cameraIpInput.value = cameraSettings.ip || "";
  if (cameraCaptureInput) cameraCaptureInput.value = cameraSettings.capture_port ?? "";
  if (cameraStreamInput) cameraStreamInput.value = cameraSettings.stream_port ?? "";
  if (stepDefaultInput) stepDefaultInput.value = uiSettings.default_step_pct ?? defaultStep;

  if (stepPartsContainer) {
    stepPartsContainer.innerHTML = "";
    const partNames = [...new Set((cfg.servos || []).map((servo) => servo.part).filter(Boolean))];
    partNames.forEach((part) => {
      const partKey = part.toLowerCase();
      const value = uiSettings.part_step_pct?.[partKey] ?? uiSettings.part_step_pct?.[part] ?? steps[partKey] ?? defaultStep;
      const wrapper = document.createElement("label");
      wrapper.className = "field";
      wrapper.innerHTML = `
        <span>${part} step (0-1)</span>
        <input type="number" step="0.01" min="0.01" max="1" data-part="${partKey}" value="${value}" />
      `;
      stepPartsContainer.appendChild(wrapper);
    });
  }

  if (servoTableBody) {
    const headerMap = document.getElementById("servo-header-map");
    const headerMin = document.getElementById("servo-header-min");
    const headerMax = document.getElementById("servo-header-max");
    if (headerMap) headerMap.textContent = driverIsPca ? "Channel" : "Pin";
    if (headerMin) headerMin.textContent = "Min";
    if (headerMax) headerMax.textContent = "Max";

    servoTableBody.innerHTML = "";
    (cfg.servos || []).forEach((servo) => {
      const partName = servo.part || `pin-${servo.pin}`;
      const partKey = partName.toLowerCase();
      const row = document.createElement("tr");
      row.dataset.part = partKey;
      row.dataset.partLabel = partName;
      const minVal = Array.isArray(servo.range) ? servo.range[0] : "";
      const maxVal = Array.isArray(servo.range) ? servo.range[1] : "";

      const partCell = document.createElement("td");
      partCell.className = "cell-part";
      partCell.innerHTML = `<strong>${partName}</strong>`;
      const subLabel = driverIsPca
        ? servo.pin != null
          ? `<span class="cell-sub">Pin ${servo.pin}</span>`
          : ""
        : servo.channel != null
          ? `<span class="cell-sub">Channel ${servo.channel}</span>`
          : "";
      if (subLabel) {
        partCell.innerHTML += subLabel;
      }
      row.appendChild(partCell);

      const mapCell = document.createElement("td");
      mapCell.className = "cell-map";
      const mapInput = document.createElement("input");
      mapInput.type = "number";
      mapInput.dataset.role = driverIsPca ? "channel" : "pin";
      mapInput.step = "1";
      if (driverIsPca) {
        mapInput.min = "0";
        mapInput.max = "15";
        mapInput.value = servo.channel ?? "";
        mapInput.placeholder = "0-15";
      } else {
        mapInput.value = servo.pin ?? "";
        mapInput.placeholder = "GPIO";
      }
      mapCell.appendChild(mapInput);
      row.appendChild(mapCell);

      const minCell = document.createElement("td");
      const minInput = document.createElement("input");
      minInput.type = "number";
      minInput.dataset.role = "min";
      minInput.step = "1";
      if (minVal !== "") minInput.value = minVal;
      minCell.appendChild(minInput);
      row.appendChild(minCell);

      const maxCell = document.createElement("td");
      const maxInput = document.createElement("input");
      maxInput.type = "number";
      maxInput.dataset.role = "max";
      maxInput.step = "1";
      if (maxVal !== "") maxInput.value = maxVal;
      maxCell.appendChild(maxInput);
      row.appendChild(maxCell);

      servoTableBody.appendChild(row);
    });
  }
}

async function pollLoop() {
  await refreshStatus();
  await refreshLogs();
  setTimeout(pollLoop, statusRefreshMs);
}

function formatTimestamp(value) {
  if (!value) return "";
  try {
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      return String(value);
    }
    return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
  } catch (err) {
    return String(value);
  }
}
