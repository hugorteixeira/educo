#!/bin/bash
# ============================================================
# Exemplos de uso da API de Controle de Servos
# Execute após iniciar a API com ./start_servo_api.sh
# ============================================================

BASE_URL="http://localhost:8000"

echo "=== EXEMPLOS DE USO DA SERVO API ==="
echo ""

# 1. Status da API
echo "1. Status da API:"
echo "curl $BASE_URL/"
curl -s "$BASE_URL/" | python3 -m json.tool
echo -e "\n"

# 2. Inicializar sistema
echo "2. Inicializar sistema de servos:"
echo "curl -X POST $BASE_URL/servo/init"
curl -s -X POST "$BASE_URL/servo/init" | python3 -m json.tool
echo -e "\n"

# 3. Status dos servos
echo "3. Status atual dos servos:"
echo "curl $BASE_URL/servo/status"
curl -s "$BASE_URL/servo/status" | python3 -m json.tool
echo -e "\n"

# 4. Mover servo posicional (suave)
echo "4. Mover servo posicional pino 2 para 45°:"
echo 'curl -X POST $BASE_URL/servo/move -H "Content-Type: application/json" -d {"pin":2,"value":45,"smooth":true}'
curl -s -X POST "$BASE_URL/servo/move" \
     -H "Content-Type: application/json" \
     -d '{"pin":2,"value":45,"smooth":true}' | python3 -m json.tool
echo -e "\n"

# 5. Mover servo posicional (direto)
echo "5. Mover servo posicional pino 9 para -30° (direto):"
echo 'curl -X POST $BASE_URL/servo/move -H "Content-Type: application/json" -d {"pin":9,"value":-30,"smooth":false}'
curl -s -X POST "$BASE_URL/servo/move" \
     -H "Content-Type: application/json" \
     -d '{"pin":9,"value":-30,"smooth":false}' | python3 -m json.tool
echo -e "\n"

# 6. Centralizar todos
echo "6. Centralizar todos os servos:"
echo "curl -X POST $BASE_URL/servo/center"
curl -s -X POST "$BASE_URL/servo/center" | python3 -m json.tool
echo -e "\n"

# 7. Comando RAW
echo "7. Comando RAW (pino 2, valor PWM 150):"
echo "curl -X POST '$BASE_URL/servo/raw?pin=2&value=150'"
curl -s -X POST "$BASE_URL/servo/raw?pin=2&value=150" | python3 -m json.tool
echo -e "\n"

# 8. Batch de comandos
echo "8. Sequência de comandos (batch):"
BATCH_DATA='{
  "commands": [
    "2 45",
    "sleep 0.5", 
    "9 30",
    "sleep 0.5",
    "21 -45", 
    "sleep 1",
    "center"
  ]
}'
echo "curl -X POST $BASE_URL/servo/batch -H 'Content-Type: application/json' -d '$BATCH_DATA'"
curl -s -X POST "$BASE_URL/servo/batch" \
     -H "Content-Type: application/json" \
     -d "$BATCH_DATA" | python3 -m json.tool
echo -e "\n"

# 9. Demo padrão
echo "9. Executar demo padrão:"
echo "curl -X POST $BASE_URL/servo/demo"
curl -s -X POST "$BASE_URL/servo/demo" | python3 -m json.tool
echo -e "\n"

# 10. Demo customizado
echo "10. Demo customizado:"
DEMO_CONTENT=$(cat demo_exemplo.txt 2>/dev/null || echo "# Demo exemplo
2 45
sleep 1
2 0
sleep 1  
center")

DEMO_DATA=$(cat << EOF
{
  "content": "$DEMO_CONTENT"
}
EOF
)

echo "curl -X POST $BASE_URL/servo/demo/custom -H 'Content-Type: application/json' -d '...' "
curl -s -X POST "$BASE_URL/servo/demo/custom" \
     -H "Content-Type: application/json" \
     -d "$DEMO_DATA" | python3 -m json.tool
echo -e "\n"

echo "=== EXEMPLO PYTHON CLIENT ==="
cat << 'EOF'
import requests
import json
import time

# Cliente Python exemplo
class ServoAPI:
    def __init__(self, base_url="http://localhost:8000"):
        self.base_url = base_url
    
    def init(self):
        """Inicializa sistema de servos"""
        response = requests.post(f"{self.base_url}/servo/init")
        return response.json()
    
    def move(self, pin, value, smooth=True):
        """Move um servo"""
        data = {"pin": pin, "value": value, "smooth": smooth}
        response = requests.post(
            f"{self.base_url}/servo/move", 
            json=data
        )
        return response.json()
    
    def center(self):
        """Centraliza todos os servos"""
        response = requests.post(f"{self.base_url}/servo/center")
        return response.json()
    
    def status(self):
        """Status dos servos"""
        response = requests.get(f"{self.base_url}/servo/status")
        return response.json()
    
    def batch(self, commands):
        """Executa sequência de comandos"""
        data = {"commands": commands}
        response = requests.post(
            f"{self.base_url}/servo/batch",
            json=data
        )
        return response.json()

# Exemplo de uso
if __name__ == "__main__":
    api = ServoAPI()
    
    # Inicializar
    print("Inicializando...", api.init())
    
    # Mover servos
    print("Movendo pino 2...", api.move(2, 45))
    time.sleep(1)
    
    print("Movendo pino 9...", api.move(9, -30))  
    time.sleep(1)
    
    # Centralizar
    print("Centralizando...", api.center())
    
    # Status
    print("Status:", api.status())
EOF

echo ""
echo "=== DOCUMENTAÇÃO INTERATIVA ==="
echo "Acesse http://localhost:8000/docs para interface Swagger"
echo "Acesse http://localhost:8000/redoc para documentação ReDoc"
echo ""
