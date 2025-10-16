# Raspberry Pi Nextcloud Setup Using Docker and Cloudflare

This repository automates deployment of **Nextcloud** on a **Raspberry Pi 5** using **Docker Compose**, optional **Cloudflare Tunnel** for secure remote access, and a robust **backup system**.

It aims to provide a production-ready Nextcloud environment with minimal manual setup and automated maintenance.

---

## Prerequisites

- Domain registered with **Cloudflare**
- Raspberry Pi 4 or 5 with **Raspberry Pi OS Lite** (fresh installation recommended)
- SSH access to the Raspberry Pi for headless setup
- (Optional) Separate SSD or USB drive for backups
- Internet connection for package installation and Docker setup

---

## Features

- **Nextcloud + MariaDB** fully containerized with Docker Compose  
- **Cloudflare Tunnel** for remote HTTPS access with automatic DNS updates  
- **Local-only mode**: access via `http://<raspi-ip>:8080` if Cloudflare is not used  
- **Automatic backups** of Nextcloud data and database (compressed, timestamped)  
- Weekly cron job for unattended backups with disk space management  
- **Maintenance mode** automation during backup  
- Minimal manual configuration; fully bootstrapped via `install`

---

## Quickstart

### 1. Bootstrap on a Fresh Raspberry Pi

Run the following on a clean Raspberry Pi OS Lite installation:

```bash
curl -fsSL https://raw.githubusercontent.com/oalterg/pinextcloudflaredeploy/main/install | sudo bash
