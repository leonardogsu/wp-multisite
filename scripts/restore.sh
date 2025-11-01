#!/bin/bash
################################################################################
# restore.sh - Script de restauración para WordPress Multi-Site
# Compatible con estructura basada en dominios sanitizados
# Versión: 2.0 - Actualizado para auto-install.sh
#
# Uso:
#   ./scripts/restore.sh --all                    # Restaura todos los sitios
#   ./scripts/restore.sh --site DOMINIO           # Restaura un sitio específico
#   ./scripts/restore.sh --site 2                 # Restaura sitio por índice
#   ./scripts/restore.sh --backup DIR             # Usa un backup específico
#   ./scripts/restore.sh --all --yes              # Sin confirmación
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
    --yes|-y) ASSUME_YES="yes"; shift ;;
    -h|--help)
      sed -n '1,15p' "$0"; exit 0 ;;
    *) die "Opción no reconocida: $1 (usa --help para ayuda)" ;;
  esac
done

[[ -n "$MODE" ]] || die "Debe indicar --all o --site <dominio|índice>"

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
    chown -R www-data:www-data "$site_dir" 2>/dev/null || chown -R 33:33 "$site_dir"
    find "$site_dir" -type d -exec chmod 755 {} \;
    find "$site_dir" -type f -exec chmod 644 {} \;
    if [[ -d "$site_dir/wp-content/uploads" ]]; then
      chmod 775 "$site_dir/wp-content/uploads"
      find "$site_dir/wp-content/uploads" -type d -exec chmod 775 {} \;
    fi
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
