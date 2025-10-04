import os
import sys
import configparser
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

DEFAULT_CFG = """[mode]
servo_driver = soft

[server]
api_host = 0.0.0.0
api_port = 8000
api_base_url = http://127.0.0.1:8000
ui_host = 0.0.0.0
ui_port = 3838

[camera]
ip = 192.168.15.9
capture_port = 80
stream_port = 81
connect_timeout = 5
stream_read_timeout = 60

[servo_move]
min_pulse = 50      ; 0.5 ms (each unit equals 10 microseconds)
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
channel1 = 0
channel2 = 1
channel3 = 2
channel4 = 3
stop_units1 =
stop_units2 =
stop_units3 =
stop_units4 =
gain_units1 =
gain_units2 =
gain_units3 =
gain_units4 =
chip1 = gpiochip3
line1 = 28
chip2 = gpiochip3
line2 = 31
chip3 = gpiochip3
line3 = 24
chip4 = gpiochip3
line4 = 27

[pca9685]
i2c_bus = 5
address = 0x40
frequency_hz = 50

[ui]
status_refresh_ms = 2000
key_repeat_ms = 120
default_step_pct = 0.15
claw_step_pct = 0.15
height_step_pct = 0.10
base_step_pct = 0.15
reach_step_pct = 0.20

[demo]
sequence = 1:45,1:0,1:-80,1:0,2:45,1:45,2:0,3:45,4:0,2:45,3:-45,3:45,4:90,4:0
smooth = true
"""

@dataclass
class ServerConfig:
    api_host: str
    api_port: int
    api_base_url: str
    ui_host: str
    ui_port: int

@dataclass
class UIConfig:
    status_refresh_ms: int
    key_repeat_ms: int
    default_step_pct: float
    part_step_pct: Dict[str, float]

@dataclass
class PCA9685Config:
    bus: int
    address: int
    freq_hz: int

@dataclass
class ServoDef:
    pin: int
    type: str
    range: Tuple[int, int]
    part: str
    gpiod_chip: str = ""
    gpiod_line: int = -1
    channel: Optional[int] = None
    stop_units: Optional[int] = None
    gain_units: Optional[float] = None

@dataclass
class AppConfig:
    servo_driver: str
    server: ServerConfig
    ui: UIConfig
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
    pca9685: Optional[PCA9685Config] = None

    @property
    def pulse_range(self) -> int:
        return self.max_pulse - self.min_pulse

    @property
    def api_base_url(self) -> str:
        return self.server.api_base_url

def _ensure_cfg(path: str) -> None:
    p = Path(path)
    if not p.exists():
        p.write_text(DEFAULT_CFG)
        print(f"[INFO] Created default config at {path}", file=sys.stderr)

def _parse_range(value: str, default: Tuple[int, int]) -> Tuple[int, int]:
    try:
        raw = value.replace(" ", "")
        a, b = raw.split(":")
        mn = int(float(a))
        mx = int(float(b))
        if mn > mx:
            mn, mx = mx, mn
        return mn, mx
    except Exception:
        return default

def _parse_optional_int(value: str) -> Optional[int]:
    value = value.strip()
    if not value:
        return None
    try:
        if value.lower().startswith("0x"):
            return int(value, 16)
        return int(float(value))
    except Exception:
        return None

def _parse_optional_float(value: str) -> Optional[float]:
    value = value.strip()
    if not value:
        return None
    try:
        return float(value)
    except Exception:
        return None

def _expand_defaults(defaults: List, count: int):
    if not defaults:
        return [None] * count
    if len(defaults) >= count:
        return defaults[:count]
    last = defaults[-1]
    return defaults + [last] * (count - len(defaults))

def load_config(path: Optional[str] = None) -> AppConfig:
    cfg_path = (
        path
        or os.environ.get("ROBOT_CFG_PATH")
        or os.environ.get("ROBOT_API_CFG")
        or "robot_api.cfg"
    )

    _ensure_cfg(cfg_path)

    cfg = configparser.ConfigParser(inline_comment_prefixes=(";", "#"), strict=False)
    cfg.read(cfg_path)

    servo_driver = cfg.get("mode", "servo_driver", fallback="soft").strip().lower()
    override_driver = os.environ.get("ROBOT_SERVO_DRIVER")
    if override_driver:
        servo_driver = override_driver.strip().lower()

    server = ServerConfig(
        api_host=cfg.get("server", "api_host", fallback="0.0.0.0").strip(),
        api_port=cfg.getint("server", "api_port", fallback=8000),
        api_base_url=cfg.get("server", "api_base_url", fallback="").strip(),
        ui_host=cfg.get("server", "ui_host", fallback="0.0.0.0").strip(),
        ui_port=cfg.getint("server", "ui_port", fallback=3838),
    )
    if not server.api_base_url:
        api_host = "127.0.0.1" if server.api_host in {"0.0.0.0", "::"} else server.api_host
        server.api_base_url = f"http://{api_host}:{server.api_port}"

    ui_default_step = cfg.getfloat("ui", "default_step_pct", fallback=0.15)
    part_step_pct: Dict[str, float] = {}
    for part in ("claw", "height", "base", "reach"):
        part_step_pct[part] = cfg.getfloat("ui", f"{part}_step_pct", fallback=ui_default_step)

    ui = UIConfig(
        status_refresh_ms=cfg.getint("ui", "status_refresh_ms", fallback=2000),
        key_repeat_ms=cfg.getint("ui", "key_repeat_ms", fallback=120),
        default_step_pct=ui_default_step,
        part_step_pct=part_step_pct,
    )

    camera_ip = cfg.get("camera", "ip", fallback="192.168.15.9").strip()
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

    servo_count = cfg.getint("servos", "count", fallback=4)
    if servo_count <= 0:
        raise ValueError("[servos] count must be >= 1")

    default_pins = [31, 33, 35, 37]
    default_parts = ["claw", "reach", "base", "height"]
    pins: List[int] = []
    types: List[str] = []
    ranges: List[Tuple[int, int]] = []
    parts: List[str] = []
    channels: List[Optional[int]] = []
    stop_units: List[Optional[int]] = []
    gain_units: List[Optional[float]] = []
    chips: List[str] = []
    lines: List[int] = []

    for idx in range(1, servo_count + 1):
        fallback_pin = default_pins[idx - 1] if idx - 1 < len(default_pins) else default_pins[-1]
        pin = cfg.getint("servos", f"pin{idx}", fallback=fallback_pin)
        pins.append(pin)

        type_val = cfg.get("servos", f"type{idx}", fallback="pos").strip().lower() or "pos"
        types.append(type_val)

        range_val = cfg.get("servos", f"range{idx}", fallback=f"{ang_min}:{ang_max}")
        ranges.append(_parse_range(range_val, (ang_min, ang_max)))

        part_val = cfg.get("servos", f"part{idx}", fallback=default_parts[idx - 1] if idx - 1 < len(default_parts) else f"servo{idx}").strip()
        parts.append(part_val or f"servo{idx}")

        channel_raw = cfg.get("servos", f"channel{idx}", fallback=str(idx - 1)).strip()
        channels.append(_parse_optional_int(channel_raw))

        stop_raw = cfg.get("servos", f"stop_units{idx}", fallback="").strip()
        stop_units.append(_parse_optional_int(stop_raw))

        gain_raw = cfg.get("servos", f"gain_units{idx}", fallback="").strip()
        gain_units.append(_parse_optional_float(gain_raw))

        chip_val = cfg.get("servos", f"chip{idx}", fallback="gpiochip3").strip()
        chips.append(chip_val)
        line_val = cfg.get("servos", f"line{idx}", fallback="0").strip()
        try:
            lines.append(int(line_val))
        except ValueError:
            lines.append(0)

    servos: List[ServoDef] = []
    for i in range(servo_count):
        servos.append(
            ServoDef(
                pin=pins[i],
                type=types[i],
                range=ranges[i],
                part=parts[i],
                gpiod_chip=chips[i],
                gpiod_line=lines[i],
                channel=channels[i],
                stop_units=stop_units[i],
                gain_units=gain_units[i],
            )
        )

    demo_raw = cfg.get("demo", "sequence", fallback="1:45,1:0,2:45,2:0,3:45,3:0,4:45,4:0")
    demo_smooth = cfg.getboolean("demo", "smooth", fallback=True)
    demo_sequence: List[Tuple[int, int]] = []
    for token in demo_raw.replace(" ", "").split(","):
        if not token:
            continue
        try:
            idx_s, val_s = token.split(":")
            idx = int(idx_s)
            val = int(val_s)
            if 1 <= idx <= servo_count:
                demo_sequence.append((idx, val))
        except Exception:
            continue

    pca_cfg: Optional[PCA9685Config] = None
    if servo_driver == "pca9685":
        bus = cfg.getint("pca9685", "i2c_bus", fallback=5)
        addr_raw = cfg.get("pca9685", "address", fallback="0x40").strip()
        try:
            address = int(addr_raw, 0)
        except ValueError:
            address = 0x40
        freq_hz = cfg.getint("pca9685", "frequency_hz", fallback=50)
        pca_cfg = PCA9685Config(bus=bus, address=address, freq_hz=freq_hz)

    return AppConfig(
        servo_driver=servo_driver,
        server=server,
        ui=ui,
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
        demo_sequence=demo_sequence,
        demo_smooth=demo_smooth,
        pca9685=pca_cfg,
    )
