# app/servo/soft_pwm.py
import os
import time
import threading
from typing import Dict, Optional, Tuple, List

from app.utils import run_gpio_command

PULSE_UNIT_US = 10  # 1 unit = 10 microseconds

class SoftPinBase:
    def set_high(self): ...
    def set_low(self): ...
    def close(self): ...

class GpioCliPin(SoftPinBase):
    """Simple output pin controlled by 'gpio' CLI (WiringOP)."""
    def __init__(self, pin_logical: int, addressing: str = "physical"):
        self.pin = pin_logical
        self._prefix = "-1 " if addressing == "physical" else ""
        run_gpio_command(f"gpio {self._prefix}mode {self.pin} out")
        self._last = 0

    def set_high(self):
        if self._last != 1:
            run_gpio_command(f"gpio {self._prefix}write {self.pin} 1")
            self._last = 1

    def set_low(self):
        if self._last != 0:
            run_gpio_command(f"gpio {self._prefix}write {self.pin} 0")
            self._last = 0

    def close(self):
        try:
            self.set_low()
        except:
            pass

class GpiodPin(SoftPinBase):
    """
    libgpiod wrapper supporting both v1 and v2 Python APIs.
    - Prefer v1 (Chip/get_line + set_value) for stability.
    - If v1 not available, use v2 (request_lines + LineSettings + set_values).
    - In v2, use LineValue enums (ACTIVE/INACTIVE or HIGH/LOW).
    """
    def __init__(self, chip_name: str, line_offset: int):
        try:
            import gpiod  # type: ignore
        except ImportError as e:
            raise RuntimeError("python3-libgpiod/gpiod is missing. Install: sudo apt-get install python3-libgpiod gpiod") from e

        import os, sys
        self._gpiod = gpiod
        self._line_offset = line_offset
        self._mode = None
        self._last = 0

        chip_dev = chip_name if chip_name.startswith("/dev/") else f"/dev/{chip_name}"
        if not os.path.exists(chip_dev):
            raise RuntimeError(f"{chip_dev} not found. Run 'gpiodetect' and update [gpiod] in robot_api.cfg")

        v1_err = None

        # Try v1 first
        if hasattr(gpiod, "Chip"):
            try:
                chip = gpiod.Chip(chip_dev)
                line = chip.get_line(line_offset)
                try:
                    line.request(consumer="soft-servo", type=gpiod.LINE_REQ_DIR_OUT, default_val=0)
                except TypeError:
                    line.request(consumer="soft-servo", type=gpiod.LINE_REQ_DIR_OUT, default_vals=[0])
                self._chip = chip
                self._line = line
                self._mode = "v1"
                return
            except Exception as e:
                v1_err = e  # keep and try v2

        # Try v2
        if not (hasattr(gpiod, "request_lines") and hasattr(gpiod, "LineSettings")):
            raise RuntimeError(f"gpiod v1 and v2 APIs unavailable. v1 error: {v1_err}")

        # Direction enum lives in different places depending on build
        Direction = None
        if hasattr(gpiod, "line") and hasattr(gpiod.line, "Direction"):
            Direction = gpiod.line.Direction
        elif hasattr(gpiod, "LineDirection"):
            Direction = gpiod.LineDirection

        try:
            LineSettings = gpiod.LineSettings
            ls = LineSettings()
            # Set OUTPUT direction
            if hasattr(ls, "set_direction") and Direction is not None:
                ls.set_direction(Direction.OUTPUT)
            else:
                try:
                    ls.direction = Direction.OUTPUT if Direction is not None else 1
                except Exception:
                    pass

            self._req = gpiod.request_lines(chip_dev, consumer="soft-servo", config={line_offset: ls})
            # Init low if possible
            try:
                self._req.set_values({line_offset: 0})
            except Exception:
                pass

            # Precompute v2 LineValue tokens
            self._lv_hi = 1
            self._lv_lo = 0
            if hasattr(gpiod, "LineValue"):
                LV = gpiod.LineValue
                if hasattr(LV, "ACTIVE") and hasattr(LV, "INACTIVE"):
                    self._lv_hi, self._lv_lo = LV.ACTIVE, LV.INACTIVE
                elif hasattr(LV, "HIGH") and hasattr(LV, "LOW"):
                    self._lv_hi, self._lv_lo = LV.HIGH, LV.LOW

            self._mode = "v2"
            return
        except Exception as e:
            if v1_err:
                raise RuntimeError(f"gpiod v1 and v2 failed; v1: {v1_err}; v2: {e}")
            raise RuntimeError(f"gpiod v2 request failed for {chip_dev}:{line_offset}: {e}")

    def set_high(self):
        if self._last == 1:
            return
        try:
            if self._mode == "v2":
                self._req.set_values({self._line_offset: getattr(self, "_lv_hi", 1)})
            else:
                self._line.set_value(1)
            self._last = 1
        except Exception:
            # You can log here if needed
            pass

    def set_low(self):
        if self._last == 0:
            return
        try:
            if self._mode == "v2":
                self._req.set_values({self._line_offset: getattr(self, "_lv_lo", 0)})
            else:
                self._line.set_value(0)
            self._last = 0
        except Exception:
            pass

    def close(self):
        try:
            self.set_low()
        except:
            pass
        try:
            if self._mode == "v2":
                if hasattr(self, "_req") and hasattr(self._req, "release"):
                    self._req.release()
            elif self._mode == "v1":
                self._line.release()
                self._chip.close()
        except:
            pass

class SoftPWMManager:
    """Single thread generating 50 Hz PWM for multiple pins."""
    def __init__(self, period_us: int = 20000, backend: str = "gpiod",
                 addressing: str = "physical",
                 gpiod_map: Optional[Dict[int, Tuple[str, int]]] = None):
        self.period_us = period_us
        self.backend = backend
        self.addressing = addressing
        self.gpiod_map = gpiod_map or {}
        self._pins: Dict[int, SoftPinBase] = {}
        self._width_us: Dict[int, int] = {}
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def _make_pin(self, pin: int) -> SoftPinBase:
        if self.backend == "gpiod":
            if pin not in self.gpiod_map:
                raise RuntimeError(f"Missing gpiod mapping for pin {pin}")
            chip, line = self.gpiod_map[pin]
            return GpiodPin(chip, line)
        else:
            return GpioCliPin(pin, addressing=self.addressing)

    def register_pin(self, pin: int, initial_units: int):
        with self._lock:
            if pin not in self._pins:
                self._pins[pin] = self._make_pin(pin)
            self._width_us[pin] = max(0, initial_units) * PULSE_UNIT_US

    def set_units(self, pin: int, units: int):
        with self._lock:
            if pin not in self._pins:
                self._pins[pin] = self._make_pin(pin)
            self._width_us[pin] = max(0, units) * PULSE_UNIT_US

    def start(self):
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, name="soft-pwm", daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=1.0)
        with self._lock:
            pins = list(self._pins.values())
            self._pins.clear()
            self._width_us.clear()
        for p in pins:
            try:
                p.set_low()
                p.close()
            except:
                pass

    def _loop(self):
        while not self._stop.is_set():
            t0 = time.perf_counter()
            with self._lock:
                items = list(self._width_us.items())
                pins_map = dict(self._pins)
            # High for all active
            for pin, w in items:
                if w > 0:
                    try:
                        pins_map[pin].set_high()
                    except:
                        pass
            # Off events
            offs = sorted(w for _, w in items if w > 0)
            last_off_us = 0
            for off_us in offs:
                sleep_us = off_us - last_off_us
                if sleep_us > 0:
                    sleep_s = sleep_us / 1_000_000.0
                    if sleep_s > 0.00025:
                        time.sleep(sleep_s - 0.0002)
                    target = t0 + off_us / 1_000_000.0
                    while True:
                        now = time.perf_counter()
                        if now >= target or self._stop.is_set():
                            break
                for pin, w in items:
                    if w == off_us:
                        try:
                            pins_map[pin].set_low()
                        except:
                            pass
                last_off_us = off_us
            elapsed = time.perf_counter() - t0
            remain = self.period_us / 1_000_000.0 - elapsed
            if remain > 0:
                time.sleep(remain)

class SoftwarePWMBackend:
    """Backend adapter wrapping SoftPWMManager to the controller interface."""
    def __init__(self, period_us: int, backend: str, addressing: str,
                 gpiod_map: Dict[int, Tuple[str, int]]):
        self._mgr = SoftPWMManager(period_us=period_us, backend=backend,
                                   addressing=addressing, gpiod_map=gpiod_map)

    def setup(self, pins: List[int], centre_units: int):
        self._mgr.start()
        try:
            for p in pins:
                self._mgr.register_pin(p, centre_units)
        except Exception:
            # Ensure all lines are released on failure to avoid "busy"
            self._mgr.stop()
            raise

    def set_units(self, pin: int, units: int):
        self._mgr.set_units(pin, units)

    def cleanup(self):
        self._mgr.stop()
