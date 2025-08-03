library(httr)
library(jsonlite)
library(base64enc)

source("llm_functions.R")

ALLOWED_URL_PREFIXES <- c(
  "http://localhost:8000/",
  "http://127.0.0.1:8000/"
)

# be sure to set your openai key in your env
# robot_api_controller.sh must be running
# esp32 or any other camera must also be running
#
# results are terrible even with o3. fine tuning vla model will be mandatory.

url = "http://localhost:8000/camera/frame?max_width=640&jpeg_quality=30" #camera for the llm to see
url_status = "http://localhost:8000/robot/status" #for the llm know the servos position
url_openapi = "http://localhost:8000/openapi.json" #openapi of the robot_controller.sh api
url_api = "http://localhost:8000" #same

diretorio = "~/teste"
inter = 10

tools_list <- carregar_funcoes_api(url_openapi,"openai", prefixos_permitidos = ALLOWED_URL_PREFIXES)

historico_tools <- data.frame(
  timestamp = as.POSIXct(character()),
  function_name = character(),
  pin = numeric(),
  angle = numeric(),
  stringsAsFactors = FALSE
)

ultimo_estado <- NULL


prompt <- "You are robot with vision. You can see the world. You know the current position of servos. You can use function calling to move 4 servos (2, 9, 21, and 22) and interact with the world. 

Use servo/move tool in the following ranges:

- Servo 2 (Claw): -70 (negative open) to 45 (positive closed)
- Servo 9 (Reaching Arm): 0 (retracted) to 90 (streched)
- Servo 21 (Rotating Base): 90 (positive goes to left) to -45 (negative goes to right)
- Servo 22 (Elevating Arm): 0 (lowered) to 90 (elevated)

Mission:

1. You will have several turns to accomplish your mission.
2. Move the servos to accomplish your goal.
3. Move at least 20 points each time, the servos are not very sensitive.
4. You can move the servos how many times do you want."

prompt_goal <- "this is your goal: just follow my finger"
prompt_goal <- "there is a plastic cup in front of you, move it off the table. when finished, say 'mission acomplished'"
prompt_goal <- "move to the right and then to the left"
prompt_goal <- "use the move servo tool to change each servo (pin) position (value) to a different value in the servo range"
prompt_goal <- "center the servos"

for(i in seq(inter)){
  status <- obter_status_robo(url_status)
  status <- status$servo_system$servos
  status <- paste(paste0("pin=", status$pin, ",value=", status$value), collapse = "; ")

  imagem <- obter_frame_robo(url,diretorio, prefixos_permitidos = ALLOWED_URL_PREFIXES)
  
  resposta <- enviar_msg(prompt,  add = paste(prompt_goal,"current servo position (change this): ", status), add_img = imagem[[1]], service = "openai", modelo = "gpt-4.1-mini",tools = tools_list)
  
  tools_usadas <- executar_resposta_tools(resposta,url_openapi,url_api, prefixos_permitidos = ALLOWED_URL_PREFIXES)
  monitorar_tools()
}

