#!/bin/bash
################################################################################
# backup.sh - Script de backup robusto para WordPress Multi-Site
# Compatible con estructura basada en dominios sanitizados
# Versión: 2.0 - Actualizado para auto-install.sh
################################################################################

set -euo pipefail

# --- Paths / constantes ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd || pwd)"
ENV_FILE="${PROJECT_DIR}/.env"
BACKUP_DIR="${PROJECT_DIR}/backups"
DATE="$(date +%Y%m%d_%H%M%S)"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

# --- Utils ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log(){ echo -e "${GREEN}[$(date +'%F %T')]${NC} $*"; }
info(){ echo -e "${BLUE}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
die(){ echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# --- Función para sanitizar nombres de dominio (igual que en setup.sh) ---
sanitize_domain_name() {
    local domain="$1"
    # Convertir puntos y guiones en guiones bajos, eliminar caracteres especiales
    # Mantiene la estructura completa del subdominio
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

# --- localizar contenedor MySQL sin depender del nombre ---
MYSQL_CID=""
detect_mysql_container(){
  local DC; DC="$(compose_cmd)"
  # 1) Si el .env define MYSQL_CONTAINER, úsalo (nombre o id)
  if [[ -n "${MYSQL_CONTAINER:-}" ]]; then
    if docker inspect "${MYSQL_CONTAINER}" &>/dev/null; then
      MYSQL_CID="${MYSQL_CONTAINER}"; return 0
    fi
  fi
  # 2) Intentar por servicio 'mysql' de compose en este proyecto
  if [[ -n "$DC" ]]; then
    local cid
    cid=$($DC --project-directory "$PROJECT_DIR" ps -q mysql 2>/dev/null || true)
    if [[ -n "$cid" ]]; then MYSQL_CID="$cid"; return 0; fi
  fi
  # 3) Buscar por nombre aproximado en docker ps
  local guess
  guess="$(docker ps --format '{{.ID}} {{.Names}}' | awk '/mysql/ {print $1; exit}')"
  if [[ -n "$guess" ]]; then MYSQL_CID="${guess}"; return 0; fi
  # 4) Buscar por imagen
  guess="$(docker ps --filter 'ancestor=mysql' --format '{{.ID}}' | head -n1)"
  if [[ -n "$guess" ]]; then MYSQL_CID="${guess}"; return 0; fi
  return 1
}

# --- Cargar env y verificar requisitos ---
declare -a DOMAINS=()
check_requirements(){
  cd "$PROJECT_DIR" || die "No se pudo acceder al proyecto"
  [[ -f "$ENV_FILE" ]] || die "No existe .env en $PROJECT_DIR"

  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a

  # Rellenar DOMAINS si existen DOMAIN_*
  mapfile -t DOMAINS < <(grep -E '^DOMAIN_' "$ENV_FILE" | cut -d'=' -f2 || true)

  if ((${#DOMAINS[@]} == 0)); then
    warn "No hay dominios configurados (DOMAIN_*) en .env"
  fi

  : "${MYSQL_ROOT_PASSWORD:?Falta MYSQL_ROOT_PASSWORD en .env}"

  detect_mysql_container || die "No se encontró el contenedor de MySQL"

  if [[ "$(docker inspect -f '{{.State.Running}}' "$MYSQL_CID")" != "true" ]]; then
    die "MySQL no está en ejecución (contenedor: $MYSQL_CID)"
  fi
}

wait_for_mysql(){
  info "Esperando a MySQL en el contenedor ($MYSQL_CID)..."
  local tries=30
  until docker exec "$MYSQL_CID" mysqladmin ping -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent &>/dev/null; do
    ((tries--)) || die "MySQL no respondió a tiempo"
    sleep 2
  done
  log "✓ MySQL está listo"
}

create_backup_dir(){
  local dir="${BACKUP_DIR}/${DATE}"
  mkdir -p "${dir}"/{databases,files}
  echo "$dir"
}

backup_databases(){
  local dir="$1"
  log "📦 Creando dump de bases de datos..."
  echo ""

  if ((${#DOMAINS[@]} == 0)); then
    warn "No hay sitios configurados, solo se hará dump global"
  else
    # Backup de cada base de datos individual
    for i in "${!DOMAINS[@]}"; do
      local domain="${DOMAINS[$i]}"
      local domain_sanitized=$(sanitize_domain_name "$domain")
      local db_name="${domain_sanitized}"
      local out="${dir}/databases/${db_name}.sql.gz"

      info "  → ${domain} (DB: ${db_name})"

      if docker exec -i "$MYSQL_CID" mysqldump \
            -uroot -p"${MYSQL_ROOT_PASSWORD}" \
            --single-transaction --quick --lock-tables=false \
            --routines --events --triggers \
            "${db_name}" 2>/dev/null | gzip > "${out}"; then
        local size=$(du -h "${out}" | cut -f1)
        log "    ✓ Backup creado (${size})"
      else
        warn "    ⚠ Falló el dump de ${db_name}"
      fi
    done
  fi

  echo ""
  info "  → Creando dump global (usuarios y privilegios)..."

  # Dump global (usuarios/privilegios)
  docker exec -i "$MYSQL_CID" mysqldump \
       -uroot -p"${MYSQL_ROOT_PASSWORD}" \
       --all-databases --single-transaction --quick --lock-tables=false \
       --routines --events --triggers \
       | gzip > "${dir}/databases/ALL_DATABASES.sql.gz"

  local size=$(du -h "${dir}/databases/ALL_DATABASES.sql.gz" | cut -f1)
  log "    ✓ Dump global creado (${size})"
  echo ""
  log "✅ Bases de datos respaldadas"
}

backup_files(){
  local dir="$1"
  log "📁 Creando backup de archivos WordPress..."
  echo ""

  # Detectar si pigz está disponible para compresión paralela
  local CZ="gzip"
  if command -v pigz &>/dev/null; then
    CZ="pigz"
    info "  ℹ Usando pigz para compresión paralela"
  fi

  if ((${#DOMAINS[@]} == 0)); then
    warn "No hay sitios configurados, se omite empaquetado por sitio"
  else
    # Backup de cada sitio
    for i in "${!DOMAINS[@]}"; do
      local domain="${DOMAINS[$i]}"
      local domain_sanitized=$(sanitize_domain_name "$domain")
      local site_dir="${domain_sanitized}"
      local out="${dir}/files/${site_dir}.tar.gz"

      if [[ ! -d "${PROJECT_DIR}/www/${site_dir}" ]]; then
        warn "  ⚠ No existe directorio: www/${site_dir}"
        continue
      fi

      info "  → ${domain} (${site_dir})"

      if tar -C "${PROJECT_DIR}/www" \
          --exclude="${site_dir}/wp-content/cache" \
          --exclude="${site_dir}/wp-content/upgrade" \
          --exclude="${site_dir}/wp-content/backups" \
          -cf - "${site_dir}" 2>/dev/null | ${CZ} > "${out}"; then
        local size=$(du -h "${out}" | cut -f1)
        log "    ✓ Archivos empaquetados (${size})"
      else
        warn "    ⚠ Falló empaquetado de ${site_dir}"
      fi
    done
  fi

  echo ""
  info "  → Respaldando configuraciones del proyecto..."

  # Backup de configuraciones
  local conf="${dir}/files/configs.tar.gz"
  if tar -C "${PROJECT_DIR}" \
      --exclude="mysql/data" \
      --exclude="logs" \
      -cf - ".env" "docker-compose.yml" "nginx" "php" "mysql" \
      2>/dev/null | ${CZ} > "${conf}"; then
    local size=$(du -h "${conf}" | cut -f1)
    log "    ✓ Configuraciones respaldadas (${size})"
  else
    warn "    ⚠ Falló backup de configuraciones"
  fi

  echo ""
  log "✅ Archivos respaldados"
}

cleanup_old_backups(){
  if [[ ! -d "$BACKUP_DIR" ]]; then
    return 0
  fi

  local old_backups=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +${RETENTION_DAYS} 2>/dev/null || true)

  if [[ -n "$old_backups" ]]; then
    echo ""
    log "🗑️  Limpiando backups antiguos (>${RETENTION_DAYS} días)..."
    echo "$old_backups" | while IFS= read -r old_backup; do
      local name=$(basename "$old_backup")
      info "  → Eliminando: $name"
      rm -rf "$old_backup"
    done
    log "✅ Limpieza completada"
  fi
}

show_summary(){
  local dir="$1"

  echo ""
  echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}  BACKUP COMPLETADO EXITOSAMENTE${NC}"
  echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
  echo ""

  info "Ubicación del backup:"
  echo "  $dir"
  echo ""

  info "Contenido del backup:"

  # Mostrar bases de datos respaldadas
  echo ""
  echo "  📦 Bases de datos:"
  if [[ -d "${dir}/databases" ]]; then
    for db_file in "${dir}/databases"/*.sql.gz; do
      if [[ -f "$db_file" ]]; then
        local name=$(basename "$db_file" .sql.gz)
        local size=$(du -h "$db_file" | cut -f1)
        echo "     • ${name} (${size})"
      fi
    done
  fi

  # Mostrar archivos respaldados
  echo ""
  echo "  📁 Archivos:"
  if [[ -d "${dir}/files" ]]; then
    for file_archive in "${dir}/files"/*.tar.gz; do
      if [[ -f "$file_archive" ]]; then
        local name=$(basename "$file_archive" .tar.gz)
        local size=$(du -h "$file_archive" | cut -f1)
        echo "     • ${name} (${size})"
      fi
    done
  fi

  echo ""
  info "Tamaño total:"
  local total_size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
  echo "  ${total_size}"

  echo ""
  info "Retención de backups: ${RETENTION_DAYS} días"

  local backup_count=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  echo "  Backups totales disponibles: ${backup_count}"

  echo ""
  echo -e "${GREEN}✓${NC} Para restaurar este backup, ejecuta:"
  echo "  ./scripts/restore.sh --backup $dir"
  echo ""
}

main(){
  log "🚀 Iniciando proceso de backup..."
  echo ""

  check_requirements
  wait_for_mysql

  local dir
  dir="$(create_backup_dir)"

  backup_databases "$dir"
  backup_files "$dir"
  cleanup_old_backups
  show_summary "$dir"

  echo -e "${GREEN}✅ Proceso de backup completado${NC}"
}

main "$@"