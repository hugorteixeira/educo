import os
import sys
import configparser
from dataclasses import dataclass
from pathlib import Path
from typing import List, Tuple

DEFAULT_CFG = """[mode]
servo_driver = soft

[camera]
ip = 192.168.15.9
capture_port = 80
stream_port = 81
connect_timeout = 5
stream_read_timeout = 60

[servo_move]
min_pulse = 50      ; 0.5 ms
max_pulse = 250     ; 2.5 ms
angle_min = -270
angle_max = 270
angle_offset = 90
smooth_steps = 20
step_delay = 0.02

[hw]
pwm_freq = 192
pwm_range = 2000

[soft]
backend = gpiod
addressing = physical
period_us = 20000

[servos]
count = 4
pin1 = 31
pin2 = 33
pin3 = 35
pin4 = 37
type1 = pos
type2 = pos
type3 = pos
type4 = pos
range1 = -80:45
range2 = -10:110
range3 = -100:120
range4 = 0:100
part1 = claw
part2 = reach
part3 = base
part4 = height

[gpiod]
chip1 = gpiochip3
line1 = 28
chip2 = gpiochip3
line2 = 31
chip3 = gpiochip3
line3 = 24
chip4 = gpiochip3
line4 = 27

[demo]
sequence = 1:45,1:0,1:-80,1:0,2:45,1:45,2:0,3:45,4:0,2:45,3:-45,3:45,4:90,4:0
smooth = true
"""

@dataclass
class ServoDef:
    pin: int
    type: str
    range: Tuple[int, int]
    part: str
    gpiod_chip: str = ""
    gpiod_line: int = -1

@dataclass
class AppConfig:
    servo_driver: str
    camera_ip: str
    camera_capture_port: int
    camera_stream_port: int
    camera_connect_timeout: int
    camera_stream_read_timeout: int
    min_pulse: int
    max_pulse: int
    angle_min: int
    angle_max: int
    angle_offset: int
    smooth_steps: int
    step_delay: float
    pwm_freq: int
    pwm_range: int
    soft_backend: str
    soft_addressing: str
    period_us: int
    servos: List[ServoDef]
    demo_sequence: List[Tuple[int, int]]
    demo_smooth: bool

    @property
    def pulse_range(self) -> int:
        return self.max_pulse - self.min_pulse

def _ensure_cfg(path: str) -> None:
    p = Path(path)
    if not p.exists():
        p.write_text(DEFAULT_CFG)
        print(f"[INFO] Created default config at {path}", file=sys.stderr)

def _parse_range(s: str, default: Tuple[int, int]) -> Tuple[int, int]:
    try:
        a, b = s.replace(" ", "").split(":")
        mn = int(float(a)); mx = int(float(b))
        if mn > mx: mn, mx = mx, mn
        return mn, mx
    except Exception:
        return default

def _get4(cfg: configparser.ConfigParser, section: str, prefix: str, fallback: List[str]) -> List[str]:
    out = []
    for i in range(1, 5):
        out.append(cfg.get(section, f"{prefix}{i}", fallback=fallback[i-1]))
    return out

def load_config(path: str | None = None) -> AppConfig:
    cfg_path = path or os.environ.get("ROBOT_API_CFG", "robot_api.cfg")
    _ensure_cfg(cfg_path)
    cfg = configparser.ConfigParser(
        inline_comment_prefixes=(";", "#"),
        strict=False,
    )
    cfg.read(cfg_path)

    servo_driver = cfg.get("mode", "servo_driver", fallback="soft").strip().lower()
    if servo_driver not in ("soft", "hw"):
        servo_driver = "soft"

    camera_ip = cfg.get("camera", "ip", fallback="192.168.15.9")
    cam_cap = cfg.getint("camera", "capture_port", fallback=80)
    cam_stream = cfg.getint("camera", "stream_port", fallback=81)
    cam_cto = cfg.getint("camera", "connect_timeout", fallback=5)
    cam_rto = cfg.getint("camera", "stream_read_timeout", fallback=60)

    min_p = cfg.getint("servo_move", "min_pulse", fallback=50)
    max_p = cfg.getint("servo_move", "max_pulse", fallback=250)
    ang_min = cfg.getint("servo_move", "angle_min", fallback=-270)
    ang_max = cfg.getint("servo_move", "angle_max", fallback=270)
    ang_off = cfg.getint("servo_move", "angle_offset", fallback=90)
    sm_steps = cfg.getint("servo_move", "smooth_steps", fallback=20)
    st_delay = cfg.getfloat("servo_move", "step_delay", fallback=0.02)

    pwm_freq = cfg.getint("hw", "pwm_freq", fallback=192)
    pwm_range = cfg.getint("hw", "pwm_range", fallback=2000)

    backend = cfg.get("soft", "backend", fallback="gpiod").strip().lower()
    addressing = cfg.get("soft", "addressing", fallback="physical").strip().lower()
    period_us = cfg.getint("soft", "period_us", fallback=20000)

    pins = [cfg.getint("servos", f"pin{i}", fallback=[31, 33, 35, 37][i-1]) for i in range(1, 5)]
    types = _get4(cfg, "servos", "type", ["pos", "pos", "pos", "pos"])
    ranges_s = _get4(cfg, "servos", "range", ["-80:45", "-10:110", "-100:120", "0:100"])
    parts = _get4(cfg, "servos", "part", ["claw", "reach", "base", "height"])
    ranges = [_parse_range(r, (ang_min, ang_max)) for r in ranges_s]

    chips = _get4(cfg, "gpiod", "chip", ["gpiochip3"] * 4)
    lines = [cfg.getint("gpiod", f"line{i}", fallback=[28, 31, 24, 27][i-1]) for i in range(1, 5)]

    servos: List[ServoDef] = []
    for i in range(4):
        servos.append(ServoDef(
            pin=pins[i],
            type=types[i].strip().lower(),
            range=ranges[i],
            part=parts[i],
            gpiod_chip=chips[i],
            gpiod_line=lines[i]
        ))

    demo_raw = cfg.get("demo", "sequence", fallback="1:45,1:0,2:45,2:0,3:45,3:0,4:45,4:0")
    demo_smooth = cfg.getboolean("demo", "smooth", fallback=True)
    seq: List[Tuple[int, int]] = []
    for token in demo_raw.replace(" ", "").split(","):
        if not token: continue
        try:
            idx_s, val_s = token.split(":")
            idx = int(idx_s); val = int(val_s)
            if 1 <= idx <= 4:
                seq.append((idx, val))
        except Exception:
            continue

    return AppConfig(
        servo_driver=servo_driver,
        camera_ip=camera_ip,
        camera_capture_port=cam_cap,
        camera_stream_port=cam_stream,
        camera_connect_timeout=cam_cto,
        camera_stream_read_timeout=cam_rto,
        min_pulse=min_p,
        max_pulse=max_p,
        angle_min=ang_min,
        angle_max=ang_max,
        angle_offset=ang_off,
        smooth_steps=sm_steps,
        step_delay=st_delay,
        pwm_freq=pwm_freq,
        pwm_range=pwm_range,
        soft_backend=backend,
        soft_addressing=addressing,
        period_us=period_us,
        servos=servos,
        demo_sequence=seq,
        demo_smooth=demo_smooth
    )
