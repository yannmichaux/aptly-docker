# Aptly Docker — Secure & Flexible APT Repository Server

[![Docker Hub](https://img.shields.io/docker/pulls/yannmichaux/aptly?style=flat-square)](https://hub.docker.com/r/yannmichaux/aptly)

This repository provides a fully featured, production-ready Docker image to serve a private APT repository using [Aptly](https://www.aptly.info/), with:

- 🔐 GPG signing (auto or custom key)
- 📂 Multi-component support (e.g., `stable`, `testing`, `public`)
- 🧾 Modern `.sources` output for clients
- 📤 Upload `.deb` packages via `PUT`
- 📦 Automatic publication with cron
- 📊 Webhook + email notifications
- 🔒 Optional Basic Auth for upload routes

---

## 🚀 Quick Start (docker-compose)

```yaml
version: "3.8"

services:
  aptly:
    container_name: aptly-server
    image: yannmichaux/aptly:latest
    ports:
      - "8080:80"
    environment:
      REPO_NAME: name
      REPO_COMPONENTS: main
      REPO_DISTRIBUTION: noble
      REPO_ARCH: amd64
      CRON_UPDATE_COMPONENTS: "*/15 * * * *"
      NOTIFY_SENDMAIL: "false"
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

## 📤 Uploading packages

Upload `.deb` files to an incoming component using `PUT`:

```bash
curl -X PUT --data-binary "@my-package.deb" http://<host>/incoming/stable/my-package.deb
```

> 🔒 Optionally protect with Basic Auth via `/config/htpasswd`.

---

## 🔁 Update mechanism

- Automatically runs every X minutes via `CRON_UPDATE_COMPONENTS`
- Accepts uploads from `/incoming/<component>`
- Creates and publishes snapshots (only if `.deb` present)
- Prevents concurrent updates via lockfile
- Generates `packages.json` with available packages
- Optionally sends:
  - A webhook POST via `NOTIFY_WEBHOOK_URL`
  - An email if `NOTIFY_SENDMAIL=true`

---

## 📬 Email (optional)

Set the following variables if you want email notifications:

```env
NOTIFY_SENDMAIL=true
SMTP_HOST=smtp.domain.com
SMTP_PORT=587
SMTP_USER=username
SMTP_PASS=password
MAIL_FROM=aptly@domain.com
MAIL_TO=you@domain.com
MAIL_SUBJECT="APT Repo Updated"
MAIL_ATTACHMENT=true
```

---

## 🔏 GPG Signing

- Mount a key at `/secrets/private.pgp` to use your own
- Or let the container generate one automatically
- Public key is exposed at:
  ```
  http://host/gpg
  ```

---

## 📚 Client Configuration

An example `.sources` file is generated at `/config/examples/<repo>.sources`, such as:

```text
Types: deb
URIs: http://<host>/
Suites: noble
Components: stable testing public
Signed-By: /usr/share/keyrings/<name>-archive-keyring.gpg
```

---

## 🧪 Debug manually

Run interactively:

```bash
docker run --rm -it yannmichaux/aptly /bin/bash
```

Manually trigger an update:

```bash
docker exec aptly-server /entrypoint.sh update
```

---

## 🛠 Powered by

- [Aptly](https://www.aptly.info/)
- [NGINX](https://nginx.org/)
- [msmtp](https://marlam.de/msmtp/)
