# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A self-hosted VPN stack using Docker Compose. The WireGuard admin panel is protected by Authelia TOTP authentication — there is no built-in password fallback, access requires both a valid Authelia session and TOTP code.

## Stack Management

All operations go through `scripts/manage.sh` (not tracked in git — created during setup):

```bash
./scripts/manage.sh init                                      # Generate all secrets
./scripts/manage.sh hash-password 'password'                  # Argon2id hash for users.yml
./scripts/manage.sh add-user <name> <email> <pass> <group>   # Add Authelia user
./scripts/manage.sh totp-reset <username>                     # Force TOTP re-enrollment
./scripts/manage.sh backup                                    # Backup volumes + config
./scripts/manage.sh up                                        # Start full stack
./scripts/manage.sh status                                    # Health check all services
```

Direct Docker Compose commands also work:
```bash
docker compose up -d
docker compose down
docker compose logs -f <service>   # traefik, authelia, wg-easy, postgres, redis
```

## Architecture

```
Internet → Traefik (:443) → Authelia forward-auth → wg-easy admin panel
                                                   → WireGuard VPN (:51820/UDP, direct)
```

**Networks:**
- `proxy` — Traefik, wg-easy, Authelia (internet-facing)
- `vpn_internal` — PostgreSQL, Redis (no external access)

**Service roles:**
- **Traefik** — TLS termination, hostname-based routing, enforces Authelia middleware on `vpn.yourdomain.com`
- **Authelia** — Forward-auth provider; TOTP secrets and session metadata in PostgreSQL; session tokens in Redis
- **wg-easy** — WireGuard kernel interface (UDP 51820) + web admin UI (51821, only reachable through Traefik+Authelia)
- **PostgreSQL** — Authelia's persistent store (TOTP secrets, user sessions)
- **Redis** — Authelia session cache (128MB, LRU eviction, password-protected)

## Configuration

All secrets and domain settings live in `.env` (git-ignored). Use `.env.example` as the template. Required variables:

- `DOMAIN` / `VPN_HOST` — your public domain and IP
- `AUTHELIA_JWT_SECRET`, `AUTHELIA_SESSION_SECRET`, `AUTHELIA_STORAGE_ENCRYPTION_KEY` — 64-char hex strings
- `POSTGRES_PASSWORD`, `REDIS_PASSWORD`
- `ACME_EMAIL` — for Let's Encrypt

Authelia user database is at `authelia/users.yml` (created during setup, not tracked in git). Passwords use Argon2id hashing.

## Key Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | All service definitions, networks, volumes, Traefik labels |
| `.env.example` | Template for all required environment variables |
| `.gitignore` | Protects `.env`, `traefik/certs/`, `backups/` from being committed |

## Security Constraints

- Never commit `.env`, `authelia/users.yml`, or anything under `traefik/certs/` or `backups/` — these are git-ignored for a reason.
- The Authelia `STORAGE_ENCRYPTION_KEY` must remain consistent across restarts; changing it corrupts the database.
- WireGuard port 51820/UDP must be open directly in the firewall; it does not go through Traefik.
- Ports 80 and 443 must be open for Traefik (80 redirects to 443).
