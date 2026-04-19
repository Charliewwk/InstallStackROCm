#!/bin/bash
set -euo pipefail

MODE="${1:-}"
CONFIRM_NUKE="${2:-}"

CURRENT_USER="${USER:-$(id -un)}"
TARGET_ENV="/srv/.env"
SOURCE_ENV="/home/${CURRENT_USER}/.env.stack"
ACTIVE_ENV=""

if [ -f "$TARGET_ENV" ]; then
  ACTIVE_ENV="$TARGET_ENV"
elif [ -f "$SOURCE_ENV" ]; then
  ACTIVE_ENV="$SOURCE_ENV"
fi

if [ -n "$ACTIVE_ENV" ]; then
  set -a
  source "$ACTIVE_ENV"
  set +a
fi

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
  local args=()
  if [ -n "$ACTIVE_ENV" ] && [ -f "$ACTIVE_ENV" ]; then
    args+=(--env-file "$ACTIVE_ENV")
  fi
  args+=(-f "$COMPOSE_CPU_FILE" -f "$COMPOSE_GPU_FILE")
  docker compose "${args[@]}" "$@"
}

usage() {
  cat <<EOF
Uso:
  $0 --soft
  $0 --deep
  $0 --nuke --yes-host-docker

Modos:
  --soft  : baja contenedores del proyecto y remove-orphans. No borra datos.
  --deep  : baja el stack y borra /srv del proyecto, EXCEPTO backups.
  --nuke  : destruye también /var/lib/docker y /var/lib/containerd del host.
            Requiere confirmación explícita: --yes-host-docker
EOF
}

soft_cleanup() {
  if [ -f "$COMPOSE_CPU_FILE" ] || [ -f "$COMPOSE_GPU_FILE" ]; then
    cd "$BASE_DIR" 2>/dev/null || true
    compose_cmd down --remove-orphans 2>/dev/null || true
  fi
}

deep_cleanup() {
  soft_cleanup

  sudo rm -rf \
    "$ODOO_DIR" \
    "$NGINX_DIR" \
    "$POSTGRES_DIR" \
    "$ONLYOFFICE_DIR" \
    "$OPENCLAW_DIR" \
    "$VLLM_DIR" \
    "$LLAMACPP_DIR" \
    "$HF_CACHE_DIR"

  sudo rm -f "$COMPOSE_CPU_FILE" "$COMPOSE_GPU_FILE" "$TARGET_ENV"
}

nuke_cleanup() {
  if [ "$CONFIRM_NUKE" != "--yes-host-docker" ]; then
    echo "❌ --nuke requiere confirmación explícita"
    echo "   Uso: $0 --nuke --yes-host-docker"
    exit 1
  fi

  deep_cleanup

  sudo systemctl stop docker || true
  sudo systemctl stop containerd || true

  sudo rm -rf /var/lib/docker /var/lib/containerd /run/docker /run/containerd

  sudo systemctl start containerd || true
  sudo systemctl start docker || true
}

if [[ -z "$MODE" ]]; then
  usage
  exit 1
fi

case "$MODE" in
  --soft)
    soft_cleanup
    ;;
  --deep)
    deep_cleanup
    ;;
  --nuke)
    nuke_cleanup
    ;;
  *)
    usage
    exit 1
    ;;
esac

echo "✅ Limpieza finalizada"
echo "ℹ️ Backups preservados en: $BACKUPS_DIR"