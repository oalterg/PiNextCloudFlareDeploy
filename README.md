# HomeBrain: Self-Hosted Private Cloud Server for Raspberry Pi

HomeBrain automates the deployment of a fully private, internet-accessible Raspberry Pi server with Nextcloud and Home Assistant. Achieve setup in under 10 minutes—no static IP, port forwarding, or dynamic DNS required. Enjoy 100% data ownership, privacy, and control with open-source code.

## Key Features

- **100% Open Source & Self-Owned**: BSD-3-Clause licensed; all code is transparent and modifiable. You own your data—no vendor lock-in or third-party access.
- **Ironclad Data Privacy**: Everything runs on your hardware. No external telemetry, cloud dependencies, or data sharing. Tunnels ensure secure, encrypted access without exposing your network.
- **Secure Setup & Authentication**: Starts with a factory password (printed on device label) for initial claiming. Automatically generates a strong, random master password during deployment, displayed securely once via an encrypted endpoint—superseding the factory default for all services (Manager, Nextcloud, Home Assistant).
- **Plug-and-Play Services**: Nextcloud for file sync/storage, Home Assistant for smart home control, all containerized with Docker.
- **Intuitive Web Dashboard**: Monitor system health (CPU, RAM, storage, services), manage backups/restores, configure FTP/Zigbee, and perform upgrades—one-click simplicity.
- **Automated Backups**: Scheduled snapshots with retention policies, drive mounting/formatting, and easy restores.
- **Tunnel-Based Connectivity**: Secure external access via Pangolin or Cloudflare—zero configuration hassle.

## Connectivity Overview

HomeBrain leverages tunnels for seamless, secure routing:
- Main domain (e.g., cloud.example.com) → Manager Dashboard.
- nc subdomain (e.g., nc.cloud.example.com) → Nextcloud.
- ha subdomain (e.g., ha.cloud.example.com) → Home Assistant.

All handled automatically during provisioning.

## Prerequisites

- Raspberry Pi 5 with Ethernet internet (headless).
- Fresh 64-bit Raspberry Pi OS Lite with SSH enabled.
- Pangolin-registered domain and tunnel credentials.

## Installation

1. **Bootstrap**:
   ```
   curl -fsSL https://raw.githubusercontent.com/oalterg/homebrain/main/install | sudo bash
   ```

2. **Provision Tunnel** (replace placeholders):
   ```
   sudo /opt/homebrain/scripts/provision.sh "<NEWT_ID>" "<NEWT_SECRET>" "<MAIN_DOMAIN>" "<PANGOLIN_ENDPOINT>" "<FACTORY_PASSWORD>"
   ```

3. **Reboot Device**
   ```
   sudo reboot
   ```

## Usage

Access the dashboard at your main domain (or locally via RPi IP). Manage services, monitor resources, and configure features. Initial login uses the generated master password—save it securely.

## Privacy & Security Highlights

- **End-to-End Ownership**: Data stays on your device; no cloud intermediaries.
- **Hardened Deployment**: Atomic updates, permission controls, and rate-limited auth.
- **Password Mechanism**: Factory password enables first boot; auto-replaced by cryptographically secure generator for ongoing use.

## License

BSD-3-Clause. See [LICENSE](LICENSE) for details.