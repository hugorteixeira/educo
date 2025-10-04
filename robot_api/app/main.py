import configparser
import copy
import os
import time
from typing import Any, Dict, List, Optional, Tuple

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, validator

from app.config import load_config
from app.servo.controller import ServoController
from app.servo.soft_pwm import SoftwarePWMBackend
from app.servo.hw_pwm import HardwarePWMBackend
from app.servo.pca9685 import PCA9685Backend
from app.camera import capture_frame, save_jpeg
from app.frontend import (
    router as frontend_router,
    STATIC_DIR as FRONTEND_STATIC_DIR,
    build_ui_payload,
)
from app.logger import LogManager

import requests

CFG_PATH = (
    os.environ.get("ROBOT_CFG_PATH")
    or os.environ.get("ROBOT_API_CFG")
    or "robot_api.cfg"
)
cfg = load_config(CFG_PATH)

# Build backend and controller
if cfg.servo_driver == "soft":
    gpiod_map = {s.pin: (s.gpiod_chip, s.gpiod_line) for s in cfg.servos}
    backend = SoftwarePWMBackend(
        period_us=cfg.period_us,
        backend=cfg.soft_backend,
        addressing=cfg.soft_addressing,
        gpiod_map=gpiod_map,
    )
elif cfg.servo_driver == "hw":
    backend = HardwarePWMBackend(pwm_freq=cfg.pwm_freq, pwm_range=cfg.pwm_range)
elif cfg.servo_driver == "pca9685":
    if cfg.pca9685 is None:
        raise RuntimeError("PCA9685 configuration is missing. Check the [pca9685] section in robot_api.cfg")
    backend = PCA9685Backend(cfg.pca9685, cfg.servos)
else:
    raise RuntimeError(f"Unsupported servo driver '{cfg.servo_driver}'. Valid options: soft, hw, pca9685")

controller = ServoController(cfg, backend)

app = FastAPI(title="Robot Control + Vision API", version="6.0.0")
app.state.cfg = cfg
app.include_router(frontend_router)
app.mount("/static", StaticFiles(directory=FRONTEND_STATIC_DIR), name="static")

IMAGE_DIR = "frames"
os.makedirs(IMAGE_DIR, exist_ok=True)
app.mount("/frames", StaticFiles(directory=IMAGE_DIR), name="frames")

LOG_DIR = os.environ.get("ROBOT_LOG_DIR", "logs")
log_manager = LogManager(LOG_DIR, IMAGE_DIR)
app.state.log_manager = log_manager


class ServoCommand(BaseModel):
    pin: int = Field(..., description="Pin number as defined in robot_api.cfg")
    value: int = Field(..., description="Angle (positional)")
    smooth: bool = Field(default=True, description="Smooth move (positional only)")


class LoggingToggle(BaseModel):
    enabled: bool


class CameraSettingsUpdate(BaseModel):
    ip: Optional[str] = None
    capture_port: Optional[int] = Field(None, ge=1, le=65535)
    stream_port: Optional[int] = Field(None, ge=1, le=65535)
    connect_timeout: Optional[int] = Field(None, ge=1, le=120)
    stream_read_timeout: Optional[int] = Field(None, ge=1, le=600)

    @validator("ip")
    def _validate_ip(cls, value: Optional[str]) -> Optional[str]:
        if value is None:
            return value
        value = value.strip()
        if not value:
            raise ValueError("Camera IP cannot be empty")
        return value


class UIStepSettingsUpdate(BaseModel):
    default_step_pct: Optional[float] = Field(None, gt=0, le=1)
    part_step_pct: Optional[Dict[str, float]] = None

    @validator("part_step_pct")
    def _validate_step_map(cls, value: Optional[Dict[str, float]]) -> Optional[Dict[str, float]]:
        if value is None:
            return value
        validated: Dict[str, float] = {}
        for key, step in value.items():
            if step is None:
                continue
            if not (0 < step <= 1):
                raise ValueError(f"Step percentage for '{key}' must be between 0 and 1")
            validated[key] = float(step)
        return validated


class ServoRangeUpdate(BaseModel):
    part: Optional[str] = None
    pin: Optional[int] = None
    range: Tuple[int, int]

    @validator("part")
    def _normalize_part(cls, value: Optional[str]) -> Optional[str]:
        if value is None:
            return value
        value = value.strip()
        return value.lower() if value else value

    @validator("pin", always=True)
    def _require_identifier(cls, value: Optional[int], values: Dict[str, Any]) -> Optional[int]:
        part = values.get("part")
        if value is None and not part:
            raise ValueError("Provide either pin or part for servo update")
        return value


class ConfigUpdate(BaseModel):
    camera: Optional[CameraSettingsUpdate] = None
    ui: Optional[UIStepSettingsUpdate] = None
    servos: Optional[List[ServoRangeUpdate]] = None


def _find_servo_index(cfg: Any, update: ServoRangeUpdate) -> int:
    for idx, servo in enumerate(cfg.servos, start=1):
        if update.pin is not None and servo.pin == update.pin:
            return idx
        if update.part is not None and servo.part.lower() == update.part:
            return idx
    raise ValueError("Servo not found for update")


def apply_config_updates(update: ConfigUpdate) -> bool:
    parser = configparser.ConfigParser(inline_comment_prefixes=(";", "#"), strict=False)
    parser.read(CFG_PATH)
    modified = False

    if update.camera:
        camera = update.camera
        if camera.ip is not None:
            parser.set("camera", "ip", camera.ip)
            modified = True
        if camera.capture_port is not None:
            parser.set("camera", "capture_port", str(int(camera.capture_port)))
            modified = True
        if camera.stream_port is not None:
            parser.set("camera", "stream_port", str(int(camera.stream_port)))
            modified = True
        if camera.connect_timeout is not None:
            parser.set("camera", "connect_timeout", str(int(camera.connect_timeout)))
            modified = True
        if camera.stream_read_timeout is not None:
            parser.set("camera", "stream_read_timeout", str(int(camera.stream_read_timeout)))
            modified = True

    if update.ui:
        ui_update = update.ui
        if ui_update.default_step_pct is not None:
            parser.set("ui", "default_step_pct", f"{ui_update.default_step_pct:.4f}")
            modified = True
        if ui_update.part_step_pct:
            for part, step in ui_update.part_step_pct.items():
                parser.set("ui", f"{part}_step_pct", f"{step:.4f}")
                modified = True

    if update.servos:
        for servo_update in update.servos:
            idx = _find_servo_index(cfg, servo_update)
            mn, mx = servo_update.range
            if mn > mx:
                mn, mx = mx, mn
            parser.set("servos", f"range{idx}", f"{int(mn)}:{int(mx)}")
            modified = True

    if not modified:
        return False

    with open(CFG_PATH, "w", encoding="utf-8") as handle:
        parser.write(handle)
    return True


@app.post("/servo/move")
async def move_servo(cmd: ServoCommand):
    try:
        controller.ensure_initialized()
        valid_pins = [s.pin for s in cfg.servos]
        if cmd.pin not in valid_pins:
            raise HTTPException(400, f"Invalid pin {cmd.pin}. Valid: {valid_pins}")

        logging_active = log_manager.enabled
        status_before = controller.status() if logging_active else None
        pre_image = log_manager.capture_snapshot(cfg, "pre") if logging_active else None

        if cmd.smooth:
            controller.move_servo_smooth(cmd.pin, int(cmd.value))
        else:
            controller.move_servo_direct(cmd.pin, int(cmd.value))

        response = {
            "pin": cmd.pin,
            "applied_angle": int(cmd.value),
            "mode": "smooth" if cmd.smooth else "direct",
        }

        if logging_active:
            status_after = controller.status()
            post_image = log_manager.capture_snapshot(cfg, "post")
            log_manager.write_entry(
                cfg,
                cmd.pin,
                int(cmd.value),
                cmd.smooth,
                status_before or [],
                status_after,
                pre_image,
                post_image,
            )

        return response
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(500, f"Servo move failed: {exc}") from exc


@app.post("/servo/center")
async def center_servos():
    try:
        controller.ensure_initialized()
        controller.center_all()
        return {"message": "Servos centered"}
    except Exception as exc:
        raise HTTPException(500, f"Center failed: {exc}") from exc


@app.post("/servo/demo")
async def run_demo():
    controller.ensure_initialized()
    for idx, val in cfg.demo_sequence:
        pin = controller.index_to_pin.get(idx)
        if pin is None:
            continue
        if cfg.demo_smooth:
            controller.move_servo_smooth(pin, val)
        else:
            controller.move_servo_direct(pin, val)
    controller.center_all()
    return {"message": "Demo executed"}


@app.get("/ui/logging")
async def get_logging_state():
    return log_manager.state()


@app.post("/ui/logging")
async def set_logging_state(toggle: LoggingToggle):
    return log_manager.set_enabled(toggle.enabled)


@app.get("/ui/logs")
async def get_logged_moves(limit: int = 50):
    limit = max(1, min(limit, 500))
    entries = log_manager.list_entries(limit)
    return {"entries": entries, "count": log_manager.entry_count}


@app.put("/ui/config")
async def update_ui_config(update: ConfigUpdate):
    try:
        modified = apply_config_updates(update)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc

    if modified:
        global cfg
        cfg = load_config(CFG_PATH)
        app.state.cfg = cfg
        controller.reconfigure(cfg)

    payload = build_ui_payload(cfg)
    payload["logging"] = log_manager.state()
    return payload


@app.get("/robot/status")
async def get_robot_status():
    controller.ensure_initialized()
    frame = capture_frame(cfg.camera_ip, cfg.camera_capture_port, cfg.camera_connect_timeout)
    cam_ok = frame is not None
    return {
        "servo_system": {
            "driver": cfg.servo_driver,
            "initialized": controller.initialized,
            "servos": controller.status(),
        },
        "camera_system": {
            "connected": cam_ok,
            "capture_url": f"http://{cfg.camera_ip}:{cfg.camera_capture_port}/capture",
            "stream_url": f"http://{cfg.camera_ip}:{cfg.camera_stream_port}/stream",
        },
        "server": {
            "api_base_url": cfg.api_base_url,
            "ui_port": cfg.server.ui_port,
        },
        "timestamp": time.time(),
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
        upstream = requests.get(
            url,
            stream=True,
            timeout=(cfg.camera_connect_timeout, cfg.camera_stream_read_timeout),
        )
    except requests.RequestException as exc:
        raise HTTPException(503, f"Camera unavailable: {exc}") from exc
    if upstream.status_code != 200:
        try:
            snippet = upstream.text[:200]
        except Exception:
            snippet = ""
        upstream.close()
        raise HTTPException(
            503, f"Camera unavailable (status {upstream.status_code}). {snippet}"
        )

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
