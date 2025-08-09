#!/usr/bin/env python3
"""
API REST Ultra Enxuta para Controle de Servos + Câmera ESP32CAM - Orange Pi Zero 2W
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

# ============================================================
# CONFIGURAÇÕES
# ============================================================
# Agora o SERVO_MAP inclui 'type', 'range' e 'part' por pino.
# Ajuste os ranges e parts como desejar (range pode ser tupla (min,max) ou string "min:max").
SERVO_MAP: Dict[int, Dict[str, Any]] = {
    2:  {"type": "pos", "range": "-80:45", "part": "claw"},
    9:  {"type": "pos", "range": "-10:110", "part": "reach"},
    21: {"type": "pos", "range": "-100:120", "part": "base"},
    22: {"type": "pos", "range": "0:100", "part": "height"},
}

MIN_PULSE = 50
MAX_PULSE = 250

# Observação: o mapeamento default abaixo usa ângulo -90..+90
# para cobrir o range completo de pulso MIN_PULSE..MAX_PULSE.
ANGLE_MIN = -270
ANGLE_MAX = 270
ANGLE_OFFSET = 90

# Configs para servos contínuos (se tiverem)
STOP_PULSE_CR = {2: 140}
GAIN_CR = {2: 2}

PWM_FREQ = 192
PWM_RANGE = 2000
PULSE_RANGE = MAX_PULSE - MIN_PULSE

SMOOTH_STEPS = 20
STEP_DELAY = 0.02

# Configurações da câmera
CAMERA_IP = "192.168.15.9"
CAMERA_CAPTURE_PORT = 80      # porta de captura (foto única /capture)
CAMERA_STREAM_PORT = 81       # porta do stream MJPEG (/stream)
CAMERA_CONNECT_TIMEOUT = 5    # timeout de conexão
CAMERA_STREAM_READ_TIMEOUT = 60  # timeout de leitura do stream

# Estado global
current_state: Dict[int, Union[int, float]] = {}
is_initialized = False

IMAGE_DIR = "frames"
os.makedirs(IMAGE_DIR, exist_ok=True)

app = FastAPI(title="Robot Control + Vision API", version="2.1.1")

# monta /frames como rota estática
app.mount("/frames", StaticFiles(directory=IMAGE_DIR), name="frames")

# ============================================================
# HELPERS DE CONFIG
# ============================================================
def _parse_range(range_value: Any) -> Tuple[int, int]:
    # aceita tupla/lista (min,max) ou string "min:max"
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
                mn = int(float(parts[0]))
                mx = int(float(parts[1]))
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
    pin: int = Field(..., description="Pino GPIO")
    value: Union[int, float] = Field(..., description="Ângulo (posicional) ou velocidade (contínuo)")
    smooth: bool = Field(default=True, description="Movimento suavizado (somente posicionais)")

    @validator('pin')
    def validate_pin(cls, v):
        if v not in SERVO_MAP:
            raise ValueError(f'Pino {v} inválido. Válidos: {list(SERVO_MAP.keys())}')
        return v

    @validator('value')
    def validate_value(cls, v, values):
        # Para 'cr' manteremos a validação -100..+100
        # Para 'pos' não validamos aqui (o range será aplicado e clampado no movimento)
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
# FUNÇÕES CORE SERVOS
# ============================================================
def run_gpio_command(command: str):
    try:
        result = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=5)
        if result.returncode != 0:
            raise HTTPException(status_code=500, detail=f"GPIO error: {result.stderr}")
        return result
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=500, detail="GPIO timeout")

def angle_to_pulse(angle: int) -> int:
    # Mapeia -90..+90 para pulsos MIN_PULSE..MAX_PULSE, com clamp para segurança
    raw = MIN_PULSE + PULSE_RANGE * (angle + ANGLE_OFFSET) / 180
    return int(max(MIN_PULSE, min(MAX_PULSE, raw)))

def ensure_initialized():
    global is_initialized
    if is_initialized:
        return
    result = subprocess.run("command -v gpio", shell=True, capture_output=True)
    if result.returncode != 0:
        raise HTTPException(status_code=500, detail="GPIO não encontrado")

    centre = MIN_PULSE + (MAX_PULSE - MIN_PULSE) // 2
    for pin, cfg in SERVO_MAP.items():
        servo_type = cfg.get("type", "pos")
        run_gpio_command(f"gpio mode {pin} pwm")
        run_gpio_command(f"gpio pwm-ms {pin}")
        run_gpio_command(f"gpio pwmc {pin} {PWM_FREQ}")
        run_gpio_command(f"gpio pwmr {pin} {PWM_RANGE}")
        if servo_type == "pos":
            run_gpio_command(f"gpio pwm {pin} {centre}")
            current_state[pin] = centre
        else:
            stop_pulse = STOP_PULSE_CR.get(pin, 150)
            run_gpio_command(f"gpio pwm {pin} {stop_pulse}")
            current_state[pin] = stop_pulse
    time.sleep(0.025)
    is_initialized = True

def move_servo_smooth(pin: int, angle: int):
    if get_servo_type(pin) != "pos":
        raise HTTPException(status_code=400, detail="Smooth apenas para posicionais")
    # Aplica clamp ao range do servo
    angle, _ = clamp_angle_to_range(pin, angle)
    target = angle_to_pulse(angle)
    current = current_state.get(pin, angle_to_pulse(0))
    diff = target - current
    step = diff / SMOOTH_STEPS
    for _ in range(SMOOTH_STEPS):
        current += step
        run_gpio_command(f"gpio pwm {pin} {int(round(current))}")
        time.sleep(STEP_DELAY)
    run_gpio_command(f"gpio pwm {pin} {target}")
    current_state[pin] = target

def move_servo_direct(pin: int, angle: int):
    if get_servo_type(pin) != "pos":
        raise HTTPException(status_code=400, detail="Direct apenas para posicionais")
    # Aplica clamp ao range do servo
    angle, _ = clamp_angle_to_range(pin, angle)
    pulse = angle_to_pulse(angle)
    run_gpio_command(f"gpio pwm {pin} {pulse}")
    current_state[pin] = pulse

def move_servo_speed(pin: int, speed: int):
    if get_servo_type(pin) != "cr":
        raise HTTPException(status_code=400, detail="Speed apenas para contínuos")
    stop_pulse = STOP_PULSE_CR.get(pin, 150)
    gain = GAIN_CR.get(pin, 2)
    pulse = max(0, min(PWM_RANGE, stop_pulse + speed * gain))
    run_gpio_command(f"gpio pwm {pin} {pulse}")
    current_state[pin] = pulse

def center_all_servos():
    for pin, cfg in SERVO_MAP.items():
        servo_type = cfg.get("type", "pos")
        if servo_type == "pos":
            # Tenta centralizar em 0; se 0 estiver fora do range, será clampado internamente
            move_servo_smooth(pin, 0)
        else:
            move_servo_speed(pin, 0)

# ============================================================
# FUNÇÕES CÂMERA
# ============================================================
def capture_frame_from_esp32():
    """Captura um frame único da ESP32CAM via endpoint /capture"""
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
        "2 45", "2 0", "2 -80", "2 0",
        "9 45", "2 45", "9 0",
        "21 45", "22 0", "9 45",
        "21 -45", "21 45", "22 90", "22 0"
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
    image_url: DataURI = Field(
        ...,
        description="Data-URI JPEG",
        example="data:image/jpeg;base64,/9j/4AA…"
    )
    timestamp: float

@app.get("/camera/frame")
async def get_frame(request: Request,
                    max_width: int = 160,
                    jpeg_quality: int = 30):
    frame = capture_frame_from_esp32()
    if frame is None:
        raise HTTPException(503, "Câmera não disponível")
    # redimensiona
    h, w = frame.shape[:2]
    if w > max_width:
        frame = cv2.resize(frame, (max_width, int(h * max_width / w)),
                           interpolation=cv2.INTER_AREA)
    # codifica JPEG
    ok, buf = cv2.imencode(".jpg", frame,
                           [int(cv2.IMWRITE_JPEG_QUALITY), jpeg_quality])
    if not ok:
        raise HTTPException(500, "Falha JPEG")
    # salva em disco
    fname = f"{uuid.uuid4().hex}.jpg"
    with open(os.path.join(IMAGE_DIR, fname), "wb") as f:
        f.write(buf.tobytes())
    # URL absoluta
    image_url = str(request.base_url) + f"frames/{fname}"
    return {"image_url": image_url, "timestamp": time.time()}

# ============================================================
# STREAM DA CÂMERA (CORRIGIDO)
# ============================================================
@app.get("/camera/stream")
def camera_stream():
    """
    Proxy do stream MJPEG da ESP32-CAM.
    Corrigido para usar a porta correta e manter o stream vivo.
    """
    url = f"http://{CAMERA_IP}:{CAMERA_STREAM_PORT}/stream"
    try:
        # timeout=(conexão, leitura)
        upstream = requests.get(url, stream=True, timeout=(CAMERA_CONNECT_TIMEOUT, CAMERA_STREAM_READ_TIMEOUT))
    except requests.RequestException as e:
        raise HTTPException(503, f"Câmera não disponível: {e}")

    if upstream.status_code != 200:
        # Captura um pedaço do texto para depuração
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
    """Status completo: servos + câmera, incluindo range e part por servo"""
    # Status servos
    servos = []
    for pin, cfg in SERVO_MAP.items():
        servo_type = cfg.get("type", "pos")
        pulse = current_state.get(pin)
        if servo_type == "pos" and pulse is not None:
            value = int(round((pulse - MIN_PULSE) * 180 / PULSE_RANGE) - ANGLE_OFFSET)
        else:
            value = pulse
        servos.append({
            "pin": pin,
            "type": servo_type,
            "range": format_range_str(pin),
            "part": cfg.get("part"),
            "value": value
        })

    # Status câmera (teste rápido)
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
    uvicorn.run(app, host="0.0.0.0", port=8000)
