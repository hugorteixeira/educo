#!/usr/bin/env python3
"""
Ultra-lean REST API for Servo Control via PCA9685 + ESP32CAM - Orange Pi
"""

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse
from fastapi.staticfiles import StaticFiles
import uuid, os
from pydantic import BaseModel, Field, validator, constr
from typing import Dict, List, Union, Optional, Tuple, Any
import asyncio
import requests
import cv2
import numpy as np
import time
import math

# ============================================================
# PCA9685 LOW-LEVEL DRIVER (SMBus2)
# ============================================================
# This avoids extra dependencies (Blinka/Servokit). If you prefer,
# you can replace this with Adafruit's CircuitPython PCA9685 library.
try:
    from smbus2 import SMBus
except ImportError as e:
    raise SystemExit(
        "Missing dependency smbus2. Install with: pip3 install smbus2\n"
        "Also ensure I2C is enabled and python3-smbus is installed: sudo apt install python3-smbus i2c-tools"
    )

class PCA9685:
    """Minimal PCA9685 driver using smbus2.
    Only features needed for servo control are implemented.
    """
    _MODE1     = 0x00
    _MODE2     = 0x01
    _SUBADR1   = 0x02
    _SUBADR2   = 0x03
    _SUBADR3   = 0x04
    _PRESCALE  = 0xFE
    _LED0_ON_L = 0x06

    def __init__(self, bus: int = 1, address: int = 0x40, freq_hz: int = 50):
        self.bus_num = bus
        self.address = address
        self.bus = SMBus(bus)
        self.freq_hz = None
        self._reset()
        self._write8(self._MODE2, 0x04)  # OUTDRV (totem-pole)
        # Enable auto-increment (AI bit in MODE1)
        oldmode = self._read8(self._MODE1)
        self._write8(self._MODE1, oldmode | 0x20)  # AI=1
        self.set_pwm_freq(freq_hz)

    def close(self):
        try:
            self.bus.close()
        except Exception:
            pass

    def _write8(self, reg: int, value: int):
        self.bus.write_byte_data(self.address, reg, value & 0xFF)

    def _read8(self, reg: int) -> int:
        return self.bus.read_byte_data(self.address, reg)

    def _reset(self):
        # MODE1 reset clears sleep and resets internal state
        self._write8(self._MODE1, 0x00)
        time.sleep(0.01)

    def set_pwm_freq(self, freq_hz: int):
        """Set PWM frequency (in Hz). Typical for servos: 50-60 Hz."""
        freq_hz = int(freq_hz)
        if freq_hz < 24 or freq_hz > 1526:
            raise ValueError("PCA9685 frequency must be between 24 and 1526 Hz")
        prescaleval = 25000000.0 / (4096.0 * float(freq_hz)) - 1.0
        prescale = int(math.floor(prescaleval + 0.5))
        oldmode = self._read8(self._MODE1)
        newmode = (oldmode & 0x7F) | 0x10  # sleep
        self._write8(self._MODE1, newmode)       # go to sleep
        self._write8(self._PRESCALE, prescale)   # set prescale
        self._write8(self._MODE1, oldmode)       # wake
        time.sleep(0.005)
        self._write8(self._MODE1, oldmode | 0xA1)  # restart + AI
        self.freq_hz = freq_hz

    def set_pwm(self, channel: int, on: int, off: int):
        """Set raw on/off 12-bit counts for a channel (0..15)."""
        if not (0 <= channel <= 15):
            raise ValueError("Channel must be 0..15")
        on &= 0x0FFF
        off &= 0x0FFF
        base = self._LED0_ON_L + 4 * channel
        self.bus.write_i2c_block_data(self.address, base, [
            on & 0xFF, (on >> 8) & 0xFF, off & 0xFF, (off >> 8) & 0xFF
        ])

    def set_pwm_us(self, channel: int, pulse_us: int):
        """Convenience: set PWM by pulse width in microseconds at current frequency."""
        if self.freq_hz is None:
            raise RuntimeError("Frequency not set")
        # 1 period in microseconds = 1_000_000 / freq
        # ticks per period = 4096
        # ticks = pulse_us * 4096 * freq / 1_000_000
        ticks = int(round(pulse_us * 4096.0 * self.freq_hz / 1_000_000.0))
        ticks = max(0, min(4095, ticks))
        self.set_pwm(channel, 0, ticks)

# ============================================================
# CONFIG
# ============================================================
# Map your REST "pin" IDs to PCA9685 channels (0..15).
# This keeps your client unchanged (pins 2,9,21,22) while we drive PCA9685 0..3.
SERVO_CHANNEL_MAP: Dict[int, int] = {
    2: 0,   # claw  -> channel 0
    9: 1,   # reach -> channel 1
    21: 2,  # base  -> channel 2
    22: 3,  # height-> channel 3
}

# Servo config per "pin" (same keys you used before)
# 'type': 'pos' (positional) or 'cr' (continuous rotation)
# 'range': allowed angle range in degrees (string "min:max" or tuple)
# 'part': friendly name
SERVO_MAP: Dict[int, Dict[str, Any]] = {
    2:  {"type": "pos", "range": "-80:45",  "part": "claw"},
    9:  {"type": "pos", "range": "-10:110", "part": "reach"},
    21: {"type": "pos", "range": "-100:120","part": "base"},
    22: {"type": "pos", "range": "0:100",   "part": "height"},
}

# PCA9685/I2C settings (you can override via env vars)
I2C_BUS = int(os.getenv("I2C_BUS", "1"))                 # check with: ls /dev/i2c-*
PCA9685_ADDR = int(os.getenv("PCA9685_ADDR", "0x40"), 16)
SERVO_PWM_FREQ = int(os.getenv("SERVO_PWM_FREQ", "50"))  # 50–60 Hz for servos

# Servo timing (microseconds). Adjust to match your servos.
MIN_PULSE_US = int(os.getenv("MIN_PULSE_US", "500"))     # 500–600 typical min
MAX_PULSE_US = int(os.getenv("MAX_PULSE_US", "2500"))    # 2400–2500 typical max
PULSE_RANGE_US = MAX_PULSE_US - MIN_PULSE_US

# Angle mapping uses [-90..+90] -> [MIN_PULSE_US..MAX_PULSE_US]
# You can request outside [-90..+90], it will clamp to min/max pulse.
ANGLE_OFFSET = 90

# Continuous rotation servo settings (µs). Adjust per channel if needed.
STOP_PULSE_CR_US = {  # neutral pulse (stops rotation)
    2: 1500,
}
# Gain: how many microseconds per unit of speed (1%).
# Example: 5 us/%, so speed=+100 => +500 us from neutral (≈1950–2000us).
GAIN_CR_US = {
    2: 5,
}

# Smooth movement
SMOOTH_STEPS = 20
STEP_DELAY = 0.02

# Camera settings
CAMERA_IP = "192.168.15.9"
CAMERA_CAPTURE_PORT = 80
CAMERA_STREAM_PORT = 81
CAMERA_CONNECT_TIMEOUT = 5
CAMERA_STREAM_READ_TIMEOUT = 60

# Global state
current_state: Dict[int, Union[int, float]] = {}  # stores last pulse_us for each "pin"
is_initialized = False
pca: Optional[PCA9685] = None

IMAGE_DIR = "frames"
os.makedirs(IMAGE_DIR, exist_ok=True)

app = FastAPI(title="Robot Control + Vision API", version="3.0.0")
app.mount("/frames", StaticFiles(directory=IMAGE_DIR), name="frames")

# ============================================================
# HELPERS (CONFIG)
# ============================================================
def _parse_range(range_value: Any) -> Tuple[int, int]:
    # Accept tuple/list (min,max) or string "min:max"
    if isinstance(range_value, (tuple, list)) and len(range_value) == 2:
        try:
            mn = int(float(range_value[0])); mx = int(float(range_value[1]))
        except Exception:
            mn, mx = -90, 90
    elif isinstance(range_value, str):
        try:
            parts = range_value.replace(" ", "").split(":")
            if len(parts) == 2:
                mn = int(float(parts[0])); mx = int(float(parts[1]))
            else:
                mn, mx = -90, 90
        except Exception:
            mn, mx = -90, 90
    else:
        mn, mx = -90, 90
    if mn > mx:
        mn, mx = mx, mn
    return mn, mx

def get_channel_for_pin(pin: int) -> int:
    ch = SERVO_CHANNEL_MAP.get(pin)
    if ch is None:
        raise HTTPException(status_code=400, detail=f"No PCA9685 channel mapped for pin {pin}")
    return ch

def get_servo_type(pin: int) -> str:
    cfg = SERVO_MAP.get(pin, {})
    return cfg.get("type", "pos")

def get_servo_range(pin: int) -> Tuple[int, int]:
    cfg = SERVO_MAP.get(pin, {})
    r = cfg.get("range", (-90, 90))
    return _parse_range(r)

def get_servo_part(pin: int) -> Optional[str]:
    cfg = SERVO_MAP.get(pin, {})
    return cfg.get("part")

def clamp_angle_to_range(pin: int, angle: Union[int, float]) -> Tuple[int, bool]:
    mn, mx = get_servo_range(pin)
    clamped = int(max(mn, min(mx, int(angle))))
    return clamped, clamped != int(angle)

def format_range_str(pin: int) -> str:
    mn, mx = get_servo_range(pin)
    return f"{mn}:{mx}"

def angle_to_pulse_us(angle: int) -> int:
    """Map [-90..+90] to [MIN_PULSE_US..MAX_PULSE_US] with safety clamp."""
    raw = MIN_PULSE_US + PULSE_RANGE_US * (angle + ANGLE_OFFSET) / 180.0
    return int(max(MIN_PULSE_US, min(MAX_PULSE_US, raw)))

def pulse_us_to_angle(pulse_us: int) -> int:
    """Inverse mapping (approximate) from pulse width to angle."""
    frac = (pulse_us - MIN_PULSE_US) / float(PULSE_RANGE_US)
    angle = frac * 180.0 - ANGLE_OFFSET
    return int(round(max(-90, min(90, angle))))

# ============================================================
# MODELS
# ============================================================
class ServoCommand(BaseModel):
    pin: int = Field(..., description="Logical pin ID (mapped to PCA9685 channel)")
    value: Union[int, float] = Field(..., description="Angle (positional) or speed (continuous)")
    smooth: bool = Field(default=True, description="Smooth movement (positional only)")

    @validator('pin')
    def validate_pin(cls, v):
        if v not in SERVO_MAP:
            raise ValueError(f'Invalid pin {v}. Valid: {list(SERVO_MAP.keys())}')
        return v

    @validator('value')
    def validate_value(cls, v, values):
        pin = values.get('pin')
        if pin is not None:
            servo_type = get_servo_type(pin)
            if servo_type == "cr":
                if not (-100 <= float(v) <= 100):
                    raise ValueError('Speed must be between -100 and +100')
        return v

class BatchCommand(BaseModel):
    commands: List[str] = Field(..., description="List of commands")

# ============================================================
# CORE SERVO FUNCTIONS (PCA9685)
# ============================================================
def ensure_initialized():
    """Initialize PCA9685 and center servos once."""
    global is_initialized, pca
    if is_initialized and pca is not None:
        return
    try:
        pca = PCA9685(bus=I2C_BUS, address=PCA9685_ADDR, freq_hz=SERVO_PWM_FREQ)
    except FileNotFoundError:
        raise HTTPException(status_code=500, detail="I2C bus not found. Enable I2C and check /dev/i2c-*")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to init PCA9685: {e}")

    centre_us = MIN_PULSE_US + (MAX_PULSE_US - MIN_PULSE_US) // 2
    for pin, cfg in SERVO_MAP.items():
        ch = get_channel_for_pin(pin)
        servo_type = cfg.get("type", "pos")
        if servo_type == "pos":
            pca.set_pwm_us(ch, centre_us)
            current_state[pin] = centre_us
        else:
            stop_us = STOP_PULSE_CR_US.get(pin, 1500)
            pca.set_pwm_us(ch, stop_us)
            current_state[pin] = stop_us
    time.sleep(0.025)
    is_initialized = True

def move_servo_smooth(pin: int, angle: int):
    """Smooth move for positional servo using incremental pulse changes."""
    if get_servo_type(pin) != "pos":
        raise HTTPException(status_code=400, detail="Smooth movement is only for positional servos")
    angle, _ = clamp_angle_to_range(pin, angle)
    target_us = angle_to_pulse_us(angle)
    current_us = int(current_state.get(pin, angle_to_pulse_us(0)))
    diff = target_us - current_us
    step = diff / float(SMOOTH_STEPS)
    ch = get_channel_for_pin(pin)
    for _ in range(SMOOTH_STEPS):
        current_us += step
        pca.set_pwm_us(ch, int(round(current_us)))
        time.sleep(STEP_DELAY)
    pca.set_pwm_us(ch, target_us)
    current_state[pin] = target_us

def move_servo_direct(pin: int, angle: int):
    """Direct move (single set) for positional servo."""
    if get_servo_type(pin) != "pos":
        raise HTTPException(status_code=400, detail="Direct movement is only for positional servos")
    angle, _ = clamp_angle_to_range(pin, angle)
    pulse_us = angle_to_pulse_us(angle)
    ch = get_channel_for_pin(pin)
    pca.set_pwm_us(ch, pulse_us)
    current_state[pin] = pulse_us

def move_servo_speed(pin: int, speed: int):
    """Speed control for continuous rotation servo. speed: -100..+100"""
    if get_servo_type(pin) != "cr":
        raise HTTPException(status_code=400, detail="Speed is only for continuous-rotation servos")
    stop_us = STOP_PULSE_CR_US.get(pin, 1500)
    gain_us = GAIN_CR_US.get(pin, 5)
    pulse_us = int(round(stop_us + gain_us * int(speed)))
    pulse_us = max(MIN_PULSE_US, min(MAX_PULSE_US, pulse_us))
    ch = get_channel_for_pin(pin)
    pca.set_pwm_us(ch, pulse_us)
    current_state[pin] = pulse_us

def center_all_servos():
    for pin, cfg in SERVO_MAP.items():
        servo_type = cfg.get("type", "pos")
        if servo_type == "pos":
            move_servo_smooth(pin, 0)
        else:
            move_servo_speed(pin, 0)

# ============================================================
# CAMERA HELPERS
# ============================================================
def capture_frame_from_esp32():
    """Grab a single frame from ESP32CAM via /capture."""
    try:
        url = f"http://{CAMERA_IP}:{CAMERA_CAPTURE_PORT}/capture"
        response = requests.get(url, timeout=CAMERA_CONNECT_TIMEOUT)
        if response.status_code == 200:
            nparr = np.frombuffer(response.content, np.uint8)
            frame = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
            return frame
        return None
    except Exception as e:
        print(f"Error capturing frame: {e}")
        return None

# ============================================================
# SERVO ENDPOINTS
# ============================================================
@app.post("/servo/move")
async def move_servo(command: ServoCommand):
    ensure_initialized()
    servo_type = get_servo_type(command.pin)

    if servo_type == "pos":
        requested = int(command.value)
        applied, clamped = clamp_angle_to_range(command.pin, requested)
        if command.smooth:
            move_servo_smooth(command.pin, applied)
        else:
            move_servo_direct(command.pin, applied)
        resp = {
            "pin": command.pin,
            "requested_angle": requested,
            "applied_angle": applied,
            "mode": "smooth" if command.smooth else "direct"
        }
        if clamped:
            resp["warning"] = f"Value was out of allowed range ({format_range_str(command.pin)}). Applied {applied}."
        return resp
    else:
        move_servo_speed(command.pin, int(command.value))
        return {"pin": command.pin, "speed": command.value}

@app.post("/servo/center")
async def center_servos():
    ensure_initialized()
    center_all_servos()
    return {"message": "Servos centered"}

@app.post("/servo/demo")
async def run_demo():
    ensure_initialized()
    demo_sequence = [
        "2 45", "2 0", "2 -80", "2 0",
        "9 45", "2 45", "9 0",
        "21 45", "22 0", "9 45",
        "21 -45", "21 45", "22 90", "22 0"
    ]
    for cmd_line in demo_sequence:
        parts = cmd_line.split()
        pin, value = int(parts[0]), int(parts[1])
        servo_type = get_servo_type(pin)
        if servo_type == "pos":
            move_servo_smooth(pin, value)
        else:
            move_servo_speed(pin, value)
    center_all_servos()
    return {"message": "Demo finished"}

# ============================================================
# IMAGE RESPONSE MODELS
# ============================================================
DataURI = constr(pattern=r"^data:image\/jpeg;base64,.*", strip_whitespace=True)

class FrameDataURIResponse(BaseModel):
    image_url: DataURI = Field(
        ...,
        description="Data-URI JPEG",
        example="data:image/jpeg;base64,/9j/4AA…"
    )
    timestamp: float

@app.get("/camera/frame")
async def get_frame(request: Request,
                    max_width: int = 160,
                    jpeg_quality: int = 30):
    frame = capture_frame_from_esp32()
    if frame is None:
        raise HTTPException(503, "Camera not available")
    # resize
    h, w = frame.shape[:2]
    if w > max_width:
        frame = cv2.resize(frame, (max_width, int(h * max_width / w)),
                           interpolation=cv2.INTER_AREA)
    # encode JPEG
    ok, buf = cv2.imencode(".jpg", frame,
                           [int(cv2.IMWRITE_JPEG_QUALITY), jpeg_quality])
    if not ok:
        raise HTTPException(500, "JPEG encode failed")
    # save to disk
    fname = f"{uuid.uuid4().hex}.jpg"
    with open(os.path.join(IMAGE_DIR, fname), "wb") as f:
        f.write(buf.tobytes())
    # absolute URL
    image_url = str(request.base_url) + f"frames/{fname}"
    return {"image_url": image_url, "timestamp": time.time()}

# ============================================================
# CAMERA STREAM (PROXY)
# ============================================================
@app.get("/camera/stream")
def camera_stream():
    """
    MJPEG stream proxy from ESP32-CAM.
    Uses proper port and keeps upstream stream alive.
    """
    url = f"http://{CAMERA_IP}:{CAMERA_STREAM_PORT}/stream"
    try:
        upstream = requests.get(url, stream=True, timeout=(CAMERA_CONNECT_TIMEOUT, CAMERA_STREAM_READ_TIMEOUT))
    except requests.RequestException as e:
        raise HTTPException(503, f"Camera not available: {e}")

    if upstream.status_code != 200:
        try:
            err_snippet = upstream.text[:200]
        except Exception:
            err_snippet = ""
        upstream.close()
        raise HTTPException(503, f"Camera not available (status {upstream.status_code}). {err_snippet}")

    content_type = upstream.headers.get("Content-Type", "multipart/x-mixed-replace; boundary=frame")

    def iter_stream():
        try:
            for chunk in upstream.iter_content(chunk_size=16384):
                if chunk:
                    yield chunk
        finally:
            upstream.close()

    headers = {
        "Cache-Control": "no-cache, no-store, must-revalidate",
        "Pragma": "no-cache",
        "Connection": "keep-alive",
        "Content-Type": content_type,
    }
    return StreamingResponse(iter_stream(), media_type=content_type, headers=headers)

# ============================================================
# FULL STATUS ENDPOINT
# ============================================================
@app.get("/robot/status")
async def get_robot_full_status():
    """Full status: servos + camera, including range and part per servo."""
    servos = []
    for pin, cfg in SERVO_MAP.items():
        servo_type = cfg.get("type", "pos")
        pulse_us = current_state.get(pin)
        if servo_type == "pos" and pulse_us is not None:
            value = pulse_us_to_angle(int(pulse_us))
        else:
            value = pulse_us  # for 'cr', report pulse_us
        servos.append({
            "pin": pin,
            "channel": SERVO_CHANNEL_MAP.get(pin),
            "type": servo_type,
            "range": format_range_str(pin),
            "part": cfg.get("part"),
            "value": value
        })

    frame = capture_frame_from_esp32()
    camera_connected = frame is not None

    return {
        "servo_system": {
            "initialized": is_initialized,
            "i2c_bus": I2C_BUS,
            "pca9685_addr": hex(PCA9685_ADDR),
            "frequency_hz": SERVO_PWM_FREQ,
            "min_pulse_us": MIN_PULSE_US,
            "max_pulse_us": MAX_PULSE_US,
            "servos": servos
        },
        "camera_system": {
            "connected": camera_connected,
            "capture_url": f"http://{CAMERA_IP}:{CAMERA_CAPTURE_PORT}/capture",
            "stream_url": f"http://{CAMERA_IP}:{CAMERA_STREAM_PORT}/stream"
        },
        "timestamp": time.time()
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
