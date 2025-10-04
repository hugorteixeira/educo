import os
import uuid
import time
from typing import Optional, Tuple

import requests
import numpy as np
import cv2

def capture_frame(ip: str, port: int, connect_timeout: int) -> Optional[np.ndarray]:
    try:
        url = f"http://{ip}:{port}/capture"
        resp = requests.get(url, timeout=connect_timeout)
        if resp.status_code != 200:
            return None
        nparr = np.frombuffer(resp.content, np.uint8)
        frame = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
        return frame
    except Exception:
        return None

def save_jpeg(frame, dest_dir: str, max_width: int, jpeg_quality: int) -> Tuple[str, bytes]:
    h, w = frame.shape[:2]
    if w > max_width:
        frame = cv2.resize(frame, (max_width, int(h * max_width / w)), interpolation=cv2.INTER_AREA)
    ok, buf = cv2.imencode(".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), jpeg_quality])
    if not ok:
        raise RuntimeError("JPEG encode failed")
    fname = f"{uuid.uuid4().hex}.jpg"
    os.makedirs(dest_dir, exist_ok=True)
    with open(os.path.join(dest_dir, fname), "wb") as f:
        f.write(buf.tobytes())
    return fname, buf.tobytes()
