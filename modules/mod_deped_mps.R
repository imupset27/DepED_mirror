# modules/mod_deped_mps.R

library(shiny)
library(shinyjs)
library(readxl)
library(dplyr)
library(stringr)
library(tibble)
library(purrr)
library(tidyr)
library(DT)
library(openxlsx)

# -------------------- UI --------------------
mod_deped_mps_ui <- function(id) {
  ns <- NS(id)
  
  fluidPage(
    useShinyjs(),
    titlePanel("MPS Extractor: Quarterly Assessment (Scores Only)"),
    sidebarLayout(
      sidebarPanel(
        width = 3,
        actionLink(ns("show_help"), label = "❓ What files should I upload?"),
        tags$br(), tags$br(),
        fileInput(
          ns("files"),
          "Upload ECR Excel Files (same subject, multiple sections)",
          multiple = TRUE,
          accept = c(".xlsx", ".xls")
        ),
        tags$small("Processing starts automatically after upload. A progress bar will appear."),
        tags$br(), tags$br(),
        
        # --- NEW: Global Quarter filter (applies to ALL outputs & Excel) ---
        selectInput(
          ns("quarter_filter"),
          label = "Quarter",
          choices = c("All", "Q1", "Q2", "Q3", "Q4"),
          selected = "All"
        ),
        
        tags$br(),
        downloadButton(ns("download_excel"), "\U0001F4E5 Download Consolidated MPS")
      ),
      mainPanel(
        width = 9,
        
        # Intro box
        div(
          id = ns("intro_box"),
          style = "background-color:#f8f9fa; padding:20px; border-radius:10px; box-shadow:0 2px 6px rgba(0,0,0,0.05);",
          tags$h4("\U0001F4D8 MPS Extractor (Scores Only)"),
          tags$p(
            class = "lead",
            HTML("Upload all ECR files for the subject (one per section).
For regular subjects (e.g., MATH), each file contains SUBJECT_Q1…Q4 sheets.
For MAPEH, each quarter file contains MUSIC_Q#, ARTS_Q#, PE_Q# (or PHYSICAL EDUCATION_Q#), and HEALTH_Q# sheets. The app also computes a MAPEH combined score per quarter by summing the four aspects per student. (only when all four exist).")
          ),
          tags$h5("Requirements"),
          tags$ul(
            tags$li("ECR files in Excel (.xlsx or .xls) — one per section for the same subject."),
            tags$li("Sheets present: INPUT DATA, SUMMARY OF QUARTERLY GRADES, and quarter sheets named like SUBJECT_Q1…SUBJECT_Q4 (e.g., MATH_Q1)."),
            tags$li("MAPEH quarter file should include MUSIC_Q#, ARTS_Q#, PE_Q# (or PHYSICAL EDUCATION_Q#), HEALTH_Q#."),
            tags$li("From each quarter sheet, the app reads: HPS at AF10, and student scores at AF12:AF112. No LRNs or Names are extracted."),
            tags$li("Grade Level is read from INPUT DATA!M7 and included in Data and Summary sheets.")
          ),
          tags$p("After upload, processing runs automatically. You'll see results and a download link when done."),
          tags$em("Data privacy: Files are processed locally in this app.")
        ),
        
        # Results box
        div(
          id = ns("results_box"),
          style = "display:none;",
          h4("Section/Quarter Summary (MPS)"),
          DTOutput(ns("summary_table")),
          tags$hr(),
          # --- NEW: Mastery Levels table (ENGLISH, MATHEMATICS, SCIENCE only) ---
          h4("Mastery Levels – ENGLISH, MATHEMATICS, SCIENCE"),
          tags$small("Distribution of learner percentages per quarter, bucketed by DepEd mastery bands."),
          DTOutput(ns("mastery_table")),
          tags$hr(),
          h4("Consolidated MPS (Preview)"),
          DTOutput(ns("table"))
          
          
          
        )
      )
    )
  )
}

# -------------------- SERVER --------------------
mod_deped_mps_server <- function(id) {
  moduleServer(id, function(input, output, session) {
    
    # ---------- Modal Help ----------
    show_mps_help <- function() {
      showModal(modalDialog(
        title = "Upload Instructions: ECR files for MPS extraction (Scores Only)",
        size = "l",
        easyClose = TRUE,
        footer = tagList(modalButton("Close")),
        tagList(
          tags$p("Upload the ECR Excel files for the same subject and grade level (one per section)."),
          tags$h4("✅ Files needed"),
          tags$ul(
            tags$li("Excel format (.xlsx or .xls), original DepEd ECR templates."),
            tags$li("Each file should contain: INPUT DATA, SUMMARY OF QUARTERLY GRADES, and quarter sheets named like SUBJECT_Q1…SUBJECT_Q4 (e.g., MATH_Q1)."),
            tags$li("For MAPEH quarter files: MUSIC_Q#, ARTS_Q#, PE_Q# (or PHYSICAL EDUCATION_Q#), HEALTH_Q#")
          ),
          tags$h4("\U0001F4C4 What we extract"),
          tags$ul(
            tags$li("From each quarter sheet (Q1–Q4): HPS at AF10, and learner Scores at AF12:AF112. We do not read LRNs or Names."),
            tags$li("Subject name is read from INPUT DATA!AI7; Grade Level from INPUT DATA!M7. Both are included in Data and Summary. A MAPEH combined score per quarter is computed when all four aspects exist for each student.")
          ),
          tags$h4("⚠️ Reminders"),
          tags$ul(
            tags$li("Do not rename or delete columns/rows in the template."),
            tags$li("Ensure quarter sheets follow the naming pattern (e.g., MATH_Q1, MUSIC_Q1, etc.).")
          ),
          tags$hr(),
          tags$h4("\U0001F5BC\uFE0F Sample (screenshot)"),
          tags$img(
            src = "ecr_sample.png",
            alt = "Sample quarter sheet screenshot",
            style = "max-width: 100%; border: 1px solid #ddd; border-radius:6px; box-shadow: 0 1px 4px rgba(0,0,0,0.1);"
          )
        )
      ))
    }
    
    observeEvent(TRUE, { show_mps_help() }, once = TRUE, ignoreInit = FALSE)
    observeEvent(input$show_help, { show_mps_help() })
    
    # ---------- Reactives ----------
    rv_data    <- reactiveVal(NULL)
    rv_summary <- reactiveVal(NULL)
    
    # --- NEW: Mastery table store ---
    rv_mastery <- reactiveVal(NULL)
    
    # Helper to read a single cell (A1 range)
    read_cell <- function(path, sheet, range) {
      out <- tryCatch({
        v <- readxl::read_excel(path, sheet = sheet, range = range, col_names = FALSE)
        if (nrow(v) > 0 && ncol(v) > 0) v[[1]][1] else NA
      }, error = function(e) NA)
      if (!is.na(out)) out <- str_squish(as.character(out))
      out
    }
    
    # Parse one ECR file -> consolidated tibble
    parse_one_file <- function(path, display_name) {
      sheets_all <- tryCatch(excel_sheets(path), error = function(e) character(0))
      if (length(sheets_all) == 0) return(NULL)
      
      subj <- tryCatch({
        s <- read_cell(path, sheet = "INPUT DATA", range = "AI7:AI7")
        if (is.na(s) || s == "") NA else toupper(s)
      }, error = function(e) NA)
      
      grade_lvl <- tryCatch({
        g <- read_cell(path, sheet = "INPUT DATA", range = "M7:M7")
        if (is.na(g) || g == "") NA else as.character(g)
      }, error = function(e) NA)
      
      q_sheets <- sheets_all[grepl("_Q[1-4]$", toupper(sheets_all))]
      if (length(q_sheets) == 0) {
        q_sheets <- sheets_all[grepl("Q[1-4]", toupper(sheets_all))]
      }
      
      aspect_patterns <- c("MUSIC", "ARTS", "PE", "PHYSICAL\\s+EDUCATION", "HEALTH")
      aspect_regex <- paste0("^(", paste(aspect_patterns, collapse = "|"), ")_Q[1-4]$")
      is_mapeh <- any(grepl(aspect_regex, toupper(q_sheets)))
      
      rows_seq <- 12:112
      
      if (is_mapeh) {
        matched <- tibble(sheet = q_sheets) %>%
          mutate(
            SheetUpper = toupper(sheet),
            Quarter    = paste0("Q", as.integer(str_extract(SheetUpper, "[1-4]"))),
            AspectRaw  = str_trim(str_replace(SheetUpper, "_Q[1-4]$", "")),
            Aspect     = case_when(
              AspectRaw == "PHYSICAL EDUCATION" ~ "PE",
              TRUE ~ AspectRaw
            ),
            Subject    = "MAPEH"
          )
        
        out_list <- pmap(
          list(matched$sheet, matched$Aspect, matched$Quarter),
          function(sh, aspect, quarter) {
            hps <- suppressWarnings(as.numeric(read_cell(path, sheet = sh, range = "AF10:AF10")))
            scores <- tryCatch({
              v <- readxl::read_excel(path, sheet = sh, range = "AF12:AF112", col_names = FALSE)[[1]]
              suppressWarnings(as.numeric(v))
            }, error = function(e) rep(NA_real_, length(rows_seq)))
            tibble(
              File         = display_name,
              Subject      = "MAPEH",
              GradeLevel   = grade_lvl,
              Aspect       = aspect,
              Sheet        = sh,
              Quarter      = quarter,
              StudentIndex = seq_along(scores),
              HPS          = hps,
              Score        = scores,
              Percent      = ifelse(!is.na(scores) & !is.na(hps) & hps > 0, round(100 * scores / hps, 2), NA_real_)
            )
          }
        )
        bind_rows(out_list)
        
      } else {
        out_list <- map(q_sheets, function(sh) {
          q_num  <- as.integer(str_extract(toupper(sh), "[1-4]"))
          quarter <- ifelse(is.na(q_num), NA, paste0("Q", q_num))
          hps <- suppressWarnings(as.numeric(read_cell(path, sheet = sh, range = "AF10:AF10")))
          scores <- tryCatch({
            v <- readxl::read_excel(path, sheet = sh, range = "AF12:AF112", col_names = FALSE)[[1]]
            suppressWarnings(as.numeric(v))
          }, error = function(e) rep(NA_real_, length(rows_seq)))
          tibble(
            File         = display_name,
            Subject      = ifelse(!is.na(subj), subj, toupper(str_split(sh, "_", 2)[[1]][1])),
            GradeLevel   = grade_lvl,
            Aspect       = "—",
            Sheet        = sh,
            Quarter      = quarter,
            StudentIndex = seq_along(scores),
            HPS          = hps,
            Score        = scores,
            Percent      = ifelse(!is.na(scores) & !is.na(hps) & hps > 0, round(100 * scores / hps, 2), NA_real_)
          )
        })
        bind_rows(out_list)
      }
    }
    
    observeEvent(input$files, {
      req(input$files)
      withProgress(message = "Processing uploaded ECR files...", value = 0, {
        paths  <- input$files$datapath
        fnames <- input$files$name
        n      <- length(paths)
        
        data_all <- vector("list", n)
        for (i in seq_along(paths)) {
          res <- tryCatch(parse_one_file(paths[i], display_name = fnames[i]), error = function(e) NULL)
          data_all[[i]] <- res
          incProgress(1/n, detail = sprintf("%s (%d/%d)", fnames[i], i, n))
        }
        
        data_all <- compact(data_all)
        
        if (length(data_all) == 0) {
          rv_data(NULL); rv_summary(NULL); rv_mastery(NULL)
        } else {
          df <- bind_rows(data_all) %>% filter(!is.na(Score))
          
          # Base summary per aspect
          base_summary <- df %>%
            group_by(File, Subject, GradeLevel, Quarter, Aspect) %>%
            summarise(
              N                    = sum(!is.na(Score)),
              HPS                  = suppressWarnings(first(na.omit(HPS))),
              `MEAN (Raw Score)`   = round(mean(Score, na.rm = TRUE), 2),
              MPS                  = round(mean(Percent, na.rm = TRUE), 2),
              `SD (Raw Score)`     = round(sd(Score, na.rm = TRUE), 2),
              .groups = "drop"
            ) %>%
            arrange(Subject, GradeLevel, File, Quarter, Aspect)
          
          # ---- MAPEH Combined per quarter (student-level) ----
          mapeh_student <- df %>%
            filter(Subject == "MAPEH", Aspect %in% c("MUSIC", "ARTS", "PE", "HEALTH")) %>%
            group_by(File, Subject, GradeLevel, Quarter, StudentIndex) %>%
            summarise(
              aspects_present = sum(!is.na(Score)),
              CombinedRaw     = ifelse(aspects_present == 4, sum(Score, na.rm = TRUE), NA_real_),
              .groups = "drop"
            ) %>%
            filter(!is.na(CombinedRaw))
          
          mapeh_hps <- df %>%
            filter(Subject == "MAPEH", Aspect %in% c("MUSIC", "ARTS", "PE", "HEALTH")) %>%
            group_by(File, Subject, GradeLevel, Quarter, Aspect) %>%
            summarise(AspectHPS = suppressWarnings(first(na.omit(HPS))), .groups = "drop") %>%
            group_by(File, Subject, GradeLevel, Quarter) %>%
            summarise(HPS = sum(AspectHPS, na.rm = TRUE), .groups = "drop")
          
          mapeh_combined <- mapeh_student %>%
            group_by(File, Subject, GradeLevel, Quarter) %>%
            summarise(
              Aspect               = "",
              N                    = n(),
              `MEAN (Raw Score)`   = round(mean(CombinedRaw, na.rm = TRUE), 2),
              `SD (Raw Score)`     = round(sd(CombinedRaw, na.rm = TRUE), 2),
              .groups = "drop"
            ) %>%
            left_join(mapeh_hps, by = c("File", "Subject", "GradeLevel", "Quarter")) %>%
            mutate(MPS = round((`MEAN (Raw Score)` / HPS) * 100, 2))
          
          summary_tbl <- bind_rows(base_summary, mapeh_combined) %>%
            arrange(Subject, GradeLevel, File, Quarter, Aspect)
          
          rv_data(df)
          rv_summary(summary_tbl)
          
          # --- NEW: Mastery Level table for ENGLISH, MATHEMATICS, SCIENCE only ---
          mastery_subjects <- c("ENGLISH", "MATHEMATICS", "SCIENCE")
          mastery_levels <- c(
            "Mastered",
            "Closely Approaching Mastery",
            "Moving Towards Mastery",
            "Average Mastery",
            "Low Mastery",
            "Very Low Mastery",
            "Absolutely No Mastery"
          )
          range_map <- c(
            "Mastered"                    = "96-100%",
            "Closely Approaching Mastery" = "86-95%",
            "Moving Towards Mastery"      = "66-85%",
            "Average Mastery"             = "35-65%",
            "Low Mastery"                 = "15-34%",
            "Very Low Mastery"            = "5-14%",
            "Absolutely No Mastery"       = "0-4%"
          )
          
          mastery_df <- df %>%
            dplyr::filter(Subject %in% mastery_subjects, !is.na(Percent)) %>%
            dplyr::mutate(
              Pct = pmin(Percent, 100),
              Description = dplyr::case_when(
                Pct >= 96 & Pct <= 100 ~ "Mastered",
                Pct >= 86 & Pct <= 95  ~ "Closely Approaching Mastery",
                Pct >= 66 & Pct <= 85  ~ "Moving Towards Mastery",
                Pct >= 35 & Pct <= 65  ~ "Average Mastery",
                Pct >= 15 & Pct <= 34  ~ "Low Mastery",
                Pct >= 5  & Pct <= 14  ~ "Very Low Mastery",
                Pct >= 0  & Pct <= 4   ~ "Absolutely No Mastery",
                TRUE ~ NA_character_
              )
            ) %>%
            dplyr::filter(!is.na(Description)) %>%
            dplyr::mutate(
              Description = factor(Description, levels = mastery_levels)
            ) %>%
            dplyr::group_by(Subject, Quarter, Description) %>%
            dplyr::summarise(`No.` = dplyr::n(), .groups = "drop") %>%
            tidyr::complete(
              Subject, Quarter, Description = factor(mastery_levels, levels = mastery_levels),
              fill = list(`No.` = 0)
            ) %>%
            dplyr::group_by(Subject, Quarter) %>%
            dplyr::mutate(
              Total = sum(`No.`),
              `%`   = ifelse(Total > 0, round(100 * `No.` / Total, 6), 0),
              Range = range_map[as.character(Description)]
            ) %>%
            dplyr::ungroup() %>%
            dplyr::select(Subject, Quarter, Description, Range, `No.`, `%`) %>%
            dplyr::arrange(Subject, Quarter, Description)  # exact order
          
          rv_mastery(mastery_df)
          
          # --- Optional: Update Quarter choices dynamically based on available data ---
          qs <- sort(unique(df$Quarter))
          updateSelectInput(session, "quarter_filter",
                            choices = c("All", qs),
                            selected = isolate(if (input$quarter_filter %in% c("All", qs)) input$quarter_filter else "All"))
        }
      })
      
      showNotification("MPS consolidation completed.", type = "message", duration = 5)
    })
    
    # Show/Hide results
    observe({
      df <- rv_data()
      if (!is.null(df) && nrow(df) > 0) {
        hide("intro_box"); show("results_box")
      } else {
        show("intro_box"); hide("results_box")
      }
    })
    
    # ----------- NEW: Filtered views that apply to ALL outputs -----------
    filtered_df <- reactive({
      df <- rv_data()
      req(df)
      q <- input$quarter_filter
      if (is.null(q) || q == "All") df else dplyr::filter(df, Quarter == q)
    })
    
    summary_view <- reactive({
      sm <- rv_summary()
      req(sm)
      q <- input$quarter_filter
      if (is.null(q) || q == "All") sm else dplyr::filter(sm, Quarter == q)
    })
    
    mastery_view <- reactive({
      md <- rv_mastery()
      req(md)
      q <- input$quarter_filter
      if (is.null(q) || q == "All") md else dplyr::filter(md, Quarter == q)
    })
    
    # ----------- Renderers using the filtered views -----------
    output$table <- renderDT({
      df <- filtered_df()
      if (is.null(df)) return(NULL)
      datatable(df, options = list(pageLength = 10, scrollX = TRUE), rownames = FALSE)
    })
    
    output$summary_table <- renderDT({
      sm <- summary_view()
      if (is.null(sm)) return(NULL)
      datatable(sm, options = list(pageLength = 10, scrollX = TRUE), rownames = FALSE)
    })
    
    output$mastery_table <- renderDT({
      md <- mastery_view()
      if (is.null(md)) return(NULL)
      datatable(md, options = list(pageLength = 10, scrollX = TRUE), rownames = FALSE)
    })
    
    # ----------- Excel download reflecting the filtered views -----------
    output$download_excel <- downloadHandler(
      filename = function() paste0("MPS_Consolidated_", Sys.Date(), ".xlsx"),
      content = function(file) {
        df <- filtered_df()
        sm <- summary_view()
        md <- mastery_view()
        
        wb <- createWorkbook()
        
        # Data sheet (filtered)
        addWorksheet(wb, "Data")
        writeData(wb, "Data", df)
        setColWidths(wb, "Data", cols = 1:ncol(df), widths = "auto")
        
        # Summary sheet (filtered)
        addWorksheet(wb, "Summary")
        writeData(wb, "Summary", sm)
        setColWidths(wb, "Summary", cols = 1:ncol(sm), widths = "auto")
        
        # Mastery Level sheet (filtered)
        addWorksheet(wb, "Mastery Level")
        writeData(wb, "Mastery Level", md)
        setColWidths(wb, "Mastery Level", cols = 1:ncol(md), widths = "auto")
        
        saveWorkbook(wb, file, overwrite = TRUE)
      }
    )
  })
}
