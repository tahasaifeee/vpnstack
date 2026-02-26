# WireGuard VPN Stack with TOTP Authentication

A production-ready, self-hosted VPN stack combining **WireGuard** (via wg-easy), **Authelia** (TOTP/2FA), **Traefik** (reverse proxy + TLS), **PostgreSQL**, and **Redis** — all in Docker Compose.

---

## One-Click Install

Run this on any fresh Linux server — the installer handles everything interactively:

```bash
curl -fsSL https://raw.githubusercontent.com/tahasaifeee/vpnstack/main/install.sh | sudo bash
```

Or with `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/tahasaifeee/vpnstack/main/install.sh | sudo bash
```

**Supported OS:** Ubuntu 20+, Debian 11+, AlmaLinux 8/9, Rocky Linux 8/9, RHEL 8/9, CentOS Stream, Fedora

The installer will ask you:

| Question | Default |
|---|---|
| Base domain (e.g. `example.com`) | — |
| Server public IP / hostname | Auto-detected |
| Timezone | System timezone |
| Admin username & password | `admin` |
| Enable TOTP two-factor auth? | Yes |
| TLS method (Let's Encrypt or self-signed) | Let's Encrypt |
| WireGuard DNS servers | `1.1.1.1, 8.8.8.8` |
| Configure firewall automatically? | Yes |

It then generates all config files, hashes your password with Argon2id, issues/downloads TLS certs, and starts the full stack — no manual editing required.

> **Custom install directory:** `VPNSTACK_DIR=/your/path curl ... | sudo bash`

---

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

**Networks:**
- `proxy` — Traefik, wg-easy, Authelia (internet-facing)
- `vpn_internal` — PostgreSQL, Redis (no direct internet access)

---

## Prerequisites

- A fresh Linux server with a **public IP** (or DDNS hostname)
- Ports open in your cloud/host firewall:
  - `80/tcp` — HTTP (used by Let's Encrypt challenge)
  - `443/tcp` — HTTPS (Traefik + admin panel)
  - `51820/udp` — WireGuard VPN tunnel
- Linux kernel ≥ 5.6 (WireGuard built-in; all modern distros qualify)
- Docker and Docker Compose are installed **automatically** by the installer

---

## After Installation

### DNS Records

Create three A records pointing to your server IP:

| Record | Type | Value |
|---|---|---|
| `vpn.yourdomain.com` | A | YOUR_SERVER_IP |
| `auth.yourdomain.com` | A | YOUR_SERVER_IP |
| `traefik.yourdomain.com` | A | YOUR_SERVER_IP |

### First Login

1. Open `https://vpn.yourdomain.com`
2. You're redirected to `https://auth.yourdomain.com`
3. Log in with your admin username and password
4. If TOTP is enabled: scan the QR code with **Google Authenticator** (or Authy/1Password)
5. Enter the 6-digit code — you're now in the **wg-easy admin panel**
6. Click **"+ New Client"** to create your first VPN peer

---

## Stack Management

The installer creates a `vpnstack` command available system-wide:

```bash
vpnstack up                                          # Start the stack
vpnstack down                                        # Stop the stack
vpnstack restart                                     # Restart all services
vpnstack status                                      # Health check all containers
vpnstack logs [service]                              # Follow logs (all or specific)
vpnstack add-user <name> <email> <pass> <group>     # Add Authelia user
vpnstack hash-password 'MyPassword123!'             # Generate Argon2id hash
vpnstack totp-reset <username>                       # Force TOTP re-enrollment
vpnstack backup                                      # Backup volumes + config files
vpnstack update                                      # Pull latest images & restart
```

Direct Docker Compose commands also work from the install directory (default `/opt/vpnstack`):

```bash
cd /opt/vpnstack
docker compose up -d
docker compose logs -f traefik
docker compose ps
```

---

## User Management

### Add a user

```bash
vpnstack add-user john john@company.com 'Password123!' vpn-admins
```

Changes are **hot-reloaded** by Authelia — no restart needed.

### Disable a user (without deleting)

Edit `/opt/vpnstack/authelia/config/users_database.yml`:

```yaml
users:
  john:
    disabled: true    # ← blocks login immediately
```

### Reset a user's TOTP

If a user loses their authenticator app:

```bash
vpnstack totp-reset john
```

They'll be prompted to register a new TOTP device on next login.

---

## WireGuard Client Setup

1. Log in to `https://vpn.yourdomain.com`
2. Click **"+ New Client"** → name it (e.g. `john-laptop`)
3. Download the `.conf` file or scan the QR code with the WireGuard app

**Client apps:**
- **Windows / macOS:** [wireguard.com/install](https://www.wireguard.com/install/)
- **iOS / Android:** WireGuard from App Store / Play Store
- **Linux:** `apt install wireguard` or `dnf install wireguard-tools`

---

## Backup & Recovery

```bash
vpnstack backup
# Saved to: /opt/vpnstack/backups/YYYYMMDD_HHMMSS/
```

Each backup contains:
- `wireguard.tar.gz` — WireGuard peer configs and keys
- `authelia_config/` — Authelia config + user database
- `authelia_db.sql.gz` — PostgreSQL dump (TOTP secrets, sessions)
- `.env.bak` — copy of secrets file

---

## File Structure

```
/opt/vpnstack/                      ← default install directory
├── install.sh                      # Master installer (this script)
├── docker-compose.yml              # Generated stack definition
├── .env                            # All secrets (gitignored)
├── authelia/
│   └── config/
│       ├── configuration.yml       # Authelia settings (TOTP, session, storage)
│       ├── users_database.yml      # User accounts + Argon2id hashes
│       └── notifications.txt       # TOTP registration links (filesystem notifier)
├── traefik/
│   ├── config/
│   │   └── tls.yml                 # TLS cipher options and cert paths
│   └── certs/                      # Self-signed cert or Let's Encrypt acme.json
├── scripts/
│   └── manage.sh                   # Management CLI (symlinked as /usr/local/bin/vpnstack)
└── backups/                        # Created by vpnstack backup
```

---

## Security Notes

- wg-easy's **built-in password is disabled** — access is 100% controlled by Authelia
- All database/cache services are on an **isolated Docker network** (no external access)
- Authelia enforces **Argon2id** password hashing (memory-hard, brute-force resistant)
- TOTP uses **30-second windows** with ±1 skew tolerance for clock drift
- Session tokens expire after **1 hour of inactivity**
- The `STORAGE_ENCRYPTION_KEY` in `.env` **must never change** — it encrypts the TOTP database

---

## Monitoring (Optional)

wg-easy v15 exposes Prometheus metrics. Enable during install or add to `docker-compose.yml`:

```yaml
- METRICS_ENABLED=true
- METRICS_PORT=51822
```

Telegraf / Prometheus scrape endpoint: `http://wg-easy:51822/metrics`

---

## Stack Component Versions

| Service    | Image                         | Stars   | License    |
|------------|------------------------------|---------|------------|
| wg-easy    | `ghcr.io/wg-easy/wg-easy:15` | ⭐ 24.7k | MIT        |
| Authelia   | `authelia/authelia:4.39`     | Actively maintained | Apache 2.0 |
| Traefik    | `traefik:v3.2`               | ⭐ 54k+ | MIT        |
| PostgreSQL | `postgres:16-alpine`          | —       | PostgreSQL |
| Redis      | `redis:7-alpine`              | —       | BSD 3      |
