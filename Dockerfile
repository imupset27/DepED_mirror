FROM rocker/shiny:latest

USER root
WORKDIR /srv/shiny-server

# Install required R packages
RUN install2.r --error --skipinstalled \
    auth0 shiny shinyjs tidyverse readxl openxlsx yaml httr bs4Dash \
    shinyWidgets fontawesome DT purrr dplyr tidyr lubridate writexl \
    digest tibble qrcode zip grid htmltools

# Create writable directory for persistent data
RUN mkdir -p /srv/shiny-server/data \
    && chown shiny:shiny /srv/shiny-server/data \
    && chmod 755 /srv/shiny-server/data

# Copy your Shiny app into the container
COPY --chown=shiny:shiny . /srv/shiny-server/
COPY --chown=shiny:shiny _auth0.yml /srv/shiny-server/_auth0.yml

# Optional: log to stdout for easier debugging
ENV APPLICATION_LOGS_TO_STDOUT=true

EXPOSE 3838

# Drop privileges
USER shiny

