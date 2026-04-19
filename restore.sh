#!/bin/bash
set -euo pipefail

ARCHIVE="${1:-}"

if [ -z "$ARCHIVE" ]; then
  echo "Uso: $0 /ruta/al/backup.tar.gz"
  exit 1
fi

if [ ! -f "$ARCHIVE" ]; then
  echo "❌ No existe $ARCHIVE"
  exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

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

echo "📦 Extrayendo backup..."
tar -xzf "$ARCHIVE" -C "$TMPDIR"

BACKUP_ROOT="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [ -z "$BACKUP_ROOT" ]; then
  echo "❌ No se pudo identificar el contenido del backup"
  exit 1
fi

if [ ! -f "$BACKUP_ROOT/.env" ]; then
  echo "❌ El backup no contiene .env"
  exit 1
fi

if [ ! -f "$BACKUP_ROOT/docker-compose.cpu.yml" ] || [ ! -f "$BACKUP_ROOT/docker-compose.gpu.yml" ]; then
  echo "❌ El backup no contiene los archivos compose requeridos"
  exit 1
fi

if [ ! -f "$BACKUP_ROOT/postgres_all.sql" ]; then
  echo "❌ El backup no contiene postgres_all.sql"
  exit 1
fi

CURRENT_ENV="/srv/.env"
CURRENT_CPU_COMPOSE="/srv/docker-compose.cpu.yml"
CURRENT_GPU_COMPOSE="/srv/docker-compose.gpu.yml"

if [ -f "$CURRENT_ENV" ] && [ -f "$CURRENT_CPU_COMPOSE" ] && [ -f "$CURRENT_GPU_COMPOSE" ]; then
  echo "🛑 Bajando stack actual si existe..."
  docker compose \
    --env-file "$CURRENT_ENV" \
    -f "$CURRENT_CPU_COMPOSE" \
    -f "$CURRENT_GPU_COMPOSE" \
    down --remove-orphans 2>/dev/null || true
fi

echo "📋 Restaurando /srv/.env..."
sudo mkdir -p /srv
sudo cp "$BACKUP_ROOT/.env" /srv/.env
sudo sed -i 's/\r$//' /srv/.env
sudo chmod 600 /srv/.env

detect_gpu_group_ids
set_env_var /srv/.env GPU_VIDEO_GID "$HOST_VIDEO_GID"
set_env_var /srv/.env GPU_RENDER_GID "$HOST_RENDER_GID"

set -a
source /srv/.env
set +a

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

compose_cmd() {
  docker compose \
    --env-file /srv/.env \
    -f "$COMPOSE_CPU_FILE" \
    -f "$COMPOSE_GPU_FILE" \
    "$@"
}

copy_if_exists() {
  local src="$1"
  local dst="$2"

  if [ -e "$src" ]; then
    sudo cp -a "$src" "$dst"
  fi
}

echo "🧹 Limpiando estructura actual del proyecto..."
sudo rm -rf \
  "$ODOO_DIR" \
  "$NGINX_DIR" \
  "$POSTGRES_DIR" \
  "$ONLYOFFICE_DIR" \
  "$OPENCLAW_DIR" \
  "$VLLM_DIR" \
  "$LLAMACPP_DIR" \
  "$HF_CACHE_DIR"

sudo rm -f "$COMPOSE_CPU_FILE" "$COMPOSE_GPU_FILE"

echo "📁 Restaurando directorios..."
sudo mkdir -p "$BASE_DIR"
copy_if_exists "$BACKUP_ROOT/odoo" "$ODOO_DIR"
copy_if_exists "$BACKUP_ROOT/nginx" "$NGINX_DIR"
copy_if_exists "$BACKUP_ROOT/onlyoffice" "$ONLYOFFICE_DIR"
copy_if_exists "$BACKUP_ROOT/openclaw" "$OPENCLAW_DIR"
copy_if_exists "$BACKUP_ROOT/vllm" "$VLLM_DIR"
copy_if_exists "$BACKUP_ROOT/llamacpp" "$LLAMACPP_DIR"
copy_if_exists "$BACKUP_ROOT/huggingface" "$HF_CACHE_DIR"

sudo cp "$BACKUP_ROOT/docker-compose.cpu.yml" "$COMPOSE_CPU_FILE"
sudo cp "$BACKUP_ROOT/docker-compose.gpu.yml" "$COMPOSE_GPU_FILE"

echo "👤 Restaurando ownership/permisos base..."
sudo chown -R "${LINUX_USER}:${LINUX_GROUP}" "$BASE_DIR"
sudo mkdir -p "$POSTGRES_DIR/postgresql-data"
sudo chown -R 999:999 "$POSTGRES_DIR/postgresql-data"
sudo chmod -R 700 "$POSTGRES_DIR/postgresql-data"
sudo chown -R 101:101 "$ODOO_DIR/odoo-data" 2>/dev/null || true
sudo chmod 600 /srv/.env

echo "🐳 Iniciando solo PostgreSQL..."
compose_cmd up -d db

echo "⏳ Esperando PostgreSQL..."
for i in $(seq 1 60); do
  if compose_cmd exec -T db pg_isready -U "${POSTGRES_USER}" -d postgres >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! compose_cmd exec -T db pg_isready -U "${POSTGRES_USER}" -d postgres >/dev/null 2>&1; then
  echo "❌ PostgreSQL no quedó operativo para la restauración"
  exit 1
fi

echo "💾 Restaurando bases..."
cat "$BACKUP_ROOT/postgres_all.sql" | compose_cmd exec -T db psql -U "${POSTGRES_USER}" -d postgres

echo "🏗️ Reconstruyendo Odoo..."
compose_cmd build odoo

echo "⬆️ Levantando stack completo..."
compose_cmd up -d

echo "✅ Restore completo finalizado"
echo "ℹ️ GID detectados dinámicamente:"
echo "   video:  ${HOST_VIDEO_GID}"
echo "   render: ${HOST_RENDER_GID}"
echo "🌐 URLs:"
echo "   Odoo:       https://${ODOO_HOST}"
echo "   OnlyOffice: https://${DOCS_HOST}"
echo "   OpenClaw:   https://${CLAW_HOST}"