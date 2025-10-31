#!/bin/bash

################################################################################
# Script de Restauración - WordPress Multi-Site
# Restaura bases de datos y archivos desde un backup
################################################################################

set -euo pipefail

# Configuración
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd || pwd)"
readonly ENV_FILE="${PROJECT_DIR}/.env"
readonly BACKUP_DIR="${PROJECT_DIR}/backups"

# Colores
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'
#!/bin/bash
# restore.sh — Restaura backups de WordPress (todos o un único sitio)
# Opciones:
#   --all                 Restaura TODOS los sitios del snapshot más reciente (o --backup)
#   --site N|sitioN|DOM   Restaura un único sitio por índice (1..N), nombre (sitio3) o dominio
#   --backup DIR          Ruta al snapshot dentro de backups/ (por defecto usa el más reciente)
#   --yes                 No pedir confirmación
# Ejemplos:
#   ./scripts/restore.sh --all
#   ./scripts/restore.sh --site 2
#   ./scripts/restore.sh --site blog.midominio.com --backup /opt/wordpress-multisite/backups/20251028_120001

set -euo pipefail

# --- Paths / constantes ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd || pwd)"
ENV_FILE="${PROJECT_DIR}/.env"
BACKUP_ROOT="${PROJECT_DIR}/backups"

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
  # 1) .env puede definir MYSQL_CONTAINER
  if [[ -n "${MYSQL_CONTAINER:-}" ]]; then
    if docker inspect "${MYSQL_CONTAINER}" &>/dev/null; then
      MYSQL_CID="${MYSQL_CONTAINER}"; return 0
    fi
  fi
  # 2) Servicio 'mysql' de compose en este proyecto
  if [[ -n "$DC" ]]; then
    local cid
    cid=$($DC --project-directory "$PROJECT_DIR" ps -q mysql 2>/dev/null || true)
    if [[ -n "$cid" ]]; then MYSQL_CID="$cid"; return 0; fi
  fi
  # 3) Buscar por nombre aproximado
  local guess
  guess="$(docker ps --format '{{.ID}} {{.Names}}' | awk '/mysql/ {print $1; exit}')"
  if [[ -n "$guess" ]]; then MYSQL_CID="${guess}"; return 0; fi
  # 4) Buscar por imagen
  guess="$(docker ps --filter 'ancestor=mysql' --format '{{.ID}}' | head -n1)"
  if [[ -n "$guess" ]]; then MYSQL_CID="${guess}"; return 0; fi
  return 1
}

wait_for_mysql(){
  info "Comprobando MySQL en contenedor ($MYSQL_CID)..."
  local tries=30
  until docker exec "$MYSQL_CID" mysqladmin ping -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent &>/dev/null; do
    ((tries--)) || die "MySQL no respondió a tiempo"
    sleep 2
  done
}

# --- Args ---
MODE=""           # "all" | "one"
SITE_ARG=""       # índice | sitioN | dominio
BACKUP_DIR=""     # ruta al snapshot
ASSUME_YES="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) MODE="all"; shift ;;
    --site) MODE="one"; SITE_ARG="${2:-}"; [[ -n "${SITE_ARG}" ]] || die "Falta valor para --site"; shift 2 ;;
    --backup) BACKUP_DIR="${2:-}"; [[ -n "${BACKUP_DIR}" ]] || die "Falta ruta para --backup"; shift 2 ;;
    --yes|-y) ASSUME_YES="yes"; shift ;;
    -h|--help)
      sed -n '1,70p' "$0"; exit 0 ;;
    *) die "Opción no reconocida: $1" ;;
  esac
done

[[ -n "$MODE" ]] || die "Debe indicar --all o --site"

# --- Cargar entorno / dominios ---
declare -a DOMAINS=()
load_env(){
  [[ -f "$ENV_FILE" ]] || die "No existe .env en $PROJECT_DIR"
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
  : "${MYSQL_ROOT_PASSWORD:?Falta MYSQL_ROOT_PASSWORD en .env}"
  mapfile -t DOMAINS < <(grep -E '^DOMAIN_' "$ENV_FILE" | cut -d'=' -f2 || true)
}

# --- Seleccionar snapshot ---
latest_backup_dir(){
  [[ -d "$BACKUP_ROOT" ]] || die "No existe ${BACKUP_ROOT}"
  local latest
  latest="$(ls -1 "$BACKUP_ROOT" | sort -r | head -n1 || true)"
  [[ -n "$latest" ]] || die "No hay snapshots en ${BACKUP_ROOT}"
  echo "${BACKUP_ROOT}/${latest}"
}

resolve_backup_dir(){
  if [[ -z "$BACKUP_DIR" ]]; then
    BACKUP_DIR="$(latest_backup_dir)"
  fi
  [[ -d "$BACKUP_DIR" ]] || die "Snapshot no válido: $BACKUP_DIR"
  [[ -d "$BACKUP_DIR/databases" && -d "$BACKUP_DIR/files" ]] || die "Estructura inválida de snapshot: faltan /databases o /files"
}

# --- Resolver sitio a partir de índice/nombre dominio ---
# Salida: SITE_INDEX (1..N), SITE_NAME (sitioN), SITE_DOMAIN
SITE_INDEX=0; SITE_NAME=""; SITE_DOMAIN=""
resolve_site(){
  local arg="$1"
  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    SITE_INDEX="$arg"
  elif [[ "$arg" =~ ^sitio([0-9]+)$ ]]; then
    SITE_INDEX="${BASH_REMATCH[1]}"
  else
    # buscar por dominio exacto en DOMAINS
    for i in "${!DOMAINS[@]}"; do
      if [[ "${DOMAINS[$i]}" == "$arg" ]]; then
        SITE_INDEX=$((i+1))
        break
      fi
    done
  fi
  (( SITE_INDEX > 0 )) || die "No se pudo resolver el sitio a partir de: '$arg'"
  SITE_NAME="sitio${SITE_INDEX}"
  SITE_DOMAIN="${DOMAINS[$((SITE_INDEX-1))]:-desconocido}"
}

# --- Utilidades de tamaño de archivo ---
human_size(){ du -h "$1" 2>/dev/null | awk '{print $1}'; }

# --- Resumen previo (un sitio) ---
show_site_summary(){
  local idx="$1"
  local name="sitio${idx}"
  local domain="${DOMAINS[$((idx-1))]:-desconocido}"
  local f_files="${BACKUP_DIR}/files/${name}.tar.gz"
  local f_db="${BACKUP_DIR}/databases/wp_sitio${idx}.sql.gz"

  [[ -f "$f_files" ]] || warn "No existe archivo de archivos para ${name}: $f_files"
  [[ -f "$f_db" ]] || warn "No existe dump de DB para ${name}: $f_db"

  local sz_files="n/a"; [[ -f "$f_files" ]] && sz_files="$(human_size "$f_files")"
  local sz_db="n/a";    [[ -f "$f_db" ]]    && sz_db="$(human_size "$f_db")"

  echo -e "${BLUE}Resumen de restauración${NC}"
  echo "  Sitio:   ${name}"
  echo "  URL:     ${domain}"
  echo "  Archivos:${sz_files}"
  echo "  DB:      ${sz_db}"
}

confirm(){
  [[ "$ASSUME_YES" == "yes" ]] && return 0
  read -r -p "¿Continuar? [y/N] " ans
  [[ "${ans:-}" =~ ^[yY]$ ]]
}

# --- Restaurar un sitio ---
restore_one(){
  local idx="$1"
  local name="sitio${idx}"
  local domain="${DOMAINS[$((idx-1))]:-desconocido}"
  local f_files="${BACKUP_DIR}/files/${name}.tar.gz"
  local f_db="${BACKUP_DIR}/databases/wp_sitio${idx}.sql.gz"

  show_site_summary "$idx"
  confirm || { info "Cancelado."; return 0; }

  # Archivos
  if [[ -f "$f_files" ]]; then
    info "Restaurando archivos de ${name}..."
    mkdir -p "${PROJECT_DIR}/www"
    if [[ -d "${PROJECT_DIR}/www/${name}" ]]; then
      mv "${PROJECT_DIR}/www/${name}" "${PROJECT_DIR}/www/${name}.bak.$(date +%Y%m%d_%H%M%S)"
    fi
    mkdir -p "${PROJECT_DIR}/www"
    tar -C "${PROJECT_DIR}/www" -xzf "$f_files"
    chown -R www-data:www-data "${PROJECT_DIR}/www/${name}" || true
  else
    warn "No se encontró el paquete de archivos: $f_files (se omite)"
  fi

  # Base de datos
  if [[ -f "$f_db" ]]; then
    info "Restaurando base de datos wp_sitio${idx}..."
    docker exec "$MYSQL_CID" sh -c \
      "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e \"DROP DATABASE IF EXISTS \\\`wp_sitio${idx}\\\`; CREATE DATABASE \\\`wp_sitio${idx}\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\"" \
      >/dev/null
    # Importar
    zcat "$f_db" | docker exec -i "$MYSQL_CID" mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" "wp_sitio${idx}"
  else
    warn "No se encontró el dump de DB: $f_db (se omite)"
  fi

  echo -e "${GREEN}✓ Restauración completada para ${name} (${domain})${NC}"
}

# --- Restaurar todos los sitios del snapshot ---
restore_all(){
  info "Iniciando restauración de TODOS los sitios desde: $BACKUP_DIR"
  # Detectar sitios por archivos presentes, manteniendo correlación 1..N
  local count=0
  shopt -s nullglob
  for f in "${BACKUP_DIR}/files"/sitio*.tar.gz; do
    local base; base="$(basename "$f")"           # sitioN.tar.gz
    local idx;  idx="$(sed -E 's/^sitio([0-9]+).*/\1/' <<< "$base")"
    if [[ -n "$idx" ]]; then
      ((count++))
      show_site_summary "$idx"
      echo
    fi
  done
  shopt -u nullglob
  [[ $count -gt 0 ]] || die "No se encontraron sitios en el snapshot."

  confirm || { info "Cancelado."; return 0; }

  # Ejecutar restauración sitio a sitio en orden
  for f in "${BACKUP_DIR}/files"/sitio*.tar.gz; do
    local base; base="$(basename "$f")"
    local idx;  idx="$(sed -E 's/^sitio([0-9]+).*/\1/' <<< "$base")"
    restore_one "$idx"
  done
}

# --- main ---
main(){
  log "🔁 Iniciando RESTORE"
  load_env
  detect_mysql_container || die "No se encontró el contenedor de MySQL."
  [[ "$(docker inspect -f '{{.State.Running}}' "$MYSQL_CID")" == "true" ]] || die "MySQL no está en ejecución ($MYSQL_CID)."
  wait_for_mysql
  resolve_backup_dir
  info "Usando snapshot: $BACKUP_DIR"

  case "$MODE" in
    all) restore_all ;;
    one)
      resolve_site "$SITE_ARG"
      restore_one "$SITE_INDEX"
      ;;
  esac

  log "✅ Restore finalizado"
}

main "$@"

# Funciones de logging
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

# Verificar requisitos
check_requirements() {
    cd "$PROJECT_DIR" || error "No se pudo acceder al directorio del proyecto"
    [[ -f "$ENV_FILE" ]] || error "Archivo .env no encontrado"
    [[ -d "$BACKUP_DIR" ]] || error "Directorio de backups no encontrado"

    if ! docker compose ps | grep -q "mysql.*running"; then
        error "MySQL no está ejecutándose. Ejecuta: docker compose up -d"
    fi
}

# Cargar variables de entorno
load_env() {
    set -a
    source "$ENV_FILE"
    set +a

    mapfile -t DOMAINS < <(grep "^DOMAIN_" "$ENV_FILE" | cut -d'=' -f2)
    readonly DOMAINS
}

# Listar backups disponibles
list_backups() {
    echo ""
    log "═══════════════════════════════════════════════════════════════"
    log "BACKUPS DISPONIBLES"
    log "═══════════════════════════════════════════════════════════════"
    echo ""

    local backups=($(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r))

    if [[ ${#backups[@]} -eq 0 ]]; then
        warning "No hay backups disponibles"
        exit 0
    fi

    local counter=1
    for backup in "${backups[@]}"; do
        local name=$(basename "$backup")
        local date=$(echo "$name" | sed 's/_/ /g')
        local size=$(du -sh "$backup" | cut -f1)
        echo "  $counter) $date ($size)"
        ((counter++))
    done

    echo ""
}

# Seleccionar backup
select_backup() {
    local backups=($(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r))

    read -rp "Selecciona el número de backup a restaurar: " selection

    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ $selection -lt 1 ]] || [[ $selection -gt ${#backups[@]} ]]; then
        error "Selección inválida"
    fi

    echo "${backups[$((selection - 1))]}"
}

# Confirmar restauración
confirm_restore() {
    local backup_dir="$1"
    local backup_name=$(basename "$backup_dir")

    echo ""
    warning "⚠️  ADVERTENCIA ⚠️"
    warning "Esto SOBRESCRIBIRÁ los datos actuales con el backup: $backup_name"
    echo ""
    read -rp "¿Estás seguro? Escribe 'RESTAURAR' para continuar: " confirmation

    if [[ "$confirmation" != "RESTAURAR" ]]; then
        info "Restauración cancelada"
        exit 0
    fi
}

# Restaurar bases de datos
restore_databases() {
    local backup_dir="$1"
    local db_dir="${backup_dir}/databases"

    log "Restaurando bases de datos..."
    echo ""

    for i in "${!DOMAINS[@]}"; do
        local site_num=$((i + 1))
        local db_name="wp_sitio${site_num}"
        local backup_file="${db_dir}/${db_name}.sql.gz"

        if [[ ! -f "$backup_file" ]]; then
            warning "  ⚠ Backup no encontrado: $db_name"
            continue
        fi

        info "  → Restaurando: $db_name"

        # Eliminar base de datos existente
        docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
            -e "DROP DATABASE IF EXISTS $db_name;" 2>/dev/null || true

        # Crear base de datos
        docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
            -e "CREATE DATABASE $db_name CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || {
            warning "    ⚠ Error al crear $db_name"
            continue
        }

        # Restaurar datos
        gunzip < "$backup_file" | docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" "$db_name" || {
            warning "    ⚠ Error al restaurar $db_name"
            continue
        }

        success "    ✓ $db_name restaurado"
    done

    echo ""
    success "✓ Bases de datos restauradas"
}

# Restaurar archivos
restore_files() {
    local backup_dir="$1"
    local files_dir="${backup_dir}/files"

    log "Restaurando archivos..."
    echo ""

    # Crear backup temporal de archivos actuales
    info "  → Creando backup temporal de archivos actuales..."
    local temp_backup="/tmp/wordpress_temp_backup_$(date +%s)"
    mkdir -p "$temp_backup"
    cp -r www "$temp_backup/" 2>/dev/null || true
    success "    ✓ Backup temporal creado en: $temp_backup"

    # Restaurar cada sitio
    for i in "${!DOMAINS[@]}"; do
        local site_num=$((i + 1))
        local backup_file="${files_dir}/sitio${site_num}.tar.gz"

        if [[ ! -f "$backup_file" ]]; then
            warning "  ⚠ Backup no encontrado: sitio${site_num}"
            continue
        fi

        info "  → Restaurando: sitio${site_num}"

        # Eliminar directorio actual
        rm -rf "www/sitio${site_num}"

        # Extraer backup
        tar -xzf "$backup_file" -C www/ || {
            warning "    ⚠ Error al restaurar sitio${site_num}"
            continue
        }

        success "    ✓ sitio${site_num} restaurado"
    done

    # Restaurar configuraciones
    local configs_backup="${files_dir}/configs.tar.gz"
    if [[ -f "$configs_backup" ]]; then
        info "  → Restaurando configuraciones..."
        tar -xzf "$configs_backup" -C . nginx/ php/ mysql/ 2>/dev/null || true
        success "    ✓ Configuraciones restauradas"
    fi

    echo ""
    success "✓ Archivos restaurados"
    info "  Backup temporal disponible en: $temp_backup"
}

# Ajustar permisos después de restaurar
fix_permissions() {
    log "Ajustando permisos..."

    chown -R www-data:www-data www/ 2>/dev/null || chown -R 33:33 www/
    find www/ -type d -exec chmod 755 {} \;
    find www/ -type f -exec chmod 644 {} \;

    # Configurar uploads
    for i in "${!DOMAINS[@]}"; do
        local site_num=$((i + 1))
        local uploads_dir="www/sitio${site_num}/wp-content/uploads"

        if [[ -d "$uploads_dir" ]]; then
            chmod 775 "$uploads_dir"
            find "$uploads_dir" -type d -exec chmod 775 {} \;
        fi
    done

    success "✓ Permisos ajustados"
}

# Reiniciar contenedores
restart_containers() {
    log "Reiniciando contenedores..."

    docker compose restart php nginx || warning "Error al reiniciar contenedores"

    success "✓ Contenedores reiniciados"
}

# Mostrar resumen
show_summary() {
    local backup_dir="$1"

    echo ""
    log "═══════════════════════════════════════════════════════════════"
    log "RESTAURACIÓN COMPLETADA"
    log "═══════════════════════════════════════════════════════════════"
    echo ""

    success "Backup restaurado desde: $(basename "$backup_dir")"
    echo ""

    info "Sitios restaurados:"
    for i in "${!DOMAINS[@]}"; do
        local site_num=$((i + 1))
        echo "  ✓ sitio${site_num}: http://${DOMAINS[$i]}"
    done
    echo ""

    info "Siguiente paso:"
    echo "  Verifica que los sitios funcionen correctamente"
    echo "  Si algo salió mal, los archivos originales están en:"
    echo "  /tmp/wordpress_temp_backup_*"
    echo ""
}

# Main
main() {
    log "🔄 Iniciando restauración de backup..."

    check_requirements
    load_env
    list_backups

    local backup_dir
    backup_dir=$(select_backup)

    confirm_restore "$backup_dir"

    echo ""
    restore_databases "$backup_dir"
    restore_files "$backup_dir"
    fix_permissions
    restart_containers
    show_summary "$backup_dir"

    success "✓ Restauración completada exitosamente"
}

main "$@"