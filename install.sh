#!/usr/bin/env bash
# =============================================================================
# VPN Stack Master Installer v1.0
# Components: WireGuard (wg-easy) + Authelia + Traefik + PostgreSQL + Redis
# Supported:  Ubuntu 20+, Debian 11+, AlmaLinux/Rocky/RHEL 8+, CentOS Stream, Fedora
# One-liner:  curl -fsSL https://raw.githubusercontent.com/tahasaifeee/vpnstack/main/install.sh | sudo bash
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── Constants ─────────────────────────────────────────────────────────────────
INSTALL_DIR="${VPNSTACK_DIR:-/opt/vpnstack}"
LOG_FILE="/tmp/vpnstack-install.log"
SCRIPT_VERSION="1.0.0"
MIN_DOCKER_MAJOR=24

# ── Colors (disabled when not a terminal) ────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Logging ───────────────────────────────────────────────────────────────────
log()     { echo -e "${GREEN}[✔]${RESET} $*" | tee -a "$LOG_FILE"; }
info()    { echo -e "${BLUE}[i]${RESET} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*" | tee -a "$LOG_FILE"; }
die()     { echo -e "${RED}[✘]${RESET} $*" | tee -a "$LOG_FILE" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}" | tee -a "$LOG_FILE"; }

# ── TTY-safe prompts (works when script is piped via curl | bash) ─────────────
ask() {
  local _var="$1" _q="$2" _default="${3:-}"
  if [[ -n "$_default" ]]; then echo -en "${YELLOW}[?]${RESET} $_q [${BOLD}${_default}${RESET}]: "
  else                           echo -en "${YELLOW}[?]${RESET} $_q: "; fi
  local _ans; read -r _ans </dev/tty
  printf -v "$_var" '%s' "${_ans:-$_default}"
}
ask_secret() {
  local _var="$1" _q="$2"
  echo -en "${YELLOW}[?]${RESET} $_q: "
  local _ans; read -rs _ans </dev/tty; echo
  printf -v "$_var" '%s' "$_ans"
}
ask_yn() {
  local _var="$1" _q="$2" _default="${3:-y}"
  local _hint; [[ "$_default" == "y" ]] && _hint="Y/n" || _hint="y/N"
  echo -en "${YELLOW}[?]${RESET} $_q [${_hint}]: "
  local _ans; read -r _ans </dev/tty
  _ans="${_ans:-$_default}"
  [[ "$_ans" =~ ^[Yy]$ ]] && printf -v "$_var" 'y' || printf -v "$_var" 'n'
}
choose() {
  # choose VARNAME "prompt" option1 option2 ...
  local _var="$1" _q="$2"; shift 2
  local _opts=("$@") _i=1
  echo -e "${YELLOW}[?]${RESET} $_q"
  for _o in "${_opts[@]}"; do printf "    %d) %s\n" $_i "$_o"; ((_i++)); done
  local _ans; read -r _ans </dev/tty
  printf -v "$_var" '%s' "${_opts[$((_ans-1))]}"
}

# ── OS Detection ──────────────────────────────────────────────────────────────
detect_os() {
  [[ -f /etc/os-release ]] || die "Cannot detect OS — /etc/os-release missing"
  # shellcheck source=/dev/null
  source /etc/os-release
  OS_ID="${ID,,}"; OS_VER="${VERSION_ID%%.*}"; PRETTY="${PRETTY_NAME:-$ID}"
  case "$OS_ID" in
    ubuntu|debian|raspbian)             OS_FAMILY="debian" ;;
    rhel|centos|almalinux|rocky|fedora|ol) OS_FAMILY="rhel" ;;
    *) die "Unsupported OS: $OS_ID. Supported: Ubuntu, Debian, RHEL, AlmaLinux, Rocky, CentOS Stream, Fedora" ;;
  esac
  log "OS: $PRETTY (family: $OS_FAMILY)"
}

require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root:  sudo bash install.sh"
}

# ── Package helpers ───────────────────────────────────────────────────────────
pkg_update() {
  info "Updating package cache..."
  case "$OS_FAMILY" in
    debian) apt-get update -qq >>"$LOG_FILE" 2>&1 ;;
    rhel)   dnf makecache -q   >>"$LOG_FILE" 2>&1 || yum makecache -q >>"$LOG_FILE" 2>&1 ;;
  esac
}
pkg_install() {
  info "Installing: $*"
  case "$OS_FAMILY" in
    debian) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >>"$LOG_FILE" 2>&1 ;;
    rhel)   dnf install -y -q "$@" >>"$LOG_FILE" 2>&1 || yum install -y -q "$@" >>"$LOG_FILE" 2>&1 ;;
  esac
}

# ── Docker Install ────────────────────────────────────────────────────────────
install_docker() {
  if command -v docker &>/dev/null; then
    local ver; ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1 || echo 0)
    if [[ "${ver:-0}" -ge "$MIN_DOCKER_MAJOR" ]]; then
      log "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+') already installed"; return 0
    fi
    warn "Docker version too old (need ≥${MIN_DOCKER_MAJOR}), upgrading..."
  fi
  info "Installing Docker Engine..."
  case "$OS_FAMILY" in
    debian)
      pkg_install ca-certificates curl gnupg lsb-release
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${OS_ID} $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
      pkg_update
      pkg_install docker-ce docker-ce-cli containerd.io docker-compose-plugin
      ;;
    rhel)
      pkg_install yum-utils
      local repo_base="https://download.docker.com/linux"
      if [[ "$OS_ID" == "fedora" ]]; then
        dnf config-manager --add-repo "${repo_base}/fedora/docker-ce.repo" >>"$LOG_FILE" 2>&1
      else
        dnf config-manager --add-repo "${repo_base}/centos/docker-ce.repo" >>"$LOG_FILE" 2>&1 \
          || yum-config-manager --add-repo "${repo_base}/centos/docker-ce.repo" >>"$LOG_FILE" 2>&1
      fi
      pkg_install docker-ce docker-ce-cli containerd.io docker-compose-plugin
      ;;
  esac
  systemctl enable --now docker >>"$LOG_FILE" 2>&1
  log "Docker installed: $(docker --version)"
}

install_deps() {
  section "Installing Dependencies"
  pkg_update
  pkg_install curl wget openssl git jq
  modprobe wireguard 2>/dev/null || warn "WireGuard kernel module not loaded (kernel ≥5.6 required)"
  install_docker
}

# ── Secret Generation ─────────────────────────────────────────────────────────
gen_hex64() { printf '%s%s' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" | head -c 64; }
gen_pass()  { openssl rand -base64 32 | tr -dc 'a-zA-Z0-9@#%^&' | head -c 24; }

# ── Interactive Config ────────────────────────────────────────────────────────
gather_config() {
  section "Configuration"
  echo -e "${BOLD}Answer the following questions to configure your VPN stack.${RESET}"
  echo    "Press Enter to accept the default shown in brackets."
  echo

  # Domain
  ask DOMAIN "Base domain (creates vpn., auth., traefik. subdomains)" ""
  while [[ -z "$DOMAIN" ]]; do warn "Domain is required"; ask DOMAIN "Base domain" ""; done

  # Public IP for WireGuard
  local detected_ip
  detected_ip=$(curl -fsSL --connect-timeout 5 https://api.ipify.org 2>/dev/null \
    || curl -fsSL --connect-timeout 5 https://ifconfig.me 2>/dev/null || echo "")
  ask VPN_HOST "Server public IP or hostname (for WireGuard clients)" "$detected_ip"
  while [[ -z "$VPN_HOST" ]]; do warn "VPN host required"; ask VPN_HOST "Server public IP" "$detected_ip"; done

  # Timezone
  local sys_tz
  sys_tz=$(timedatectl show --property=Timezone --value 2>/dev/null \
    || cat /etc/timezone 2>/dev/null || echo "UTC")
  ask TZ "Timezone" "$sys_tz"

  # Admin credentials
  ask ADMIN_USERNAME "Admin username" "admin"
  ask ADMIN_EMAIL    "Admin email"    "admin@${DOMAIN}"
  ask_secret ADMIN_PASSWORD "Admin password (min 12 chars)"
  while [[ ${#ADMIN_PASSWORD} -lt 12 ]]; do
    warn "Password must be at least 12 characters"
    ask_secret ADMIN_PASSWORD "Admin password (min 12 chars)"
  done

  # TOTP
  ask_yn ENABLE_TOTP "Enable TOTP two-factor authentication (strongly recommended)" "y"

  # TLS
  echo
  echo -e "${YELLOW}[?]${RESET} TLS certificate method:"
  echo    "    1) Let's Encrypt  (automatic, requires public domain + open port 80)"
  echo    "    2) Self-signed    (works anywhere, browser shows security warning)"
  local tls_choice; ask tls_choice "Choose" "1"
  if [[ "$tls_choice" == "2" ]]; then
    TLS_METHOD="selfsigned"; ACME_EMAIL=""
  else
    TLS_METHOD="letsencrypt"
    ask ACME_EMAIL "Email for Let's Encrypt" "$ADMIN_EMAIL"
  fi

  # WireGuard
  ask WG_DNS         "WireGuard client DNS"       "1.1.1.1,8.8.8.8"
  ask WG_ALLOWED_IPS "WireGuard allowed IPs"      "0.0.0.0/0"

  # Firewall
  ask_yn SETUP_FIREWALL "Configure firewall rules automatically" "y"

  # Monitoring (optional Prometheus metrics)
  ask_yn ENABLE_METRICS "Enable Prometheus metrics on wg-easy" "n"

  # Summary
  echo
  echo -e "${BOLD}${CYAN}── Summary ────────────────────────────────────────────────────${RESET}"
  printf "  %-28s ${CYAN}%s${RESET}\n" "VPN Panel:"       "https://vpn.${DOMAIN}"
  printf "  %-28s ${CYAN}%s${RESET}\n" "Auth Portal:"     "https://auth.${DOMAIN}"
  printf "  %-28s %s\n"                "WireGuard Host:"  "${VPN_HOST}:51820/UDP"
  printf "  %-28s %s\n"                "Admin User:"      "${ADMIN_USERNAME} (${ADMIN_EMAIL})"
  printf "  %-28s %s\n"                "TOTP:"            "$ENABLE_TOTP"
  printf "  %-28s %s\n"                "TLS:"             "$TLS_METHOD"
  printf "  %-28s %s\n"                "Install Dir:"     "$INSTALL_DIR"
  echo
  ask_yn CONFIRM "Proceed with installation" "y"
  [[ "$CONFIRM" == "y" ]] || die "Aborted by user"
}

# ── Directory Structure ───────────────────────────────────────────────────────
setup_dirs() {
  section "Creating Directory Structure"
  mkdir -p "${INSTALL_DIR}"/{authelia/config,traefik/{config,certs},scripts,backups}
  log "Created ${INSTALL_DIR}/"
}

# ── .env File ─────────────────────────────────────────────────────────────────
generate_env() {
  section "Generating Secrets & .env"
  JWT_SECRET=$(gen_hex64)
  SESSION_SECRET=$(gen_hex64)
  STORAGE_KEY=$(gen_hex64)
  POSTGRES_PASSWORD=$(gen_pass)
  REDIS_PASSWORD=$(gen_pass)

  cat > "${INSTALL_DIR}/.env" <<EOF
# VPN Stack — generated by installer $(date -u +"%Y-%m-%d %H:%M UTC")
# KEEP THIS FILE SECRET. Never commit to git.

# Domain & Networking
DOMAIN=${DOMAIN}
VPN_HOST=${VPN_HOST}
TZ=${TZ}

# WireGuard
WG_DNS=${WG_DNS}
WG_ALLOWED_IPS=${WG_ALLOWED_IPS}

# Authelia Secrets  ── DO NOT CHANGE after first run (corrupts DB)
AUTHELIA_JWT_SECRET=${JWT_SECRET}
AUTHELIA_SESSION_SECRET=${SESSION_SECRET}
AUTHELIA_STORAGE_ENCRYPTION_KEY=${STORAGE_KEY}

# Database
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}

# TLS / ACME
ACME_EMAIL=${ACME_EMAIL:-admin@${DOMAIN}}
EOF
  chmod 600 "${INSTALL_DIR}/.env"
  log ".env generated with random secrets"
}

# ── docker-compose.yml ────────────────────────────────────────────────────────
generate_compose() {
  section "Generating docker-compose.yml"

  # Build up the Traefik ACME lines and wg-easy middleware label
  local acme_lines="" wg_middleware_label=""
  if [[ "$TLS_METHOD" == "letsencrypt" ]]; then
    acme_lines='      - "--certificatesresolvers.letsencrypt.acme.email=${ACME_EMAIL}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/certs/acme.json"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"'
  fi
  if [[ "$ENABLE_TOTP" == "y" ]]; then
    wg_middleware_label='      - "traefik.http.routers.wg-easy.middlewares=authelia@docker"'
  fi
  local metrics_env=""
  if [[ "$ENABLE_METRICS" == "y" ]]; then
    metrics_env='      - METRICS_ENABLED=true
      - METRICS_PORT=51822'
  fi

  # Write compose file — use printf to avoid heredoc variable-expansion issues
  cat > "${INSTALL_DIR}/docker-compose.yml" <<'BASEEOF'
version: "3.9"

networks:
  proxy:
    name: proxy
    driver: bridge
  vpn_internal:
    name: vpn_internal
    driver: bridge
    internal: true

volumes:
  wg_data:
  authelia_db:
  redis_data:

services:

  traefik:
    image: traefik:v3.2
    container_name: traefik
    restart: unless-stopped
    command:
      - "--api.dashboard=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=proxy"
      - "--providers.file.directory=/config"
      - "--providers.file.watch=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.websecure.http.tls=true"
BASEEOF

  # Append ACME lines if Let's Encrypt
  if [[ -n "$acme_lines" ]]; then
    echo "$acme_lines" >> "${INSTALL_DIR}/docker-compose.yml"
  fi

  cat >> "${INSTALL_DIR}/docker-compose.yml" <<'EOF'
      - "--log.level=INFO"
      - "--accesslog=true"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/config:/config:ro
      - ./traefik/certs:/certs
    networks:
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik-dashboard.rule=Host(`traefik.${DOMAIN}`)"
      - "traefik.http.routers.traefik-dashboard.entrypoints=websecure"
      - "traefik.http.routers.traefik-dashboard.service=api@internal"
      - "traefik.http.routers.traefik-dashboard.middlewares=authelia@docker"
      - "traefik.http.middlewares.authelia.forwardauth.address=http://authelia:9091/api/authz/forward-auth"
      - "traefik.http.middlewares.authelia.forwardauth.trustForwardHeader=true"
      - "traefik.http.middlewares.authelia.forwardauth.authResponseHeaders=Remote-User,Remote-Groups,Remote-Name,Remote-Email"

  authelia:
    image: authelia/authelia:4.39
    container_name: authelia
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
    environment:
      - TZ=${TZ:-UTC}
      - AUTHELIA_JWT_SECRET=${AUTHELIA_JWT_SECRET}
      - AUTHELIA_SESSION_SECRET=${AUTHELIA_SESSION_SECRET}
      - AUTHELIA_STORAGE_ENCRYPTION_KEY=${AUTHELIA_STORAGE_ENCRYPTION_KEY}
      - AUTHELIA_STORAGE_POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - ./authelia/config:/config
    networks:
      - proxy
      - vpn_internal
    expose:
      - "9091"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.authelia.rule=Host(`auth.${DOMAIN}`)"
      - "traefik.http.routers.authelia.entrypoints=websecure"
      - "traefik.http.services.authelia.loadbalancer.server.port=9091"

  redis:
    image: redis:7-alpine
    container_name: authelia-redis
    restart: unless-stopped
    command: redis-server --requirepass ${REDIS_PASSWORD} --maxmemory 128mb --maxmemory-policy allkeys-lru
    volumes:
      - redis_data:/data
    networks:
      - vpn_internal
    expose:
      - "6379"

  postgres:
    image: postgres:16-alpine
    container_name: authelia-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_DB=authelia
      - POSTGRES_USER=authelia
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - authelia_db:/var/lib/postgresql/data
    networks:
      - vpn_internal
    expose:
      - "5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U authelia"]
      interval: 10s
      timeout: 5s
      retries: 5

  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:15
    container_name: wg-easy
    restart: unless-stopped
    depends_on:
      - traefik
      - authelia
    environment:
      - LANG=en
      - WG_HOST=${VPN_HOST}
      - WG_PORT=51820
      - PORT=51821
      - WG_DEFAULT_DNS=${WG_DNS:-1.1.1.1}
      - WG_ALLOWED_IPS=${WG_ALLOWED_IPS:-0.0.0.0/0}
      - WG_DEFAULT_ADDRESS=10.8.0.x
      - WG_PERSISTENT_KEEPALIVE=25
      - UI_TRAFFIC_STATS=true
      - UI_CHART_TYPE=1
      - INSECURE=false
EOF

  # Append metrics env vars if enabled
  if [[ -n "$metrics_env" ]]; then
    echo "$metrics_env" >> "${INSTALL_DIR}/docker-compose.yml"
  fi

  cat >> "${INSTALL_DIR}/docker-compose.yml" <<'EOF'
    volumes:
      - wg_data:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1
    networks:
      - proxy
    ports:
      - "51820:51820/udp"
    expose:
      - "51821"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.wg-easy.rule=Host(`vpn.${DOMAIN}`)"
      - "traefik.http.routers.wg-easy.entrypoints=websecure"
EOF

  # Auth middleware (only if TOTP / Authelia protection is enabled)
  if [[ -n "$wg_middleware_label" ]]; then
    echo "$wg_middleware_label" >> "${INSTALL_DIR}/docker-compose.yml"
  fi

  echo '      - "traefik.http.services.wg-easy.loadbalancer.server.port=51821"' \
    >> "${INSTALL_DIR}/docker-compose.yml"

  log "docker-compose.yml generated (TLS: ${TLS_METHOD}, TOTP: ${ENABLE_TOTP})"
}

# ── Authelia configuration.yml ────────────────────────────────────────────────
generate_authelia_config() {
  section "Generating Authelia Configuration"
  local policy; [[ "$ENABLE_TOTP" == "y" ]] && policy="two_factor" || policy="one_factor"

  cat > "${INSTALL_DIR}/authelia/config/configuration.yml" <<EOF
---
server:
  host: 0.0.0.0
  port: 9091

log:
  level: info

totp:
  issuer: ${DOMAIN}
  period: 30
  skew: 1

authentication_backend:
  file:
    path: /config/users_database.yml
    password:
      algorithm: argon2id
      iterations: 3
      memory: 65536
      parallelism: 4

access_control:
  default_policy: deny
  rules:
    - domain: "auth.${DOMAIN}"
      policy: bypass
    - domain:
        - "vpn.${DOMAIN}"
        - "traefik.${DOMAIN}"
      policy: ${policy}

session:
  name: authelia_session
  expiration: 3600
  inactivity: 300
  remember_me: 1M
  cookies:
    - domain: ${DOMAIN}
      authelia_url: https://auth.${DOMAIN}
  redis:
    host: authelia-redis
    port: 6379
    password: ${REDIS_PASSWORD}

regulation:
  max_retries: 5
  find_time: 2m
  ban_time: 10m

storage:
  postgres:
    host: authelia-postgres
    port: 5432
    database: authelia
    username: authelia
    tls:
      skip_verify: true

notifier:
  filesystem:
    filename: /config/notifications.txt
EOF

  log "authelia/config/configuration.yml generated (policy: ${policy})"
}

# ── Password Hash via Authelia container ──────────────────────────────────────
hash_password() {
  info "Hashing admin password with Argon2id..."
  ADMIN_PASS_HASH=$(
    docker run --rm authelia/authelia:4.39 \
      authelia crypto hash generate argon2 --password "$ADMIN_PASSWORD" 2>/dev/null \
      | grep -i 'Digest:' | awk '{print $2}'
  )
  [[ -n "$ADMIN_PASS_HASH" ]] || die "Password hashing failed. Check Docker is working."
  log "Password hash generated"
}

# ── users_database.yml ────────────────────────────────────────────────────────
generate_users_db() {
  section "Creating Admin User"
  hash_password
  cat > "${INSTALL_DIR}/authelia/config/users_database.yml" <<EOF
---
# Authelia user database — hot-reloaded, no restart needed
# Manage users with:  vpnstack add-user <name> <email> <pass> vpn-admins

users:
  ${ADMIN_USERNAME}:
    disabled: false
    displayname: "VPN Admin"
    password: "${ADMIN_PASS_HASH}"
    email: ${ADMIN_EMAIL}
    groups:
      - vpn-admins
EOF
  chmod 600 "${INSTALL_DIR}/authelia/config/users_database.yml"
  log "users_database.yml created for: ${ADMIN_USERNAME}"
}

# ── Traefik TLS config ────────────────────────────────────────────────────────
generate_traefik_config() {
  section "Generating Traefik TLS Config"
  if [[ "$TLS_METHOD" == "selfsigned" ]]; then
    cat > "${INSTALL_DIR}/traefik/config/tls.yml" <<'EOF'
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /certs/cert.pem
        keyFile:  /certs/key.pem
  options:
    default:
      minVersion: VersionTLS12
      cipherSuites:
        - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
        - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
EOF
  else
    cat > "${INSTALL_DIR}/traefik/config/tls.yml" <<'EOF'
tls:
  options:
    default:
      minVersion: VersionTLS12
      cipherSuites:
        - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
        - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
EOF
  fi
  log "traefik/config/tls.yml generated"
}

# ── TLS Certificates ──────────────────────────────────────────────────────────
setup_tls() {
  touch "${INSTALL_DIR}/traefik/certs/acme.json"
  chmod 600 "${INSTALL_DIR}/traefik/certs/acme.json"

  if [[ "$TLS_METHOD" == "selfsigned" ]]; then
    section "Generating Self-Signed Certificate"
    openssl req -x509 -newkey rsa:4096 -nodes \
      -keyout "${INSTALL_DIR}/traefik/certs/key.pem" \
      -out    "${INSTALL_DIR}/traefik/certs/cert.pem" \
      -days 3650 \
      -subj "/CN=*.${DOMAIN}" \
      -addext "subjectAltName=DNS:*.${DOMAIN},DNS:${DOMAIN}" \
      >>"$LOG_FILE" 2>&1
    log "Self-signed wildcard cert created for *.${DOMAIN} (valid 10 years)"
  else
    log "acme.json ready — Let's Encrypt will issue certs on first startup"
  fi
}

# ── manage.sh ─────────────────────────────────────────────────────────────────
generate_manage_sh() {
  section "Generating Management Script"
  cat > "${INSTALL_DIR}/scripts/manage.sh" <<'MGEOF'
#!/usr/bin/env bash
# VPN Stack management CLI
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

usage() {
  cat <<HELP
Usage: vpnstack <command> [args]

Commands:
  up                               Start the stack
  down                             Stop the stack
  restart                          Restart the stack
  status                           Show service health
  logs [service]                   Follow logs
  hash-password <password>         Generate Argon2id hash
  add-user <user> <email> <pass> <group>   Add Authelia user
  totp-reset <username>            Force TOTP re-enrollment
  backup                           Backup all data to ./backups/
  update                           Pull latest images and restart
HELP
}

CMD="${1:-help}"; shift || true
case "$CMD" in
  up)       docker compose up -d; docker compose ps ;;
  down)     docker compose down ;;
  restart)  docker compose down && docker compose up -d ;;
  status)
    docker compose ps
    echo; echo "=== Container Health ==="
    for c in traefik authelia authelia-redis authelia-postgres wg-easy; do
      s=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || echo "not found")
      printf "  %-25s %s\n" "$c:" "$s"
    done ;;
  logs)     docker compose logs -f --tail=100 "${1:-}" ;;
  hash-password)
    [[ -z "${1:-}" ]] && { echo "Usage: vpnstack hash-password '<password>'"; exit 1; }
    docker run --rm authelia/authelia:4.39 \
      authelia crypto hash generate argon2 --password "$1" 2>/dev/null ;;
  add-user)
    [[ $# -lt 4 ]] && { echo "Usage: vpnstack add-user <user> <email> <pass> <group>"; exit 1; }
    user="$1"; email="$2"; pass="$3"; group="$4"
    hash=$(docker run --rm authelia/authelia:4.39 \
      authelia crypto hash generate argon2 --password "$pass" 2>/dev/null \
      | grep -i 'Digest:' | awk '{print $2}')
    cat >> authelia/config/users_database.yml <<UEOF
  ${user}:
    disabled: false
    displayname: "${user}"
    password: "${hash}"
    email: ${email}
    groups:
      - ${group}
UEOF
    echo "User '${user}' added (hot-reloaded — no restart needed)" ;;
  totp-reset)
    [[ -z "${1:-}" ]] && { echo "Usage: vpnstack totp-reset <username>"; exit 1; }
    docker exec authelia-postgres psql -U authelia -d authelia \
      -c "DELETE FROM totp_configurations WHERE username = '$1';"
    echo "TOTP cleared for '$1' — they must re-enroll on next login" ;;
  backup)
    ts=$(date +%Y%m%d_%H%M%S); dest="./backups/${ts}"; mkdir -p "$dest"
    docker exec authelia-postgres pg_dump -U authelia authelia \
      | gzip > "${dest}/authelia_db.sql.gz"
    cp -r authelia/config "${dest}/authelia_config"
    docker run --rm -v wg_data:/data -v "$(pwd)/${dest}":/backup \
      alpine tar czf /backup/wireguard.tar.gz -C /data .
    cp .env "${dest}/.env.bak"
    echo "Backup saved to: ${dest}"; ls -lh "${dest}/" ;;
  update)
    docker compose pull && docker compose up -d
    echo "Stack updated." ;;
  *) usage ;;
esac
MGEOF

  chmod +x "${INSTALL_DIR}/scripts/manage.sh"
  ln -sf "${INSTALL_DIR}/scripts/manage.sh" /usr/local/bin/vpnstack 2>/dev/null || true
  log "manage.sh installed → run as: vpnstack <command>"
}

# ── Firewall ──────────────────────────────────────────────────────────────────
setup_firewall() {
  [[ "$SETUP_FIREWALL" == "y" ]] || return 0
  section "Configuring Firewall"
  if command -v ufw &>/dev/null; then
    ufw --force enable                              >>"$LOG_FILE" 2>&1 || true
    ufw allow 22/tcp    comment "SSH"               >>"$LOG_FILE" 2>&1
    ufw allow 80/tcp    comment "HTTP (Traefik)"    >>"$LOG_FILE" 2>&1
    ufw allow 443/tcp   comment "HTTPS (Traefik)"   >>"$LOG_FILE" 2>&1
    ufw allow 51820/udp comment "WireGuard"         >>"$LOG_FILE" 2>&1
    ufw deny  51821/tcp comment "wg-easy UI (internal)" >>"$LOG_FILE" 2>&1 || true
    ufw deny  9091/tcp  comment "Authelia (internal)"   >>"$LOG_FILE" 2>&1 || true
    ufw reload                                      >>"$LOG_FILE" 2>&1 || true
    log "UFW rules applied"
  elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-service=ssh    >>"$LOG_FILE" 2>&1
    firewall-cmd --permanent --add-service=http   >>"$LOG_FILE" 2>&1
    firewall-cmd --permanent --add-service=https  >>"$LOG_FILE" 2>&1
    firewall-cmd --permanent --add-port=51820/udp >>"$LOG_FILE" 2>&1
    firewall-cmd --reload                         >>"$LOG_FILE" 2>&1
    log "firewalld rules applied"
  else
    warn "No firewall found — open ports 80/tcp, 443/tcp, 51820/udp manually"
  fi
}

# ── Start Stack ───────────────────────────────────────────────────────────────
start_stack() {
  section "Starting VPN Stack"
  cd "${INSTALL_DIR}"
  info "Pulling Docker images (this may take a few minutes)..."
  docker compose pull >>"$LOG_FILE" 2>&1
  docker compose up -d >>"$LOG_FILE" 2>&1
  log "All containers started"
}

# ── Health Check ──────────────────────────────────────────────────────────────
health_check() {
  section "Waiting for Services"
  local elapsed=0 interval=5 timeout=120
  while [[ $elapsed -lt $timeout ]]; do
    local pg_health
    pg_health=$(docker inspect --format='{{.State.Health.Status}}' authelia-postgres 2>/dev/null || echo "unknown")
    if [[ "$pg_health" == "healthy" ]]; then
      log "Services healthy (${elapsed}s elapsed)"
      return 0
    fi
    sleep "$interval"; elapsed=$((elapsed + interval))
    info "Waiting... ${elapsed}/${timeout}s (postgres: ${pg_health})"
  done
  warn "Timed out — services may still be starting. Check: vpnstack status"
  docker compose -f "${INSTALL_DIR}/docker-compose.yml" ps
}

# ── Final Summary ─────────────────────────────────────────────────────────────
print_summary() {
  echo
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗"
  echo    "║           VPN Stack Installation Complete!                  ║"
  echo -e "╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo
  echo -e "${BOLD}Access URLs:${RESET}"
  printf "  %-30s ${CYAN}%s${RESET}\n" "VPN Admin Panel:"   "https://vpn.${DOMAIN}"
  printf "  %-30s ${CYAN}%s${RESET}\n" "Auth Portal:"       "https://auth.${DOMAIN}"
  printf "  %-30s ${CYAN}%s${RESET}\n" "Traefik Dashboard:" "https://traefik.${DOMAIN}"
  echo
  echo -e "${BOLD}Required DNS Records (→ ${VPN_HOST}):${RESET}"
  printf "  A  vpn.%-20s  →  %s\n"     "${DOMAIN}" "$VPN_HOST"
  printf "  A  auth.%-19s  →  %s\n"    "${DOMAIN}" "$VPN_HOST"
  printf "  A  traefik.%-16s  →  %s\n" "${DOMAIN}" "$VPN_HOST"
  echo
  echo -e "${BOLD}First Login:${RESET}"
  echo    "  1. Create the DNS records above"
  echo    "  2. Open https://vpn.${DOMAIN}"
  echo    "  3. Log in: ${ADMIN_USERNAME} / <your password>"
  if [[ "$ENABLE_TOTP" == "y" ]]; then
  echo    "  4. Scan the TOTP QR code with Google Authenticator"
  echo    "  5. Enter the 6-digit code — you're in!"
  fi
  echo
  echo -e "${BOLD}Common Commands:${RESET}"
  echo    "  vpnstack status"
  echo    "  vpnstack logs [service]"
  echo    "  vpnstack add-user john john@co.com 'Pass123!' vpn-admins"
  echo    "  vpnstack backup"
  echo    "  vpnstack totp-reset john"
  echo
  if [[ "$TLS_METHOD" == "selfsigned" ]]; then
  echo -e "${YELLOW}Note:${RESET} Browser will show a TLS warning — accept the self-signed cert."
  echo    "      For production, re-run and choose Let's Encrypt."
  echo
  fi
  echo    "  Install dir: ${INSTALL_DIR}"
  echo    "  Full log:    ${LOG_FILE}"
  echo
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "VPN Stack Installer ${SCRIPT_VERSION} — $(date -u)" > "$LOG_FILE"

  echo -e "${BOLD}${CYAN}"
  echo " ██╗   ██╗██████╗ ███╗   ██╗    ███████╗████████╗ █████╗  ██████╗██╗  ██╗"
  echo " ██║   ██║██╔══██╗████╗  ██║    ██╔════╝╚══██╔══╝██╔══██╗██╔════╝██║ ██╔╝"
  echo " ██║   ██║██████╔╝██╔██╗ ██║    ███████╗   ██║   ███████║██║     █████╔╝ "
  echo " ╚██╗ ██╔╝██╔═══╝ ██║╚██╗██║    ╚════██║   ██║   ██╔══██║██║     ██╔═██╗ "
  echo "  ╚████╔╝ ██║     ██║ ╚████║    ███████║   ██║   ██║  ██║╚██████╗██║  ██╗"
  echo "   ╚═══╝  ╚═╝     ╚═╝  ╚═══╝    ╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝"
  echo -e "${RESET}"
  echo "  WireGuard + Authelia TOTP + Traefik | v${SCRIPT_VERSION}"
  echo "  Log: ${LOG_FILE}"
  echo

  require_root
  detect_os
  install_deps
  gather_config
  setup_dirs
  generate_env
  generate_compose
  generate_authelia_config
  generate_users_db
  generate_traefik_config
  setup_tls
  generate_manage_sh
  setup_firewall
  start_stack
  health_check
  print_summary
}

main "$@"
