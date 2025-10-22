# modules/mod_deped_sf1.R
library(shiny)
library(shinyjs)
library(readxl)
library(DT)
library(openxlsx)
library(stringr)

# -------------------- UI --------------------
mod_deped_sf1_ui <- function(id) {
  ns <- NS(id)
  fluidPage(
    useShinyjs(),
    titlePanel("Master list of Learners"),
    sidebarLayout(
      sidebarPanel(width = 3,
                   # ❓ Help link to open the instructions modal
                   actionLink(ns("show_help"), label = "❓ What file should I upload?"),
                   tags$br(), tags$br(),
                   
                   # Hint about auto-processing and progress bar
                   tags$small("Processing will start automatically after upload. A progress bar will appear."),
                   tags$br(), tags$br(),
                   fileInput(ns("file"), "Upload Excel File (DepEd LIS SF1)", accept = c(".xlsx", ".xls")),
                   downloadButton(ns("download_excel"), "Download Excel")
      ),
      mainPanel(width = 9,
                # -------- Intro panel (shown before upload/processing) --------
                div(
                  id = ns("intro_box"),
                  style = "background-color:#f8f9fa; padding:20px; border-radius:10px; box-shadow:0 2px 6px rgba(0,0,0,0.05);",
                  tags$h4("4d8 SF1 Extractor"),
                  tags$p(class = "lead", "Upload your School Form 1 (SF1) from the DepEd LIS and the app will extract the header details and clean the learners list automatically."),
                  tags$h5("What you need"),
                  tags$ul(
                    tags$li("The original SF1 Excel file (.xlsx or .xls) downloaded from the LIS"),
                    tags$li("Keep the top rows intact; the app reads header cells like F3 (School ID), F4 (School Name), T4 (School Year), AE4 (Grade Level), T3 (Division), AM3 (District), AM4 (Section), K3 (Region)"),
                    tags$li("Learners table should contain columns for LRN, Name, Gender, Birthday, Age, and Parents' names")
                  ),
                  tags$p("Once you upload, processing starts and you'll see a progress bar. After completion, the results will appear here."),
                  tags$em("Data privacy: Files are processed locally in this app. Handle learner data securely.")
                ),
                
                # -------- Results panel (hidden until data is ready) --------
                div(
                  id = ns("results_box"),
                  style = "display:none;",
                  h4("Classification Details"),
                  DTOutput(ns("header_table")),
                  tags$hr(),
                  h4("Learner's Details"),
                  DTOutput(ns("table"))
                )
      )
    )
  )
}

# -------------------- SERVER --------------------
mod_deped_sf1_server <- function(id) {
  moduleServer(id, function(input, output, session) {
    
    # ---------- MODAL: Upload instructions + sample screenshot ----------
    show_sf1_help <- function() {
      showModal(modalDialog(
        title = "Upload Instructions: DepEd LIS School Form 1 (SF1)",
        size  = "l",
        easyClose = TRUE,
        footer = tagList(modalButton("Close")),
        tagList(
          # Intro
          tags$p("Please upload the School Form 1 (SF1) file downloaded from the DepEd Learner Information System (LIS)."),
          
          # What to upload
          tags$h4("✅ What file to upload"),
          tags$ul(
            tags$li("File type: Excel (.xlsx or .xls)."),
            tags$li("Use the original SF1 template from LIS (do not convert to CSV or PDF)."),
            tags$li("Do not rename, delete, or reorder columns.")
          ),
          
          # Where to get it
          tags$h4("📄 Where to get the SF1"),
          tags$p("Log in to the DepEd LIS, navigate to your class/section, and download SF1 for the current School Year and Grade Level."),
          
          # Required contents
          tags$h4("🧩 What the file must contain"),
          tags$ul(
            tags$li("Header fields at the top (School ID, School Name, School Year, Grade Level, Division, District, Section, Region).")
      
          ),
          
          # Important reminders
          tags$h4("⚠️ Important reminders"),
          tags$ul(
            tags$li("Keep the top rows intact so the app can detect headers correctly (the app skips the first three rows)."),
            tags$li("Do not upload PDF, images, or CSV exports.")
          ),
          
          # Privacy
          tags$h4("🔒 Data privacy"),
          tags$p("Your uploaded file is processed locally by this app and used only to generate the cleaned learners list. Handle learner data securely and follow your school's data privacy policies."),
          
          tags$hr(),
          
          # Sample screenshot (place in www/)
          tags$h4("🖼️ Sample SF1 (screenshot)"),
          tags$p("This is what a typical SF1 looks like after download from LIS."),
          tags$img(
            src = "sf1_sample.jpg",  # Put the image in www/sf1_sample.png
            alt = "Sample screenshot of DepEd LIS SF1",
            style = "max-width: 100%; border: 1px solid #ddd; border-radius: 6px; box-shadow: 0 1px 4px rgba(0,0,0,0.1);"
          )
          
        )
      ))
    }
    
    # Auto-open the modal on first load (once)
    observeEvent(TRUE, {
      show_sf1_help()
    }, once = TRUE, ignoreInit = FALSE)
    
    # Open the modal when the help link is clicked
    observeEvent(input$show_help, {
      show_sf1_help()
    })
    
    # Reactive values to store processed outputs
    rv_header <- reactiveVal(NULL)
    rv_data   <- reactiveVal(NULL)
    
    # Helper: read a single cell (A1 address) using readxl
    get_cell <- function(path, sheet = 1, address) {
      val <- readxl::read_excel(path, sheet = sheet, range = address, col_names = FALSE)
      out <- if (nrow(val) > 0 && ncol(val) > 0) val[[1]][1] else NA
      if (!is.na(out)) out <- stringr::str_trim(as.character(out))
      out
    }
    
    # Automatically process after upload, with a progress bar
    observeEvent(input$file, {
      req(input$file)
      
      withProgress(message = "Processing uploaded SF1 file...", value = 0, {
        # --- Step 1: Read header cells ---
        incProgress(0.10, detail = "Reading header fields...")
        cells <- c(
          "School ID"   = "F3",
          "School Name" = "F4",
          "School Year" = "T4",
          "Grade Level" = "AE4",
          "Division"    = "T3",
          "District"    = "AM3",
          "Section"     = "AM4",
          "Region"      = "K3"
        )
        values <- vector("character", length(cells))
        for (i in seq_along(cells)) {
          values[i] <- get_cell(input$file$datapath, sheet = 1, address = cells[i])
          incProgress(0.05, detail = sprintf("Header: %s", names(cells)[i]))
        }
        header_df <- data.frame(Field = names(cells), Value = values, stringsAsFactors = FALSE)
        rv_header(header_df)
        
        # --- Step 2: Read learners table ---
        incProgress(0.20, detail = "Reading learners table...")
        df <- readxl::read_excel(input$file$datapath, skip = 3)
        
        # Columns: 1=LRN, 3=Name, 7=Gender, 8=Birthday, 10=Age, 28=Father's Name, 32=Mother's Name
        df_subset <- df[, c(1, 3, 7, 8, 10, 28, 32)]
        names(df_subset) <- c("LRN", "Name", "Gender", "Birthday", "Age", "Father's Name", "Mother's Name")
        
        # --- Step 3: Clean learners ---
        incProgress(0.25, detail = "Cleaning learners data...")
        df_clean <- df_subset[!(is.na(df_subset$LRN) & is.na(df_subset$Name)), ]
        
        # Trim only character columns
        idx_char <- sapply(df_clean, is.character)
        df_clean[idx_char] <- lapply(df_clean[idx_char], function(x) stringr::str_trim(x))
        
        # Standardize Gender (M/F only)
        df_clean$Gender <- toupper(df_clean$Gender)
        df_clean$Gender <- ifelse(df_clean$Gender %in% c("M", "MALE"), "M",
                                  ifelse(df_clean$Gender %in% c("F", "FEMALE"), "F", NA))
        
        # Keep valid LRNs = exactly 12 digits
        df_clean$LRN <- ifelse(grepl("^\\d{12}$", df_clean$LRN), df_clean$LRN, NA)
        
        # Remove unwanted rows in Name
        remove_patterns <- c("TOTAL MALE", "TOTAL FEMALE", "COMBINED", "NAME")
        df_clean <- df_clean[!grepl(paste(remove_patterns, collapse = "|"), toupper(df_clean$Name)), ]
        
        # Remove empty rows strictly
        df_clean <- df_clean[!( (is.na(df_clean$LRN) | df_clean$LRN == "") & (is.na(df_clean$Name) | df_clean$Name == "") ), ]
        
        # Add FormattedName (LAST, FIRST M.)
        incProgress(0.15, detail = "Formatting names...")
        df_clean$FormattedName <- toupper(df_clean$Name)
        df_clean$FormattedName <- sapply(df_clean$FormattedName, function(fullname) {
          parts <- stringr::str_split(fullname, ",")[[1]]
          if (length(parts) == 3) {
            last   <- stringr::str_trim(parts[1])   # LASTNAME
            first  <- stringr::str_trim(parts[2])   # FIRSTNAME
            middle <- stringr::str_trim(parts[3])   # MIDDLENAME
            if (middle == "-" | middle == "") {
              paste0(last, ", ", first)
            } else {
              middle_parts <- stringr::str_split(middle, "\\s+")[[1]]
              initials <- paste0(substr(middle_parts, 1, 1), collapse = "")
              paste0(last, ", ", first, " ", initials, ".")
            }
          } else {
            fullname
          }
        })
        
        # Place FormattedName as the 4th column
        desired_order <- c("LRN", "Name", "Gender", "FormattedName",
                           "Birthday", "Age", "Father's Name", "Mother's Name")
        df_clean <- df_clean[, desired_order]
        
        rv_data(df_clean)
        
        # Final step
        incProgress(0.10, detail = "Finalizing...")
      })
      
      # Completion notification
      showNotification("SF1 extraction completed.", type = "message", duration = 5)
    })
    
    # Toggle intro/results visibility based on data readiness
    observe({
      df <- rv_data()
      if (!is.null(df) && nrow(df) > 0) {
        shinyjs::hide("intro_box")
        shinyjs::show("results_box")
      } else {
        shinyjs::show("intro_box")
        shinyjs::hide("results_box")
      }
    })
    
    # --- Render header and table
    output$header_table <- renderDT({
      hdr <- rv_header()
      if (is.null(hdr)) return(NULL)
      datatable(hdr, options = list(dom = 't', paging = FALSE), rownames = FALSE)
    })
    
    output$table <- renderDT({
      df <- rv_data()
      if (is.null(df)) return(NULL)
      datatable(df, options = list(pageLength = 10))
    })
    
    # --- Download as Excel with formatting
    output$download_excel <- downloadHandler(
      filename = function() {
        paste0("Learners_Data_", Sys.Date(), ".xlsx")
      },
      content = function(file) {
        df <- rv_data()
        header_df <- rv_header()
        
        if (is.null(df)) {
          wb <- openxlsx::createWorkbook()
          openxlsx::addWorksheet(wb, "Data")
          openxlsx::saveWorkbook(wb, file, overwrite = TRUE)
          return()
        }
        
        # Ensure LRN is text
        df$LRN <- as.character(df$LRN)
        
        wb <- openxlsx::createWorkbook()
        
        # Add "Data" sheet
        openxlsx::addWorksheet(wb, "Data")
        openxlsx::writeData(wb, "Data", df)
        
        # Apply formats
        text_style <- openxlsx::createStyle(numFmt = "@")               # for LRN
        date_style <- openxlsx::createStyle(numFmt = "mm/dd/yyyy")      # for Birthday
        
        # Apply LRN as text (col 1)
        openxlsx::addStyle(wb, "Data", text_style, cols = 1,
                           rows = 2:(nrow(df) + 1), gridExpand = TRUE)
        
        # Apply date format for Birthday (col 5)
        openxlsx::addStyle(wb, "Data", date_style, cols = 5,
                           rows = 2:(nrow(df) + 1), gridExpand = TRUE)
        
        # Auto-adjust all column widths
        openxlsx::setColWidths(wb, "Data", cols = 1:ncol(df), widths = "auto")
        
        # Add "Header" sheet (visible; change to hidden if preferred)
        if (!is.null(header_df)) {
          openxlsx::addWorksheet(wb, "Header")
          openxlsx::writeData(wb, "Header", header_df)
          openxlsx::setColWidths(wb, "Header", cols = 1:2, widths = c(20, 40))
          # To hide the sheet, uncomment the next two lines:
          # openxlsx::setSheetVisibility(wb, sheet = "Header", visibility = "hidden")
          # openxlsx::setActiveSheet(wb, sheet = "Data")
        }
        
        openxlsx::saveWorkbook(wb, file, overwrite = TRUE)
      }
    )
  })
}
