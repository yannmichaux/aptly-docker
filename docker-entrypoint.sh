#!/bin/bash
set -e

# Define default values for environment variables
REPO_ARCH="${REPO_ARCH:-amd64}"
REPO_NAME="${REPO_NAME:-default}"
REPO_COMPONENTS="${REPO_COMPONENTS:-main}"
REPO_DISTRIBUTION="${REPO_DISTRIBUTION:-noble}"
GPG_KEY_PATH="${GPG_KEY_PATH:-/secrets/private.asc}"
REPO_MAX_SNAPSHOTS="${REPO_MAX_SNAPSHOTS:-15}"

CONFIG_PATH="/config/aptly.conf"
LOCKFILE="/tmp/aptly-update.lock"

# Split components list by comma
IFS=',' read -ra COMPONENTS <<< "$REPO_COMPONENTS"

# Function to add packages to the corresponding component repository
add_packages_to_repo() {
  local COMPONENT="$1"
  local REPO_ID="${REPO_NAME}-${COMPONENT}"
  local INCOMING_DIR="/incoming/$COMPONENT"

  if ! find "$INCOMING_DIR" -type f -name '*.deb' | grep -q .; then
    echo "ℹ️ No .deb found in $INCOMING_DIR, skipping $COMPONENT"
    return 1
  fi

  echo "📦 Processing component: $COMPONENT"
  find "$INCOMING_DIR" -name '*.deb' -type f | while read -r pkg; do
    echo "➕ Adding $pkg to repo"
    aptly repo add -remove-files "$REPO_ID" "$pkg"
  done
}

# Function to create snapshot and publish or switch if already exists
create_and_publish_snapshot() {
  local COMPONENT="$1"
  local NOW="$2"
  local REPO_ID="${REPO_NAME}-${COMPONENT}"
  local SNAP_NAME="${REPO_ID}_${NOW}"

  echo "📸 Creating snapshot: $SNAP_NAME"
  aptly snapshot create "$SNAP_NAME" from repo "$REPO_ID"

  if aptly publish list | grep -q "$REPO_DISTRIBUTION.*$COMPONENT"; then
    echo "🔁 Switching publish for $COMPONENT"
    aptly publish switch -component="$COMPONENT" -gpg-key="$GPG_KEY_ID" "$REPO_DISTRIBUTION" "$SNAP_NAME"
  fi
}

# Function to generate a JSON summary of packages for a component
generate_packages_json() {
  local COMPONENT="$1"
  local REPO_ID="${REPO_NAME}-${COMPONENT}"
  local PACKAGES_FILE="/var/lib/aptly/${REPO_ID}_packages.json"

  aptly repo show -json -with-packages "$REPO_ID" | jq '
    .Packages
    | map(split("_") | {name: .[0], version: .[1], arch: .[2]})
    | group_by(.name)
    | map({
        name: .[0].name,
        version: (map(.version) | unique | sort),
        arch: (map(.arch) | unique)
      })
    | map(. + {latest_version: (.version | last)})
  ' > "$PACKAGES_FILE"

  echo "$PACKAGES_FILE"
}

# Function to send webhook notification with the packages JSON
notify_webhook() {
  local COMPONENT="$1"
  local PACKAGES_FILE="$2"

  if [[ -n "$NOTIFY_WEBHOOK_URL" ]]; then
    echo "📤 Sending packages.json to $NOTIFY_WEBHOOK_URL..."
    curl -s -X POST -H "Content-Type: application/json" \
      -H "x-repo-name: ${REPO_NAME}" \
      -H "x-repo-component: ${COMPONENT}" \
      --data "@$PACKAGES_FILE" \
      "$NOTIFY_WEBHOOK_URL?repo_name=$REPO_NAME&repo_component=$COMPONENT"
    echo "✅ Webhook sent"
  fi
}

# Function to send email notification about the update
send_email_notification() {
  local COMPONENT="$1"
  local PACKAGES_FILE="$2"

  if [[ "$NOTIFY_SENDMAIL" != "true" ]]; then
    return
  fi

  local MUTT_CONF="$(mktemp)"
  echo "📧 Sending mail to $MAIL_TO"
  echo "APT repository '$REPO_NAME', component '${COMPONENT}', has been updated on $(date +"%Y-%m-%d %H:%M:%S")" > /tmp/email.txt

  cat > "$MUTT_CONF" <<EOF
set from="$MAIL_FROM"
set realname="${MAIL_FROM:-Aptly Repo}"
set smtp_url="smtp://$SMTP_USER@$SMTP_HOST:$SMTP_PORT/"
set smtp_pass="$SMTP_PASS"
set ssl_starttls=${SMTP_STARTTLS:-no}
EOF

  # Ignore SSL certs if SMTP_IGNORE_CERTS is set
  if [[ "$SMTP_IGNORE_CERTS" == "true" ]]; then
    echo "set ssl_verify_host=no" >> "$MUTT_CONF"
    echo "set ssl_verify_dates=no" >> "$MUTT_CONF"
  fi


  local SUBJECT="${MAIL_SUBJECT:-APT Repo Update}"
  if [[ "$MAIL_ATTACHMENT" == "true" ]]; then
    mutt -F "$MUTT_CONF" -s "$SUBJECT" -a "$PACKAGES_FILE" -- "$MAIL_TO" < /tmp/email.txt
  else
    mutt -F "$MUTT_CONF" -s "$SUBJECT" -- "$MAIL_TO" < /tmp/email.txt
  fi

  rm -f /tmp/email.txt "$MUTT_CONF"
}

# Function to cleanup old snapshots and database
cleanup_snapshots() {
  local COMPONENT="$1"
  local REPO_ID="${REPO_NAME}-${COMPONENT}"
  local SNAPSHOTS=$(aptly snapshot list -raw | grep "^$REPO_ID" | sort -r)
  local SNAP_COUNT=$(echo "$SNAPSHOTS" | wc -l)

  if (( SNAP_COUNT > REPO_MAX_SNAPSHOTS )); then
    echo "🗑️ Cleaning up old snapshots..."
    echo "$SNAPSHOTS" | tail -n +$((REPO_MAX_SNAPSHOTS + 1)) | while read -r SNAP; do
      echo "🗑️ Deleting snapshot: $SNAP"
      aptly snapshot drop "$SNAP"
    done
  fi

  echo "🗑️ Cleaning up aptly database..."
  aptly db cleanup

  echo "🗑️ Cleaning up empty directories..."
  find /var/lib/aptly/public -type d -empty -delete
}

# Main start function
start() {
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

  # -- GPG
  if [[ -f "$GPG_KEY_PATH" ]]; then
    echo "🔐 Importing GPG key from $GPG_KEY_PATH..."
    gpg --batch --import "$GPG_KEY_PATH" &>/dev/null || true
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
    fi
  fi

  GPG_KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ { print $10; exit }')
  echo "$GPG_KEY_ID:6:" | gpg --import-ownertrust
  echo "🔑 Using GPG key ID: $GPG_KEY_ID"
  echo "🧩 Loading components: ${COMPONENTS[*]}"

  if [[ ! -f "$GPG_KEY_PATH" ]]; then
    echo "💾 Exporting generated private key to $GPG_KEY_PATH"
    mkdir -p "$(dirname "$GPG_KEY_PATH")"
    gpg --batch --yes --armor --export-secret-keys "$GPG_KEY_ID" > "$GPG_KEY_PATH"
  fi

  # -- /incoming dirs
  for COMPONENT in "${COMPONENTS[@]}"; do
    REPO_ID="${REPO_NAME}-${COMPONENT}"
    SNAP_NAME="${REPO_ID}_initial"

    mkdir -p "/incoming/$COMPONENT"

    if ! aptly repo list -raw | grep -q "^$REPO_ID$"; then
      echo "📦 Creating repo $REPO_ID"
      aptly repo create -distribution="$REPO_DISTRIBUTION" -component="$COMPONENT" "$REPO_ID" &>/dev/null
      echo "📸 Creating initial snapshot $SNAP_NAME for $COMPONENT"
      aptly snapshot create "$SNAP_NAME" from repo "$REPO_ID" &>/dev/null
    fi
  done

  # -- Initial publish of all snapshots
  if ! aptly publish list -raw | grep -q "$REPO_DISTRIBUTION"; then
    SNAPSHOTS=$(aptly snapshot list -raw | grep "_initial$" | sort -r)
    COMPONENTS=$(echo "${COMPONENTS[@]}" | tr ' ' ',')

    echo "🚀 Publishing initial snapshosts"
    aptly publish snapshot \
      -component="$COMPONENTS" \
      -distribution="$REPO_DISTRIBUTION" \
      -architectures="$REPO_ARCH" \
      -gpg-key="$GPG_KEY_ID" \
      $SNAPSHOTS  &>/dev/null
  fi

  # -- Cron
  if [[ -n "${CRON_UPDATE_COMPONENTS:-}" ]]; then
    echo "$CRON_UPDATE_COMPONENTS root /entrypoint.sh update" > /etc/cron.d/aptly-update
    chmod 0644 /etc/cron.d/aptly-update
    crontab /etc/cron.d/aptly-update
    cron
  fi

  # -- NGINX dynamic config
  TEMPLATE_FILE="/templates/nginx.conf"
  CONFIG_FILE="/config/nginx.conf"
  NGINX_LINK="/etc/nginx/conf.d/default.conf"

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "⚠️ Missing nginx.conf in /config, generating from template..."
    mkdir -p /config

    COMPONENTS_REGEX=$(echo "$REPO_COMPONENTS" | sed 's/,/|/g')
    ESCAPED_REGEX=$(echo "$COMPONENTS_REGEX" | sed 's/|/\\|/g')
    sed "s|__COMPONENTS_REGEX__|$ESCAPED_REGEX|g" "$TEMPLATE_FILE" > "$CONFIG_FILE"

    # Inject auth block if htpasswd present
    if [[ -s "/config/htpasswd" ]]; then
      sed -i '/__AUTH_BLOCK__/r'<(echo -e "        auth_basic \"Restricted\";\n        auth_basic_user_file /config/htpasswd;") "$CONFIG_FILE"
    fi

    # Clean placeholder
    sed -i '/__AUTH_BLOCK__/d' "$CONFIG_FILE"
  fi

  # -- Symlink config to NGINX expected path
  ln -sf "$CONFIG_FILE" "$NGINX_LINK"
  echo "🌐 Linked nginx.conf to $NGINX_LINK"

  mkdir -p /config/examples
  gpg --batch --yes --output /var/lib/aptly/public.gpg --armor --export "$GPG_KEY_ID"
  cp /var/lib/aptly/public.gpg "/config/examples/${REPO_NAME}-archive-keyring.gpg"

  SOURCES_FILE="/config/examples/${REPO_NAME}.sources"
  if [[ ! -f "$SOURCES_FILE" ]]; then
    cat > "$SOURCES_FILE" <<EOF
Types: deb
URIs: http://your-domain/
Suites: ${REPO_DISTRIBUTION}
Components: ${REPO_COMPONENTS//,/ }
Signed-By: /usr/share/keyrings/${REPO_NAME}-archive-keyring.gpg
EOF
  fi

  echo "✅ Ready. Starting NGINX..."
  exec nginx -g "daemon off;"
}

# Main update function
update() {
  TARGET_COMPONENTS=("${COMPONENTS[@]}")

  if [[ -n "$2" ]]; then
    IFS=',' read -ra REQUESTED <<< "$2"
    TARGET_COMPONENTS=()
    for REQ in "${REQUESTED[@]}"; do
      FOUND=false
      for COMPONENT in "${COMPONENTS[@]}"; do
        if [[ "$COMPONENT" == "$REQ" ]]; then
          TARGET_COMPONENTS+=("$REQ")
          FOUND=true
          break
        fi
      done
      if [[ "$FOUND" == false ]]; then
        echo "❌ Component '$REQ' not found in REPO_COMPONENTS: $REPO_COMPONENTS"
        echo "ℹ️ Available components: $REPO_COMPONENTS"
        exit 1
      fi
    done
  fi

  if [[ -f "$LOCKFILE" ]]; then
    echo "⛔️ Update already running. Exiting."
    exit 0
  fi

  touch "$LOCKFILE"
  trap 'rm -f "$LOCKFILE"' EXIT

  NOW=$(date +"%Y%m%d-%H%M%S")
  echo "🔄 Starting update for: ${TARGET_COMPONENTS[*]}"

  for COMPONENT in "${TARGET_COMPONENTS[@]}"; do
    if ! add_packages_to_repo "$COMPONENT"; then
      continue
    fi

    create_and_publish_snapshot "$COMPONENT" "$NOW"
    PACKAGES_FILE=$(generate_packages_json "$COMPONENT")

    notify_webhook "$COMPONENT" "$PACKAGES_FILE"
    send_email_notification "$COMPONENT" "$PACKAGES_FILE"
    cleanup_snapshots "$COMPONENT"
  done

  echo "✅ Update complete."
  exit 0
}

# Entrypoint command dispatcher
case "$1" in
  update)
    update "$@"
    ;;
  ""|start)
    start
    ;;
  *)
    echo "❓ Unknown command: $1"
    echo "Usage: $0 [start|update [component1,component2,...]]"
    echo "ℹ️ Available components: $REPO_COMPONENTS"
    exit 1
    ;;
esac
