# Automated RPi Tunneled NextCloud and Home Assistant  Deployment

Automated deployment of internet accessible Nextcloud and Home Assistant for Raspberry Pi 4/5 (Bookworm) via a Flask-based Web UI. Supports Pangolin and Cloudflare tunnels.

### 1\. Bootstrap

Download scripts and install core dependencies:

```bash
curl -fsSL https://raw.githubusercontent.com/oalterg/pinextcloudflaredeploy/main/install | sudo bash
```

### 2\. Tunnel Provisioning

Install the Web Manager service. Replace placeholders with your Pangolin/Newt credentials:

```bash
# Usage: provision.sh <NEWT_ID> <NEWT_SECRET> <NC_DOMAIN> <HA_DOMAIN> <PANGOLIN_ENDPOINT>
sudo /opt/raspi-nextcloud-setup/provision.sh "id" "secret" "cloud.example.com" "ha.example.com" "https://pangolin.endpoint"
```

### Usage

Open `http://<RPI_IP>/` in your browser. The Web UI manages the "headless" installation of Docker containers, system health, backups, and Cloudflare/Pangolin tunnel configuration.