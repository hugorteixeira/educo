from typing import List
from app.utils import run_gpio_command

class HardwarePWMBackend:
    """Hardware PWM via `gpio` CLI for ALL 4 pins (no mixing)."""
    def __init__(self, pwm_freq: int, pwm_range: int):
        self.pwm_freq = pwm_freq
        self.pwm_range = pwm_range

    def setup(self, pins: List[int], centre_units: int):
        # Note: pins must be numbers accepted by the `gpio` tool (not physical).
        for p in pins:
            run_gpio_command(f"gpio mode {p} pwm")
        for p in pins:
            run_gpio_command(f"gpio pwm-ms {p}")
            run_gpio_command(f"gpio pwmc {p} {self.pwm_freq}")
            run_gpio_command(f"gpio pwmr {p} {self.pwm_range}")
            run_gpio_command(f"gpio pwm {p} {centre_units}")

    def set_units(self, pin: int, units: int):
        run_gpio_command(f"gpio pwm {pin} {units}")

    def cleanup(self):
        # Optional: nothing
        pass
