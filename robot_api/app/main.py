import csv
import configparser
import copy
import logging
import os
import queue
import socket
import threading
import time
import uuid
from io import StringIO
from typing import Any, Dict, List, Optional, Tuple

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, validator

import requests

import cv2
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

logger = logging.getLogger(__name__)


class CameraStreamRelay:
    def __init__(self, cfg):
        self._cfg = cfg
        self._clients: Dict[str, "queue.Queue[Optional[bytes]]"] = {}
        self._lock = threading.Lock()
        self._thread: Optional[threading.Thread] = None
        self._stop_event: Optional[threading.Event] = None
        self._frame_interval = 0.0

    def update_config(self, cfg) -> None:
        with self._lock:
            self._cfg = cfg

    def add_client(self) -> Tuple[str, "queue.Queue[Optional[bytes]]"]:
        client_id = uuid.uuid4().hex
        frame_queue: "queue.Queue[Optional[bytes]]" = queue.Queue(maxsize=4)
        with self._lock:
            self._clients[client_id] = frame_queue
            self._ensure_thread()
        return client_id, frame_queue

    def remove_client(self, client_id: str) -> None:
        to_join: Optional[threading.Thread] = None
        with self._lock:
            queue_ref = self._clients.pop(client_id, None)
            if queue_ref is not None:
                while not queue_ref.empty():
                    try:
                        queue_ref.get_nowait()
                    except queue.Empty:
                        break
                try:
                    queue_ref.put_nowait(None)
                except queue.Full:
                    pass
            if not self._clients and self._thread and self._stop_event:
                self._stop_event.set()
                to_join = self._thread
                self._thread = None
        if to_join:
            to_join.join(timeout=2)

    def _ensure_thread(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop_event = threading.Event()
        self._thread = threading.Thread(
            target=self._capture_loop,
            args=(self._stop_event,),
            daemon=True,
        )
        self._thread.start()

    @staticmethod
    def _parse_boundary(content_type: str) -> bytes:
        if not content_type:
            return b"--frame"

        boundary = None
        for part in content_type.split(";"):
            part = part.strip()
            if part.lower().startswith("boundary="):
                boundary = part.split("=", 1)[1].strip()
                break

        if not boundary:
            boundary = "frame"

        if boundary.startswith('"') and boundary.endswith('"') and len(boundary) >= 2:
            boundary = boundary[1:-1]

        if not boundary.startswith("--"):
            boundary = "--" + boundary

        return boundary.encode("utf-8", errors="ignore") or b"--frame"

    @staticmethod
    def _read_mjpeg_frame(reader, boundary: bytes) -> Optional[bytes]:
        while True:
            line = reader.readline()
            if not line:
                return None
            if line.strip() == b"":
                continue
            if line.startswith(boundary):
                break

        headers: Dict[str, str] = {}
        while True:
            line = reader.readline()
            if not line:
                return None
            if line in (b"\r\n", b"\n"):
                break
            try:
                key, value = line.decode("latin-1").split(":", 1)
            except ValueError:
                continue
            headers[key.strip().lower()] = value.strip()

        length_str = headers.get("content-length")
        if not length_str:
            return None

        try:
            expected = int(length_str)
        except ValueError:
            return None

        buffer = bytearray()
        remaining = expected
        while remaining > 0:
            chunk = reader.read(remaining)
            if not chunk:
                return None
            buffer.extend(chunk)
            remaining -= len(chunk)

        reader.readline()

        return bytes(buffer)

    def _capture_loop(self, stop_event: threading.Event) -> None:
        session = requests.Session()
        stream_resp: Optional[requests.Response] = None
        boundary = b"--frame"
        reader = None
        last_target: Optional[Tuple[str, int]] = None
        last_fallback = 0.0

        def close_stream():
            nonlocal stream_resp, reader
            if stream_resp is not None:
                try:
                    stream_resp.close()
                except Exception:
                    pass
            stream_resp = None
            reader = None

        try:
            while not stop_event.is_set():
                with self._lock:
                    cfg = self._cfg
                    has_clients = bool(self._clients)
                if not has_clients:
                    break

                stream_target = (cfg.camera_ip, cfg.camera_stream_port)
                if stream_target != last_target:
                    close_stream()
                    last_target = stream_target

                if stream_resp is None:
                    stream_url = f"http://{cfg.camera_ip}:{cfg.camera_stream_port}/stream"
                    try:
                        stream_resp = session.get(
                            stream_url,
                            stream=True,
                            timeout=(cfg.camera_connect_timeout, cfg.camera_stream_read_timeout),
                        )
                        stream_resp.raise_for_status()
                        boundary = self._parse_boundary(stream_resp.headers.get("Content-Type", ""))
                        reader = stream_resp.raw
                        reader.decode_content = True
                        logger.debug("Camera stream connected: %s", stream_url)
                    except (requests.RequestException, socket.timeout) as exc:
                        logger.warning("Camera stream connect failed (%s): %s", stream_url, exc)
                        close_stream()
                        if stop_event.wait(1.0):
                            break
                        continue

                frame_bytes: Optional[bytes] = None
                if reader is not None:
                    try:
                        frame_bytes = self._read_mjpeg_frame(reader, boundary)
                    except (socket.timeout, requests.RequestException) as exc:
                        logger.warning("Camera stream read error: %s", exc)
                        frame_bytes = None

                if frame_bytes is None:
                    close_stream()

                    now = time.time()
                    if now - last_fallback >= 1.0:
                        fallback = capture_frame(
                            cfg.camera_ip,
                            cfg.camera_capture_port,
                            cfg.camera_connect_timeout,
                        )
                        if fallback is not None:
                            ok, buffer = cv2.imencode(
                                ".jpg",
                                fallback,
                                [int(cv2.IMWRITE_JPEG_QUALITY), 70],
                            )
                            if ok:
                                self._broadcast(buffer.tobytes())
                        last_fallback = now

                    if stop_event.wait(0.1):
                        break
                    continue

                self._broadcast(frame_bytes)
                if self._frame_interval > 0 and stop_event.wait(self._frame_interval):
                    break
        finally:
            close_stream()
            session.close()
            self._broadcast(None)
            with self._lock:
                if self._stop_event is stop_event:
                    self._stop_event = None

    def _broadcast(self, payload: Optional[bytes]) -> None:
        with self._lock:
            recipients = list(self._clients.items())
        if not recipients:
            return
        for client_id, q in recipients:
            if payload is None:
                while not q.empty():
                    try:
                        q.get_nowait()
                    except queue.Empty:
                        break
                try:
                    q.put_nowait(None)
                except queue.Full:
                    pass
                continue
            try:
                q.put_nowait(payload)
            except queue.Full:
                try:
                    q.get_nowait()
                except queue.Empty:
                    pass
                try:
                    q.put_nowait(payload)
                except queue.Full:
                    pass
camera_stream_relay = CameraStreamRelay(cfg)
app.state.camera_stream = camera_stream_relay


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


class ServoConfigUpdate(BaseModel):
    part: str
    pin: Optional[int] = None
    channel: Optional[int] = None
    range: Optional[Tuple[int, int]] = None

    @validator("part")
    def _normalize_part(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("Servo part cannot be empty")
        return value.lower()

    @validator("pin")
    def _validate_pin(cls, value: Optional[int]) -> Optional[int]:
        if value is None:
            return None
        return int(value)

    @validator("channel")
    def _validate_channel(cls, value: Optional[int]) -> Optional[int]:
        if value is None:
            return None
        return int(value)

    @validator("range")
    def _validate_range(cls, value: Optional[Tuple[int, int]]) -> Optional[Tuple[int, int]]:
        if value is None:
            return None
        mn, mx = value
        return (int(mn), int(mx))


class ConfigUpdate(BaseModel):
    camera: Optional[CameraSettingsUpdate] = None
    ui: Optional[UIStepSettingsUpdate] = None
    servos: Optional[List[ServoConfigUpdate]] = None


class ChannelTestRequest(BaseModel):
    angle_delta: int = Field(20, ge=5, le=90)
    hold_ms: int = Field(400, ge=100, le=2000)
    settle_ms: int = Field(250, ge=50, le=2000)


def _find_servo_index(cfg: Any, update: ServoConfigUpdate) -> int:
    part_key = update.part.lower() if update.part else None
    for idx, servo in enumerate(cfg.servos, start=1):
        if part_key and servo.part.lower() == part_key:
            return idx
        if update.pin is not None and servo.pin == update.pin:
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
            if servo_update.range is not None:
                mn, mx = servo_update.range
                if mn > mx:
                    mn, mx = mx, mn
                parser.set("servos", f"range{idx}", f"{int(mn)}:{int(mx)}")
                modified = True
            if servo_update.pin is not None:
                parser.set("servos", f"pin{idx}", str(int(servo_update.pin)))
                modified = True
            if servo_update.channel is not None:
                parser.set("servos", f"channel{idx}", str(int(servo_update.channel)))
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


@app.post("/servo/test-channels")
async def test_pca9685_channels(params: ChannelTestRequest = ChannelTestRequest()):
    if cfg.servo_driver != "pca9685":
        raise HTTPException(400, "Channel test is only available when using the PCA9685 driver")

    controller.ensure_initialized()

    tested: List[Dict[str, Any]] = []
    hold_s = params.hold_ms / 1000.0
    settle_s = params.settle_ms / 1000.0
    delta = params.angle_delta

    for servo in cfg.servos:
        if servo.type != "pos" or servo.channel is None:
            continue

        tested.append({
            "part": servo.part,
            "pin": servo.pin,
            "channel": servo.channel,
        })

        lower = max(servo.range[0], -delta)
        upper = min(servo.range[1], delta)

        try:
            controller.move_servo_smooth(servo.pin, 0)
            time.sleep(settle_s)
            controller.move_servo_smooth(servo.pin, lower)
            time.sleep(hold_s)
            controller.move_servo_smooth(servo.pin, 0)
            time.sleep(settle_s)
            controller.move_servo_smooth(servo.pin, upper)
            time.sleep(hold_s)
            controller.move_servo_smooth(servo.pin, 0)
            time.sleep(settle_s)
        except Exception as exc:
            raise HTTPException(500, f"Channel test failed while moving '{servo.part}': {exc}") from exc

    return {"tested": len(tested), "details": tested}


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


@app.get("/ui/logs/export")
async def export_logged_moves_csv():
    entries = log_manager.iter_all_entries()
    filename = f"educo_move_logs_{int(time.time())}.csv"

    def row_iter():
        output = StringIO()
        writer = csv.writer(output)
        writer.writerow(["id", "timestamp", "part", "pin", "target_value", "smooth", "pre_image", "post_image"])
        yield output.getvalue()
        for entry in entries:
            output = StringIO()
            writer = csv.writer(output)
            camera = entry.get("camera") or {}
            writer.writerow(
                [
                    entry.get("id"),
                    entry.get("timestamp"),
                    entry.get("part"),
                    entry.get("pin"),
                    entry.get("target_value"),
                    entry.get("smooth"),
                    camera.get("pre_image"),
                    camera.get("post_image"),
                ]
            )
            yield output.getvalue()

    headers = {"Content-Disposition": f'attachment; filename="{filename}"'}
    return StreamingResponse(row_iter(), media_type="text/csv", headers=headers)

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
        camera_stream_relay.update_config(cfg)

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
    client_id, frame_queue = camera_stream_relay.add_client()
    boundary = "frame"
    boundary_bytes = boundary.encode()

    def frame_generator():
        try:
            while True:
                try:
                    payload = frame_queue.get(timeout=5)
                except queue.Empty:
                    continue
                if payload is None:
                    break
                yield (
                    b"--" + boundary_bytes + b"\r\n"
                    b"Content-Type: image/jpeg\r\n"
                    b"Content-Length: " + str(len(payload)).encode() + b"\r\n\r\n"
                    + payload
                    + b"\r\n"
                )
        finally:
            camera_stream_relay.remove_client(client_id)

    headers = {
        "Cache-Control": "no-cache, no-store, must-revalidate",
        "Pragma": "no-cache",
        "Connection": "keep-alive",
    }
    media_type = f"multipart/x-mixed-replace; boundary={boundary}"
    return StreamingResponse(frame_generator(), media_type=media_type, headers=headers)
