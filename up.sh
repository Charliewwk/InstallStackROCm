#!/bin/bash
set -euo pipefail

if [ "${EUID}" -eq 0 ]; then
  echo "❌ Ejecutá este script con tu usuario normal, no con sudo"
  exit 1
fi

CURRENT_USER="${USER}"
TARGET_ENV="/srv/.env"

if [ ! -f "$TARGET_ENV" ]; then
  echo "❌ No existe $TARGET_ENV"
  echo "   Ejecutá primero ~/deploy.sh"
  exit 1
fi

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

resolve_rocm_bin_dir() {
  if [ -x /opt/rocm/bin/rocminfo ]; then
    echo "/opt/rocm/bin"
    return 0
  fi

  local candidate
  candidate="$(find /opt -maxdepth 2 -type f -name rocminfo 2>/dev/null | sort | tail -n 1 || true)"
  if [ -n "$candidate" ]; then
    dirname "$candidate"
    return 0
  fi

  if command -v rocminfo >/dev/null 2>&1; then
    dirname "$(readlink -f "$(command -v rocminfo)")"
    return 0
  fi

  return 1
}

resolve_rocm_lib_path() {
  local parts=()

  [ -d /opt/rocm/lib ] && parts+=("/opt/rocm/lib")
  [ -d /opt/rocm/lib64 ] && parts+=("/opt/rocm/lib64")

  local latest_versioned
  latest_versioned="$(find /opt -maxdepth 1 -type d -name 'rocm-*' 2>/dev/null | sort | tail -n 1 || true)"
  if [ -n "$latest_versioned" ]; then
    [ -d "$latest_versioned/lib" ] && parts+=("$latest_versioned/lib")
    [ -d "$latest_versioned/lib64" ] && parts+=("$latest_versioned/lib64")
  fi

  if [ "${#parts[@]}" -eq 0 ]; then
    return 1
  fi

  local joined=""
  local p
  for p in "${parts[@]}"; do
    if [ -z "$joined" ]; then
      joined="$p"
    else
      joined="${joined}:$p"
    fi
  done

  echo "$joined"
}

run_rocm_cmd() {
  local rocm_bin_dir="$1"
  local rocm_lib_path="$2"
  shift 2

  env -i \
    HOME="$HOME" \
    USER="$USER" \
    LOGNAME="$LOGNAME" \
    SHELL="${SHELL:-/bin/bash}" \
    PATH="${rocm_bin_dir}:/usr/bin:/bin" \
    LD_LIBRARY_PATH="${rocm_lib_path}" \
    "$@"
}

set -a
source "$TARGET_ENV"
set +a

USER_NAME="${LINUX_USER:-$CURRENT_USER}"
GROUP_NAME="${LINUX_GROUP:-$USER_NAME}"

BASE_DIR="${BASE_DIR:-/srv}"
COMPOSE_CPU_FILE="${COMPOSE_CPU_FILE:-$BASE_DIR/docker-compose.cpu.yml}"
COMPOSE_GPU_FILE="${COMPOSE_GPU_FILE:-$BASE_DIR/docker-compose.gpu.yml}"

LLAMACPP_AUTOSTART="${LLAMACPP_AUTOSTART:-false}"
GPU_EXPECTED_ROCM_REGEX="${GPU_EXPECTED_ROCM_REGEX:-AMD Radeon|gfx}"
GPU_EXPECTED_CLINFO_REGEX="${GPU_EXPECTED_CLINFO_REGEX:-AMD Radeon|gfx}"
GPU_EXPECTED_VULKAN_REGEX="${GPU_EXPECTED_VULKAN_REGEX:-AMD Radeon|RADV|gfx}"

compose_cmd() {
  docker compose \
    --env-file "$TARGET_ENV" \
    -f "$COMPOSE_CPU_FILE" \
    -f "$COMPOSE_GPU_FILE" \
    "$@"
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

detect_gpu_group_ids

GPU_VIDEO_GID="$HOST_VIDEO_GID"
GPU_RENDER_GID="$HOST_RENDER_GID"
export GPU_VIDEO_GID GPU_RENDER_GID

set_env_var "$TARGET_ENV" GPU_VIDEO_GID "$GPU_VIDEO_GID"
set_env_var "$TARGET_ENV" GPU_RENDER_GID "$GPU_RENDER_GID"

set -a
source "$TARGET_ENV"
set +a

validate_rocm_platform

if ! systemctl is-active --quiet docker; then
  if systemctl list-unit-files | grep -q '^docker.service'; then
    echo "🐳 Docker no está activo. Iniciándolo..."
    sudo systemctl start docker
  else
    echo "❌ Docker no está instalado en el host"
    echo "   Ejecutá primero: ~/deploy.sh"
    exit 1
  fi
fi

if [ ! -f "$COMPOSE_CPU_FILE" ] || [ ! -f "$COMPOSE_GPU_FILE" ]; then
  echo "❌ No existen los archivos compose esperados"
  echo "   CPU: $COMPOSE_CPU_FILE"
  echo "   GPU: $COMPOSE_GPU_FILE"
  exit 1
fi

CURRENT_GROUPS="$(id -nG)"
if ! echo "$CURRENT_GROUPS" | grep -qw render; then
  echo "❌ La sesión actual no tiene el grupo render"
  echo "   Ejecutá ~/install_rocm_amd_ubuntu2404.sh phase2"
  echo "   Luego cerrá sesión, volvé a entrar y reintentá"
  exit 1
fi

if ! echo "$CURRENT_GROUPS" | grep -qw video; then
  echo "❌ La sesión actual no tiene el grupo video"
  echo "   Ejecutá ~/install_rocm_amd_ubuntu2404.sh phase2"
  echo "   Luego cerrá sesión, volvé a entrar y reintentá"
  exit 1
fi

if [ ! -e /dev/kfd ] || [ ! -e /dev/dri/renderD128 ]; then
  echo "❌ No están disponibles /dev/kfd o /dev/dri/renderD128 en el host"
  echo "   Ejecutá ~/install_rocm_amd_ubuntu2404.sh phase1 y phase2"
  echo "   Reiniciá el host y verificá nuevamente"
  exit 1
fi

if ! ROCM_BIN_DIR="$(resolve_rocm_bin_dir)"; then
  echo "❌ No se pudo localizar rocminfo en el sistema"
  exit 1
fi

if ! ROCM_LIB_PATH="$(resolve_rocm_lib_path)"; then
  echo "❌ No se pudieron localizar las librerías ROCm"
  exit 1
fi

if ! command -v clinfo >/dev/null 2>&1; then
  echo "❌ No se encontró clinfo"
  exit 1
fi

if ! command -v vulkaninfo >/dev/null 2>&1; then
  echo "❌ No se encontró vulkaninfo"
  echo "   Instalá vulkan-tools en el host"
  exit 1
fi

echo "🧪 Validando ROCm con rocminfo..."
if ! run_rocm_cmd "$ROCM_BIN_DIR" "$ROCM_LIB_PATH" "${ROCM_BIN_DIR}/rocminfo" >/tmp/rocminfo.out 2>/tmp/rocminfo.err; then
  echo "❌ rocminfo falló"
  echo "---- stdout ----"
  cat /tmp/rocminfo.out || true
  echo "---- stderr ----"
  cat /tmp/rocminfo.err || true
  exit 1
fi

if ! grep -Eiq "${GPU_EXPECTED_ROCM_REGEX}" /tmp/rocminfo.out; then
  echo "❌ rocminfo no enumeró una GPU compatible con el patrón esperado"
  echo "   Regex: ${GPU_EXPECTED_ROCM_REGEX}"
  cat /tmp/rocminfo.out || true
  exit 1
fi

echo "🧪 Validando OpenCL con clinfo..."
if ! clinfo >/tmp/clinfo.out 2>/tmp/clinfo.err; then
  echo "❌ clinfo falló"
  echo "---- stdout ----"
  cat /tmp/clinfo.out || true
  echo "---- stderr ----"
  cat /tmp/clinfo.err || true
  exit 1
fi

CLINFO_DEVICE_COUNT="$(
  awk -F: '/^Number of devices/ {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
    print $2
    exit
  }' /tmp/clinfo.out
)"

if [ -z "${CLINFO_DEVICE_COUNT}" ] || ! [[ "${CLINFO_DEVICE_COUNT}" =~ ^[0-9]+$ ]] || [ "${CLINFO_DEVICE_COUNT}" -lt 1 ]; then
  echo "❌ clinfo no detectó ningún dispositivo GPU utilizable"
  cat /tmp/clinfo.out || true
  exit 1
fi

if ! grep -Eiq "${GPU_EXPECTED_CLINFO_REGEX}" /tmp/clinfo.out; then
  echo "❌ clinfo no detectó una GPU compatible con el patrón esperado"
  echo "   Regex: ${GPU_EXPECTED_CLINFO_REGEX}"
  cat /tmp/clinfo.out || true
  exit 1
fi

echo "🧪 Validando Vulkan con vulkaninfo..."
VULKAN_RC=0
vulkaninfo >/tmp/vulkaninfo.out 2>/tmp/vulkaninfo.err || VULKAN_RC=$?

if ! grep -Eiq "${GPU_EXPECTED_VULKAN_REGEX}" /tmp/vulkaninfo.out /tmp/vulkaninfo.err; then
  echo "❌ vulkaninfo no detectó una GPU compatible con el patrón esperado"
  echo "   Regex: ${GPU_EXPECTED_VULKAN_REGEX}"
  echo "---- stdout ----"
  cat /tmp/vulkaninfo.out || true
  echo "---- stderr ----"
  cat /tmp/vulkaninfo.err || true
  exit 1
fi

if [ "$VULKAN_RC" -ne 0 ]; then
  echo "⚠️ vulkaninfo devolvió código $VULKAN_RC, pero la GPU compatible fue detectada"
fi

cd "$BASE_DIR"

echo "🧪 Validando compose..."
compose_cmd config >/dev/null

echo "🏗️ Construyendo imagen custom de Odoo..."
compose_cmd build odoo

echo "🎮 Levantando vLLM..."
compose_cmd up -d vllm

echo "⏳ Esperando disponibilidad de vLLM..."
for i in $(seq 1 300); do
  if curl -fsS -H "Authorization: Bearer ${VLLM_API_KEY}" \
    "http://127.0.0.1:${VLLM_PORT}/v1/models" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

if ! curl -fsS -H "Authorization: Bearer ${VLLM_API_KEY}" \
  "http://127.0.0.1:${VLLM_PORT}/v1/models" >/dev/null 2>&1; then
  echo "❌ vLLM no quedó disponible en el puerto ${VLLM_PORT}"
  echo "   Revisá: ~/logs.sh vllm"
  exit 1
fi

if [ "${LLAMACPP_AUTOSTART}" = "true" ]; then
  echo "🧩 Levantando llama.cpp fallback..."
  compose_cmd up -d llamacpp

  echo "⏳ Esperando disponibilidad de llama.cpp..."
  for i in $(seq 1 300); do
    if curl -fsS "http://127.0.0.1:${LLAMACPP_PORT}/health" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done

  if ! curl -fsS "http://127.0.0.1:${LLAMACPP_PORT}/health" >/dev/null 2>&1; then
    echo "❌ llama.cpp no quedó disponible en el puerto ${LLAMACPP_PORT}"
    echo "   Revisá: ~/logs.sh llamacpp"
    echo "   Si el problema es VRAM, bajá VLLM_MAX_MODEL_LEN o VLLM_GPU_MEMORY_UTILIZATION,"
    echo "   o poné LLAMACPP_AUTOSTART=false en /srv/.env y relanzá ~/up.sh"
    exit 1
  fi
else
  echo "🛑 LLAMACPP_AUTOSTART=false, asegurando que llama.cpp quede detenido..."
  compose_cmd stop llamacpp || true
fi

echo "⬆️ Levantando plano CPU..."
compose_cmd up -d db odoo onlyoffice openclaw nginx

echo "📋 Estado de servicios:"
compose_cmd ps

echo ""
echo "🌐 URLs:"
echo "   Odoo:       https://${ODOO_HOST}"
echo "   OnlyOffice: https://${DOCS_HOST}"
echo "   OpenClaw:   https://${CLAW_HOST}"
echo "   vLLM API:   http://127.0.0.1:${VLLM_PORT}/v1"
if [ "${LLAMACPP_AUTOSTART}" = "true" ]; then
  echo "   llama.cpp:  http://127.0.0.1:${LLAMACPP_PORT}/v1"
fi
echo ""
echo "ℹ️ GID detectados dinámicamente:"
echo "   video:  ${GPU_VIDEO_GID}"
echo "   render: ${GPU_RENDER_GID}"
echo "ℹ️ Verificación ROCm:"
echo "   ~/install_rocm_amd_ubuntu2404.sh status"
echo "ℹ️ Logs vLLM:"
echo "   ~/logs.sh vllm"
echo "ℹ️ Logs llama.cpp:"
echo "   ~/logs.sh llamacpp"