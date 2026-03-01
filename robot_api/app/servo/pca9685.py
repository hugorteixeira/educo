import math
import time
from typing import Dict, List, Optional
from urllib.parse import urlencode

import requests

from app.config import PCA9685Config, ServoDef

PULSE_UNIT_US = 10  # servo controller uses 10 us units


class PCA9685Device:
    MODE1 = 0x00
    MODE2 = 0x01
    PRESCALE = 0xFE
    LED0_ON_L = 0x06

    def __init__(self, bus: int, address: int, freq_hz: int):
        try:
            from smbus2 import SMBus  # type: ignore
        except ImportError as exc:
            raise RuntimeError(
                "Missing dependency smbus2. Install it with 'pip install smbus2'"
            ) from exc
        self._bus = SMBus(bus)
        self._address = address
        self._freq_hz: Optional[int] = None
        self._initialise(freq_hz)

    def close(self) -> None:
        try:
            self._bus.close()
        except Exception:
            pass

    def _write8(self, register: int, value: int) -> None:
        self._bus.write_byte_data(self._address, register, value & 0xFF)

    def _read8(self, register: int) -> int:
        return self._bus.read_byte_data(self._address, register)

    def _initialise(self, freq_hz: int) -> None:
        self._write8(self.MODE1, 0x00)
        time.sleep(0.01)
        self._write8(self.MODE2, 0x04)  # OUTDRV
        old_mode = self._read8(self.MODE1)
        self._write8(self.MODE1, old_mode | 0x20)
        self.set_pwm_freq(freq_hz)

    def set_pwm_freq(self, freq_hz: int) -> None:
        freq_hz = int(freq_hz)
        if freq_hz < 24 or freq_hz > 1526:
            raise ValueError("PCA9685 frequency must be between 24 Hz and 1526 Hz")
        prescale_val = 25_000_000.0 / (4096.0 * freq_hz) - 1.0
        prescale = int(math.floor(prescale_val + 0.5))
        old_mode = self._read8(self.MODE1)
        self._write8(self.MODE1, (old_mode & 0x7F) | 0x10)  # sleep
        self._write8(self.PRESCALE, prescale)
        self._write8(self.MODE1, old_mode)
        time.sleep(0.005)
        self._write8(self.MODE1, old_mode | 0xA1)  # restart + auto-increment
        self._freq_hz = freq_hz

    def set_pwm(self, channel: int, on: int, off: int) -> None:
        if not (0 <= channel <= 15):
            raise ValueError("PCA9685 channel must be between 0 and 15")
        base = self.LED0_ON_L + 4 * channel
        on &= 0x0FFF
        off &= 0x0FFF
        self._bus.write_i2c_block_data(
            self._address,
            base,
            [on & 0xFF, (on >> 8) & 0xFF, off & 0xFF, (off >> 8) & 0xFF],
        )

    def set_pwm_us(self, channel: int, pulse_us: int) -> None:
        if self._freq_hz is None:
            raise RuntimeError("PCA9685 frequency not configured")
        ticks = int(round(pulse_us * 4096.0 * self._freq_hz / 1_000_000.0))
        ticks = max(0, min(4095, ticks))
        self.set_pwm(channel, 0, ticks)


class PCA9685ESP32BridgeDevice:
    def __init__(
        self,
        base_url: str,
        address: int,
        timeout_s: float,
        reinit: bool,
        sda: Optional[int],
        scl: Optional[int],
    ):
        self._base_url = base_url.rstrip("/")
        self._address = int(address)
        self._timeout_s = float(timeout_s)
        self._sda = sda
        self._scl = scl

        if not self._base_url:
            raise RuntimeError("PCA9685 bridge mode requires [pca9685] bridge_base_url")

        if reinit:
            self.reinit()
        else:
            self.health_check()

    def close(self) -> None:
        return None

    def _build_url(self, path: str, params: Optional[Dict[str, str]] = None) -> str:
        if not params:
            return f"{self._base_url}{path}"
        return f"{self._base_url}{path}?{urlencode(params)}"

    def _get_json(self, path: str, params: Optional[Dict[str, str]] = None) -> Dict:
        url = self._build_url(path, params)
        try:
            resp = requests.get(url, timeout=self._timeout_s)
            resp.raise_for_status()
        except requests.RequestException as exc:
            raise RuntimeError(f"ESP32 bridge request failed: {url} ({exc})") from exc

        try:
            data = resp.json()
        except Exception as exc:
            raise RuntimeError(f"ESP32 bridge returned non-JSON response for {url}") from exc

        if not isinstance(data, dict):
            raise RuntimeError(f"ESP32 bridge returned invalid payload for {url}: {data!r}")
        return data

    def health_check(self) -> None:
        data = self._get_json("/health")
        if not data.get("ok"):
            raise RuntimeError(f"ESP32 bridge health failed: {data}")
        if not data.get("pca_ready"):
            raise RuntimeError(f"ESP32 bridge reports PCA not ready: {data}")

    def reinit(self) -> None:
        params: Dict[str, str] = {"addr": hex(self._address)}
        if self._sda is not None and self._scl is not None:
            params["sda"] = str(self._sda)
            params["scl"] = str(self._scl)

        data = self._get_json("/api/pca/reinit", params)
        if not data.get("ok") or not data.get("pca_ready"):
            raise RuntimeError(f"ESP32 bridge reinit failed: {data}")

    def set_pwm_us(self, channel: int, pulse_us: int) -> None:
        if not (0 <= channel <= 15):
            raise ValueError("PCA9685 channel must be between 0 and 15")
        params = {"channel": str(int(channel)), "us": str(int(pulse_us))}
        data = self._get_json("/api/pca/move", params)
        if not data.get("ok"):
            raise RuntimeError(f"ESP32 bridge move failed: {data}")


class PCA9685Backend:
    def __init__(self, cfg: PCA9685Config, servos: List[ServoDef]):
        self._cfg = cfg
        self._servo_map: Dict[int, ServoDef] = {servo.pin: servo for servo in servos}
        self._device: Optional[object] = None
        self._channels: Dict[int, int] = {}

    def _build_device(self) -> object:
        mode = (self._cfg.mode or "local").strip().lower()
        if mode == "esp32":
            return PCA9685ESP32BridgeDevice(
                base_url=self._cfg.bridge_base_url,
                address=self._cfg.address,
                timeout_s=self._cfg.bridge_timeout_s,
                reinit=self._cfg.bridge_reinit,
                sda=self._cfg.bridge_sda,
                scl=self._cfg.bridge_scl,
            )
        return PCA9685Device(self._cfg.bus, self._cfg.address, self._cfg.freq_hz)

    def setup(self, pins: List[int], centre_units: int) -> None:
        self._device = self._build_device()

        for pin in pins:
            servo = self._servo_map.get(pin)
            if servo is None:
                raise RuntimeError(f"Servo definition missing for pin {pin}")
            if servo.channel is None:
                raise RuntimeError(
                    f"Servo pin {pin} does not define a PCA9685 channel. Set channelN entries in the [servos] section."
                )
            self._channels[pin] = int(servo.channel)

        centre_us = max(0, int(centre_units)) * PULSE_UNIT_US
        for pin in pins:
            channel = self._channels[pin]
            self._device.set_pwm_us(channel, centre_us)  # type: ignore[attr-defined]

    def set_units(self, pin: int, units: int) -> None:
        if self._device is None:
            raise RuntimeError("PCA9685 backend has not been initialised. Call setup() first.")
        channel = self._channels.get(pin)
        if channel is None:
            raise RuntimeError(f"Pin {pin} has no PCA9685 channel mapping")
        pulse_us = max(0, int(units)) * PULSE_UNIT_US
        self._device.set_pwm_us(channel, pulse_us)  # type: ignore[attr-defined]

    def cleanup(self) -> None:
        if self._device is not None:
            try:
                self._device.close()  # type: ignore[attr-defined]
            except Exception:
                pass
            self._device = None

    def __del__(self) -> None:
        try:
            self.cleanup()
        except Exception:
            pass
