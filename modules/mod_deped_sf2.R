# modules/mod_deped_sf2.R
# --------------------------------------------------------------------
# Self-contained fluidPage app + merged-cell-aware SF2 template writer
# Writes ONLY: Date row, DOW row, No.+Name, attendance marks; preserves merges & formulas.
# --------------------------------------------------------------------

library("shiny")
library("DT")
library("dplyr")
library("tidyr")
library("lubridate")
library("writexl")
library("digest")
library("shinyjs")
library("tibble")
library("qrcode")
library("zip")
library("readxl")
library("grid")
library("htmltools")
library("openxlsx")

# ---- Options ----
# options(shiny.host = "0.0.0.0", shiny.port = 8080)
# options(shiny.maxRequestSize = 30*1024^2) # ~30MB uploads
# options(shiny.fullstacktrace = TRUE)

# ---- Storage paths ----
.data_dir            <- "data"
.users_rds_path      <- file.path(.data_dir, "users.rds")
.attendance_rds_path <- file.path(.data_dir, "attendance.rds")
.qr_dir              <- file.path(.data_dir, "qrcodes")
.base_url_path       <- file.path(.data_dir, "qr_base_url.txt")
.secret_path         <- file.path(.data_dir, "qr_secret.txt")

if (!dir.exists(.data_dir)) dir.create(.data_dir, recursive = TRUE)
if (!dir.exists(.qr_dir))   dir.create(.qr_dir,   recursive = TRUE)
addResourcePath('qr', .qr_dir)

# Secret on first run
if (!file.exists(.secret_path)) {
  writeLines(substr(digest(Sys.time(), algo = "sha256"), 1, 32), .secret_path)
}

# ---- Helpers ----
`%or%`  <- function(a,b) if (!is.null(a) && length(a)>0 && nzchar(a)) a else b
`%||%`  <- function(a,b) if (!is.null(a) && !is.na(a) && nzchar(a)) a else b
sanitize_dirname <- function(x) gsub("[^0-9A-Za-z_\\-]", "_", x)
status_choices <- c("Present"="P","Absent"="A","Late"="L","Excused"="E","Other"="O")

save_atomic <- function(df, path) {
  tmp <- paste0(path, ".tmp"); saveRDS(df, tmp)
  ok <- FALSE; try({ ok <- file.rename(tmp, path) }, silent = TRUE)
  if (!isTRUE(ok)) { file.copy(tmp, path, overwrite = TRUE); unlink(tmp) }
}

load_users <- function() {
  if (file.exists(.users_rds_path)) {
    u <- readRDS(.users_rds_path)
    if (!"gender" %in% names(u)) u$gender <- "Unknown"
    u
  } else tibble::tibble(
    user_id = character(), full_name = character(), gender = character(),
    role = character(), password_hash = character(), section = character()
  )
}
load_attendance <- function() {
  if (file.exists(.attendance_rds_path)) readRDS(.attendance_rds_path) else
    tibble::tibble(
      record_id = character(), user_id = character(), full_name = character(),
      section = character(), date = as.Date(character()), time = character(),
      source = character(), status = character(), note = character(),
      created_at = as.POSIXct(character())
    )
}
save_users      <- function(df) save_atomic(df, .users_rds_path)
save_attendance <- function(df) save_atomic(df, .attendance_rds_path)

# Settings
load_base_url <- function() if (file.exists(.base_url_path)) readLines(.base_url_path, warn = FALSE)[1] else "http://localhost:8080/"
save_base_url <- function(x) writeLines(x, .base_url_path)
load_secret   <- function() readLines(.secret_path, warn = FALSE)[1]
save_secret   <- function(x) writeLines(x, .secret_path)

# Seeder
seed_users <- function() {
  if (!file.exists(.users_rds_path)) {
    users <- tibble::tibble(
      user_id = c("T001","S001"),
      full_name = c("EMLSTAT","Juan Dela Cruz"),
      gender = c("F","M"),
      role = c("teacher","student"),
      password_hash = c(digest("SF2","sha256"), digest("S001","sha256")),
      section = c("Sec A","Sec A")
    ); saveRDS(users, .users_rds_path)
  }
}
seed_attendance <- function() {
  if (!file.exists(.attendance_rds_path)) {
    att <- tibble::tibble(
      record_id=character(), user_id=character(), full_name=character(),
      section=character(), date=as.Date(character()), time=character(),
      source=character(), status=character(), note=character(),
      created_at=as.POSIXct(character())
    ); saveRDS(att, .attendance_rds_path)
  }
}
seed_users(); seed_attendance()

# QR helpers
make_simple_qr_url <- function(base_url, lrn) paste0(base_url, "?lrn=", URLencode(lrn))
verify_signed <- function(lrn, date, sig, secret) {
  expected <- digest(paste0(paste(lrn, as.character(date), sep = "\n"), "\n", secret), algo = "sha256")
  isTRUE(sig == expected)
}

# Import helpers
normalize_names <- function(x) tolower(gsub("[ .]+", "_", trimws(x)))
pick_col <- function(nms, candidates) nms[match(TRUE, nms %in% candidates, nomatch = 0)] %||% NA_character_
import_students_excel <- function(path, section, make_password_lrn = TRUE) {
  df <- readxl::read_excel(path)
  names(df) <- normalize_names(names(df))
  lrn_col    <- pick_col(names(df), c("lrn","student_number","student_no","studentnum","user_id","id","student_id"))
  name_col   <- pick_col(names(df), c("full_name","fullname","name","student_name","student_fullname","studentname"))
  gender_col <- pick_col(names(df), c("gender","sex"))
  if (is.na(lrn_col) || is.na(name_col) || is.na(gender_col))
    stop("Excel must contain columns for LRN, Full Name, and Gender.")
  out <- df %>%
    transmute(
      user_id   = as.character(.data[[lrn_col]]),
      full_name = as.character(.data[[name_col]]),
      gender    = as.character(.data[[gender_col]])
    ) %>%
    mutate(user_id=trimws(user_id), full_name=trimws(full_name), gender=trimws(gender)) %>%
    filter(nzchar(user_id), nzchar(full_name), nzchar(gender)) %>%
    distinct(user_id, .keep_all = TRUE)
  out$role <- "student"; out$section <- section
  if (isTRUE(make_password_lrn)) out$password_hash <- vapply(out$user_id, digest, character(1), algo="sha256")
  out
}
upsert_students <- function(existing_users, imported_df, reset_pw = TRUE) {
  added <- 0L; updated <- 0L; u <- existing_users
  if (!"gender" %in% names(u)) u$gender <- "Unknown"
  for (i in seq_len(nrow(imported_df))) {
    row <- imported_df[i,]
    if (row$user_id %in% u$user_id) {
      idx <- which(u$user_id == row$user_id)
      u$full_name[idx] <- row$full_name; u$gender[idx] <- row$gender
      u$role[idx] <- "student"; u$section[idx] <- row$section
      if (isTRUE(reset_pw) && !is.null(row$password_hash)) u$password_hash[idx] <- row$password_hash
      updated <- updated + 1L
    } else {
      ph <- if (isTRUE(reset_pw) && !is.null(row$password_hash)) row$password_hash else digest(row$user_id,"sha256")
      u <- dplyr::bind_rows(u, tibble::tibble(
        user_id=row$user_id, full_name=row$full_name, gender=row$gender,
        role="student", password_hash=ph, section=row$section
      )); added <- added + 1L
    }
  }
  list(users = u, added = added, updated = updated)
}

# Reports (we’ll use only D# columns; NO totals written to template)
make_monthly_matrix <- function(att, users, month_date, exclude_weekends = TRUE) {
  if (!"gender" %in% names(users)) users$gender <- NA_character_
  gender_rank <- function(g) {
    x <- tolower(substr(ifelse(is.na(g), "", trimws(g)), 1, 1))
    dplyr::case_when(x == "m" ~ 1L, x == "f" ~ 2L, TRUE ~ 3L)
  }
  month_start <- lubridate::floor_date(as.Date(month_date), "month")
  month_end   <- lubridate::ceiling_date(month_start, "month") - lubridate::days(1)
  days_all    <- seq.Date(month_start, month_end, by="day")
  days_work   <- if (isTRUE(exclude_weekends)) days_all[!lubridate::wday(days_all) %in% c(1,7)] else days_all
  
  if (nrow(users) == 0 || length(days_work) == 0) {
    return(tibble::tibble(user_id = users$user_id, full_name = users$full_name, gender = users$gender, section = users$section))
  }
  
  att_month_all <- att %>%
    dplyr::filter(date >= month_start, date <= month_end) %>%
    dplyr::arrange(date, created_at) %>%
    dplyr::group_by(user_id, date) %>%
    dplyr::slice_tail(n = 1) %>% dplyr::ungroup()
  att_month <- att_month_all %>% dplyr::filter(date %in% days_work)
  
  grid <- tidyr::expand_grid(user_id = users$user_id[users$role == "student"], date = days_work)
  wide <- grid %>%
    dplyr::left_join(att_month %>% dplyr::select(user_id, date, status), by = c("user_id","date")) %>%
    dplyr::mutate(status = dplyr::coalesce(status, "")) %>%
    dplyr::mutate(daynum = lubridate::day(date)) %>%
    dplyr::select(user_id, daynum, status) %>%
    tidyr::pivot_wider(names_from = daynum, values_from = status, names_prefix = "D") %>%
    dplyr::left_join(users %>% dplyr::filter(role == "student") %>% dplyr::select(user_id, full_name, gender, section), by = "user_id") %>%
    dplyr::relocate(user_id, full_name, gender, section) %>%
    dplyr::mutate(.g_order = gender_rank(gender)) %>%
    dplyr::arrange(section, .g_order, full_name) %>%
    dplyr::select(-.g_order)
  
  wide
}

# Display
build_users_display <- function(u) {
  if (!"gender" %in% names(u)) u$gender <- "Unknown"
  u %>%
    mutate(
      Actions = ifelse(
        role == "student",
        sprintf('<button class="btn btn-xs btn-danger del-btn" data-id="%s" title="Delete student">Delete</button>',
                htmltools::htmlEscape(user_id)),
        '<button class="btn btn-xs btn-secondary" disabled title="Teachers cannot be deleted">Locked</button>'
      )
    ) %>%
    select(user_id, full_name, gender, role, section, Actions)
}

# ============================================================
#                    MODULE UI (fluidPage)
# ============================================================
mod_deped_sf2_ui <- function(id) {
  ns <- NS(id)
  
  tagList(
    shinyjs::useShinyjs(),
    tags$head(tags$style(HTML("
    /* Layout helpers (unchanged) */
    .auth-box{max-width:520px;margin:24px auto}
    .note{color:#666}
    .status-badge{font-weight:600;padding:4px 10px;border-radius:8px;background:#eef}
    .qr-card{display:inline-block;margin:8px;padding:8px;border:1px solid #ddd;border-radius:6px;text-align:center}
    .qr-img{width:200px;height:200px}

    /* --- Bootstrap 3-like 'panel' look, recreated for Bootstrap 4 --- */
    .panel { background:#fff; border:1px solid #dee2e6; border-radius:8px; margin-bottom:16px;
             box-shadow:0 2px 8px rgba(0,0,0,.05); }
    .panel .panel-header { padding:10px 14px; font-weight:600; border-bottom:1px solid #e9ecef;
                           background:#f8f9fa; color:#0d6efd; }
    .panel .panel-body { padding:14px; }

    /* --- TabsetPanel color tweaks --- */
    .nav-tabs .nav-link { color:#0b5ed7; font-weight:600; }
    .nav-tabs .nav-link.active { color:#0b5ed7; background:#fff;
                                 border-color:#dee2e6 #dee2e6 #fff; }

    /* --- Buttons palette (keeps bs4Dash theme but nudges the colors) --- */
    .btn-primary { background-color:#0d6efd; border-color:#0b5ed7; }
    .btn-warning { background-color:#ffc107; border-color:#ffca2c; color:#212529; }
    .btn-danger  { background-color:#dc3545; border-color:#d32535; }
    .btn-success { background-color:#28a745; border-color:#218838; }

    /* --- Tables: header accent (for DT tables) --- */
    table.dataTable thead th { background:#f8f9fa; color:#0b5ed7; }

    /* --- Minor typography accents --- */
    h2, h3, .panel .panel-header { letter-spacing:.2px; }
  "))),
    
    
    tabsetPanel(
      id = ns("sf2_tabs"),
      
      # --- Login ---
      tabPanel(title = "Login", value = "login",
               div(class = "auth-box panel",
                   div(class = "panel-header", "Sign in"),
                   div(class = "panel-body",
                       radioButtons(ns("role"), "Role", choices = c("Student"="student","Teacher"="teacher"),
                                    inline = TRUE, selected = "teacher"),
                       textInput(ns("user_id"), "User ID (LRN)", placeholder = "T001"),
                       passwordInput(ns("password"), "Password (LRN for students)", placeholder = "SF2"),
                       actionButton(ns("login_btn"), "Login", class = "btn btn-primary"),
                       tags$p(class="note", "")
                   )
               )
      ),
      
      # --- Student (disabled by server) ---
      tabPanel(title = "Student", value = "student",
               fluidRow(
                 column(
                   width = 12,
                   div(class = "panel",
                       div(class = "panel-header", "Student Check-in"),
                       div(class = "panel-body",
                           uiOutput(ns("student_header")),
                           tags$hr(),
                           radioButtons(ns("student_status"), "Status", choices = status_choices, inline = TRUE, selected = "P"),
                           textAreaInput(ns("student_note"), "Optional note", rows = 2, placeholder = "e.g., Arrived 5 minutes late"),
                           actionButton(ns("btn_submit_att"), "Submit Attendance", class="btn btn-success"),
                           tags$span(id = ns("student_submit_msg"), class = "status-badge", "")
                       )
                   ),
                   div(class = "panel",
                       div(class = "panel-header", "Your recent submissions"),
                       div(class = "panel-body", DTOutput(ns("student_table")))
                   )
                 )
               )
      ),
      
      # --- Teacher ---
      tabPanel(title = "Teacher", value = "teacher",
               fluidRow(
                 column(
                   width = 12,
                   div(class = "panel",
                       div(class = "panel-header", "Daily Roll / Overrides"),
                       div(class = "panel-body",
                           dateInput(ns("teacher_date"), "Date", value = Sys.Date()),
                           selectInput(ns("teacher_section"), "Section", choices = NULL),
                           radioButtons(ns("teacher_set_status"), "Set status for selected rows", choices = status_choices, inline = TRUE),
                           textInput(ns("teacher_note"), "Note (optional)", placeholder = "e.g., Field trip"),
                           actionButton(ns("teacher_apply"), "Apply to Selected", class = "btn btn-warning"),
                           tags$br(), tags$br(),
                           DTOutput(ns("teacher_roll"))
                       )
                   ),
                   div(class = "panel",
                       div(class = "panel-header", "Monthly Report & Download"),
                       div(class = "panel-body",
                           uiOutput(ns("month_picker_ui")),
                           checkboxInput(ns("report_skip_weekends"), "Exclude weekends (Sat/Sun)", TRUE),
                           div(
                             style = "display:flex; gap:12px; align-items:flex-end; flex-wrap:wrap;",
                           
                             downloadButton(ns("download_report"), "Download Excel (Summary)")
                           ),
                           DTOutput(ns("monthly_preview"))
                       )
                   )
                 )
               )
      ),
      
      # --- Users ---
      tabPanel(title = "Users", value = "users",
               fluidRow(
                 column(
                   width = 12,
                   div(class = "panel",
                       div(class = "panel-header", "User Accounts (Teacher only)"),
                       div(class = "panel-body",
                           tags$p(class="note","Create or update users. Passwords are stored as SHA-256 hashes."),
                           tags$div(id = ns("user_form"),
                                    textInput(ns("new_user_id"),  "User ID (LRN)"),
                                    textInput(ns("new_full_name"),"Full name"),
                                    selectInput(ns("new_gender"), "Gender", choices=c("Male","Female","Other","Unknown"), selected="Unknown"),
                                    selectInput(ns("new_role"),   "Role", choices=c("teacher","student"), selected="student"),
                                    textInput(ns("new_section"),  "Section"),
                                    passwordInput(ns("new_password"), "Set/Reset password (leave blank to use LRN for students)")
                           ),
                           actionButton(ns("add_user"), "Add / Update User", class = "btn btn-danger"),
                           tags$hr(),
                           DTOutput(ns("users_table"))
                       )
                   )
                 )
               )
      ),
      
      # --- QR Codes ---
      tabPanel(title = "QR Codes", value = "qr",
               fluidRow(
                 column(
                   width = 12,
                   div(class = "panel",
                       div(class = "panel-header", "QR Settings"),
                       div(class = "panel-body",
                           textInput(ns("qr_base_url"), "Base URL (default http://localhost:8080/)", value = load_base_url()),
                           checkboxInput(ns("qr_secure"), "Secure mode (daily signed tokens)", value = FALSE),
                           passwordInput(ns("qr_secret"), "Secret key (used to sign tokens)",  value = load_secret()),
                           actionButton(ns("qr_save_settings"), "Save Settings", class = "btn btn-primary")
                           #tags$p(class="note", HTML("<b>Important:</b> On phones, <code>localhost</code> points to the phone itself. Use your server's LAN IP (e.g., <code>http://192.168.x.x:8080/</code>) when scanning from Android."))
                       )
                   ),
                   div(class = "panel",
                       div(class = "panel-header", "Import Students (Excel: LRN, full_name, gender) & QR"),
                       div(class = "panel-body",
                           fileInput(ns("students_excel"), "Upload Excel (.xlsx)", accept = c(".xlsx",".xls")),
                           selectInput(ns("import_section"), "Assign to Section", choices = NULL),
                           checkboxInput(ns("import_pw_lrn"), "Set/Reset password to LRN", TRUE),
                           actionButton(ns("import_btn"), "Import & Generate QRs (PNG)", class = "btn btn-warning"),
                           tags$hr(),
                           numericInput(ns("qr_size_cm"),   "Sticker QR size (cm)", value = 3.5, min=1, max=10, step=0.1),
                           numericInput(ns("qr_margin_mm"), "Page margins (mm)",    value = 10,  min=0, max=25, step=1),
                           numericInput(ns("qr_gutter_mm"), "Gap between stickers (mm)", value = 3, min=0, max=20, step=1),
                           numericInput(ns("qr_label_mm"),  "Label height (mm)",    value = 6,   min=0, max=15, step=1),
                           selectInput(ns("qr_orientation"),"A4 orientation", choices = c("Portrait"="portrait","Landscape"="landscape"), selected = "portrait"),
                           numericInput(ns("qr_label_cex"), "Label font size", value = 0.65, min=0.4, max=1.2, step=0.05),
                           checkboxInput(ns("qr_short_label"), "Use short name (first 10 chars) in stickers", TRUE),
                           downloadButton(ns("qr_zip"), "Download ZIP of PNGs"),
                           downloadButton(ns("qr_pdf"), "Download A4 PDF (stickers, print-ready)"),
                           tags$hr(),
                           uiOutput(ns("qr_preview"))
                       )
                   )
                 )
               )
      )
    )
  )
}

# ============================================================
#                   MODULE SERVER (fluidPage)
# ============================================================
mod_deped_sf2_server <- function(id,query = reactive(NULL)) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    
    # Live readers
    att_live   <- reactiveFileReader(2000, session, .attendance_rds_path, readRDS)
    users_live <- reactiveFileReader(1000, session, .users_rds_path, readRDS)
    
    # State
    rv <- reactiveValues(
      auth = list(is_auth = FALSE, role = NA_character_, user_id = NA_character_),
      qr_files = character(),
      base_url = load_base_url(),
      secret   = load_secret(),
      last_section = NULL,
      pending_delete_id = NULL
    )
    
    # Disable Student tab
    DISABLE_STUDENT_TAB <- TRUE
    observe({
      if (isTRUE(DISABLE_STUDENT_TAB) && identical(input$sf2_tabs, "student")) {
        updateTabsetPanel(session, "sf2_tabs", selected = "login")
        showNotification("Student tab is temporarily disabled. Please use QR scanning.", type = "warning")
      }
    })
    
    # QR auto check-in via URL
    observe({
      query <- parseQueryString(session$clientData$url_search)
      if (!is.null(query$lrn)) {
        lrn <- query$lrn; today <- Sys.Date()
        if (!is.null(query$date) && !is.null(query$sig)) {
          if (!verify_signed(lrn, as.Date(query$date), query$sig, rv$secret)) { showNotification("Invalid QR signature.", type="error"); return(NULL) }
          if (as.Date(query$date) != today) { showNotification("QR token expired or for a different date.", type="warning"); return(NULL) }
        }
        u <- users_live() %>% dplyr::filter(user_id == lrn, role == "student")
        if (nrow(u) == 1) {
          last <- att_live() %>% dplyr::filter(user_id == lrn, date == today) %>% dplyr::arrange(created_at) %>% dplyr::slice_tail(n=1)
          if (nrow(last) == 1 && last$status[1] == "P") showNotification(sprintf("Already present: %s", u$full_name[1]), type="message")
          else {
            new_row <- tibble::tibble(
              record_id = paste0("R", as.integer(Sys.time()), sample(1000:9999, 1)),
              user_id = u$user_id, full_name = u$full_name, section = u$section,
              date = today, time = format(Sys.time(), "%H:%M:%S"), source = "qr", status = "P",
              note = "QR auto-check-in", created_at = Sys.time()
            )
            att <- dplyr::bind_rows(att_live(), dplyr::select(new_row, dplyr::any_of(names(att_live()))))
            save_attendance(att); showNotification(sprintf("Present recorded for %s", u$full_name[1]), type="message")
          }
        } else showNotification("Unknown LRN.", type="error")
      }
    })
    
    # Sections list upkeep
    observe({
      u <- users_live()
      clean_sections <- function(x) { x <- x[!is.na(x) & nzchar(x)]; sort(unique(x)) }
      secs_students <- u %>% dplyr::filter(role == "student") %>% dplyr::pull(section) %>% clean_sections()
      secs_teachers <- u %>% dplyr::filter(role == "teacher") %>% dplyr::pull(section) %>% clean_sections()
      secs_all <- sort(unique(c(secs_students, secs_teachers)))
      updateSelectInput(session, "teacher_section", choices = secs_students)
      updateSelectInput(session, "import_section",  choices = secs_all)
      
      if (isTRUE(rv$auth$is_auth) && identical(rv$auth$role, "teacher")) {
        t_sec <- u %>% dplyr::filter(user_id == rv$auth$user_id) %>% dplyr::pull(section)
        t_sec <- t_sec[!is.na(t_sec) & nzchar(t_sec)]
        if (length(t_sec) && t_sec[1] %in% secs_all) updateSelectInput(session, "import_section", selected = t_sec[1])
      }
    })
    
    # Login -> redirect to Teacher
    observeEvent(input$login_btn, {
      req(input$user_id, input$password, input$role)
      u <- users_live(); rec <- u %>% dplyr::filter(user_id == input$user_id, role == input$role)
      if (nrow(rec) == 1 && digest(input$password, "sha256") == rec$password_hash[1]) {
        rv$auth$is_auth <- TRUE; rv$auth$role <- input$role; rv$auth$user_id <- input$user_id
        updateTabsetPanel(session, "sf2_tabs", selected = "teacher")
        showNotification(sprintf("Welcome, %s", rec$full_name[1]), type="message")
      } else showNotification("Invalid credentials", type="error")
    })
    
    # Guard Teacher-only tabs
    observe({
      req(input$sf2_tabs)  # ensures input$tabs exists before checking
      
      if (input$sf2_tabs %in% c("teacher","users","qr")) {
        # make sure rv$auth exists and has the needed fields
        req(rv$auth$is_auth, rv$auth$role)
        
        if (!isTRUE(rv$auth$is_auth) || rv$auth$role != "teacher") {
          showNotification("Teacher login required.", type = "error")
          updateTabsetPanel(session, "sf2_tabs", selected = "login")
        }
      }
    })
    
    # Teacher roll (sorted)
    teacher_roll_data <- reactive({
      req(rv$auth$is_auth, rv$auth$role == "teacher", input$teacher_section, input$teacher_date)
      u <- users_live()
      students <- u %>% dplyr::filter(role == "student", section == input$teacher_section)
      selected_day <- lubridate::as_date(input$teacher_date)
      today_att <- att_live() %>%
        dplyr::filter(date == selected_day) %>% dplyr::arrange(created_at) %>%
        dplyr::group_by(user_id) %>% dplyr::slice_tail(n = 1) %>% dplyr::ungroup() %>%
        dplyr::select(user_id, status, note)
      out <- students %>% dplyr::left_join(today_att, by = "user_id") %>%
        dplyr::mutate(status = dplyr::coalesce(status, "")) %>%
        dplyr::select(user_id, full_name, section, status, note)
      out %>%
        dplyr::left_join(u %>% dplyr::select(user_id, gender), by = "user_id") %>%
        dplyr::mutate(.g = { x <- tolower(substr(ifelse(is.na(gender), "", trimws(gender)),1,1)); dplyr::case_when(x=="m"~1L,x=="f"~2L,TRUE~3L) }) %>%
        dplyr::arrange(section, .g, full_name) %>% dplyr::select(-gender, -.g)
    })
    output$teacher_roll <- renderDT({
      datatable(teacher_roll_data(), selection = "multiple", rownames = FALSE, options = list(pageLength = 8))
    }, server = TRUE)
    
    observeEvent(input$teacher_apply, {
      req(rv$auth$is_auth, rv$auth$role == "teacher")
      idx <- input$teacher_roll_rows_selected
      if (!length(idx)) { showNotification("Select at least one row.", type="warning"); return() }
      selected_day <- lubridate::as_date(input$teacher_date)
      df <- teacher_roll_data(); sel <- df[idx,]
      new_rows <- sel %>% transmute(
        record_id = paste0("R", as.integer(Sys.time()), sample(1000:9999,1)),
        user_id, full_name, section, date = selected_day,
        time = format(Sys.time(), "%H:%M:%S"), source = "teacher",
        status = input$teacher_set_status, note = input$teacher_note %or% "",
        created_at = Sys.time()
      )
      att <- dplyr::bind_rows(att_live(), new_rows); save_attendance(att)
      showNotification("Statuses updated.", type = "message")
    })
    
    # Monthly report UI
    output$month_picker_ui <- renderUI({
      req(rv$auth$is_auth, rv$auth$role == "teacher")
      this_month <- lubridate::floor_date(Sys.Date(), unit = "month")
      tagList(
        dateInput(ns("report_month"), "Month", value = this_month, format = "yyyy-mm", startview = "year"),
        selectInput(ns("report_section"), "Section (optional)", choices = c("All", sort(unique(users_live()$section))), selected = "All")
      )
    })
    
    # Preview table (NO totals columns)
    make_preview <- reactive({
      req(rv$auth$is_auth, rv$auth$role == "teacher", input$report_month)
      month_date <- lubridate::as_date(input$report_month)
      users <- users_live() %>% dplyr::filter(role == "student")
      if (!is.null(input$report_section) && input$report_section != "All")
        users <- users %>% dplyr::filter(section == input$report_section)
      make_monthly_matrix(att_live(), users, month_date, exclude_weekends = isTRUE(input$report_skip_weekends))
    })
    output$monthly_preview <- renderDT({
      req(make_preview()); datatable(make_preview(), options = list(scrollX = TRUE, pageLength = 10), rownames = FALSE)
    })
    
    # Summary download (still available)
    output$download_report <- downloadHandler(
      filename = function() {
        d <- if (!is.null(input$report_month)) as.Date(input$report_month) else Sys.Date()
        sprintf("attendance_%s.xlsx", format(d, "%Y_%m"))
      },
      content = function(file) {
        req(rv$auth$is_auth, rv$auth$role == "teacher"); req(input$report_month)
        month_date <- as.Date(input$report_month)
        users <- users_live() %>% dplyr::filter(role == "student")
        if (!is.null(input$report_section) && input$report_section != "All")
          users <- users %>% dplyr::filter(section == input$report_section)
        Summary <- as.data.frame(make_monthly_matrix(att_live(), users, month_date, exclude_weekends = isTRUE(input$report_skip_weekends)), check.names = FALSE)
        Raw_Log <- as.data.frame(att_live(), check.names = FALSE)
        writexl::write_xlsx(list(Summary = Summary, Raw_Log = Raw_Log), path = file)
      }
    )
    
   
    
    # Users table + actions
    users_proxy <- dataTableProxy(ns("users_table"))
    output$users_table <- renderDT({
      req(rv$auth$is_auth, rv$auth$role == "teacher")
      u <- users_live()
      datatable(
        build_users_display(u),
        escape = FALSE, selection = "none", rownames = FALSE, options = list(pageLength = 8),
        
        callback = DT::JS(
          sprintf(
            "table.on('click','button.del-btn',function(){var uid=$(this).data('id');Shiny.setInputValue('%s', uid, {priority:'event'});});",
            ns("delete_user_id")
          )
        )
        
        
        
        
      )
    }, server = TRUE)
    
    observeEvent(input$add_user, {
      req(rv$auth$is_auth, rv$auth$role == "teacher")
      if (!nzchar(input$new_user_id) || !nzchar(input$new_full_name) || !nzchar(input$new_section)) {
        showNotification("Please fill: User ID, Full name, and Section.", type="warning"); return()
      }
      if (!nzchar(input$new_role))   { showNotification("Choose a Role.", type="warning"); return() }
      if (!nzchar(input$new_gender)) { showNotification("Choose a Gender.", type="warning"); return() }
      
      u <- users_live()
      if (input$new_user_id %in% u$user_id) {
        idx <- which(u$user_id == input$new_user_id)
        u$full_name[idx] <- input$new_full_name
        u$gender[idx]    <- input$new_gender
        u$role[idx]      <- input$new_role
        u$section[idx]   <- input$new_section
        if (nzchar(input$new_password)) u$password_hash[idx] <- digest(input$new_password,"sha256")
        msg <- "User updated."
      } else {
        default_pw <- if (input$new_role == "student") input$new_user_id else "changeme"
        ph <- if (nzchar(input$new_password)) digest(input$new_password,"sha256") else digest(default_pw,"sha256")
        u <- dplyr::bind_rows(u, tibble::tibble(
          user_id = input$new_user_id, full_name = input$new_full_name, gender = input$new_gender,
          role = input$new_role, password_hash = ph, section = input$new_section
        )); msg <- "User added."
      }
      save_users(u); replaceData(users_proxy, build_users_display(u), resetPaging = FALSE, rownames = FALSE)
      showNotification(msg, type="message")
      shinyjs::reset(ns("user_form")); updateSelectInput(session,"new_role","student"); updateSelectInput(session,"new_gender","Unknown")
    })
    
    observeEvent(input$delete_user_id, {
      req(input$delete_user_id); uid <- as.character(input$delete_user_id); u <- users_live()
      target <- u %>% dplyr::filter(user_id == uid)
      if (nrow(target) == 0) { showNotification("User not found.", type="error"); return() }
      if (target$role[1] != "student") { showNotification("Teacher accounts cannot be deleted.", type="warning"); return() }
      rv$pending_delete_id <- uid
      showModal(modalDialog(
        title = "Confirm Deletion", easyClose = FALSE,
        footer = tagList(modalButton("Cancel"), actionButton(ns("confirm_delete"), "Delete", class="btn btn-danger")),
        div(
          p(HTML(sprintf("Delete student <b>%s</b> (<code>%s</code>) from section <b>%s</b>?",
                         htmltools::htmlEscape(target$full_name[1]),
                         htmltools::htmlEscape(target$user_id[1]),
                         htmltools::htmlEscape(target$section[1] %or% "")))),
          tags$p(class="note","This removes the student account and QR images. Attendance logs remain for record‑keeping.")
        )
      ))
    })
    observeEvent(input$confirm_delete, {
      req(rv$pending_delete_id); uid <- rv$pending_delete_id; u <- users_live()
      target <- u %>% dplyr::filter(user_id == uid)
      if (nrow(target) == 1 && target$role[1] == "student") {
        u_new <- u %>% dplyr::filter(user_id != uid); save_users(u_new)
        qr_files <- list.files(.qr_dir, pattern = paste0("^", uid, "\\.(png|svg)$"), recursive = TRUE, full.names = TRUE, ignore.case = TRUE)
        if (length(qr_files)) try(unlink(qr_files), silent = TRUE)
        replaceData(users_proxy, build_users_display(u_new), resetPaging = FALSE, rownames = FALSE)
        showNotification(sprintf("Deleted student %s (%s).", target$full_name[1], uid), type="message")
      } else showNotification("Cannot delete this account.", type="error")
      rv$pending_delete_id <- NULL; removeModal()
    })
    
    # QR settings & import (unchanged)
    observeEvent(input$qr_save_settings, {
      req(rv$auth$is_auth, rv$auth$role == "teacher")
      rv$base_url <- input$qr_base_url %or% rv$base_url
      rv$secret   <- input$qr_secret   %or% rv$secret
      save_base_url(rv$base_url); save_secret(rv$secret)
      showNotification("QR settings saved.", type = "message")
    })
    observeEvent(input$import_btn, {
      req(rv$auth$is_auth, rv$auth$role == "teacher"); req(input$students_excel); req(input$import_section)
      withProgress(message = "Importing students & generating QR...", value = 0, {
        incProgress(0.2)
        imp <- tryCatch({
          import_students_excel(input$students_excel$datapath, section = input$import_section, make_password_lrn = isTRUE(input$import_pw_lrn))
        }, error = function(e) { showNotification(e$message, type="error"); NULL })
        if (is.null(imp)) return(NULL)
        res <- upsert_students(users_live(), imp, reset_pw = isTRUE(input$import_pw_lrn)); save_users(res$users)
        base_url <- input$qr_base_url %or% rv$base_url
        students <- users_live() %>% dplyr::filter(role == "student", section == input$import_section)
        if (nrow(students) == 0) { showNotification("No students in section.", type="warning"); return(NULL) }
        out_dir <- file.path(.qr_dir, sanitize_dirname(input$import_section)); if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
        old <- list.files(out_dir, pattern = "\\.(png|svg)$", full.names = TRUE); if (length(old)) unlink(old)
        files <- character(0)
        for (i in seq_len(nrow(students))) {
          lrn <- students$user_id[i]; fname <- file.path(out_dir, paste0(lrn, ".png"))
          url <- make_simple_qr_url(base_url, lrn)
          png(fname, width = 600, height = 600); par(mar = c(0,0,0,0)); plot(qrcode::qr_code(url), axes = FALSE); dev.off()
          files <- c(files, fname)
        }
        rv$qr_files <- files; rv$last_section <- input$import_section
        incProgress(1); showNotification(sprintf("Imported %d students. Generated %d QR PNGs.", nrow(imp), length(files)), type="message")
      })
    })
    
    
    
    observe({
      req(input$sf2_tabs)
      query <- parseQueryString(session$clientData$url_search)
      if (!is.null(query$lrn) && nzchar(query$lrn)) {
        updateTabsetPanel(session, "sf2_tabs", selected = "login")  # Show login tab
        
        # Auto attendance logic
        lrn <- query$lrn
        today <- Sys.Date()
        u <- users_live()
        stu <- u %>% dplyr::filter(user_id == lrn, role == "student")
        
        if (nrow(stu) == 1) {
          last <- att_live() %>%
            dplyr::filter(user_id == lrn, date == today) %>%
            dplyr::arrange(created_at) %>%
            dplyr::slice_tail(n = 1)
          
          if (nrow(last) == 0 || last$status[1] != "P") {
            new_row <- tibble::tibble(
              record_id = paste0("R", as.integer(Sys.time()), sample(1000:9999, 1)),
              user_id = stu$user_id,
              full_name = stu$full_name,
              section = stu$section,
              date = today,
              time = format(Sys.time(), "%H:%M:%S"),
              source = "qr",
              status = "P",
              note = "QR auto-check-in",
              created_at = Sys.time()
            )
            att <- dplyr::bind_rows(att_live(), new_row)
            save_attendance(att)
            showNotification(sprintf("Present recorded for %s", stu$full_name[1]), type = "message")
          } else {
            showNotification(sprintf("Already present: %s", stu$full_name[1]), type = "message")
          }
        } else {
          showNotification("Unknown LRN.", type = "error")
        }
      }
    })
    
    
    output$qr_preview <- renderUI({
      req(rv$qr_files); n <- min(length(rv$qr_files), 8)
      tags$div(lapply(seq_len(n), function(i) {
        f <- rv$qr_files[i]; section_dir <- basename(dirname(f)); src <- paste0('qr/', section_dir, '/', basename(f))
        tags$div(class="qr-card", tags$img(src = src, class="qr-img"), tags$p(basename(rv$qr_files[i])))
      }))
    })
    output$qr_zip <- downloadHandler(
      filename = function() {
        sec <- rv$last_section %or% input$import_section %or% "section"
        paste0("qr_", sanitize_dirname(sec), "_", format(Sys.Date(), "%Y%m%d"), ".zip")
      },
      content = function(file) { req(rv$qr_files); zip::zipr(zipfile = file, files = rv$qr_files) }
    )
    output$qr_pdf <- downloadHandler(
      filename = function() {
        sec_real <- rv$last_section %or% input$import_section %or% "section"
        paste0("qr_stickers_", sanitize_dirname(sec_real), "_", format(Sys.Date(), "%Y%m%d"), ".pdf")
      },
      content = function(file) {
        sec_real <- rv$last_section %or% input$import_section
        if (is.null(sec_real) || !nzchar(sec_real)) stop("No section selected for PDF.")
        students <- users_live() %>% dplyr::filter(role == "student", section == sec_real)
        if (nrow(students) == 0) stop("No students in section: ", sec_real)
        base_url <- input$qr_base_url %or% rv$base_url; if (!nzchar(base_url)) base_url <- "http://localhost:8080/"
        orientation <- input$qr_orientation %or% "portrait"
        page_w_cm <- if (orientation == "portrait") 21.0 else 29.7
        page_h_cm <- if (orientation == "portrait") 29.7 else 21.0
        qr_size_cm <- as.numeric(input$qr_size_cm %or% 3.5); margin_mm  <- as.numeric(input$qr_margin_mm %or% 10)
        gutter_mm  <- as.numeric(input$qr_gutter_mm %or% 3); label_mm   <- as.numeric(input$qr_label_mm %or% 6)
        label_cex  <- as.numeric(input$qr_label_cex %or% 0.65)
        margin_cm <- margin_mm/10; gutter_cm <- gutter_mm/10; label_cm <- label_mm/10
        cell_w_cm <- qr_size_cm; cell_h_cm <- qr_size_cm + ifelse(label_cm > 0, label_cm, 0)
        avail_w_cm <- page_w_cm - 2*margin_cm; avail_h_cm <- page_h_cm - 2*margin_cm
        cols <- max(1, floor((avail_w_cm + gutter_cm) / (cell_w_cm + gutter_cm)))
        rows <- max(1, floor((avail_h_cm + gutter_cm) / (cell_h_cm + gutter_cm)))
        per_page <- rows*cols; if (per_page < 1) stop("Sticker too large or margins too big for page.")
        cm2in <- function(x) x/2.54
        grDevices::pdf(file, width = cm2in(page_w_cm), height = cm2in(page_h_cm)); on.exit({ grDevices::dev.off() }, add = TRUE)
        draw_qr <- function(m, left_cm, top_cm, size_cm) {
          img <- as.raster(ifelse(m, "#000000FF", "#FFFFFFFF"))
          grid::grid.raster(img, x = grid::unit(left_cm, "cm"), y = grid::unit(top_cm, "cm"),
                            width = grid::unit(size_cm, "cm"), height = grid::unit(size_cm, "cm"),
                            just = c("left","top"), interpolate = FALSE)
        }
        n <- nrow(students); pages <- ceiling(n / per_page)
        for (pg in seq_len(pages)) {
          grid::grid.newpage(); idx_start <- (pg-1)*per_page + 1; idx_end <- min(pg*per_page, n); i_seq <- idx_start:idx_end
          for (k in seq_along(i_seq)) {
            i <- i_seq[k]; r <- ceiling(k/cols); c <- k - (r-1)*cols
            left_cm <- margin_cm + (c-1)*(cell_w_cm + gutter_cm); top_cm <- page_h_cm - margin_cm - (r-1)*(cell_h_cm + gutter_cm)
            url <- make_simple_qr_url(base_url, students$user_id[i]); m <- qrcode::qr_code(url)
            draw_qr(m, left_cm, top_cm, qr_size_cm)
            if (label_cm > 0) {
              lab_y <- top_cm - qr_size_cm - 0.05
              label_name <- if (isTRUE(input$qr_short_label)) substr(trimws(students$full_name[i]), 1, 10) else students$full_name[i]
              grid::grid.text(sprintf("%s\n%s", label_name, students$user_id[i]),
                              x = grid::unit(left_cm + qr_size_cm/2, "cm"),
                              y = grid::unit(lab_y, "cm"),
                              just = c("center","top"), gp = grid::gpar(cex = label_cex))
            }
          }
        }
      }
    )
    
    # Persist
    session$onSessionEnded(function() {
      att <- isolate(att_live())
      usr <- isolate(users_live())
      if (!file.exists(.attendance_rds_path)) seed_attendance()
      save_attendance(att)
      save_users(usr)
    })
  })
}