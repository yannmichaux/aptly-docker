FROM debian:bookworm-slim

LABEL maintainer="Yann Michaux <yann.michaux1@gmail.com>"
LABEL description="Custom Docker image for Aptly with GPG and NGINX support"

ENV DEBIAN_FRONTEND=noninteractive
ENV APTLY_ROOT=/var/lib/aptly

# Install dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    gnupg curl wget ca-certificates nginx rsync xz-utils jq cron mutt && \
    rm -rf /var/lib/apt/lists/*

# Add Aptly official repo & key
RUN mkdir -p /etc/apt/keyrings && \
    chmod 755 /etc/apt/keyrings && \
    wget -O /etc/apt/keyrings/aptly.asc https://www.aptly.info/pubkey.txt && \
    echo "deb [signed-by=/etc/apt/keyrings/aptly.asc] http://repo.aptly.info/release bookworm main" > /etc/apt/sources.list.d/aptly.list && \
    apt-get update && apt-get install -y aptly && \
    rm -rf /var/lib/apt/lists/*

# Setup dirs
RUN mkdir -p $APTLY_ROOT/public /etc/aptly

# Remove default NGINX config to avoid port conflict
RUN rm -f /etc/nginx/conf.d/default.conf /etc/nginx/sites-enabled/default

# Copy entrypoint + nginx fallback
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Copy config files
RUN mkdir -p /templates
COPY nginx.conf /templates/nginx.conf

# Add update wrapper script into PATH
RUN echo '#!/bin/bash\nexec /docker-entrypoint.sh update "$@"' > /usr/local/bin/update && chmod +x /usr/local/bin/update

# Add remove wrapper script into PATH
RUN echo '#!/bin/bash\nexec /docker-entrypoint.sh remove "$@"' > /usr/local/bin/remove && chmod +x /usr/local/bin/remove

# Add help wrapper script into PATH
RUN echo '#!/bin/bash\nexec /docker-entrypoint.sh help "$@"' > /usr/local/bin/help && chmod +x /usr/local/bin/help

# Volumes : data, GPG key, config
VOLUME ["/var/lib/aptly", "/secrets", "/config", "/incoming"]

EXPOSE 80

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["start"]
