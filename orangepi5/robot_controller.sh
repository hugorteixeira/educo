#!/bin/bash

# Configurações
SERVO_PINS="0 2 5 8"  # Pinos dos servos
MIN_PULSE=100
MAX_PULSE=200
PULSE_RANGE=$((MAX_PULSE - MIN_PULSE))
PWM_FREQ=192
PWM_RANGE=2000
SMOOTH_STEPS=20
STEP_DELAY=0.02

# Posições atuais dos servos (variáveis simples)
current_pulse_0=150
current_pulse_2=150
current_pulse_5=150
current_pulse_8=150

init_servo() {
    echo "Inicializando servos..."
    gpio pwm-ms
    gpio pwmc $PWM_FREQ
    gpio pwmr $PWM_RANGE
    
    # Inicializa todos os servos
    for pin in $SERVO_PINS; do
        gpio mode $pin pwm
        # Posição central
        center_pulse=$((MIN_PULSE + PULSE_RANGE/2))
        gpio pwm $pin $center_pulse
        
        # Atualiza variável de posição correspondente
        case $pin in
            0) current_pulse_0=$center_pulse ;;
            2) current_pulse_2=$center_pulse ;;
            5) current_pulse_5=$center_pulse ;;
            8) current_pulse_8=$center_pulse ;;
        esac
        
        echo "Servo no pino $pin inicializado na posição central"
    done
    sleep 1
}

# Movimento suave para servo específico
move_smooth() {
    local servo_pin=$1
    local target_angle=$2
    local target_pulse step_size i current_pulse
    
    # Validação do ângulo
    if [ "$target_angle" -lt 0 ] || [ "$target_angle" -gt 180 ]; then
        echo "Erro: Ângulo deve ser entre 0 e 180"
        return 1
    fi
    
    target_pulse=$((MIN_PULSE + PULSE_RANGE * target_angle / 180))
    
    # Pega posição atual do servo correspondente
    case $servo_pin in
        0) current_pulse=$current_pulse_0 ;;
        2) current_pulse=$current_pulse_2 ;;
        5) current_pulse=$current_pulse_5 ;;
        8) current_pulse=$current_pulse_8 ;;
        *) echo "Erro: Pino $servo_pin não configurado"; return 1 ;;
    esac
    
    echo "Movendo servo pino $servo_pin para angulo: ${target_angle} graus (pulse: $target_pulse)"
    
    # Calcula o tamanho do passo
    step_size=$(((target_pulse - current_pulse) / SMOOTH_STEPS))
    
    # Se o passo for muito pequeno, move direto
    if [ "${step_size#-}" -lt 1 ]; then
        gpio pwm $servo_pin $target_pulse
        # Atualiza posição atual
        case $servo_pin in
            0) current_pulse_0=$target_pulse ;;
            2) current_pulse_2=$target_pulse ;;
            5) current_pulse_5=$target_pulse ;;
            8) current_pulse_8=$target_pulse ;;
        esac
        return 0
    fi
    
    echo "Movendo de $current_pulse para $target_pulse (passo: $step_size)"
    
    # Move gradualmente
    i=0
    while [ $i -lt $SMOOTH_STEPS ]; do
        current_pulse=$((current_pulse + step_size))
        gpio pwm $servo_pin $current_pulse
        sleep $STEP_DELAY
        i=$((i + 1))
    done
    
    # Garante posição final exata
    gpio pwm $servo_pin $target_pulse
    
    # Atualiza posição atual correspondente
    case $servo_pin in
        0) current_pulse_0=$target_pulse ;;
        2) current_pulse_2=$target_pulse ;;
        5) current_pulse_5=$target_pulse ;;
        8) current_pulse_8=$target_pulse ;;
    esac
    
    echo "Movimento completo para servo pino $servo_pin"
}

# Movimento direto (brusco) para servo específico
move_direct() {
    local servo_pin=$1
    local angle=$2
    local pulse=$((MIN_PULSE + PULSE_RANGE * angle / 180))
    
    gpio pwm $servo_pin $pulse
    
    # Atualiza posição atual
    case $servo_pin in
        0) current_pulse_0=$pulse ;;
        2) current_pulse_2=$pulse ;;
        5) current_pulse_5=$pulse ;;
        8) current_pulse_8=$pulse ;;
    esac
    
    echo "Movimento direto servo pino $servo_pin para ${angle} graus"
}

cleanup() {
    echo "Parando servos..."
    for pin in $SERVO_PINS; do
        gpio pwm $pin 0
    done
    exit 0
}

# Modo Demo - Sequência específica
demo_mode() {
    echo "=== MODO DEMO - Iniciando sequência ==="
    echo "Aguarde 2 segundos para começar..."
    sleep 2
    
    echo "--- Fase 1: Servo GPIO 0 ---"
    echo "GPIO 2: 90 graus -> 180 graus"
    move_smooth 0 90
    sleep 1
    move_smooth 0 180
    sleep 1
    
    echo "GPIO 8: 180 graus -> 90 graus"
    move_smooth 2 90
    sleep 1
    
    echo "--- Fase 2: Servo GPIO 2 ---"
    echo "GPIO 2: 0 graus -> 90 graus"
    move_smooth 2 0
    sleep 1
    move_smooth 5 90
    sleep 1
    
    echo "GPIO 2: 90 graus -> 180 graus"
    move_smooth 5 180
    sleep 1
    
    echo "GPIO 2: 180 graus -> 150 graus"
    move_smooth 8 150
    sleep 1
    
    echo "--- Fase 3: Servo GPIO 8 ---"
    echo "GPIO 8: 90 graus -> 180 graus"
    move_smooth 8 90
    sleep 1
    move_smooth 5 180
    sleep 1
    
    echo "GPIO 8: 180 graus -> 90 graus"
    move_smooth 2 90
    sleep 1
    
    echo "GPIO 8: 90 graus -> 0 graus"
    move_smooth 0 0
    sleep 1
    
    echo "=== DEMO CONCLUÍDO ==="
}

# Controle interativo
interactive_control() {
    echo "=== Controle Interativo ==="
    echo "Comandos disponíveis:"
    echo "  <pino> <angulo>  - Move servo (ex: 0 90)"
    echo "  demo            - Executa modo demo"
    echo "  center          - Centraliza todos os servos"
    echo "  q               - Sair"
    echo ""
    
    while true; do
        printf "Comando: "
        read input
        
        case $input in
            q|quit|exit)
                break
                ;;
            demo)
                demo_mode
                ;;
            center)
                echo "Centralizando todos os servos..."
                for pin in $SERVO_PINS; do
                    move_smooth $pin 90
                done
                ;;
            '')
                echo "Digite um comando!"
                ;;
            *)
                # Verifica se é comando pino ângulo
                set -- $input
                if [ $# -eq 2 ]; then
                    pin=$1
                    angle=$2
                    
                    # Verifica se pino é válido
                    valid_pin=0
                    for valid in $SERVO_PINS; do
                        if [ "$pin" = "$valid" ]; then
                            valid_pin=1
                            break
                        fi
                    done
                    
                    if [ $valid_pin -eq 0 ]; then
                        echo "Erro: Pino deve ser um de: $SERVO_PINS"
                        continue
                    fi
                    
                    # Verifica se ângulo é número válido
                    if echo "$angle" | grep -q '^[0-9]\+'

# Trap para cleanup
trap cleanup INT TERM

# Verifica se gpio está disponível
if ! command -v gpio > /dev/null 2>&1; then
    echo "Erro: comando 'gpio' não encontrado!"
    echo "Instale o WiringOP: sudo apt install wiringpi-orangepi"
    exit 1
fi

# Menu principal
case "$1" in
    demo)
        init_servo
        demo_mode
        ;;
    interactive|i|"")
        init_servo
        interactive_control
        ;;
    direct)
        if [ $# -lt 3 ]; then
            echo "Erro: Uso correto: $0 direct <pino> <angulo>"
            echo "Exemplo: $0 direct 2 90"
            exit 1
        fi
        init_servo
        move_direct $2 $3
        ;;
    smooth)
        if [ $# -lt 3 ]; then
            echo "Erro: Uso correto: $0 smooth <pino> <ângulo>"
            echo "Exemplo: $0 smooth 2 90"
            exit 1
        fi
        init_servo
        move_smooth $2 $3
        ;;
    *)
        echo "Uso: $0 [demo|interactive|direct <pino> <angulo>|smooth <pino> <angulo>]"
        echo ""
        echo "  demo                    - Executa sequência de demonstração"
        echo "  interactive            - Controle interativo (padrão)"
        echo "  direct <pino> <angulo> - Move diretamente servo para angulo"
        echo "  smooth <pino> <angulo> - Move suavemente servo para angulo"
        echo ""
        echo "Pinos disponíveis: $SERVO_PINS"
        echo ""
        echo "Exemplos:"
        echo "  sudo bash $0                # Modo interativo"
        echo "  sudo bash $0 demo           # Executa modo demo"
        echo "  sudo bash $0 smooth 2 90    # Move servo pino 2 para 90 graus"
        echo "  sudo bash $0 direct 0 180   # Move servo pino 0 para 180 graus"
        exit 1
        ;;
esac

cleanup; then
                        if [ "$angle" -ge 0 ] && [ "$angle" -le 180 ]; then
                            move_smooth $pin $angle
                        else
                            echo "Erro: Angulo deve ser entre 0 e 180"
                        fi
                    else
                        echo "Erro: Angulo deve ser um numero"
                    fi
                else
                    echo "Formato: <pino> <angulo> ou 'demo' ou 'center' ou 'q'"
                    echo "Exemplo: 2 90"
                fi
                ;;
        esac
    done
}

# Trap para cleanup
trap cleanup INT TERM

# Verifica se gpio está disponível
if ! command -v gpio > /dev/null 2>&1; then
    echo "Erro: comando 'gpio' não encontrado!"
    echo "Instale o WiringOP: sudo apt install wiringpi-orangepi"
    exit 1
fi

# Menu principal
case "$1" in
    test)
        init_servo
        test_movement
        ;;
    interactive|i|"")
        init_servo
        interactive_control
        ;;
    direct)
        init_servo
        move_direct ${2:-90}
        ;;
    smooth)
        init_servo
        move_smooth ${2:-90}
        ;;
    *)
        echo "Uso: $0 [test|interactive|direct <ângulo>|smooth <ângulo>]"
        echo ""
        echo "  test        - Executa sequência de teste suave"
        echo "  interactive - Controle interativo (padrão)"
        echo "  direct <n>  - Move diretamente para ângulo n"
        echo "  smooth <n>  - Move suavemente para ângulo n"
        echo ""
        echo "Exemplos:"
        echo "  sudo bash $0              # Modo interativo"
        echo "  sudo bash $0 smooth 90    # Move suave para 90°"
        echo "  sudo bash $0 test         # Executa teste"
        exit 1
        ;;
esac

cleanup
