#!/usr/bin/env python3
"""
API REST Ultra Enxuta para Controle de Servos + Câmera ESP32CAM - Orange Pi Zero 2W
"""

from fastapi import FastAPI, HTTPException, Response
from fastapi.responses import StreamingResponse
from fastapi import Request
from fastapi.staticfiles import StaticFiles
import uuid, os  
from pydantic import BaseModel, Field, validator
from typing import Dict, List, Union, Optional
import subprocess
import asyncio
import requests
import cv2
import numpy as np
import base64
import time
import threading
from io import BytesIO

# ============================================================
# CONFIGURAÇÕES
# ============================================================
SERVO_MAP = {2: "pos", 9: "pos", 21: "pos", 22: "pos"}
MIN_PULSE = 50
MAX_PULSE = 250
ANGLE_MIN = -270
ANGLE_MAX = 270
ANGLE_OFFSET = 90
STOP_PULSE_CR = {2: 140}
GAIN_CR = {2: 2}
PWM_FREQ = 192
PWM_RANGE = 2000
PULSE_RANGE = MAX_PULSE - MIN_PULSE
SMOOTH_STEPS = 20
STEP_DELAY = 0.02

# Configurações da câmera
CAMERA_IP = "192.168.15.9"
CAMERA_PORT = 81
CAMERA_TIMEOUT = 5

# Estado global
current_state: Dict[int, Union[int, float]] = {}
is_initialized = False

IMAGE_DIR = "frames"
os.makedirs(IMAGE_DIR, exist_ok=True)

app = FastAPI(title="Robot Control + Vision API", version="2.0.0")

# monta /frames como rota estática
app.mount("/frames", StaticFiles(directory=IMAGE_DIR), name="frames")

# ============================================================
# MODELOS
# ============================================================
class ServoCommand(BaseModel):
    pin: int = Field(..., description="Pino GPIO")
    value: Union[int, float] = Field(..., description="Ângulo (-270 a +270) ou velocidade (-100 a +100)")
    smooth: bool = Field(default=True, description="Movimento suavizado")
    
    @validator('pin')
    def validate_pin(cls, v):
        if v not in SERVO_MAP:
            raise ValueError(f'Pino {v} inválido. Válidos: {list(SERVO_MAP.keys())}')
        return v
    
    @validator('value')
    def validate_value(cls, v, values):
        if 'pin' in values:
            servo_type = SERVO_MAP[values['pin']]
            if servo_type == "pos" and not (ANGLE_MIN <= v <= ANGLE_MAX):
                raise ValueError(f'Ângulo: {ANGLE_MIN} a {ANGLE_MAX}')
            elif servo_type == "cr" and not (-100 <= v <= 100):
                raise ValueError(f'Velocidade: -100 a +100')
        return v

class BatchCommand(BaseModel):
    commands: List[str] = Field(..., description="Lista de comandos")

# ============================================================
# FUNÇÕES CORE SERVOS (mantidas iguais)
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
    return int(MIN_PULSE + PULSE_RANGE * (angle + ANGLE_OFFSET) / 180)

def ensure_initialized():
    global is_initialized
    if is_initialized:
        return
        
    result = subprocess.run("command -v gpio", shell=True, capture_output=True)
    if result.returncode != 0:
        raise HTTPException(status_code=500, detail="GPIO não encontrado")
    
    centre = MIN_PULSE + (MAX_PULSE - MIN_PULSE) // 2
    
    for pin, servo_type in SERVO_MAP.items():
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
    if SERVO_MAP[pin] != "pos":
        raise HTTPException(status_code=400, detail="Smooth apenas para posicionais")
    
    target = angle_to_pulse(angle)
    current = current_state.get(pin, angle_to_pulse(0))
    diff = target - current
    step = diff / SMOOTH_STEPS
    
    for i in range(SMOOTH_STEPS):
        current += step
        run_gpio_command(f"gpio pwm {pin} {int(round(current))}")
        time.sleep(STEP_DELAY)
    
    run_gpio_command(f"gpio pwm {pin} {target}")
    current_state[pin] = target

def move_servo_direct(pin: int, angle: int):
    if SERVO_MAP[pin] != "pos":
        raise HTTPException(status_code=400, detail="Direct apenas para posicionais")
    pulse = angle_to_pulse(angle)
    run_gpio_command(f"gpio pwm {pin} {pulse}")
    current_state[pin] = pulse

def move_servo_speed(pin: int, speed: int):
    if SERVO_MAP[pin] != "cr":
        raise HTTPException(status_code=400, detail="Speed apenas para contínuos")
    stop_pulse = STOP_PULSE_CR.get(pin, 150)
    gain = GAIN_CR.get(pin, 2)
    pulse = max(0, min(PWM_RANGE, stop_pulse + speed * gain))
    run_gpio_command(f"gpio pwm {pin} {pulse}")
    current_state[pin] = pulse

def center_all_servos():
    for pin, servo_type in SERVO_MAP.items():
        if servo_type == "pos":
            move_servo_smooth(pin, 0)
        else:
            move_servo_speed(pin, 0)

# ============================================================
# FUNÇÕES CÂMERA
# ============================================================
def capture_frame_from_esp32():
    """Captura um frame único da ESP32CAM via endpoint /capture"""
    try:
        url = f"http://{CAMERA_IP}/capture"
        response = requests.get(url, timeout=CAMERA_TIMEOUT)
        
        if response.status_code == 200:
            # Decodifica JPEG direto
            nparr = np.frombuffer(response.content, np.uint8)
            frame = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
            return frame
        return None
    except Exception as e:
        print(f"Erro ao capturar frame: {e}")
        return None

# ============================================================
# AENDPOINTS SERVOS (mantidos iguais)
# ============================================================
@app.post("/servo/move")
async def move_servo(command: ServoCommand):
    ensure_initialized()
    
    servo_type = SERVO_MAP[command.pin]
    
    if servo_type == "pos":
        if command.smooth:
            move_servo_smooth(command.pin, int(command.value))
        else:
            move_servo_direct(command.pin, int(command.value))
        return {"pin": command.pin, "angle": command.value, "mode": "smooth" if command.smooth else "direct"}
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
        servo_type = SERVO_MAP[pin]
        
        if servo_type == "pos":
            move_servo_smooth(pin, value)
        else:
            move_servo_speed(pin, value)
        
        await asyncio.sleep(0.5)
    
    center_all_servos()
    return {"message": "Demo executado"}

# ============================================================
# MODELOS PARA A IMAGEM
# ============================================================
from pydantic import BaseModel, Field, constr

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
# ENDPOINT STATUS COMPLETO
# ============================================================
@app.get("/robot/status")
async def get_robot_full_status():
    """Status completo: servos + câmera"""
    # Status servos
    servos = []
    for pin, servo_type in SERVO_MAP.items():
        pulse = current_state.get(pin)
        if servo_type == "pos" and pulse:
            value = int(round((pulse - MIN_PULSE) * 180 / PULSE_RANGE) - ANGLE_OFFSET)
        else:
            value = pulse
        servos.append({"pin": pin, "type": servo_type, "value": value})
    
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
            "camera_url": f"http://{CAMERA_IP}/capture"
        },
        "timestamp": time.time()
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
