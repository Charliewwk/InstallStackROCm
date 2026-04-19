#!/bin/bash
set -euo pipefail

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
COMPOSE_CPU_FILE="${COMPOSE_CPU_FILE:-$BASE_DIR/docker-compose.cpu.yml}"
COMPOSE_GPU_FILE="${COMPOSE_GPU_FILE:-$BASE_DIR/docker-compose.gpu.yml}"

compose_cmd() {
  docker compose \
    --env-file "$TARGET_ENV" \
    -f "$COMPOSE_CPU_FILE" \
    -f "$COMPOSE_GPU_FILE" \
    "$@"
}

cd "$BASE_DIR"
compose_cmd down --remove-orphans
compose_cmd ps || true