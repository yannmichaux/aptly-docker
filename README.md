# Aptly Docker — Secure & Flexible APT Repository Server

[![Docker Hub](https://img.shields.io/docker/pulls/yannmichaux/aptly?style=flat-square)](https://hub.docker.com/r/yannmichaux/aptly)
[![GitHub Release](https://img.shields.io/github/v/release/yannmichaux/aptly-docker?style=flat-square)](https://github.com/yannmichaux/aptly/releases)

This repository provides a fully featured, production-ready Docker image to serve a private APT repository using [Aptly](https://www.aptly.info/), with:

- 🔐 GPG signing (auto or custom key)
- 📂 Multi-component support (e.g., `main`, `stable`, etc.)
- 🧾 Modern `.sources` output for clients
- 📤 Upload `.deb` packages via `PUT`
- 📦 Automatic publication with cron
- 📊 Webhook + email notifications
- 🔒 Optional Basic Auth for upload routes
- 🧩 Manual updates via `docker exec aptly update [component]`

---

## 🚀 Quick Start (docker-compose)

```yaml
services:
  aptly:
    container_name: aptly-server
    image: yannmichaux/aptly:latest
    ports:
      - "8080:80"
    environment:
      # Repo name
      REPO_NAME: name
      # Comma separated components, eg: main,stable,foo,bar
      REPO_COMPONENTS: main
      # Target distro, such as bookworm, noble
      REPO_DISTRIBUTION: noble
      # Arch for repo, can be all, amd64, etc.
      REPO_ARCH: amd64
      # (Optional) Cron notation for automatic repository update
      CRON_UPDATE_COMPONENTS: "*/15 * * * *"
      # (Optional) Send packages.json to a URL using curl POST
      NOTIFY_WEBHOOK_URL: https://<host>/foo/bar
      # (Optional) Send mail using env vars after an update
      NOTIFY_SENDMAIL: true
      SMTP_HOST: smtp.domain.com
      SMTP_PORT: 587
      SMTP_USER: username
      SMTP_PASS: password
      MAIL_FROM: aptly@domain.com
      MAIL_TO: you@domain.com
      MAIL_SUBJECT: "APT Repo Updated"
      ## Send packages.json file as attachment on mail
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

You can also **manually trigger an update** from the host using:

```bash
docker exec aptly-server update
```

Or to update a specific component:

```bash
docker exec aptly-server update stable
```

To update multiple components (comma separated):

```bash
docker exec aptly-server update stable,testing
```

> If a component passed doesn't exist, the update will be aborted with a helpful message listing available components.

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

- Mount a key at `/secrets/private.asc` to use your own
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

Manually trigger an update (full control):

```bash
docker exec aptly-server update
```

---

## 🛠 Powered by

- [Aptly](https://www.aptly.info/)
- [NGINX](https://nginx.org/)
- [msmtp](https://marlam.de/msmtp/)
