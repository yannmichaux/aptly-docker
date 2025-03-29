FROM debian:bookworm

LABEL maintainer="Yann Michaux <yann.michaux1@gmail.com>"
LABEL description="Custom Docker image for Aptly with GPG and NGINX support"

ENV DEBIAN_FRONTEND=noninteractive
ENV APTLY_ROOT=/var/lib/aptly

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gnupg curl wget ca-certificates nginx rsync xz-utils jq cron && \
    rm -rf /var/lib/apt/lists/*

# Add Aptly official repo & key
RUN mkdir -p /etc/apt/keyrings && chmod 755 /etc/apt/keyrings && \
    wget -O /etc/apt/keyrings/aptly.asc https://www.aptly.info/pubkey.txt && \
    echo "deb [signed-by=/etc/apt/keyrings/aptly.asc] http://repo.aptly.info/release bookworm main" > /etc/apt/sources.list.d/aptly.list && \
    apt-get update && apt-get install -y aptly && \
    rm -rf /var/lib/apt/lists/*

# Setup dirs
RUN mkdir -p $APTLY_ROOT/public /etc/aptly

# Remove default NGINX config to avoid port conflict
RUN rm -f /etc/nginx/conf.d/default.conf /etc/nginx/sites-enabled/default

# Copy entrypoint + nginx fallback
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY nginx.conf.template /config/nginx.conf.template

# Volumes : données, clé GPG, config
VOLUME ["/var/lib/aptly", "/secrets", "/config", "/incoming"]

EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
