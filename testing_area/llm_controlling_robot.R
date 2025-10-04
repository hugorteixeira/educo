library(httr)
library(jsonlite)
library(base64enc)

source("llm_functions.R")

ALLOWED_URL_PREFIXES <- c(
  "http://localhost:8000/",
  "http://127.0.0.1:8000/"
)

# Ensure your OpenAI key is available in the environment before running.
# The robot API controller must be running and the camera online.

frame_url <- "http://localhost:8000/camera/frame?max_width=640&jpeg_quality=30"  # camera snapshot
status_url <- "http://localhost:8000/robot/status"                               # servo state
openapi_url <- "http://localhost:8000/openapi.json"                              # OpenAPI schema
api_base_url <- "http://localhost:8000"                                          # API root

output_dir <- "~/robot_session"
iterations <- 10

tools_list <- load_api_functions(openapi_url, "openai", allowed_prefixes = ALLOWED_URL_PREFIXES)

tool_history <- data.frame(
  timestamp = as.POSIXct(character()),
  function_name = character(),
  pin = numeric(),
  angle = numeric(),
  stringsAsFactors = FALSE
)

last_state <- NULL

prompt <- "You are a robot with vision. You can see the world and know the current position of servos. You can use function calling to move four servos (2, 9, 21, and 22).

Use the servo/move tool within these ranges:

- Servo 2 (Claw): -70 (open) to 45 (closed)
- Servo 9 (Reach): 0 (retracted) to 90 (extended)
- Servo 21 (Base): -45 (right) to 90 (left)
- Servo 22 (Lift): 0 (low) to 90 (high)

Mission:

1. You will have several turns to accomplish your mission.
2. Move the servos to accomplish your goal.
3. Move at least 20 points each time—small moves are ignored.
4. Move the servos as many times as needed."

prompt_goal <- "Center the servos"

for (i in seq(iterations)) {
  status <- get_robot_status(status_url)
  status <- status$servo_system$servos
  status_text <- paste(paste0("pin=", status$pin, ",value=", status$value), collapse = "; ")

  image <- get_robot_frame(frame_url, output_dir, allowed_prefixes = ALLOWED_URL_PREFIXES)

  response <- send_message(prompt,
                           add = paste(prompt_goal, "current servo position (change these):", status_text),
                           add_img = image[[1]],
                           service = "openai",
                           model = "gpt-4.1-mini",
                           tools = tools_list)

  executed_tools <- run_tool_calls(response, openapi_url, api_base_url, allowed_prefixes = ALLOWED_URL_PREFIXES)
  monitor_tools()
}
