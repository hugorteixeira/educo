import os
import time
from typing import Dict, Any, List, Tuple

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from app.config import load_config
from app.servo.controller import ServoController
from app.servo.soft_pwm import SoftwarePWMBackend
from app.servo.hw_pwm import HardwarePWMBackend
from app.camera import capture_frame, save_jpeg

import requests

CFG_PATH = os.environ.get("ROBOT_API_CFG", "robot_api.cfg")
cfg = load_config(CFG_PATH)

# Build backend and controller
if cfg.servo_driver == "soft":
    # Build gpiod map: pin -> (chip, line)
    gpiod_map = {s.pin: (s.gpiod_chip, s.gpiod_line) for s in cfg.servos}
    backend = SoftwarePWMBackend(
        period_us=cfg.period_us,
        backend=cfg.soft_backend,
        addressing=cfg.soft_addressing,
        gpiod_map=gpiod_map
    )
else:
    backend = HardwarePWMBackend(pwm_freq=cfg.pwm_freq, pwm_range=cfg.pwm_range)

controller = ServoController(cfg, backend)

# FastAPI app
app = FastAPI(title="Robot Control + Vision API", version="5.0.0")

IMAGE_DIR = "frames"
os.makedirs(IMAGE_DIR, exist_ok=True)
app.mount("/frames", StaticFiles(directory=IMAGE_DIR), name="frames")

class ServoCommand(BaseModel):
    pin: int = Field(..., description="Pin number as defined in robot_api.cfg")
    value: int = Field(..., description="Angle (positional)")
    smooth: bool = Field(default=True, description="Smooth move (positional only)")

@app.post("/servo/move")
async def move_servo(cmd: ServoCommand):
    try:
        controller.ensure_initialized()
        # Ensure valid pin
        if cmd.pin not in [s.pin for s in cfg.servos]:
            raise HTTPException(400, f"Invalid pin {cmd.pin}. Valid: {[s.pin for s in cfg.servos]}")
        if cmd.smooth:
            controller.move_servo_smooth(cmd.pin, int(cmd.value))
        else:
            controller.move_servo_direct(cmd.pin, int(cmd.value))
        return {"pin": cmd.pin, "applied_angle": int(cmd.value), "mode": "smooth" if cmd.smooth else "direct"}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(500, f"Servo move failed: {e}")

@app.post("/servo/center")
async def center_servos():
    try:
        controller.ensure_initialized()
        controller.center_all()
        return {"message": "Servos centered"}
    except Exception as e:
        raise HTTPException(500, f"Center failed: {e}")

@app.post("/servo/demo")
async def run_demo():
    controller.ensure_initialized()
    # Convert demo (idx -> pin) and execute
    for idx, val in cfg.demo_sequence:
        pin = controller.index_to_pin[idx]
        if cfg.demo_smooth:
            controller.move_servo_smooth(pin, val)
        else:
            controller.move_servo_direct(pin, val)
    controller.center_all()
    return {"message": "Demo executed"}

@app.get("/robot/status")
async def get_robot_status():
    controller.ensure_initialized()
    # Camera quick probe
    frame = capture_frame(cfg.camera_ip, cfg.camera_capture_port, cfg.camera_connect_timeout)
    cam_ok = frame is not None
    return {
        "servo_system": {
            "driver": cfg.servo_driver,
            "initialized": controller.initialized,
            "servos": controller.status()
        },
        "camera_system": {
            "connected": cam_ok,
            "capture_url": f"http://{cfg.camera_ip}:{cfg.camera_capture_port}/capture",
            "stream_url": f"http://{cfg.camera_ip}:{cfg.camera_stream_port}/stream"
        },
        "timestamp": time.time()
    }

@app.get("/camera/frame")
async def camera_frame(request: Request, max_width: int = 160, jpeg_quality: int = 30):
    frame = capture_frame(cfg.camera_ip, cfg.camera_capture_port, cfg.camera_connect_timeout)
    if frame is None:
        raise HTTPException(503, "Camera unavailable")
    fname, _ = save_jpeg(frame, IMAGE_DIR, max_width=max_width, jpeg_quality=jpeg_quality)
    url = str(request.base_url) + f"frames/{fname}"
    return {"image_url": url, "timestamp": time.time()}

@app.get("/camera/stream")
def camera_stream():
    url = f"http://{cfg.camera_ip}:{cfg.camera_stream_port}/stream"
    try:
        upstream = requests.get(url, stream=True, timeout=(cfg.camera_connect_timeout, cfg.camera_stream_read_timeout))
    except requests.RequestException as e:
        raise HTTPException(503, f"Camera unavailable: {e}")
    if upstream.status_code != 200:
        try:
            snippet = upstream.text[:200]
        except Exception:
            snippet = ""
        upstream.close()
        raise HTTPException(503, f"Camera unavailable (status {upstream.status_code}). {snippet}")

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
