import json
from pathlib import Path
from typing import Any, Dict, List

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from app.config import AppConfig

ROOT_DIR = Path(__file__).resolve().parent
TEMPLATE_DIR = ROOT_DIR / "templates"
STATIC_DIR = ROOT_DIR / "static"

router = APIRouter()
templates = Jinja2Templates(directory=str(TEMPLATE_DIR))


def build_ui_payload(cfg: AppConfig) -> Dict[str, Any]:
    servos: List[Dict[str, Any]] = []
    for servo in cfg.servos:
        servos.append(
            {
                "pin": servo.pin,
                "channel": servo.channel,
                "part": servo.part,
                "type": servo.type,
                "range": [servo.range[0], servo.range[1]],
            }
        )

    payload = {
        "statusRefreshMs": cfg.ui.status_refresh_ms,
        "keyRepeatMs": cfg.ui.key_repeat_ms,
        "step": {**cfg.ui.part_step_pct, "default": cfg.ui.default_step_pct},
        "servos": servos,
        "demoSmooth": cfg.demo_smooth,
        "servoDriver": cfg.servo_driver,
        "camera": {
            "capture": f"/camera/frame",
            "stream": f"/camera/stream",
            "raw": {
                "capture": f"http://{cfg.camera_ip}:{cfg.camera_capture_port}/capture",
                "stream": f"http://{cfg.camera_ip}:{cfg.camera_stream_port}/stream",
            },
        },
        "api": {
            "move": "/servo/move",
            "center": "/servo/center",
            "demo": "/servo/demo",
            "status": "/robot/status",
            "logs": "/ui/logs",
            "logsExport": "/ui/logs/export",
            "config": "/ui/config",
            "testChannels": "/servo/test-channels" if cfg.servo_driver == "pca9685" else None,
        },
        "cameraSettings": {
            "ip": cfg.camera_ip,
            "capture_port": cfg.camera_capture_port,
            "stream_port": cfg.camera_stream_port,
            "connect_timeout": cfg.camera_connect_timeout,
            "stream_read_timeout": cfg.camera_stream_read_timeout,
        },
        "uiSettings": {
            "default_step_pct": cfg.ui.default_step_pct,
            "part_step_pct": cfg.ui.part_step_pct,
        },
    }
    return payload


def _get_cfg(request: Request) -> AppConfig:
    cfg = getattr(request.app.state, "cfg", None)
    if cfg is None:
        raise RuntimeError("Application configuration has not been initialised")
    return cfg


@router.get("/ui", response_class=HTMLResponse)
async def robot_ui(request: Request):
    cfg = _get_cfg(request)
    payload = build_ui_payload(cfg)
    log_manager = getattr(request.app.state, "log_manager", None)
    payload["logging"] = {
        "enabled": bool(getattr(log_manager, "enabled", False)),
        "log_count": int(getattr(log_manager, "entry_count", 0)),
    }
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "ui_config_json": json.dumps(payload),
            "title": "Educo Robot Control Dashboard",
        },
    )


@router.get("/ui/metadata")
async def ui_metadata(request: Request) -> Dict[str, Any]:
    cfg = _get_cfg(request)
    payload = build_ui_payload(cfg)
    log_manager = getattr(request.app.state, "log_manager", None)
    payload["logging"] = {
        "enabled": bool(getattr(log_manager, "enabled", False)),
        "log_count": int(getattr(log_manager, "entry_count", 0)),
    }
    return payload
