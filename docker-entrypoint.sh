#!/bin/bash
set -e

REPO_NAME="${REPO_NAME:-default}"
REPO_COMPONENTS="${REPO_COMPONENTS:-main}"
REPO_DISTRIBUTION="${REPO_DISTRIBUTION:-noble}"
REPO_ARCH="${REPO_ARCH:-amd64}"
GPG_KEY_PATH="${GPG_KEY_PATH:-/secrets/private.asc}"
CONFIG_PATH="/config/aptly.conf"

LOCKFILE="/tmp/aptly-update.lock"
PACKAGES_FILE="/var/lib/aptly/packages.json"

IFS=',' read -ra COMPONENTS <<< "$REPO_COMPONENTS"

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
    fi
  fi

  GPG_KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ { print $10; exit }')
  echo "$GPG_KEY_ID:6:" | gpg --import-ownertrust
  echo "🔑 Using GPG key ID: $GPG_KEY_ID"
  echo "🧩 Loaded components: ${COMPONENTS[*]}"

  if [[ ! -f "$GPG_KEY_PATH" ]]; then
    echo "💾 Exporting generated private key to $GPG_KEY_PATH"
    mkdir -p "$(dirname "$GPG_KEY_PATH")"
    gpg --batch --yes --armor --export-secret-keys "$GPG_KEY_ID" > "$GPG_KEY_PATH"
  fi

  # -- /incoming dirs
  for COMPONENT in "${COMPONENTS[@]}"; do
    mkdir -p "/incoming/$COMPONENT"
  done

  # -- Create repo if needed
  if ! aptly repo list -raw | grep -q "^$REPO_NAME$"; then
    FIRST_COMPONENT=$(echo "$REPO_COMPONENTS" | cut -d',' -f1)
    echo "📦 Creating repo $REPO_NAME with component $FIRST_COMPONENT"
    aptly repo create -distribution="$REPO_DISTRIBUTION" -component="$FIRST_COMPONENT" "$REPO_NAME"
  fi

  # -- Initial publish if not yet done (via snapshots for switch compatibility)
  if ! aptly publish list | grep -q "$REPO_DISTRIBUTION"; then
    echo "📸 Creating initial empty snapshots for each component..."

    COMPONENT_LIST=()
    SNAPSHOT_LIST=()

    for COMPONENT in "${COMPONENTS[@]}"; do
      SNAP_NAME="${COMPONENT}_initial"
      echo "📸 Creating snapshot $SNAP_NAME"
      aptly snapshot create "$SNAP_NAME" from repo "$REPO_NAME"
      COMPONENT_LIST+=("$COMPONENT")
      SNAPSHOT_LIST+=("$SNAP_NAME")
    done

    COMPONENTS_JOINED=$(IFS=, ; echo "${COMPONENT_LIST[*]}")

    echo "🚀 Publishing initial snapshots with components: $COMPONENTS_JOINED"
    aptly publish snapshot \
      -component="$COMPONENTS_JOINED" \
      -distribution="$REPO_DISTRIBUTION" \
      -architectures="$REPO_ARCH" \
      -gpg-key="$GPG_KEY_ID" \
      "${SNAPSHOT_LIST[@]}"
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

  if [[ -n "$NOTIFY_WEBHOOK_URL" ]]; then
    echo "📤 Sending packages.json to $NOTIFY_WEBHOOK_URL..."
    curl -s -X POST -H "Content-Type: application/json" --data "@$PACKAGES_FILE" "$NOTIFY_WEBHOOK_URL"
    echo "✅ Webhook sent"
  fi

  if [[ "$NOTIFY_SENDMAIL" == "true" ]]; then
    echo "📧 Sending mail to $MAIL_TO"
    echo "APT Repo '$REPO_NAME' updated on $(date)" > /tmp/email.txt
    SUBJECT="${MAIL_SUBJECT:-APT Repo Update}"
    # ... msmtp logic as before ...
  fi

  echo "✅ Update complete."
}

# --- Entrypoint dispatcher
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
