# Aptly Docker — Secure & Flexible APT Repository Server

[![Docker Hub](https://img.shields.io/docker/pulls/yannmichaux/aptly?style=flat-square)](https://hub.docker.com/r/yannmichaux/aptly)
[![GitHub Release](https://img.shields.io/github/v/release/yannmichaux/aptly-docker?style=flat-square)](https://github.com/yannmichaux/aptly/releases)

A fully-featured, production-ready Docker image to serve a private APT repository using [Aptly](https://www.aptly.info/), with:

- 🔐 GPG signing (auto-generated or custom key)
- 📂 Multi-component support (e.g., `main`, `stable`, `testing`)
- 🧾 Modern `.sources` file generation for clients
- 📤 Upload `.deb` packages via `PUT`
- 📦 Automated publishing with cron
- 📊 Webhook + email notifications
- 🔒 Optional Basic Auth for uploads
- 🧩 Manual update via `docker exec aptly-server update [component]`

---

## 💡 How it works

This image follows a simplified **"one Aptly repo per component"** strategy.  
Each component (e.g., `main`, `stable`, `testing`) gets its **own Aptly repository**, allowing for isolated publishing, easier updates, and separate snapshots.

Each repository is named using the format:

```
<REPO_NAME>_<COMPONENT>
```

For example, if `REPO_NAME=internal` and `REPO_COMPONENTS=stable,testing`, the following Aptly repos will be created:

- `internal_stable`
- `internal_testing`

This approach improves clarity, avoids publishing conflicts, and lets you update components independently.

---

## 🚀 Quick Start (Docker Compose)

```yaml
services:
  aptly:
    container_name: aptly-server
    image: yannmichaux/aptly:latest
    ports:
      - "8080:80"
    environment:
      REPO_NAME: internal
      REPO_COMPONENTS: main,stable,testing
      REPO_DISTRIBUTION: noble
      REPO_ARCH: amd64

      # Optional cron for automatic update
      CRON_UPDATE_COMPONENTS: "*/15 * * * *"

      # Optional webhook
      NOTIFY_WEBHOOK_URL: https://my-webhook-server/notify

      # Optional email
      NOTIFY_SENDMAIL: true
      SMTP_HOST: smtp.domain.com
      SMTP_PORT: 587
      SMTP_USER: username
      SMTP_PASS: password
      SMTP_STARTTLS: no
      MAIL_FROM: aptly@domain.com
      MAIL_TO: you@domain.com
      MAIL_SUBJECT: "APT Repo Updated"
      MAIL_ATTACHMENT: true
    volumes:
      - aptly-data:/var/lib/aptly
      - /path/to/config:/config
      - /path/to/secrets:/secrets
      - /path/to/incoming:/incoming
    restart: unless-stopped

volumes:
  aptly-data:
```

---

## 📤 Upload Packages

Upload `.deb` files directly using `PUT`:

```bash
curl -X PUT --data-binary "@my-package.deb" http://<host>:8080/incoming/<component>/my-package.deb
```

> 🔐 If `/config/htpasswd` exists, Basic Auth will be enabled on incoming routes.

---

## 🔁 Update Mechanism

- Runs automatically via `CRON_UPDATE_COMPONENTS`
- Consumes `.deb` files from `/incoming/<component>`
- Creates repo & publishes snapshots per component
- Prevents concurrent updates via a lock file
- Generates a `packages.json` file for each component
- Optionally sends:
  - A webhook POST to `NOTIFY_WEBHOOK_URL`
  - An email if `NOTIFY_SENDMAIL=true`

### Manual update:

```bash
docker exec aptly-server update
```

### Update a specific component:

```bash
docker exec aptly-server update stable
```

### Update multiple components:

```bash
docker exec aptly-server update stable,testing
```

> ❗ If one component is not found, the update is aborted and a list of valid components is shown.

---

## 📬 Email Notifications

To enable email after each update:

```env
NOTIFY_SENDMAIL=true
SMTP_HOST=smtp.domain.com
SMTP_PORT=587
SMTP_USER=username
SMTP_PASS=password
SMTP_STARTTLS=no
MAIL_FROM=aptly@domain.com
MAIL_TO=you@domain.com
MAIL_SUBJECT="APT Repo Updated"
MAIL_ATTACHMENT=true
```

Uses `mutt` with SMTP authentication.

---

## 🔏 GPG Signing

- If `/secrets/private.asc` is present, it will be imported.
- If no key is found, one will be generated at startup.

Public key is available at:

```
http://<host>/gpg
```

---

## 📚 Client Configuration

A `.sources` file is generated at `/config/examples/<REPO_NAME>.sources`, e.g.:

```
Types: deb
URIs: http://your-domain/
Suites: noble
Components: main stable
Signed-By: /usr/share/keyrings/internal-archive-keyring.gpg
```

---

## 🧪 Manual Debug

Run in interactive mode:

```bash
docker run --rm -it yannmichaux/aptly /bin/bash
```

Trigger manual update inside the container:

```bash
/docker-entrypoint.sh update
```

---

## 🛠 Powered by

- [Aptly](https://www.aptly.info/)
- [NGINX](https://nginx.org/)
- [mutt](http://www.mutt.org/) (for SMTP)
