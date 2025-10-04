# app.R
# Requirements:
# install.packages(c("shiny", "bslib", "httr2", "jsonlite"))

library(shiny)
library(bslib)
library(httr2)
library(jsonlite)

# -----------------------------------------------------------------------------
# Configuration helpers
# -----------------------------------------------------------------------------
`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0 || (length(x) == 1 && (is.na(x) || identical(x, "")))) y else x
}

strip_comment <- function(line) {
  # Remove everything after ';' or '#' unless escaped
  sub("[;#].*$", "", line, perl = TRUE)
}

read_robot_config <- function(path) {
  if (!file.exists(path)) {
    warning(sprintf("Configuration file '%s' not found. Using defaults.", path))
    return(list())
  }
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  cfg <- list()
  section <- NULL
  for (raw in lines) {
    line <- trimws(strip_comment(raw))
    if (line == "") next
    if (startsWith(line, "[") && endsWith(line, "]")) {
      section <- tolower(substr(line, 2, nchar(line) - 1))
      if (!nzchar(section)) section <- NULL
      if (!is.null(section) && is.null(cfg[[section]])) cfg[[section]] <- list()
      next
    }
    if (is.null(section)) next
    parts <- strsplit(line, "=", fixed = TRUE)[[1]]
    if (length(parts) >= 2) {
      key <- trimws(parts[1])
      value <- trimws(paste(parts[-1], collapse = "="))
      cfg[[section]][[key]] <- value
    }
  }
  cfg
}

cfg_get <- function(cfg, section, key, default = NULL) {
  section <- tolower(section)
  if (!is.null(cfg[[section]]) && !is.null(cfg[[section]][[key]])) {
    return(cfg[[section]][[key]])
  }
  default
}

cfg_get_num <- function(cfg, section, key, default, as_integer = FALSE) {
  val <- cfg_get(cfg, section, key, NULL)
  if (is.null(val) || !nzchar(val)) return(default)
  num <- suppressWarnings(as.numeric(val))
  if (is.na(num)) return(default)
  if (as_integer) return(as.integer(round(num)))
  num
}

# Determine configuration path
cfg_path <- Sys.getenv("ROBOT_CFG_PATH")
if (!nzchar(cfg_path)) {
  cfg_path <- file.path(getwd(), "robot_api", "robot_api.cfg")
}
cfg <- read_robot_config(cfg_path)

api_host <- cfg_get(cfg, "server", "api_host", "0.0.0.0")
api_port <- cfg_get_num(cfg, "server", "api_port", 8000, as_integer = TRUE)
api_base <- cfg_get(cfg, "server", "api_base_url", "")
if (!nzchar(api_base)) {
  host_public <- if (api_host %in% c("0.0.0.0", "::")) "127.0.0.1" else api_host
  api_base <- sprintf("http://%s:%s", host_public, api_port)
}

BASE_URL <- gsub("/+$", "", api_base)
AUTO_MS <- cfg_get_num(cfg, "ui", "status_refresh_ms", 2000, as_integer = TRUE)
KEY_REPEAT_MS <- cfg_get_num(cfg, "ui", "key_repeat_ms", 120, as_integer = TRUE)
DEFAULT_STEP_PCT <- cfg_get_num(cfg, "ui", "default_step_pct", 0.15)
PART_STEP_PCT <- list(
  claw   = cfg_get_num(cfg, "ui", "claw_step_pct", DEFAULT_STEP_PCT),
  height = cfg_get_num(cfg, "ui", "height_step_pct", DEFAULT_STEP_PCT),
  base   = cfg_get_num(cfg, "ui", "base_step_pct", DEFAULT_STEP_PCT),
  reach  = cfg_get_num(cfg, "ui", "reach_step_pct", DEFAULT_STEP_PCT)
)

# -----------------------------------------------------------------------------
# Theme and CSS
# -----------------------------------------------------------------------------
neo_theme <- bs_theme(
  version = 5,
  bg = "#0b0f14",
  fg = "#e6ffe6",
  primary = "#00e676",
  secondary = "#00c853",
  base_font = font_google("Rajdhani", local = TRUE),
  heading_font = font_google("Orbitron", local = TRUE)
)

hitech_css <- HTML("
:root {
  --bg: #0b0f14;
  --bg2: #0f141b;
  --fg: #d6ffd6;
  --fg-dim: #a2dba2;
  --primary: #00e676;
  --primary-2: #00c853;
  --accent: #00ffc3;
  --danger: #ff5252;
  --card-border: #102a19;
}
body { background: var(--bg); color: var(--fg); }
.hitech-title {
  font-family: 'Orbitron', sans-serif;
  letter-spacing: 1.5px;
  text-transform: uppercase;
  color: var(--primary);
  text-shadow: 0 0 8px rgba(0,230,118,0.4);
}
.neo-card {
  background: linear-gradient(180deg, #0d1117 0%, #0b0f14 100%);
  border: 1px solid var(--card-border);
  border-radius: 14px;
  padding: 18px;
  box-shadow: inset 0 0 0 1px rgba(0, 230, 118, 0.08),
              0 8px 20px rgba(0, 0, 0, 0.6);
  margin-bottom: 18px;
}
.neo-card h4, .neo-card h5 { color: var(--primary); }
.hr-soft {
  border: 0; height: 1px; background: linear-gradient(90deg, rgba(0,230,118,0), rgba(0,230,118,.3), rgba(0,230,118,0));
  margin: 14px 0 10px 0;
}
.camera-frame {
  width: 100%;
  aspect-ratio: 16 / 9;
  background: radial-gradient(ellipse at center, #0d131a 0, #0b0f14 60%);
  border: 1px solid var(--card-border);
  border-radius: 14px;
  display: flex; align-items:center; justify-content:center;
  overflow: hidden;
}
.camera-frame img { width: 100%; height: 100%; object-fit: contain; filter: saturate(1.05) contrast(1.03); }
.badge-soft {
  display:inline-block; padding: 3px 8px; border-radius: 999px; font-weight:700; font-size:.8rem;
  color: #001a10; background: linear-gradient(180deg, #00e676, #00c853);
}
.badge-ghost {
  display:inline-block; padding: 3px 8px; border-radius: 999px; font-weight:700; font-size:.8rem;
  color: var(--primary); border: 1px solid rgba(0, 230, 118, .35); background: rgba(0, 230, 118, .06);
}
.muted { color: var(--fg-dim); }
pre.code {
  background: #0f141b; color: #b6ffc7; border: 1px solid #173b24; border-radius: 12px; padding: 12px; max-height: 360px; overflow:auto;
  text-shadow: 0 0 3px rgba(0,230,118,.15);
}
.small-note { font-size: .88rem; color: var(--fg-dim); }
.header-bar { display:flex; align-items:center; justify-content:space-between; gap:16px; margin-bottom: 12px; }
.app-title { font-size: 1.5rem; font-weight: 800; letter-spacing: 1px; }
.footer-note { color: var(--fg-dim); font-size: .85rem; text-align:center; margin-top: 10px; }

/* Virtual keypad */
.keypad {
  display:grid; grid-template-columns: repeat(3, 64px); grid-auto-rows: 64px; gap: 10px; justify-content:center; user-select:none;
}
.keybtn {
  display:flex; align-items:center; justify-content:center;
  border-radius:12px; border:1px solid rgba(0,230,118,.35);
  background: rgba(0,230,118,.08); color: var(--primary);
  font-weight:800; font-size:1rem; letter-spacing:.5px; cursor:pointer;
  box-shadow: inset 0 0 0 1px rgba(0,230,118,.06), 0 4px 12px rgba(0,0,0,.45);
  touch-action: none;
}
.keybtn:hover { filter: brightness(1.08); }
.keybtn.active {
  background: linear-gradient(180deg, #00e676, #00c853);
  color: #001a10; box-shadow: 0 0 12px rgba(0,230,118,.7), inset 0 -3px 8px rgba(0,0,0,.35);
}
.keypad .spacer { visibility:hidden; }
.ctrl-row { display:flex; gap:18px; flex-wrap:wrap; justify-content:center; }
.map-chip {
  display:inline-flex; gap:6px; align-items:center; padding: 4px 10px; border-radius:999px;
  border:1px solid rgba(0,230,118,.35); color: var(--primary); background: rgba(0,230,118,.06);
  font-weight:700; font-size:.9rem;
}
.ctrl-actions { display:flex; gap:10px; justify-content:center; margin-top: 8px; }
.hitech-btn {
  background: linear-gradient(180deg, #00e676, #00c853);
  color: #001a10 !important;
  border: 0; border-radius: 10px; padding: 8px 14px;
  font-weight: 800; letter-spacing: .6px; text-transform: uppercase;
  box-shadow: 0 0 8px rgba(0, 230, 118, .5), inset 0 -2px 0 rgba(0,0,0,.2);
}
.hitech-btn.ghost {
  background: transparent; color: var(--primary) !important; border: 1px solid rgba(0, 230, 118, .35);
}
")

# -----------------------------------------------------------------------------
# HTTP helpers
# -----------------------------------------------------------------------------
join_url <- function(base, path) paste0(sub("/+$", "", base), path)

safe_pretty <- function(x) {
  tryCatch(jsonlite::toJSON(x, auto_unbox = TRUE, pretty = TRUE),
           error = function(e) sprintf("<error formatting JSON: %s>", e$message))
}

safe_post <- function(base_url, path, body = NULL, timeout = 4) {
  out <- list(ok = FALSE, data = NULL, error = NULL, status = NA_integer_)
  req <- request(join_url(base_url, path)) |>
    req_method("POST") |>
    req_timeout(timeout)
  if (!is.null(body)) req <- req |> req_body_json(body)
  resp <- tryCatch(req_perform(req), error = function(e) e)
  if (inherits(resp, "error")) { out$error <- resp$message; return(out) }
  out$status <- resp_status(resp)
  if (out$status >= 200 && out$status < 300) {
    ct <- resp_content_type(resp)
    if (grepl("json", ct, ignore.case = TRUE)) {
      out$data <- tryCatch(resp_body_json(resp, simplifyVector = TRUE), error = function(e) list())
    }
    out$ok <- TRUE
  } else {
    err <- tryCatch(resp_body_json(resp, simplifyVector = TRUE), error = function(e) NULL)
    out$error <- if (!is.null(err$detail)) {
      paste("Error:", paste(vapply(err$detail, function(d) d$msg %||% "", character(1L)), collapse = "; "))
    } else paste("HTTP error", out$status)
  }
  out
}

safe_get_json <- function(base_url, path, query = list(), timeout = 6) {
  out <- list(ok = FALSE, data = NULL, error = NULL, status = NA_integer_)
  req <- request(join_url(base_url, path))
  if (length(query)) req <- do.call(req_url_query, c(list(req), query))
  req <- req_timeout(req, timeout)
  resp <- tryCatch(req_perform(req), error = function(e) e)
  if (inherits(resp, "error")) { out$error <- resp$message; return(out) }
  out$status <- resp_status(resp)
  if (out$status >= 200 && out$status < 300) {
    out$data <- tryCatch(resp_body_json(resp, simplifyVector = TRUE), error = function(e) NULL)
    out$ok <- !is.null(out$data)
    if (!out$ok) out$error <- "Response is not JSON."
  } else {
    err <- tryCatch(resp_body_json(resp, simplifyVector = TRUE), error = function(e) NULL)
    out$error <- if (!is.null(err$detail)) {
      paste("Error:", paste(vapply(err$detail, function(d) d$msg %||% "", character(1L)), collapse = "; "))
    } else paste("HTTP error", out$status)
  }
  out
}

parse_range <- function(r) {
  if (is.null(r)) return(c(-270L, 270L))
  if (is.character(r)) {
    p <- strsplit(gsub(" ", "", r[1]), ":", fixed = TRUE)[[1]]
    if (length(p) == 2) {
      mn <- suppressWarnings(as.integer(round(as.numeric(p[1]))))
      mx <- suppressWarnings(as.integer(round(as.numeric(p[2]))))
      if (is.na(mn) || is.na(mx)) return(c(-270L, 270L))
      if (mn > mx) c(mx, mn) else c(mn, mx)
    } else c(-270L, 270L)
  } else if (is.numeric(r) && length(r) == 2) {
    mn <- as.integer(r[1]); mx <- as.integer(r[2]); if (mn > mx) c(mx, mn) else c(mn, mx)
  } else c(-270L, 270L)
}

norm_part <- function(p) {
  p <- tolower(as.character(p %||% ""))
  if (p == "heigth") p <- "height"  # tolerate misspelling
  p
}

build_part_map <- function(status) {
  out <- list()
  if (is.null(status) || is.null(status$servo_system)) return(out)
  sv <- status$servo_system$servos
  if (is.null(sv)) return(out)

  if (is.data.frame(sv)) {
    for (i in seq_len(nrow(sv))) {
      part <- norm_part(sv$part[i])
      if (!nzchar(part)) next
      rng <- parse_range(sv$range[i])
      pin <- as.integer(sv$pin[i])
      val <- suppressWarnings(as.integer((sv$value[i]) %||% 0))
      out[[part]] <- list(pin = pin, min = rng[1], max = rng[2], value = val)
    }
  } else if (is.list(sv)) {
    for (i in seq_along(sv)) {
      s <- sv[[i]]
      part <- norm_part(s$part %||% s[["part"]] %||% "")
      if (!nzchar(part)) next
      rng  <- parse_range(s$range %||% s[["range"]])
      pin  <- as.integer(s$pin %||% s[["pin"]] %||% NA)
      val  <- suppressWarnings(as.integer((s$value %||% s[["value"]] %||% 0)))
      out[[part]] <- list(pin = pin, min = rng[1], max = rng[2], value = val)
    }
  }
  out
}

# -----------------------------------------------------------------------------
# Modules
# -----------------------------------------------------------------------------
mod_camera_stream_ui <- function(id) {
  ns <- NS(id)
  div(class = "neo-card",
      div(class = "header-bar",
          h4("Camera (Stream)", class = "hitech-title"),
          span(class = "badge-ghost", "Live feed")
      ),
      div(class = "camera-frame",
          tags$img(src = paste0(BASE_URL, "/camera/stream"))
      ),
      div(class = "small-note", "MJPEG stream straight from the camera.")
  )
}

mod_status_ui <- function(id) {
  ns <- NS(id)
  div(class = "neo-card",
      div(class = "header-bar",
          h4("Robot Status", class = "hitech-title"),
          span(class = "badge-ghost", "System")
      ),
      pre(class = "code", textOutput(ns("status_json")))
  )
}

mod_status_server <- function(id, status_reactive) {
  moduleServer(id, function(input, output, session) {
    output$status_json <- renderText({
      dat <- status_reactive()
      if (is.null(dat)) return("// loading...")
      safe_pretty(dat)
    })
  })
}

mod_controls_ui <- function(id) {
  ns <- NS(id)
  div(class = "neo-card",
      div(class = "header-bar",
          h4("Controls (Keyboard & Touch)", class = "hitech-title"),
          span(class = "badge-ghost", "Control")
      ),
      div(id = ns("map_info")),
      hr(class = "hr-soft"),
      div(class = "ctrl-row",
          div(
            div(class = "keypad",
                div(class = "spacer"),
                div(class = "keybtn", `data-key` = "ArrowUp",    "↑"),
                div(class = "spacer"),
                div(class = "keybtn", `data-key` = "ArrowLeft",  "←"),
                div(class = "keybtn", `data-key` = "ArrowDown",  "↓"),
                div(class = "keybtn", `data-key` = "ArrowRight", "→")
            ),
            div(class = "small-note", style = "text-align:center; margin-top:8px;",
                "Arrows: height (↑/↓) and claw (←/→), step adjustments")
          ),
          div(
            div(class = "keypad",
                div(class = "spacer"),
                div(class = "keybtn", `data-key` = "KeyW", "W"),
                div(class = "spacer"),
                div(class = "keybtn", `data-key` = "KeyA", "A"),
                div(class = "keybtn", `data-key` = "KeyS", "S"),
                div(class = "keybtn", `data-key` = "KeyD", "D")
            ),
            div(class = "small-note", style = "text-align:center; margin-top:8px;",
                "W/S: reach • A/D: base (A = left, D = right)")
          )
      ),
      div(class = "ctrl-actions",
          actionButton(ns("center"), "Center", class = "hitech-btn"),
          actionButton(ns("demo"),   "Demo",   class = "hitech-btn ghost")
      ),
      tags$script(HTML(paste0("
        (function(ns){
          var keys = ['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','KeyA','KeyD','KeyW','KeyS'];
          var state = {}; keys.forEach(function(k){ state[k]=false; });
          function send(){ if(window.Shiny){ Shiny.setInputValue(ns+'key_state', Object.assign({ts:Date.now()}, state), {priority:'event'}); } }
          function setKey(k, val){
            if(!(k in state)) return;
            if(state[k] === val) return;
            state[k] = val; send();
            var el = document.querySelector('[data-key=\"'+k+'\"]');
            if(el){ if(val) el.classList.add('active'); else el.classList.remove('active'); }
          }
          document.addEventListener('keydown', function(e){
            if(keys.indexOf(e.code) >= 0){
              e.preventDefault();
              setKey(e.code, true);
            }
          }, {passive:false});
          document.addEventListener('keyup', function(e){
            if(keys.indexOf(e.code) >= 0){
              e.preventDefault();
              setKey(e.code, false);
            }
          }, {passive:false});
          function bindBtn(el){
            var k = el.getAttribute('data-key');
            var start = function(ev){ ev.preventDefault(); setKey(k, true); };
            var end   = function(ev){ ev.preventDefault(); setKey(k, false); };
            el.addEventListener('pointerdown', start);
            el.addEventListener('pointerup', end);
            el.addEventListener('pointerleave', end);
            el.addEventListener('touchstart', start, {passive:false});
            el.addEventListener('touchend', end, {passive:false});
            el.addEventListener('touchcancel', end, {passive:false});
          }
          document.querySelectorAll('[data-key]').forEach(bindBtn);
        })('", ns(""), "');
      ")))
  )
}

mod_controls_server <- function(id, status_reactive) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns

    local_angles <- reactiveValues()
    part_map <- reactiveVal(list())

    observe({
      st <- status_reactive()
      if (is.null(st)) return()
      pm <- build_part_map(st)
      part_map(pm)

      if (length(pm)) {
        for (nm in names(pm)) {
          pin <- as.character(pm[[nm]]$pin)
          local_angles[[pin]] <- pm[[nm]]$value %||% 0L
        }
      }

      pct_str <- function(pname) {
        pct <- PART_STEP_PCT[[pname]] %||% DEFAULT_STEP_PCT
        paste0(" • step: ", round(pct * 100), "%")
      }
      make_chip <- function(label, p) {
        if (is.null(p)) return(NULL)
        span(class = "map-chip",
             tags$b(toupper(label)), paste0("→ pin ", p$pin, " [", p$min, ",", p$max, "]"),
             if (!is.null(p$value)) paste0(" • val: ", p$value),
             pct_str(label)
        )
      }
      output$map_info <- renderUI({
        pm <- part_map()
        tagList(
          make_chip("claw",   pm$claw),
          make_chip("height", pm$height),
          make_chip("base",   pm$base),
          make_chip("reach",  pm$reach),
          div(class = "small-note", "Hold the keys to move. On mobile, tap the buttons above.")
        )
      })
    })

    send_angle <- function(p, angle) {
      a <- max(p$min, min(p$max, as.integer(angle)))
      safe_post(BASE_URL, "/servo/move", list(pin = p$pin, value = a, smooth = FALSE), timeout = 3)
      local_angles[[as.character(p$pin)]] <- a
    }

    step_part <- function(pname, dir) {
      pm <- part_map()
      p <- pm[[pname]]
      if (is.null(p)) return()

      pin_chr <- as.character(p$pin)
      cur <- as.integer(isolate(local_angles[[pin_chr]] %||% (p$value %||% 0L)))
      span <- max(1L, as.integer(p$max - p$min))
      pct  <- PART_STEP_PCT[[pname]] %||% DEFAULT_STEP_PCT
      step <- max(1L, as.integer(round(span * pct)))
      new  <- cur + dir * step
      new  <- max(p$min, min(p$max, new))

      if (new != cur) send_angle(p, new)
    }

    observeEvent(input$center, { safe_post(BASE_URL, "/servo/center", NULL, timeout = 6) })
    observeEvent(input$demo,   { safe_post(BASE_URL, "/servo/demo",   NULL, timeout = 6) })

    observe({
      invalidateLater(KEY_REPEAT_MS, session)
      ks <- input$key_state
      if (is.null(ks)) return()

      if (isTRUE(ks$ArrowLeft) && !isTRUE(ks$ArrowRight)) step_part("claw",   -1)
      else if (isTRUE(ks$ArrowRight))                      step_part("claw",   +1)

      if (isTRUE(ks$ArrowUp) && !isTRUE(ks$ArrowDown))     step_part("height", +1)
      else if (isTRUE(ks$ArrowDown))                       step_part("height", -1)

      if (isTRUE(ks$KeyA) && !isTRUE(ks$KeyD))             step_part("base",   +1)
      else if (isTRUE(ks$KeyD))                            step_part("base",   -1)

      if (isTRUE(ks$KeyW) && !isTRUE(ks$KeyS))             step_part("reach",  +1)
      else if (isTRUE(ks$KeyS))                            step_part("reach",  -1)
    })
  })
}

# -----------------------------------------------------------------------------
# Main UI
# -----------------------------------------------------------------------------
ui <- page_fluid(
  theme = neo_theme,
  tags$head(
    tags$meta(charset = "utf-8"),
    tags$link(rel = "preconnect", href = "https://fonts.googleapis.com"),
    tags$link(rel = "preconnect", href = "https://fonts.gstatic.com", crossorigin = "anonymous"),
    tags$link(rel = "stylesheet", href = "https://fonts.googleapis.com/css2?family=Orbitron:wght@500;700;900&family=Rajdhani:wght@400;600;700&display=swap"),
    tags$style(hitech_css)
  ),
  fluidRow(
    column(12,
           div(class = "neo-card",
               div(class = "header-bar",
                   div(class = "hitech-title app-title", "Robot Control Dashboard"),
                   span(class = "badge-soft", "Online")
               ),
               div(class = "small-note",
                   sprintf("Live stream and status every %.1fs. Keyboard or on-screen buttons with step-based moves.", AUTO_MS / 1000)
               )
           )
    )
  ),
  fluidRow(
    column(8, mod_camera_stream_ui("cam")),
    column(4, mod_controls_ui("ctl"))
  ),
  fluidRow(
    column(12, mod_status_ui("stat"))
  ),
  div(class = "footer-note", "Built with Shiny • Neon tech style")
)

# -----------------------------------------------------------------------------
# Server
# -----------------------------------------------------------------------------
server <- function(input, output, session) {
  status_rv <- reactiveVal(NULL)
  observe({
    res <- safe_get_json(BASE_URL, "/robot/status")
    if (res$ok) {
      status_rv(res$data)
    } else {
      status_rv(list(error = res$error %||% paste("HTTP", res$status)))
    }
    invalidateLater(AUTO_MS, session)
  })

  mod_status_server("stat", status_reactive = status_rv)
  mod_controls_server("ctl", status_reactive = status_rv)
}

shinyApp(ui, server)
