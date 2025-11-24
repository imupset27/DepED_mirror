# modules/mod_deped_sf2.R
# --------------------------------------------------------------------------------
# Self-contained fluidPage app + DepEd SF2 template writer
# Key features:
# - Per-teacher isolation & admin override
# - Data-driven no-class days: header date is shown only if there is at least one attendance record for that weekday
# - Missing gender warning; Unknown appended to Girls block
# - Auto-hide unused rows (blank + height=0) in Boys/Girls blocks
# - QR generation & stickers, monthly preview, summary Excel
# --------------------------------------------------------------------------------
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

# ---- Optional runtime settings ----
# options(shiny.host = "0.0.0.0", shiny.port = 8080)
# options(shiny.maxRequestSize = 30*1024^2) # ~30MB uploads
# options(shiny.fullstacktrace = TRUE)

# ---- Storage paths ----
.data_dir             <- "data"
.users_rds_path       <- file.path(.data_dir, "users.rds")
.attendance_rds_path  <- file.path(.data_dir, "attendance.rds")
.qr_dir               <- file.path(.data_dir, "qrcodes")
.base_url_path        <- file.path(.data_dir, "qr_base_url.txt")
.secret_path          <- file.path(.data_dir, "qr_secret.txt")
.sf2_template_path    <- "sf2_template.xlsx"   # Ensure this file exists
.sf2_sheet_name       <- "sf2"

if (!dir.exists(.data_dir)) dir.create(.data_dir, recursive = TRUE)
if (!dir.exists(.qr_dir)) dir.create(.qr_dir, recursive = TRUE)
addResourcePath('qr', .qr_dir)

# Secret on first run
if (!file.exists(.secret_path)) {
  writeLines(substr(digest(Sys.time(), algo = "sha256"), 1, 32), .secret_path)
}

# ---- Helpers ----
`%or%`  <- function(a,b) if (!is.null(a) && length(a)>0 && nzchar(a)) a else b          # scalar fallback
`%||%`  <- function(a,b) if (!is.null(a) && !is.na(a) && nzchar(a)) a else b            # scalar coalesce

# Vector-safe string coalescer: replaces NA/"" with default element-wise
safe_chr <- function(x, default = "") {
  if (is.null(x)) return(character(0))
  out <- as.character(x)
  out[is.na(out) | !nzchar(out)] <- default
  out
}

sanitize_dirname <- function(x) gsub("[^0-9A-Za-z_\\-]", "_", x)
status_choices   <- c("Present"="P","Absent"="A","Late"="L","Excused"="E","Other"="O")

save_atomic <- function(df, path) {
  tmp <- paste0(path, ".tmp"); saveRDS(df, tmp)
  ok <- FALSE; try({ ok <- file.rename(tmp, path) }, silent = TRUE)
  if (!isTRUE(ok)) { file.copy(tmp, path, overwrite = TRUE); unlink(tmp) }
}

# ---- Users / Attendance IO ----
load_users <- function() {
  if (file.exists(.users_rds_path)) {
    u <- readRDS(.users_rds_path)
    # Ensure columns exist
    if (!"gender"   %in% names(u)) u$gender   <- "Unknown"
    if (!"owner_id" %in% names(u)) u$owner_id <- NA_character_
    if (!"section"  %in% names(u)) u$section  <- NA_character_
    if (!"role"     %in% names(u)) u$role     <- "student"
    
    # Backfill owner_id by matching teacher/admin in same section (best-effort)
    needs_owner <- is.na(u$owner_id) & u$role == "student" & !is.na(u$section) & nzchar(u$section)
    if (any(needs_owner)) {
      teachers <- u %>% dplyr::filter(role %in% c("teacher","admin")) %>% dplyr::select(user_id, section)
      u$owner_id[needs_owner] <- vapply(which(needs_owner), function(i) {
        sec <- u$section[i]
        owner <- teachers$user_id[match(sec, teachers$section)]
        ifelse(is.na(owner), NA_character_, owner)
      }, character(1))
    }
    u
  } else tibble::tibble(
    user_id = character(), full_name = character(), gender = character(),
    role = character(), password_hash = character(), section = character(),
    owner_id = character()
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
      user_id       = c("ADMIN","T001","S001"),
      full_name     = c("Administrator","EMLSTAT","Juan Dela Cruz"),
      gender        = c("Other","F","M"),
      role          = c("admin","teacher","student"),
      password_hash = c(digest("ADMIN","sha256"), digest("SF2","sha256"), digest("S001","sha256")),
      section       = c(NA_character_,"Sec A","Sec A"),
      owner_id      = c(NA_character_,"T001","T001")
    )
    saveRDS(users, .users_rds_path)
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

import_students_excel <- function(path, section, make_password_lrn = TRUE, owner_id) {
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
  
  out$role        <- "student"
  out$section     <- section
  out$owner_id    <- owner_id
  if (isTRUE(make_password_lrn)) out$password_hash <- vapply(out$user_id, digest, character(1), algo="sha256")
  out
}

upsert_students <- function(existing_users, imported_df, reset_pw = TRUE, actor_id, actor_role) {
  added <- 0L; updated <- 0L; u <- existing_users
  if (!"gender"   %in% names(u)) u$gender   <- "Unknown"
  if (!"owner_id" %in% names(u)) u$owner_id <- NA_character_
  
  for (i in seq_len(nrow(imported_df))) {
    row <- imported_df[i,]
    # Only allow teacher to add/update their own students; admin can do all
    if (actor_role != "admin" && !identical(row$owner_id, actor_id)) next
    if (row$user_id %in% u$user_id) {
      idx <- which(u$user_id == row$user_id)
      # Prevent cross-ownership updates unless admin
      if (actor_role != "admin" && !isTRUE(u$owner_id[idx] == actor_id)) next
      
      u$full_name[idx] <- row$full_name; u$gender[idx] <- row$gender
      u$role[idx]      <- "student";     u$section[idx] <- row$section
      u$owner_id[idx]  <- row$owner_id %||% u$owner_id[idx]
      if (isTRUE(reset_pw) && !is.null(row$password_hash)) u$password_hash[idx] <- row$password_hash
      updated <- updated + 1L
    } else {
      ph <- if (isTRUE(reset_pw) && !is.null(row$password_hash)) row$password_hash else digest(row$user_id,"sha256")
      u <- dplyr::bind_rows(u, tibble::tibble(
        user_id=row$user_id, full_name=row$full_name, gender=row$gender,
        role="student", password_hash=ph, section=row$section, owner_id=row$owner_id
      ))
      added <- added + 1L
    }
  }
  list(users = u, added = added, updated = updated)
}

# ---- Monthly report (matrix used for preview & summary) ----
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

# ---- Display table helper ----
build_users_display <- function(u) {
  if (!"gender"   %in% names(u)) u$gender   <- "Unknown"
  if (!"owner_id" %in% names(u)) u$owner_id <- NA_character_
  u %>%
    mutate(
      Owner = ifelse(role=="student", owner_id, NA_character_),
      Actions = ifelse(
        role == "student",
        sprintf('<button class="btn btn-xs btn-danger del-btn" data-id="%s" title="Delete student">Delete</button>',
                htmltools::htmlEscape(user_id)),
        '<button class="btn btn-xs btn-secondary" disabled title="Teachers cannot be deleted">Locked</button>'
      )
    ) %>%
    select(user_id, full_name, gender, role, section, Owner, Actions)
}

# ============================================================
# DepEd SF2 Template Export helpers
# ============================================================

# Build the 5x5 (Mon–Fri × 5 weeks) header for G11:AE11, based on actual attendance:
# - If a weekday has zero attendance records, leave the header cell blank.
# - Weekends are excluded by construction.
build_weekday_header <- function(month_date, att_latest_df) {
  month_start <- lubridate::floor_date(as.Date(month_date), "month")
  month_end   <- lubridate::ceiling_date(month_start, "month") - lubridate::days(1)
  
  # Normalize types
  att_latest_df <- att_latest_df %>%
    dplyr::mutate(date = as.Date(date), user_id = as.character(user_id))
  
  # Days within the month that have at least one record
  has_attendance <- att_latest_df %>%
    dplyr::filter(date >= month_start, date <= month_end) %>%
    dplyr::count(date, name = "n") %>%
    dplyr::mutate(has = n > 0) %>%
    dplyr::select(date, has)
  
  # First Monday of the month
  target <- 2L # Monday in lubridate::wday (Sun=1)
  offset <- (target - lubridate::wday(month_start) + 7L) %% 7L
  first_mon <- month_start + lubridate::days(offset)
  
  dates <- as.Date(rep(NA_character_, 25))
  for (w in 0:4) {
    for (d in 0:4) {
      j  <- w*5 + d + 1
      dt <- first_mon + lubridate::days(w*7 + d)
      in_month <- (dt >= month_start && dt <= month_end)
      if (in_month) {
        flag <- has_attendance$has[match(dt, has_attendance$date)]
        dates[j] <- if (isTRUE(flag)) dt else as.Date(NA)
      } else {
        dates[j] <- as.Date(NA)
      }
    }
  }
  labels <- vapply(dates, function(x) if (is.na(x)) "" else as.character(lubridate::day(x)), character(1))
  list(dates = dates, labels = labels)
}

# Create attendance matrix (rows = user_ids; cols = 25 dates); blanks where header is blank
build_attendance_matrix <- function(user_ids, header_dates, att_latest_df) {
  cols <- length(header_dates)
  rows <- length(user_ids)
  m <- matrix("", nrow = rows, ncol = cols)
  if (!nrow(att_latest_df) || !rows) return(m)
  
  att_latest_df <- att_latest_df %>%
    dplyr::mutate(user_id = as.character(user_id),
                  date    = as.Date(date))
  
  for (j in seq_len(cols)) {
    dt <- header_dates[j]
    if (is.na(dt)) { m[, j] <- ""; next }  # Blank column when header is blank
    day_df <- att_latest_df %>%
      dplyr::filter(date == dt, user_id %in% user_ids) %>%
      dplyr::select(user_id, status)
    if (!nrow(day_df)) { m[, j] <- ""; next }
    stat_map <- setNames(safe_chr(day_df$status, default=""), day_df$user_id)
    m[, j] <- safe_chr(stat_map[user_ids], default = "")
  }
  m
}

# Write into the template:
# - Month (AA6), Section (AF8), Dates header (G11:AE11)
# - Boys names (B13:B52) & attendance (G13:AE52), auto-hide unused rows
# - Girls names (B54:B93) & attendance (G54:AE93), auto-hide unused rows
# - Teacher name at AE120
write_sf2_template <- function(
    template_path, sheet_name, file_out,
    month_date, section, teacher_name,
    boys_df, girls_df, att_df,
    hide_extra_rows = TRUE
) {
  if (!file.exists(template_path)) stop("Template not found: ", template_path)
  wb <- openxlsx::loadWorkbook(template_path)
  
  # --- Month name at AA6 (col 27) ---
  month_label <- toupper(format(as.Date(month_date), "%B"))
  openxlsx::writeData(wb, sheet = sheet_name, x = month_label, startRow = 6, startCol = 27, colNames = FALSE)
  
  # --- Section at AF8 (col 32) ---
  openxlsx::writeData(wb, sheet = sheet_name, x = section %||% "", startRow = 8, startCol = 32, colNames = FALSE)
  
  # --- Dates header G11:AE11 (attendance-aware) ---
  hdr <- build_weekday_header(month_date, att_df)
  if (length(hdr$labels) != 25) stop("Header must contain 25 weekday columns; got ", length(hdr$labels))
  hdr_row <- matrix(hdr$labels, nrow = 1)
  openxlsx::writeData(wb, sheet = sheet_name, x = hdr_row, startRow = 11, startCol = 7, colNames = FALSE, rowNames = FALSE)
  
  # --- Names blocks (cap 40) ---
  boys_names  <- head(boys_df$full_name, 40L)
  girls_names <- head(girls_df$full_name, 40L)
  
  # Boys names into B13:B52
  if (length(boys_names)) {
    openxlsx::writeData(
      wb, sheet = sheet_name,
      x = data.frame(Name = boys_names, check.names = FALSE),
      startRow = 13, startCol = 2, colNames = FALSE, rowNames = FALSE
    )
  } else {
    openxlsx::writeData(
      wb, sheet = sheet_name,
      x = data.frame(Name = rep("", 40), check.names = FALSE),
      startRow = 13, startCol = 2, colNames = FALSE, rowNames = FALSE
    )
  }
  
  # Girls names into B54:B93
  if (length(girls_names)) {
    openxlsx::writeData(
      wb, sheet = sheet_name,
      x = data.frame(Name = girls_names, check.names = FALSE),
      startRow = 54, startCol = 2, colNames = FALSE, rowNames = FALSE
    )
  } else {
    openxlsx::writeData(
      wb, sheet = sheet_name,
      x = data.frame(Name = rep("", 40), check.names = FALSE),
      startRow = 54, startCol = 2, colNames = FALSE, rowNames = FALSE
    )
  }
  
  # --- Attendance blocks ---
  boys_ids  <- head(boys_df$user_id, 40L)
  girls_ids <- head(girls_df$user_id, 40L)
  
  boys_mat  <- if (length(boys_ids))  build_attendance_matrix(boys_ids,  hdr$dates, att_df) else matrix("", nrow=0, ncol=length(hdr$dates))
  girls_mat <- if (length(girls_ids)) build_attendance_matrix(girls_ids, hdr$dates, att_df) else matrix("", nrow=0, ncol=length(hdr$dates))
  
  # Boys attendance into G13:AE52
  if (nrow(boys_mat)) {
    openxlsx::writeData(wb, sheet = sheet_name, x = boys_mat, startRow = 13, startCol = 7, colNames = FALSE, rowNames = FALSE)
  } else {
    openxlsx::writeData(wb, sheet = sheet_name,
                        x = matrix("", nrow = 40, ncol = 25),
                        startRow = 13, startCol = 7, colNames = FALSE, rowNames = FALSE)
  }
  
  # Girls attendance into G54:AE93
  if (nrow(girls_mat)) {
    openxlsx::writeData(wb, sheet = sheet_name, x = girls_mat, startRow = 54, startCol = 7, colNames = FALSE, rowNames = FALSE)
  } else {
    openxlsx::writeData(wb, sheet = sheet_name,
                        x = matrix("", nrow = 40, ncol = 25),
                        startRow = 54, startCol = 7, colNames = FALSE, rowNames = FALSE)
  }
  
  # --- Auto-hide unused rows (blank + height 0) ---
  if (isTRUE(hide_extra_rows)) {
    # Boys block rows 13..52 (40 rows)
    n_boys <- length(boys_names)
    if (n_boys < 40) {
      rows_to_hide_boys <- seq(13 + n_boys, 52)
      if (length(rows_to_hide_boys)) {
        openxlsx::writeData(
          wb, sheet = sheet_name,
          x = data.frame(Name = rep("", length(rows_to_hide_boys)), check.names = FALSE),
          startRow = min(rows_to_hide_boys), startCol = 2,
          colNames = FALSE, rowNames = FALSE
        )
        openxlsx::writeData(
          wb, sheet = sheet_name,
          x = matrix("", nrow = length(rows_to_hide_boys), ncol = 25),
          startRow = min(rows_to_hide_boys), startCol = 7,
          colNames = FALSE, rowNames = FALSE
        )
        openxlsx::setRowHeights(wb, sheet = sheet_name, rows = rows_to_hide_boys, heights = 0)
      }
    }
    
    # Girls block rows 54..93 (40 rows)
    n_girls <- length(girls_names)
    if (n_girls < 40) {
      rows_to_hide_girls <- seq(54 + n_girls, 93)
      if (length(rows_to_hide_girls)) {
        openxlsx::writeData(
          wb, sheet = sheet_name,
          x = data.frame(Name = rep("", length(rows_to_hide_girls)), check.names = FALSE),
          startRow = min(rows_to_hide_girls), startCol = 2,
          colNames = FALSE, rowNames = FALSE
        )
        openxlsx::writeData(
          wb, sheet = sheet_name,
          x = matrix("", nrow = length(rows_to_hide_girls), ncol = 25),
          startRow = min(rows_to_hide_girls), startCol = 7,
          colNames = FALSE, rowNames = FALSE
        )
        openxlsx::setRowHeights(wb, sheet = sheet_name, rows = rows_to_hide_girls, heights = 0)
      }
    }
  }
  
  # --- Teacher name at AE120 ---
  openxlsx::writeData(wb, sheet = sheet_name, x = teacher_name %||% "", startRow = 120, startCol = 31, colNames = FALSE)
  
  # Save
  openxlsx::saveWorkbook(wb, file_out, overwrite = TRUE)
}

# ============================================================
# MODULE UI (fluidPage)
# ============================================================
mod_deped_sf2_ui <- function(id) {
  ns <- NS(id)
  tagList(
    shinyjs::useShinyjs(),
    tags$head(tags$style(HTML("
      .auth-box{max-width:520px;margin:24px auto}
      .note{color:#666}
      .status-badge{font-weight:600;padding:4px 10px;border-radius:8px;background:#eef}
      .qr-card{display:inline-block;margin:8px;padding:8px;border:1px solid #ddd;border-radius:6px;text-align:center}
      .qr-img{width:200px;height:200px}
      .panel { background:#fff; border:1px solid #dee2e6; border-radius:8px; margin-bottom:16px;
               box-shadow:0 2px 8px rgba(0,0,0,.05); }
      .panel .panel-header { padding:10px 14px; font-weight:600; border-bottom:1px solid #e9ecef;
                             background:#f8f9fa; color:#0d6efd; }
      .panel .panel-body { padding:14px; }
      .nav-tabs .nav-link { color:#0b5ed7; font-weight:600; }
      .nav-tabs .nav-link.active { color:#0b5ed7; background:#fff;
                                   border-color:#dee2e6 #dee2e6 #fff; }
      .btn-primary { background-color:#0d6efd; border-color:#0b5ed7; }
      .btn-warning { background-color:#ffc107; border-color:#ffca2c; color:#212529; }
      .btn-danger  { background-color:#dc3545; border-color:#d32535; }
      .btn-success { background-color:#28a745; border-color:#218838; }
      table.dataTable thead th { background:#f8f9fa; color:#0b5ed7; }
      h2, h3, .panel .panel-header { letter-spacing:.2px; }
    "))),
    tabsetPanel(
      id = ns("sf2_tabs"),
      # --- Login ---
      tabPanel(title = "Login", value = "login",
               div(class = "auth-box panel",
                   div(class = "panel-header", "Sign in"),
                   div(class = "panel-body",
                       radioButtons(ns("role"), "Role",
                                    choices = c("Student"="student","Teacher"="teacher","Admin"="admin"),
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
      
      # --- Teacher/Admin ---
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
                             downloadButton(ns("download_report"), "Download Excel (Summary)"),
                             downloadButton(ns("download_sf2"),    "Download DepEd SF2 (Template)")
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
                       div(class = "panel-header", "User Accounts (Teacher/Admin)"),
                       div(class = "panel-body",
                           tags$p(class="note","Create or update users. Passwords are stored as SHA-256 hashes."),
                           tags$div(id = ns("user_form"),
                                    textInput(ns("new_user_id"), "User ID (LRN)"),
                                    textInput(ns("new_full_name"),"Full name"),
                                    selectInput(ns("new_gender"), "Gender", choices=c("Male","Female","Other","Unknown"), selected="Unknown"),
                                    selectInput(ns("new_role"), "Role", choices=c("teacher","student","admin"), selected="student"),
                                    textInput(ns("new_section"), "Section"),
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
                           passwordInput(ns("qr_secret"), "Secret key (used to sign tokens)", value = load_secret()),
                           actionButton(ns("qr_save_settings"), "Save Settings", class = "btn btn-primary")
                       )
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
                         numericInput(ns("qr_size_cm"), "Sticker QR size (cm)", value = 3.5, min=1, max=10, step=0.1),
                         numericInput(ns("qr_margin_mm"), "Page margins (mm)", value = 10, min=0, max=25, step=1),
                         numericInput(ns("qr_gutter_mm"), "Gap between stickers (mm)", value = 3, min=0, max=20, step=1),
                         numericInput(ns("qr_label_mm"), "Label height (mm)", value = 6, min=0, max=15, step=1),
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
}

# ============================================================
# MODULE SERVER (fluidPage)
# ============================================================
mod_deped_sf2_server <- function(id, query = reactive(NULL)) {
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
      secret = load_secret(),
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
    
    # QR auto check-in via URL (simple mode)
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
    
    # Sections list upkeep (per-owner filtering)
    observe({
      u <- users_live()
      
      clean_sections <- function(x) { x <- x[!is.na(x) & nzchar(x)]; sort(unique(x)) }
      
      secs_students_all <- u %>% dplyr::filter(role == "student") %>% dplyr::pull(section) %>% clean_sections()
      secs_teachers_all <- u %>% dplyr::filter(role %in% c("teacher","admin")) %>% dplyr::pull(section) %>% clean_sections()
      secs_all          <- sort(unique(c(secs_students_all, secs_teachers_all)))
      
      if (isTRUE(rv$auth$is_auth)) {
        actor_id   <- rv$auth$user_id
        actor_role <- rv$auth$role
        
        if (actor_role == "admin") {
          updateSelectInput(session, "teacher_section", choices = secs_all)
          updateSelectInput(session, "import_section",  choices = secs_all)
        } else if (actor_role == "teacher") {
          owned_secs <- u %>% dplyr::filter(role == "student", owner_id == actor_id) %>% dplyr::pull(section) %>% clean_sections()
          my_sec <- u %>% dplyr::filter(user_id == actor_id) %>% dplyr::pull(section); my_sec <- my_sec[!is.na(my_sec) & nzchar(my_sec)]
          owned_secs <- sort(unique(c(owned_secs, my_sec)))
          updateSelectInput(session, "teacher_section", choices = owned_secs)
          updateSelectInput(session, "import_section",  choices = owned_secs)
        }
      } else {
        updateSelectInput(session, "teacher_section", choices = secs_students_all)
        updateSelectInput(session, "import_section",  choices = secs_all)
      }
    })
    
    # Login -> redirect to Teacher tab
    observeEvent(input$login_btn, {
      req(input$user_id, input$password, input$role)
      u <- users_live(); rec <- u %>% dplyr::filter(user_id == input$user_id, role == input$role)
      if (nrow(rec) == 1 && digest(input$password, "sha256") == rec$password_hash[1]) {
        rv$auth$is_auth <- TRUE; rv$auth$role <- input$role; rv$auth$user_id <- input$user_id
        updateTabsetPanel(session, "sf2_tabs", selected = "teacher")
        showNotification(sprintf("Welcome, %s", rec$full_name[1]), type="message")
      } else showNotification("Invalid credentials", type="error")
    })
    
    # Guard Teacher/Admin-only tabs
    observe({
      req(input$sf2_tabs)
      if (input$sf2_tabs %in% c("teacher","users","qr")) {
        req(rv$auth$is_auth, rv$auth$role)
        if (!isTRUE(rv$auth$is_auth) || !(rv$auth$role %in% c("teacher","admin"))) {
          showNotification("Teacher or Admin login required.", type = "error")
          updateTabsetPanel(session, "sf2_tabs", selected = "login")
        }
      }
    })
    
    # Teacher/Admin roll (sorted, owner-filtered)
    teacher_roll_data <- reactive({
      req(rv$auth$is_auth, input$teacher_section, input$teacher_date)
      u <- users_live()
      actor_id   <- rv$auth$user_id
      actor_role <- rv$auth$role
      
      if (actor_role == "admin") {
        students <- u %>% dplyr::filter(role == "student", section == input$teacher_section)
      } else {
        students <- u %>% dplyr::filter(role == "student", section == input$teacher_section, owner_id == actor_id)
      }
      
      selected_day <- lubridate::as_date(input$teacher_date)
      today_att <- att_live() %>%
        dplyr::filter(date == selected_day) %>%
        dplyr::arrange(created_at) %>%
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
      req(rv$auth$is_auth, rv$auth$role %in% c("teacher","admin"))
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
    
    # Monthly report UI (sections restricted per role)
    output$month_picker_ui <- renderUI({
      req(rv$auth$is_auth, rv$auth$role %in% c("teacher","admin"))
      u <- users_live()
      actor_id   <- rv$auth$user_id
      actor_role <- rv$auth$role
      this_month <- lubridate::floor_date(Sys.Date(), unit = "month")
      
      clean_sections <- function(x) { x <- x[!is.na(x) & nzchar(x)]; sort(unique(x)) }
      secs <- if (actor_role == "admin") {
        c("All", clean_sections(u$section))
      } else {
        owned_secs <- u %>% dplyr::filter(role == "student", owner_id == actor_id) %>% dplyr::pull(section) %>% clean_sections()
        c("All", owned_secs)
      }
      
      tagList(
        dateInput(ns("report_month"), "Month", value = this_month, format = "yyyy-mm", startview = "year"),
        selectInput(ns("report_section"), "Section (optional)", choices = secs, selected = "All")
      )
    })
    
    # Monthly preview table
    make_preview <- reactive({
      req(rv$auth$is_auth, rv$auth$role %in% c("teacher","admin"), input$report_month)
      month_date <- lubridate::as_date(input$report_month)
      u <- users_live()
      actor_id   <- rv$auth$user_id
      actor_role <- rv$auth$role
      
      students <- u %>% dplyr::filter(role == "student")
      if (!is.null(input$report_section) && input$report_section != "All")
        students <- students %>% dplyr::filter(section == input$report_section)
      if (actor_role != "admin") students <- students %>% dplyr::filter(owner_id == actor_id)
      
      make_monthly_matrix(att_live(), students, month_date, exclude_weekends = isTRUE(input$report_skip_weekends))
    })
    
    output$monthly_preview <- renderDT({
      req(make_preview()); datatable(make_preview(), options = list(scrollX = TRUE, pageLength = 10), rownames = FALSE)
    })
    
    # Summary download
    output$download_report <- downloadHandler(
      filename = function() {
        d <- if (!is.null(input$report_month)) as.Date(input$report_month) else Sys.Date()
        sprintf("attendance_%s.xlsx", format(d, "%Y_%m"))
      },
      content = function(file) {
        req(rv$auth$is_auth, rv$auth$role %in% c("teacher","admin")); req(input$report_month)
        month_date <- as.Date(input$report_month)
        u <- users_live()
        actor_id   <- rv$auth$user_id
        actor_role <- rv$auth$role
        
        students <- u %>% dplyr::filter(role == "student")
        if (!is.null(input$report_section) && input$report_section != "All")
          students <- students %>% dplyr::filter(section == input$report_section)
        if (actor_role != "admin") students <- students %>% dplyr::filter(owner_id == actor_id)
        
        Summary <- as.data.frame(make_monthly_matrix(att_live(), students, month_date, exclude_weekends = isTRUE(input$report_skip_weekends)), check.names = FALSE)
        Raw_Log <- as.data.frame(att_live(), check.names = FALSE)
        writexl::write_xlsx(list(Summary = Summary, Raw_Log = Raw_Log), path = file)
      }
    )
    
    # --- DepEd SF2 Template download (attendance-aware header; no holiday UI) ---
    output$download_sf2 <- downloadHandler(
      filename = function() {
        d <- if (!is.null(input$report_month)) as.Date(input$report_month) else Sys.Date()
        sec <- input$report_section %||% "Section"
        sprintf("SF2_%s_%s.xlsx", sanitize_dirname(sec), format(d, "%Y_%m"))
      },
      content = function(file) {
        req(rv$auth$is_auth, rv$auth$role %in% c("teacher","admin")); req(input$report_month)
        month_date <- lubridate::as_date(input$report_month)
        
        # Require a specific section (template is per-section)
        req(input$report_section); if (identical(input$report_section, "All")) {
          showNotification("Please choose a specific Section (not 'All') for SF2 export.", type = "error"); stop("Section required")
        }
        section <- input$report_section
        
        if (!file.exists(.sf2_template_path)) {
          showNotification(sprintf("Template not found: %s", .sf2_template_path), type="error")
          stop("Template missing")
        }
        
        u <- users_live()
        actor_id   <- rv$auth$user_id
        actor_role <- rv$auth$role
        
        # Students for the chosen section with ownership enforced
        if (actor_role == "admin") {
          students <- u %>% dplyr::filter(role == "student", section == section)
        } else {
          students <- u %>% dplyr::filter(role == "student", section == section, owner_id == actor_id)
        }
        if (nrow(students) == 0) {
          showNotification(sprintf("No students found for section '%s'.", section), type="warning")
        }
        
        # Warn on missing/unknown gender
        gsafe  <- safe_chr(students$gender, default = "")
        gchars <- tolower(substr(gsafe, 1, 1))
        is_male   <- gchars == "m"
        is_female <- gchars == "f"
        unknown   <- !(is_male | is_female)
        if (any(unknown)) {
          unk_names <- paste(head(students$full_name[unknown], 5), collapse = ", ")
          msg <- sprintf("Warning: %d student(s) with missing/unknown gender (e.g., %s). They are appended to the GIRLS block for SF2 layout.", sum(unknown), unk_names)
          showNotification(msg, type = "warning")
        }
        
        boys_df  <- students %>% dplyr::filter(is_male)   %>% dplyr::arrange(full_name)
        girls_df <- students %>% dplyr::filter(is_female) %>% dplyr::arrange(full_name)
        others   <- students %>% dplyr::filter(unknown)   %>% dplyr::arrange(full_name)
        if (nrow(others)) girls_df <- dplyr::bind_rows(girls_df, others)
        
        # Build latest attendance per (user_id, date) for the whole month
        month_start <- lubridate::floor_date(as.Date(month_date), "month")
        month_end   <- lubridate::ceiling_date(month_start, "month") - lubridate::days(1)
        att_latest <- att_live() %>%
          dplyr::filter(date >= month_start, date <= month_end) %>%
          dplyr::arrange(date, created_at) %>%
          dplyr::group_by(user_id, date) %>%
          dplyr::slice_tail(n = 1) %>% dplyr::ungroup() %>%
          dplyr::select(user_id, date, status)
        
        # Teacher name (scalar)
        tname <- u %>% dplyr::filter(user_id == rv$auth$user_id) %>% dplyr::pull(full_name)
        teacher_name <- if (length(tname)) tname[1] else ""
        
        # Write into template
        write_sf2_template(
          template_path = .sf2_template_path,
          sheet_name    = .sf2_sheet_name,
          file_out      = file,
          month_date    = month_date,
          section       = section,
          teacher_name  = teacher_name,
          boys_df       = boys_df,
          girls_df      = girls_df,
          att_df        = att_latest,
          hide_extra_rows = TRUE
        )
      }
    )
    
    # Users table + actions (ownership enforced)
    users_proxy <- dataTableProxy(ns("users_table"))
    output$users_table <- renderDT({
      req(rv$auth$is_auth)
      u <- users_live()
      actor_id   <- rv$auth$user_id
      actor_role <- rv$auth$role
      
      if (actor_role == "admin") {
        show_df <- u
      } else {
        show_df <- u %>% dplyr::filter(
          (role == "student" & owner_id == actor_id) |
            (role == "teacher" & user_id == actor_id)
        )
      }
      
      datatable(
        build_users_display(show_df),
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
      req(rv$auth$is_auth)
      actor_id   <- rv$auth$user_id
      actor_role <- rv$auth$role
      
      if (!nzchar(input$new_user_id) || !nzchar(input$new_full_name) || !nzchar(input$new_section)) {
        showNotification("Please fill: User ID, Full name, and Section.", type="warning"); return()
      }
      if (!nzchar(input$new_role))   { showNotification("Choose a Role.",   type="warning"); return() }
      if (!nzchar(input$new_gender)) { showNotification("Choose a Gender.", type="warning"); return() }
      
      # Teachers cannot create other teachers/admins
      if (actor_role != "admin" && input$new_role != "student") {
        showNotification("Only admin can create or modify teacher/admin accounts.", type="error"); return()
      }
      
      u <- users_live()
      is_existing <- input$new_user_id %in% u$user_id
      
      desired_owner <- if (input$new_role == "student") actor_id else NA_character_
      
      if (is_existing) {
        idx <- which(u$user_id == input$new_user_id)
        # Ownership guard: teachers can only modify their students
        if (actor_role != "admin" && !(u$role[idx] == "student" && u$owner_id[idx] == actor_id)) {
          showNotification("You can only modify your own students.", type="error"); return()
        }
        u$full_name[idx] <- input$new_full_name
        u$gender[idx]    <- input$new_gender
        u$role[idx]      <- input$new_role
        u$section[idx]   <- input$new_section
        if (u$role[idx] == "student") u$owner_id[idx] <- desired_owner
        if (nzchar(input$new_password)) u$password_hash[idx] <- digest(input$new_password,"sha256")
        msg <- "User updated."
      } else {
        # Create
        default_pw <- if (input$new_role == "student") input$new_user_id else "changeme"
        ph <- if (nzchar(input$new_password)) digest(input$new_password,"sha256") else digest(default_pw,"sha256")
        
        u <- dplyr::bind_rows(u, tibble::tibble(
          user_id = input$new_user_id, full_name = input$new_full_name, gender = input$new_gender,
          role = input$new_role, password_hash = ph, section = input$new_section,
          owner_id = if (input$new_role == "student") desired_owner else NA_character_
        ))
        msg <- "User added."
      }
      
      save_users(u)
      display_u <- if (actor_role == "admin") u else u %>% dplyr::filter(
        (role=="student" & owner_id==actor_id) | (role=="teacher" & user_id==actor_id)
      )
      replaceData(users_proxy, build_users_display(display_u), resetPaging = FALSE, rownames = FALSE)
      showNotification(msg, type="message")
      shinyjs::reset(ns("user_form")); updateSelectInput(session,"new_role","student"); updateSelectInput(session,"new_gender","Unknown")
    })
    
    observeEvent(input$delete_user_id, {
      req(input$delete_user_id); uid <- as.character(input$delete_user_id); u <- users_live()
      target <- u %>% dplyr::filter(user_id == uid)
      if (nrow(target) == 0) { showNotification("User not found.", type="error"); return() }
      if (target$role[1] != "student") { showNotification("Teacher/admin accounts cannot be deleted here.", type="warning"); return() }
      rv$pending_delete_id <- uid
      showModal(modalDialog(
        title = "Confirm Deletion", easyClose = FALSE,
        footer = tagList(modalButton("Cancel"), actionButton(ns("confirm_delete"), "Delete", class="btn btn-danger")),
        div(
          p(HTML(sprintf("Delete student <b>%s</b> (<code>%s</code>) from section <b>%s</b>?",
                         htmltools::htmlEscape(target$full_name[1]),
                         htmltools::htmlEscape(target$user_id[1]),
                         htmltools::htmlEscape(target$section[1] %or% "")
          ))),
          tags$p(class="note","This removes the student account and QR images. Attendance logs remain for record‑keeping.")
        )
      ))
    })
    
    observeEvent(input$confirm_delete, {
      req(rv$pending_delete_id); uid <- rv$pending_delete_id; u <- users_live()
      actor_id   <- rv$auth$user_id
      actor_role <- rv$auth$role
      
      target <- u %>% dplyr::filter(user_id == uid)
      if (nrow(target) == 1 && target$role[1] == "student" &&
          (actor_role == "admin" || target$owner_id[1] == actor_id)) {
        u_new <- u %>% dplyr::filter(user_id != uid); save_users(u_new)
        qr_files <- list.files(.qr_dir, pattern = paste0("^", uid, "\\.(png|svg)$"), recursive = TRUE, full.names = TRUE, ignore.case = TRUE)
        if (length(qr_files)) try(unlink(qr_files), silent = TRUE)
        display_u <- if (actor_role == "admin") u_new else u_new %>% dplyr::filter(
          (role=="student" & owner_id==actor_id) | (role=="teacher" & user_id==actor_id)
        )
        replaceData(users_proxy, build_users_display(display_u), resetPaging = FALSE, rownames = FALSE)
        showNotification(sprintf("Deleted student %s (%s).", target$full_name[1], uid), type="message")
      } else {
        showNotification("You are not allowed to delete this account.", type="error")
      }
      rv$pending_delete_id <- NULL; removeModal()
    })
    
    # QR settings
    observeEvent(input$qr_save_settings, {
      req(rv$auth$is_auth, rv$auth$role %in% c("teacher","admin"))
      rv$base_url <- input$qr_base_url %or% rv$base_url
      rv$secret   <- input$qr_secret   %or% rv$secret
      save_base_url(rv$base_url); save_secret(rv$secret)
      showNotification("QR settings saved.", type = "message")
    })
    
    # Import students & generate QR (ownership enforced)
    observeEvent(input$import_btn, {
      req(rv$auth$is_auth, rv$auth$role %in% c("teacher","admin")); req(input$students_excel); req(input$import_section)
      withProgress(message = "Importing students & generating QR...", value = 0, {
        incProgress(0.2)
        imp <- tryCatch({
          import_students_excel(
            input$students_excel$datapath,
            section = input$import_section,
            make_password_lrn = isTRUE(input$import_pw_lrn),
            owner_id = rv$auth$user_id  # owner = uploader
          )
        }, error = function(e) { showNotification(e$message, type="error"); NULL })
        if (is.null(imp)) return(NULL)
        
        res <- upsert_students(
          users_live(), imp,
          reset_pw = isTRUE(input$import_pw_lrn),
          actor_id = rv$auth$user_id,
          actor_role = rv$auth$role
        ); save_users(res$users)
        
        base_url <- input$qr_base_url %or% rv$base_url
        u <- users_live()
        actor_id   <- rv$auth$user_id
        actor_role <- rv$auth$role
        
        # Students for this section respecting ownership
        if (actor_role == "admin") {
          students <- u %>% dplyr::filter(role == "student", section == input$import_section)
        } else {
          students <- u %>% dplyr::filter(role == "student", section == input$import_section, owner_id == actor_id)
        }
        if (nrow(students) == 0) { showNotification("No students in section.", type="warning"); return(NULL) }
        
        out_dir <- file.path(.qr_dir, sanitize_dirname(input$import_section)); if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
        old <- list.files(out_dir, pattern = "\\.(png|svg)$", full.names = TRUE); if (length(old)) unlink(old)
        
        files <- character(0)
        for (i in seq_len(nrow(students))) {
          lrn   <- students$user_id[i]; fname <- file.path(out_dir, paste0(lrn, ".png"))
          url   <- make_simple_qr_url(base_url, lrn)
          png(fname, width = 600, height = 600); par(mar = c(0,0,0,0)); plot(qrcode::qr_code(url), axes = FALSE); dev.off()
          files <- c(files, fname)
        }
        rv$qr_files <- files; rv$last_section <- input$import_section
        incProgress(1); showNotification(sprintf("Imported %d students. Generated %d QR PNGs.", nrow(imp), length(files)), type="message")
      })
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
        u <- users_live()
        actor_id   <- rv$auth$user_id
        actor_role <- rv$auth$role
        
        if (actor_role == "admin") {
          students <- u %>% dplyr::filter(role == "student", section == sec_real)
        } else {
          students <- u %>% dplyr::filter(role == "student", section == sec_real, owner_id == actor_id)
        }
        if (nrow(students) == 0) stop("No students in section: ", sec_real)
        
        base_url <- input$qr_base_url %or% rv$base_url; if (!nzchar(base_url)) base_url <- "http://localhost:8080/"
        orientation <- input$qr_orientation %or% "portrait"
        page_w_cm <- if (orientation == "portrait") 21.0 else 29.7
        page_h_cm <- if (orientation == "portrait") 29.7 else 21.0
        qr_size_cm <- as.numeric(input$qr_size_cm %or% 3.5); margin_mm <- as.numeric(input$qr_margin_mm %or% 10)
        gutter_mm  <- as.numeric(input$qr_gutter_mm %or% 3);  label_mm  <- as.numeric(input$qr_label_mm %or% 6)
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