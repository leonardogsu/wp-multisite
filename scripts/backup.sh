#!/bin/bash
# backup.sh — robusto frente a nombre de contenedor MySQL (Compose o custom)
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
  : "${MYSQL_ROOT_PASSWORD:?Falta MYSQL_ROOT_PASSWORD en .env}"

  detect_mysql_container || die "No se encontró el contenedor de MySQL (revise nombre/servicio)."
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
}

create_backup_dir(){
  local dir="${BACKUP_DIR}/${DATE}"
  mkdir -p "${dir}"/{databases,files}
  echo "$dir"
}

backup_databases(){
  local dir="$1"
  log "Dump de bases de datos..."

  # Si no hay DOMAIN_* en .env, saltar dump por sitio y hacer solo global
  if ((${#DOMAINS[@]}==0)); then
    warn "No hay DOMAIN_* en .env; se hará solo dump global."
  else
    for i in "${!DOMAINS[@]}"; do
      local n; n=$((i+1))
      local db="wp_sitio${n}"
      local out="${dir}/databases/${db}.sql.gz"
      info "  → ${db}"
      if docker exec -i "$MYSQL_CID" mysqldump \
            -uroot -p"${MYSQL_ROOT_PASSWORD}" \
            --single-transaction --quick --lock-tables=false \
            --routines --events --triggers \
            "${db}" | gzip > "${out}"; then
        :
      else
        warn "    Falló el dump de ${db}"
      fi
    done
  fi

  # Dump global (usuarios/privilegios)
  docker exec -i "$MYSQL_CID" mysqldump \
       -uroot -p"${MYSQL_ROOT_PASSWORD}" \
       --all-databases --single-transaction --quick --lock-tables=false \
       --routines --events --triggers \
       | gzip > "${dir}/databases/ALL_DATABASES.sql.gz"
}

backup_files(){
  local dir="$1"
  log "Backup de archivos de WordPress..."
  local CZ="gzip"; command -v pigz &>/dev/null && CZ="pigz"

  if ((${#DOMAINS[@]}==0)); then
    warn "No hay sitios (DOMAIN_*); se omite empaquetado por sitio."
  else
    for i in "${!DOMAINS[@]}"; do
      local n; n=$((i+1))
      local site="sitio${n}"
      local out="${dir}/files/${site}.tar.gz"
      tar -C "${PROJECT_DIR}/www" \
          --exclude="${site}/wp-content/cache" \
          --exclude="${site}/wp-content/upgrade" \
          --exclude="${site}/wp-content/backups" \
          -cf - "${site}" 2>/dev/null | ${CZ} > "${out}" || warn "Falló ${site}"
    done
  fi

  local conf="${dir}/files/configs.tar.gz"
  tar -C "${PROJECT_DIR}" \
      --exclude="mysql/data" \
      --exclude="logs" \
      -cf - ".env" "docker-compose.yml" "nginx" "php" "mysql" \
      2>/dev/null | ${CZ} > "${conf}" || true
}

cleanup_old_backups(){
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +${RETENTION_DAYS} -exec rm -rf {} \; 2>/dev/null || true
}

summary(){
  local dir="$1"
  echo -e "\n${BLUE}Backup en:${NC} $dir"
  du -sh "$dir" 2>/dev/null | awk '{print "Tamaño total: "$1}'
}

main(){
  log "🔄 Iniciando backup..."
  check_requirements
  wait_for_mysql
  local dir; dir="$(create_backup_dir)"
  backup_databases "$dir"
  backup_files "$dir"
  cleanup_old_backups
  summary "$dir"
  echo -e "${GREEN}[OK]${NC} Backup completado"
}
main "$@"
