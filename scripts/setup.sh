#!/bin/bash

################################################################################
# WordPress Multi-Site - Setup WordPress (REFACTORIZADO)
# Descarga WordPress y configura sitios usando plantillas
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
readonly WP_DOWNLOAD="/tmp/latest.tar.gz"

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
declare -A DOMAIN_CACHE=()       # Caché: domain -> sanitized (renombrado para evitar conflicto)
declare -A SFTP_PASSWORDS=()     # Caché: domain -> password
declare -A DB_PASSWORDS=()       # Caché: domain -> password
declare MYSQL_ROOT_PASSWORD="" SERVER_IP=""

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

# Verificar comando existe
cmd_exists() { command -v "$1" &>/dev/null; }

# ══════════════════════════════════════════════════════════════════════════════
# VERIFICACIONES
# ══════════════════════════════════════════════════════════════════════════════

check_requirements() {
    cd "$PROJECT_DIR" || error "No se pudo acceder a: $PROJECT_DIR"
    [[ -f "$ENV_FILE" ]] || error "Archivo .env no encontrado"
    [[ -d "$TEMPLATE_DIR" ]] || error "Directorio templates/ no encontrado"
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

        i=$((i + 1))  # FIX: Forma segura de incrementar
    done

    success "Variables cargadas: ${#DOMAINS[@]} dominios"
}

# ══════════════════════════════════════════════════════════════════════════════
# DESCARGA DE WORDPRESS
# ══════════════════════════════════════════════════════════════════════════════

download_wordpress() {
    banner "══ PASO 1: Descargando WordPress ══"

    # Eliminar archivo previo
    rm -f "$WP_DOWNLOAD"

    log "Descargando WordPress en español..."
    if ! wget -q https://es.wordpress.org/latest-es_ES.tar.gz -O "$WP_DOWNLOAD"; then
        error "Error al descargar WordPress"
    fi

    # Verificar descarga
    if file "$WP_DOWNLOAD" | grep -q "gzip"; then
        success "WordPress en español descargado"
    else
        error "Archivo descargado no es válido"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURACIÓN DE SITIOS
# ══════════════════════════════════════════════════════════════════════════════

setup_site() {
    local domain="$1"
    local site_num="$2"
    local san="${DOMAIN_CACHE[$domain]}"
    local site_dir="www/$san"

    log "  Configurando: $domain → $san"

    # Verificar si ya existe
    if [[ -d "$site_dir" ]]; then
        warning "    Directorio ya existe, omitiendo..."
        return 0
    fi

    mkdir -p "$site_dir"

    # Extraer WordPress
    tar -xzf "$WP_DOWNLOAD" -C /tmp/
    cp -r /tmp/wordpress/* "$site_dir/"
    success "    WordPress extraído"

    # Generar wp-config.php
    generate_wp_config "$domain" "$site_num" "$san" "$site_dir"
}

generate_wp_config() {
    local domain="$1"
    local site_num="$2"
    local san="$3"
    local site_dir="$4"

    log "    Generando wp-config.php..."

    # Verificar plantilla
    [[ -f "${TEMPLATE_DIR}/wp-config.php.template" ]] || error "Plantilla wp-config.php.template no encontrada"

    # Obtener salt keys
    local salt_keys
    salt_keys=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/) || salt_keys="/* Error obteniendo salt keys - regenerar manualmente */"

    # Obtener credenciales desde caché o variable
    local db_password="${DB_PASSWORDS[$domain]:-}"
    [[ -z "$db_password" ]] && {
        local db_pw_var="DB_PASSWORD_$site_num"
        db_password="${!db_pw_var:-}"
    }

    local sftp_password="${SFTP_PASSWORDS[$domain]:-}"
    [[ -z "$sftp_password" ]] && {
        local sftp_pw_var="SFTP_${san^^}_PASSWORD"
        sftp_password="${!sftp_pw_var:-}"
    }

    # Exportar variables para envsubst
    export DOMAIN="$domain"
    export SITE_NUM="$site_num"
    export DOMAIN_SANITIZED="$san"
    export DB_NAME="$san"
    export DB_USER="wpuser_$san"
    export DB_PASSWORD="$db_password"
    export DATE="$(date)"
    export SALT_KEYS="$salt_keys"
    export SFTP_USER="sftp_$san"
    export SFTP_PASSWORD="$sftp_password"
    export SFTP_HOST="${SERVER_IP}"
    export SFTP_PORT="2222"

    # Generar wp-config.php
    envsubst '${DOMAIN} ${SITE_NUM} ${DOMAIN_SANITIZED} ${DB_NAME} ${DB_USER} ${DB_PASSWORD} ${DATE} ${SALT_KEYS} ${SFTP_USER} ${SFTP_PASSWORD} ${SFTP_HOST} ${SFTP_PORT}' \
        < "${TEMPLATE_DIR}/wp-config.php.template" > "${site_dir}/wp-config.php"

    # Limpiar exports
    unset DOMAIN SITE_NUM DOMAIN_SANITIZED DB_NAME DB_USER DB_PASSWORD DATE SALT_KEYS SFTP_USER SFTP_PASSWORD SFTP_HOST SFTP_PORT

    success "    wp-config.php generado"
}

setup_all_sites() {
    banner "══ PASO 2: Configurando sitios ══"

    local i=1
    for domain in "${DOMAINS[@]}"; do
        setup_site "$domain" "$i"
        i=$((i + 1))  # FIX: Forma segura de incrementar
    done

    # Limpiar archivos temporales
    rm -rf /tmp/wordpress

    success "Todos los sitios configurados"
}

# ══════════════════════════════════════════════════════════════════════════════
# DOCKER CONTAINERS
# ══════════════════════════════════════════════════════════════════════════════

start_containers() {
    banner "══ PASO 3: Iniciando contenedores Docker ══"

    # Detener si están corriendo
    if docker compose ps -q 2>/dev/null | grep -q .; then
        log "Deteniendo contenedores existentes..."
        docker compose down 2>/dev/null || true
    fi

    log "Iniciando contenedores..."
    docker compose up -d || error "Error al iniciar contenedores"

    success "Contenedores iniciados"
}

wait_for_mysql() {
    banner "══ PASO 4: Esperando MySQL ══"

    local max_attempts=90
    local attempt=1  # FIX: Empezar en 1 en lugar de 0

    while [[ $attempt -le $max_attempts ]]; do
        if docker compose exec -T mysql mysqladmin ping -h localhost -u root -p"${MYSQL_ROOT_PASSWORD}" &>/dev/null; then
            success "MySQL está listo"
            log "Esperando 10s para scripts de inicialización..."
            sleep 10
            return 0
        fi

        if [[ $((attempt % 10)) -eq 0 ]]; then
            log "  Intento $attempt de $max_attempts..."
        fi

        attempt=$((attempt + 1))  # FIX: Forma segura de incrementar
        sleep 2
    done

    error "Timeout esperando MySQL. Ver logs: docker compose logs mysql"
}

# ══════════════════════════════════════════════════════════════════════════════
# VERIFICACIÓN DE BASES DE DATOS
# ══════════════════════════════════════════════════════════════════════════════

verify_databases() {
    banner "══ PASO 5: Verificando bases de datos ══"

    local i=1
    for domain in "${DOMAINS[@]}"; do
        local san="${DOMAIN_CACHE[$domain]}"
        local db_name="$san"
        local db_user="wpuser_$san"
        local db_password="${DB_PASSWORDS[$domain]:-}"

        # Fallback si no está en caché
        [[ -z "$db_password" ]] && {
            local db_pw_var="DB_PASSWORD_$i"
            db_password="${!db_pw_var:-}"
        }

        log "  Configurando: $domain → DB: $db_name | User: $db_user"

        # Eliminar usuario previo si existe
        docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
            -e "DROP USER IF EXISTS '${db_user}'@'%';" 2>/dev/null || true

        # Crear base de datos
        if ! docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
            -e "CREATE DATABASE IF NOT EXISTS $db_name CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; then
            warning "    No se pudo crear DB: $db_name"
            i=$((i + 1))
            continue
        fi

        # Crear usuario
        if ! docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
            -e "CREATE USER '${db_user}'@'%' IDENTIFIED BY '${db_password}';"; then
            warning "    No se pudo crear usuario: $db_user"
            i=$((i + 1))
            continue
        fi

        # Otorgar permisos
        if ! docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
            -e "GRANT ALL PRIVILEGES ON $db_name.* TO '${db_user}'@'%';"; then
            warning "    No se pudieron otorgar permisos"
            i=$((i + 1))
            continue
        fi

        success "    $db_name configurada"
        i=$((i + 1))  # FIX: Forma segura de incrementar
    done

    # Aplicar cambios
    docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
        -e "FLUSH PRIVILEGES;" 2>/dev/null || warning "No se pudo ejecutar FLUSH PRIVILEGES"

    success "Verificación de bases de datos completada"
}

# ══════════════════════════════════════════════════════════════════════════════
# VERIFICACIÓN PHP
# ══════════════════════════════════════════════════════════════════════════════

verify_php_connection() {
    banner "══ PASO 6: Verificando conexión PHP ══"

    local i=1
    for domain in "${DOMAINS[@]}"; do
        local san="${DOMAIN_CACHE[$domain]}"
        local db_name="$san"
        local db_user="wpuser_$san"
        local db_password="${DB_PASSWORDS[$domain]:-}"

        # Fallback
        [[ -z "$db_password" ]] && {
            local db_pw_var="DB_PASSWORD_$i"
            db_password="${!db_pw_var:-}"
        }

        local test_script="www/$san/test-db.php"

        log "  Probando conexión a $db_name..."

        # Crear script de prueba
        cat > "$test_script" << EOF
<?php
\$conn = new mysqli('mysql', '${db_user}', '${db_password}', '${db_name}');
echo \$conn->connect_error ? "ERROR: ".\$conn->connect_error."\n" : "OK\n";
\$conn->close();
EOF

        # Ejecutar test
        local result
        result=$(docker compose exec -T php php "/var/www/html/$san/test-db.php" 2>&1) || true

        if echo "$result" | grep -q "^OK"; then
            success "    Conexión exitosa a $db_name"
        else
            warning "    Problema de conexión a $db_name"
            if [[ -n "$result" ]]; then
                echo "$result" | head -3 | while IFS= read -r line; do
                    warning "      $line"
                done
            fi
        fi

        rm -f "$test_script"
        i=$((i + 1))  # FIX: Forma segura de incrementar
    done

    success "Verificación de conexiones PHP completada"
}

# ══════════════════════════════════════════════════════════════════════════════
# RESUMEN FINAL
# ══════════════════════════════════════════════════════════════════════════════

show_summary() {
    banner "╔══════════════════════════════════════════════════════════════════╗"
    banner "║              ✓ SETUP COMPLETADO EXITOSAMENTE ✓                   ║"
    banner "╚══════════════════════════════════════════════════════════════════╝"

    echo -e "\n${GREEN}Contenedores en ejecución:${NC}"
    docker compose ps
    echo ""

    echo -e "${YELLOW}Sitios configurados:${NC}"
    local i=1
    for domain in "${DOMAINS[@]}"; do
        local san="${DOMAIN_CACHE[$domain]}"
        echo "  $i. $domain → http://$domain"
        echo "     Carpeta: $san | DB: $san | User: wpuser_$san"
        i=$((i + 1))  # FIX
    done

    echo -e "\n${YELLOW}CREDENCIALES:${NC}"
    echo "  MySQL Root: root / ${MYSQL_ROOT_PASSWORD}"
    echo ""
    echo "  Usuarios MySQL por sitio:"
    i=1
    for domain in "${DOMAINS[@]}"; do
        local san="${DOMAIN_CACHE[$domain]}"
        local password="${DB_PASSWORDS[$domain]:-}"
        [[ -z "$password" ]] && {
            local pw_var="DB_PASSWORD_$i"
            password="${!pw_var:-N/A}"
        }
        echo "    $domain: wpuser_$san / $password"
        i=$((i + 1))  # FIX
    done

    echo ""
    echo "  SFTP (usuarios independientes):"
    for domain in "${DOMAINS[@]}"; do
        local san="${DOMAIN_CACHE[$domain]}"
        local password="${SFTP_PASSWORDS[$domain]:-}"
        [[ -z "$password" ]] && password=$(grep "^SFTP_${san^^}_PASSWORD=" "$ENV_FILE" | cut -d'=' -f2)
        echo "    $domain: sftp_$san / ${password:-N/A}"
    done

    echo -e "\n${YELLOW}ACCESO A SERVICIOS:${NC}"
    echo "  phpMyAdmin: http://${DOMAINS[0]}/phpmyadmin/"
    echo "  SFTP: ${SERVER_IP}:2222"

    echo -e "\n${BLUE}NOTA:${NC} Los permisos se configurarán en install.sh → set_wordpress_permissions()"

    echo -e "\n${GREEN}PRÓXIMOS PASOS:${NC}"
    echo "  1. Apuntar DNS de dominios a: ${SERVER_IP}"
    echo "  2. Ejecutar: ./scripts/setup-ssl.sh"
    echo "  3. Completar instalación WordPress en:"
    for domain in "${DOMAINS[@]}"; do
        echo "     - http://$domain/wp-admin/install.php"
    done

    echo -e "\n${YELLOW}COMANDOS ÚTILES:${NC}"
    echo "  Ver logs: docker compose logs [servicio]"
    echo "  MySQL CLI: docker compose exec mysql mysql -uroot -p${MYSQL_ROOT_PASSWORD}"
    echo "  Gestión: docker compose [start|stop|restart]"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

main() {
    banner "══ SETUP DE WORDPRESS MULTI-SITE ══"

    check_requirements
    load_env
    download_wordpress
    setup_all_sites
    start_containers
    wait_for_mysql
    verify_databases
    verify_php_connection
    show_summary
}

main "$@"