#!/bin/bash
set -euo pipefail

PHASE="${1:-}"
SOURCE_ENV="${HOME}/.env.stack"
TARGET_ENV="/srv/.env"

load_env() {
  if [ -f "$TARGET_ENV" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$TARGET_ENV"
    set +a
  elif [ -f "$SOURCE_ENV" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$SOURCE_ENV"
    set +a
  fi
}

load_env

ROCM_INSTALLER_SERIES="${ROCM_INSTALLER_SERIES:-7.2.2}"
ROCM_INSTALLER_BUILD="${ROCM_INSTALLER_BUILD:-7.2.2.70202-1}"
ROCM_UBUNTU_CODENAME="${ROCM_UBUNTU_CODENAME:-noble}"
ROCM_TARGET_USER="${ROCM_TARGET_USER:-${SUDO_USER:-${USER:-christian}}}"

ROCM_REQUIRED_UBUNTU_SERIES="${ROCM_REQUIRED_UBUNTU_SERIES:-24.04}"
ROCM_REQUIRED_UBUNTU_POINT="${ROCM_REQUIRED_UBUNTU_POINT:-24.04.4}"
ROCM_REQUIRED_KERNEL_GA_PREFIX="${ROCM_REQUIRED_KERNEL_GA_PREFIX:-6.8.}"
ROCM_REQUIRED_KERNEL_HWE_PREFIX="${ROCM_REQUIRED_KERNEL_HWE_PREFIX:-6.17.}"
ROCM_REQUIRED_GLIBC="${ROCM_REQUIRED_GLIBC:-2.39}"

# Ajustables por si AMD cambia estos repos en una release futura
AMDGPU_REPO_FROM="${AMDGPU_REPO_FROM:-30.30.2}"
AMDGPU_REPO_TO="${AMDGPU_REPO_TO:-30.30.1}"
ROCM_GRAPHICS_REPO_FROM="${ROCM_GRAPHICS_REPO_FROM:-7.2.2}"
ROCM_GRAPHICS_REPO_TO="${ROCM_GRAPHICS_REPO_TO:-7.2.1}"

source /etc/os-release

usage() {
  cat <<EOF
Uso:
  $0 phase1      # registra repos AMD e instala driver kernel-space (amdgpu-dkms)
  $0 phase2      # instala ROCm user-space y herramientas, configura grupos/PATH
  $0 status      # verifica estado post-instalación
  $0 uninstall   # desinstala ROCm, driver y repositorios AMD
EOF
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

apt_pkg_installed() {
  local pkg="$1"
  dpkg -s "$pkg" >/dev/null 2>&1
}

safe_purge_if_installed() {
  local pkg="$1"
  if apt_pkg_installed "$pkg"; then
    echo "🧹 Purge de $pkg"
    sudo apt purge -y "$pkg"
  else
    echo "ℹ️ $pkg no está instalado; continúo"
  fi
}

remove_repo_file_if_exists() {
  local file="$1"
  if [ -f "$file" ]; then
    echo "🧹 Eliminando $file"
    sudo rm -f "$file"
  fi
}

validate_rocm_platform() {
  local current_point_release
  local current_kernel
  local current_glibc

  current_point_release="$(get_ubuntu_point_release)"
  current_kernel="$(uname -r)"
  current_glibc="$(get_glibc_version)"

  if [ "${ID}" != "ubuntu" ] || [ "${VERSION_ID}" != "${ROCM_REQUIRED_UBUNTU_SERIES}" ] || [ "${VERSION_CODENAME}" != "${ROCM_UBUNTU_CODENAME}" ]; then
    echo "❌ Esta instalación ROCm fue preparada para Ubuntu ${ROCM_REQUIRED_UBUNTU_POINT} (${ROCM_UBUNTU_CODENAME})"
    echo "   Sistema detectado: ${PRETTY_NAME}"
    exit 1
  fi

  if [ -z "$current_point_release" ] || [ "$current_point_release" != "$ROCM_REQUIRED_UBUNTU_POINT" ]; then
    echo "❌ Esta GPU/stack fue validada contra Ubuntu ${ROCM_REQUIRED_UBUNTU_POINT}"
    echo "   Release detectada: ${current_point_release:-desconocida}"
    exit 1
  fi

  case "$current_kernel" in
    ${ROCM_REQUIRED_KERNEL_GA_PREFIX}*|${ROCM_REQUIRED_KERNEL_HWE_PREFIX}*)
      ;;
    *)
      echo "❌ Kernel no soportado por esta validación ROCm"
      echo "   Kernel actual: $current_kernel"
      echo "   Permitidos: ${ROCM_REQUIRED_KERNEL_GA_PREFIX}* o ${ROCM_REQUIRED_KERNEL_HWE_PREFIX}*"
      exit 1
      ;;
  esac

  if [ "$current_glibc" != "$ROCM_REQUIRED_GLIBC" ]; then
    echo "❌ glibc no soportada por esta validación ROCm"
    echo "   glibc actual: $current_glibc"
    echo "   glibc requerida: $ROCM_REQUIRED_GLIBC"
    exit 1
  fi
}

register_amd_repositories() {
  local tmp_dir
  local amdgpu_deb
  local amdgpu_url
  local deb_path

  tmp_dir="$(mktemp -d)"
  amdgpu_deb="amdgpu-install_${ROCM_INSTALLER_BUILD}_all.deb"
  amdgpu_url="https://repo.radeon.com/amdgpu-install/${ROCM_INSTALLER_SERIES}/ubuntu/${ROCM_UBUNTU_CODENAME}/${amdgpu_deb}"
  deb_path="${tmp_dir}/${amdgpu_deb}"

  echo "🧹 Limpiando instaladores/repositorios AMD previos"
  safe_purge_if_installed amdgpu-install
  sudo apt autoremove -y || true

  echo "🧹 Limpiando caché APT"
  sudo rm -rf /var/cache/apt/*
  sudo apt clean all
  sudo apt update

  echo "⬇️ Descargando instalador de repositorios AMD"
  wget -O "$deb_path" "$amdgpu_url"

  echo "📥 Registrando repositorios AMD"
  sudo apt install -y "$deb_path"

  if [ -f /etc/apt/sources.list.d/amdgpu.list ]; then
    echo "🩹 Ajustando repositorio AMDGPU (${AMDGPU_REPO_FROM} -> ${AMDGPU_REPO_TO})"
    sudo sed -i "s#/${AMDGPU_REPO_FROM}#/${AMDGPU_REPO_TO}#g" /etc/apt/sources.list.d/amdgpu.list
  fi

  if [ -f /etc/apt/sources.list.d/rocm.list ]; then
    echo "🩹 Ajustando repositorio ROCm graphics (${ROCM_GRAPHICS_REPO_FROM} -> ${ROCM_GRAPHICS_REPO_TO})"
    sudo sed -i "s#graphics/${ROCM_GRAPHICS_REPO_FROM}#graphics/${ROCM_GRAPHICS_REPO_TO}#g" /etc/apt/sources.list.d/rocm.list
  fi

  sudo apt update

  rm -rf "$tmp_dir"
}

install_kernel_driver() {
  echo "🧹 Removiendo driver AMDGPU DKMS previo si existe"
  if apt_pkg_installed amdgpu-dkms; then
    sudo apt autoremove -y amdgpu-dkms || true
  else
    echo "ℹ️ amdgpu-dkms no estaba instalado"
  fi

  echo "🧩 Instalando headers y módulos extra del kernel actual"
  sudo apt install -y "linux-headers-$(uname -r)" "linux-modules-extra-$(uname -r)"

  echo "🎮 Instalando driver kernel-space AMDGPU"
  sudo apt install -y amdgpu-dkms
}

install_rocm_userspace() {
  echo "📦 Instalando prerrequisitos ROCm/Vulkan"
  sudo apt install -y python3-setuptools python3-wheel clinfo vulkan-tools

  echo "👤 Agregando ${ROCM_TARGET_USER} a los grupos render y video"
  sudo usermod -a -G render,video "$ROCM_TARGET_USER"

  echo "🧠 Instalando ROCm (meta-paquete)"
  sudo apt install -y rocm

  echo "🔗 Configurando shared objects de ROCm en el linker"
  sudo tee /etc/ld.so.conf.d/rocm.conf >/dev/null <<'EOF'
/opt/rocm/lib
/opt/rocm/lib64
EOF
  sudo ldconfig

  echo "🛣️ Configurando PATH de ROCm para futuras sesiones"
  sudo tee /etc/profile.d/rocm.sh >/dev/null <<EOF
export PATH=/opt/rocm/bin:/opt/rocm-${ROCM_INSTALLER_SERIES}/bin:\$PATH
EOF
  sudo chmod 644 /etc/profile.d/rocm.sh
}

phase1() {
  validate_rocm_platform
  register_amd_repositories
  install_kernel_driver

  echo "✅ Phase 1 finalizada"
  echo "⚠️ Reiniciá el host antes de seguir"
  echo "   Luego ejecutá: $0 phase2"
}

phase2() {
  validate_rocm_platform
  install_rocm_userspace

  echo "✅ Phase 2 finalizada"
  echo "⚠️ Reiniciá nuevamente el host o, como mínimo, cerrá sesión y volvé a entrar"
  echo "   Luego verificá con: $0 status"
}

status() {
  validate_rocm_platform

  echo "📋 Usuario objetivo: ${ROCM_TARGET_USER}"
  echo

  echo "📋 Release Ubuntu"
  echo "${PRETTY_NAME}"
  echo

  echo "📋 Kernel"
  uname -r
  echo

  echo "📋 glibc"
  getconf GNU_LIBC_VERSION || true
  echo

  echo "📋 Grupos del usuario"
  id "$ROCM_TARGET_USER" || true
  echo

  echo "📋 Repositorios AMD/ROCm"
  ls -l /etc/apt/sources.list.d/amdgpu.list /etc/apt/sources.list.d/rocm.list 2>/dev/null || true
  echo

  echo "📋 Dispositivos GPU"
  ls -l /dev/kfd /dev/dri 2>/dev/null || true
  echo

  echo "📋 Estado DKMS"
  dkms status || true
  echo

  echo "📋 rocminfo"
  if command -v rocminfo >/dev/null 2>&1; then
    rocminfo || true
  else
    echo "ℹ️ rocminfo no está en PATH"
  fi
  echo

  echo "📋 clinfo"
  if command -v clinfo >/dev/null 2>&1; then
    clinfo || true
  else
    echo "ℹ️ clinfo no está instalado"
  fi
  echo

  echo "📋 vulkaninfo (deviceName)"
  if command -v vulkaninfo >/dev/null 2>&1; then
    vulkaninfo 2>/dev/null | grep deviceName || true
  else
    echo "ℹ️ vulkaninfo no está instalado"
  fi
}

uninstall_all() {
  echo "🧹 Desinstalando ROCm meta-paquetes"
  sudo apt autoremove -y rocm || true
  sudo apt autoremove -y rocm-core || true

  echo "🧹 Desinstalando driver kernel-space AMDGPU"
  sudo apt autoremove -y amdgpu-dkms || true

  echo "🧹 Removiendo configuración de linker/PATH"
  sudo rm -f /etc/ld.so.conf.d/rocm.conf
  sudo rm -f /etc/profile.d/rocm.sh
  sudo ldconfig || true

  echo "🧹 Removiendo registrador/repositorios AMD"
  safe_purge_if_installed amdgpu-install
  sudo apt autoremove -y || true

  remove_repo_file_if_exists /etc/apt/sources.list.d/amdgpu.list
  remove_repo_file_if_exists /etc/apt/sources.list.d/rocm.list

  echo "🧹 Limpiando caché APT"
  sudo rm -rf /var/cache/apt/*
  sudo apt clean all
  sudo apt update

  echo "✅ Desinstalación finalizada"
  echo "⚠️ Reiniciá el host"
}

case "$PHASE" in
  phase1)
    phase1
    ;;
  phase2)
    phase2
    ;;
  status)
    status
    ;;
  uninstall)
    uninstall_all
    ;;
  *)
    usage
    exit 1
    ;;
esac