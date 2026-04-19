#!/bin/bash
set -euo pipefail

INCLUDE_HF_CACHE="${1:-}"

TARGET_ENV="/srv/.env"

if [ ! -f "$TARGET_ENV" ]; then
  echo "❌ No existe $TARGET_ENV"
  echo "   Ejecutá primero ~/deploy.sh"
  exit 1
fi

set -a
source "$TARGET_ENV"
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

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
HOSTNAME_SHORT="$(hostname -s)"
BACKUP_NAME="${COMPOSE_PROJECT_NAME:-stack}-backup-${HOSTNAME_SHORT}-${TIMESTAMP}"
STAGING_DIR="$(mktemp -d)"
BACKUP_ROOT="${STAGING_DIR}/${BACKUP_NAME}"
ARCHIVE_PATH="${BACKUPS_DIR}/${BACKUP_NAME}.tar.gz"

mkdir -p "$BACKUP_ROOT"
mkdir -p "$BACKUPS_DIR"

compose_cmd() {
  docker compose \
    --env-file "$TARGET_ENV" \
    -f "$COMPOSE_CPU_FILE" \
    -f "$COMPOSE_GPU_FILE" \
    "$@"
}

copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [ -e "$src" ]; then
    cp -a "$src" "$dst"
  fi
}

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

echo "📋 Copiando archivos base..."
cp "$TARGET_ENV" "$BACKUP_ROOT/.env"
cp "$COMPOSE_CPU_FILE" "$BACKUP_ROOT/docker-compose.cpu.yml"
cp "$COMPOSE_GPU_FILE" "$BACKUP_ROOT/docker-compose.gpu.yml"

echo "📝 Guardando metadata..."
cat > "$BACKUP_ROOT/metadata.txt" <<EOF
backup_name=${BACKUP_NAME}
created_at=$(date -Is)
hostname=$(hostname -f 2>/dev/null || hostname)
base_dir=${BASE_DIR}
compose_project_name=${COMPOSE_PROJECT_NAME:-}
include_hf_cache=${INCLUDE_HF_CACHE:-false}
EOF

echo "💾 Exportando PostgreSQL..."
if ! compose_cmd ps --status running db >/dev/null 2>&1; then
  echo "❌ El servicio db no está corriendo"
  echo "   Levantá el stack antes de ejecutar el backup"
  exit 1
fi

compose_cmd exec -T db pg_dumpall -U "${POSTGRES_USER}" > "$BACKUP_ROOT/postgres_all.sql"

echo "📁 Copiando directorios del proyecto..."
copy_if_exists "$ODOO_DIR" "$BACKUP_ROOT/odoo"
copy_if_exists "$NGINX_DIR" "$BACKUP_ROOT/nginx"
copy_if_exists "$ONLYOFFICE_DIR" "$BACKUP_ROOT/onlyoffice"
copy_if_exists "$OPENCLAW_DIR" "$BACKUP_ROOT/openclaw"
copy_if_exists "$VLLM_DIR" "$BACKUP_ROOT/vllm"
copy_if_exists "$LLAMACPP_DIR" "$BACKUP_ROOT/llamacpp"

if [ "${INCLUDE_HF_CACHE:-}" = "--with-hf-cache" ]; then
  echo "📦 Incluyendo Hugging Face cache..."
  copy_if_exists "$HF_CACHE_DIR" "$BACKUP_ROOT/huggingface"
else
  echo "ℹ️ Hugging Face cache no incluido (usá --with-hf-cache si lo necesitás)"
fi

echo "🗜️ Generando archivo ${ARCHIVE_PATH} ..."
tar -czf "$ARCHIVE_PATH" -C "$STAGING_DIR" "$BACKUP_NAME"

echo "✅ Backup finalizado"
echo "📦 Archivo: $ARCHIVE_PATH"