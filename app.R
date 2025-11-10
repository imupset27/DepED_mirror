# --- Options you may keep in app.R (recommended) ---
# options(shiny.host = "192.168.254.105", shiny.port = 8080)
options(shiny.maxRequestSize = 30*1024^2)     # ~30MB uploads
options(shiny.fullstacktrace = TRUE)          # helpful while debugging

# app.R
library(auth0)
library(shiny)
library(bs4Dash)
library(shinyWidgets)
library(fontawesome)
library(shinyjs)

options(auth0_config_file = Sys.getenv("AUTH0_CONFIG", "/srv/shiny-server/_auth0.yml"))

# ---- MODULES ----
source("modules/mod_deped.R")
source("modules/mod_deped_sf1.R")
source("modules/mod_deped_sf2.R")
source("modules/mod_deped_sf9.R")
source("modules/mod_deped_mps.R")

# -------------------- UI --------------------
ui <- bs4DashPage(
  title = "EMLStat",
  
  header = dashboardHeader(
    title = tags$div(
      tags$img(src = "emlstat_logo.png", height = "35px", style = "margin-right:10px;"),
      "EMLStat Analytics"
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
            tags$h1("Empowering Decisions Through Data"),
            tags$h4("Your trusted partner in statistical consulting, analytics, and research solutions.")
          ),
          
          br(),
          tags$h2(class = "text-center mb-4 text-primary", "Our Services"),
          
          fluidRow(
            column(6,
                   tags$div(
                     class = "service-card",
                     style = "padding: 20px;",
                     onclick = "Shiny.setInputValue('open_deped', true, {priority: 'event'})",
                     bs4Card(
                       title = tagList(icon("school", class = "service-icon"), " DepEd Reports & Analytics"),
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
            "EMLStat Analytics & Consulting is a statistical solutions company that helps organizations transform raw data into actionable insights.
             We specialize in education analytics, research dashboards, and statistical consulting to empower data-driven decision making."
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
        tabName = "consult",
        fluidPage(
          tags$h2("Consulting & Training"),
          tags$p("Partner with EMLStat Analytics & Consulting to unlock the full potential of your data."),
          
          tags$h3("What We Offer"),
          tags$ul(
            tags$li("Customized analytics consulting for institutions and businesses"),
            tags$li("Hands-on training workshops on data visualization and predictive modeling"),
            tags$li("Strategic guidance for data-driven decision-making")
          ),
          
          tags$h3("Why Work With Us"),
          tags$p("We combine technical expertise with a human-centered approach, ensuring your team gains practical skills and actionable insights."),
          
          tags$h3("Get in Touch"),
          tags$p("For project collaborations, workshops, or tailored solutions, email us at "),
          tags$a(href = "mailto:info@emlstat.uk", "info@emlstat.uk")
        )
      )
      ,
      tabItem(
        tabName = "about",
        fluidPage(
          tags$h2("About EMLStat"),
          tags$p("EMLStat Analytics & Consulting helps institutions make better decisions using data."),
          tags$hr(),
          
          # Tagline
          tags$h3("Tagline"),
          tags$p("Turning Data Into Decisions That Matter."),
          
          # Humanized description
          tags$h3("Who We Are"),
          tags$p("At EMLStat Analytics & Consulting, we believe data should work for people—not the other way around. We turn complex information into clear, actionable insights that help teams move with confidence."),
          
          # Mission
          tags$h3("Mission"),
          tags$p("Our mission is to help organizations unlock the true potential of their data by delivering insights and strategic guidance that drive growth, efficiency, and innovation—always with a human touch."),
          
          # Vision
          tags$h3("Vision"),
          tags$p("Our vision is a world where data empowers every decision, making institutions smarter, more agile, and more connected to the people they serve."),
          
          # Optional: Core services (feel free to edit or remove)
          tags$h3("Core Services"),
          tags$ul(
            tags$li("Business intelligence dashboards & data visualization"),
            tags$li("Predictive modeling & performance analytics"),
            tags$li("Data strategy, governance, and quality"),
            tags$li("Process optimization & decision support")
          )
        )
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
  
  mod_deped_server("deped")
}

#shinyApp(ui, server)
auth0::shinyAppAuth0(ui, server)
