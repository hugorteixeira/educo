#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Small PCA9685 channel probe: nudges each channel so you can see which servo moves.

import os, time, math
from smbus2 import SMBus

class PCA9685:
    MODE1     = 0x00
    MODE2     = 0x01
    PRESCALE  = 0xFE
    LED0_ON_L = 0x06

    def __init__(self, bus=1, address=0x40, freq_hz=50):
        self.bus = SMBus(bus)
        self.address = address
        self.freq_hz = None
        self._write8(self.MODE1, 0x00)         # reset
        time.sleep(0.01)
        self._write8(self.MODE2, 0x04)         # OUTDRV
        # Enable auto-increment
        oldmode = self._read8(self.MODE1)
        self._write8(self.MODE1, oldmode | 0x20)
        self.set_pwm_freq(freq_hz)

    def close(self):
        try: self.bus.close()
        except: pass

    def _write8(self, reg, val):
        self.bus.write_byte_data(self.address, reg, val & 0xFF)

    def _read8(self, reg):
        return self.bus.read_byte_data(self.address, reg)

    def set_pwm_freq(self, freq_hz):
        """Set output frequency (Hz). 50–60 Hz typical for servos."""
        freq_hz = int(freq_hz)
        prescaleval = 25_000_000.0 / (4096.0 * freq_hz) - 1.0
        prescale = int(math.floor(prescaleval + 0.5))
        oldmode = self._read8(self.MODE1)
        self._write8(self.MODE1, (oldmode & 0x7F) | 0x10)  # sleep
        self._write8(self.PRESCALE, prescale)
        self._write8(self.MODE1, oldmode)                  # wake
        time.sleep(0.005)
        self._write8(self.MODE1, oldmode | 0xA1)           # restart + AI
        self.freq_hz = freq_hz

    def set_pwm(self, channel, on, off):
        """Set raw 12-bit on/off counts (0..4095)."""
        base = self.LED0_ON_L + 4 * channel
        on &= 0x0FFF; off &= 0x0FFF
        self.bus.write_i2c_block_data(self.address, base, [
            on & 0xFF, (on >> 8) & 0xFF, off & 0xFF, (off >> 8) & 0xFF
        ])

    def set_pwm_us(self, channel, pulse_us):
        """Set PWM by pulse width in microseconds."""
        ticks = int(round(pulse_us * 4096.0 * self.freq_hz / 1_000_000.0))
        ticks = max(0, min(4095, ticks))
        self.set_pwm(channel, 0, ticks)

def main():
    # Env vars let you change bus/address without editing code.
    bus = int(os.getenv("I2C_BUS", "5"))
    addr = int(os.getenv("PCA9685_ADDR", "0x40"), 16)
    freq = int(os.getenv("SERVO_PWM_FREQ", "50"))

    # Pulse settings (safe defaults)
    center = int(os.getenv("CENTER_US", "1500"))
    delta  = int(os.getenv("DELTA_US", "200"))   # nudge amplitude
    hold   = float(os.getenv("HOLD_S", "0.4"))   # time to hold each nudge
    pause  = float(os.getenv("PAUSE_S", "0.6"))  # pause between channels

    # Limit to a subset if you want (e.g., "0-7" or "0,1,2,3")
    only = os.getenv("CHANNELS", "").strip()
    if only:
        chans = []
        for part in only.split(","):
            part = part.strip()
            if "-" in part:
                a,b = part.split("-")
                chans.extend(range(int(a), int(b)+1))
            elif part:
                chans.append(int(part))
    else:
        chans = list(range(16))  # 0..15

    pca = PCA9685(bus=bus, address=addr, freq_hz=freq)
    try:
        print(f"Using I2C bus={bus}, addr=0x{addr:02X}, freq={freq} Hz")
        print("Centering all channels...")
        for ch in chans:
            pca.set_pwm_us(ch, center)
        time.sleep(1.0)

        print("Probing channels. Watch the robot and note which joint moves.")
        for ch in chans:
            print(f"\nChannel {ch}: moving now...")
            # Pattern: left -> center -> right -> center
            pca.set_pwm_us(ch, max(500, center - delta)); time.sleep(hold)
            pca.set_pwm_us(ch, center); time.sleep(0.25)
            pca.set_pwm_us(ch, min(2500, center + delta)); time.sleep(hold)
            pca.set_pwm_us(ch, center); time.sleep(0.25)
            print(f"Channel {ch}: done. Note what moved.")
            time.sleep(pause)

        print("\nFinished. Update your SERVO_CHANNEL_MAP accordingly.")
    finally:
        # Leave all centered
        for ch in chans:
            pca.set_pwm_us(ch, center)
        pca.close()

if __name__ == "__main__":
    main()
