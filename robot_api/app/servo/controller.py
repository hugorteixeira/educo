import time
from typing import Dict, List, Tuple

from app.config import AppConfig, ServoDef


class ServoController:
    def __init__(self, cfg: AppConfig, backend):
        self.cfg = cfg
        self.backend = backend
        self.current_state: Dict[int, int] = {}
        self.initialized = False
        self.index_to_pin = {idx + 1: servo.pin for idx, servo in enumerate(cfg.servos)}
        self.pin_to_def = {servo.pin: servo for servo in cfg.servos}

    def reconfigure(self, cfg: AppConfig, backend=None) -> None:
        self.cfg = cfg
        if backend is not None:
            self.backend = backend
        self.index_to_pin = {idx + 1: servo.pin for idx, servo in enumerate(cfg.servos)}
        self.pin_to_def = {servo.pin: servo for servo in cfg.servos}
        self.current_state.clear()
        self.initialized = False

    def ensure_initialized(self) -> None:
        if self.initialized:
            return
        centre_units = self.cfg.min_pulse + self.cfg.pulse_range // 2
        pins = [servo.pin for servo in self.cfg.servos]
        self.backend.setup(pins, centre_units)
        for servo in self.cfg.servos:
            if servo.type == "pos" or servo.stop_units is None:
                initial_units = centre_units
            else:
                initial_units = int(servo.stop_units)
            self.backend.set_units(servo.pin, initial_units)
            self.current_state[servo.pin] = initial_units
        time.sleep(0.02)
        self.initialized = True

    def _parse_range(self, pin: int) -> Tuple[int, int]:
        return self.pin_to_def[pin].range

    def _clamp_angle(self, pin: int, angle: int) -> Tuple[int, bool]:
        mn, mx = self._parse_range(pin)
        clamped = int(max(mn, min(mx, int(angle))))
        return clamped, clamped != int(angle)

    def angle_to_pulse(self, angle: int) -> int:
        raw = self.cfg.min_pulse + self.cfg.pulse_range * (angle + self.cfg.angle_offset) / 180.0
        return int(max(self.cfg.min_pulse, min(self.cfg.max_pulse, raw)))

    def move_servo_direct(self, pin: int, angle: int) -> None:
        servo_def = self.pin_to_def[pin]
        if servo_def.type != "pos":
            raise ValueError("Direct move is only supported for positional servos")
        angle, _ = self._clamp_angle(pin, angle)
        units = self.angle_to_pulse(angle)
        self.backend.set_units(pin, units)
        self.current_state[pin] = units

    def move_servo_smooth(self, pin: int, angle: int) -> None:
        servo_def = self.pin_to_def[pin]
        if servo_def.type != "pos":
            raise ValueError("Smooth move is only supported for positional servos")
        angle, _ = self._clamp_angle(pin, angle)
        target_units = self.angle_to_pulse(angle)
        current_units = int(self.current_state.get(pin, self.angle_to_pulse(0)))
        diff = target_units - current_units
        steps = max(1, self.cfg.smooth_steps)
        step = diff / steps
        value = current_units
        for _ in range(steps):
            value += step
            self.backend.set_units(pin, int(round(value)))
            time.sleep(self.cfg.step_delay)
        self.backend.set_units(pin, target_units)
        self.current_state[pin] = target_units

    def center_all(self) -> None:
        for servo in self.cfg.servos:
            if servo.type == "pos":
                self.move_servo_smooth(servo.pin, 0)
            elif servo.stop_units is not None:
                units = int(servo.stop_units)
                self.backend.set_units(servo.pin, units)
                self.current_state[servo.pin] = units

    def status(self) -> List[Dict]:
        report: List[Dict] = []
        for idx, servo in enumerate(self.cfg.servos, start=1):
            pulse = self.current_state.get(servo.pin)
            if pulse is not None:
                value = int(round((int(pulse) - self.cfg.min_pulse) * 180 / self.cfg.pulse_range) - self.cfg.angle_offset)
            else:
                value = None
            entry = {
                "idx": idx,
                "pin": servo.pin,
                "type": servo.type,
                "part": servo.part,
                "range": f"{servo.range[0]}:{servo.range[1]}",
                "value": value,
            }
            if servo.channel is not None:
                entry["channel"] = servo.channel
            if servo.stop_units is not None:
                entry["stop_units"] = servo.stop_units
            report.append(entry)
        return report
