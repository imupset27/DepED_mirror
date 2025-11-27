# --- Options you may keep in app.R (recommended) ---
#options(shiny.host = "192.168.137.1", shiny.port = 8080)
options(shiny.maxRequestSize = 30*1024^2)     # ~30MB uploads
options(shiny.fullstacktrace = TRUE)          # helpful while debugging

# app.R
library(shiny)
library(bs4Dash)
library(shinyWidgets)
library(fontawesome)
library(shinyjs)
library(bslib)

# ---- MODULES ----
source("modules/mod_deped.R")
source("modules/mod_deped_sf1.R")
source("modules/mod_deped_sf2.R")
source("modules/mod_deped_sf9.R")
source("modules/mod_deped_mps.R")

# -------------------- UI --------------------
ui <- bs4DashPage(
  title = "EMLStat",
  freshTheme = bs_theme(
    version = 4,          # Bootstrap 4 for AdminLTE 3
    primary = "#0d6efd",  # your brand blue
    warning = "#ffc107",
    danger  = "#dc3545",
    success = "#28a745"
  ),
  
  
  
  header = dashboardHeader(
      disable = TRUE,    
      title = tags$div(
      tags$img(src = "emlstat_logo.png", height = "80px", style = "margin-right:10px;"),
      ""
    )
  ),
  
  sidebar = dashboardSidebar(
    sidebarMenu(
      id = "main_tabs",
      menuItem("Home", tabName = "home", icon = icon("home")),
      menuItem("DepEd Reports", tabName = "deped", icon = icon("school")),
      menuItem("Statistical Tools", tabName = "stat", icon = icon("chart-line")),
      menuItem("Research Dashboard", tabName = "research", icon = icon("flask")),
      menuItem("Consulting & Training", tabName = "consult", icon = icon("chalkboard-teacher")),
      menuItem("About", tabName = "about", icon = icon("info-circle"))
    )
  ),
  
  body = dashboardBody(
    useShinyjs(),
    
    tags$head(
      tags$script(HTML("
        $(function() {
          $('body').addClass('sidebar-collapse');
        });
      "))
    ),
    
    tags$head(
      tags$style(HTML("
        body, .content-wrapper { background-color: #f8f9fa !important; }
        h1, h2, h3 { font-family: 'Segoe UI', sans-serif; }
        .hero-section {
          background: linear-gradient(120deg, #0d6efd, #0b5ed7);
          color: white;
          padding: 60px 30px;
          text-align: center;
          border-radius: 10px;
          box-shadow: 0 4px 15px rgba(0,0,0,0.1);
        }
        .service-card {
          transition: transform 0.2s, box-shadow 0.2s;
          border-radius: 12px;
          cursor: pointer;
        }
        .service-card:hover {
          transform: translateY(-5px);
          box-shadow: 0 6px 20px rgba(0,0,0,0.15);
        }
        .service-icon {
          font-size: 40px;
          color: #0d6efd;
        }
        .footer {
          text-align: center;
          color: #6c757d;
          margin-top: 50px;
          padding: 20px;
          border-top: 1px solid #dee2e6;
        }
      "))
    ),
    
    tabItems(
      tabItem(
        tabName = "home",
        fluidPage(
          tags$div(
            class = "hero-section",
            tags$h1("Simplifying School Data for Smarter Decisions"),
            tags$h4("Your all-in-one solution for DepEd reports, analytics, and grade management.")
          ),
          
          br(),
          #tags$h2(class = "text-center mb-4 text-primary", "Our Services"),
          
          fluidRow(
            column(6,
                   tags$div(
                     class = "service-card",
                     style = "padding: 20px;",
                     onclick = "Shiny.setInputValue('open_deped', true, {priority: 'event'})",
                     bs4Card(
                       title = tagList(icon("school", class = "service-icon"), " DepEd Automation Hub"),
                       status = "primary", width = 12,
                       "We build and automate data-driven reports aligned with the Department of Education’s standards to support evidence-based decision making in schools.",
                       br(), tags$div("Explore Service", class = "btn btn-primary mt-2")
                     )
                   )
            ),
            column(6,
                   tags$div(
                     class = "service-card",
                     style = "padding: 20px;",
                     onclick = "Shiny.setInputValue('open_stat', true, {priority: 'event'})",
                     bs4Card(
                       title = tagList(icon("chart-line", class = "service-icon"), " Statistical Tools & Modeling"),
                       status = "info", width = 12,
                       "We provide advanced statistical models, forecasting tools, and automated data analytics applications for research and institutional analysis.",
                       br(), tags$div("Explore Service", class = "btn btn-info mt-2")
                     )
                   )
            )
          ),
          
          fluidRow(
            column(6,
                   tags$div(
                     class = "service-card",
                     style = "padding: 20px;",
                     onclick = "Shiny.setInputValue('open_research', true, {priority: 'event'})",
                     bs4Card(
                       title = tagList(icon("flask", class = "service-icon"), " Research Data Dashboards"),
                       status = "success", width = 12,
                       "Interactive dashboards for exploring research datasets, visualizing trends, and presenting insights to stakeholders effectively.",
                       br(), tags$div("Explore Service", class = "btn btn-success mt-2")
                     )
                   )
            ),
            column(6,
                   tags$div(
                     class = "service-card",
                     style = "padding: 20px;",
                     onclick = "Shiny.setInputValue('open_consult', true, {priority: 'event'})",
                     bs4Card(
                       title = tagList(icon("chalkboard-teacher", class = "service-icon"), " Consulting & Training"),
                       status = "warning", width = 12,
                       "Customized workshops and consulting for schools, universities, and organizations to enhance data literacy and research capacity.",
                       br(), tags$div("Contact Us", class = "btn btn-warning mt-2")
                     )
                   )
            )
          ),
          
          br(),
          tags$h2(class = "text-center text-primary mt-5 mb-3", "Who We Are"),
          tags$p(
            class = "lead text-center mx-auto", style = "max-width:800px;",
            "EMLStat is dedicated to empowering schools and educators with smart, data-driven solutions. We specialize in DepEd-compliant reporting tools, grade consolidation systems, and education analytics dashboards that simplify data management and improve decision-making. Our mission is to help teachers and administrators turn raw school data into actionable insights—making compliance easier and learning outcomes better."
          ),
          
          tags$div(
            class = "footer",
            # Brand
            tags$span("© 2025 "),
            tags$b("EMLStat Analytics & Consulting"),
            
            # Spacing separator
            HTML(" | "),
            
            # Email link
            tags$a(
              href = "mailto:info@emlstat.uk",
              aria_label = "Email EMLStat",
              style = "text-decoration:none;color:inherit",
              icon("envelope"), " info@emlstat.uk"
            ),
            
            HTML(" | "),
            
            # Phone link
            tags$a(
              href = "tel:+639286563785",
              aria_label = "Call EMLStat",
              style = "text-decoration:none;color:inherit",
              icon("phone"), " +63 928 656 3785"
            ),
            
            HTML(" | "),
            
            # WhatsApp link (with optional pre-filled message)
            tags$a(
              href = "https://wa.me/639286563785?text=Hi%20EMLStat%2C%20I%27d%20like%20to%20inquire%20about%20consulting%20and%20training.",
              target = "_blank", rel = "noopener",
              aria_label = "Chat on WhatsApp",
              style = "text-decoration:none;color:#25D366",
              icon("whatsapp"), " WhatsApp"
            )
          )
        )
      ),
      
      tabItem(tabName = "deped", mod_deped_ui("deped")),
      tabItem(tabName = "stat", fluidPage(tags$h3("Statistical Tools (Under Construction)"))),
      tabItem(tabName = "research", fluidPage(tags$h3("Research Dashboard (Under Construction)"))),
      tabItem(
        tabName = "consult",fluidPage(
          tags$h3("Consulting & Training (Under Construction)")
        )
      )
      ,
      tabItem(
        tabName = "about",
        fluidPage(tags$h3("About (Under Construction)")),
        tags$p("For project collaborations, workshops, or tailored solutions, email us at"),
        tags$a(href = "mailto:info@emlstat.uk", "info@emlstat.uk")
      )
      
    )
  )
)

# -------------------- SERVER --------------------
server <- function(input, output, session) {
  observeEvent(input$open_deped, updateTabItems(session, "main_tabs", "deped"))
  observeEvent(input$open_stat, updateTabItems(session, "main_tabs", "stat"))
  observeEvent(input$open_research, updateTabItems(session, "main_tabs", "research"))
  observeEvent(input$open_consult, updateTabItems(session, "main_tabs", "consult"))
  
  query <- reactive(parseQueryString(session$clientData$url_search))
  
  mod_deped_server("deped")
  
  rv <- reactiveVal(NULL)
  
  observe({
    query <- parseQueryString(session$clientData$url_search)
    if (!is.null(query$lrn) && nzchar(query$lrn)) {
      updateTabItems(session, "main_tabs", "deped")
      rv("sf2")  # Now this works
    }
  })
  
  observeEvent(rv(), {
    if (rv() == "sf2") mod_deped_sf2_server("sf2", reactive(parseQueryString(session$clientData$url_search)))
  })
  
  
  
}

shinyApp(ui, server)
