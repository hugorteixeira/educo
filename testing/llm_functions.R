estimar_tokens <- function(texto) {
  # Estima o número de tokens considerando 4 caracteres por token.
  num_tokens <- ceiling(nchar(texto) / 4)
  return(num_tokens)
}
carregar_funcoes_api <- function(url, padrao = "openai", prefixos_permitidos) {
 
  url_validada <- validar_url(url, prefixos_permitidos)
  
  # Lê o arquivo OpenAPI spec
  spec_txt <- if (grepl("^https?://", url, ignore.case = TRUE)) {
    r <- httr::GET(url_validada)
    stop_for_status(r)
    content(r, "text", encoding = "UTF-8")
  } else {
    paste(readLines(url, warn = FALSE), collapse = "\n")
  }
  
  spec <- jsonlite::fromJSON(spec_txt, simplifyVector = FALSE)
  
  # Helper para resolver referências
  resolve_ref <- function(ref_string, root) {
    path <- strsplit(sub("^#/", "", ref_string), "/", fixed = TRUE)[[1]]
    node <- root
    for (p in path) node <- node[[p]]
    node
  }
  
  # Helper para converter schemas
  convert_schema <- function(schema, root) {
    if (!is.null(schema$`$ref`)) {
      schema <- resolve_ref(schema$`$ref`, root)
    }
    
    if (is.null(schema$type) && !is.null(schema$properties)) {
      schema$type <- "object"
    }
    
    if (identical(schema$type, "object")) {
      props <- list()
      if (!is.null(schema$properties)) {
        for (prop_name in names(schema$properties)) {
          prop <- schema$properties[[prop_name]]
          if (!is.null(prop$`$ref`)) {
            prop <- resolve_ref(prop$`$ref`, root)
          }
          
          # Garantir estrutura mínima da propriedade
          prop_item <- list(
            type = prop$type %||% "string"
          )
          
          if (!is.null(prop$description)) {
            prop_item$description <- prop$description
          }
          
          if (!is.null(prop$enum)) {
            prop_item$enum <- prop$enum
          }
          
          props[[prop_name]] <- prop_item
        }
      }
      
      result <- list(
        type = "object",
        properties = props
      )
      
      if (!is.null(schema$required) && length(schema$required) > 0) {
        result$required <- schema$required
      }
      
      return(result)
    } else {
      # Para tipos primitivos, criar um wrapper object
      return(list(
        type = "object",
        properties = list(
          value = list(
            type = schema$type %||% "string",
            description = schema$description %||% "Input value"
          )
        ),
        required = list("value")
      ))
    }
  }
  
  # Lista para armazenar as tools
  tools_list <- list()
  
  # Processar cada endpoint
  for (path_name in names(spec$paths)) {
    path_item <- spec$paths[[path_name]]
    
    for (method_name in names(path_item)) {
      operation <- path_item[[method_name]]
      
      # Nome da função
      function_name <- operation$operationId %||% 
        paste0(method_name, "_", gsub("[^a-zA-Z0-9_]", "_", path_name))
      
      # Descrição da função
      function_description <- operation$summary %||% 
        operation$description %||% 
        paste("Execute", method_name, "operation on", path_name)
      
      # Inicializar estrutura de parâmetros
      properties <- list()
      required_params <- character()
      
      # Processar parâmetros (query, path, header)
      if (!is.null(operation$parameters)) {
        for (param in operation$parameters) {
          if (!is.null(param$`$ref`)) {
            param <- resolve_ref(param$`$ref`, spec)
          }
          
          param_schema <- list(
            type = param$schema$type %||% "string"
          )
          
          if (!is.null(param$description)) {
            param_schema$description <- param$description
          }
          
          if (!is.null(param$schema$enum)) {
            param_schema$enum <- param$schema$enum
          }
          
          properties[[param$name]] <- param_schema
          
          if (isTRUE(param$required)) {
            required_params <- c(required_params, param$name)
          }
        }
      }
      
      # Processar requestBody (se existir)
      if (!is.null(operation$requestBody)) {
        content_schemas <- operation$requestBody$content
        if (!is.null(content_schemas$`application/json`$schema)) {
          body_schema <- convert_schema(content_schemas$`application/json`$schema, spec)
          
          # Mesclar propriedades do body com parâmetros
          if (!is.null(body_schema$properties)) {
            for (body_prop_name in names(body_schema$properties)) {
              properties[[body_prop_name]] <- body_schema$properties[[body_prop_name]]
            }
          }
          
          # Adicionar campos obrigatórios do body
          if (!is.null(body_schema$required)) {
            required_params <- unique(c(required_params, body_schema$required))
          }
        }
      }
      
      # Garantir que properties não está vazio
      if (length(properties) == 0) {
        properties <- structure(list(), .Names = character(0))
      }
      
      # Construir a estrutura final da tool
      tool_definition <- list(
        type = "function",
        `function` = list(
          name = function_name,
          description = function_description,
          parameters = list(
            type = "object",
            properties = properties
          )
        )
      )
      
      # Adicionar required apenas se houver parâmetros obrigatórios
      if (length(required_params) > 0) {
        tool_definition$`function`$parameters$required <- required_params
      }
      
      # Adicionar à lista de tools
      tools_list[[length(tools_list) + 1]] <- tool_definition
    }
  }
  
  return(tools_list)
}
enviar_msg_openai <- function(prompt, modelo, temp_v, add_img, tools = FALSE, timeout_secs = 80) {
  library(httr)
  library(jsonlite)
  
  api_url <- "https://api.openai.com/v1/chat/completions"
  
  if (is.null(modelo)) {
    modelo <- "gpt-4-turbo"
  }
  
  api_key <- Sys.getenv("OPENAI_API_KEY")
  if (is.null(api_key) || api_key == "") {
    stop("Variável de ambiente OPENAI_API_KEY não definida.")
  }
  
  headers <- add_headers(
    Authorization = paste("Bearer", api_key), 
    "Content-Type" = "application/json"
  )
  
  # Construção da mensagem inicial
  initial_message <- list(
    role = "user", 
    content = if (!is.null(add_img)) {
      list(
        list(type = "text", text = prompt),
        list(type = "image_url", image_url = list(url = paste0("data:image/jpeg;base64,", encode_image(add_img))))
      )
    } else {
      prompt
    }
  )
  
  # Ajuste de temperatura para modelos "o1"
  if (grepl("^o", modelo)) {
    temp_v <- 1
  }
  
  # Construção do body da requisição
  body <- list(
    model = modelo,
    messages = list(initial_message),
    temperature = temp_v
  )
  
  # Verificação corrigida para tools
  if (!is.null(tools) && is.list(tools) && length(tools) > 0) {
    #  cat("Usando tools na chamada OpenAI\n")
    body$tools <- tools
    body$tool_choice <- "auto"
  } else if (!is.null(tools) && is.logical(tools) && tools) {
    warning("Parâmetro 'tools' é TRUE mas nenhuma lista de tools foi fornecida")
  }
  
  # Casos especiais para modelos de busca
  if (grepl("search", modelo)) {
    body <- list(model = modelo, messages = list(initial_message))
  }
  
  # Chamada da API com tratamento de timeout
  response <- tryCatch({
    httr::POST(
      url = api_url,
      headers,
      body = toJSON(body, auto_unbox = TRUE, null = "null"),
      encode = "json",
      config = httr::timeout(timeout_secs)
    )
  }, error = function(e) {
    err_msg <- conditionMessage(e)
    if (grepl("Timeout was reached|Operation timed out", err_msg, ignore.case = TRUE)) {
      warning(paste("Timeout HTTR em enviar_msg_openai após", timeout_secs, "segundos:", err_msg))
      return(paste0("TIMEOUT_ERROR_HTTR: API call exceeded ", timeout_secs, " seconds."))
    } else {
      warning(paste("Erro HTTR em enviar_msg_openai:", err_msg))
      return(paste0("HTTR_ERROR: ", err_msg))
    }
  })
  
  # Verificar se response é uma string de erro
  if (is.character(response) && (startsWith(response, "TIMEOUT_ERROR_HTTR:") || startsWith(response, "HTTR_ERROR:"))) {
    return(response)
  }
  
  # Processamento da resposta
  if (http_status(response)$category != "Success") {
    error_content <- content(response, "text", encoding = "UTF-8")
    error_msg <- paste("Erro na API OpenAI:", http_status(response)$reason, "-", error_content)
    warning(error_msg)
    error_details <- tryCatch(fromJSON(error_content)$error$message, error = function(e) error_content)
    return(paste("API_ERROR:", http_status(response)$reason, "-", error_details))
  }
  
  result <- content(response, as = "parsed", type = "application/json", encoding = "UTF-8")
  
  # Processar resposta
  message_content <- result$choices[[1]]$message
  
  # Verificar se há tool calls e retornar a estrutura completa
  if (!is.null(message_content$tool_calls)) {
    # Retorna uma lista com o conteúdo e as tool calls para processamento manual
    return(list(
      content = message_content$content,
      tool_calls = message_content$tool_calls,
      finish_reason = result$choices[[1]]$finish_reason
    ))
  } else if (!is.null(message_content$function_call)) {
    # Retorna uma lista com o conteúdo e a function call para processamento manual
    return(list(
      content = message_content$content,
      function_call = message_content$function_call,
      finish_reason = result$choices[[1]]$finish_reason
    ))
  } else if (!is.null(message_content$content)) {
    # Resposta normal sem function calls
    return(message_content$content)
  } else if (!is.null(result$choices[[1]]$finish_reason) && result$choices[[1]]$finish_reason == "content_filter") {
    warning("Conteúdo bloqueado pelo filtro da OpenAI.")
    return("CONTENT_FILTERED: Response blocked by OpenAI content filter.")
  } else {
    warning("Resposta da API OpenAI inesperada. Finish reason: ", result$choices[[1]]$finish_reason)
    return("API_RESPONSE_ERROR: No valid content, tool_calls or function_call found.")
  }
}
enviar_msg <- function(contexto, res_contexto = TRUE, add = NULL, add_img = NULL, diretorio = "content", label = NULL, service = "gemini", modelo = "gemini-2.5-flash-preview-04-17", temp = NULL, tools = FALSE, think = FALSE, timeout_api = 240, null_repeat = TRUE) {
  
  # --- Start: Setup & Input Processing (Keep existing code) ---
  # library(httr) # Ensure libraries are loaded where needed (cluster export handles this for parallel)
  # library(jsonlite)
  
  if (!dir.exists(diretorio)) { dir.create(diretorio, recursive = TRUE, showWarnings = FALSE) }
  
  # Extract single string values for service, model, temp if passed as list/vector
  if (is.list(service)) service <- as.character(service$service %||% service[[1]]) else if (is.vector(service)) service <- as.character(service[1])
  if (is.list(modelo)) modelo <- as.character(modelo$model %||% modelo$modelo %||% modelo[[1]]) else if (is.vector(modelo)) modelo <- as.character(modelo[1])
  if (is.list(temp)) temp <- as.numeric(temp$temperature %||% temp$temp %||% temp[[1]]) else if (is.vector(temp)) temp <- as.numeric(temp[1])
  temp_v <- ifelse(is.null(temp) || !is.numeric(temp) || is.na(temp), 0.7, temp) # Ensure valid temp
  
  processar_add <- function(contexto, add) {
    if (!is.null(add)) {
      texto_completo <- ""
      if (!is.list(add)) {
        add <- as.list(add)
      }
      
      for (item in add) {
        item_text <- ""
        
        if (is.character(item) && length(item) == 1 && file.exists(item)) {
          extensao <- tools::file_ext(item)
          
          if (extensao %in% c("txt", "csv")) {
            if (extensao == "txt") {
              texto <- readLines(item, encoding = "UTF-8")
              item_text <- paste(texto, collapse = "\n")
            } else if (extensao == "csv") {
              dados <- read.csv(item, stringsAsFactors = FALSE)
              item_text <- paste(capture.output(print(dados)), collapse = "\n")
            }
          } else {
            stop("Formato de arquivo não suportado. Utilize .txt ou .csv.")
          }
        } else if (is.character(item)) {
          item_text <- item
        } else if (is.data.frame(item) || is.matrix(item)) {
          item_text <- paste(capture.output(print(item)), collapse = "\n")
        } else if (is.list(item)) {
          # Novo tratamento para listas aninhadas
          item_text <- paste(unlist(rapply(item, function(x) as.character(x))), collapse = "\n")
        } else {
          item_text <- as.character(item)
        }
        
        texto_completo <- paste(texto_completo, item_text, sep = "\n")
      }
      
      prompt <- paste(contexto, "\n\nTexto:\n", texto_completo)
      tokens <- estimar_tokens(prompt)
      
    } else {
      prompt <- contexto
      tokens <- estimar_tokens(prompt)
    }
    return(list(prompt = prompt, tokens = tokens))
  }
  
  # Process context, add, tokens
  prompt_info <- processar_add(contexto, add)
  prompt <- prompt_info$prompt
  tokens_enviados <- prompt_info$tokens
  # cat("Estimativa de tokens enviados: ", tokens_enviados, "\n") # Optional: uncomment for verbose logging
  
  # --- Start Timing & API Call ---
  msg_enviada <- Sys.time()
  resposta_api <- NULL # Initialize
  api_call_error <- NULL # To store specific API call errors
  
  # Use tryCatch around the switch for better error isolation
  tryCatch({
    resposta_api <- switch(tolower(service), # Use tolower for robustness
                           "openai" = enviar_msg_openai(prompt, modelo, temp_v, add_img, tools = tools, timeout_secs = timeout_api),
                           "ollama" = enviar_msg_ollama(prompt, modelo, temp_v, add_img, tools = tools, think = think, timeout_secs = timeout_api),
                           "gemini" = enviar_msg_gemini(prompt, modelo, temp_v, add_img, tools = tools, timeout_secs = timeout_api),
                           "geminicheck" = enviar_msg_geminiCHECK(prompt, modelo, temp_v, add_img, tools = tools, timeout_secs = timeout_api),
                           "openrouter" = enviar_msg_openrouter(prompt, modelo, temp_v, add_img, tools = tools, timeout_secs = timeout_api),
                           "claude" = enviar_msg_claude(prompt, modelo, temp_v, add_img, tools = tools, timeout_secs = timeout_api), # Add timeout if needed
                           "mistral" = enviar_msg_mistral(prompt, modelo, temp_v, add_img, tools = tools, timeout_secs = timeout_api),# Add timeout if needed
                           "groq" = enviar_msg_groq(prompt, modelo, temp_v, add_img, tools = tools, timeout_secs = timeout_api),
                           "zhipu" = enviar_msg_zhipu(prompt, modelo, temp_v, add_img, tools = tools, timeout_secs = timeout_api),
                           "huggingface" = enviar_msg_huggingface(prompt, modelo, temp_v, add_img, tools = tools, timeout_secs = timeout_api),
                           "cohere" = enviar_msg_cohere(prompt, modelo, temp_v, add_img, tools = tools, timeout_secs = timeout_api),
                           "grok" = enviar_msg_grok(prompt, modelo, temp_v, add_img, tools = tools, timeout_secs = timeout_api),
                           "nebius" = enviar_msg_nebius(prompt, modelo, temp_v, add_img, tools = tools, timeout_secs = timeout_api),
                           "sambanova" = enviar_msg_sambanova(prompt, modelo, temp_v, add_img, tools = tools, timeout_secs = timeout_api),
                           "cerebras" = enviar_msg_cerebras(prompt, modelo, temp_v, add_img, tools = tools, timeout_secs = timeout_api),
                           "fal" = enviar_msg_fal(prompt, modelo, add_img, tools = tools, timeout_secs = timeout_api),
                           "hyperbolic" = enviar_msg_hyperbolic(prompt, modelo, temp_v, add_img, tools = tools, timeout_secs = timeout_api),
                           "deepinfra" = enviar_msg_deepinfra(prompt, modelo, temp_v, add_img, tools = tools, timeout_secs = timeout_api),
                           "fireworks" = enviar_msg_fireworks(prompt, modelo, temp_v, add_img, tools = tools, timeout_secs = timeout_api),
                           "perplexity" = enviar_msg_perplexity(prompt, modelo, temp_v, tools = tools, timeout_secs = timeout_api),
                           "deepseek" = enviar_msg_deepseek(prompt, modelo, temp_v, add_img, tools = tools, timeout_secs = timeout_api),
                           "together" = enviar_msg_together(prompt, modelo, temp_v, add_img, tools = tools, timeout_secs = timeout_api),
                           # Add other services here...
                           # Fallback error for unknown service
                           paste0("SERVICE_NOT_IMPLEMENTED: ", service)
    )
  }, error = function(e) {
    # Catch errors specifically from the service call functions
    api_call_error <<- paste("Error during API call execution:", conditionMessage(e))
    resposta_api <<- api_call_error # Set response to the error message
  })
  if (null_repeat &&
      is.character(resposta_api) &&
      resposta_api == "EMPTY_OR_NULL_RESPONSE") {
    
    # vetor de intervalos de espera em segundos: 10s, 60s, 600s
    retry_intervals <- c(10, 60, 600)
    
    for (wait_sec in retry_intervals) {
      message(sprintf("Resposta vazia detectada, vou esperar %ss e tentar de novo...", wait_sec))
      Sys.sleep(wait_sec)
      
      # re-chama o mesmo serviço
      resposta_api <- switch(
        tolower(service),
        "openai"      = enviar_msg_openai(...),
        "gemini"      = enviar_msg_gemini(...),
        # ...
        paste0("SERVICE_NOT_IMPLEMENTED: ", service)
      )
      
      # se não for mais EMPTY, sai do loop
      if (!(is.character(resposta_api) &&
            resposta_api == "EMPTY_OR_NULL_RESPONSE")) {
        message("Recebi algo diferente de EMPTY, sigo o fluxo normal.")
        break
      }
    }
    
    # Se, após todas as tentativas, ainda for EMPTY, aborta com erro
    if (is.character(resposta_api) &&
        resposta_api == "EMPTY_OR_NULL_RESPONSE") {
      stop("EMPTY_OR_NULL_RESPONSE persistente após 4 tentativas (- 0s,10s,60s,600s). Abortando.")
    }
  }
  msg_recebida <- Sys.time()
  tempo_resposta <- as.numeric(difftime(msg_recebida, msg_enviada, units = "secs"))
  
  # --- Process Response & Determine Status ---
  tokens_recebidos <- NA_integer_ # Default to NA
  houve_erro_api <- FALSE
  mensagem_status <- "OK"
  resposta_valor_final <- NULL # Will hold the actual content or error msg for the list
  
  # Check if an error occurred during the API call itself
  if (!is.null(api_call_error)) {
    houve_erro_api <- TRUE
    mensagem_status <- api_call_error
    resposta_valor_final <- mensagem_status # Store the error message
  } else if (is.character(resposta_api) &&
             (startsWith(resposta_api, "TIMEOUT_ERROR_HTTR:") ||
              startsWith(resposta_api, "HTTR_ERROR:") ||
              startsWith(resposta_api, "API_ERROR:") ||
              startsWith(resposta_api, "CONTENT_FILTERED:") ||
              startsWith(resposta_api, "PROMPT_BLOCKED:") ||
              startsWith(resposta_api, "SERVICE_NOT_IMPLEMENTED:") ||
              startsWith(resposta_api, "API_RESPONSE_ERROR:") ||
              startsWith(resposta_api, "FUNCTION_CALL_ERROR:") ||
              startsWith(resposta_api, "TOOL_CALL_ERROR:")
             )) {
    # Check if the returned value itself is a known error code string
    houve_erro_api <- TRUE
    mensagem_status <- resposta_api
    resposta_valor_final <- mensagem_status # Store the error message
  } else if (is.null(resposta_api) || length(resposta_api) == 0 || (is.character(resposta_api) && nchar(trimws(resposta_api)) == 0)){
    # Handle cases where API genuinely returns empty/NULL without error code
    houve_erro_api <- TRUE
    mensagem_status <- "EMPTY_OR_NULL_RESPONSE"
    resposta_valor_final <- mensagem_status # Store the error code
  } else {
    # Success case: Store the actual API response and estimate tokens
    resposta_valor_final <- resposta_api # Store the successful response
    if (is.character(resposta_valor_final)) {
      tokens_recebidos <- tryCatch(estimar_tokens(resposta_valor_final), error = function(e) NA_integer_)
    } else {
      # Handle non-character success (e.g., function call results if not stringified)
      tokens_recebidos <- tryCatch(estimar_tokens(paste(capture.output(str(resposta_valor_final)), collapse="\n")), error = function(e) NA_integer_)
    }
    mensagem_status <- "OK"
  }
  
  
  # --- Define Labels ---
  label_base <- label # Use the passed label directly
  if (is.null(label_base)) {
    # Fallback if label wasn't passed (shouldn't happen with gerar_conteudo)
    label_base <- deparse(substitute(contexto))
    label_base <- substr(gsub("[^A-Za-z0-9_.-]", "_", label_base), 1, 50)
  }
  label_cat <- label_base # Use the same label for category for now
  
  # --- Salvar Resposta (calls the separate function) ---
  # Pass the actual API content or the determined error message to be saved
  # Note: salvar_resposta now just saves and logs, the main return value logic is here.
  valor_retorno_salvar <- salvar_resposta(
    resposta_api = resposta_valor_final, # Pass the final content or error string
    contexto = contexto,
    res_contexto = res_contexto,
    label = label_base,
    label_cat = label_cat,
    service = service,
    modelo = modelo,
    temp = temp_v,
    tempo_resposta = tempo_resposta,
    diretorio = diretorio,
    status = ifelse(houve_erro_api, "ERRO", "SUCESSO"), # Pass determined status
    tokens_enviados = tokens_enviados,
    tokens_recebidos = tokens_recebidos %||% NA_integer_ # Pass estimated tokens or NA
  )
  # We don't necessarily need the return value of salvar_resposta anymore if it just saves/logs
  
  
  # --- Construct the Return List ---
  # THIS is the structure that must be returned consistently
  resultado_com_atributos <- list(
    resposta_valor   = resposta_valor_final, # The actual content or error message
    label            = label_base,
    label_cat        = label_cat,
    service          = service,
    modelo           = modelo,
    temp             = temp_v,
    tempo            = tempo_resposta,
    status_api       = ifelse(houve_erro_api, "ERRO", "SUCESSO"),
    mensagem_status  = mensagem_status, # Specific error message or "OK"
    tokens_enviados  = tokens_enviados,
    tokens_recebidos = tokens_recebidos # Estimated or NA
    # arquivo_salvo can be added here if needed, get from salvar_resposta return if modified
  )
  
  # --- Explicitly return the structured list ---
  # Remove invisible() to be certain the list is returned
  return(invisible(resultado_com_atributos))
}
salvar_resposta <- function(resposta_api,           # Resposta da API ou string de erro
                            contexto,               # Contexto original
                            res_contexto,           # Flag booleana para incluir contexto no .txt
                            label,                  # Label principal
                            label_cat,              # Label para categoria/log
                            service,                # Nome do serviço (ex: "gemini")
                            modelo,                 # Nome do modelo
                            temp,                   # Temperatura usada
                            tempo_resposta,         # Tempo em segundos
                            diretorio,              # Diretório para salvar
                            status,                 # "SUCESSO" ou "ERRO"
                            tokens_enviados,        # Contagem de tokens enviados (estimada) - Usado no log
                            tokens_recebidos) {
  
  # --- Geração do nome do arquivo ---
  data_hora <- format(Sys.time(), "%Y%m%d_%H%M%S")
  
  if (is.null(label)) {
    label <- deparse(substitute(contexto))
    label_cat <- label # Usa o label derivado
  } else {
    label_cat <- label # Usa o label fornecido
  }
  
  # Limpeza e formatação do nome do modelo para o nome do arquivo
  # Garante que modelo seja string antes de usar gsub
  modelo_str <- ifelse(is.null(modelo) || !is.character(modelo), "modelo_desconhecido", modelo)
  modelo_fn <- gsub("[^A-Za-z0-9_.-]", "_", modelo_str) # Remove caracteres inválidos
  modelo_fn <- gsub("[:/]", "_", modelo_fn)            # Substitui : e / por _
  
  # Garante que service e temp sejam usáveis no nome do arquivo
  service_fn <- ifelse(is.null(service) || !is.character(service), "servico_desconhecido", service)
  temp_fn <- ifelse(is.null(temp) || is.na(temp) || !is.numeric(temp), "temp_desconhecida", temp)
  
  
  nome_arquivo <- paste0(label, "_", service_fn, "_", modelo_fn, "_tp", temp_fn, "_", data_hora, ".txt")
  caminho_resultado_final <- file.path(diretorio, nome_arquivo)
  
  # --- Escrever o arquivo de resultado ---
  conteudo_para_salvar <- if (is.character(resposta_api)) {
    resposta_api
  } else {
    # Tenta converter para character se não for (ex: erro, NULL)
    tryCatch(as.character(resposta_api), error = function(e) {
      warning("Nao foi possivel converter resposta_api para character ao salvar: ", conditionMessage(e))
      return("ERRO_CONVERSAO_SALVAR")
    })
  }
  
  # Garante que diretorio exista antes de tentar escrever
  if (!dir.exists(diretorio)) {
    dir.create(diretorio, recursive = TRUE, showWarnings = FALSE)
    cat("Diretorio criado:", diretorio, "\n")
  }
  
  if (status == "ERRO") {
    # Em caso de erro, salva apenas a mensagem de erro no arquivo principal
    write_result <- try(writeLines(paste("STATUS:", status, "\nMENSAGEM:", conteudo_para_salvar),
                                   con = caminho_resultado_final, useBytes = TRUE))
  } else if (label == "pedido_dir_mkt" || label == "resposta_dir_mkt" || res_contexto == TRUE) {
    # Salva resposta + contexto se for sucesso e aplicável
    contexto_str <- tryCatch(as.character(contexto), error = function(e) {
      warning("Nao foi possivel converter contexto para character: ", conditionMessage(e))
      return("ERRO_CONVERSAO_CONTEXTO")
    })
    write_result <- try(writeLines(c(conteudo_para_salvar, "\n\n--- Contexto Fornecido ---", contexto_str),
                                   con = caminho_resultado_final, useBytes = TRUE))
  } else {
    # Salva apenas a resposta se for sucesso e res_contexto = FALSE
    write_result <- try(writeLines(conteudo_para_salvar,
                                   con = caminho_resultado_final, useBytes = TRUE))
  }
  
  # Verifica se a escrita do arquivo falhou
  if (inherits(write_result, "try-error")) {
    warning("Falha ao escrever o arquivo principal: ", caminho_resultado_final, " - Erro: ", write_result)
  }
  
  
  # --- Mensagem no Console ---
  preview_resposta <- if (is.character(conteudo_para_salvar)) {
    substr(gsub("\n", " ", conteudo_para_salvar), 1, 150) # Limita e remove quebras de linha
  } else {
    typeof(conteudo_para_salvar) # Mostra o tipo se não for string
  }
  
  # Garante que os valores numéricos para sprintf sejam válidos
  tempo_print <- ifelse(is.null(tempo_resposta) || is.na(tempo_resposta) || !is.numeric(tempo_resposta), 0, tempo_resposta)
  tokens_env_print <- ifelse(is.null(tokens_enviados) || is.na(tokens_enviados) || !is.numeric(tokens_enviados), "?", tokens_enviados)
  tokens_rec_print <- ifelse(is.null(tokens_recebidos) || is.na(tokens_recebidos) || !is.numeric(tokens_recebidos), "?", tokens_recebidos)
  
  message_line <- sprintf(
    "[%s] %s | %s | %s | Temp: %s | Tempo: %.2fs | Tk_Env: %s | Tk_Rec: %s \n   -> Arquivo: %s\n   -> Resposta: %s...\n",
    status,
    label_cat, service_fn, modelo_str, temp_fn, # Usar as versões seguras para print
    tempo_print,
    tokens_env_print,
    tokens_rec_print,
    basename(caminho_resultado_final), # Mostra o nome base do arquivo salvo
    preview_resposta
  )
  #  cat(message_line)
  
  # --- REMOVIDO: Toda a lógica de `lista_tempo` e `new_entry` ---
  
  
  # --- Processamento específico para email e retorno ---
  valor_retorno <- resposta_api # Por padrão, retorna o que recebeu (resposta ou erro)
  
  # Processa e-mail apenas se a chamada foi um sucesso E é do tipo correto E resposta_api é character
  if (status == "SUCESSO" && label == "resposta_dir_mkt" && is.character(resposta_api)) {
    caminho_resultado_final_email <- file.path(diretorio, paste0("email_", nome_arquivo))
    # Assume que separar_email existe e funciona com a resposta_api
    resposta_api_editada <- tryCatch(
      separar_email(resposta_api),
      error = function(e) {
        warning("Falha ao executar separar_email: ", conditionMessage(e))
        return(paste("ERRO_SEPARAR_EMAIL:", conditionMessage(e)))
      }
    )
    
    # Tenta escrever o arquivo de email
    write_email_result <- try(writeLines(as.character(resposta_api_editada),
                                         con = caminho_resultado_final_email, useBytes = TRUE))
    
    if (inherits(write_email_result, "try-error")) {
      warning("Falha ao escrever o arquivo de email: ", caminho_resultado_final_email, " - Erro: ", write_email_result)
      # Decide se quer retornar o erro ou a tentativa de edição
      # Aqui, retornamos a tentativa de edição mesmo se salvar falhou
      valor_retorno <- resposta_api_editada
    } else {
      # Se salvou com sucesso, retorna a versão editada
      valor_retorno <- resposta_api_editada
    }
  }
  
  # Retorna o valor determinado (resposta original, erro, ou resposta editada)
  return(invisible(valor_retorno))
}
executar_resposta_tools <- function(resposta_enviar_msg, openapi_spec_url, base_url = NULL) {
  # Verificar diferentes estruturas de resposta
  tool_calls <- NULL
  
  if (is.list(resposta_enviar_msg)) {
    # Estrutura do Ollama: resposta direta com tool_calls
    if (!is.null(resposta_enviar_msg$tool_calls)) {
      tool_calls <- resposta_enviar_msg$tool_calls
    }
    # Estrutura alternativa: resposta_valor$tool_calls
    else if (!is.null(resposta_enviar_msg$resposta_valor) && 
             !is.null(resposta_enviar_msg$resposta_valor$tool_calls)) {
      tool_calls <- resposta_enviar_msg$resposta_valor$tool_calls
    }
  }
  
  if (!is.null(tool_calls)) {
    cat("Executando", length(tool_calls), "tool calls...\n")
    
    resultados <- executar_tool_calls(
      tool_calls,
      openapi_spec_url,
      base_url
    )
    
    return(resultados)
  } else {
    cat("Nenhum tool call encontrado na resposta.\n")
    cat("Estrutura da resposta recebida:\n")
    str(resposta_enviar_msg)
    return(NULL)
  }
}
encode_image <- function(image_path) {
  if (!file.exists(image_path)) {
    stop("Arquivo de imagem não encontrado")
  }
  image_data <- readBin(image_path, "raw", file.info(image_path)$size)
  base64enc::base64encode(image_data)
}
executar_tool_calls <- function(tool_calls, openapi_spec_url, base_url = NULL,prefixos_permitidos) {
  require(httr)
  require(jsonlite)
  
  # Carregar a especificação OpenAPI
  spec <- carregar_spec_openapi(openapi_spec_url, prefixos_permitidos)
  
  resultados <- list()
  
  for (i in seq_along(tool_calls)) {
    tool_call <- tool_calls[[i]]
    
    cat(sprintf("Executando tool call %d: %s\n", i, tool_call$`function`$name))
    
    resultado <- executar_funcao_api(
      function_name = tool_call$`function`$name,
      arguments_json = tool_call$`function`$arguments,
      spec = spec,
      call_id = tool_call$id,
      base_url = base_url
    )
    
    resultados[[i]] <- resultado
  }
  
  return(resultados)
}
carregar_spec_openapi <- function(url, prefixos_permitidos) {
  spec_txt <- if (grepl("^https?://", url_validada, ignore.case = TRUE)) {
    r <- httr::GET(url_validada)
    httr::stop_for_status(r)
    httr::content(r, "text", encoding = "UTF-8")
  }
  
  spec <- jsonlite::fromJSON(spec_txt, simplifyVector = FALSE)
  return(spec)
}
encontrar_endpoint <- function(function_name, spec) {
  for (path_name in names(spec$paths)) {
    path_item <- spec$paths[[path_name]]
    
    for (method_name in names(path_item)) {
      operation <- path_item[[method_name]]
      
      # Gerar o nome da função da mesma forma que em carregar_funcoes_api
      expected_name <- operation$operationId %||% 
        paste0(method_name, "_", gsub("[^a-zA-Z0-9_]", "_", path_name))
      
      if (expected_name == function_name) {
        return(list(
          path = path_name,
          method = method_name,
          operation = operation
        ))
      }
    }
  }
  
  return(NULL)
}
substituir_parametros_path <- function(url, args, endpoint_info) {
  if (is.null(endpoint_info$operation$parameters)) {
    return(url)
  }
  
  for (param in endpoint_info$operation$parameters) {
    if (param$`in` == "path" && !is.null(args[[param$name]])) {
      placeholder <- paste0("{", param$name, "}")
      url <- gsub(placeholder, args[[param$name]], url, fixed = TRUE)
    }
  }
  
  return(url)
}
separar_parametros <- function(args, endpoint_info) {
  query_params <- list()
  header_params <- list()
  body_params <- list()
  
  # Parâmetros definidos na operação
  if (!is.null(endpoint_info$operation$parameters)) {
    for (param in endpoint_info$operation$parameters) {
      param_name <- param$name
      
      if (!is.null(args[[param_name]])) {
        if (param$`in` == "query") {
          query_params[[param_name]] <- args[[param_name]]
        } else if (param$`in` == "header") {
          header_params[[param_name]] <- args[[param_name]]
        }
      }
    }
  }
  
  # RequestBody - todos os outros parâmetros vão para o body
  used_params <- c(names(query_params), names(header_params))
  
  # Adicionar parâmetros de path aos usados
  if (!is.null(endpoint_info$operation$parameters)) {
    path_params <- sapply(endpoint_info$operation$parameters, function(p) {
      if (p$`in` == "path") p$name else NULL
    })
    path_params <- path_params[!sapply(path_params, is.null)]
    used_params <- c(used_params, unlist(path_params))
  }
  
  for (arg_name in names(args)) {
    if (!arg_name %in% used_params) {
      body_params[[arg_name]] <- args[[arg_name]]
    }
  }
  
  return(list(
    query = query_params,
    header = header_params,
    body = body_params
  ))
}
fazer_requisicao_http <- function(url, method, query_params, body_params, header_params) {
  # Preparar headers - usando método simples
  headers_list <- list("Content-Type" = "application/json")
  if (length(header_params) > 0) {
    headers_list <- c(headers_list, header_params)
  }
  
  # Preparar query
  query <- if (length(query_params) > 0) query_params else NULL
  
  # Preparar body
  body <- if (length(body_params) > 0) {
    toJSON(body_params, auto_unbox = TRUE)
  } else {
    NULL
  }
  
  # cat(sprintf("Fazendo requisição %s para: %s\n", toupper(method), url))
  if (!is.null(body)) {
    cat("Body:", body, "\n")
  }
  
  # Fazer a requisição - versão simplificada
  response <- tryCatch({
    switch(tolower(method),
           "get" = httr::GET(url, query = query, httr::content_type("application/json")),
           "post" = httr::POST(url, query = query, body = body, httr::content_type("application/json")),
           "put" = httr::PUT(url, query = query, body = body, httr::content_type("application/json")),
           "delete" = httr::DELETE(url, query = query, httr::content_type("application/json")),
           "patch" = httr::PATCH(url, query = query, body = body, httr::content_type("application/json")),
           stop(paste("Método HTTP não suportado:", method))
    )
  }, error = function(e) {
    return(list(
      status_code = 0,
      body = paste("Erro na requisição:", e$message),
      success = FALSE
    ))
  })
  
  # Processar resposta
  if (inherits(response, "response")) {
    status <- httr::status_code(response)
    body_content <- tryCatch({
      httr::content(response, "text", encoding = "UTF-8")
    }, error = function(e) {
      "Erro ao ler corpo da resposta"
    })
    
    # Tentar fazer parse do JSON se possível
    parsed_body <- tryCatch({
      jsonlite::fromJSON(body_content, simplifyVector = TRUE)
    }, error = function(e) {
      body_content  # Retorna texto bruto se não for JSON
    })
    
    return(list(
      status_code = status,
      body = parsed_body,
      success = status >= 200 && status < 300
    ))
  } else {
    return(response)  # Já é uma lista de erro
  }
}
obter_frame_robo <- function(url, diretorio, prefixos_permitidos) {
  
  url_api_validada <- validar_url(url, prefixos_permitidos)
  
  # Verifica se o diretório existe; se não, cria
  if (!dir.exists(diretorio)) {
    dir.create(diretorio, recursive = TRUE)
  }
  
  # 1. Fazer requisição para a URL e obter o JSON
  resposta <- tryCatch(
    {
      GET(url_api_validada)
    },
    error = function(e) {
      stop(paste("Erro ao acessar a URL:", e$message))
    }
  )
  
  # Verificar se a requisição foi bem-sucedida
  if (status_code(resposta) != 200) {
    stop(paste("Erro HTTP:", status_code(resposta)))
  }
  
  # 2. Parse do JSON
  dados <- tryCatch(
    {
      fromJSON(content(resposta, "text", encoding = "UTF-8"), simplifyVector = TRUE)
    },
    error = function(e) {
      stop(paste("Erro ao processar JSON:", e$message))
    }
  )
  
  # 3. Extrair image_url e timestamp
  if (!"image_url" %in% names(dados)) {
    stop("O JSON retornado não contém o campo 'image_url'.")
  }
  
  image_url <- dados$image_url
  image_url_validada <- validar_url(image_url, prefixos_permitidos)
  timestamp <- dados$timestamp
  
  # Gerar nome do arquivo com base no timestamp
  nome_arquivo <- sprintf("frame_%s.jpg", gsub("[^0-9]", "", as.character(timestamp)))
  caminho_arquivo <- file.path(diretorio, nome_arquivo)
  
  # 4. Baixar a imagem e salvar no disco
  imagem_resposta <- tryCatch(
    {
      GET(image_url_validada, write_disk(caminho_arquivo, overwrite = TRUE))
    },
    error = function(e) {
      stop(paste("Erro ao baixar a imagem:", e$message))
    }
  )
  
  if (status_code(imagem_resposta) != 200) {
    stop(paste("Erro ao baixar a imagem (HTTP", status_code(imagem_resposta), ")"))
  }
  
  # 5. Codificar a imagem em base64
  if (!file.exists(caminho_arquivo)) {
    stop("A imagem não foi salva corretamente.")
  }
  
  con <- file(caminho_arquivo, "rb")
  imagem_binaria <- readBin(con, "raw", file.info(caminho_arquivo)$size)
  close(con)
  
  imagem_base64 <- base64encode(imagem_binaria)
  
  # 6. Retornar lista com caminho e base64
  return(list(
    caminho_salvo = caminho_arquivo,
    base64 = imagem_base64
  ))
}
obter_status_robo <- function(url) {
  # 1. Fazer a requisição à URL
  resposta <- tryCatch(
    {
      GET(url)
    },
    error = function(e) {
      stop(paste("Erro ao acessar a URL:", e$message))
    }
  )
  
  # 2. Verificar se retornou HTTP 200
  if (status_code(resposta) != 200) {
    stop(paste("Erro HTTP ao obter status do robô:", status_code(resposta)))
  }
  
  # 3. Parse do JSON
  dados <- tryCatch(
    {
      fromJSON(content(resposta, "text", encoding = "UTF-8"), simplifyVector = TRUE)
    },
    error = function(e) {
      stop(paste("Erro ao processar JSON:", e$message))
    }
  )
  
  # 4. (Opcional) Validações básicas
  if (!all(c("servo_system", "camera_system", "timestamp") %in% names(dados))) {
    warning("O JSON retornado não contém todas as chaves esperadas ('servo_system', 'camera_system', 'timestamp').")
  }
  
  # 5. Retorna a lista com os dados
  return(dados)
}
salvar_se_diferente <- function(tools_obj) {
  
  # Verificar se o objeto existe e tem a estrutura esperada
  if (!exists("tools_obj") || is.null(tools_obj)) {
    warning("Objeto tools_usadas não encontrado ou é NULL")
    return(FALSE)
  }
  
  # Extrair dados relevantes
  tryCatch({
    function_name <- tools_obj$function_name
    pin <- tools_obj$response_body$pin
    angle <- tools_obj$response_body$angle
    
    # Verificar se todos os campos necessários existem
    if (is.null(function_name) || is.null(pin) || is.null(angle)) {
      warning("Campos obrigatórios ausentes no objeto tools_usadas")
      return(FALSE)
    }
    
    # Criar estado atual para comparação
    estado_atual <- list(
      function_name = function_name,
      pin = pin,
      angle = angle
    )
    
    # Comparar com último estado
    if (is.null(ultimo_estado) || !identical(estado_atual, ultimo_estado)) {
      
      # Criar nova linha
      nova_linha <- data.frame(
        timestamp = Sys.time(),
        function_name = function_name,
        pin = pin,
        angle = angle,
        stringsAsFactors = FALSE
      )
      
      # Adicionar ao histórico
      historico_tools <<- rbind(historico_tools, nova_linha)
      
      # Atualizar último estado
      ultimo_estado <<- estado_atual
      
      # Salvar em arquivo CSV (opcional - descomente se quiser persistir)
      # write.csv(historico_tools, "historico_tools.csv", row.names = FALSE)
      
      cat("✓ Novo registro salvo:", function_name, "| Pin:", pin, "| Angle:", angle, "\n")
      return(TRUE)
    } else {
      cat("• Valores idênticos ao anterior - não salvando\n")
      return(FALSE)
    }
    
  }, error = function(e) {
    warning(paste("Erro ao processar tools_usadas:", e$message))
    return(FALSE)
  })
}
monitorar_tools <- function() {
  if (exists("tools_usadas", envir = .GlobalEnv)) {
    # Se tools_usadas for uma lista com múltiplos elementos
    if (is.list(tools_usadas) && length(tools_usadas) > 0) {
      # Processar o primeiro elemento (ou adapte conforme sua estrutura)
      salvar_se_diferente(tools_usadas[[1]])
    } else {
      salvar_se_diferente(tools_usadas)
    }
  }
}
ver_historico <- function(n = 10) {
  if (nrow(historico_tools) == 0) {
    cat("Nenhum registro no histórico ainda.\n")
    return(invisible())
  }
  
  cat("📊 Últimos", min(n, nrow(historico_tools)), "registros:\n")
  print(tail(historico_tools, n))
  
  cat("\n📈 Resumo:\n")
  cat("Total de registros:", nrow(historico_tools), "\n")
  cat("Funções únicas:", length(unique(historico_tools$function_name)), "\n")
  cat("Pins únicos:", length(unique(historico_tools$pin)), "\n")
  cat("Range de ângulos:", min(historico_tools$angle), "-", max(historico_tools$angle), "\n")
}
salvar_historico <- function(arquivo = "historico_tools.csv") {
  if (nrow(historico_tools) > 0) {
    write.csv(historico_tools, arquivo, row.names = FALSE)
    cat("✓ Histórico salvo em:", arquivo, "\n")
  } else {
    cat("⚠ Nenhum dado para salvar\n")
  }
}
carregar_historico <- function(arquivo = "historico_tools.csv") {
  if (file.exists(arquivo)) {
    historico_tools <<- read.csv(arquivo, stringsAsFactors = FALSE)
    historico_tools$timestamp <<- as.POSIXct(historico_tools$timestamp)
    cat("✓ Histórico carregado:", nrow(historico_tools), "registros\n")
  } else {
    cat("⚠ Arquivo não encontrado:", arquivo, "\n")
  }
}
validar_url <- function(url_para_validar, prefixos_permitidos) {
  # Verifica se a URL começa com algum dos prefixos permitidos
  url_e_permitida <- any(sapply(prefixos_permitidos, function(prefixo) {
    startsWith(url_para_validar, prefixo)
  }))
  
  if (!url_e_permitida) {
    # NUNCA inclua a URL maliciosa na mensagem de erro para evitar log injection.
    stop("Tentativa de acesso a uma URL não autorizada foi bloqueada.", call. = FALSE)
  }
  
  return(url_para_validar)
}