#!/bin/bash
set -e

REPO_NAME="${REPO_NAME:-default}"
REPO_COMPONENTS="${REPO_COMPONENTS:-main}"
REPO_DISTRIBUTION="${REPO_DISTRIBUTION:-noble}"
REPO_ARCH="${REPO_ARCH:-amd64}"
GPG_KEY_PATH="${GPG_KEY_PATH:-/secrets/private.pgp}"
CONFIG_PATH="/config/aptly.conf"

# -- Config Aptly
if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "⚠️ No aptly.conf found in /config, generating default..."
  mkdir -p /config
  cat > "$CONFIG_PATH" <<EOF
{
  "rootDir": "/var/lib/aptly",
  "downloadConcurrency": 10,
  "architectures": [],
  "gpgDisableSign": false,
  "gpgDisableVerify": false,
  "gpgProvider": "gpg",
  "FileSystemPublishEndpoints": {
    "debian": {
      "rootDir": "/var/lib/aptly/public",
      "linkMethod": "symlink",
      "verifyMethod": "md5"
    }
  }
}
EOF
fi

ln -sf "$CONFIG_PATH" /etc/aptly.conf
echo "🔧 Using aptly.conf from $CONFIG_PATH"

# -- GPG: Import or generate key
if [[ -f "$GPG_KEY_PATH" ]]; then
  echo "🔐 Importing GPG key from $GPG_KEY_PATH..."
  gpg --batch --import "$GPG_KEY_PATH" || true
else
  echo "⚠️ No GPG key provided — checking for existing key..."
  if ! gpg --list-secret-keys | grep -q sec; then
    echo "🔐 No existing GPG key — generating a new one..."
    cat > /tmp/gen-key <<EOF
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Name-Real: Aptly Auto
Name-Email: aptly@localhost
Expire-Date: 0
%no-protection
%commit
EOF
    gpg --batch --gen-key /tmp/gen-key
    rm -f /tmp/gen-key
    echo "💾 Exporting generated private key to $GPG_KEY_PATH"
    mkdir -p "$(dirname "$GPG_KEY_PATH")"
    gpg --batch --yes --armor --export-secret-keys "$GPG_KEY_ID" > "$GPG_KEY_PATH"
  fi
fi

GPG_KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ { print $10; exit }')
echo "$GPG_KEY_ID:6:" | gpg --import-ownertrust
echo "🔑 Using GPG key ID: $GPG_KEY_ID"

# -- Create /incoming/<component> dirs
IFS=',' read -ra COMPONENTS <<< "$REPO_COMPONENTS"
for COMPONENT in "${COMPONENTS[@]}"; do
  mkdir -p "/incoming/$COMPONENT"
done

# -- Create repo if needed
if ! aptly repo list -raw | grep -q "^$REPO_NAME$"; then
  FIRST_COMPONENT=$(echo "$REPO_COMPONENTS" | cut -d',' -f1)
  echo "📦 Creating repo $REPO_NAME with component $FIRST_COMPONENT"
  aptly repo create -distribution="$REPO_DISTRIBUTION" -component="$FIRST_COMPONENT" "$REPO_NAME"
fi

# -- Initial publish if not yet done
if ! aptly publish list | grep -q "$REPO_DISTRIBUTION"; then
  echo "🚀 Publishing $REPO_NAME for $REPO_DISTRIBUTION"
  aptly publish repo -architectures="$REPO_ARCH" -gpg-key="$GPG_KEY_ID" "$REPO_NAME"
fi

# -- Cron auto-update
if [[ -n "${CRON_UPDATE_COMPONENTS:-}" ]]; then
  echo "$CRON_UPDATE_COMPONENTS root /entrypoint.sh update" > /etc/cron.d/aptly-update
  chmod 0644 /etc/cron.d/aptly-update
  crontab /etc/cron.d/aptly-update
  cron
fi

# -- Mode update
if [[ "$1" == "update" ]]; then
  LOCKFILE="/tmp/aptly-update.lock"
  if [[ -f "$LOCKFILE" ]]; then
    echo "⛔️ Update already running. Exiting."
    exit 0
  fi
  touch "$LOCKFILE"
  trap 'rm -f "$LOCKFILE"' EXIT

  NOW=$(date +"%Y%m%d-%H%M%S")
  echo "🔄 Starting update..."

  for COMPONENT in "${COMPONENTS[@]}"; do
    INCOMING_DIR="/incoming/$COMPONENT"
    if ! find "$INCOMING_DIR" -type f -name '*.deb' | grep -q .; then
      echo "ℹ️ No .deb found in $INCOMING_DIR, skipping $COMPONENT"
      continue
    fi

    echo "📦 Processing component: $COMPONENT"

    find "$INCOMING_DIR" -name '*.deb' -type f | while read -r pkg; do
      echo "➕ Adding $pkg to repo"
      aptly repo add "$REPO_NAME" "$pkg"
      rm -f "$pkg"
    done

    SNAP_NAME="${COMPONENT}_${NOW}"
    echo "📸 Creating snapshot: $SNAP_NAME"
    aptly snapshot create "$SNAP_NAME" from repo "$REPO_NAME"

    if aptly publish list | grep -q "$REPO_DISTRIBUTION"; then
      echo "🔁 Switching publish for $COMPONENT"
      aptly publish switch -component="$COMPONENT" -gpg-key="$GPG_KEY_ID" "$REPO_DISTRIBUTION" "$SNAP_NAME"
    else
      echo "🚀 Publishing $COMPONENT"
      aptly publish snapshot -component="$COMPONENT" -distribution="$REPO_DISTRIBUTION" -architectures="$REPO_ARCH" -gpg-key="$GPG_KEY_ID" "$SNAP_NAME"
    fi
  done

  # -- packages.json
  PACKAGES_FILE="/var/lib/aptly/packages.json"
  echo "[" > "$PACKAGES_FILE.tmp"

  aptly repo show -with-packages "$REPO_NAME" | grep -v '^\[' | grep -v '^\]' | while read -r line; do
    PKG=$(echo "$line" | awk -F_ '{print $1}')
    VER=$(echo "$line" | awk -F_ '{print $2}')
    COMPONENT=$(echo "$line" | grep -oE "(${REPO_COMPONENTS//,/|})")
    echo "{\"name\":\"$PKG\",\"version\":\"$VER\",\"component\":\"$COMPONENT\"}," >> "$PACKAGES_FILE.tmp"
  done

  sed -i '$ s/,$//' "$PACKAGES_FILE.tmp"
  echo "]" >> "$PACKAGES_FILE.tmp"
  mv "$PACKAGES_FILE.tmp" "$PACKAGES_FILE"
  echo "✅ packages.json generated"

  # -- Webhook
  if [[ -n "$NOTIFY_WEBHOOK_URL" ]]; then
    echo "📤 Sending packages.json to $NOTIFY_WEBHOOK_URL..."
    curl -s -X POST -H "Content-Type: application/json" --data "@$PACKAGES_FILE" "$NOTIFY_WEBHOOK_URL"
    echo "✅ Webhook sent"
  fi

  # -- Email
  if [[ "$NOTIFY_SENDMAIL" == "true" ]]; then
    echo "📧 Sending mail to $MAIL_TO"
    echo "APT Repo '$REPO_NAME' updated on $(date)" > /tmp/email.txt
    SUBJECT="${MAIL_SUBJECT:-APT Repo Update}"

    cat > /tmp/msmtp.conf <<EOF
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
account        default
host           $SMTP_HOST
port           $SMTP_PORT
user           $SMTP_USER
password       $SMTP_PASS
from           $MAIL_FROM
EOF

    chmod 600 /tmp/msmtp.conf

    if [[ "$MAIL_ATTACHMENT" == "true" ]]; then
      (echo "Subject: $SUBJECT"
       echo "To: $MAIL_TO"
       echo "From: $MAIL_FROM"
       echo "MIME-Version: 1.0"
       echo "Content-Type: multipart/mixed; boundary=BOUNDARY"
       echo
       echo "--BOUNDARY"
       echo "Content-Type: text/plain; charset=utf-8"
       echo
       cat /tmp/email.txt
       echo "--BOUNDARY"
       echo "Content-Type: application/json"
       echo "Content-Disposition: attachment; filename=\"packages.json\""
       echo
       cat "$PACKAGES_FILE"
       echo "--BOUNDARY--"
      ) | msmtp --account=default --file=/tmp/msmtp.conf "$MAIL_TO"
    else
      cat /tmp/email.txt | msmtp --account=default --file=/tmp/msmtp.conf -s "$SUBJECT" "$MAIL_TO"
    fi
  fi

  echo "✅ Update complete."
  exit 0
fi

# -- NGINX dynamic config
NGINX_TEMPLATE="/config/nginx.conf.template"
NGINX_DEST="/etc/nginx/conf.d/default.conf"

if [[ -f "$NGINX_TEMPLATE" ]]; then
  COMPONENTS_REGEX=$(echo "$REPO_COMPONENTS" | sed 's/,/|/g')
  sed "s|__COMPONENTS_REGEX__|$COMPONENTS_REGEX|g" "$NGINX_TEMPLATE" > "$NGINX_DEST"

  if [[ -s "/config/htpasswd" ]]; then
    sed -i '/__AUTH_BLOCK__/r'<(echo -e "        auth_basic \"Restricted\";\n        auth_basic_user_file /config/htpasswd;") "$NGINX_DEST"
  fi
  sed -i '/__AUTH_BLOCK__/d' "$NGINX_DEST"
fi

# -- Export GPG key
mkdir -p /config/examples
gpg --batch --yes --output /var/lib/aptly/public.gpg --armor --export "$GPG_KEY_ID"
cp /var/lib/aptly/public.gpg "/config/examples/${REPO_NAME}-archive-keyring.gpg"

# -- Generate .sources
SOURCES_FILE="/config/examples/${REPO_NAME}.sources"
if [[ ! -f "$SOURCES_FILE" ]]; then
  cat > "$SOURCES_FILE" <<EOF
Types: deb
URIs: http://your-domain/linux/ubuntu
Suites: ${REPO_DISTRIBUTION}
Components: ${REPO_COMPONENTS//,/ }
Signed-By: /usr/share/keyrings/${REPO_NAME}-archive-keyring.gpg
EOF
fi

echo "✅ Ready. Starting NGINX..."
exec nginx -g "daemon off;"
