#!/usr/bin/env python3
"""
Compatibility launcher for the unified robot API (software or hardware PWM).
Reads the shared configuration file and starts the FastAPI application.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import uvicorn

BASE_DIR = Path(__file__).resolve().parent
APP_DIR = BASE_DIR / "robot_api"
if str(APP_DIR) not in sys.path:
    sys.path.insert(0, str(APP_DIR))

from app.config import load_config  # type: ignore  # pylint: disable=import-error


def resolve_config_path() -> str:
    env_path = os.environ.get("ROBOT_CFG_PATH") or os.environ.get("ROBOT_API_CFG")
    if env_path:
        return env_path
    return str(APP_DIR / "robot_api.cfg")

def main() -> None:
    cfg_path = resolve_config_path()
    os.environ.setdefault("ROBOT_CFG_PATH", cfg_path)
    os.environ.setdefault("ROBOT_API_CFG", cfg_path)

    cfg = load_config(cfg_path)
    host = os.environ.get("HOST") or os.environ.get("API_HOST") or cfg.server.api_host
    port_env = os.environ.get("PORT") or os.environ.get("API_PORT")
    try:
        port = int(port_env) if port_env is not None else int(cfg.server.api_port)
    except ValueError:
        port = int(cfg.server.api_port)

    if not os.environ.get("ROBOT_SERVO_DRIVER"):
        os.environ["ROBOT_SERVO_DRIVER"] = cfg.servo_driver

    uvicorn.run("app.main:app", host=host, port=port, reload=False)


if __name__ == "__main__":
    main()
