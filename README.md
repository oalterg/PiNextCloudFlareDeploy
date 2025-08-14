# Raspberry Pi Nextcloud + Cloudflare Tunnel Setup

This project fully automates deployment of Nextcloud on a Raspberry Pi with:

- NVMe boot
- Raspbian Lite
- Dockerized Nextcloud + MariaDB
- Cloudflare Tunnel for SSL and remote access
- Automated weekly backups

## Quick Install

On a fresh Raspberry Pi (Raspbian Lite):

```bash
curl -sSL https://raw.githubusercontent.com/YOURUSER/raspi-nextcloud-setup/main/install.sh | sudo bash
