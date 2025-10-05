import json
import os
import threading
import time
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

from app.camera import capture_frame, save_jpeg
from app.config import AppConfig


class LogManager:
    def __init__(self, base_dir: str, image_dir: str):
        self.base_path = Path(base_dir)
        self.image_path = Path(image_dir)
        self.frame_path = self.image_path / "logs"
        self.base_path.mkdir(parents=True, exist_ok=True)
        self.frame_path.mkdir(parents=True, exist_ok=True)
        self.log_file = self.base_path / "move_logs.jsonl"
        self.enabled: bool = False
        self._lock = threading.Lock()
        self.entry_count = self._initial_count()

    def _initial_count(self) -> int:
        if not self.log_file.exists():
            return 0
        try:
            with self.log_file.open("r", encoding="utf-8") as handle:
                return sum(1 for _ in handle)
        except OSError:
            return 0

    def state(self) -> Dict[str, Any]:
        return {"enabled": self.enabled, "log_count": self.entry_count}

    def set_enabled(self, enabled: bool) -> Dict[str, Any]:
        with self._lock:
            self.enabled = enabled
        return self.state()

    def capture_snapshot(self, cfg: AppConfig, prefix: str) -> Optional[str]:
        frame = capture_frame(cfg.camera_ip, cfg.camera_capture_port, cfg.camera_connect_timeout)
        if frame is None:
            return None
        tag = f"{prefix}_{int(time.time() * 1000)}_{uuid.uuid4().hex[:8]}"
        try:
            fname, _ = save_jpeg(frame, str(self.frame_path), max_width=640, jpeg_quality=35)
            return f"/frames/logs/{fname}"
        except Exception:
            return None

    def write_entry(
        self,
        cfg: AppConfig,
        pin: int,
        target_value: int,
        smooth: bool,
        status_before: List[Dict[str, Any]],
        status_after: List[Dict[str, Any]],
        pre_image: Optional[str],
        post_image: Optional[str],
    ) -> None:
        part = next((servo.part for servo in cfg.servos if servo.pin == pin), None)
        entry = {
            "id": uuid.uuid4().hex,
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "pin": pin,
            "part": part,
            "target_value": target_value,
            "smooth": smooth,
            "status_before": status_before,
            "status_after": status_after,
            "camera": {
                "pre_image": pre_image,
                "post_image": post_image,
            },
        }
        data = json.dumps(entry, ensure_ascii=False)
        with self._lock:
            with self.log_file.open("a", encoding="utf-8") as handle:
                handle.write(data + "\n")
            self.entry_count += 1

    def list_entries(self, limit: int = 50) -> List[Dict[str, Any]]:
        if not self.log_file.exists() or limit <= 0:
            return []
        entries: List[Dict[str, Any]] = []
        with self._lock:
            try:
                with self.log_file.open("r", encoding="utf-8") as handle:
                    lines = handle.readlines()
            except OSError:
                return []
        for line in reversed(lines[-limit:]):
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        return entries

    def iter_all_entries(self) -> List[Dict[str, Any]]:
        if not self.log_file.exists():
            return []
        with self._lock:
            try:
                with self.log_file.open("r", encoding="utf-8") as handle:
                    lines = handle.readlines()
            except OSError:
                return []
        entries: List[Dict[str, Any]] = []
        for line in lines:
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        return entries
