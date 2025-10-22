# modules/mod_deped.R
mod_deped_ui <- function(id) {
  ns <- NS(id)
  
  tagList(
    useShinyjs(),
    tags$style(HTML("
      .intro-section {
        background: #f8f9fa;
        border-radius: 12px;
        padding: 30px;
        box-shadow: 0 4px 15px rgba(0,0,0,0.05);
        transition: opacity 0.5s ease;
      }
      .intro-section.hidden { opacity: 0; display: none; }
      .feature-card {
        background: white;
        border-radius: 10px;
        box-shadow: 0 3px 8px rgba(0,0,0,0.05);
        padding: 20px;
        text-align: center;
        cursor: pointer;
        transition: transform 0.2s, box-shadow 0.2s;
      }
      .feature-card:hover {
        transform: translateY(-5px);
        box-shadow: 0 6px 15px rgba(0,0,0,0.15);
      }
      .feature-icon {
        font-size: 40px;
        color: #0d6efd;
        margin-bottom: 10px;
      }
      .back-btn {
        background-color: #6c757d !important;
        color: white !important;
        border: none;
        border-radius: 6px;
        padding: 8px 16px;
      }
      .back-btn:hover { background-color: #5a6268 !important; }
    ")),
    
    div(
      id = ns("intro_section"),
      class = "intro-section",
      tags$h2(class = "text-primary mb-3", "DepEd Reports & Analytics Suite"),
      tags$p(class = "lead", 
             "Welcome to the EMLStat DepEd Analytics Suite — a collection of applications designed to simplify data management, automate grade consolidation, and support data-driven decision-making for schools."),
      tags$div(
        class = "howto-box mt-3",
        tags$h5(icon("lightbulb", class = "text-primary"), " How to Use:"),
        tags$ol(
          tags$li("Click one of the app cards below to launch the application."),
          tags$li("Follow the on-screen guide for each app."),
          tags$li("Return to this overview anytime by clicking 'Return to Overview'.")
        )
      ),
      br(),
      fluidRow(
        column(4,
               div(id = ns("card_grades"), class = "feature-card",
                   `onclick` = sprintf("Shiny.setInputValue('%s', true, {priority: 'event'})", ns("card_grades")),
                   icon("school", class = "feature-icon"),
                   tags$h5("Grades Consolidator"),
                   tags$p("Combine all grades from different subjects using electronic class record (ECR)"))
        ),
        column(4,
               div(id = ns("card_lrn"), class = "feature-card",
                   `onclick` = sprintf("Shiny.setInputValue('%s', true, {priority: 'event'})", ns("card_lrn")),
                   icon("chart-bar", class = "feature-icon"),
                   tags$h5("LRN Extractor"),
                   tags$p("Extract and manage Learner Reference Numbers from DepEd SF1 in seconds."))
        ),
        column(4,
               div(id = ns("card_mps"), class = "feature-card",
                   `onclick` = sprintf("Shiny.setInputValue('%s', true, {priority: 'event'})", ns("card_mps")),
                   icon("calculator", class = "feature-icon"),
                   tags$h5("Mean Percentage Score (Quarterly Assessment)"),
                   tags$p("Streamline and simplify the generation and calculations for your test results."))
        )
      ),
      br(),
      
      fluidRow(
        column(4,
               div(id = ns("card_sf2"), class = "feature-card",
                   `onclick` = sprintf("Shiny.setInputValue('%s', true, {priority: 'event'})", ns("card_sf2")),
                   icon("school", class = "feature-icon"),
                   tags$h5("SF2: Attendance App"),
                   tags$p("Attendance System with use of QR codes and automatic downloadable realtime reports."))
        )
      )
      
      
    ),
    
    br(),
    uiOutput(ns("app_container"))
  )
}

mod_deped_server <- function(id) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    rv <- reactiveVal(NULL)
    
    observeEvent(input$card_grades, { rv("grades") })
    observeEvent(input$card_lrn, { rv("lrn") })
    observeEvent(input$card_mps, { rv("mps") })
    observeEvent(input$card_sf2, { rv("sf2") })
    
    observe({
      if (is.null(rv())) {
        shinyjs::show(id = "intro_section")
      } else {
        shinyjs::hide(id = "intro_section")
      }
    })
    
    output$app_container <- renderUI({
      req(rv())
      tagList(
        switch(rv(),
               "lrn" = mod_deped_sf1_ui(ns("lrn")),
               "sf2" = mod_deped_sf2_ui(ns("sf2")),
               "grades" = mod_deped_sf9_ui(ns("grades")),
               "mps" = mod_deped_mps_ui(ns("mps"))
        ),
        hr(),
        div(
          style = "margin-bottom: 15px;",
          actionButton(ns("back_to_intro"), "⬅ Return to Overview", class = "back-btn")
        )
      )
    })
    
    observeEvent(input$back_to_intro, {
      rv(NULL)
    })
    
    
    observeEvent(rv(), {
      if (rv() == "grades") mod_deped_sf9_server("grades")
      else if (rv() == "lrn") mod_deped_sf1_server("lrn")
      else if (rv() == "mps") mod_deped_mps_server("mps")
      else if (rv() == "sf2") mod_deped_sf2_server("sf2")
    }, ignoreInit = TRUE)
    
  })
}
