# Deploy automático Odoo + Stack auxiliar (ROCm AMD Saphire Radeon RX 9060 16Gb XT Pulse)

## Descripción

Este repositorio contiene un conjunto de **scripts de aprovisionamiento, despliegue, operación y recuperación** para montar un entorno productivo completo basado en Docker sobre **Ubuntu 24.04.4**, orientado a ejecutar:

- **Odoo 19** (custom build)
- **PostgreSQL 15**
- **Nginx** (reverse proxy + SSL)
- **OnlyOffice Document Server**
- **OpenClaw** (AI gateway) Telegram
- **vLLM** (modelos locales servidos por API)
- **llama.cpp** (modelo local alternativo / fallback)

La arquitectura está preparada para trabajar con GPU AMD bajo **ROCm** y fue validada sobre una **AMD Sapphire Radeon RX 9060 XT Pulse 16 GB**.

## Objetivo

El objetivo del proyecto es dejar un servidor listo para ejecutar un stack integrado de gestión y asistencia AI, con despliegue reproducible y persistencia en `/srv`, minimizando cambios manuales posteriores al primer aprovisionamiento.

## Componentes incluidos

### Aplicación principal
- **Odoo 19** con imagen custom basada en `odoo:19.0`
- Build propio para agregar certificados locales y dependencias auxiliares

### Base de datos
- **PostgreSQL 15**
- Persistencia en volumen dedicado dentro de `/srv/postgres`

### Proxy y publicación
- **Nginx** como reverse proxy
- Hosts separados para Odoo, OnlyOffice y OpenClaw
- Certificado autofirmado generado durante el deploy

### Edición documental
- **OnlyOffice Document Server**

### Gateway AI
- **OpenClaw** como punto de entrada AI / UI / Telegram

### Modelos locales
- **vLLM** como motor principal de inferencia local
- **llama.cpp** como motor alternativo / fallback local

## Modelos configurados

### Modelo principal
- `vllm/qwen2.5-7b-instruct-awq`

### Modelo fallback
- `llamacpp/qwen2.5-7b-instruct-gguf`

## Estructura general en disco

Todos los datos persistentes y archivos generados quedan bajo `/srv`:

```text
/srv
├── .env
├── docker-compose.cpu.yml
├── docker-compose.gpu.yml
├── backups/
├── huggingface/
├── llamacpp/
├── nginx/
├── odoo/
├── onlyoffice/
├── openclaw/
├── postgres/
└── vllm/
```

## Requisitos del host

### Sistema operativo
- Ubuntu **24.04.4**

### GPU
- GPU AMD compatible con ROCm
- Validado con **AMD Radeon RX 9060 XT**

### Validaciones contempladas por scripts
- kernel compatible con ROCm
- glibc compatible
- grupos `render` y `video`
- dispositivos `/dev/kfd` y `/dev/dri/renderD128`
- Docker instalado y operativo

## Variables de uso

La base de variables se define en:
Reemplazar __SET_ME__

```text
/home/<usuario>/.env.stack
```

Durante `deploy.sh`, ese archivo se copia a:

```text
/srv/.env
```

Además, el deploy detecta dinámicamente y agrega a `/srv/.env`:

- `GPU_VIDEO_GID`
- `GPU_RENDER_GID`

### Variables principales
Reemplazar __SET_ME__

#### Sistema
- `TZ`
- `COMPOSE_PROJECT_NAME`
- `LINUX_USER`
- `LINUX_GROUP`
- `HOME_DIR`

#### Paths
- `BASE_DIR`
- `ODOO_DIR`
- `NGINX_DIR`
- `POSTGRES_DIR`
- `ONLYOFFICE_DIR`
- `OPENCLAW_DIR`
- `VLLM_DIR`
- `LLAMACPP_DIR`
- `HF_CACHE_DIR`
- `BACKUPS_DIR`

#### PostgreSQL
- `POSTGRES_DB`
- `POSTGRES_USER`
- `POSTGRES_PASSWORD`

#### Odoo
- `ODOO_ADMIN_PASSWORD`
- `ODOO_DB_HOST`
- `ODOO_DB_PORT`
- `ODOO_DB_USER`
- `ODOO_DB_PASSWORD`
- `ODOO_WORKERS`
- `ODOO_MAX_CRON_THREADS`
- `ODOO_LIMIT_MEMORY_HARD`
- `ODOO_LIMIT_MEMORY_SOFT`
- `ODOO_LIMIT_REQUEST`
- `ODOO_LIMIT_TIME_CPU`
- `ODOO_LIMIT_TIME_REAL`
- `ODOO_DBFILTER`

#### Dominios / Nginx / SSL
- `ODOO_HOST`
- `DOCS_HOST`
- `CLAW_HOST`
- `SSL_COUNTRY`
- `SSL_STATE`
- `SSL_CITY`
- `SSL_ORG`
- `SSL_UNIT`
- `SSL_COMMON_NAME`

#### OnlyOffice
- `ONLYOFFICE_JWT_ENABLED`
- `ONLYOFFICE_JWT_SECRET`
- `ONLYOFFICE_JWT_HEADER`
- `ONLYOFFICE_USE_UNAUTHORIZED_STORAGE`

#### OpenClaw / Telegram
- `OPENCLAW_IMAGE`
- `OPENCLAW_GATEWAY_TOKEN`
- `OPENCLAW_BIND`
- `OPENCLAW_PORT`
- `TELEGRAM_ENABLED`
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_DM_POLICY`
- `TELEGRAM_GROUP_POLICY`
- `OPENCLAW_DEFAULT_MODEL`
- `OPENCLAW_FALLBACK_MODEL`

#### vLLM
- `VLLM_IMAGE`
- `VLLM_PORT`
- `VLLM_API_KEY`
- `VLLM_MODEL`
- `VLLM_MODEL_ALIAS`
- `VLLM_MAX_MODEL_LEN`
- `VLLM_MAX_TOKENS`
- `VLLM_MAX_NUM_SEQS`
- `VLLM_GPU_MEMORY_UTILIZATION`
- `VLLM_TOOL_CALL_PARSER`

#### llama.cpp
- `LLAMACPP_AUTOSTART`
- `LLAMACPP_IMAGE`
- `LLAMACPP_PORT`
- `LLAMACPP_API_KEY`
- `LLAMACPP_MODEL_ALIAS`
- `LLAMACPP_HF_REPO`
- `LLAMACPP_CTX_SIZE`
- `LLAMACPP_MAX_TOKENS`
- `LLAMACPP_N_GPU_LAYERS`
- `LLAMACPP_THREADS`
- `LLAMACPP_PARALLEL`

#### Hugging Face
- `HF_TOKEN`

#### Validación GPU
- `GPU_EXPECTED_ROCM_REGEX`
- `GPU_EXPECTED_CLINFO_REGEX`
- `GPU_EXPECTED_VULKAN_REGEX`

## Scripts incluidos

### `install_rocm_amd_ubuntu2404.sh`
Instala ROCm usando el flujo actual (Abril 2026) recomendado por AMD para Ubuntu 24.04:

- registra repositorios AMD
- instala `amdgpu-dkms`
- instala ROCm user-space
- configura linker y PATH
- verifica kernel, glibc y release

#### Uso
Reemplazar __SET_ME__

```bash
~/install_rocm_amd_ubuntu2404.sh phase1
sudo reboot
~/install_rocm_amd_ubuntu2404.sh phase2
sudo reboot
~/install_rocm_amd_ubuntu2404.sh status
```

### `deploy.sh`
Script de aprovisionamiento y generación de configuración.

#### Qué hace
- copia `~/.env.stack` a `/srv/.env`
- detecta `GPU_VIDEO_GID` y `GPU_RENDER_GID`
- instala Docker y utilitarios base
- crea la estructura persistente en `/srv`
- genera:
  - `docker-compose.cpu.yml`
  - `docker-compose.gpu.yml`
  - `odoo.conf`
  - `nginx.conf`
  - `openclaw.json`
  - `Dockerfile` custom de Odoo
- genera certificado autofirmado
- aplica ownership y permisos

#### Uso
Reemplazar __SET_ME__

```bash
~/deploy.sh
```

### `up.sh`
Script de validación y arranque del stack.

#### Qué hace
- usa `/srv/.env` ya desplegado
- refresca `GPU_VIDEO_GID` y `GPU_RENDER_GID`
- valida ROCm, Docker, GPU y librerías
- construye imagen custom de Odoo
- levanta `vllm`
- opcionalmente levanta `llamacpp` si `LLAMACPP_AUTOSTART=true`
- levanta plano CPU:
  - `db`
  - `odoo`
  - `onlyoffice`
  - `openclaw`
  - `nginx`

#### Uso

```bash
~/up.sh
```

### `down.sh`
Baja el stack sin borrar datos persistentes.

#### Uso

```bash
~/down.sh
```

### `logs.sh`
Muestra logs del stack completo o de un servicio puntual.

#### Uso

```bash
~/logs.sh
~/logs.sh openclaw
~/logs.sh vllm
~/logs.sh nginx
```

### `clean.sh`
Limpieza controlada del stack.

#### Modos
- `--soft`: baja contenedores y remove-orphans, sin borrar datos
- `--deep`: borra estructura del proyecto en `/srv` excepto backups
- `--nuke --yes-host-docker`: destruye también datos Docker del host

#### Uso

```bash
~/clean.sh --soft
~/clean.sh --deep
~/clean.sh --nuke --yes-host-docker
```

### `backup.sh`
Genera un backup consistente del stack.

#### Qué guarda
- `/srv/.env`
- `docker-compose.cpu.yml`
- `docker-compose.gpu.yml`
- `postgres_all.sql`
- directorios del proyecto:
  - `odoo`
  - `nginx`
  - `onlyoffice`
  - `openclaw`
  - `vllm`
  - `llamacpp`
- opcionalmente cache Hugging Face

#### Uso

```bash
~/backup.sh
~/backup.sh --with-hf-cache
```

### `restore.sh`
Restaura un backup generado por `backup.sh`.

#### Qué hace
- extrae el archivo
- restaura `/srv/.env`
- reinyecta GIDs de GPU del host actual
- restaura estructura del proyecto
- levanta PostgreSQL
- restaura `postgres_all.sql`
- reconstruye Odoo
- levanta el stack completo

#### Uso

```bash
~/restore.sh /ruta/al/backup.tar.gz
```

## Servicios incluidos

### Plano CPU
- `db`
- `odoo`
- `onlyoffice`
- `openclaw`
- `nginx`

### Plano GPU
- `vllm`
- `llamacpp`

## Hosts requeridos

Los clientes que acceden al stack deben resolver estos hosts:

- `odoo.lan`
- `docs.odoo.lan`
- `claw.odoo.lan`

Ejemplo en `/etc/hosts` del cliente:

```text
192.168.x.x  odoo.lan docs.odoo.lan claw.odoo.lan
```

## Flujo recomendado de instalación

### 1. Preparar variables base
Crear y ajustar:

```text
/home/<usuario>/.env.stack
```

### 2. Instalar ROCm

```bash
~/install_rocm_amd_ubuntu2404.sh phase1
sudo reboot
~/install_rocm_amd_ubuntu2404.sh phase2
sudo reboot
~/install_rocm_amd_ubuntu2404.sh status
```

### 3. Aprovisionar el entorno

```bash
~/deploy.sh
```

### 4. Levantar el stack

```bash
~/up.sh
```

### 5. Verificar servicios

```bash
~/logs.sh
```

## URLs publicadas

Una vez levantado el stack:

- **Odoo:** `https://odoo.lan`
- **OnlyOffice:** `https://docs.odoo.lan`
- **OpenClaw:** `https://claw.odoo.lan`
- **vLLM API:** `http://127.0.0.1:${VLLM_PORT}/v1`
- **llama.cpp API:** `http://127.0.0.1:${LLAMACPP_PORT}/v1` (solo si está activo)

## OpenClaw / Telegram

La configuración generada de OpenClaw contempla Telegram con:

- `enabled: true`
- `dmPolicy: pairing`
- `groupPolicy: allowlist`

Esto significa:

- mensajes directos nuevos requieren aprobación de pairing
- grupos quedan en modo allowlist
- el acceso Telegram puede resetearse limpiando stores de pairing si fuera necesario

## Notas operativas

- `deploy.sh` **no levanta** el stack
- `up.sh` asume que `/srv/.env` y los compose ya existen
- `up.sh` no regenera archivos de configuración
- si `LLAMACPP_AUTOSTART=false`, `up.sh` asegura que `llamacpp` quede detenido
- el stack está pensado para persistencia y restore reproducible

## Estado del proyecto

Este repositorio está orientado a:

- despliegue reproducible en hardware AMD con ROCm
- operación simple sobre Docker Compose
- Odoo + servicios auxiliares + AI local
- posibilidad de reinstalar el stack en otros equipos sin repetir ajustes manuales fuera de los scripts
