FROM rocker/shiny:latest

WORKDIR /srv/shiny-server

# Install required R packages
RUN install2.r --error --skipinstalled \
    auth0 \
    shiny \
    shinyjs \
    tidyverse \
    readxl \
    openxlsx \
    yaml \
    httr \
    bs4Dash \
    shinyWidgets \
    fontawesome \
    DT \
    purrr


# Copy your Shiny app into the container
COPY . /srv/shiny-server/

# Make sure auth0.yml is in the same directory as app.R
COPY _auth0.yml /srv/shiny-server/_auth0.yml

# Optional: log to stdout for easier debugging in Portainer
ENV APPLICATION_LOGS_TO_STDOUT=true

# Expose the default Shiny port
EXPOSE 3838
