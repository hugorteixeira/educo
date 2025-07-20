#!/usr/bin/env python3
"""
API REST para Controle de Servos - Orange Pi Zero 2W
Encapsula o script bash original em endpoints HTTP
"""

from fastapi import FastAPI, HTTPException, BackgroundTasks
from pydantic import BaseModel, Field, validator
from typing import Dict, List, Optional, Union
import subprocess
import asyncio
import os
import tempfile
from enum import Enum

# ============================================================
# CONFIGURAÇÕES (espelho do bash original)
# ============================================================
SERVO_MAP = {
    2: "pos", 9: "pos", 21: "pos", 22: "pos"
}
MIN_PULSE = 50
MAX_PULSE = 250
ANGLE_MIN = -270
ANGLE_MAX = 270
ANGLE_OFFSET = 90
STOP_PULSE_CR = {2: 140}
GAIN_CR = {2: 2}
PWM_FREQ = 192
PWM_RANGE = 2000

# Estado atual dos servos
current_state: Dict[int, Union[int, float]] = {}
is_initialized = False

app = FastAPI(
    title="Servo Control API",
    description="API REST para controle de servos via Orange Pi Zero 2W",
    version="1.0.0"
)

# ============================================================
# MODELOS PYDANTIC
# ============================================================
class ServoType(str, Enum):
    POSICIONAL = "pos"
    CONTINUO = "cr"

class ServoCommand(BaseModel):
    pin: int = Field(..., description="Número do pino GPIO")
    value: Union[int, float] = Field(..., description="Ângulo (-270 a +270) ou velocidade (-100 a +100)")
    smooth: bool = Field(default=True, description="Movimento suavizado (apenas para servos posicionais)")
    
    @validator('pin')
    def validate_pin(cls, v):
        if v not in SERVO_MAP:
            raise ValueError(f'Pino {v} não configurado. Pinos válidos: {list(SERVO_MAP.keys())}')
        return v
    
    @validator('value')
    def validate_value(cls, v, values):
        if 'pin' in values:
            servo_type = SERVO_MAP[values['pin']]
            if servo_type == "pos" and not (ANGLE_MIN <= v <= ANGLE_MAX):
                raise ValueError(f'Ângulo deve estar entre {ANGLE_MIN} e {ANGLE_MAX}')
            elif servo_type == "cr" and not (-100 <= v <= 100):
                raise ValueError(f'Velocidade deve estar entre -100 e +100')
        return v

class BatchCommand(BaseModel):
    commands: List[str] = Field(..., description="Lista de comandos no formato bash original")

class DemoFile(BaseModel):
    content: str = Field(..., description="Conteúdo do arquivo demo")
    
class ServoStatus(BaseModel):
    pin: int
    type: str
    current_value: Optional[Union[int, float]]
    is_initialized: bool

# ============================================================
# FUNÇÕES DE CONTROLE (tradução do bash)
# ============================================================
def run_gpio_command(command: str) -> subprocess.CompletedProcess:
    """Executa comando gpio e retorna resultado"""
    try:
        result = subprocess.run(
            command, 
            shell=True, 
            capture_output=True, 
            text=True, 
            timeout=5
        )
        return result
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=500, detail="Timeout no comando GPIO")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Erro executando comando: {str(e)}")

def init_servo_system():
    """Inicializa sistema de servos (tradução de init_servo)"""
    global is_initialized
    
    # Verifica se gpio está disponível
    result = run_gpio_command("command -v gpio")
    if result.returncode != 0:
        raise HTTPException(status_code=500, detail="Comando 'gpio' não encontrado")
    
    centre = MIN_PULSE + (MAX_PULSE - MIN_PULSE) // 2
    
    for pin, servo_type in SERVO_MAP.items():
        # Configura PWM
        run_gpio_command(f"gpio mode {pin} pwm")
        run_gpio_command(f"gpio pwm-ms {pin}")
        run_gpio_command(f"gpio pwmc {pin} {PWM_FREQ}")
        run_gpio_command(f"gpio pwmr {pin} {PWM_RANGE}")
        
        # Valor inicial
        if servo_type == "pos":
            run_gpio_command(f"gpio pwm {pin} {centre}")
            current_state[pin] = 0  # posição central
        else:
            stop_pulse = STOP_PULSE_CR.get(pin, 150)
            run_gpio_command(f"gpio pwm {pin} {stop_pulse}")
            current_state[pin] = 0  # velocidade zero
    
    # Espera estabilizar
    import time
    time.sleep(0.025)
    
    is_initialized = True
    return True

def move_servo_smooth(pin: int, angle: int):
    """Movimento suavizado (tradução de move_smooth)"""
    if SERVO_MAP[pin] != "pos":
        raise HTTPException(status_code=400, detail="Movimento suavizado apenas para servos posicionais")
    
    norm = angle + ANGLE_OFFSET
    target = MIN_PULSE + (MAX_PULSE - MIN_PULSE) * norm // 180
    current = current_state.get(pin, MIN_PULSE + (MAX_PULSE - MIN_PULSE) // 2)
    
    steps = 20
    step_delay = 0.02
    step = (target - current) // steps
    if abs(step) < 1:
        step = -1 if step < 0 else 1
    
    import time
    for i in range(steps):
        current += step
        current = max(0, min(PWM_RANGE, current))
        run_gpio_command(f"gpio pwm {pin} {current}")
        time.sleep(step_delay)
    
    run_gpio_command(f"gpio pwm {pin} {target}")
    current_state[pin] = angle

def move_servo_direct(pin: int, angle: int):
    """Movimento direto (tradução de move_direct)"""
    if SERVO_MAP[pin] != "pos":
        raise HTTPException(status_code=400, detail="Comando direto apenas para servos posicionais")
    
    pulse = MIN_PULSE + (MAX_PULSE - MIN_PULSE) * (angle + ANGLE_OFFSET) // 180
    pulse = max(0, min(PWM_RANGE, pulse))
    run_gpio_command(f"gpio pwm {pin} {pulse}")
    current_state[pin] = angle

def move_servo_speed(pin: int, speed: int):
    """Controle de velocidade (tradução de move_speed)"""
    if SERVO_MAP[pin] != "cr":
        raise HTTPException(status_code=400, detail="Controle de velocidade apenas para servos contínuos")
    
    stop_pulse = STOP_PULSE_CR.get(pin, 150)
    gain = GAIN_CR.get(pin, 2)
    pulse = stop_pulse + speed * gain
    pulse = max(0, min(PWM_RANGE, pulse))
    
    run_gpio_command(f"gpio pwm {pin} {pulse}")
    current_state[pin] = speed

def center_all_servos():
    """Centraliza todos os servos"""
    for pin, servo_type in SERVO_MAP.items():
        if servo_type == "pos":
            move_servo_smooth(pin, 0)
        else:
            move_servo_speed(pin, 0)

# ============================================================
# ENDPOINTS DA API
# ============================================================
@app.get("/")
async def root():
    return {
        "message": "Servo Control API",
        "version": "1.0.0",
        "endpoints": ["/docs", "/servo/init", "/servo/move", "/servo/status"]
    }

@app.post("/servo/init")
async def initialize_servos():
    """Inicializa sistema de servos"""
    try:
        init_servo_system()
        return {
            "status": "success", 
            "message": "Servos inicializados",
            "configured_pins": list(SERVO_MAP.keys())
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/servo/move")
async def move_servo(command: ServoCommand):
    """Move um servo específico"""
    if not is_initialized:
        raise HTTPException(status_code=400, detail="Sistema não inicializado. Use /servo/init primeiro")
    
    try:
        servo_type = SERVO_MAP[command.pin]
        
        if servo_type == "pos":
            if command.smooth:
                move_servo_smooth(command.pin, int(command.value))
            else:
                move_servo_direct(command.pin, int(command.value))
            return {
                "status": "success",
                "pin": command.pin,
                "angle": command.value,
                "mode": "smooth" if command.smooth else "direct"
            }
        else:  # servo contínuo
            move_servo_speed(command.pin, int(command.value))
            return {
                "status": "success",
                "pin": command.pin,
                "speed": command.value
            }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/servo/center")
async def center_servos():
    """Centraliza todos os servos"""
    if not is_initialized:
        raise HTTPException(status_code=400, detail="Sistema não inicializado")
    
    try:
        center_all_servos()
        return {"status": "success", "message": "Todos os servos centralizados"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/servo/status")
async def get_servo_status():
    """Retorna status atual dos servos"""
    servos = []
    for pin, servo_type in SERVO_MAP.items():
        servos.append(ServoStatus(
            pin=pin,
            type=servo_type,
            current_value=current_state.get(pin),
            is_initialized=is_initialized
        ))
    
    return {
        "system_initialized": is_initialized,
        "servos": servos
    }

@app.post("/servo/raw")
async def send_raw_command(pin: int, value: int):
    """Envia comando PWM direto (equivalente ao 'raw' do bash)"""
    if not is_initialized:
        raise HTTPException(status_code=400, detail="Sistema não inicializado")
    
    if pin not in SERVO_MAP:
        raise HTTPException(status_code=400, detail=f"Pino {pin} não configurado")
    
    try:
        value = max(0, min(PWM_RANGE, value))
        run_gpio_command(f"gpio pwm {pin} {value}")
        return {"status": "success", "pin": pin, "raw_value": value}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/servo/batch")
async def run_batch_commands(batch: BatchCommand):
    """Executa sequência de comandos (equivalente ao modo batch)"""
    if not is_initialized:
        raise HTTPException(status_code=400, detail="Sistema não inicializado")
    
    results = []
    for cmd_line in batch.commands:
        cmd_line = cmd_line.strip()
        if not cmd_line or cmd_line.startswith('#'):
            continue
            
        parts = cmd_line.split()
        if not parts:
            continue
            
        cmd = parts[0]
        
        try:
            if cmd == "sleep":
                delay = float(parts[1]) if len(parts) > 1 else 0
                await asyncio.sleep(delay)
                results.append(f"sleep {delay}")
                
            elif cmd == "center":
                center_all_servos()
                results.append("center executed")
                
            elif cmd == "raw" and len(parts) >= 3:
                pin, value = int(parts[1]), int(parts[2])
                value = max(0, min(PWM_RANGE, value))
                run_gpio_command(f"gpio pwm {pin} {value}")
                results.append(f"raw {pin} {value}")
                
            elif cmd.isdigit():  # comando de movimento por pino
                pin, value = int(cmd), int(parts[1])
                servo_type = SERVO_MAP.get(pin)
                if servo_type == "pos":
                    move_servo_smooth(pin, value)
                elif servo_type == "cr":
                    move_servo_speed(pin, value)
                results.append(f"moved pin {pin} to {value}")
                
        except Exception as e:
            results.append(f"Error in '{cmd_line}': {str(e)}")
    
    return {"status": "success", "executed_commands": len(results), "results": results}

@app.post("/servo/demo")
async def run_demo():
    """Executa demo padrão (tradução da função demo)"""
    if not is_initialized:
        raise HTTPException(status_code=400, detail="Sistema não inicializado")
    
    demo_sequence = [
        "2 45", "2 0", "2 -80", "2 0",
        "9 45", "2 45", "9 0",
        "21 45", "22 0", "9 45",
        "21 -45", "21 45", "22 90", "22 0",
        "center"
    ]
    
    return await run_batch_commands(BatchCommand(commands=demo_sequence))

@app.post("/servo/demo/custom")
async def run_custom_demo(demo: DemoFile):
    """Executa demo customizado a partir de conteúdo de arquivo"""
    if not is_initialized:
        raise HTTPException(status_code=400, detail="Sistema não inicializado")
    
    # Processa o conteúdo do demo (similar ao run_demo_file)
    lines = demo.content.strip().split('\n')
    commands = []
    limits = {}
    header_done = False
    
    for line in lines:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
            
        if not header_done:
            # Verifica se é linha de limite (formato pin:min:max)
            if ':' in line and len(line.split(':')) == 3:
                try:
                    pin, min_val, max_val = map(int, line.split(':'))
                    limits[pin] = (min_val, max_val)
                    continue
                except ValueError:
                    pass
            header_done = True
        
        # Aplica limites se definidos
        parts = line.split()
        if parts and parts[0].isdigit():
            pin = int(parts[0])
            if pin in limits and len(parts) > 1:
                value = int(parts[1])
                min_val, max_val = limits[pin]
                value = max(min_val, min(max_val, value))
                line = f"{pin} {value}"
        
        commands.append(line)
    
    return await run_batch_commands(BatchCommand(commands=commands))

# ============================================================
# EXECUÇÃO
# ============================================================
if __name__ == "__main__":
    import uvicorn
    print("Iniciando Servo Control API...")
    print("Documentação disponível em: http://localhost:8000/docs")
    uvicorn.run(app, host="0.0.0.0", port=8000)

