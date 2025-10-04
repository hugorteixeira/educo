import math
import time
from typing import Dict, List, Optional

from app.config import PCA9685Config, ServoDef

PULSE_UNIT_US = 10  # servo controller uses 10 µs units


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
        self._SMBus = SMBus
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
        # Reset device
        self._write8(self.MODE1, 0x00)
        time.sleep(0.01)
        self._write8(self.MODE2, 0x04)  # OUTDRV
        # Enable auto-increment (AI bit)
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


class PCA9685Backend:
    def __init__(self, cfg: PCA9685Config, servos: List[ServoDef]):
        self._cfg = cfg
        self._servo_map: Dict[int, ServoDef] = {servo.pin: servo for servo in servos}
        self._device: Optional[PCA9685Device] = None
        self._channels: Dict[int, int] = {}

    def setup(self, pins: List[int], centre_units: int) -> None:
        self._device = PCA9685Device(self._cfg.bus, self._cfg.address, self._cfg.freq_hz)
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
            self._device.set_pwm_us(channel, centre_us)

    def set_units(self, pin: int, units: int) -> None:
        if self._device is None:
            raise RuntimeError("PCA9685 backend has not been initialised. Call setup() first.")
        channel = self._channels.get(pin)
        if channel is None:
            raise RuntimeError(f"Pin {pin} has no PCA9685 channel mapping")
        pulse_us = max(0, int(units)) * PULSE_UNIT_US
        self._device.set_pwm_us(channel, pulse_us)

    def cleanup(self) -> None:
        if self._device is not None:
            self._device.close()
            self._device = None

    def __del__(self) -> None:
        try:
            self.cleanup()
        except Exception:
            pass
