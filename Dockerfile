FROM rocker/shiny:latest

# Install any additional R packages your app needs
RUN R -e "install.packages(c('shiny', 'ggplot2'))"

# Copy your Shiny app
COPY ./app /srv/shiny-server/

# Copy custom config to change port
COPY shiny-server.conf /etc/shiny-server/shiny-server.conf

# Expose the new internal port
EXPOSE 3839

CMD ["/usr/bin/shiny-server"]
