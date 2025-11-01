#!/bin/bash
################################################################################
# verify-backup.sh - Script de verificación de integridad de backups
# Verifica que un backup tenga todos los componentes necesarios
################################################################################

set -euo pipefail

# --- Configuración ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd || pwd)"
ENV_FILE="${PROJECT_DIR}/.env"
BACKUP_ROOT="${PROJECT_DIR}/backups"

# --- Colores ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log(){ echo -e "${GREEN}[✓]${NC} $*"; }
info(){ echo -e "${BLUE}[ℹ]${NC} $*"; }
warn(){ echo -e "${YELLOW}[⚠]${NC} $*"; }
error(){ echo -e "${RED}[✗]${NC} $*"; }

# --- Función de sanitización ---
sanitize_domain_name() {
    local domain="$1"
    echo "$domain" | sed 's/\./_/g' | sed 's/-/_/g' | sed 's/[^a-zA-Z0-9_]//g' | tr '[:upper:]' '[:lower:]'
}

# --- Cargar entorno ---
declare -a DOMAINS=()
load_env(){
  [[ -f "$ENV_FILE" ]] || { error "No existe .env"; exit 1; }
  set -a; source "$ENV_FILE"; set +a
  mapfile -t DOMAINS < <(grep -E '^DOMAIN_' "$ENV_FILE" | cut -d'=' -f2 || true)
}

# --- Seleccionar backup ---
select_backup(){
  if [[ -n "${1:-}" ]]; then
    echo "$1"
    return
  fi

  if [[ ! -d "$BACKUP_ROOT" ]]; then
    error "No existe directorio de backups: $BACKUP_ROOT"
    exit 1
  fi

  local backups=($(ls -1t "$BACKUP_ROOT" 2>/dev/null || true))

  if [[ ${#backups[@]} -eq 0 ]]; then
    error "No hay backups disponibles"
    exit 1
  fi

  echo ""
  info "Backups disponibles:"
  echo ""
  for i in "${!backups[@]}"; do
    local idx=$((i+1))
    local name="${backups[$i]}"
    local size=$(du -sh "${BACKUP_ROOT}/${name}" 2>/dev/null | cut -f1)
    echo "  ${idx}. ${name} (${size})"
  done

  echo ""
  read -rp "Selecciona el número de backup a verificar [1]: " selection
  selection=${selection:-1}

  if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ $selection -lt 1 ]] || [[ $selection -gt ${#backups[@]} ]]; then
    error "Selección inválida"
    exit 1
  fi

  echo "${BACKUP_ROOT}/${backups[$((selection-1))]}"
}

# --- Detectar formato ---
detect_format(){
  local backup_dir="$1"
  local db_dir="${backup_dir}/databases"

  if ls "${db_dir}"/wp_sitio*.sql.gz &>/dev/null; then
    echo "legacy"
  elif ls "${db_dir}"/*.sql.gz &>/dev/null 2>&1; then
    echo "new"
  else
    echo "unknown"
  fi
}

# --- Verificar estructura ---
verify_structure(){
  local backup_dir="$1"
  local errors=0

  echo ""
  info "Verificando estructura del backup..."
  echo ""

  # Verificar directorios principales
  if [[ -d "${backup_dir}/databases" ]]; then
    log "Directorio databases/ existe"
  else
    error "Falta directorio databases/"
    ((errors++))
  fi

  if [[ -d "${backup_dir}/files" ]]; then
    log "Directorio files/ existe"
  else
    error "Falta directorio files/"
    ((errors++))
  fi

  return $errors
}

# --- Verificar bases de datos ---
verify_databases(){
  local backup_dir="$1"
  local format="$2"
  local errors=0

  echo ""
  info "Verificando bases de datos..."
  echo ""

  local db_dir="${backup_dir}/databases"

  # Verificar dump global
  if [[ -f "${db_dir}/ALL_DATABASES.sql.gz" ]]; then
    local size=$(du -h "${db_dir}/ALL_DATABASES.sql.gz" | cut -f1)
    log "Dump global encontrado (${size})"
  else
    warn "No se encontró dump global (ALL_DATABASES.sql.gz)"
  fi

  # Verificar dumps individuales
  if [[ "$format" == "new" ]]; then
    echo ""
    info "Verificando dumps individuales (formato nuevo)..."
    echo ""
    for i in "${!DOMAINS[@]}"; do
      local domain="${DOMAINS[$i]}"
      local domain_sanitized=$(sanitize_domain_name "$domain")
      local db_file="${db_dir}/${domain_sanitized}.sql.gz"

      if [[ -f "$db_file" ]]; then
        local size=$(du -h "$db_file" | cut -f1)
        log "${domain} → ${domain_sanitized}.sql.gz (${size})"
      else
        error "Falta dump de ${domain} (${domain_sanitized}.sql.gz)"
        ((errors++))
      fi
    done
  elif [[ "$format" == "legacy" ]]; then
    echo ""
    info "Verificando dumps individuales (formato antiguo)..."
    echo ""
    for i in "${!DOMAINS[@]}"; do
      local idx=$((i+1))
      local domain="${DOMAINS[$i]}"
      local db_file="${db_dir}/wp_sitio${idx}.sql.gz"

      if [[ -f "$db_file" ]]; then
        local size=$(du -h "$db_file" | cut -f1)
        log "${domain} → wp_sitio${idx}.sql.gz (${size})"
      else
        error "Falta dump de ${domain} (wp_sitio${idx}.sql.gz)"
        ((errors++))
      fi
    done
  fi

  return $errors
}

# --- Verificar archivos ---
verify_files(){
  local backup_dir="$1"
  local format="$2"
  local errors=0

  echo ""
  info "Verificando archivos de sitios..."
  echo ""

  local files_dir="${backup_dir}/files"

  # Verificar archivos de sitios
  if [[ "$format" == "new" ]]; then
    for i in "${!DOMAINS[@]}"; do
      local domain="${DOMAINS[$i]}"
      local domain_sanitized=$(sanitize_domain_name "$domain")
      local file="${files_dir}/${domain_sanitized}.tar.gz"

      if [[ -f "$file" ]]; then
        local size=$(du -h "$file" | cut -f1)
        log "${domain} → ${domain_sanitized}.tar.gz (${size})"
      else
        error "Falta archivo de ${domain} (${domain_sanitized}.tar.gz)"
        ((errors++))
      fi
    done
  elif [[ "$format" == "legacy" ]]; then
    for i in "${!DOMAINS[@]}"; do
      local idx=$((i+1))
      local domain="${DOMAINS[$i]}"
      local file="${files_dir}/sitio${idx}.tar.gz"

      if [[ -f "$file" ]]; then
        local size=$(du -h "$file" | cut -f1)
        log "${domain} → sitio${idx}.tar.gz (${size})"
      else
        error "Falta archivo de ${domain} (sitio${idx}.tar.gz)"
        ((errors++))
      fi
    done
  fi

  # Verificar configuraciones
  echo ""
  if [[ -f "${files_dir}/configs.tar.gz" ]]; then
    local size=$(du -h "${files_dir}/configs.tar.gz" | cut -f1)
    log "Configuraciones encontradas (${size})"
  else
    warn "No se encontró configs.tar.gz"
  fi

  return $errors
}

# --- Verificar integridad de archivos comprimidos ---
verify_integrity(){
  local backup_dir="$1"
  local errors=0

  echo ""
  info "Verificando integridad de archivos comprimidos..."
  echo ""

  # Verificar todos los .gz
  local count=0
  local failed=0

  while IFS= read -r -d '' file; do
    ((count++))
    if gzip -t "$file" 2>/dev/null; then
      :  # Archivo OK
    else
      error "Corrupto: $(basename "$file")"
      ((failed++))
      ((errors++))
    fi
  done < <(find "$backup_dir" -name "*.gz" -type f -print0)

  if [[ $failed -eq 0 ]]; then
    log "Todos los archivos comprimidos son válidos (${count} archivos)"
  else
    error "${failed} de ${count} archivos están corruptos"
  fi

  return $errors
}

# --- Resumen ---
show_summary(){
  local backup_dir="$1"
  local format="$2"
  local total_errors="$3"

  echo ""
  echo "════════════════════════════════════════════════════════════════"

  if [[ $total_errors -eq 0 ]]; then
    echo -e "${GREEN}✅ BACKUP VÁLIDO${NC}"
  else
    echo -e "${RED}❌ BACKUP CON ERRORES${NC}"
  fi

  echo "════════════════════════════════════════════════════════════════"
  echo ""

  info "Ubicación:"
  echo "  $backup_dir"
  echo ""

  info "Formato:"
  if [[ "$format" == "new" ]]; then
    echo "  Nuevo (basado en dominios sanitizados)"
  elif [[ "$format" == "legacy" ]]; then
    echo "  Antiguo (sitioN)"
  else
    echo "  Desconocido"
  fi
  echo ""

  info "Tamaño total:"
  local size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
  echo "  ${size}"
  echo ""

  info "Sitios configurados:"
  echo "  ${#DOMAINS[@]}"
  echo ""

  if [[ $total_errors -eq 0 ]]; then
    info "Estado: ✅ Listo para restaurar"
    echo ""
    echo "Para restaurar este backup:"
    echo "  ./scripts/restore.sh --backup $backup_dir"
  else
    warn "Estado: ⚠️ Hay ${total_errors} errores"
    echo ""
    echo "Revisa los errores antes de restaurar este backup"
  fi

  echo ""
}

# --- Main ---
main(){
  echo ""
  echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║${NC}  ${GREEN}Verificador de Integridad de Backups${NC}                      ${BLUE}║${NC}"
  echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"

  load_env

  if ((${#DOMAINS[@]} == 0)); then
    error "No hay dominios configurados en .env"
    exit 1
  fi

  local backup_dir
  backup_dir=$(select_backup "${1:-}")

  if [[ ! -d "$backup_dir" ]]; then
    error "El backup no existe: $backup_dir"
    exit 1
  fi

  local format
  format=$(detect_format "$backup_dir")

  local total_errors=0

  verify_structure "$backup_dir" || ((total_errors+=$?))
  verify_databases "$backup_dir" "$format" || ((total_errors+=$?))
  verify_files "$backup_dir" "$format" || ((total_errors+=$?))
  verify_integrity "$backup_dir" || ((total_errors+=$?))

  show_summary "$backup_dir" "$format" "$total_errors"

  exit $total_errors
}

main "$@"