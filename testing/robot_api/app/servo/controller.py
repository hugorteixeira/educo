import time
from typing import Dict, Tuple, List

from app.config import AppConfig, ServoDef

class ServoController:
    def __init__(self, cfg: AppConfig, backend):
        self.cfg = cfg
        self.backend = backend
        self.current_state: Dict[int, int] = {}  # pin -> pulse units
        self.initialized = False
        # Build helper maps
        self.index_to_pin = {i + 1: cfg.servos[i].pin for i in range(4)}
        self.pin_to_def = {s.pin: s for s in cfg.servos}

    def ensure_initialized(self):
        if self.initialized:
            return
        centre_units = self.cfg.min_pulse + (self.cfg.max_pulse - self.cfg.min_pulse) // 2
        pins = [s.pin for s in self.cfg.servos]
        self.backend.setup(pins, centre_units)
        for p in pins:
            self.current_state[p] = centre_units
        time.sleep(0.02)
        self.initialized = True

    def _parse_range(self, pin: int) -> Tuple[int, int]:
        sdef: ServoDef = self.pin_to_def[pin]
        return sdef.range

    def _clamp_angle(self, pin: int, angle: int) -> Tuple[int, bool]:
        mn, mx = self._parse_range(pin)
        clamped = int(max(mn, min(mx, int(angle))))
        return clamped, (clamped != int(angle))

    def angle_to_pulse(self, angle: int) -> int:
        # Map -90..+90 to min..max using offset
        raw = self.cfg.min_pulse + self.cfg.pulse_range * (angle + self.cfg.angle_offset) / 180.0
        return int(max(self.cfg.min_pulse, min(self.cfg.max_pulse, raw)))

    def move_servo_direct(self, pin: int, angle: int):
        sdef = self.pin_to_def[pin]
        if sdef.type != "pos":
            raise ValueError("Direct move is only for positional servos")
        angle, _ = self._clamp_angle(pin, angle)
        units = self.angle_to_pulse(angle)
        self.backend.set_units(pin, units)
        self.current_state[pin] = units

    def move_servo_smooth(self, pin: int, angle: int):
        sdef = self.pin_to_def[pin]
        if sdef.type != "pos":
            raise ValueError("Smooth move is only for positional servos")
        angle, _ = self._clamp_angle(pin, angle)
        target_units = self.angle_to_pulse(angle)
        current_units = int(self.current_state.get(pin, self.angle_to_pulse(0)))
        diff = target_units - current_units
        steps = max(1, self.cfg.smooth_steps)
        step = diff / steps
        val = current_units
        for _ in range(steps):
            val += step
            self.backend.set_units(pin, int(round(val)))
            time.sleep(self.cfg.step_delay)
        self.backend.set_units(pin, target_units)
        self.current_state[pin] = target_units

    def center_all(self):
        for s in self.cfg.servos:
            self.move_servo_smooth(s.pin, 0)

    def status(self) -> List[Dict]:
        lst = []
        for i, s in enumerate(self.cfg.servos, start=1):
            pulse = self.current_state.get(s.pin)
            if pulse is not None:
                value = int(round((int(pulse) - self.cfg.min_pulse) * 180 / self.cfg.pulse_range) - self.cfg.angle_offset)
            else:
                value = None
            lst.append({
                "idx": i,
                "pin": s.pin,
                "type": s.type,
                "part": s.part,
                "range": f"{s.range[0]}:{s.range[1]}",
                "value": value
            })
        return lst
