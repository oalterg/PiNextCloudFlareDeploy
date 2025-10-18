# Raspberry Pi Nextcloud Setup Using Docker and Cloudflare

This project automates the deployment and management of a production-ready Nextcloud instance on a Raspberry Pi 5 or 4.

It uses a Text User Interface (TUI) to manage a containerized stack (Docker Compose), secure remote access (Cloudflare Tunnel), and a robust backup system.

-----

## Prerequisites

  * A Raspberry Pi 4 or 5 with a fresh installation of Raspberry Pi OS Lite booted from SSD or NVMe.
  * A domain registered with Cloudflare.
  * SSH access to the Raspberry Pi.

-----

## Features

  * **TUI-Driven Management:** A `dialog`-based interface for setup, backups, restores, and maintenance.
  * **Containerized Stack:** Deploys Nextcloud and MariaDB using Docker Compose.
  * **Secure Remote Access:** Automatically configures a Cloudflare Tunnel for HTTPS access without opening firewall ports.
  * **Backup & Restore:** TUI-driven functions to create full backups (data + DB) and restore from an archive.
  * **Automated Backups:** Configure a weekly cron job for unattended backups and retention.
  * **Storage Management:**
      * **OS Cloning:** TUI option to flash the running OS from an SD card to an NVMe/SSD drive.
      * **LVM Expansion:** A guided, multi-phase process to expand the root filesystem across two separate SSD/NVMe drives.
  * **System Health:** A TUI dashboard to check Docker status, container health, disk space, and recent log errors.

-----

## Quickstart

Run the following command on a fresh Raspberry Pi OS Lite installation. This will download the installer, install dependencies, and launch the main TUI script.

```bash
curl -fsSL https://raw.githubusercontent.com/oalterg/pinextcloudflaredeploy/main/install | sudo bash
```

After installation, you can re-launch the interface at any time by running:

```bash
sudo raspi-cloud
```