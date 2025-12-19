#!/bin/bash

################################################################################
# WordPress Multi-Site - Generador de Configuraciones (REFACTORIZADO)
# Usa plantillas externas y patrones de eficiencia
# Armonizado con auto-install-refactored.sh
################################################################################

set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURACIÓN Y CONSTANTES
# ══════════════════════════════════════════════════════════════════════════════

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd || pwd)"
readonly TEMPLATE_DIR="${PROJECT_DIR}/templates"
readonly ENV_FILE="${PROJECT_DIR}/.env"

# Colores (con fallback para no-TTY)
if [[ -t 1 ]]; then
    readonly RED=$'\e[0;31m' GREEN=$'\e[0;32m' YELLOW=$'\e[1;33m'
    readonly BLUE=$'\e[0;34m' CYAN=$'\e[0;36m' NC=$'\e[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
fi

# ══════════════════════════════════════════════════════════════════════════════
# VARIABLES GLOBALES (arrays asociativos para caché)
# ══════════════════════════════════════════════════════════════════════════════

declare -a DOMAINS=()
declare -A DOMAIN_CACHE=()       # Caché: domain -> sanitized (renombrado para evitar conflicto con envsubst)
declare -A SFTP_PASSWORDS=()     # Caché: domain -> password
declare -A DB_PASSWORDS=()       # Caché: domain -> password
declare MYSQL_ROOT_PASSWORD="" SERVER_IP=""
declare PHPMYADMIN_AUTH_USER="" PHPMYADMIN_AUTH_PASSWORD=""

# ══════════════════════════════════════════════════════════════════════════════
# FUNCIONES DE UTILIDAD
# ══════════════════════════════════════════════════════════════════════════════

# Logging unificado
_log() {
    local level="$1" color="$2" msg="${*:3}"
    printf '%b[%s][%s]%b %s\n' "$color" "$(date +%T)" "$level" "$NC" "$msg"
}
log()     { _log "INFO" "$GREEN" "$@"; }
error()   { _log "ERROR" "$RED" "$@"; exit 1; }
warning() { _log "WARN" "$YELLOW" "$@"; }
info()    { _log "INFO" "$BLUE" "$@"; }
success() { _log "OK" "$GREEN" "✓ $*"; }
banner()  { echo -e "\n${CYAN}$*${NC}"; }

# Sanitizar dominio (bash puro, sin subshell para caché)
sanitize_domain() {
    local domain="$1"
    local sanitized="${domain//./_}"
    sanitized="${sanitized//-/_}"
    sanitized="${sanitized//[^a-zA-Z0-9_]/}"
    echo "${sanitized,,}"  # Lowercase
}

# Pre-poblar caché de dominios sanitizados
populate_domain_cache() {
    for domain in "${DOMAINS[@]}"; do
        DOMAIN_CACHE[$domain]=$(sanitize_domain "$domain")
    done
}

# Generar contraseña
generate_password() {
    local length="${1:-24}"
    if command -v pwgen &>/dev/null; then
        pwgen -s "$length" 1
    else
        head -c 100 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$length"
    fi
}

# Verificar comando existe
cmd_exists() { command -v "$1" &>/dev/null; }

# ══════════════════════════════════════════════════════════════════════════════
# VERIFICACIONES
# ══════════════════════════════════════════════════════════════════════════════

check_requirements() {
    cd "$PROJECT_DIR" || error "No se pudo acceder a: $PROJECT_DIR"
    [[ -f "$ENV_FILE" ]] || error "Archivo .env no encontrado"
    [[ -d "$TEMPLATE_DIR" ]] || error "Directorio templates/ no encontrado"

    # ══════════════════════════════════════════════════════════════════════════
    # FIX: Verificar que los templates necesarios existen
    # ══════════════════════════════════════════════════════════════════════════
    local required_templates=(
        "docker-compose.yml.template"
        "nginx.conf.template"
        "vhost-http.conf.template"
        "vhost-https.conf.template"
        "phpmyadmin-http.conf.template"
        "phpmyadmin-https.conf.template"
        "php.ini.template"
        "www.conf.template"
        "my.cnf.template"
        "wp-config.php.template"
        "gitignore.template"
    )

    for template in "${required_templates[@]}"; do
        if [[ ! -f "${TEMPLATE_DIR}/${template}" ]]; then
            error "Template faltante: ${TEMPLATE_DIR}/${template}"
        fi
    done

    if ! cmd_exists htpasswd; then
        warning "Instalando apache2-utils..."
        apt-get update -qq && apt-get install -y -qq apache2-utils
    fi

    if ! cmd_exists pwgen; then
        warning "Instalando pwgen..."
        apt-get install -y -qq pwgen
    fi

    success "Requisitos verificados"
}

# ══════════════════════════════════════════════════════════════════════════════
# CARGA DE VARIABLES
# ══════════════════════════════════════════════════════════════════════════════

load_env() {
    log "Cargando variables de entorno..."

    # Exportar variables del .env
    set -a
    source "$ENV_FILE"
    set +a

    # Cargar array de dominios
    mapfile -t DOMAINS < <(grep "^DOMAIN_" "$ENV_FILE" | cut -d'=' -f2)
    [[ ${#DOMAINS[@]} -eq 0 ]] && error "No hay dominios configurados en .env"

    # Pre-poblar caché
    populate_domain_cache

    # Cargar credenciales existentes a arrays asociativos
    local i=1
    for domain in "${DOMAINS[@]}"; do
        local san="${DOMAIN_CACHE[$domain]}"
        local san_upper="${san^^}"

        # DB Password
        local db_pw_var="DB_PASSWORD_$i"
        [[ -n "${!db_pw_var:-}" ]] && DB_PASSWORDS[$domain]="${!db_pw_var}"

        # SFTP Password
        local sftp_pw_var="SFTP_${san_upper}_PASSWORD"
        [[ -n "${!sftp_pw_var:-}" ]] && SFTP_PASSWORDS[$domain]="${!sftp_pw_var}"

        ((i++)) || true  # FIX: Prevenir fallo con set -e cuando i=0
    done

    success "Variables cargadas: ${#DOMAINS[@]} dominios"
}

# ══════════════════════════════════════════════════════════════════════════════
# SETUP CREDENCIALES
# ══════════════════════════════════════════════════════════════════════════════

setup_phpmyadmin_credentials() {
    log "Configurando phpMyAdmin..."

    # Verificar si ya existe
    if ! grep -q "^PHPMYADMIN_AUTH_USER=" "$ENV_FILE" 2>/dev/null; then
        PHPMYADMIN_AUTH_USER="phpmyadmin"
        PHPMYADMIN_AUTH_PASSWORD=$(generate_password 16)

        {
            echo ""
            echo "# phpMyAdmin Authentication"
            echo "PHPMYADMIN_AUTH_USER=$PHPMYADMIN_AUTH_USER"
            echo "PHPMYADMIN_AUTH_PASSWORD=$PHPMYADMIN_AUTH_PASSWORD"
        } >> "$ENV_FILE"

        info "Nuevo usuario phpMyAdmin: $PHPMYADMIN_AUTH_USER"
    else
        PHPMYADMIN_AUTH_USER=$(grep "^PHPMYADMIN_AUTH_USER=" "$ENV_FILE" | cut -d'=' -f2)
        PHPMYADMIN_AUTH_PASSWORD=$(grep "^PHPMYADMIN_AUTH_PASSWORD=" "$ENV_FILE" | cut -d'=' -f2)
    fi

    # Crear htpasswd
    mkdir -p nginx/auth
    htpasswd -bc nginx/auth/.htpasswd "$PHPMYADMIN_AUTH_USER" "$PHPMYADMIN_AUTH_PASSWORD" 2>/dev/null
    chmod 644 nginx/auth/.htpasswd

    # PMA_ABSOLUTE_URI si no existe
    if ! grep -q "^PMA_ABSOLUTE_URI=" "$ENV_FILE" 2>/dev/null && [[ -n "${DOMAINS[0]:-}" ]]; then
        {
            echo ""
            echo "# phpMyAdmin Configuration"
            echo "PMA_ABSOLUTE_URI=http://${DOMAINS[0]}/phpmyadmin/"
        } >> "$ENV_FILE"
    fi

    success "phpMyAdmin configurado"
}

setup_db_credentials() {
    log "Configurando credenciales de base de datos..."

    if grep -q "^DB_PASSWORD_1=" "$ENV_FILE" 2>/dev/null; then
        success "Credenciales DB ya existen"
        return 0
    fi

    {
        echo ""
        echo "# Database passwords por sitio"
    } >> "$ENV_FILE"

    local i=1
    for domain in "${DOMAINS[@]}"; do
        local password
        password=$(generate_password 24)
        DB_PASSWORDS[$domain]="$password"
        echo "DB_PASSWORD_$i=$password" >> "$ENV_FILE"
        ((i++)) || true  # FIX: Prevenir fallo con set -e
    done

    # Recargar variables
    set -a; source "$ENV_FILE"; set +a

    success "Credenciales DB generadas"
}

setup_sftp_credentials() {
    log "Configurando usuarios SFTP..."

    local first_san="${DOMAIN_CACHE[${DOMAINS[0]}]}"
    if grep -q "^SFTP_${first_san^^}_PASSWORD=" "$ENV_FILE" 2>/dev/null; then
        success "Credenciales SFTP ya existen"
        return 0
    fi

    {
        echo ""
        echo "# SFTP - Usuarios independientes por sitio"
    } >> "$ENV_FILE"

    for domain in "${DOMAINS[@]}"; do
        local san="${DOMAIN_CACHE[$domain]}"
        local password
        password=$(generate_password 24)
        SFTP_PASSWORDS[$domain]="$password"
        echo "SFTP_${san^^}_PASSWORD=$password" >> "$ENV_FILE"
        info "  Usuario: sftp_$san"
    done

    # Recargar variables
    set -a; source "$ENV_FILE"; set +a

    success "Credenciales SFTP generadas"
}

# ══════════════════════════════════════════════════════════════════════════════
# GENERACIÓN DE CONFIGURACIONES
# ══════════════════════════════════════════════════════════════════════════════

generate_docker_compose() {
    log "Generando docker-compose.yml..."

    # Construir volúmenes y usuarios SFTP
    local sftp_volumes="" sftp_users=""

    for domain in "${DOMAINS[@]}"; do
        local san="${DOMAIN_CACHE[$domain]}"
        local password="${SFTP_PASSWORDS[$domain]:-}"

        # Fallback si no está en cache
        [[ -z "$password" ]] && password=$(grep "^SFTP_${san^^}_PASSWORD=" "$ENV_FILE" | cut -d'=' -f2)

        sftp_volumes+="      - ./www/${san}:/home/sftp_${san}/${san}:rw"$'\n'
        sftp_users+="      sftp_${san}:${password}:82:82:${san}"$'\n'
    done

    # Eliminar último newline
    sftp_volumes="${sftp_volumes%$'\n'}"
    sftp_users="${sftp_users%$'\n'}"

    # Exportar variables para envsubst
    export MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
    export DB_PASSWORD="${DB_PASSWORDS[${DOMAINS[0]}]:-${DB_PASSWORD_1:-}}"
    export SERVER_IP="${SERVER_IP:-}"
    export PMA_ABSOLUTE_URI="${PMA_ABSOLUTE_URI:-http://${DOMAINS[0]}/phpmyadmin/}"
    export SFTP_VOLUMES="$sftp_volumes"
    export SFTP_USERS="$sftp_users"

    envsubst '${MYSQL_ROOT_PASSWORD} ${DB_PASSWORD} ${SERVER_IP} ${PMA_ABSOLUTE_URI} ${SFTP_VOLUMES} ${SFTP_USERS}' \
        < "${TEMPLATE_DIR}/docker-compose.yml.template" > docker-compose.yml

    success "docker-compose.yml"
}

generate_nginx_conf() {
    log "Generando nginx.conf..."
    cp "${TEMPLATE_DIR}/nginx.conf.template" nginx/nginx.conf
    success "nginx.conf"
}

generate_vhost() {
    local domain="$1"
    local site_num="$2"
    local is_first="$3"
    local san="${DOMAIN_CACHE[$domain]}"
    local output_file="nginx/conf.d/${domain}.conf"

    info "  → $domain → $san"

    # ══════════════════════════════════════════════════════════════════════════
    # FIX: Verificar que el directorio de salida existe
    # ══════════════════════════════════════════════════════════════════════════
    mkdir -p "$(dirname "$output_file")"

    # Exportar variables para plantillas
    export DOMAIN="$domain"
    export SITE_NUM="$site_num"
    export DOMAIN_SANITIZED="$san"
    export DATE
    DATE="$(date)"

    # ══════════════════════════════════════════════════════════════════════════
    # FIX: Verificar existencia del template antes de usarlo
    # ══════════════════════════════════════════════════════════════════════════
    local http_template="${TEMPLATE_DIR}/vhost-http.conf.template"
    local https_template="${TEMPLATE_DIR}/vhost-https.conf.template"
    local pma_http_template="${TEMPLATE_DIR}/phpmyadmin-http.conf.template"
    local pma_https_template="${TEMPLATE_DIR}/phpmyadmin-https.conf.template"

    [[ -f "$http_template" ]] || error "Template no encontrado: $http_template"

    # Generar bloque HTTP
    envsubst '${DOMAIN} ${SITE_NUM} ${DOMAIN_SANITIZED} ${DATE}' \
        < "$http_template" | sed 's/\$\$/$/g' > "$output_file"

    # phpMyAdmin si es primer dominio
    if [[ "$is_first" == "true" ]]; then
        [[ -f "$pma_http_template" ]] || error "Template no encontrado: $pma_http_template"
        sed 's/\$\$/$/g' "$pma_http_template" >> "$output_file"
    else
        echo "}" >> "$output_file"
    fi

    # Bloque HTTPS (comentado)
    echo "" >> "$output_file"
    if [[ -f "$https_template" ]]; then
        envsubst '${DOMAIN} ${SITE_NUM} ${DOMAIN_SANITIZED} ${DATE}' \
            < "$https_template" | sed 's/\$\$/$/g' >> "$output_file"
    fi

    if [[ "$is_first" == "true" ]]; then
        [[ -f "$pma_https_template" ]] && sed 's/\$\$/$/g' "$pma_https_template" >> "$output_file"
    else
        echo "# }" >> "$output_file"
    fi

    unset DOMAIN SITE_NUM DOMAIN_SANITIZED DATE
}

generate_vhosts() {
    log "Generando virtual hosts..."

    # ══════════════════════════════════════════════════════════════════════════
    # FIX: Usar forma segura de determinar is_first (evita problemas con set -e)
    # ══════════════════════════════════════════════════════════════════════════
    local i=0
    local is_first
    for domain in "${DOMAINS[@]}"; do
        local site_num=$((i + 1))

        # FIX: Forma segura que no falla con set -e
        if [[ $i -eq 0 ]]; then
            is_first="true"
        else
            is_first="false"
        fi

        generate_vhost "$domain" "$site_num" "$is_first"
        i=$((i + 1))  # FIX: Usar $(()) en lugar de ((i++)) para evitar problemas con set -e cuando i=0
    done

    success "${#DOMAINS[@]} virtual hosts generados"
}

generate_php_configs() {
    log "Generando configuraciones PHP..."
    cp "${TEMPLATE_DIR}/php.ini.template" php/php.ini
    cp "${TEMPLATE_DIR}/www.conf.template" php/www.conf
    success "php.ini y www.conf"
}

generate_mysql_configs() {
    log "Generando configuraciones MySQL..."

    cp "${TEMPLATE_DIR}/my.cnf.template" mysql/my.cnf

    # Script de inicialización
    {
        echo "-- Script de inicialización de bases de datos WordPress"
        echo "-- Generado: $(date)"
        echo "-- NOTA: Los usuarios se crean desde setup.sh"
        echo ""
        echo "-- Crear bases de datos"

        for domain in "${DOMAINS[@]}"; do
            local san="${DOMAIN_CACHE[$domain]}"
            echo "CREATE DATABASE IF NOT EXISTS ${san} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        done

        echo ""
        echo "-- Fin de inicialización"
    } > mysql/init/01-init-databases.sql

    success "Configuraciones MySQL"
}

generate_gitignore() {
    log "Generando .gitignore..."
    cp "${TEMPLATE_DIR}/gitignore.template" .gitignore
    success ".gitignore"
}

# ══════════════════════════════════════════════════════════════════════════════
# RESUMEN
# ══════════════════════════════════════════════════════════════════════════════

show_summary() {
    banner "╔══════════════════════════════════════════════════════════════════╗"
    banner "║              ✓ CONFIGURACIÓN COMPLETADA ✓                        ║"
    banner "╚══════════════════════════════════════════════════════════════════╝"

    echo -e "\n${YELLOW}phpMyAdmin:${NC}"
    echo "  URL: http://${DOMAINS[0]}/phpmyadmin/"
    echo "  Auth HTTP → Usuario: $PHPMYADMIN_AUTH_USER | Contraseña: $PHPMYADMIN_AUTH_PASSWORD"
    echo "  MySQL → Servidor: mysql | Usuario: root/wpuser_*"

    echo -e "\n${YELLOW}Usuarios MySQL por sitio:${NC}"
    local i=1
    for domain in "${DOMAINS[@]}"; do
        local san="${DOMAIN_CACHE[$domain]}"
        local password="${DB_PASSWORDS[$domain]:-}"
        [[ -z "$password" ]] && password=$(grep "^DB_PASSWORD_$i=" "$ENV_FILE" | cut -d'=' -f2)
        echo "  $domain:"
        echo "    DB: $san | User: wpuser_$san | Pass: $password"
        ((i++)) || true  # FIX
    done

    echo -e "\n${YELLOW}Usuarios SFTP independientes:${NC}"
    echo "  Host: $SERVER_IP:2222"
    for domain in "${DOMAINS[@]}"; do
        local san="${DOMAIN_CACHE[$domain]}"
        local password="${SFTP_PASSWORDS[$domain]:-}"
        [[ -z "$password" ]] && password=$(grep "^SFTP_${san^^}_PASSWORD=" "$ENV_FILE" | cut -d'=' -f2)
        echo "  $domain:"
        echo "    User: sftp_$san | Dir: /$san | Pass: $password"
    done

    echo -e "\n${GREEN}Siguiente paso:${NC} ./scripts/setup.sh\n"
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

main() {
    banner "══ GENERACIÓN DE CONFIGURACIONES ══"

    check_requirements
    load_env
    setup_phpmyadmin_credentials
    setup_db_credentials
    setup_sftp_credentials
    generate_docker_compose
    generate_nginx_conf
    generate_vhosts
    generate_php_configs
    generate_mysql_configs
    generate_gitignore

    success "Todas las configuraciones generadas"
    show_summary
}

main "$@"