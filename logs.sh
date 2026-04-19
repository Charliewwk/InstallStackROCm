#!/bin/bash
set -euo pipefail

CURRENT_USER="${USER:-$(id -un)}"
TARGET_ENV="/srv/.env"
SOURCE_ENV="/home/${CURRENT_USER}/.env.stack"
ACTIVE_ENV=""

if [ -f "$TARGET_ENV" ]; then
  ACTIVE_ENV="$TARGET_ENV"
elif [ -f "$SOURCE_ENV" ]; then
  ACTIVE_ENV="$SOURCE_ENV"
else
  echo "❌ No existe /srv/.env ni ${SOURCE_ENV}"
  exit 1
fi

set -a
source "$ACTIVE_ENV"
set +a

BASE_DIR="${BASE_DIR:-/srv}"
COMPOSE_CPU_FILE="${COMPOSE_CPU_FILE:-$BASE_DIR/docker-compose.cpu.yml}"
COMPOSE_GPU_FILE="${COMPOSE_GPU_FILE:-$BASE_DIR/docker-compose.gpu.yml}"
TAIL_LINES="${TAIL_LINES:-200}"

compose_cmd() {
  local args=()
  if [ -f "$ACTIVE_ENV" ]; then
    args+=(--env-file "$ACTIVE_ENV")
  fi
  args+=(-f "$COMPOSE_CPU_FILE" -f "$COMPOSE_GPU_FILE")
  docker compose "${args[@]}" "$@"
}

cd "$BASE_DIR"

if [ $# -eq 0 ]; then
  compose_cmd logs -f --tail="$TAIL_LINES"
else
  compose_cmd logs -f --tail="$TAIL_LINES" "$@"
fi