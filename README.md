# WireGuard VPN Stack with TOTP Authentication

A production-ready, self-hosted VPN stack combining **WireGuard** (via wg-easy), **Authelia** (TOTP/2FA), **Traefik** (reverse proxy + TLS), **PostgreSQL**, and **Redis** — all in Docker Compose.

## Architecture

```
Internet User
    │
    ▼
[Traefik :443]  ──── TLS termination, routes by hostname
    │
    ├──► [Authelia :9091]          auth.yourdomain.com
    │         │  Username + Password
    │         │  TOTP (Google Authenticator)
    │         │           │
    │         │     ┌─────┴──────┐
    │         │   [Redis]   [PostgreSQL]
    │         │   Sessions    TOTP secrets
    │         │
    └──► [wg-easy :51821]         vpn.yourdomain.com  ← Protected by Authelia TOTP
              │  (Admin panel: create/manage WireGuard peers)
              │
    ┌─────────┘
[WireGuard :51820/UDP]   ← Direct UDP, VPN clients connect here
    │
    └── VPN Clients (phones, laptops, etc.)
```

## Prerequisites

- Docker Engine 24+ and Docker Compose v2
- A server with a public IP or DDNS hostname
- UDP port **51820** open in your firewall (for WireGuard clients)
- TCP ports **80** and **443** open (for Traefik/admin panel)
- Linux kernel with WireGuard support (any modern kernel ≥5.6)

## Quick Start

### 1. Clone and Configure

```bash
git clone <your-repo> vpn-stack
cd vpn-stack

# Create and edit your .env file
cp .env.example .env
nano .env
```

Edit `.env` and set at minimum:
```bash
DOMAIN=vpn.yourdomain.com          # Your base domain
VPN_HOST=203.0.113.10              # Your server's public IP
TZ=Asia/Dubai
```

### 2. Generate Secrets

```bash
chmod +x scripts/manage.sh
./scripts/manage.sh init           # Auto-generates secrets in .env
```

### 3. Set Up Your Admin Password

```bash
# Generate a password hash
./scripts/manage.sh hash-password 'YourStrongPassword123!'
```

Copy the `$argon2id$...` hash into `authelia/config/users_database.yml`:

```yaml
users:
  admin:
    disabled: false
    displayname: "VPN Admin"
    password: "$argon2id$v=19$..."   # ← paste hash here
    email: admin@yourdomain.com
    groups:
      - vpn-admins
```

### 4. DNS Setup

Create these DNS records pointing to your server IP:

| Subdomain            | Type | Value         |
|----------------------|------|---------------|
| `vpn.yourdomain.com`    | A    | YOUR_SERVER_IP |
| `auth.yourdomain.com`   | A    | YOUR_SERVER_IP |
| `traefik.yourdomain.com`| A    | YOUR_SERVER_IP |

### 5. TLS Certificates

**Option A — Let's Encrypt (recommended for public domains):**

Uncomment the ACME lines in `docker-compose.yml` under the Traefik command:
```yaml
- "--certificatesresolvers.letsencrypt.acme.email=${ACME_EMAIL}"
- "--certificatesresolvers.letsencrypt.acme.storage=/certs/acme.json"
- "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
```
Then add `tls: { certResolver: letsencrypt }` to each router in labels.

**Option B — Self-signed (internal/testing):**
```bash
openssl req -x509 -newkey rsa:4096 -nodes \
  -keyout traefik/certs/key.pem \
  -out traefik/certs/cert.pem \
  -days 365 -subj "/CN=*.yourdomain.com"
```
Uncomment the `certificates` block in `traefik/config/tls.yml`.

### 6. Deploy

```bash
./scripts/manage.sh up
./scripts/manage.sh status
```

### 7. First Login & TOTP Registration

1. Browse to `https://vpn.yourdomain.com`
2. You'll be redirected to `https://auth.yourdomain.com`
3. Log in with your username/password
4. Authelia will ask to **register a TOTP device**
5. Scan the QR code with **Google Authenticator** (or any TOTP app)
6. Enter the 6-digit code to confirm
7. You're now at the **wg-easy admin panel** — create your first VPN peer!

---

## User Management

### Add a New Admin/User

```bash
./scripts/manage.sh add-user john john@company.com 'Password123!' vpn-admins
```

Or manually edit `authelia/config/users_database.yml` — changes are **hot-reloaded** (no restart needed).

### Reset a User's TOTP

If a user loses their authenticator app:
```bash
./scripts/manage.sh totp-reset john
```
The user will be prompted to register a new TOTP device on their next login.

### Disable a User (without deleting)

```yaml
users:
  john:
    disabled: true    # ← blocks login immediately (hot-reloaded)
```

---

## WireGuard Client Setup

1. Log in to `https://vpn.yourdomain.com` (requires TOTP)
2. Click **"+ New Client"** and name it (e.g., `john-laptop`)
3. Download the `.conf` file or scan the QR code with the WireGuard mobile app
4. The VPN tunnel connects to `YOUR_SERVER_IP:51820/UDP`

### Client Apps
- **Windows/macOS**: [wireguard.com/install](https://www.wireguard.com/install/)
- **iOS/Android**: WireGuard app from App Store / Play Store
- **Linux**: `apt install wireguard` or `dnf install wireguard-tools`

---

## Firewall Rules (UFW / iptables)

```bash
# Allow WireGuard UDP (required for VPN clients)
ufw allow 51820/udp

# Allow HTTP/HTTPS for admin panel
ufw allow 80/tcp
ufw allow 443/tcp

# Block direct access to internal ports
ufw deny 51821/tcp    # wg-easy UI — only accessible via Traefik+Authelia
ufw deny 9091/tcp     # Authelia — only via Traefik
```

---

## Monitoring Integration

Since you're running Zabbix + InfluxDB, wg-easy v15 exposes **Prometheus metrics**:

```yaml
# Add to wg-easy environment in docker-compose.yml:
- METRICS_ENABLED=true
- METRICS_PORT=51822
```

Scrape from Prometheus/InfluxDB Telegraf:
```toml
[[inputs.prometheus]]
  urls = ["http://wg-easy:51822/metrics"]
```

---

## Backup & Recovery

```bash
# Full backup (WireGuard config + Authelia DB + config files)
./scripts/manage.sh backup
# Saved to: ./backups/YYYYMMDD_HHMMSS/
```

Backups contain:
- `wireguard.tar.gz` — all WireGuard peer configs and keys
- `authelia_config/` — Authelia config + user database
- `authelia_db.sql.gz` — PostgreSQL dump (TOTP secrets, sessions)

---

## File Structure

```
vpn-stack/
├── docker-compose.yml          # Main stack definition
├── .env.example                # Environment template
├── .env                        # Your secrets (gitignored!)
├── .gitignore
├── authelia/
│   └── config/
│       ├── configuration.yml   # Authelia config (TOTP, access rules)
│       ├── users_database.yml  # User accounts + password hashes
│       └── notifications.txt   # TOTP registration links (filesystem notifier)
├── traefik/
│   ├── config/
│   │   └── tls.yml             # TLS options
│   └── certs/                  # TLS certificates (if self-signed)
├── scripts/
│   └── manage.sh               # Setup & management CLI
└── backups/                    # Auto-created by backup command
```

---

## Security Notes

- wg-easy's **built-in password is disabled** — access is 100% controlled by Authelia TOTP
- All internal services are on an **isolated Docker network** (no direct external access)
- PostgreSQL and Redis are **not exposed** on the host — only accessible within Docker
- Authelia enforces **Argon2id** password hashing (memory-hard, brute-force resistant)
- TOTP uses **30-second windows** with ±1 skew tolerance for clock drift
- Session tokens are stored in Redis with configurable **1-hour expiry**

---

## Stack Component Versions

| Service    | Image                          | GitHub Stars | License  |
|------------|-------------------------------|-------------|----------|
| wg-easy    | `ghcr.io/wg-easy/wg-easy:15`  | ⭐ 24.7k    | MIT      |
| Authelia   | `authelia/authelia:4.39`      | Actively maintained | Apache 2.0 |
| Traefik    | `traefik:v3.2`                | ⭐ 54k+     | MIT      |
| PostgreSQL | `postgres:16-alpine`           | —           | PostgreSQL |
| Redis      | `redis:7-alpine`               | —           | BSD 3    |
