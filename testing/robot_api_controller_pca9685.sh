#!/usr/bin/env python3
"""
REST API for Servo Control + ESP32CAM Camera - Orange Pi with PCA9685
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

# Adafruit PCA9685/ServoKit libraries
import board
import busio
from adafruit_servokit import ServoKit

# ============================================================
# CONFIGURATION
# ============================================================
# The SERVO_MAP now uses PCA9685 channels (0-15) as keys instead of GPIO pins.
# I've mapped your old pins (2, 9, 21, 22) to the first four channels (0, 1, 2, 3).
SERVO_MAP: Dict[int, Dict[str, Any]] = {
    0:  {"type": "pos", "range": "-80:45", "part": "claw"},    # Was GPIO 2
    1:  {"type": "pos", "range": "-10:110", "part": "reach"},  # Was GPIO 9
    2: {"type": "pos", "range": "-100:120", "part": "base"},   # Was GPIO 21
    3: {"type": "pos", "range": "0:100", "part": "height"},  # Was GPIO 22
}

# Standard pulse width range for most hobby servos (in microseconds).
# The ServoKit library uses these values.
MIN_PULSE_WIDTH = 500
MAX_PULSE_WIDTH = 2500

# Default total angle range for servos. Most are ~180 degrees.
# This will be the default if not specified in SERVO_MAP.
DEFAULT_ACTUATION_RANGE = 180

# Configs for continuous rotation servos (if you have any)
# Throttle is from -1.0 (full reverse) to 1.0 (full forward). 0 is stop.
CR_SERVOS = {} # Example: {4: {"part": "wheel"}}

# Movement smoothing settings
SMOOTH_STEPS = 20
STEP_DELAY = 0.02

# Camera settings
CAMERA_IP = "192.168.15.9"
CAMERA_CAPTURE_PORT = 80
CAMERA_STREAM_PORT = 81
CAMERA_CONNECT_TIMEOUT = 5
CAMERA_STREAM_READ_TIMEOUT = 60

# Global state
kit: Optional[ServoKit] = None
is_initialized = False

IMAGE_DIR = "frames"
os.makedirs(IMAGE_DIR, exist_ok=True)

app = FastAPI(title="Robot Control + Vision API (PCA9685)", version="2.2.0")
app.mount("/frames", StaticFiles(directory=IMAGE_DIR), name="frames")

# ============================================================
# CONFIG HELPERS
# ============================================================
def _parse_range(range_value: Any) -> Tuple[int, int]:
    # Accepts tuple/list (min,max) or string "min:max"
    if isinstance(range_value, (tuple, list)) and len(range_value) == 2:
        try:
            mn, mx = int(float(range_value[0])), int(float(range_value[1]))
        except Exception:
            mn, mx = -90, 90
    elif isinstance(range_value, str):
        try:
            parts = range_value.replace(" ", "").split(":")
            mn, mx = (int(float(parts[0])), int(float(parts[1]))) if len(parts) == 2 else (-90, 90)
        except Exception:
            mn, mx = -90, 90
    else:
        mn, mx = -90, 90
    return (mn, mx) if mn <= mx else (mx, mn)

def get_servo_type(channel: int) -> str:
    return SERVO_MAP.get(channel, {}).get("type", "pos")

def get_servo_range(channel: int) -> Tuple[int, int]:
    r = SERVO_MAP.get(channel, {}).get("range", (-90, 90))
    return _parse_range(r)

def get_servo_part(channel: int) -> Optional[str]:
    return SERVO_MAP.get(channel, {}).get("part")

def clamp_angle_to_range(channel: int, angle: Union[int, float]) -> Tuple[int, bool]:
    mn, mx = get_servo_range(channel)
    clamped = int(max(mn, min(mx, int(angle))))
    return clamped, clamped != int(angle)

def format_range_str(channel: int) -> str:
    mn, mx = get_servo_range(channel)
    return f"{mn}:{mx}"

# ============================================================
# MODELS
# ============================================================
class ServoCommand(BaseModel):
    channel: int = Field(..., description="PCA9685 channel (0-15)")
    value: Union[int, float] = Field(..., description="Angle (positional) or speed (continuous)")
    smooth: bool = Field(default=True, description="Use smooth motion (positional only)")

    @validator('channel')
    def validate_channel(cls, v):
        if v not in SERVO_MAP:
            raise ValueError(f'Invalid channel {v}. Valid channels: {list(SERVO_MAP.keys())}')
        return v

    @validator('value')
    def validate_value(cls, v, values):
        channel = values.get('channel')
        if channel is not None:
            servo_type = get_servo_type(channel)
            if servo_type == "cr" and not (-100 <= float(v) <= 100):
                raise ValueError('Speed must be between -100 and +100')
        return v

# ============================================================
# CORE SERVO FUNCTIONS (PCA9685)
# ============================================================
def ensure_initialized():
    global is_initialized, kit
    if is_initialized:
        return
    try:
        i2c = busio.I2C(board.SCL, board.SDA)
        kit = ServoKit(channels=16, i2c=i2c)
        # Configure each servo
        for channel, config in SERVO_MAP.items():
            if config.get("type", "pos") == "pos":
                kit.servo[channel].actuation_range = DEFAULT_ACTUATION_RANGE
                kit.servo[channel].set_pulse_width_range(MIN_PULSE_WIDTH, MAX_PULSE_WIDTH)
        is_initialized = True
        print("PCA9685 and Servos initialized successfully.")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to initialize PCA9685: {e}. Check I2C connection and permissions.")

def move_servo_smooth(channel: int, angle: int):
    global kit
    if get_servo_type(channel) != "pos":
        raise HTTPException(status_code=400, detail="Smooth motion is for positional servos only.")
    
    angle, _ = clamp_angle_to_range(channel, angle)
    
    # ServoKit's angle might be None on first access, default to a center position (90)
    current_angle = kit.servo[channel].angle if kit.servo[channel].angle is not None else 90
    
    diff = angle - current_angle
    if abs(diff) < 1: return # No movement needed

    step = diff / SMOOTH_STEPS
    for i in range(SMOOTH_STEPS):
        current_angle += step
        kit.servo[channel].angle = current_angle
        time.sleep(STEP_DELAY)
    
    kit.servo[channel].angle = angle # Ensure it ends at the exact target

def move_servo_direct(channel: int, angle: int):
    global kit
    if get_servo_type(channel) != "pos":
        raise HTTPException(status_code=400, detail="Direct motion is for positional servos only.")
    
    angle, _ = clamp_angle_to_range(channel, angle)
    kit.servo[channel].angle = angle

def move_servo_speed(channel: int, speed: int):
    global kit
    if get_servo_type(channel) != "cr":
        raise HTTPException(status_code=400, detail="Speed control is for continuous rotation servos only.")
    
    # Map speed (-100 to 100) to throttle (-1.0 to 1.0)
    throttle = max(-1.0, min(1.0, speed / 100.0))
    kit.continuous_servo[channel].throttle = throttle

def center_all_servos():
    for channel, cfg in SERVO_MAP.items():
        servo_type = cfg.get("type", "pos")
        if servo_type == "pos":
            # Move to angle 0, clamped to the servo's allowed range
            move_servo_smooth(channel, 0)
        else:
            move_servo_speed(channel, 0) # Stop continuous servos

# ============================================================
# CAMERA FUNCTIONS (Unchanged)
# ============================================================
def capture_frame_from_esp32():
    """Captures a single frame from the ESP32CAM via /capture endpoint"""
    try:
        url = f"http://{CAMERA_IP}:{CAMERA_CAPTURE_PORT}/capture"
        response = requests.get(url, timeout=CAMERA_CONNECT_TIMEOUT)
        if response.status_code == 200:
            nparr = np.frombuffer(response.content, np.uint8)
            return cv2.imdecode(nparr, cv2.IMREAD_COLOR)
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
    servo_type = get_servo_type(command.channel)

    if servo_type == "pos":
        requested = int(command.value)
        applied, was_clamped = clamp_angle_to_range(command.channel, requested)

        if command.smooth:
            move_servo_smooth(command.channel, applied)
        else:
            move_servo_direct(command.channel, applied)

        resp = {
            "channel": command.channel,
            "requested_angle": requested,
            "applied_angle": applied,
            "mode": "smooth" if command.smooth else "direct"
        }
        if was_clamped:
            resp["warning"] = f"Value was outside the allowed range ({format_range_str(command.channel)}). Applied {applied}."
        return resp

    else: # Continuous rotation servo
        move_servo_speed(command.channel, int(command.value))
        return {"channel": command.channel, "speed": command.value}

@app.post("/servo/center")
async def center_servos():
    ensure_initialized()
    center_all_servos()
    return {"message": "All servos centered or stopped."}

@app.post("/servo/demo")
async def run_demo():
    ensure_initialized()
    # Demo sequence now uses channels 0, 1, 2, 3
    demo_sequence = [
        "0 45", "0 0", "0 -80", "0 0",      # Claw
        "1 45", "0 45", "1 0",            # Reach + Claw
        "2 45", "3 0", "1 45",            # Base, Height, Reach
        "2 -45", "2 45", "3 90", "3 0"   # Base, Height
    ]
    for cmd_line in demo_sequence:
        parts = cmd_line.split()
        channel, value = int(parts[0]), int(parts[1])
        servo_type = get_servo_type(channel)
        if servo_type == "pos":
            move_servo_smooth(channel, value)
        else:
            move_servo_speed(channel, value)
    center_all_servos()
    return {"message": "Demo sequence completed."}

# ============================================================
# CAMERA MODELS & ENDPOINTS (Unchanged)
# ============================================================
DataURI = constr(pattern=r"^data:image\/jpeg;base64,.*", strip_whitespace=True)

class FrameDataURIResponse(BaseModel):
    image_url: DataURI = Field(..., description="JPEG Data-URI", example="data:image/jpeg;base64,/9j/4AA…")
    timestamp: float

@app.get("/camera/frame")
async def get_frame(request: Request, max_width: int = 160, jpeg_quality: int = 30):
    frame = capture_frame_from_esp32()
    if frame is None:
        raise HTTPException(503, "Camera unavailable")
    h, w = frame.shape[:2]
    if w > max_width:
        frame = cv2.resize(frame, (max_width, int(h * max_width / w)), interpolation=cv2.INTER_AREA)
    ok, buf = cv2.imencode(".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), jpeg_quality])
    if not ok:
        raise HTTPException(500, "JPEG encoding failed")
    fname = f"{uuid.uuid4().hex}.jpg"
    with open(os.path.join(IMAGE_DIR, fname), "wb") as f:
        f.write(buf.tobytes())
    image_url = str(request.base_url) + f"frames/{fname}"
    return {"image_url": image_url, "timestamp": time.time()}

@app.get("/camera/stream")
def camera_stream():
    url = f"http://{CAMERA_IP}:{CAMERA_STREAM_PORT}/stream"
    try:
        upstream = requests.get(url, stream=True, timeout=(CAMERA_CONNECT_TIMEOUT, CAMERA_STREAM_READ_TIMEOUT))
        upstream.raise_for_status()
    except requests.RequestException as e:
        raise HTTPException(503, f"Camera unavailable: {e}")

    content_type = upstream.headers.get("Content-Type", "multipart/x-mixed-replace; boundary=frame")
    
    def iter_stream():
        try:
            for chunk in upstream.iter_content(chunk_size=16384):
                yield chunk
        finally:
            upstream.close()

    headers = {
        "Cache-Control": "no-cache, no-store, must-revalidate",
        "Pragma": "no-cache",
        "Connection": "keep-alive",
    }
    return StreamingResponse(iter_stream(), media_type=content_type, headers=headers)

# ============================================================
# FULL STATUS ENDPOINT
# ============================================================
@app.get("/robot/status")
async def get_robot_full_status():
    """Full status: servos + camera, including range and part per servo"""
    servos = []
    if is_initialized and kit:
        for channel, cfg in SERVO_MAP.items():
            servo_type = cfg.get("type", "pos")
            current_value = None
            if servo_type == "pos":
                current_value = kit.servo[channel].angle
            else: # continuous
                current_value = kit.continuous_servo[channel].throttle * 100 # convert back to -100..100
            
            servos.append({
                "channel": channel,
                "type": servo_type,
                "range": format_range_str(channel) if servo_type == "pos" else "-100:100",
                "part": cfg.get("part"),
                "value": round(current_value, 2) if current_value is not None else None
            })

    frame = capture_frame_from_esp32()
    camera_connected = frame is not None

    return {
        "servo_system": {
            "initialized": is_initialized,
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
