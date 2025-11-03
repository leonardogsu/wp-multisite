#!/bin/bash
################################################################################
# restore.sh - Script de restauración para WordPress Multi-Site
# Compatible con estructura basada en dominios sanitizados
# Versión: 2.3 - Permisos mejorados para WordPress
#
# Uso:
#   ./scripts/restore.sh --all                    # Restaura todos los sitios
#   ./scripts/restore.sh --site DOMINIO           # Restaura un sitio específico
#   ./scripts/restore.sh --site 2                 # Restaura sitio por índice
#   ./scripts/restore.sh --backup DIR             # Usa un backup específico
#   ./scripts/restore.sh --all --yes              # Sin confirmación
#
#   --- Restauración externa ---
#   ./scripts/restore.sh --external               # Restaurar desde ZIP externo
#       - Lista los ZIPs disponibles en backups/external
#       - Permite elegir un ZIP que contenga un SQL y un TAR
#       - Permite elegir un sitio destino instalado
#       - Sobrescribe la base de datos y los archivos de ese sitio
#
# Changelog v2.3:
#   - Permisos completos de WordPress establecidos correctamente en todos los modos
#   - Soluciona problemas de permisos para subir medios y actualizar plugins/temas
#   - Crea automáticamente el directorio wp-content/upgrade si no existe
#   - Permisos mejorados en wp-content, plugins, themes, uploads, upgrade y cache
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

# --- Función para sanitizar nombres de dominio ---
sanitize_domain_name() {
    local domain="$1"
    echo "$domain" | sed 's/\./_/g' | sed 's/-/_/g' | sed 's/[^a-zA-Z0-9_]//g' | tr '[:upper:]' '[:lower:]'
}

# --- Función para establecer permisos correctos de WordPress ---
set_wordpress_permissions() {
    local site_dir="$1"

    [[ -d "$site_dir" ]] || { warn "Directorio no existe: $site_dir"; return 1; }

    info "Estableciendo permisos de WordPress..."

    # Permisos base: propietario www-data
    chown -R www-data:www-data "$site_dir" 2>/dev/null || chown -R 33:33 "$site_dir"

    # Directorios: 755, Archivos: 644
    find "$site_dir" -type d -exec chmod 755 {} \;
    find "$site_dir" -type f -exec chmod 644 {} \;

    # wp-content/uploads: necesita escritura para subir medios
    if [[ -d "$site_dir/wp-content/uploads" ]]; then
        chmod 775 "$site_dir/wp-content/uploads"
        find "$site_dir/wp-content/uploads" -type d -exec chmod 775 {} \;
        find "$site_dir/wp-content/uploads" -type f -exec chmod 664 {} \;
    fi

    # wp-content/plugins: necesita escritura para actualizar plugins
    if [[ -d "$site_dir/wp-content/plugins" ]]; then
        chmod 775 "$site_dir/wp-content/plugins"
        find "$site_dir/wp-content/plugins" -type d -exec chmod 775 {} \;
    fi

    # wp-content/themes: necesita escritura para actualizar temas
    if [[ -d "$site_dir/wp-content/themes" ]]; then
        chmod 775 "$site_dir/wp-content/themes"
        find "$site_dir/wp-content/themes" -type d -exec chmod 775 {} \;
    fi

    # wp-content/upgrade: necesita escritura para actualizaciones temporales
    if [[ -d "$site_dir/wp-content/upgrade" ]]; then
        chmod 775 "$site_dir/wp-content/upgrade"
        find "$site_dir/wp-content/upgrade" -type d -exec chmod 775 {} \;
    else
        # Crear directorio upgrade si no existe
        mkdir -p "$site_dir/wp-content/upgrade"
        chown www-data:www-data "$site_dir/wp-content/upgrade" 2>/dev/null || chown 33:33 "$site_dir/wp-content/upgrade"
        chmod 775 "$site_dir/wp-content/upgrade"
    fi

    # wp-content/cache: si existe, necesita escritura
    if [[ -d "$site_dir/wp-content/cache" ]]; then
        chmod 775 "$site_dir/wp-content/cache"
        find "$site_dir/wp-content/cache" -type d -exec chmod 775 {} \;
        find "$site_dir/wp-content/cache" -type f -exec chmod 664 {} \;
    fi

    # wp-content base: debe permitir crear subcarpetas
    if [[ -d "$site_dir/wp-content" ]]; then
        chmod 775 "$site_dir/wp-content"
    fi

    log "✓ Permisos de WordPress establecidos correctamente"
    return 0
}

# --- docker compose shim ---
compose_cmd(){
  if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    echo "docker compose"
  elif command -v docker-compose &>/dev/null; then
    echo "docker-compose"
  else
    echo ""
  fi
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
    --all) MODE="all"; shift ;;
    --site) MODE="one"; SITE_ARG="${2:-}"; [[ -n "${SITE_ARG}" ]] || die "Falta valor para --site"; shift 2 ;;
    --backup) BACKUP_DIR="${2:-}"; [[ -n "${BACKUP_DIR}" ]] || die "Falta ruta para --backup"; shift 2 ;;
    --external) MODE="external"; shift ;;
    --yes|-y) ASSUME_YES="yes"; shift ;;
    -h|--help)
      sed -n '1,20p' "$0"; exit 0 ;;
    *) die "Opción no reconocida: $1 (usa --help para ayuda)" ;;
  esac
done

# --- Restauración externa: ZIP que contiene un SQL y un TAR ---
EXTERNAL_DIR="${BACKUP_ROOT}/external"
EXTERNAL_ZIP=""


[[ -n "$MODE" ]] || die "Debe indicar --all, --site <dominio|índice> o --external"

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

select_backup_interactive(){
  list_available_backups
  local backups=($(ls -1t "$BACKUP_ROOT" 2>/dev/null))
  echo -e "${YELLOW}Selecciona el backup a usar:${NC}"
  read -rp "  Número [1 = más reciente]: " selection
  selection=${selection:-1}
  if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ $selection -lt 1 ]] || [[ $selection -gt ${#backups[@]} ]]; then
    die "Selección inválida"
  fi
  echo "${BACKUP_ROOT}/${backups[$((selection-1))]}"
}

resolve_backup_dir(){
  # Evita que el "set -u" interrumpa si BACKUP_DIR aún no existe
  BACKUP_DIR="${BACKUP_DIR:-}"

  # Si no se pasó --backup, ofrecer selección o usar el más reciente
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

  # Validaciones reales (ya con BACKUP_DIR asignado)
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

restore_database(){
  local idx="$1"
  local domain="${DOMAINS[$((idx-1))]}"
  local domain_sanitized=$(sanitize_domain_name "$domain")
  local db_name="${domain_sanitized}"
  local db_user="wpuser_${domain_sanitized}"
  local format=$(detect_backup_format)
  local f_db

  if [[ "$format" == "legacy" ]]; then
    f_db="${BACKUP_DIR}/databases/wp_sitio${idx}.sql.gz"
  else
    f_db="${BACKUP_DIR}/databases/${domain_sanitized}.sql.gz"
  fi

  [[ -f "$f_db" ]] || { warn "No se encontró dump de DB: $f_db"; return 1; }

  info "Restaurando base de datos: ${db_name}..."
  docker exec "$MYSQL_CID" sh -c \
    "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e \"DROP DATABASE IF EXISTS \\\`${db_name}\\\`; CREATE DATABASE \\\`${db_name}\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\"" \
    || die "Error al recrear base de datos ${db_name}"

  zcat "$f_db" | docker exec -i "$MYSQL_CID" mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" "${db_name}" || \
    die "Error al importar datos a ${db_name}"

  log "✓ Base de datos ${db_name} restaurada"
}

restore_files(){
  local idx="$1"
  local domain="${DOMAINS[$((idx-1))]}"
  local domain_sanitized
  domain_sanitized=$(sanitize_domain_name "$domain")
  local site_dir="${PROJECT_DIR}/www/${domain_sanitized}"

  local format
  format=$(detect_backup_format)
  local f_files

  if [[ "$format" == "legacy" ]]; then
    f_files="${BACKUP_DIR}/files/sitio${idx}.tar.gz"
  else
    f_files="${BACKUP_DIR}/files/${domain_sanitized}.tar.gz"
  fi

  if [[ ! -f "$f_files" ]]; then
    # 🔍 Intento automático: detectar archivo por patrón
    f_files=$(find "${BACKUP_DIR}/files" -maxdepth 1 -type f -name "*${domain_sanitized}*.tar.gz" | head -n1 || true)
    if [[ -z "$f_files" ]]; then
      warn "⚠ No se encontró archivo de respaldo para ${domain_sanitized}"
      return 1
    fi
  fi

  info "Restaurando archivos desde: $(basename "$f_files")"

  # 🧩 Si existe el directorio, hacer copia de seguridad temporal
  if [[ -d "$site_dir" ]]; then
    local backup_name="${domain_sanitized}.bak.$(date +%Y%m%d_%H%M%S)"
    mv "$site_dir" "${PROJECT_DIR}/www/${backup_name}"
    info "  Backup temporal: www/${backup_name}"
  fi

  mkdir -p "${PROJECT_DIR}/www"

  # 📦 Detectar carpeta interna real dentro del tar
  local inner_dir
  inner_dir=$(tar -tzf "$f_files" | head -1 | cut -d/ -f1)

  info "Carpeta interna detectada en el backup: ${inner_dir:-<vacía>}"

  # Extraer al directorio base
  tar -xzf "$f_files" -C "${PROJECT_DIR}/www" || die "Error al extraer archivos"

  # Si la carpeta interna no coincide con la esperada, la renombramos
  if [[ -n "$inner_dir" && "$inner_dir" != "$domain_sanitized" && -d "${PROJECT_DIR}/www/${inner_dir}" ]]; then
    mv "${PROJECT_DIR}/www/${inner_dir}" "$site_dir"
    info "  Renombrado ${inner_dir} → ${domain_sanitized}"
  fi

  # 🛠 Ajustar permisos solo si el directorio existe tras extraer
  if [[ -d "$site_dir" ]]; then
    set_wordpress_permissions "$site_dir"
    log "  ✓ Archivos restaurados en www/${domain_sanitized}"
  else
    die "❌ No se encontró ${site_dir} tras la extracción. Estructura inesperada en el backup."
  fi

  return 0
}

restore_one(){
  local idx="$1"
  show_site_summary "$idx"
  confirm || { info "Cancelado."; return; }
  restore_database "$idx"
  restore_files "$idx"
  log "✅ Restauración completada para: ${DOMAINS[$((idx-1))]}"
}

restore_all(){
  log "Iniciando restauración de todos los sitios..."
  for i in "${!DOMAINS[@]}"; do
    local idx=$((i+1))
    restore_database "$idx"
    restore_files "$idx"
  done
  log "✅ Restauración completa"
}

restore_from_external_zip(){
  log "🗂 Restauración externa desde ZIP en ${EXTERNAL_DIR}"

  select_external_zip
  [[ -f "$EXTERNAL_ZIP" ]] || die "ZIP no encontrado: $EXTERNAL_ZIP"

  # Descomprimir ZIP a un directorio temporal
  local TMP; TMP="$(mktemp -d)"
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
  confirm || { info "Cancelado."; rm -rf "$TMP"; return; }

  # Base de datos
  info "Restaurando base de datos ${db_name}..."
  docker exec "$MYSQL_CID" sh -c \
    "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e \"DROP DATABASE IF EXISTS \\\`${db_name}\\\`; CREATE DATABASE \\\`${db_name}\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\"" \
    || { rm -rf "$TMP"; die "Error al recrear la base de datos"; }

  if [[ "$SQL_FILE" == *.sql.gz ]]; then
    zcat "$SQL_FILE" | docker exec -i "$MYSQL_CID" mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" "${db_name}" \
      || { rm -rf "$TMP"; die "Error al importar el SQL gz"; }
  else
    cat "$SQL_FILE" | docker exec -i "$MYSQL_CID" mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" "${db_name}" \
      || { rm -rf "$TMP"; die "Error al importar el SQL"; }
  fi
  log "✓ Base de datos restaurada"

  # Archivos
  info "Sobrescribiendo archivos del sitio ${domain_sanitized}..."

  # Guardar wp-config.php actual antes de hacer backup del sitio
  local OLD_WPCONFIG=""
  if [[ -f "${site_dir}/wp-config.php" ]]; then
    OLD_WPCONFIG="$(mktemp)"
    cp "${site_dir}/wp-config.php" "$OLD_WPCONFIG"
    info "  wp-config.php actual guardado temporalmente"
  fi

  # Backup temporal del sitio actual
  if [[ -d "$site_dir" ]]; then
    local backup_name="${domain_sanitized}.bak.$(date +%Y%m%d_%H%M%S)"
    mv "$site_dir" "${PROJECT_DIR}/www/${backup_name}"
    info "  Backup temporal del sitio actual: www/${backup_name}"
  fi

  mkdir -p "$site_dir"

  # Extraer TAR a un staging temporal y mover el directorio raíz al destino
  local STAGE="$TMP/_wpfiles"
  mkdir -p "$STAGE"
  _extract_tar_autodetect "$TAR_FILE" "$STAGE"

  # Detectar directorio raíz extraído
  local inner_dir
  inner_dir="$(find "$STAGE" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
  [[ -n "$inner_dir" ]] || { rm -rf "$TMP"; die "No se detectó carpeta raíz dentro del TAR"; }

  mv "$inner_dir"/* "$site_dir/"
  mv "$inner_dir"/.[!.]* "$site_dir/" 2>/dev/null || true

  # Preservar credenciales del wp-config.php antiguo
  if [[ -n "$OLD_WPCONFIG" && -f "$OLD_WPCONFIG" ]]; then
    preserve_wpconfig_credentials "$OLD_WPCONFIG" "${site_dir}/wp-config.php"
    rm -f "$OLD_WPCONFIG"
  fi

  # Permisos completos de WordPress
  set_wordpress_permissions "$site_dir"
  log "✓ Archivos restaurados en www/${domain_sanitized}"

  # Limpieza
  rm -rf "$TMP"

  log "✅ Restauración externa completada para ${domain}"
}


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

# Devuelve por stdout la ruta al SQL extraído. Soporta .sql y .sql.gz
_pick_sql_file(){
  local root="$1"
  local f
  f=$(find "$root" -type f \( -iname "*.sql" -o -iname "*.sql.gz" \) | head -n1 || true)
  [[ -n "$f" ]] || die "No se encontró archivo SQL dentro del ZIP"
  echo "$f"
}

# Devuelve por stdout la ruta al TAR extraído. Soporta .tar .tar.gz .tgz .tar.bz2
_pick_tar_file(){
  local root="$1"
  local f
  f=$(find "$root" -type f \( -iname "*.tar" -o -iname "*.tar.gz" -o -iname "*.tgz" -o -iname "*.tar.bz2" \) | head -n1 || true)
  [[ -n "$f" ]] || die "No se encontró archivo TAR dentro del ZIP"
  echo "$f"
}

# Extrae TAR a un destino. Auto detecta compresión
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

# Preserva configuraciones de DB y SFTP del wp-config.php antiguo en el nuevo
preserve_wpconfig_credentials(){
  local old_config="$1"
  local new_config="$2"

  [[ -f "$old_config" ]] || { warn "No se encontró wp-config.php antiguo, usando el del backup"; return; }
  [[ -f "$new_config" ]] || { warn "No se encontró wp-config.php nuevo"; return; }

  info "Preservando credenciales de DB y SFTP del wp-config.php actual..."

  # Crear archivo temporal con las definiciones a preservar
  local TMP_DEFS; TMP_DEFS="$(mktemp)"

  # Extraer definiciones de base de datos
  grep -E "^define\(\s*['\"]DB_(NAME|USER|PASSWORD|HOST|CHARSET|COLLATE)['\"]" "$old_config" > "$TMP_DEFS" || true

  # Extraer definiciones de SFTP/FTP
  grep -E "^define\(\s*['\"]FTP_(USER|PASS|HOST|SSL|PUBKEY|PRIKEY)['\"]" "$old_config" >> "$TMP_DEFS" || true
  grep -E "^define\(\s*['\"]FS_METHOD['\"]" "$old_config" >> "$TMP_DEFS" || true

  # Extraer definiciones adicionales de FTP
  grep -E "^define\(\s*['\"]FTPS?_(USER|PASS|HOST|SSL|PORT)['\"]" "$old_config" >> "$TMP_DEFS" || true

  if [[ ! -s "$TMP_DEFS" ]]; then
    warn "No se encontraron definiciones de DB o SFTP para preservar"
    rm -f "$TMP_DEFS"
    return
  fi

  # Crear backup del nuevo config antes de modificar
  cp "$new_config" "${new_config}.bak"

  # Eliminar las definiciones antiguas del nuevo archivo
  sed -i '/^define(\s*['\''"]DB_\(NAME\|USER\|PASSWORD\|HOST\|CHARSET\|COLLATE\)['\''"].*$/d' "$new_config"
  sed -i '/^define(\s*['\''"]FTP_\(USER\|PASS\|HOST\|SSL\|PUBKEY\|PRIKEY\)['\''"].*$/d' "$new_config"
  sed -i '/^define(\s*['\''"]FTPS\?_\(USER\|PASS\|HOST\|SSL\|PORT\)['\''"].*$/d' "$new_config"
  sed -i '/^define(\s*['\''"]FS_METHOD['\''"].*$/d' "$new_config"

  # Insertar las definiciones preservadas después de la línea de configuración de MySQL
  # Buscar la última línea que contiene comentarios sobre MySQL o DB
  local insert_line
  insert_line=$(grep -n "\/\*\*.*MySQL\|\/\*\*.*database\|\/\/ \*\* MySQL" "$new_config" | tail -1 | cut -d: -f1 || echo "")

  if [[ -n "$insert_line" ]]; then
    # Insertar después del comentario
    sed -i "${insert_line}r $TMP_DEFS" "$new_config"
  else
    # Si no hay comentario, insertar al principio después de la etiqueta PHP
    sed -i "1r $TMP_DEFS" "$new_config"
  fi

  rm -f "$TMP_DEFS"

  log "✓ Credenciales de DB y SFTP preservadas en wp-config.php"
}

restart_services(){
  info "Reiniciando servicios PHP y Nginx..."
  local DC; DC="$(compose_cmd)"
  [[ -n "$DC" ]] && $DC --project-directory "$PROJECT_DIR" restart php nginx 2>/dev/null || true
  log "✓ Servicios reiniciados"
}

main(){
  log "🔄 Iniciando restauración de backup..."
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

  # Restauración normal desde backups locales
  resolve_backup_dir

  local format=$(detect_backup_format)
  [[ "$format" == "legacy" ]] && warn "⚠ Backup detectado en formato antiguo"

  if [[ "$MODE" == "all" ]]; then
    restore_all
  else
    resolve_site "$SITE_ARG"
    restore_one "$SITE_INDEX"
  fi

  restart_services
  log "✅ Proceso de restauración finalizado"
  info "Verifica que los sitios funcionen correctamente"
}

main "$@"