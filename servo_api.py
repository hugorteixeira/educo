#!/usr/bin/env python3
"""
API REST para Controle de Servos - Orange Pi Zero 2W
Versão Final: Replica fielmente o comportamento do script bash
usando BackgroundTasks para garantir timing correto em movimentos suaves.
"""
from fastapi import FastAPI, HTTPException, BackgroundTasks
from pydantic import BaseModel, Field, validator
from typing import Dict, List, Optional, Union
import subprocess
import time
from enum import Enum

# ============================================================
# CONFIGURAÇÕES (espelho exato do bash original)
# ============================================================
SERVO_MAP = {
    2: "pos", 9: "pos", 21: "pos", 22: "pos"
}
MIN_PULSE = 50
MAX_PULSE = 250
PULSE_RANGE = MAX_PULSE - MIN_PULSE
ANGLE_MIN = -270
ANGLE_MAX = +270
ANGLE_OFFSET = 90
STOP_PULSE_CR = {2: 140}
GAIN_CR = {2: 2}
PWM_FREQ = 192
PWM_RANGE = 2000
SMOOTH_STEPS = 20
STEP_DELAY = 0.02

# Estado global dos servos (valores de pulso PWM)
# Esta variável é compartilhada entre as requisições e as tarefas de fundo
current_pulse: Dict[int, int] = {}
is_initialized = False

app = FastAPI(
    title="Servo Control API",
    description="API REST para controle de servos via Orange Pi Zero 2W (com movimento suave corrigido)",
    version="2.0.0"
)

# ============================================================
# MODELOS PYDANTIC (sem alterações)
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
        if 'pin' in values and SERVO_MAP.get(values['pin']) == "pos":
            if not (ANGLE_MIN <= v <= ANGLE_MAX):
                raise ValueError(f'Ângulo deve estar entre {ANGLE_MIN} e {ANGLE_MAX}')
        elif 'pin' in values and SERVO_MAP.get(values['pin']) == "cr":
            if not (-100 <= v <= 100):
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
    current_pulse: Optional[int]

# ============================================================
# FUNÇÕES DE CONTROLE (SÍNCRONAS, PARA SEREM USADAS EM BACKGROUND)
# ============================================================
def _run_gpio_command(command: str):
    """Função interna para executar comandos gpio. Loga erros em vez de quebrar."""
    try:
        # Usar check=True para lançar exceção em caso de erro
        subprocess.run(
            command, shell=True, capture_output=True, text=True, check=True, timeout=5
        )
        return True
    except subprocess.CalledProcessError as e:
        print(f"Erro executando comando GPIO '{command}': {e.stderr.strip()}")
    except subprocess.TimeoutExpired:
        print(f"Timeout executando comando GPIO: '{command}'")
    except Exception as e:
        print(f"Erro inesperado no comando GPIO: '{command}': {e}")
    return False

def pwm_write(pin: int, value: int):
    """Define o valor PWM para um pino e atualiza o estado global."""
    value = max(0, min(value, PWM_RANGE))
    if _run_gpio_command(f"gpio pwm {pin} {value}"):
        current_pulse[pin] = value

def config_pwm_pin(pin: int):
    """Configura um pino para operar em modo PWM."""
    _run_gpio_command(f"gpio mode {pin} pwm")
    _run_gpio_command(f"gpio pwm-ms {pin}")
    _run_gpio_command(f"gpio pwmc {pin} {PWM_FREQ}")
    _run_gpio_command(f"gpio pwmr {pin} {PWM_RANGE}")

def init_servo_system():
    """Inicializa todos os servos configurados para uma posição de repouso."""
    global is_initialized
    print("Inicializando sistema de servos...")
    if not _run_gpio_command("command -v gpio"):
        print("ERRO CRÍTICO: Comando 'gpio' não encontrado. A API não funcionará.")
        raise RuntimeError("Comando 'gpio' não encontrado.")

    centre_pulse = MIN_PULSE + PULSE_RANGE // 2
    for pin, servo_type in SERVO_MAP.items():
        config_pwm_pin(pin)
        if servo_type == "pos":
            initial_pulse = centre_pulse
        else:
            initial_pulse = STOP_PULSE_CR.get(pin, 150)
        
        # Define o pulso inicial e atualiza o estado global
        pwm_write(pin, initial_pulse)

    time.sleep(0.025) # Espera para garantir que o primeiro pulso seja estável
    is_initialized = True
    print("Servos prontos.")

def move_servo_smooth(pin: int, angle: int):
    """Executa um movimento suavizado. Esta função é bloqueante e ideal para BackgroundTasks."""
    if SERVO_MAP.get(pin) != "pos":
        print(f"Aviso: Movimento suave ignorado para pino não posicional {pin}.")
        return

    # Validação e cálculos
    norm = angle + ANGLE_OFFSET
    tgt = MIN_PULSE + PULSE_RANGE * norm // 180
    curv = current_pulse.get(pin, MIN_PULSE + PULSE_RANGE // 2)
    
    if curv == tgt: # Já está na posição, não faz nada
        return
        
    step = (tgt - curv) // SMOOTH_STEPS
    if abs(step) < 1:
        step = -1 if (tgt - curv) < 0 else 1

    print(f"Movimento suave: Pino {pin} de {curv} para {tgt} em passos de {step}")
    
    current_val = curv
    for _ in range(SMOOTH_STEPS):
        current_val += step
        # Checagem para não ultrapassar o alvo
        if (step > 0 and current_val > tgt) or (step < 0 and current_val < tgt):
            break
        pwm_write(pin, current_val)
        time.sleep(STEP_DELAY)

    # Garante a posição final exata
    pwm_write(pin, tgt)
    print(f"Movimento concluído. Pino {pin} na posição final {tgt}")

def move_servo_direct(pin: int, angle: int):
    """Move um servo posicional diretamente para um ângulo."""
    pulse = MIN_PULSE + PULSE_RANGE * (angle + ANGLE_OFFSET) // 180
    pwm_write(pin, pulse)
    print(f"Movimento direto: Pino {pin} -> {angle}° (pulso {pulse})")

def move_servo_speed(pin: int, vel: int):
    """Define a velocidade de um servo de rotação contínua."""
    if SERVO_MAP.get(pin) != "cr":
        print(f"Aviso: Comando de velocidade ignorado para pino não contínuo {pin}.")
        return
    stop_pulse = STOP_PULSE_CR.get(pin, 150)
    gain = GAIN_CR.get(pin, 2)
    pulse = stop_pulse + vel * gain
    pwm_write(pin, pulse)

def center_all_servos():
    """Centraliza todos os servos com movimento suave."""
    print("Centralizando todos os servos...")
    for pin, servo_type in SERVO_MAP.items():
        if servo_type == "pos":
            move_servo_smooth(pin, 0)
        else:
            move_servo_speed(pin, 0)
    print("Centralização concluída.")

def send_raw(pin: int, value: int):
    """Envia um valor de pulso PWM bruto para um pino."""
    pwm_write(pin, value)
    print(f"Comando RAW: Pino {pin} <- {value}")

def run_cmd_line(cmd_line: str):
    """Processa e executa uma única linha de comando (estilo batch)."""
    parts = cmd_line.strip().split()
    if not parts or parts[0].startswith('#'):
        return

    cmd = parts[0]
    args = parts[1:]

    try:
        if cmd == "sleep":
            time.sleep(float(args[0]))
        elif cmd == "center":
            center_all_servos()
        elif cmd == "raw" and len(args) == 2:
            send_raw(int(args[0]), int(args[1]))
        elif cmd == "speed" and len(args) == 2:
            move_servo_speed(int(args[0]), int(args[1]))
        elif cmd == "direct" and len(args) == 2:
            move_servo_direct(int(args[0]), int(args[1]))
        elif cmd.isdigit() and len(args) == 1:
            pin = int(cmd)
            val = int(args[0])
            if SERVO_MAP.get(pin) == "pos":
                move_servo_smooth(pin, val)
            elif SERVO_MAP.get(pin) == "cr":
                move_servo_speed(pin, val)
        else:
            print(f"Comando desconhecido ou inválido: '{cmd_line}'")
    except (ValueError, IndexError) as e:
        print(f"Erro processando comando '{cmd_line}': {e}")

# ============================================================
# ENDPOINTS DA API
# ============================================================
@app.on_event("startup")
def startup_event():
    """Ação de inicialização do servidor."""
    print("API de Controle de Servos iniciada.")
    print("Use o endpoint /servo/init para preparar os servos.")

@app.post("/servo/init", status_code=200)
async def api_init_servos():
    """Inicializa o sistema de servos."""
    if is_initialized:
        return {"status": "warning", "message": "Servos já inicializados."}
    try:
        init_servo_system()
        return {"status": "success", "message": "Servos inicializados com sucesso."}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Falha crítica na inicialização: {e}")

@app.post("/servo/move", status_code=202)
async def api_move_servo(command: ServoCommand, background_tasks: BackgroundTasks):
    """Move um servo. Movimentos suaves são executados em segundo plano."""
    if not is_initialized:
        raise HTTPException(status_code=400, detail="Sistema não inicializado. Use /servo/init primeiro.")
    
    pin, value = command.pin, int(command.value)
    servo_type = SERVO_MAP[pin]

    if servo_type == "pos":
        if command.smooth:
            background_tasks.add_task(move_servo_smooth, pin, value)
            return {"status": "pending", "message": f"Movimento suave do pino {pin} para {value}° iniciado."}
        else:
            move_servo_direct(pin, value)
            return {"status": "success", "message": "Movimento direto executado."}
    else: # Contínuo
        move_servo_speed(pin, value)
        return {"status": "success", "message": f"Velocidade do pino {pin} definida para {value}."}

@app.post("/servo/center", status_code=202)
async def api_center_all(background_tasks: BackgroundTasks):
    """Centraliza todos os servos em segundo plano."""
    if not is_initialized:
        raise HTTPException(status_code=400, detail="Sistema não inicializado.")
    background_tasks.add_task(center_all_servos)
    return {"status": "pending", "message": "Centralização de todos os servos iniciada."}

@app.get("/servo/status")
async def api_get_status():
    """Retorna o status atual de todos os servos."""
    servos = []
    for pin, servo_type in SERVO_MAP.items():
        pulse = current_pulse.get(pin)
        val = None
        if pulse is not None:
            if servo_type == "pos":
                val = (pulse - MIN_PULSE) * 180 // PULSE_RANGE - ANGLE_OFFSET
            else:
                stop = STOP_PULSE_CR.get(pin, 150)
                gain = GAIN_CR.get(pin, 2)
                if gain != 0:
                    val = (pulse - stop) // gain
        servos.append(ServoStatus(pin=pin, type=servo_type, current_value=val, current_pulse=pulse))
    
    return {
        "system_initialized": is_initialized,
        "servos": servos
    }

@app.post("/servo/raw", status_code=200)
async def api_send_raw(pin: int, value: int):
    """Envia um valor PWM bruto diretamente para um pino."""
    if not is_initialized:
        raise HTTPException(status_code=400, detail="Sistema não inicializado.")
    if pin not in SERVO_MAP:
        raise HTTPException(status_code=400, detail=f"Pino {pin} não configurado.")
    send_raw(pin, value)
    return {"status": "success", f"Pino {pin} definido para o valor bruto {value}."}

@app.post("/servo/batch", status_code=202)
async def api_run_batch(batch: BatchCommand, background_tasks: BackgroundTasks):
    """Executa uma sequência de comandos em segundo plano."""
    if not is_initialized:
        raise HTTPException(status_code=400, detail="Sistema não inicializado.")

    def batch_task(commands: List[str]):
        print("=== INICIANDO BATCH ===")
        for line in commands:
            run_cmd_line(line)
        print("=== FIM DO BATCH ===")

    background_tasks.add_task(batch_task, batch.commands)
    return {"status": "pending", "message": f"{len(batch.commands)} comandos agendados para execução."}

@app.post("/servo/demo", status_code=202)
async def api_run_demo(background_tasks: BackgroundTasks):
    """Executa a demonstração padrão em segundo plano."""
    if not is_initialized:
        raise HTTPException(status_code=400, detail="Sistema não inicializado.")

    demo_sequence = [
        "2 45", "2 0", "2 -80", "2 0", "9 45", "2 45", "9 0",
        "21 45", "22 0", "9 45", "21 -45", "21 45", "22 90", "22 0",
        "center"
    ]
    
    def demo_task():
        print("=== DEMO PADRÃO INICIADO ===")
        for line in demo_sequence:
            run_cmd_line(line)
        print("=== FIM DEMO PADRÃO ===")

    background_tasks.add_task(demo_task)
    return {"status": "pending", "message": "Demonstração padrão iniciada."}

@app.post("/servo/demo/custom", status_code=202)
async def api_run_custom_demo(demo: DemoFile, background_tasks: BackgroundTasks):
    """Executa uma demonstração customizada de um arquivo de texto."""
    if not is_initialized:
        raise HTTPException(status_code=400, detail="Sistema não inicializado.")
    
    def custom_demo_task(content: str):
        print("=== INICIANDO CUSTOM DEMO ===")
        lines = content.strip().split('\n')
        limits = {}
        header_done = False
        
        for line in lines:
            line = line.strip()
            if not line or line.startswith('#'): continue

            if not header_done:
                try:
                    p_str, min_str, max_str = line.split(':')
                    pin, min_val, max_val = int(p_str), int(min_str), int(max_str)
                    limits[pin] = (min_val, max_val)
                    continue
                except (ValueError, IndexError):
                    header_done = True
            
            # Processamento de comando normal com aplicação de limites
            parts = line.split()
            if parts and parts[0].isdigit():
                try:
                    pin = int(parts[0])
                    val = int(parts[1])
                    if pin in limits:
                        min_v, max_v = limits[pin]
                        val = max(min_v, min(val, max_v))
                        line = f"{pin} {val}" # Atualiza a linha com o valor corrigido
                except (ValueError, IndexError):
                    pass # Linha não corresponde ao formato, executa como está
            
            run_cmd_line(line)
        print("=== FIM CUSTOM DEMO ===")

    background_tasks.add_task(custom_demo_task, demo.content)
    return {"status": "pending", "message": "Demonstração customizada iniciada."}


# ============================================================
# EXECUÇÃO
# ============================================================
if __name__ == "__main__":
    import uvicorn
    print("Iniciando Servo Control API v2.0.0")
    print("O movimento suave e as demos agora são executados em segundo plano para garantir o timing correto.")
    print("Acesse a documentação interativa em: http://0.0.0.0:8000/docs")
    uvicorn.run(app, host="0.0.0.0", port=8000)
