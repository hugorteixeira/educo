const cfg = window.robotUiConfig || {};
let statusRefreshMs = cfg.statusRefreshMs ?? 2000;
let keyRepeatMs = cfg.keyRepeatMs ?? 120;
let steps = cfg.step ? { ...cfg.step } : {};
let defaultStep = steps.default ?? 0.15;
let loggingState = cfg.logging || { enabled: false, log_count: 0 };

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
const cameraStreamInput = document.getElementById("camera-stream");
const stepDefaultInput = document.getElementById("step-default");
const stepPartsContainer = document.getElementById("step-parts");
const servoTableBody = document.getElementById("servo-table");

const partState = {};
const pinToPart = new Map();
let statusErrorShown = false;

(cfg.servos || []).forEach((servo) => {
  const part = servo.part || `pin-${servo.pin}`;
  partState[part] = {
    pin: servo.pin,
    part,
    type: servo.type,
    min: Array.isArray(servo.range) ? servo.range[0] : -270,
    max: Array.isArray(servo.range) ? servo.range[1] : 270,
    value: null,
  };
  pinToPart.set(servo.pin, part);
});

if (rawStreamLink && cfg.camera?.raw?.stream) {
  rawStreamLink.href = cfg.camera.raw.stream;
}

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
    loggingCountEl.textContent = loggingState.log_count
      ? `Logged moves: ${loggingState.log_count}`
      : "Logs disabled";
  }
}

async function refreshLoggingState() {
  try {
    const data = await fetchJSON("/ui/logging");
    if (data && typeof data === "object") {
      loggingState = data;
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
  } catch (err) {
    toast(`Logging update failed: ${err.message}`, "error");
    loggingToggle.checked = !enabled;
  } finally {
    loggingToggle.disabled = false;
  }
}

function renderMap() {
  if (!mapEl) return;
  const items = (cfg.servos || []).map((servo) => {
    const state = partState[servo.part] || {};
    const partKey = servo.part?.toLowerCase?.() || "";
    const stepPct = Math.round(((steps[partKey] ?? steps[servo.part] ?? defaultStep) || defaultStep) * 100);
    const value = state.value ?? "–";
    return `
      <div class="map-pill">
        <strong>${servo.part.toUpperCase()}</strong>
        <span>pin ${servo.pin}</span>
        <span>${state.min}:${state.max}</span>
        <span>val ${value}</span>
        <span>${stepPct}% step</span>
      </div>
    `;
  });
  mapEl.innerHTML = items.join("") || "<span class=\"map-pill\">No servos configured.</span>";
}

renderMap();
updateLoggingUI();
initializeConfigForm();
refreshLoggingState();

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
      const part = servo.part || pinToPart.get(servo.pin);
      if (!partState[part]) return;
      const value = typeof servo.value === "number" ? Math.round(servo.value) : null;
      partState[part].value = value;
      if (typeof servo.range === "string" && servo.range.includes(":")) {
        const [mn, mx] = servo.range.split(":").map((v) => Number(v));
        if (!Number.isNaN(mn) && !Number.isNaN(mx)) {
          partState[part].min = Math.min(mn, mx);
          partState[part].max = Math.max(mn, mx);
        }
      }
    });
    renderMap();
  }
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

async function moveServo(part, target) {
  const info = partState[part];
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
    if (loggingState.enabled) {
      refreshLoggingState();
    }
  } catch (err) {
    toast(`Move failed: ${err.message}`, "error");
  }
}

function stepServo(part, dir) {
  const info = partState[part];
  if (!info) return;
  const span = (info.max ?? 90) - (info.min ?? -90);
  const partKey = part.toLowerCase();
  const stepPct = steps[partKey] ?? steps[part] ?? defaultStep;
  const step = Math.max(1, Math.round(span * stepPct));
  const current = typeof info.value === "number" ? info.value : 0;
  const target = clamp(current + dir * step, info.min, info.max);
  if (target === current) return;
  moveServo(part, target);
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
    btn.setPointerCapture(event.pointerId);
    setKeyActive(key, true);
  });
  btn.addEventListener("pointerup", (event) => {
    event.preventDefault();
    btn.releasePointerCapture(event.pointerId);
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

if (configForm) {
  configForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const payload = buildConfigPayload();
    const submitBtn = configForm.querySelector("button[type='submit']");
    if (submitBtn) submitBtn.disabled = true;
    try {
      await fetchJSON("/ui/config", {
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
    const rows = servoTableBody.querySelectorAll("tr[data-pin]");
    rows.forEach((row) => {
      const pin = Number(row.dataset.pin);
      const part = row.dataset.part || undefined;
      const minInput = row.querySelector("input[data-role='min']");
      const maxInput = row.querySelector("input[data-role='max']");
      if (!minInput || !maxInput) return;
      const minVal = Number(minInput.value);
      const maxVal = Number(maxInput.value);
      if (Number.isNaN(minVal) || Number.isNaN(maxVal)) return;
      payload.servos.push({
        pin,
        part,
        range: [minVal, maxVal],
      });
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
    const partNames = [...new Set((cfg.servos || []).map((servo) => servo.part))];
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
    servoTableBody.innerHTML = "";
    (cfg.servos || []).forEach((servo) => {
      const row = document.createElement("tr");
      row.dataset.pin = servo.pin;
      row.dataset.part = (servo.part || "").toLowerCase();
      const minVal = Array.isArray(servo.range) ? servo.range[0] : "";
      const maxVal = Array.isArray(servo.range) ? servo.range[1] : "";
      row.innerHTML = `
        <td>${servo.part}</td>
        <td>${servo.pin}</td>
        <td><input type="number" data-role="min" value="${minVal}" step="1" /></td>
        <td><input type="number" data-role="max" value="${maxVal}" step="1" /></td>
      `;
      servoTableBody.appendChild(row);
    });
  }
}

async function pollLoop() {
  await refreshStatus();
  setTimeout(pollLoop, statusRefreshMs);
}

pollLoop();
