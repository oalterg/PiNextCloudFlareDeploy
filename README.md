# HomeBrain: Automated RPi Tunneled NextCloud and Home Assistant Deployment

Deploy and manage your own, fully private, internet-accessible Raspberry Pi cloud server in under 10 minutes, without requiring static IP, port-forwarding, or dynamic DNS.

Automates deployment of Nextcloud and Home Assistant via a Flask-based Web UI. Supports Pangolin and Cloudflare tunnels.


### 0\. Prerequisites

 0. RaspberryPi 5 with LAN internet access (headless) with fresh 64bit Raspberry Pi OS Lite install and ssh access
 1. Pangolin or Cloudflared registered Domain
 2. Tunnel (with keys) created from Pangolin or Cloudflare dashboard

### 1\. Bootstrap

Download scripts and install core dependencies:

```bash
curl -fsSL https://raw.githubusercontent.com/oalterg/homebrain/main/install | sudo bash
```

### 2\. Tunnel Provisioning

Install the HomeBrain Manager service. Replace placeholders with your Pangolin/Newt credentials:

```bash
# Usage: provision.sh <NEWT_ID> <NEWT_SECRET> <NC_DOMAIN> <HA_DOMAIN> <PANGOLIN_ENDPOINT>
sudo /opt/homebrain/scripts/provision.sh "id" "secret" "cloud.example.com" "ha.example.com" "https://pangolin.endpoint"
```

### Usage

Open `http://<RPI_IP>/` in your browser. The Web UI manages the "headless" installation of Docker containers, system health, backups, and Cloudflare/Pangolin tunnel configuration.
