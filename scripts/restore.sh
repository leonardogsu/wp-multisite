#!/bin/bash
################################################################################
# restore.sh - Script de restauración para WordPress Multi-Site OPTIMIZADO
# Compatible con estructura basada en dominios sanitizados
# Versión: 3.3 - ACTUALIZADO: Formato simplificado de SFTP en wp-config.php
#
# Uso:
#   ./scripts/restore.sh --site DOMINIO           # Restaura un sitio específico
#   ./scripts/restore.sh --site 2                 # Restaura sitio por índice
#   ./scripts/restore.sh --backup DIR             # Usa un backup específico
#   ./scripts/restore.sh --site DOMINIO --yes     # Sin confirmación
#
#   --- Restauración externa ---
#   ./scripts/restore.sh --external               # Restaurar desde ZIP externo
#       - Lista los ZIPs disponibles en backups/external
#       - Permite elegir un ZIP que contenga un SQL y un TAR
#       - Permite elegir un sitio destino instalado
#       - Sobrescribe la base de datos y los archivos de ese sitio
#
# Changelog v3.3:
#   + ACTUALIZADO: Formato simplificado de SFTP en wp-config.php
#   + FTP_HOST ahora usa SERVER_IP:2222 desde .env
#   + FS_METHOD = 'direct'
#   + Eliminadas líneas FTP_BASE, FTP_CONTENT_DIR, FTP_PLUGIN_DIR
#
# Changelog v3.2:
#   + UNIFICADO: Gestión centralizada de wp-config.php
#   + NEW: update_wpconfig_from_env() actualiza credenciales DB y SFTP desde .env
#   + REMOVED: preserve_wpconfig_credentials() ya no es necesaria
#   + FIX: Comportamiento idéntico en --site y --external
#
# Changelog v3.1:
#   + FIX: Subshells ahora usan set +e para evitar muerte prematura
#   + FIX: Verificación robusta de archivos de status
#   + FIX: Mejor manejo de errores en prepare_files_staging
#   + FIX: Diagnóstico mejorado cuando falla la preparación de archivos
################################################################################

set -euo pipefail

# --- Paths / constantes ---
LOCAL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${LOCAL_SCRIPT_DIR}/.." 2>/dev/null && pwd || pwd)"
ENV_FILE="${PROJECT_DIR}/.env"
BACKUP_ROOT="${PROJECT_DIR}/backups"

# --- Utils ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log(){ echo -e "${GREEN}[$(date +'%F %T')]${NC} $*"; }
info(){ echo -e "${BLUE}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
die(){ echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

################################################################################
# ESTRATEGIA 1: GESTIÓN CENTRALIZADA DE RECURSOS TEMPORALES
################################################################################

# Directorio raíz para todos los archivos temporales
TEMP_ROOT="$(mktemp -d -t wp-restore.XXXXXX)"
declare -a CLEANUP_ITEMS=()

# Función de limpieza centralizada
cleanup_temp_files() {
    local exit_code=$?

    # Limpiar items registrados individualmente
    if [[ ${#CLEANUP_ITEMS[@]} -gt 0 ]]; then
        for item in "${CLEANUP_ITEMS[@]}"; do
            [[ -e "$item" ]] && rm -rf "$item" 2>/dev/null || true
        done
    fi

    # Limpiar directorio raíz temporal
    [[ -d "$TEMP_ROOT" ]] && rm -rf "$TEMP_ROOT" 2>/dev/null || true

    return $exit_code
}

# Registrar trap para limpieza automática
trap cleanup_temp_files EXIT INT TERM

# Función para registrar archivos temporales
register_temp() {
    local temp_name="$1"
    local temp_path="$TEMP_ROOT/$temp_name"
    mkdir -p "$(dirname "$temp_path")"
    CLEANUP_ITEMS+=("$temp_path")
    echo "$temp_path"
}

# Función para crear directorio temporal
register_temp_dir() {
    local dir_name="$1"
    local dir_path="$TEMP_ROOT/$dir_name"
    mkdir -p "$dir_path"
    CLEANUP_ITEMS+=("$dir_path")
    echo "$dir_path"
}

################################################################################
# FUNCIONES ORIGINALES (sin cambios en la lógica)
################################################################################

# --- Función para sanitizar nombres de dominio (optimizada) ---
sanitize_domain_name() {
    echo "$1" | sed -e 's/[.-]/_/g' -e 's/[^a-zA-Z0-9_]//g' | tr '[:upper:]' '[:lower:]'
}

# --- Convierte dominio a formato de variable SFTP del .env ---
# Ejemplo: comandolibertad.com -> COMANDOLIBERTAD_COM
domain_to_sftp_var(){
  local domain="$1"
  echo "$domain" | tr '[:lower:]' '[:upper:]' | sed 's/[.-]/_/g'
}

# --- docker compose shim (con caché) ---
COMPOSE_CMD=""
compose_cmd(){
  if [[ -z "$COMPOSE_CMD" ]]; then
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
      COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
      COMPOSE_CMD="docker-compose"
    fi
  fi
  echo "$COMPOSE_CMD"
}

# --- localizar contenedor MySQL ---
MYSQL_CID=""
detect_mysql_container(){
  local DC; DC="$(compose_cmd)"
  if [[ -n "${MYSQL_CONTAINER:-}" ]]; then
    if docker inspect "${MYSQL_CONTAINER}" &>/dev/null; then
      MYSQL_CID="${MYSQL_CONTAINER}"; return 0
    fi
  fi
  if [[ -n "$DC" ]]; then
    local cid
    cid=$($DC --project-directory "$PROJECT_DIR" ps -q mysql 2>/dev/null || true)
    if [[ -n "$cid" ]]; then MYSQL_CID="$cid"; return 0; fi
  fi
  local guess
  guess="$(docker ps --format '{{.ID}} {{.Names}}' | awk '/mysql/ {print $1; exit}')"
  if [[ -n "$guess" ]]; then MYSQL_CID="${guess}"; return 0; fi
  guess="$(docker ps --filter 'ancestor=mysql' --format '{{.ID}}' | head -n1)"
  if [[ -n "$guess" ]]; then MYSQL_CID="${guess}"; return 0; fi
  return 1
}

wait_for_mysql(){
  info "Verificando MySQL en contenedor ($MYSQL_CID)..."
  local tries=30
  until docker exec "$MYSQL_CID" mysqladmin ping -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent &>/dev/null; do
    ((tries--)) || die "MySQL no respondió a tiempo"
    sleep 2
  done
  log "✓ MySQL está listo"
}

# --- Variables globales ---
declare -a DOMAINS=()
MODE=""
SITE_ARG=""
BACKUP_DIR=""
ASSUME_YES="no"

# --- Procesar argumentos ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site) MODE="one"; SITE_ARG="${2:-}"; [[ -n "${SITE_ARG}" ]] || die "Falta valor para --site"; shift 2 ;;
    --backup) BACKUP_DIR="${2:-}"; [[ -n "${BACKUP_DIR}" ]] || die "Falta ruta para --backup"; shift 2 ;;
    --external) MODE="external"; shift ;;
    --yes|-y) ASSUME_YES="yes"; shift ;;
    -h|--help)
      sed -n '1,18p' "$0"; exit 0 ;;
    *) die "Opción no reconocida: $1 (usa --help para ayuda)" ;;
  esac
done

EXTERNAL_DIR="${BACKUP_ROOT}/external"
EXTERNAL_ZIP=""

[[ -n "$MODE" ]] || die "Debe indicar --site <dominio|índice> o --external"

# --- Cargar entorno / dominios ---
load_env(){
  [[ -f "$ENV_FILE" ]] || die "No existe .env en $PROJECT_DIR"
  set -a; source "$ENV_FILE"; set +a
  : "${MYSQL_ROOT_PASSWORD:?Falta MYSQL_ROOT_PASSWORD en .env}"
  mapfile -t DOMAINS < <(grep -E '^DOMAIN_' "$ENV_FILE" | cut -d'=' -f2 || true)

  if ((${#DOMAINS[@]} == 0)); then
    die "No hay dominios configurados (DOMAIN_*) en .env"
  fi
}

# --- Seleccionar snapshot ---
latest_backup_dir(){
  [[ -d "$BACKUP_ROOT" ]] || die "No existe ${BACKUP_ROOT}"
  local latest
  latest="$(ls -1t "$BACKUP_ROOT" | head -n1 || true)"
  [[ -n "$latest" ]] || die "No hay snapshots en ${BACKUP_ROOT}"
  echo "${BACKUP_ROOT}/${latest}"
}

list_available_backups(){
  echo ""
  info "Backups disponibles:"
  echo ""

  local backups=($(ls -1t "$BACKUP_ROOT" 2>/dev/null || true))

  if [[ ${#backups[@]} -eq 0 ]]; then
    die "No hay backups disponibles"
  fi

  for i in "${!backups[@]}"; do
    local idx=$((i+1))
    local name="${backups[$i]}"
    local size=$(du -sh "${BACKUP_ROOT}/${name}" 2>/dev/null | cut -f1 || echo "?")
    if [[ $i -eq 0 ]]; then
      echo -e "  ${GREEN}${idx}. ${name}${NC} (${size}) ${BLUE}← Más reciente${NC}"
    else
      echo "  ${idx}. ${name} (${size})"
    fi
  done
  echo ""
}

resolve_backup_dir(){
  BACKUP_DIR="${BACKUP_DIR:-}"

  if [[ -z "$BACKUP_DIR" ]]; then
    if [[ "$ASSUME_YES" == "yes" ]]; then
      BACKUP_DIR="$(latest_backup_dir)"
      info "Usando backup más reciente: $(basename "$BACKUP_DIR")"
    else
      list_available_backups
      echo -e "${YELLOW}Selecciona el backup a usar:${NC}"
      read -rp "  Número [1 = más reciente]: " selection
      selection="${selection:-1}"
      local backups=($(ls -1t "$BACKUP_ROOT" 2>/dev/null || true))
      if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#backups[@]} )); then
        BACKUP_DIR="${BACKUP_ROOT}/${backups[$((selection-1))]}"
      else
        warn "Selección inválida, usando el más reciente."
        BACKUP_DIR="$(latest_backup_dir)"
      fi
    fi
  fi

  if [[ ! -d "$BACKUP_DIR" ]]; then
    die "Snapshot no válido: $BACKUP_DIR"
  fi
  if [[ ! -d "$BACKUP_DIR/databases" || ! -d "$BACKUP_DIR/files" ]]; then
    die "Estructura inválida: faltan /databases o /files en $BACKUP_DIR"
  fi

  echo ""
  info "Backup seleccionado: $(basename "$BACKUP_DIR")"
}

# --- Detectar formato ---
detect_backup_format(){
  local db_dir="${BACKUP_DIR}/databases"
  if ls "${db_dir}"/wp_sitio*.sql.gz &>/dev/null; then
    echo "legacy"
  elif ls "${db_dir}"/*.sql.gz &>/dev/null && ! ls "${db_dir}"/wp_sitio*.sql.gz &>/dev/null 2>&1; then
    echo "new"
  else
    echo "unknown"
  fi
}

SITE_INDEX=0; SITE_DOMAIN=""; SITE_SANITIZED=""
resolve_site(){
  local arg="$1"
  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    SITE_INDEX="$arg"
    if (( SITE_INDEX < 1 || SITE_INDEX > ${#DOMAINS[@]} )); then
      die "Índice fuera de rango: $SITE_INDEX"
    fi
    SITE_DOMAIN="${DOMAINS[$((SITE_INDEX-1))]}"
  else
    for i in "${!DOMAINS[@]}"; do
      if [[ "${DOMAINS[$i]}" == "$arg" ]]; then
        SITE_INDEX=$((i+1))
        SITE_DOMAIN="$arg"
        break
      fi
    done
    (( SITE_INDEX == 0 )) && die "Dominio no encontrado: '$arg'"
  fi
  SITE_SANITIZED=$(sanitize_domain_name "$SITE_DOMAIN")
}

human_size(){ du -h "$1" 2>/dev/null | awk '{print $1}'; }

confirm(){
  [[ "$ASSUME_YES" == "yes" ]] && return 0
  read -r -p "¿Continuar? [y/N] " ans
  [[ "${ans:-}" =~ ^[yY]$ ]]
}

show_site_summary(){
  local idx="$1"
  local domain="${DOMAINS[$((idx-1))]}"
  local domain_sanitized=$(sanitize_domain_name "$domain")
  local format=$(detect_backup_format)
  local f_files f_db

  if [[ "$format" == "legacy" ]]; then
    f_files="${BACKUP_DIR}/files/sitio${idx}.tar.gz"
    f_db="${BACKUP_DIR}/databases/wp_sitio${idx}.sql.gz"
  else
    f_files="${BACKUP_DIR}/files/${domain_sanitized}.tar.gz"
    f_db="${BACKUP_DIR}/databases/${domain_sanitized}.sql.gz"
  fi

  echo ""
  echo -e "${BLUE}Resumen de restauración${NC}"
  echo "  Sitio:    #${idx} - ${domain}"
  echo "  Carpeta:  ${domain_sanitized}"
  echo "  Archivos: $(human_size "$f_files" 2>/dev/null || echo 'n/a')"
  echo "  DB:       $(human_size "$f_db" 2>/dev/null || echo 'n/a')"
  echo ""
}

################################################################################
# FUNCIÓN UNIFICADA: Actualizar wp-config.php desde .env
# v3.3: Formato simplificado de SFTP
################################################################################

# Actualiza wp-config.php con credenciales del .env
# Uso: update_wpconfig_from_env <idx> <wpconfig_path>
update_wpconfig_from_env(){
  local idx="$1"
  local wpconfig="$2"

  [[ -f "$wpconfig" ]] || { warn "wp-config.php no encontrado: $wpconfig"; return 1; }

  local domain="${DOMAINS[$((idx-1))]}"
  local domain_sanitized
  domain_sanitized=$(sanitize_domain_name "$domain")
  local sftp_var_name
  sftp_var_name="SFTP_$(domain_to_sftp_var "$domain")_PASSWORD"

  # Obtener valores del .env
  local db_name="$domain_sanitized"
  local db_user="wpuser_${domain_sanitized}"
  local db_password=""
  local db_host="mysql"
  local sftp_user="sftp_${domain_sanitized}"
  local sftp_password=""

  # Obtener SERVER_IP del .env (nuevo en v3.3)
  local server_ip=""
  server_ip=$(grep -E "^SERVER_IP=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
  if [[ -z "$server_ip" ]]; then
    warn "  ⚠ No se encontró SERVER_IP en .env, usando 'localhost'"
    server_ip="localhost"
  fi

  # Leer DB_PASSWORD_{idx} del .env
  db_password=$(grep -E "^DB_PASSWORD_${idx}=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)

  # Leer SFTP password del .env
  sftp_password=$(grep -E "^${sftp_var_name}=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)

  info "Actualizando wp-config.php desde .env para sitio #${idx} (${domain})..."

  # Validar que tenemos las credenciales necesarias
  if [[ -z "$db_password" ]]; then
    warn "  ⚠ No se encontró DB_PASSWORD_${idx} en .env"
  fi

  # Crear backup del wp-config.php antes de modificar
  cp "$wpconfig" "${wpconfig}.pre-update.bak"

  # --- Actualizar configuración de base de datos ---
  info "  Actualizando credenciales de base de datos..."

  # DB_NAME
  if grep -qE "define\s*\(\s*['\"]DB_NAME['\"]" "$wpconfig"; then
    sed -i -E "s/(define\s*\(\s*['\"]DB_NAME['\"]\s*,\s*)['\"][^'\"]*['\"]/\1'${db_name}'/" "$wpconfig"
  else
    # Insertar después de la apertura de PHP o al inicio
    sed -i "1a define('DB_NAME', '${db_name}');" "$wpconfig"
  fi

  # DB_USER
  if grep -qE "define\s*\(\s*['\"]DB_USER['\"]" "$wpconfig"; then
    sed -i -E "s/(define\s*\(\s*['\"]DB_USER['\"]\s*,\s*)['\"][^'\"]*['\"]/\1'${db_user}'/" "$wpconfig"
  else
    sed -i "/DB_NAME/a define('DB_USER', '${db_user}');" "$wpconfig"
  fi

  # DB_PASSWORD - Escapar caracteres especiales
  local db_pass_escaped
  db_pass_escaped=$(printf '%s\n' "$db_password" | sed 's/[&/\]/\\&/g')
  if grep -qE "define\s*\(\s*['\"]DB_PASSWORD['\"]" "$wpconfig"; then
    sed -i -E "s/(define\s*\(\s*['\"]DB_PASSWORD['\"]\s*,\s*)['\"][^'\"]*['\"]/\1'${db_pass_escaped}'/" "$wpconfig"
  else
    sed -i "/DB_USER/a define('DB_PASSWORD', '${db_password}');" "$wpconfig"
  fi

  # DB_HOST
  if grep -qE "define\s*\(\s*['\"]DB_HOST['\"]" "$wpconfig"; then
    sed -i -E "s/(define\s*\(\s*['\"]DB_HOST['\"]\s*,\s*)['\"][^'\"]*['\"]/\1'${db_host}'/" "$wpconfig"
  else
    sed -i "/DB_PASSWORD/a define('DB_HOST', '${db_host}');" "$wpconfig"
  fi

  log "  ✓ Credenciales de DB actualizadas: DB=${db_name}, USER=wpuser_${domain_sanitized}, HOST=${db_host}"

  # --- Actualizar configuración SFTP (FORMATO SIMPLIFICADO v3.3) ---
  info "  Actualizando configuración de sistema de archivos..."

  # Eliminar configuraciones antiguas de FTP que ya no se usan
  sed -i "/define\s*(\s*['\"]FTP_BASE['\"]/d" "$wpconfig"
  sed -i "/define\s*(\s*['\"]FTP_CONTENT_DIR['\"]/d" "$wpconfig"
  sed -i "/define\s*(\s*['\"]FTP_PLUGIN_DIR['\"]/d" "$wpconfig"

  # Escapar caracteres especiales en password SFTP
  local sftp_pass_escaped=""
  if [[ -n "$sftp_password" ]]; then
    sftp_pass_escaped=$(printf '%s\n' "$sftp_password" | sed 's/[&/\]/\\&/g')
  fi

  # Construir FTP_HOST con SERVER_IP:2222
  local ftp_host_value="${server_ip}:2222"

  # FS_METHOD = 'direct'
  if grep -qE "define\s*\(\s*['\"]FS_METHOD['\"]" "$wpconfig"; then
    sed -i -E "s/(define\s*\(\s*['\"]FS_METHOD['\"]\s*,\s*)['\"][^'\"]*['\"]/\1'direct'/" "$wpconfig"
  else
    # Buscar una línea después de las configuraciones de DB para insertar el bloque SFTP
    if grep -qE "define\s*\(\s*['\"]DB_COLLATE['\"]" "$wpconfig"; then
      sed -i "/define.*DB_COLLATE/a\\
\\
/** Método de acceso al sistema de archivos */\\
define('FS_METHOD', 'direct');" "$wpconfig"
    elif grep -qE "define\s*\(\s*['\"]DB_HOST['\"]" "$wpconfig"; then
      sed -i "/define.*DB_HOST/a\\
\\
/** Método de acceso al sistema de archivos */\\
define('FS_METHOD', 'direct');" "$wpconfig"
    else
      # Añadir al final del archivo antes de cualquier cierre PHP
      {
        echo ""
        echo "/** Método de acceso al sistema de archivos */"
        echo "define('FS_METHOD', 'direct');"
      } >> "$wpconfig"
    fi
  fi

  # FTP_USER
  if grep -qE "define\s*\(\s*['\"]FTP_USER['\"]" "$wpconfig"; then
    sed -i -E "s/(define\s*\(\s*['\"]FTP_USER['\"]\s*,\s*)['\"][^'\"]*['\"]/\1'${sftp_user}'/" "$wpconfig"
  else
    sed -i "/define.*FS_METHOD/a define('FTP_USER', '${sftp_user}');" "$wpconfig"
  fi

  # FTP_PASS
  if [[ -n "$sftp_password" ]]; then
    if grep -qE "define\s*\(\s*['\"]FTP_PASS['\"]" "$wpconfig"; then
      sed -i -E "s/(define\s*\(\s*['\"]FTP_PASS['\"]\s*,\s*)['\"][^'\"]*['\"]/\1'${sftp_pass_escaped}'/" "$wpconfig"
    else
      sed -i "/define.*FTP_USER/a define('FTP_PASS', '${sftp_password}');" "$wpconfig"
    fi
    log "  ✓ FTP_PASS configurado"
  else
    warn "  ⚠ No se encontró ${sftp_var_name} en .env - FTP_PASS no configurado"
    # Si no hay password, insertar línea vacía o comentada
    if ! grep -qE "define\s*\(\s*['\"]FTP_PASS['\"]" "$wpconfig"; then
      sed -i "/define.*FTP_USER/a define('FTP_PASS', '');" "$wpconfig"
    fi
  fi

  # FTP_HOST con formato SERVER_IP:2222
  if grep -qE "define\s*\(\s*['\"]FTP_HOST['\"]" "$wpconfig"; then
    sed -i -E "s|(define\s*\(\s*['\"]FTP_HOST['\"]\s*,\s*)['\"][^'\"]*['\"]|\1'${ftp_host_value}'|" "$wpconfig"
  else
    sed -i "/define.*FTP_PASS/a define('FTP_HOST', '${ftp_host_value}');" "$wpconfig"
  fi

  log "  ✓ Configuración SFTP actualizada:"
  log "    FS_METHOD = 'direct'"
  log "    FTP_USER  = '${sftp_user}'"
  log "    FTP_HOST  = '${ftp_host_value}'"

  log "✓ wp-config.php actualizado correctamente para ${domain}"
  return 0
}

################################################################################
# FUNCIONES DE RESTAURACIÓN CON TEMPORALES GESTIONADOS
################################################################################

restore_database(){
  local idx="$1"
  local domain="${DOMAINS[$((idx-1))]}"
  local domain_sanitized=$(sanitize_domain_name "$domain")
  local db_name="${domain_sanitized}"
  local format=$(detect_backup_format)
  local f_db

  if [[ "$format" == "legacy" ]]; then
    f_db="${BACKUP_DIR}/databases/wp_sitio${idx}.sql.gz"
  else
    f_db="${BACKUP_DIR}/databases/${domain_sanitized}.sql.gz"
  fi

  [[ -f "$f_db" ]] || { warn "No se encontró dump de DB: $f_db"; return 1; }

  info "Restaurando base de datos: ${db_name}..."

  # Crear/recrear la base de datos - USANDO SISTEMA DE TEMPORALES
  local TMP_ERR; TMP_ERR="$(register_temp "db_err_create_${RANDOM}.log")"
  docker exec "$MYSQL_CID" sh -c \
    "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e \"DROP DATABASE IF EXISTS \\\`${db_name}\\\`; CREATE DATABASE \\\`${db_name}\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\"" \
    2>"$TMP_ERR" || {
      warn "Error al recrear base de datos ${db_name}:"
      grep -v "Using a password" "$TMP_ERR" || cat "$TMP_ERR"
      die "Falló la creación de la base de datos"
    }

  # Importar datos - USANDO SISTEMA DE TEMPORALES
  TMP_ERR="$(register_temp "db_err_import_${RANDOM}.log")"
  if zcat "$f_db" | docker exec -i "$MYSQL_CID" mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" "${db_name}" 2>"$TMP_ERR"; then
    log "✓ Base de datos ${db_name} restaurada"
  else
    warn "══════════════════════════════════════════════════════════"
    warn "ERROR al importar datos a ${db_name}"
    warn "══════════════════════════════════════════════════════════"
    if [[ -s "$TMP_ERR" ]]; then
      grep -v "Using a password" "$TMP_ERR" | head -20 || cat "$TMP_ERR" | head -20
    fi
    info "Espacio en disco: $(df -h / | tail -1 | awk '{print $5 " usado"}')"
    warn "══════════════════════════════════════════════════════════"
    die "Importación SQL falló - revisa los errores arriba"
  fi
}

################################################################################
# ESTRATEGIA 2: PARALELIZACIÓN - FUNCIONES CORREGIDAS (v3.1)
################################################################################

# Preparar archivos en staging (sin tocar el sitio destino aún)
# CORREGIDO: Mejor manejo de errores y diagnóstico
prepare_files_staging(){
  local idx="$1"
  local domain="${DOMAINS[$((idx-1))]}"
  local domain_sanitized
  domain_sanitized=$(sanitize_domain_name "$domain")

  local format
  format=$(detect_backup_format)
  local f_files

  if [[ "$format" == "legacy" ]]; then
    f_files="${BACKUP_DIR}/files/sitio${idx}.tar.gz"
  else
    f_files="${BACKUP_DIR}/files/${domain_sanitized}.tar.gz"
  fi

  # DEBUG: Mostrar qué archivo se busca
  info "  [DEBUG] Buscando archivo: $f_files"

  if [[ ! -f "$f_files" ]]; then
    info "  [DEBUG] No encontrado, buscando alternativas con patrón *${domain_sanitized}*.tar.gz"
    f_files=$(find "${BACKUP_DIR}/files" -maxdepth 1 -type f -name "*${domain_sanitized}*.tar.gz" 2>/dev/null | head -n1 || true)
    if [[ -z "$f_files" || ! -f "$f_files" ]]; then
      warn "⚠ No se encontró archivo de respaldo para ${domain_sanitized}"
      warn "  Archivos disponibles en ${BACKUP_DIR}/files/:"
      ls -la "${BACKUP_DIR}/files/" 2>/dev/null | head -20 || echo "  (no se pudo listar)"
      return 1
    fi
  fi

  info "Preparando archivos desde: $(basename "$f_files")"

  # Crear directorio staging temporal
  local staging_dir
  staging_dir="$(register_temp_dir "staging_${domain_sanitized}")"

  # Verificar que se creó
  if [[ ! -d "$staging_dir" ]]; then
    warn "❌ No se pudo crear directorio staging: $staging_dir"
    return 1
  fi

  # Extraer a staging
  info "  Extrayendo $(basename "$f_files") a staging..."
  if ! tar -xzf "$f_files" -C "$staging_dir"; then
    warn "❌ Error al extraer archivos de $(basename "$f_files")"
    return 1
  fi

  # Detectar directorio interno
  local inner_dir
  inner_dir=$(tar -tzf "$f_files" 2>/dev/null | head -1 | cut -d/ -f1 || true)

  # Si inner_dir está vacío, intentar detectar desde el staging
  if [[ -z "$inner_dir" ]]; then
    inner_dir=$(find "$staging_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | head -n1 || true)
  fi

  info "  [DEBUG] inner_dir detectado: '${inner_dir:-<vacío>}'"
  info "  [DEBUG] staging_dir: $staging_dir"
  info "  [DEBUG] Contenido del staging:"
  ls -la "$staging_dir" 2>/dev/null | head -10 || echo "  (vacío o error)"

  # Guardar información para la fase de finalización
  # CRÍTICO: Estos archivos DEBEN existir para que finalize_files_move funcione
  echo "$staging_dir" > "$TEMP_ROOT/staging_path_${idx}"
  echo "$inner_dir" > "$TEMP_ROOT/inner_dir_${idx}"
  echo "$domain_sanitized" > "$TEMP_ROOT/domain_sanitized_${idx}"

  # Verificar que se escribieron
  if [[ ! -s "$TEMP_ROOT/staging_path_${idx}" ]]; then
    warn "❌ No se pudo escribir staging_path_${idx}"
    return 1
  fi

  log "  ✓ Archivos preparados en staging"
  return 0
}

# Finalizar movimiento de archivos (rápido, ya están extraídos)
finalize_files_move(){
  local idx="$1"

  # Verificar que existen los archivos de metadata
  if [[ ! -f "$TEMP_ROOT/staging_path_${idx}" ]]; then
    warn "❌ No existe archivo de metadata: $TEMP_ROOT/staging_path_${idx}"
    warn "  Contenido de TEMP_ROOT ($TEMP_ROOT):"
    ls -la "$TEMP_ROOT" 2>/dev/null || echo "  (no existe)"
    return 1
  fi

  # Recuperar información de staging
  local staging_path
  staging_path=$(cat "$TEMP_ROOT/staging_path_${idx}")
  local inner_dir
  inner_dir=$(cat "$TEMP_ROOT/inner_dir_${idx}" 2>/dev/null || true)
  local domain_sanitized
  domain_sanitized=$(cat "$TEMP_ROOT/domain_sanitized_${idx}")

  # Validaciones
  if [[ -z "$staging_path" || ! -d "$staging_path" ]]; then
    warn "❌ staging_path inválido o no existe: '$staging_path'"
    return 1
  fi

  if [[ -z "$domain_sanitized" ]]; then
    warn "❌ domain_sanitized está vacío"
    return 1
  fi

  local site_dir="${PROJECT_DIR}/www/${domain_sanitized}"

  info "Finalizando instalación de archivos en www/${domain_sanitized}..."

  # Backup del sitio actual si existe
  if [[ -d "$site_dir" ]]; then
    local backup_name="${domain_sanitized}.bak.$(date +%Y%m%d_%H%M%S)"
    info "  Creando backup del sitio actual: www/${backup_name}"
    if mv "$site_dir" "${PROJECT_DIR}/www/${backup_name}"; then
      info "  ✓ Backup temporal creado: www/${backup_name}"
    else
      warn "  ⚠ No se pudo crear backup del sitio actual"
    fi
  fi

  mkdir -p "${PROJECT_DIR}/www"

  # Mover desde staging
  info "  [DEBUG] inner_dir='$inner_dir', staging_path='$staging_path'"

  if [[ -n "$inner_dir" && "$inner_dir" != "$domain_sanitized" && -d "${staging_path}/${inner_dir}" ]]; then
    info "  Moviendo ${staging_path}/${inner_dir} → $site_dir"
    mv "${staging_path}/${inner_dir}" "$site_dir"
    info "  Renombrado ${inner_dir} → ${domain_sanitized}"
  elif [[ -d "${staging_path}/${domain_sanitized}" ]]; then
    info "  Moviendo ${staging_path}/${domain_sanitized} → $site_dir"
    mv "${staging_path}/${domain_sanitized}" "$site_dir"
  else
    # Si hay un solo directorio en staging, usarlo
    local single_dir
    single_dir=$(find "$staging_path" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1 || true)
    if [[ -n "$single_dir" && -d "$single_dir" ]]; then
      info "  Moviendo directorio único: $(basename "$single_dir") → $site_dir"
      mv "$single_dir" "$site_dir"
    else
      warn "❌ No se encontró estructura válida en staging"
      warn "  Contenido de staging ($staging_path):"
      ls -la "$staging_path" 2>/dev/null || echo "  (vacío)"
      return 1
    fi
  fi

  if [[ -d "$site_dir" ]]; then
    # NUEVO v3.2: Actualizar wp-config.php desde .env (comportamiento unificado)
    if [[ -f "${site_dir}/wp-config.php" ]]; then
      update_wpconfig_from_env "$idx" "${site_dir}/wp-config.php"
    else
      warn "⚠ No se encontró wp-config.php en ${site_dir}"
    fi

    cleanup_and_verify_site "$site_dir"
    log "  ✓ Archivos instalados en www/${domain_sanitized}"
  else
    warn "❌ No se pudo instalar el sitio en ${site_dir}"
    return 1
  fi

  return 0
}

# Restauración paralela (FUNCIÓN PRINCIPAL - CORREGIDA v3.1)
restore_one_parallel(){
  local idx="$1"
  show_site_summary "$idx"
  confirm || { info "Cancelado."; return; }

  local pid_db pid_files
  local status_file_db status_file_files

  # Crear archivos de estado
  status_file_db="$(register_temp "status_db_${idx}")"
  status_file_files="$(register_temp "status_files_${idx}")"

  # Inicializar con -1 para detectar si nunca se escribieron
  echo "-1" > "$status_file_db"
  echo "-1" > "$status_file_files"

  info "⚡ Iniciando restauración paralela..."

  # Restaurar DB en background
  # CORREGIDO: set +e para que el subshell no muera prematuramente
  (
    trap - EXIT INT TERM
    set +e  # ← CRÍTICO: Desactivar set -e en el subshell
    restore_database "$idx"
    local result=$?
    echo "$result" > "$status_file_db"
    exit $result
  ) &
  pid_db=$!

  # Preparar archivos en paralelo
  # CORREGIDO: set +e para capturar el código de salida correctamente
  (
    trap - EXIT INT TERM
    set +e  # ← CRÍTICO: Desactivar set -e en el subshell
    prepare_files_staging "$idx"
    local result=$?
    echo "$result" > "$status_file_files"
    exit $result
  ) &
  pid_files=$!

  info "  [DB] Restaurando base de datos (PID: $pid_db)"
  info "  [FILES] Preparando archivos (PID: $pid_files)"

  # Esperar DB
  wait $pid_db || true  # No fallar si wait retorna error
  local status_db
  status_db=$(cat "$status_file_db" 2>/dev/null || echo "999")

  if [[ "$status_db" == "0" ]]; then
    log "  ✓ [DB] Completado"
  else
    warn "  ✗ [DB] Código de salida: $status_db"
    if [[ "$status_db" == "-1" ]]; then
      die "❌ [DB] El proceso terminó sin escribir status (posible crash)"
    else
      die "❌ [DB] Falló la restauración de base de datos"
    fi
  fi

  # Esperar Files
  wait $pid_files || true  # No fallar si wait retorna error
  local status_files
  status_files=$(cat "$status_file_files" 2>/dev/null || echo "999")

  if [[ "$status_files" == "0" ]]; then
    log "  ✓ [FILES] Preparación completada"
  else
    warn "  ✗ [FILES] Código de salida: $status_files"
    if [[ "$status_files" == "-1" ]]; then
      die "❌ [FILES] El proceso terminó sin escribir status (posible crash)"
    else
      die "❌ [FILES] Falló la preparación de archivos"
    fi
  fi

  # Ahora mover archivos al destino final (operación rápida)
  if ! finalize_files_move "$idx"; then
    die "❌ Falló la instalación final de archivos"
  fi

  log "✅ Restauración paralela completada para: ${DOMAINS[$((idx-1))]}"
}

# Wrapper para mantener compatibilidad (usa versión paralela)
restore_one(){
  restore_one_parallel "$@"
}

################################################################################
# RESTAURACIÓN EXTERNA OPTIMIZADA CON PARALELIZACIÓN
################################################################################

restore_from_external_zip(){
  log "🗂 Restauración externa desde ZIP en ${EXTERNAL_DIR}"

  select_external_zip
  [[ -f "$EXTERNAL_ZIP" ]] || die "ZIP no encontrado: $EXTERNAL_ZIP"

  # Descomprimir ZIP a un directorio temporal GESTIONADO
  local TMP; TMP="$(register_temp_dir "external_zip_extract")"
  unzip -oq "$EXTERNAL_ZIP" -d "$TMP" || die "No se pudo descomprimir el ZIP"

  # Identificar SQL y TAR dentro del ZIP
  local SQL_FILE TAR_FILE
  SQL_FILE=$(_pick_sql_file "$TMP")
  TAR_FILE=$(_pick_tar_file "$TMP")

  info "SQL detectado: $(basename "$SQL_FILE")"
  info "TAR detectado: $(basename "$TAR_FILE")"

  # Elegir sitio destino
  echo ""
  info "Sitios instalados:"
  for i in "${!DOMAINS[@]}"; do
    echo "  $((i+1)). ${DOMAINS[$i]}"
  done
  echo ""
  read -rp "Selecciona el número del sitio a sobrescribir: " selection
  [[ "$selection" =~ ^[0-9]+$ ]] || die "Selección inválida"
  (( selection >= 1 && selection <= ${#DOMAINS[@]} )) || die "Índice fuera de rango"

  local domain="${DOMAINS[$((selection-1))]}"
  local domain_sanitized; domain_sanitized=$(sanitize_domain_name "$domain")
  local site_dir="${PROJECT_DIR}/www/${domain_sanitized}"
  local db_name="${domain_sanitized}"

  echo ""
  echo -e "${BLUE}Resumen de restauración externa${NC}"
  echo "  ZIP:      $(basename "$EXTERNAL_ZIP")"
  echo "  SQL:      $(basename "$SQL_FILE")"
  echo "  TAR:      $(basename "$TAR_FILE")"
  echo "  Sitio:    #${selection} - ${domain}"
  echo "  Carpeta:  ${domain_sanitized}"
  echo ""

  warn "⚠️  ADVERTENCIA: Se sobrescribirán TODOS los archivos y la base de datos del sitio seleccionado"
  confirm || { info "Cancelado."; return; }

  # PARALELIZACIÓN: DB y extracción de archivos en paralelo
  local pid_db pid_tar
  local status_file_db status_file_tar

  status_file_db="$(register_temp "external_status_db")"
  status_file_tar="$(register_temp "external_status_tar")"

  # Inicializar
  echo "-1" > "$status_file_db"
  echo "-1" > "$status_file_tar"

  info "⚡ Iniciando restauración paralela desde ZIP externo..."

  # Base de datos en background - CORREGIDO
  (
    trap - EXIT INT TERM
    set +e
    _restore_external_database "$SQL_FILE" "$db_name"
    echo $? > "$status_file_db"
  ) &
  pid_db=$!

  # Extracción de archivos en paralelo - CORREGIDO
  local STAGE; STAGE="$(register_temp_dir "external_wpfiles")"
  (
    trap - EXIT INT TERM
    set +e
    _extract_tar_autodetect "$TAR_FILE" "$STAGE"
    echo $? > "$status_file_tar"
  ) &
  pid_tar=$!

  info "  [DB] Restaurando base de datos (PID: $pid_db)"
  info "  [TAR] Extrayendo archivos (PID: $pid_tar)"

  # Esperar DB
  wait $pid_db || true
  local status_db=$(cat "$status_file_db" 2>/dev/null || echo "999")
  [[ "$status_db" == "0" ]] && log "  ✓ [DB] Base de datos restaurada" || die "❌ [DB] Falló la restauración (código: $status_db)"

  # Esperar TAR
  wait $pid_tar || true
  local status_tar=$(cat "$status_file_tar" 2>/dev/null || echo "999")
  [[ "$status_tar" == "0" ]] && log "  ✓ [TAR] Archivos extraídos" || die "❌ [TAR] Falló la extracción (código: $status_tar)"

  # Ahora instalar archivos (ya están extraídos)
  info "Instalando archivos del sitio ${domain_sanitized}..."

  # Backup temporal del sitio actual
  if [[ -d "$site_dir" ]]; then
    local backup_name="${domain_sanitized}.bak.$(date +%Y%m%d_%H%M%S)"
    mv "$site_dir" "${PROJECT_DIR}/www/${backup_name}"
    info "  Backup temporal del sitio actual: www/${backup_name}"
  fi

  mkdir -p "$site_dir"

  # Detectar directorio raíz extraído
  local inner_dir
  inner_dir="$(find "$STAGE" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
  [[ -n "$inner_dir" ]] || die "No se detectó carpeta raíz dentro del TAR"

  mv "$inner_dir"/* "$site_dir/"
  mv "$inner_dir"/.[!.]* "$site_dir/" 2>/dev/null || true

  # NUEVO v3.2: Actualizar wp-config.php desde .env (comportamiento unificado)
  # Reemplaza la antigua preserve_wpconfig_credentials()
  if [[ -f "${site_dir}/wp-config.php" ]]; then
    update_wpconfig_from_env "$selection" "${site_dir}/wp-config.php"
  else
    warn "⚠ No se encontró wp-config.php en ${site_dir}"
  fi

  # Limpiar caché y verificar configuración
  cleanup_and_verify_site "$site_dir"

  log "✓ Archivos restaurados en www/${domain_sanitized}"
  log "✅ Restauración externa completada para ${domain}"
}

# Función auxiliar para restaurar DB externa (con manejo mejorado de errores)
_restore_external_database(){
  local sql_file="$1"
  local db_name="$2"

  info "Restaurando base de datos ${db_name}..."

  # Crear/recrear base de datos
  local TMP_ERR; TMP_ERR="$(register_temp "ext_db_err_create.log")"
  docker exec "$MYSQL_CID" sh -c \
    "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e \"DROP DATABASE IF EXISTS \\\`${db_name}\\\`; CREATE DATABASE \\\`${db_name}\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\"" \
    2>"$TMP_ERR" || {
      warn "Error al recrear la base de datos:"
      grep -v "Using a password" "$TMP_ERR" || cat "$TMP_ERR"
      return 1
    }

  # Importar SQL con diagnóstico mejorado
  TMP_ERR="$(register_temp "ext_db_err_import.log")"

  if [[ "$sql_file" == *.sql.gz ]]; then
    if zcat "$sql_file" | docker exec -i "$MYSQL_CID" mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" "${db_name}" 2>"$TMP_ERR"; then
      return 0
    else
      warn "══════════════════════════════════════════════════════════"
      warn "ERROR AL IMPORTAR SQL"
      warn "══════════════════════════════════════════════════════════"
      warn "Archivo: $(basename "$sql_file")"
      warn "Tamaño: $(du -h "$sql_file" | cut -f1)"
      echo ""
      warn "Errores de MySQL:"
      if [[ -s "$TMP_ERR" ]]; then
        grep -v "Using a password" "$TMP_ERR" | head -30 | sed 's/^/  /' || cat "$TMP_ERR" | head -30 | sed 's/^/  /'
      else
        warn "  (Sin mensajes de error capturados)"
      fi
      echo ""
      info "Espacio en disco: $(df -h / | tail -1 | awk '{print $5 " usado, " $4 " disponible"}')"
      warn "══════════════════════════════════════════════════════════"
      return 1
    fi
  else
    if cat "$sql_file" | docker exec -i "$MYSQL_CID" mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" "${db_name}" 2>"$TMP_ERR"; then
      return 0
    else
      warn "══════════════════════════════════════════════════════════"
      warn "ERROR AL IMPORTAR SQL"
      warn "══════════════════════════════════════════════════════════"
      warn "Archivo: $(basename "$sql_file")"
      warn "Tamaño: $(du -h "$sql_file" | cut -f1)"
      echo ""
      warn "Errores de MySQL:"
      if [[ -s "$TMP_ERR" ]]; then
        grep -v "Using a password" "$TMP_ERR" | head -30 | sed 's/^/  /' || cat "$TMP_ERR" | head -30 | sed 's/^/  /'
      else
        warn "  (Sin mensajes de error capturados)"
      fi
      echo ""
      info "Espacio en disco: $(df -h / | tail -1 | awk '{print $5 " usado, " $4 " disponible"}')"
      warn "══════════════════════════════════════════════════════════"
      return 1
    fi
  fi
}

################################################################################
# FUNCIONES AUXILIARES (sin cambios, excepto uso de temporales gestionados)
################################################################################

select_external_zip(){
  [[ -d "$EXTERNAL_DIR" ]] || die "No existe ${EXTERNAL_DIR}"

  mapfile -t zips < <(find "$EXTERNAL_DIR" -maxdepth 1 -type f -name "*.zip" -printf "%T@ %p\n" 2>/dev/null | sort -rn | cut -d' ' -f2- || true)

  if (( ${#zips[@]} == 0 )); then
    die "No hay archivos .zip en ${EXTERNAL_DIR}"
  fi

  echo ""
  info "ZIPs disponibles en ${EXTERNAL_DIR}:"
  echo ""

  for i in "${!zips[@]}"; do
    local idx=$((i+1))
    local zip_name=$(basename "${zips[$i]}")
    local zip_size=$(du -h "${zips[$i]}" 2>/dev/null | awk '{print $1}')
    local zip_date=$(stat -c %y "${zips[$i]}" 2>/dev/null | cut -d' ' -f1 || echo "")

    if [[ $i -eq 0 ]]; then
      echo -e "  ${GREEN}${idx}. ${zip_name}${NC} (${zip_size}) [${zip_date}] ${BLUE}← Más reciente${NC}"
    else
      echo "  ${idx}. ${zip_name} (${zip_size}) [${zip_date}]"
    fi
  done
  echo ""

  if [[ "$ASSUME_YES" == "yes" && ${#zips[@]} -eq 1 ]]; then
    EXTERNAL_ZIP="${zips[0]}"
    info "Usando ZIP: $(basename "$EXTERNAL_ZIP")"
  else
    read -rp "Selecciona el número del ZIP a usar [1 = más reciente]: " sel
    sel="${sel:-1}"
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#zips[@]} )); then
      die "Selección inválida"
    fi
    EXTERNAL_ZIP="${zips[$((sel-1))]}"
    info "ZIP seleccionado: $(basename "$EXTERNAL_ZIP")"
  fi
}

_pick_sql_file(){
  local f
  f=$(find "$1" -type f \( -iname "*.sql" -o -iname "*.sql.gz" \) -print -quit)
  [[ -n "$f" ]] || die "No se encontró archivo SQL dentro del ZIP"
  echo "$f"
}

_pick_tar_file(){
  local f
  f=$(find "$1" -type f \( -iname "*.tar" -o -iname "*.tar.gz" -o -iname "*.tgz" -o -iname "*.tar.bz2" \) -print -quit)
  [[ -n "$f" ]] || die "No se encontró archivo TAR dentro del ZIP"
  echo "$f"
}

_extract_tar_autodetect(){
  local tarfile="$1"
  local dest="$2"
  mkdir -p "$dest"
  case "$tarfile" in
    *.tar.gz|*.tgz)  tar -xzf "$tarfile" -C "$dest" ;;
    *.tar.bz2)       tar -xjf "$tarfile" -C "$dest" ;;
    *.tar)           tar -xf  "$tarfile" -C "$dest" ;;
    *) die "Formato TAR no soportado: $(basename "$tarfile")" ;;
  esac
}

cleanup_and_verify_site(){
  local site_dir="$1"
  local domain_sanitized=$(basename "$site_dir")

  info "Limpiando caché de ${domain_sanitized}..."

  # Limpiar caché de WordPress
  if [[ -d "${site_dir}/wp-content/cache" ]]; then
    rm -rf "${site_dir}/wp-content/cache"/*
    info "  ✓ Caché de WordPress limpiada"
  fi

  # Limpiar caché de plugins comunes
  for cache_dir in "${site_dir}/wp-content/"{w3tc-config,cache-enabler,wp-rocket-config,litespeed}; do
    if [[ -d "$cache_dir" ]]; then
      rm -rf "$cache_dir"/*
      info "  ✓ Caché de $(basename "$cache_dir") limpiada"
    fi
  done

  # Nota: La verificación de SFTP ya no es necesaria aquí porque
  # update_wpconfig_from_env() ya configuró todo correctamente

  log "  ✓ Sitio verificado y caché limpiada"
}

restart_services(){
  info "Limpiando caché de PHP y reiniciando todos los servicios..."
  local DC; DC="$(compose_cmd)"

  if [[ -n "$DC" ]]; then
    info "  Limpiando OPcache de PHP..."
    $DC --project-directory "$PROJECT_DIR" exec -T php php -r "if(function_exists('opcache_reset')){opcache_reset();echo 'OPcache limpiado\n';}" 2>/dev/null || true

    info "  Reiniciando todos los contenedores..."
    $DC --project-directory "$PROJECT_DIR" restart 2>/dev/null || true

    sleep 3

    info "  Verificando servicios..."
    local services_ok=true

    if ! $DC --project-directory "$PROJECT_DIR" ps | grep -q "php.*Up"; then
      warn "  ⚠ Servicio PHP no está corriendo"
      services_ok=false
    fi

    if ! $DC --project-directory "$PROJECT_DIR" ps | grep -q "nginx.*Up"; then
      warn "  ⚠ Servicio Nginx no está corriendo"
      services_ok=false
    fi

    if [[ "$services_ok" == true ]]; then
      log "✓ Todos los servicios reiniciados y verificados"
    else
      warn "✓ Servicios reiniciados pero algunos pueden tener problemas"
      info "  Ejecuta: docker compose ps para verificar el estado"
    fi
  else
    warn "No se pudo detectar docker compose, saltando reinicio de servicios"
  fi
}

################################################################################
# FUNCIÓN PRINCIPAL
################################################################################

main(){
  log "🔄 Iniciando restauración de backup [VERSIÓN v3.3 - Formato SFTP simplificado]..."
  cd "$PROJECT_DIR" || die "No se pudo acceder al proyecto"
  load_env
  detect_mysql_container || die "No se encontró contenedor MySQL"
  wait_for_mysql

  # Modo de restauración externa (solo si se especifica --external)
  if [[ "$MODE" == "external" ]]; then
    restore_from_external_zip
    restart_services
    log "✅ Restauración externa finalizada"
    exit 0
  fi

  # Restauración normal desde backups locales - SOLO --site
  resolve_backup_dir

  local format=$(detect_backup_format)
  [[ "$format" == "legacy" ]] && warn "⚠ Backup detectado en formato antiguo"

  resolve_site "$SITE_ARG"
  restore_one "$SITE_INDEX"

  restart_services
  log "✅ Proceso de restauración finalizado"
  info "Verifica que el sitio funcione correctamente"
  info "📊 Estadísticas: Limpieza automática garantizada | Paralelización DB+Files activa | wp-config.php unificado"
}

main "$@"