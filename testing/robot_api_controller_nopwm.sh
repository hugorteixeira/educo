#!/usr/bin/env python3
"""
API REST Ultra Enxuta para Controle de Servos + Câmera ESP32CAM
- Suporta Orange Pi Zero 2W (HW PWM) e Orange Pi 3B (PWM por software)
- Você pode misturar drivers por pino: "hw" (pwm de hardware via comando `gpio`) e "soft" (PWM por software)
"""
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse
from fastapi.staticfiles import StaticFiles
import uuid, os
from pydantic import BaseModel, Field, validator, constr
from typing import Dict, List, Union, Optional, Tuple, Any
import subprocess
import asyncio
import requests
import cv2
import numpy as np
import time
import threading
import atexit

# ============================================================
# CONFIGURAÇÕES
# ============================================================
# Agora o SERVO_MAP inclui 'type', 'range', 'part' e 'driver' por pino.
# driver:
#   - "soft": PWM por software (gpiod recomendado)
#   - "hw": PWM de hardware via comando `gpio` (como no Zero 2W)
# Ajuste ranges e parts como quiser.
SERVO_MAP: Dict[int, Dict[str, Any]] = {
    31:  {"type": "pos", "range": "-80:45",  "part": "claw",   "driver": "soft"},
    33:  {"type": "pos", "range": "-10:110", "part": "reach",  "driver": "soft"},
    35: {"type": "pos", "range": "-100:120","part": "base",   "driver": "soft"},
    37: {"type": "pos", "range": "0:100",   "part": "height", "driver": "soft"},
}
# Se quiser misturar: troque "driver": "hw" nos pinos com PWM de hardware.

# Mapeamento para pinos "soft" quando usando backend gpiod:
# Preencha com base no `gpioinfo` do seu Orange Pi 3B.
# Exemplo (fictício): 2: ("gpiochip0", 12) -> pin lógico 2 usa line 12 no chip gpiochip0
SOFT_GPIOD_MAP: Dict[int, Tuple[str, int]] = {
    31:  ("gpiochip0", 28),
    33:  ("gpiochip0", 31),
    35:  ("gpiochip0", 24),
    37:  ("gpiochip0", 27),
}

# Backend preferido para PWM por software: "gpiod" (recomendado) ou "gpio_cli" (fallback)
SOFT_PWM_BACKEND = "gpiod"  # "gpiod" ou "gpio_cli"
GPIO_CLI_ADDRESING = "physical"
# Janela de pulsos (mantém compatibilidade com seu mapeamento anterior):
# MIN_PULSE..MAX_PULSE são valores em "unidades" onde 2000 unidades = 20 ms => 1 unidade = 10 us
MIN_PULSE = 50    # 0.5 ms
MAX_PULSE = 250   # 2.5 ms
PULSE_UNIT_US = 10  # 1 unidade = 10 microsegundos

# Observação: o mapeamento default abaixo usa ângulo -90..+90
# para cobrir o range completo de pulso MIN_PULSE..MAX_PULSE.
ANGLE_MIN = -270
ANGLE_MAX = 270
ANGLE_OFFSET = 90

# Configs para servos contínuos (se tiverem) - em "unidades"
STOP_PULSE_CR = {2: 140}
GAIN_CR = {2: 2}

# Configs do PWM de hardware (se usar driver "hw")
PWM_FREQ = 192
PWM_RANGE = 2000
PULSE_RANGE = MAX_PULSE - MIN_PULSE

SMOOTH_STEPS = 20
STEP_DELAY = 0.02

# Configurações da câmera
CAMERA_IP = "192.168.15.9"
CAMERA_CAPTURE_PORT = 80      # porta de captura (foto única /capture)
CAMERA_STREAM_PORT = 81       # porta do stream MJPEG (/stream)
CAMERA_CONNECT_TIMEOUT = 5
CAMERA_STREAM_READ_TIMEOUT = 60

# Estado global
current_state: Dict[int, Union[int, float]] = {}
is_initialized = False

IMAGE_DIR = "frames"
os.makedirs(IMAGE_DIR, exist_ok=True)

app = FastAPI(title="Robot Control + Vision API", version="3.0.0")
app.mount("/frames", StaticFiles(directory=IMAGE_DIR), name="frames")

# ============================================================
# HELPERS DE CONFIG
# ============================================================
def _parse_range(range_value: Any) -> Tuple[int, int]:
    if isinstance(range_value, (tuple, list)) and len(range_value) == 2:
        try:
            mn = int(float(range_value[0]))
            mx = int(float(range_value[1]))
        except Exception:
            mn, mx = ANGLE_MIN, ANGLE_MAX
    elif isinstance(range_value, str):
        try:
            parts = range_value.replace(" ", "").split(":")
            if len(parts) == 2:
                mn = int(float(parts[0])); mx = int(float(parts[1]))
            else:
                mn, mx = ANGLE_MIN, ANGLE_MAX
        except Exception:
            mn, mx = ANGLE_MIN, ANGLE_MAX
    else:
        mn, mx = ANGLE_MIN, ANGLE_MAX
    if mn > mx:
        mn, mx = mx, mn
    return mn, mx

def get_servo_type(pin: int) -> str:
    cfg = SERVO_MAP.get(pin, {})
    return cfg.get("type", "pos")

def get_servo_range(pin: int) -> Tuple[int, int]:
    cfg = SERVO_MAP.get(pin, {})
    r = cfg.get("range", (ANGLE_MIN, ANGLE_MAX))
    return _parse_range(r)

def get_servo_part(pin: int) -> Optional[str]:
    cfg = SERVO_MAP.get(pin, {})
    return cfg.get("part")

def get_driver(pin: int) -> str:
    cfg = SERVO_MAP.get(pin, {})
    return cfg.get("driver", "hw")  # padrão hw para retrocompat

def clamp_angle_to_range(pin: int, angle: Union[int, float]) -> Tuple[int, bool]:
    mn, mx = get_servo_range(pin)
    clamped = int(max(mn, min(mx, int(angle))))
    return clamped, clamped != int(angle)

def format_range_str(pin: int) -> str:
    mn, mx = get_servo_range(pin)
    return f"{mn}:{mx}"

# ============================================================
# MODELOS
# ============================================================
class ServoCommand(BaseModel):
    pin: int = Field(..., description="Pino GPIO (mapa lógico da API)")
    value: Union[int, float] = Field(..., description="Ângulo (posicional) ou velocidade (contínuo)")
    smooth: bool = Field(default=True, description="Movimento suavizado (somente posicionais)")

    @validator('pin')
    def validate_pin(cls, v):
        if v not in SERVO_MAP:
            raise ValueError(f'Pino {v} inválido. Válidos: {list(SERVO_MAP.keys())}')
        return v

    @validator('value')
    def validate_value(cls, v, values):
        pin = values.get('pin')
        if pin is not None:
            servo_type = get_servo_type(pin)
            if servo_type == "cr":
                if not (-100 <= float(v) <= 100):
                    raise ValueError('Velocidade: -100 a +100')
        return v

class BatchCommand(BaseModel):
    commands: List[str] = Field(..., description="Lista de comandos")

# ============================================================
# BACKENDS GPIO
# ============================================================
def run_gpio_command(command: str):
    try:
        result = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=5)
        if result.returncode != 0:
            raise HTTPException(status_code=500, detail=f"GPIO error: {result.stderr.strip()} [{command}]")
        return result
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=500, detail=f"GPIO timeout [{command}]")

def angle_to_pulse(angle: int) -> int:
    raw = MIN_PULSE + PULSE_RANGE * (angle + ANGLE_OFFSET) / 180
    return int(max(MIN_PULSE, min(MAX_PULSE, raw)))

# ============================================================
# PWM POR SOFTWARE
# ============================================================
class SoftPinBase:
    def set_high(self): pass
    def set_low(self): pass
    def close(self): pass

class GpioCliPin(SoftPinBase):
    def __init__(self, pin_logical: int):
        self.pin = pin_logical
        # configura como saída
        run_gpio_command(f"gpio mode {self.pin} out")
        self._last = 0

    def set_high(self):
        if self._last != 1:
            run_gpio_command(f"gpio write {self.pin} 1")
            self._last = 1

    def set_low(self):
        if self._last != 0:
            run_gpio_command(f"gpio write {self.pin} 0")
            self._last = 0

    def close(self):
        # opcional: voltar para low
        try:
            self.set_low()
        except:
            pass

class GpioCliPin(SoftPinBase):
    def __init__(self, pin_logical: int):
        self.pin = pin_logical
        self._prefix = "-1 " if GPIO_CLI_ADDRESSING == "physical" else ""
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

class SoftPWMManager:
    """
    Gera PWM por software em 50 Hz para múltiplos pinos em um único thread.
    Usa PULSE_UNIT_US=10us; você passa largura em "unidades" (50..250).
    """
    def __init__(self, period_us: int = 20000):
        self.period_us = period_us
        self._pins: Dict[int, SoftPinBase] = {}     # pin_logical -> SoftPinBase
        self._width_us: Dict[int, int] = {}         # pin_logical -> largura em us
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def _make_pin(self, pin_logical: int) -> SoftPinBase:
        if SOFT_PWM_BACKEND == "gpiod":
            if pin_logical not in SOFT_GPIOD_MAP:
                raise RuntimeError(f"SOFT_GPIOD_MAP não possui o mapeamento do pino {pin_logical}. Preencha usando 'gpioinfo'.")
            chip, line = SOFT_GPIOD_MAP[pin_logical]
            return GpiodPin(chip, line)
        else:
            return GpioCliPin(pin_logical)

    def register_pin(self, pin_logical: int, initial_units: int):
        with self._lock:
            if pin_logical not in self._pins:
                self._pins[pin_logical] = self._make_pin(pin_logical)
            self._width_us[pin_logical] = max(0, initial_units) * PULSE_UNIT_US

    def set_units(self, pin_logical: int, units: int):
        with self._lock:
            if pin_logical not in self._pins:
                self._pins[pin_logical] = self._make_pin(pin_logical)
            self._width_us[pin_logical] = max(0, units) * PULSE_UNIT_US

    def unregister_pin(self, pin_logical: int):
        with self._lock:
            pin = self._pins.pop(pin_logical, None)
            self._width_us.pop(pin_logical, None)
        if pin:
            try:
                pin.set_low()
                pin.close()
            except:
                pass

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
        # Estratégia: inicia alto todos que precisarem; agenda desligamentos por ordem crescente de largura.
        while not self._stop.is_set():
            t0 = time.perf_counter()  # alta resolução
            with self._lock:
                items = [(pin, w) for pin, w in self._width_us.items()]
                pins_map = dict(self._pins)

            # Liga todos (que tiverem largura > 0)
            for pin, w in items:
                if w > 0:
                    try:
                        pins_map[pin].set_high()
                    except Exception:
                        pass

            # Ordena eventos de desligamento
            offs = sorted([w for _, w in items if w > 0])
            i = 0
            last_off_us = 0
            for off_us in offs:
                # Dorme até o próximo evento
                sleep_us = off_us - last_off_us
                if sleep_us > 0:
                    # dorme parte grande
                    sleep_s = sleep_us / 1_000_000.0
                    if sleep_s > 0.00025:
                        time.sleep(sleep_s - 0.0002)
                    # termina com busy-wait leve
                    target = t0 + off_us / 1_000_000.0
                    while True:
                        now = time.perf_counter()
                        if now >= target or self._stop.is_set():
                            break
                        # busy wait curto
                # Desliga todos que tenham exatamente essa largura
                for pin, w in items:
                    if w == off_us:
                        try:
                            pins_map[pin].set_low()
                        except Exception:
                            pass
                last_off_us = off_us

            # Dorme até completar o período de 20 ms
            elapsed = (time.perf_counter() - t0)
            remain = self.period_us / 1_000_000.0 - elapsed
            if remain > 0:
                time.sleep(remain)
            else:
                # ciclo atrasou; segue imediatamente
                pass

# Instância global do gestor de PWM por software
soft_pwm = SoftPWMManager()
atexit.register(soft_pwm.stop)

# ============================================================
# CORE SERVOS (driver-aware)
# ============================================================
def ensure_initialized():
    global is_initialized
    if is_initialized:
        return

    # Inicializa backends conforme driver de cada pino
    # HW driver precisa do binário gpio
    need_hw = any(get_driver(pin) == "hw" for pin in SERVO_MAP)
    if need_hw:
        result = subprocess.run("command -v gpio", shell=True, capture_output=True)
        if result.returncode != 0:
            raise HTTPException(status_code=500, detail="GPIO não encontrado (necessário para driver 'hw').")

    # Inicia soft PWM se houver pinos "soft"
    need_soft = any(get_driver(pin) == "soft" for pin in SERVO_MAP)
    if need_soft:
        soft_pwm.start()

    centre_units = MIN_PULSE + (MAX_PULSE - MIN_PULSE) // 2

    for pin, cfg in SERVO_MAP.items():
        servo_type = cfg.get("type", "pos")
        driver = get_driver(pin)
        if driver == "hw":
            # Configura PWM de hardware via 'gpio' (compatível com seu script original)
            run_gpio_command(f"gpio mode {pin} pwm")
            run_gpio_command(f"gpio pwm-ms {pin}")
            run_gpio_command(f"gpio pwmc {pin} {PWM_FREQ}")
            run_gpio_command(f"gpio pwmr {pin} {PWM_RANGE}")
            if servo_type == "pos":
                run_gpio_command(f"gpio pwm {pin} {centre_units}")
                current_state[pin] = centre_units
            else:
                stop_pulse = STOP_PULSE_CR.get(pin, 150)
                run_gpio_command(f"gpio pwm {pin} {stop_pulse}")
                current_state[pin] = stop_pulse
        else:
            # Driver por software
            if servo_type == "pos":
                soft_pwm.register_pin(pin, centre_units)
                current_state[pin] = centre_units
            else:
                stop_pulse = STOP_PULSE_CR.get(pin, 150)
                soft_pwm.register_pin(pin, stop_pulse)
                current_state[pin] = stop_pulse

    time.sleep(0.025)
    is_initialized = True

def _set_pulse_units(pin: int, units: int):
    driver = get_driver(pin)
    if driver == "hw":
        run_gpio_command(f"gpio pwm {pin} {units}")
    else:
        soft_pwm.set_units(pin, units)

def move_servo_smooth(pin: int, angle: int):
    if get_servo_type(pin) != "pos":
        raise HTTPException(status_code=400, detail="Smooth apenas para posicionais")
    angle, _ = clamp_angle_to_range(pin, angle)
    target_units = angle_to_pulse(angle)
    current_units = int(current_state.get(pin, angle_to_pulse(0)))
    diff = target_units - current_units
    step = diff / SMOOTH_STEPS
    val = current_units
    for _ in range(SMOOTH_STEPS):
        val += step
        _set_pulse_units(pin, int(round(val)))
        time.sleep(STEP_DELAY)
    _set_pulse_units(pin, target_units)
    current_state[pin] = target_units

def move_servo_direct(pin: int, angle: int):
    if get_servo_type(pin) != "pos":
        raise HTTPException(status_code=400, detail="Direct apenas para posicionais")
    angle, _ = clamp_angle_to_range(pin, angle)
    units = angle_to_pulse(angle)
    _set_pulse_units(pin, units)
    current_state[pin] = units

def move_servo_speed(pin: int, speed: int):
    if get_servo_type(pin) != "cr":
        raise HTTPException(status_code=400, detail="Speed apenas para contínuos")
    stop_pulse = STOP_PULSE_CR.get(pin, 150)
    gain = GAIN_CR.get(pin, 2)
    units = max(0, min(PWM_RANGE, stop_pulse + speed * gain))
    _set_pulse_units(pin, units)
    current_state[pin] = units

def center_all_servos():
    for pin, cfg in SERVO_MAP.items():
        servo_type = cfg.get("type", "pos")
        if servo_type == "pos":
            move_servo_smooth(pin, 0)
        else:
            move_servo_speed(pin, 0)

# ============================================================
# FUNÇÕES CÂMERA
# ============================================================
def capture_frame_from_esp32():
    try:
        url = f"http://{CAMERA_IP}:{CAMERA_CAPTURE_PORT}/capture"
        response = requests.get(url, timeout=CAMERA_CONNECT_TIMEOUT)
        if response.status_code == 200:
            nparr = np.frombuffer(response.content, np.uint8)
            frame = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
            return frame
        return None
    except Exception as e:
        print(f"Erro ao capturar frame: {e}")
        return None

# ============================================================
# ENDPOINTS SERVOS
# ============================================================
@app.post("/servo/move")
async def move_servo(command: ServoCommand):
    ensure_initialized()
    servo_type = get_servo_type(command.pin)

    if servo_type == "pos":
        requested = int(command.value)
        applied, clamped = clamp_angle_to_range(command.pin, requested)

        if command.smooth:
            move_servo_smooth(command.pin, applied)
        else:
            move_servo_direct(command.pin, applied)

        resp = {
            "pin": command.pin,
            "requested_angle": requested,
            "applied_angle": applied,
            "mode": "smooth" if command.smooth else "direct"
        }
        if clamped:
            resp["warning"] = f"Valor fora do range permitido ({format_range_str(command.pin)}). Aplicado {applied}."
        return resp

    else:
        move_servo_speed(command.pin, int(command.value))
        return {"pin": command.pin, "speed": command.value}

@app.post("/servo/center")
async def center_servos():
    ensure_initialized()
    center_all_servos()
    return {"message": "Servos centralizados"}

@app.post("/servo/demo")
async def run_demo():
    ensure_initialized()
    demo_sequence = [
        "31 45", "31 0", "31 -80", "31 0",
        "33 45", "33 45", "33 0",
        "35 45", "35 0", "35 45",
        "35 -45", "35 45", "35 90", "35 0"
    ]
    for cmd_line in demo_sequence:
        parts = cmd_line.split()
        pin, value = int(parts[0]), int(parts[1])
        servo_type = get_servo_type(pin)
        if servo_type == "pos":
            move_servo_smooth(pin, value)
        else:
            move_servo_speed(pin, value)
    center_all_servos()
    return {"message": "Demo executado"}

# ============================================================
# MODELOS PARA A IMAGEM
# ============================================================
DataURI = constr(pattern=r"^data:image\/jpeg;base64,.*", strip_whitespace=True)

class FrameDataURIResponse(BaseModel):
    image_url: DataURI = Field(..., description="Data-URI JPEG", example="data:image/jpeg;base64,/9j/4AA…")
    timestamp: float

@app.get("/camera/frame")
async def get_frame(request: Request, max_width: int = 160, jpeg_quality: int = 30):
    frame = capture_frame_from_esp32()
    if frame is None:
        raise HTTPException(503, "Câmera não disponível")
    h, w = frame.shape[:2]
    if w > max_width:
        frame = cv2.resize(frame, (max_width, int(h * max_width / w)), interpolation=cv2.INTER_AREA)
    ok, buf = cv2.imencode(".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), jpeg_quality])
    if not ok:
        raise HTTPException(500, "Falha JPEG")
    fname = f"{uuid.uuid4().hex}.jpg"
    with open(os.path.join(IMAGE_DIR, fname), "wb") as f:
        f.write(buf.tobytes())
    image_url = str(request.base_url) + f"frames/{fname}"
    return {"image_url": image_url, "timestamp": time.time()}

# ============================================================
# STREAM DA CÂMERA
# ============================================================
@app.get("/camera/stream")
def camera_stream():
    url = f"http://{CAMERA_IP}:{CAMERA_STREAM_PORT}/stream"
    try:
        upstream = requests.get(url, stream=True, timeout=(CAMERA_CONNECT_TIMEOUT, CAMERA_STREAM_READ_TIMEOUT))
    except requests.RequestException as e:
        raise HTTPException(503, f"Câmera não disponível: {e}")

    if upstream.status_code != 200:
        try:
            err_snippet = upstream.text[:200]
        except Exception:
            err_snippet = ""
        upstream.close()
        raise HTTPException(503, f"Câmera não disponível (status {upstream.status_code}). {err_snippet}")

    content_type = upstream.headers.get("Content-Type", "multipart/x-mixed-replace; boundary=frame")

    def iter_stream():
        try:
            for chunk in upstream.iter_content(chunk_size=16384):
                if chunk:
                    yield chunk
        finally:
            upstream.close()

    headers = {
        "Cache-Control": "no-cache, no-store, must-revalidate",
        "Pragma": "no-cache",
        "Connection": "keep-alive",
        "Content-Type": content_type,
    }
    return StreamingResponse(iter_stream(), media_type=content_type, headers=headers)

# ============================================================
# ENDPOINT STATUS COMPLETO
# ============================================================
@app.get("/robot/status")
async def get_robot_full_status():
    servos = []
    for pin, cfg in SERVO_MAP.items():
        servo_type = cfg.get("type", "pos")
        pulse = current_state.get(pin)
        if servo_type == "pos" and pulse is not None:
            value = int(round((int(pulse) - MIN_PULSE) * 180 / PULSE_RANGE) - ANGLE_OFFSET)
        else:
            value = pulse
        servos.append({
            "pin": pin,
            "type": servo_type,
            "driver": get_driver(pin),
            "range": format_range_str(pin),
            "part": cfg.get("part"),
            "value": value
        })

    frame = capture_frame_from_esp32()
    camera_connected = frame is not None

    return {
        "servo_system": {
            "initialized": is_initialized,
            "servos": servos
        },
        "camera_system": {
            "connected": camera_connected,
            "capture_url": f"http://{CAMERA_IP}:{CAMERA_CAPTURE_PORT}/capture",
            "stream_url": f"http://{CAMERA_IP}:{CAMERA_STREAM_PORT}/stream"
        },
        "timestamp": time.time()
    }

if __name__ == "__main__":
    import uvicorn
    try:
        uvicorn.run(app, host="0.0.0.0", port=8000)
    finally:
        soft_pwm.stop()

