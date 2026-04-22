#!/bin/bash
set -euo pipefail

if [ "${EUID}" -eq 0 ]; then
  echo "❌ Ejecutá este script con tu usuario normal, no con sudo"
  exit 1
fi

CURRENT_USER="${USER}"
DEFAULT_SOURCE_ENV="/home/${CURRENT_USER}/.env.stack"
DEFAULT_TARGET_ENV="/srv/.env"

SOURCE_ENV="${SOURCE_ENV:-$DEFAULT_SOURCE_ENV}"
TARGET_ENV="${TARGET_ENV:-$DEFAULT_TARGET_ENV}"

if [ ! -f "$SOURCE_ENV" ]; then
  echo "❌ No existe $SOURCE_ENV"
  exit 1
fi

set -a
source "$SOURCE_ENV"
set +a

USER_NAME="${LINUX_USER:-$CURRENT_USER}"
GROUP_NAME="${LINUX_GROUP:-$USER_NAME}"
HOME_DIR="${HOME_DIR:-/home/$USER_NAME}"

BASE_DIR="${BASE_DIR:-/srv}"
ODOO_DIR="${ODOO_DIR:-$BASE_DIR/odoo}"
NGINX_DIR="${NGINX_DIR:-$BASE_DIR/nginx}"
POSTGRES_DIR="${POSTGRES_DIR:-$BASE_DIR/postgres}"
ONLYOFFICE_DIR="${ONLYOFFICE_DIR:-$BASE_DIR/onlyoffice}"
OPENCLAW_DIR="${OPENCLAW_DIR:-$BASE_DIR/openclaw}"
VLLM_DIR="${VLLM_DIR:-$BASE_DIR/vllm}"
LLAMACPP_DIR="${LLAMACPP_DIR:-$BASE_DIR/llamacpp}"
HF_CACHE_DIR="${HF_CACHE_DIR:-$BASE_DIR/huggingface}"
BACKUPS_DIR="${BACKUPS_DIR:-$BASE_DIR/backups}"

COMPOSE_CPU_FILE="${COMPOSE_CPU_FILE:-$BASE_DIR/docker-compose.cpu.yml}"
COMPOSE_GPU_FILE="${COMPOSE_GPU_FILE:-$BASE_DIR/docker-compose.gpu.yml}"

TELEGRAM_ENABLED="${TELEGRAM_ENABLED:-true}"
TELEGRAM_DM_POLICY="${TELEGRAM_DM_POLICY:-pairing}"
TELEGRAM_GROUP_POLICY="${TELEGRAM_GROUP_POLICY:-allowlist}"
LLAMACPP_AUTOSTART="${LLAMACPP_AUTOSTART:-false}"

GPU_EXPECTED_ROCM_REGEX="${GPU_EXPECTED_ROCM_REGEX:-AMD Radeon|gfx}"
GPU_EXPECTED_CLINFO_REGEX="${GPU_EXPECTED_CLINFO_REGEX:-AMD Radeon|gfx}"
GPU_EXPECTED_VULKAN_REGEX="${GPU_EXPECTED_VULKAN_REGEX:-AMD Radeon|RADV|gfx}"

quote_env_value() {
  local value="$1"

  if [[ "$value" =~ ^[A-Za-z0-9._:/@%+=,-]+$ ]]; then
    printf '%s' "$value"
  else
    printf "'%s'" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
  fi
}

set_env_var() {
  local file="$1"
  local key="$2"
  local value="$3"
  local rendered_value
  local escaped_value

  rendered_value="$(quote_env_value "$value")"
  escaped_value="$(printf '%s' "$rendered_value" | sed -e 's/[&|]/\\&/g')"

  if grep -q "^${key}=" "$file"; then
    sudo sed -i "s|^${key}=.*|${key}=${escaped_value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$rendered_value" | sudo tee -a "$file" >/dev/null
  fi
}

detect_gpu_group_ids() {
  HOST_VIDEO_GID="$(getent group video | cut -d: -f3 || true)"
  HOST_RENDER_GID="$(getent group render | cut -d: -f3 || true)"

  if [ -z "${HOST_VIDEO_GID}" ] || [ -z "${HOST_RENDER_GID}" ]; then
    echo "❌ No se pudieron resolver los GID de video/render en el host"
    echo "   Verificá la instalación AMD/ROCm y los grupos del sistema"
    exit 1
  fi
}

get_ubuntu_point_release() {
  local point=""
  point="$(
    printf '%s\n%s\n' \
      "$(grep '^VERSION=' /etc/os-release | cut -d= -f2- | tr -d '"')" \
      "$(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"')" \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
    | head -n1 \
    || true
  )"
  printf '%s' "$point"
}

get_glibc_version() {
  getconf GNU_LIBC_VERSION | awk '{print $2}'
}

validate_rocm_platform() {
  source /etc/os-release

  local current_point_release
  local current_kernel
  local current_glibc

  current_point_release="$(get_ubuntu_point_release)"
  current_kernel="$(uname -r)"
  current_glibc="$(get_glibc_version)"

  if [ "${ID}" != "ubuntu" ] || [ "${VERSION_ID}" != "${ROCM_REQUIRED_UBUNTU_SERIES}" ] || [ "${VERSION_CODENAME}" != "${ROCM_UBUNTU_CODENAME}" ]; then
    echo "❌ Este stack GPU requiere Ubuntu ${ROCM_REQUIRED_UBUNTU_POINT} (${ROCM_UBUNTU_CODENAME})"
    echo "   Sistema detectado: ${PRETTY_NAME}"
    exit 1
  fi

  if [ -z "$current_point_release" ] || [ "$current_point_release" != "$ROCM_REQUIRED_UBUNTU_POINT" ]; then
    echo "❌ Este stack GPU requiere Ubuntu ${ROCM_REQUIRED_UBUNTU_POINT}"
    echo "   Release detectada: ${current_point_release:-desconocida}"
    exit 1
  fi

  case "$current_kernel" in
    ${ROCM_REQUIRED_KERNEL_GA_PREFIX}*|${ROCM_REQUIRED_KERNEL_HWE_PREFIX}*)
      ;;
    *)
      echo "❌ Kernel no soportado por ROCm para este stack"
      echo "   Kernel actual: $current_kernel"
      echo "   Permitidos: ${ROCM_REQUIRED_KERNEL_GA_PREFIX}* o ${ROCM_REQUIRED_KERNEL_HWE_PREFIX}*"
      exit 1
      ;;
  esac

  if [ "$current_glibc" != "$ROCM_REQUIRED_GLIBC" ]; then
    echo "❌ glibc no soportada por ROCm para este stack"
    echo "   glibc actual: $current_glibc"
    echo "   glibc requerida: $ROCM_REQUIRED_GLIBC"
    exit 1
  fi
}

sudo mkdir -p "$BASE_DIR"
sudo cp "$SOURCE_ENV" "$TARGET_ENV"
sudo chown "$USER_NAME:$GROUP_NAME" "$TARGET_ENV"
sudo chmod 600 "$TARGET_ENV"
sudo sed -i 's/\r$//' "$TARGET_ENV"

detect_gpu_group_ids

GPU_VIDEO_GID="$HOST_VIDEO_GID"
GPU_RENDER_GID="$HOST_RENDER_GID"

set_env_var "$TARGET_ENV" GPU_VIDEO_GID "$GPU_VIDEO_GID"
set_env_var "$TARGET_ENV" GPU_RENDER_GID "$GPU_RENDER_GID"
set_env_var "$TARGET_ENV" TELEGRAM_ENABLED "$TELEGRAM_ENABLED"
set_env_var "$TARGET_ENV" TELEGRAM_DM_POLICY "$TELEGRAM_DM_POLICY"
set_env_var "$TARGET_ENV" TELEGRAM_GROUP_POLICY "$TELEGRAM_GROUP_POLICY"
set_env_var "$TARGET_ENV" LLAMACPP_AUTOSTART "$LLAMACPP_AUTOSTART"
set_env_var "$TARGET_ENV" GPU_EXPECTED_ROCM_REGEX "$GPU_EXPECTED_ROCM_REGEX"
set_env_var "$TARGET_ENV" GPU_EXPECTED_CLINFO_REGEX "$GPU_EXPECTED_CLINFO_REGEX"
set_env_var "$TARGET_ENV" GPU_EXPECTED_VULKAN_REGEX "$GPU_EXPECTED_VULKAN_REGEX"

set -a
source "$TARGET_ENV"
set +a

FALLBACKS_JSON="[]"
if [ -n "${OPENCLAW_FALLBACK_MODEL:-}" ]; then
  FALLBACKS_JSON="[\"${OPENCLAW_FALLBACK_MODEL}\"]"
fi

validate_rocm_platform

echo "🕒 Configurando zona horaria: $TZ"
sudo timedatectl set-timezone "$TZ"

echo "📦 Removiendo paquetes Docker conflictivos"
sudo apt-get update
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y "$pkg" 2>/dev/null || true
done

echo "📦 Instalando Docker y utilitarios base"
sudo install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
| sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update
sudo apt-get install -y \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
  git curl wget unzip build-essential jq \
  python3 python3-pip python3-venv python3-jwt \
  ca-certificates gnupg lsb-release \
  tesseract-ocr poppler-utils ffmpeg \
  pciutils vulkan-tools

echo "🐳 Habilitando Docker"
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker "$USER_NAME" || true

echo "🔎 Verificando Docker"
sudo docker version
sudo docker compose version

echo "📁 Creando estructura persistente"
sudo mkdir -p "$ODOO_DIR/config" "$ODOO_DIR/extra-addons" "$ODOO_DIR/logs" "$ODOO_DIR/odoo-data"
sudo mkdir -p "$NGINX_DIR/ssl" "$NGINX_DIR/logs"
sudo mkdir -p "$POSTGRES_DIR/postgresql-data"
sudo mkdir -p "$ONLYOFFICE_DIR/data" "$ONLYOFFICE_DIR/logs" "$ONLYOFFICE_DIR/lib" "$ONLYOFFICE_DIR/db" "$ONLYOFFICE_DIR/fonts"
sudo mkdir -p "$OPENCLAW_DIR/config" "$OPENCLAW_DIR/data" "$OPENCLAW_DIR/logs" "$OPENCLAW_DIR/workspace"
sudo mkdir -p "$VLLM_DIR"
sudo mkdir -p "$LLAMACPP_DIR/cache"
sudo mkdir -p "$HF_CACHE_DIR"
sudo mkdir -p "$BACKUPS_DIR"

echo "📋 Generando docker-compose.cpu.yml"
sudo tee "$COMPOSE_CPU_FILE" > /dev/null <<'CPUEOF'
services:
  db:
    image: postgres:15
    container_name: postgres15
    command:
      - postgres
      - -c
      - timezone=${TZ}
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      TZ: ${TZ}
    volumes:
      - ${POSTGRES_DIR}/postgresql-data:/var/lib/postgresql/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    restart: always
    networks:
      - cpu_backend_net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5

  odoo:
    build:
      context: ${ODOO_DIR}
      dockerfile: Dockerfile
    image: odoo:19.0-custom
    container_name: odoo
    depends_on:
      db:
        condition: service_healthy
    environment:
      HOST: ${ODOO_DB_HOST}
      USER: ${ODOO_DB_USER}
      PASSWORD: ${ODOO_DB_PASSWORD}
      TZ: ${TZ}
    volumes:
      - ${ODOO_DIR}/extra-addons:/mnt/extra-addons
      - ${ODOO_DIR}/config/odoo.conf:/etc/odoo/odoo.conf:ro
      - ${ODOO_DIR}/logs:/var/log/odoo
      - ${ODOO_DIR}/odoo-data:/var/lib/odoo
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    restart: always
    networks:
      - cpu_backend_net

  onlyoffice:
    image: onlyoffice/documentserver:latest
    container_name: onlyoffice_docs
    environment:
      TZ: ${TZ}
      JWT_ENABLED: "${ONLYOFFICE_JWT_ENABLED}"
      JWT_SECRET: ${ONLYOFFICE_JWT_SECRET}
      JWT_HEADER: ${ONLYOFFICE_JWT_HEADER}
      USE_UNAUTHORIZED_STORAGE: "${ONLYOFFICE_USE_UNAUTHORIZED_STORAGE}"
    volumes:
      - ${ONLYOFFICE_DIR}/data:/var/www/onlyoffice/Data
      - ${ONLYOFFICE_DIR}/logs:/var/log/onlyoffice
      - ${ONLYOFFICE_DIR}/lib:/var/lib/onlyoffice
      - ${ONLYOFFICE_DIR}/db:/var/lib/postgresql
      - ${ONLYOFFICE_DIR}/fonts:/usr/share/fonts/truetype/custom
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    restart: always
    networks:
      - cpu_backend_net

  openclaw:
    image: ${OPENCLAW_IMAGE}
    container_name: openclaw
    environment:
      HOME: /home/node
      TERM: xterm-256color
      TZ: ${TZ}
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN}
      TELEGRAM_BOT_TOKEN: ${TELEGRAM_BOT_TOKEN}
    volumes:
      - ${OPENCLAW_DIR}/config:/home/node/.openclaw
      - ${OPENCLAW_DIR}/workspace:/home/node/.openclaw/workspace
      - ${OPENCLAW_DIR}/data:/srv/openclaw/data
      - ${OPENCLAW_DIR}/logs:/srv/openclaw/logs
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    command:
      [
        "node",
        "dist/index.js",
        "gateway",
        "--bind",
        "${OPENCLAW_BIND}",
        "--port",
        "${OPENCLAW_PORT}"
      ]
    init: true
    restart: unless-stopped
    ports:
      - "127.0.0.1:${OPENCLAW_PORT}:${OPENCLAW_PORT}"
    networks:
      - cpu_backend_net
      - gpu_backend_net

  nginx:
    image: nginx:latest
    container_name: nginx_proxy
    depends_on:
      - odoo
      - onlyoffice
      - openclaw
    environment:
      TZ: ${TZ}
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ${NGINX_DIR}/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ${NGINX_DIR}/ssl:/etc/nginx/ssl:ro
      - ${NGINX_DIR}/logs:/var/log/nginx
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    restart: always
    networks:
      cpu_backend_net:
        aliases:
          - ${ODOO_HOST}
          - ${DOCS_HOST}
          - ${CLAW_HOST}

networks:
  cpu_backend_net:
    name: ${COMPOSE_PROJECT_NAME}_cpu_backend_net
    driver: bridge
  gpu_backend_net:
    name: ${COMPOSE_PROJECT_NAME}_gpu_backend_net
    driver: bridge
CPUEOF

echo "📋 Generando docker-compose.gpu.yml"
sudo tee "$COMPOSE_GPU_FILE" > /dev/null <<'GPUEOF'
services:
  vllm:
    image: ${VLLM_IMAGE}
    container_name: vllm
    environment:
      TZ: ${TZ}
      HF_TOKEN: ${HF_TOKEN}
    ports:
      - "127.0.0.1:${VLLM_PORT}:8000"
    ipc: host
    cap_add:
      - SYS_PTRACE
    security_opt:
      - seccomp=unconfined
    devices:
      - /dev/kfd:/dev/kfd
      - /dev/dri:/dev/dri
    group_add:
      - "${GPU_VIDEO_GID}"
      - "${GPU_RENDER_GID}"
    volumes:
      - ${HF_CACHE_DIR}:/root/.cache/huggingface
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    command:
      [
        "--model",
        "${VLLM_MODEL}",
        "--served-model-name",
        "${VLLM_MODEL_ALIAS}",
        "--host",
        "0.0.0.0",
        "--port",
        "8000",
        "--api-key",
        "${VLLM_API_KEY}",
        "--max-model-len",
        "${VLLM_MAX_MODEL_LEN}",
        "--max-num-seqs",
        "${VLLM_MAX_NUM_SEQS}",
        "--gpu-memory-utilization",
        "${VLLM_GPU_MEMORY_UTILIZATION}",
        "--dtype",
        "half",
        "--trust-remote-code",
        "--enable-auto-tool-choice",
        "--tool-call-parser",
        "${VLLM_TOOL_CALL_PARSER}"
      ]
    restart: unless-stopped
    networks:
      - gpu_backend_net

  llamacpp:
    image: ${LLAMACPP_IMAGE}
    container_name: llamacpp
    environment:
      TZ: ${TZ}
      HF_TOKEN: ${HF_TOKEN}
      LLAMA_API_KEY: ${LLAMACPP_API_KEY}
    ports:
      - "127.0.0.1:${LLAMACPP_PORT}:8080"
    devices:
      - /dev/dri:/dev/dri
    group_add:
      - "${GPU_VIDEO_GID}"
      - "${GPU_RENDER_GID}"
    security_opt:
      - seccomp=unconfined
    volumes:
      - ${LLAMACPP_DIR}:/models
      - ${LLAMACPP_DIR}/cache:/root/.cache
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    command:
      [
        "--hf-repo",
        "${LLAMACPP_HF_REPO}",
        "--host",
        "0.0.0.0",
        "--port",
        "8080",
        "--ctx-size",
        "${LLAMACPP_CTX_SIZE}",
        "--n-gpu-layers",
        "${LLAMACPP_N_GPU_LAYERS}",
        "--threads",
        "${LLAMACPP_THREADS}",
        "--parallel",
        "${LLAMACPP_PARALLEL}",
        "--api-key",
        "${LLAMACPP_API_KEY}",
        "--alias",
        "${LLAMACPP_MODEL_ALIAS}"
      ]
    restart: unless-stopped
    networks:
      - gpu_backend_net

networks:
  gpu_backend_net:
    name: ${COMPOSE_PROJECT_NAME}_gpu_backend_net
    driver: bridge
GPUEOF

echo "📋 Generando odoo.conf"
sudo tee "$ODOO_DIR/config/odoo.conf" > /dev/null <<ODOOEOF
[options]
admin_passwd = ${ODOO_ADMIN_PASSWORD}

db_host = ${ODOO_DB_HOST}
db_port = ${ODOO_DB_PORT}
db_user = ${ODOO_DB_USER}
db_password = ${ODOO_DB_PASSWORD}

addons_path = /usr/lib/python3/dist-packages/odoo/addons,/mnt/extra-addons
data_dir = /var/lib/odoo

log_level = info
proxy_mode = True
gevent_port = 8072
http_interface = 0.0.0.0
dbfilter = ${ODOO_DBFILTER}

workers = ${ODOO_WORKERS}
max_cron_threads = ${ODOO_MAX_CRON_THREADS}
limit_memory_hard = ${ODOO_LIMIT_MEMORY_HARD}
limit_memory_soft = ${ODOO_LIMIT_MEMORY_SOFT}
limit_request = ${ODOO_LIMIT_REQUEST}
limit_time_cpu = ${ODOO_LIMIT_TIME_CPU}
limit_time_real = ${ODOO_LIMIT_TIME_REAL}
ODOOEOF

echo "📋 Generando openssl-san.cnf"
sudo tee "$NGINX_DIR/ssl/openssl-san.cnf" > /dev/null <<SSLEOF
[req]
default_bits = 4096
prompt = no
default_md = sha256
x509_extensions = v3_req
distinguished_name = dn

[dn]
C = ${SSL_COUNTRY}
ST = ${SSL_STATE}
L = ${SSL_CITY}
O = ${SSL_ORG}
OU = ${SSL_UNIT}
CN = ${SSL_COMMON_NAME}

[v3_req]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${ODOO_HOST}
DNS.2 = ${DOCS_HOST}
DNS.3 = ${CLAW_HOST}
SSLEOF

echo "🔐 Generando certificado autofirmado"
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$NGINX_DIR/ssl/odoo.key" \
  -out "$NGINX_DIR/ssl/odoo.crt" \
  -config "$NGINX_DIR/ssl/openssl-san.cnf"

echo "📋 Copiando CA local al contexto de build de Odoo"
sudo cp "$NGINX_DIR/ssl/odoo.crt" "$ODOO_DIR/odoo-local-ca.crt"

echo "📋 Generando Dockerfile de Odoo"
sudo tee "$ODOO_DIR/Dockerfile" > /dev/null <<'DOCKEREOF'
FROM odoo:19.0

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3-jwt ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY odoo-local-ca.crt /usr/local/share/ca-certificates/odoo-local-ca.crt
RUN update-ca-certificates

USER odoo
DOCKEREOF

echo "📋 Generando nginx.conf"
sudo tee "$NGINX_DIR/nginx.conf" > /dev/null <<NGINXEOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

upstream odoo_backend {
    server odoo:8069;
}

upstream odoo_chat {
    server odoo:8072;
}

upstream onlyoffice_docs {
    server onlyoffice:80;
}

upstream openclaw_ui {
    server openclaw:${OPENCLAW_PORT};
}

server {
    listen 80;
    listen [::]:80;
    server_name ${ODOO_HOST};
    return 301 https://\$host\$request_uri;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${DOCS_HOST};
    return 301 https://\$host\$request_uri;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${CLAW_HOST};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${ODOO_HOST};

    ssl_certificate     /etc/nginx/ssl/odoo.crt;
    ssl_certificate_key /etc/nginx/ssl/odoo.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;

    access_log /var/log/nginx/odoo.access.log;
    error_log  /var/log/nginx/odoo.error.log warn;

    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    location /websocket {
        proxy_pass http://odoo_chat;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port 443;
    }

    location / {
        proxy_pass http://odoo_backend;
        proxy_http_version 1.1;
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port 443;
    }

    gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
    gzip on;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${DOCS_HOST};

    ssl_certificate     /etc/nginx/ssl/odoo.crt;
    ssl_certificate_key /etc/nginx/ssl/odoo.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;

    access_log /var/log/nginx/onlyoffice.access.log;
    error_log  /var/log/nginx/onlyoffice.error.log warn;

    client_max_body_size 100M;

    proxy_read_timeout 3600s;
    proxy_connect_timeout 3600s;
    proxy_send_timeout 3600s;

    location ^~ /onlyoffice/file/ {
        proxy_pass http://odoo_backend;
        proxy_http_version 1.1;
        proxy_redirect off;
        proxy_set_header Host ${ODOO_HOST};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port 443;
    }

    location / {
        proxy_pass http://onlyoffice_docs;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${CLAW_HOST};

    ssl_certificate     /etc/nginx/ssl/odoo.crt;
    ssl_certificate_key /etc/nginx/ssl/odoo.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;

    access_log /var/log/nginx/openclaw.access.log;
    error_log  /var/log/nginx/openclaw.error.log warn;

    proxy_read_timeout 3600s;
    proxy_connect_timeout 3600s;
    proxy_send_timeout 3600s;

    location / {
        proxy_pass http://openclaw_ui;
        proxy_http_version 1.1;
        proxy_redirect off;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port 443;
    }
}
NGINXEOF

echo "📋 Generando openclaw.json"
sudo tee "$OPENCLAW_DIR/config/openclaw.json" > /dev/null <<OPENCLAWEOF
{
  "gateway": {
    "mode": "local",
    "bind": "${OPENCLAW_BIND}",
    "controlUi": {
      "allowedOrigins": [
        "http://127.0.0.1:${OPENCLAW_PORT}",
        "http://localhost:${OPENCLAW_PORT}",
        "https://${CLAW_HOST}"
      ]
    }
  },
  "channels": {
    "telegram": {
      "enabled": ${TELEGRAM_ENABLED},
      "dmPolicy": "${TELEGRAM_DM_POLICY}",
      "groupPolicy": "${TELEGRAM_GROUP_POLICY}"
    }
  },
  "agents": {
    "defaults": {
      "workspace": "/home/node/.openclaw/workspace",
      "model": {
        "primary": "${OPENCLAW_DEFAULT_MODEL}",
        "fallbacks": ${FALLBACKS_JSON}
      }
    }
  },
  "models": {
    "providers": {
      "vllm": {
        "apiKey": "${VLLM_API_KEY}",
        "baseUrl": "http://vllm:8000/v1",
        "api": "openai-completions",
        "models": [
          {
            "id": "${VLLM_MODEL_ALIAS}",
            "name": "${VLLM_MODEL}",
            "input": ["text"],
            "cost": {
              "input": 0,
              "output": 0,
              "cacheRead": 0,
              "cacheWrite": 0
            },
            "contextWindow": ${VLLM_MAX_MODEL_LEN},
            "maxTokens": ${VLLM_MAX_TOKENS}
          }
        ]
      },
      "llamacpp": {
        "apiKey": "${LLAMACPP_API_KEY}",
        "baseUrl": "http://llamacpp:8080/v1",
        "api": "openai-completions",
        "models": [
          {
            "id": "${LLAMACPP_MODEL_ALIAS}",
            "name": "${LLAMACPP_HF_REPO}",
            "input": ["text"],
            "cost": {
              "input": 0,
              "output": 0,
              "cacheRead": 0,
              "cacheWrite": 0
            },
            "contextWindow": ${LLAMACPP_CTX_SIZE},
            "maxTokens": ${LLAMACPP_MAX_TOKENS}
          }
        ]
      }
    }
  }
}
OPENCLAWEOF

echo "👤 Aplicando ownership"
sudo chown -R "$USER_NAME:$GROUP_NAME" "$BASE_DIR"
sudo chown -R 999:999 "$POSTGRES_DIR/postgresql-data"
sudo chown -R 101:101 "$ODOO_DIR/odoo-data"

echo "🔒 Aplicando permisos"
sudo chmod -R 755 "$BASE_DIR"

sudo chmod -R 775 "$ODOO_DIR/extra-addons"
sudo chmod -R 775 "$ODOO_DIR/logs"
sudo chmod -R 775 "$ODOO_DIR/odoo-data"
sudo chmod 644 "$ODOO_DIR/config/odoo.conf"
sudo chmod 644 "$ODOO_DIR/Dockerfile"
sudo chmod 644 "$ODOO_DIR/odoo-local-ca.crt"

sudo chmod -R 775 "$NGINX_DIR/logs"
sudo chmod -R 755 "$NGINX_DIR/ssl"
sudo chmod 644 "$NGINX_DIR/nginx.conf"
sudo chmod 644 "$NGINX_DIR/ssl/odoo.crt"
sudo chmod 600 "$NGINX_DIR/ssl/odoo.key"
sudo chmod 644 "$NGINX_DIR/ssl/openssl-san.cnf"

sudo chmod -R 700 "$POSTGRES_DIR/postgresql-data"

sudo chmod -R 775 "$ONLYOFFICE_DIR/data"
sudo chmod -R 775 "$ONLYOFFICE_DIR/logs"
sudo chmod -R 775 "$ONLYOFFICE_DIR/lib"
sudo chmod -R 775 "$ONLYOFFICE_DIR/db"
sudo chmod -R 775 "$ONLYOFFICE_DIR/fonts"

sudo chmod -R 775 "$OPENCLAW_DIR/config"
sudo chmod -R 775 "$OPENCLAW_DIR/data"
sudo chmod -R 775 "$OPENCLAW_DIR/logs"
sudo chmod -R 775 "$OPENCLAW_DIR/workspace"

sudo chmod -R 775 "$VLLM_DIR"
sudo chmod -R 775 "$LLAMACPP_DIR"
sudo chmod -R 775 "$HF_CACHE_DIR"

sudo chmod -R 775 "$BACKUPS_DIR"
find "$BACKUPS_DIR" -type f -exec chmod 644 {} \; 2>/dev/null || true

sudo chmod 644 "$COMPOSE_CPU_FILE"
sudo chmod 644 "$COMPOSE_GPU_FILE"
sudo chmod 600 "$TARGET_ENV"

echo "✅ Deploy listo"
echo "ℹ️ GID detectados dinámicamente:"
echo "   video:  ${GPU_VIDEO_GID}"
echo "   render: ${GPU_RENDER_GID}"
echo "ℹ️ Archivos compose:"
echo "   CPU: $COMPOSE_CPU_FILE"
echo "   GPU: $COMPOSE_GPU_FILE"
echo "ℹ️ ROCm/AMDGPU no se instala desde este deploy"
echo "ℹ️ Para Ubuntu 24.04 usar el script aparte: ~/install_rocm_amd_ubuntu2404.sh"
echo "ℹ️ No levanta el stack. Ejecutá: ~/up.sh"
echo "ℹ️ Agregá a /etc/hosts en cada cliente:"
echo "   <IP_DE_TU_SERVIDOR> ${ODOO_HOST} ${DOCS_HOST} ${CLAW_HOST}"
echo "ℹ️ Si recién agregaste el usuario al grupo docker, cerrá sesión y volvé a entrar."
