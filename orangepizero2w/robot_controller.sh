#!/usr/bin/env bash
# ============================================================
# Controle de Servos – Orange Pi Zero 2W / WiringOP
#   • tipo pos  → ângulo  –90…+90
#   • tipo cr   → velocidade –100…+100
#   – demo, batch, record/play, raw, etc.
#   – configurando PWM por PINO  (sem “Usage: gpio …”)
# ============================================================

######################### CONFIGURAÇÃO ########################
SERVO_MAP="2:pos 9:pos 21:pos 22:pos"

MIN_PULSE=50          # 0,50 ms
MAX_PULSE=250         # 2,50 ms
ANGLE_MIN=-180
ANGLE_MAX=+180
ANGLE_OFFSET=90

declare -A STOP_PULSE_CR GAIN_CR
STOP_PULSE_CR[2]=140
GAIN_CR[2]=2

PWM_FREQ=192          # clock divisor
PWM_RANGE=2000        # 1 unid = 10 µs

SMOOTH_STEPS=20
STEP_DELAY=0.02
################################################################

PULSE_RANGE=$((MAX_PULSE - MIN_PULSE))

# ---- arrays de pinos e tipos ----
declare -a PINS
declare -A type
for pair in $SERVO_MAP; do
    p=${pair%%:*}; t=${pair##*:}
    PINS+=( "$p" ); type[$p]=$t
done
SERVO_PINS="${PINS[*]}"

declare -A cur           # último pulso
declare -a recording     # buffer para record/play

##################### FUNÇÕES BÁSICAS ##########################

pwm_write() {                     # pwm_write <pin> <valor>
    local p=$1 v=$2
    (( v < 0 )) && v=0
    (( v > PWM_RANGE )) && v=$PWM_RANGE
    gpio pwm "$p" "$v"
    cur[$p]=$v
}

config_pwm_pin() {
    local p=$1
    gpio mode "$p" pwm 2>/dev/null || true  # ignora erro
    gpio pwm-ms "$p"
    gpio pwmc  "$p" "$PWM_FREQ"
    gpio pwmr  "$p" "$PWM_RANGE"
}

init_servo() {
    echo "Inicializando…"

    # pulso de repouso para cada tipo
    local centre=$((MIN_PULSE + PULSE_RANGE/2))

    for p in $SERVO_PINS; do
        # 1) coloca em PWM e já configura clock e range
        config_pwm_pin "$p"

        # 2) valor inicial = repouso (NÃO zero!)
        if [[ ${type[$p]} == pos ]]; then
            pwm_write "$p" "$centre"           # 1,5 ms
        else
            pwm_write "$p" "${STOP_PULSE_CR[$p]:-150}"
        fi
    done

    # 3) espera 25 ms (um período) para que o 1º pulso “bom” seja emitido
    sleep 0.025

    echo "Servos prontos."
}

##################### POSICIONAIS ##############################
move_smooth() {          # <pin> <angulo>
    local p=$1 ang=$2
    [[ $ang =~ ^-?[0-9]+$ && $ang -ge $ANGLE_MIN && $ang -le $ANGLE_MAX ]] \
        || { echo "Ângulo deve ser $ANGLE_MIN…$ANGLE_MAX"; return 1; }
    local norm=$(( ang + ANGLE_OFFSET ))
    local tgt=$(( MIN_PULSE + PULSE_RANGE * norm / 180 ))
    local curv=${cur[$p]:-$((MIN_PULSE + PULSE_RANGE/2))}
    local step=$(((tgt - curv)/SMOOTH_STEPS))
    (( ${step#-} < 1 )) && step=$(( step<0 ? -1 : 1 ))
    for ((i=0;i<SMOOTH_STEPS;i++)); do
        curv=$((curv+step)); pwm_write "$p" "$curv"; sleep "$STEP_DELAY"
    done
    pwm_write "$p" "$tgt"
}

move_direct() {          # <pin> <angulo>
    local p=$1 ang=$2
    local pulse=$(( MIN_PULSE + PULSE_RANGE * (ang+ANGLE_OFFSET) / 180 ))
    pwm_write "$p" "$pulse"
    echo "Direto: $p ← $ang° (pulso $pulse)"
}

####################### CONTÍNUOS ##############################
move_speed() {           # <pin> <vel -100..100>
    local p=$1 vel=$2
    [[ $vel =~ ^-?[0-9]+$ && $vel -ge -100 && $vel -le 100 ]] \
        || { echo "Velocidade -100…+100"; return 1; }
    local pulse=$(( STOP_PULSE_CR[$p] + vel * GAIN_CR[$p] ))
    pwm_write "$p" "$pulse"
}

####################### UTILITÁRIOS ############################
send_raw()   { pwm_write "$1" "$2"; echo "RAW $1 ← $2"; }
center_all() { for p in $SERVO_PINS; do [[ ${type[$p]} == pos ]] && move_smooth "$p" 0 || move_speed "$p" 0; done; }

run_cmd() {                # executa 1 linha de batch
    local cmd=$1; shift
    case $cmd in
        ''|\#*) ;;            # vazio ou comentário
        sleep) sleep "${1:-0}" ;;
        center) center_all ;;
        raw)   send_raw   "$@" ;;
        speed) move_speed "$@" ;;
        direct) move_direct "$@" ;;
        *)
            p=$cmd; val=$1
            [[ -z ${type[$p]} ]] && { echo "Pino inválido"; return; }
            [[ ${type[$p]} == pos ]] && move_smooth "$p" "$val" || move_speed "$p" "$val"
            ;;
    esac
}

run_batch() {               # <arquivo> | stdin
    while IFS= read -r line; do
        run_cmd $line
    done < "${1:-/dev/stdin}"
}

######################## DEMO ##################################
demo() {
    local -a sequence=(
        # ---------- exemplo ----------
        "2 45"          # pino 5 → −30°
	"2 0"
	"2 45"
        "9 45"
	"9 0"
	"9 -45"
	"9 0"
	"9 45"
        "21 90"
	"22 45"
	"22 -45"
	"22 0"
	"22 -45"
	"center"
        # ---------- fim do exemplo ---
    )

    echo "=== DEMO PERSONALIZADA ==="
    for line in "${sequence[@]}"; do
        run_cmd $line
    done
    echo "=== FIM DEMO ==="
}
##################### INTERATIVO ###############################
interactive() {
    echo "Comandos: ang | speed | raw | direct | record | play | save | load | demo | center | q"
    while true; do
        read -r -p "> " cmd a b
        case $cmd in
            q|quit|exit) break ;;
            demo) demo ;;
            center) center_all ;;
            record)
                echo "(gravando, stoprec para parar)"
                recording=()
                while read -r -p "(rec) " line; do
                    [[ $line == stoprec ]] && break
                    recording+=( "$line" )
                    run_cmd $line
                done ;;
            play) printf '%s\n' "${recording[@]}" | run_batch ;;
            save) printf '%s\n' "${recording[@]}" > "${a:-macro.txt}" ;;
            load) mapfile -t recording < "$a" 2>/dev/null || echo "não achei $a" ;;
            *) run_cmd "$cmd" "$a" "$b" ;;
        esac
    done
}

######################## MAIN ##################################
command -v gpio >/dev/null || { echo "'gpio' não encontrado!"; exit 1; }

case $1 in
    demo)      init_servo; demo ;;
    smooth)    init_servo; move_smooth "$2" "$3" ;;
    direct)    init_servo; move_direct "$2" "$3" ;;
    speed)     init_servo; move_speed  "$2" "$3" ;;
    batch)     init_servo; run_batch  "$2" ;;
    interactive|i|'') init_servo; interactive ;;
    *)
        echo "Uso: $0 [interactive|demo|smooth p a|direct p a|speed p v|batch arq]"
        exit 1 ;;
esac
cleanup() { :; }
