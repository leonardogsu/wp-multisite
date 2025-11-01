#!/bin/bash

################################################################################
# Script refactorizado para generar configuraciones del proyecto
# Usa plantillas externas para máxima mantenibilidad
# VERSIÓN CORREGIDA - Con nombres basados en dominio
################################################################################

set -euo pipefail

# Configuración
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd || pwd)"
readonly TEMPLATE_DIR="${PROJECT_DIR}/templates"
readonly ENV_FILE=".env"

# Colores
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Funciones de logging
log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }

# Función para sanitizar nombre de dominio
sanitize_domain_name() {
    local domain="$1"
    # Convertir puntos en guiones bajos y eliminar caracteres especiales
    echo "$domain" | tr '.' '_' | tr '-' '_' | sed 's/[^a-zA-Z0-9_]//g'
}

# Verificar requisitos
check_requirements() {
    cd "$PROJECT_DIR" || error "No se pudo acceder al directorio del proyecto"
    [[ -f "$ENV_FILE" ]] || error "Archivo .env no encontrado en $PROJECT_DIR"
    [[ -d "$TEMPLATE_DIR" ]] || error "Directorio templates/ no encontrado en $TEMPLATE_DIR"

    if ! command -v htpasswd &>/dev/null; then
        warning "Instalando apache2-utils..."
        apt-get update -qq && apt-get install -y -qq apache2-utils
    fi
}

# Cargar variables de entorno
load_env() {
    # Exportar todas las variables del .env
    set -a
    source "$ENV_FILE"
    set +a

    # Cargar array de dominios
    mapfile -t DOMAINS < <(grep "^DOMAIN_" "$ENV_FILE" | cut -d'=' -f2)
    readonly DOMAINS
}

# Setup phpMyAdmin
setup_phpmyadmin_credentials() {
    log "Configurando phpMyAdmin..."

    if ! grep -q "^PHPMYADMIN_AUTH_USER=" "$ENV_FILE" 2>/dev/null; then
        local user="phpmyadmin"
        local password
        password=$(pwgen -s 16 1)

        {
            echo ""
            echo "# phpMyAdmin Authentication"
            echo "PHPMYADMIN_AUTH_USER=$user"
            echo "PHPMYADMIN_AUTH_PASSWORD=$password"
        } >> "$ENV_FILE"

        info "  Nuevo usuario: $user / $password"

        # Recargar variables
        export PHPMYADMIN_AUTH_USER="$user"
        export PHPMYADMIN_AUTH_PASSWORD="$password"
    fi

    local user password
    user="${PHPMYADMIN_AUTH_USER:-$(grep "^PHPMYADMIN_AUTH_USER=" "$ENV_FILE" | cut -d'=' -f2)}"
    password="${PHPMYADMIN_AUTH_PASSWORD:-$(grep "^PHPMYADMIN_AUTH_PASSWORD=" "$ENV_FILE" | cut -d'=' -f2)}"

    mkdir -p nginx/auth
    htpasswd -bc nginx/auth/.htpasswd "$user" "$password"
    chmod 644 nginx/auth/.htpasswd

    if ! grep -q "^PMA_ABSOLUTE_URI=" "$ENV_FILE" 2>/dev/null && [[ -n "${DOMAINS[0]:-}" ]]; then
        {
            echo ""
            echo "# phpMyAdmin Configuration"
            echo "PMA_ABSOLUTE_URI=http://${DOMAINS[0]}/phpmyadmin/"
        } >> "$ENV_FILE"

        export PMA_ABSOLUTE_URI="http://${DOMAINS[0]}/phpmyadmin/"
    fi
}

# Setup SFTP usuarios independientes
setup_sftp_credentials() {
    log "Configurando usuarios SFTP independientes..."

    # Verificar si ya existen credenciales SFTP para el primer dominio
    local first_domain_sanitized=$(sanitize_domain_name "${DOMAINS[0]}")
    if ! grep -q "^SFTP_${first_domain_sanitized^^}_PASSWORD=" "$ENV_FILE" 2>/dev/null; then
        {
            echo ""
            echo "# SFTP - Usuarios independientes por sitio"
        } >> "$ENV_FILE"

        for i in "${!DOMAINS[@]}"; do
            local domain="${DOMAINS[$i]}"
            local domain_sanitized=$(sanitize_domain_name "$domain")
            local password
            password=$(pwgen -s 24 1)
            echo "SFTP_${domain_sanitized^^}_PASSWORD=$password" >> "$ENV_FILE"
            info "  Usuario ${domain}: sftp_${domain_sanitized} / $password"
        done

        # Recargar .env
        set -a
        source "$ENV_FILE"
        set +a
    fi
}

# Setup credenciales de DB por sitio
setup_db_credentials() {
    log "Configurando credenciales de base de datos por sitio..."

    # Verificar si ya existen credenciales DB
    if ! grep -q "^DB_PASSWORD_1=" "$ENV_FILE" 2>/dev/null; then
        {
            echo ""
            echo "# Database passwords por sitio"
        } >> "$ENV_FILE"

        for i in "${!DOMAINS[@]}"; do
            local site_num=$((i + 1))
            local password
            password=$(pwgen -s 24 1)
            echo "DB_PASSWORD_${site_num}=$password" >> "$ENV_FILE"
            info "  DB password sitio ${site_num}: $password"
        done

        # Recargar .env
        set -a
        source "$ENV_FILE"
        set +a
    fi
}

# Generar docker-compose
generate_docker_compose() {
    log "Generando docker-compose.yml..."

    # Construir volúmenes SFTP
    local sftp_volumes=""
    for i in "${!DOMAINS[@]}"; do
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        sftp_volumes+="      - ./www/${domain_sanitized}:/home/sftp_${domain_sanitized}/${domain_sanitized}:rw"$'\n'
    done
    sftp_volumes="${sftp_volumes%$'\n'}"

    # Construir usuarios SFTP
    local sftp_users=""
    for i in "${!DOMAINS[@]}"; do
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        local password_var="SFTP_${domain_sanitized^^}_PASSWORD"
        local password="${!password_var}"
        sftp_users+="      sftp_${domain_sanitized}:${password}:33:33:${domain_sanitized}"$'\n'
    done
    sftp_users="${sftp_users%$'\n'}"

    # Asegurar que todas las variables estén exportadas
    export MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}"
    # Usar DB_PASSWORD_1 como DB_PASSWORD para compatibilidad con template docker-compose
    # (aunque creamos usuarios individuales en setup.sh)
    export DB_PASSWORD="${DB_PASSWORD_1}"
    export SERVER_IP="${SERVER_IP}"
    export PMA_ABSOLUTE_URI="${PMA_ABSOLUTE_URI:-http://${DOMAINS[0]}/phpmyadmin/}"
    export SFTP_VOLUMES="$sftp_volumes"
    export SFTP_USERS="$sftp_users"

    # Usar envsubst
    envsubst '${MYSQL_ROOT_PASSWORD} ${DB_PASSWORD} ${SERVER_IP} ${PMA_ABSOLUTE_URI} ${SFTP_VOLUMES} ${SFTP_USERS}' \
        < "${TEMPLATE_DIR}/docker-compose.yml.template" > docker-compose.yml

    log "✅ docker-compose.yml generado"
}

# Generar nginx.conf
generate_nginx_conf() {
    log "Generando nginx.conf..."
    cp "${TEMPLATE_DIR}/nginx.conf.template" nginx/nginx.conf
    log "✅ nginx.conf generado"
}

# Generar vhost individual
generate_vhost() {
    local domain="$1"
    local site_num="$2"
    local is_first="${3:-false}"
    local domain_sanitized=$(sanitize_domain_name "$domain")
    local output_file="nginx/conf.d/${domain}.conf"

    log "  → $domain → ${domain_sanitized}"

    # Variables para las plantillas
    export DOMAIN="$domain"
    export SITE_NUM="$site_num"
    export DOMAIN_SANITIZED="$domain_sanitized"
    export DATE="$(date)"

    # Generar bloque HTTP
    # Primero procesamos las variables de plantilla, luego convertimos $$ a $
    envsubst '${DOMAIN} ${SITE_NUM} ${DOMAIN_SANITIZED} ${DATE}' < "${TEMPLATE_DIR}/vhost-http.conf.template" | \
        sed 's/\$\$/$/g' > "$output_file"

    # Añadir phpMyAdmin si es el primer dominio
    if [[ "$is_first" == "true" ]]; then
        # phpMyAdmin block no necesita envsubst, solo convertir $$ a $
        sed 's/\$\$/$/g' "${TEMPLATE_DIR}/phpmyadmin-http.conf.template" >> "$output_file"
    else
        # Cerrar el bloque server si NO es el primer dominio
        echo "}" >> "$output_file"
    fi

    # Añadir bloque HTTPS (comentado)
    echo "" >> "$output_file"
    envsubst '${DOMAIN} ${SITE_NUM} ${DOMAIN_SANITIZED} ${DATE}' < "${TEMPLATE_DIR}/vhost-https.conf.template" | \
        sed 's/\$\$/$/g' >> "$output_file"

    # Añadir phpMyAdmin HTTPS si es el primer dominio
    if [[ "$is_first" == "true" ]]; then
        sed 's/\$\$/$/g' "${TEMPLATE_DIR}/phpmyadmin-https.conf.template" >> "$output_file"
    else
        # Cerrar el bloque server comentado si NO es el primer dominio
        echo "# }" >> "$output_file"
    fi

    unset DOMAIN SITE_NUM DOMAIN_SANITIZED DATE
}

# Generar todos los vhosts
generate_vhosts() {
    log "Generando virtual hosts..."

    for i in "${!DOMAINS[@]}"; do
        local site_num=$((i + 1))
        local is_first=false
        [[ $i -eq 0 ]] && is_first=true

        generate_vhost "${DOMAINS[$i]}" "$site_num" "$is_first"
    done

    log "✅ ${#DOMAINS[@]} virtual hosts generados"
}

# Generar configuraciones PHP
generate_php_configs() {
    log "Generando configuraciones PHP..."
    cp "${TEMPLATE_DIR}/php.ini.template" php/php.ini
    cp "${TEMPLATE_DIR}/www.conf.template" php/www.conf
    log "✅ php.ini y www.conf generados"
}

# Generar configuraciones MySQL
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

        for i in "${!DOMAINS[@]}"; do
            local domain="${DOMAINS[$i]}"
            local domain_sanitized=$(sanitize_domain_name "$domain")
            echo "CREATE DATABASE IF NOT EXISTS ${domain_sanitized} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        done

        echo ""
        echo "-- Fin de inicialización"
    } > mysql/init/01-init-databases.sql

    log "✅ Configuraciones MySQL generadas"
}

# Generar .gitignore
generate_gitignore() {
    log "Generando .gitignore..."
    cp "${TEMPLATE_DIR}/gitignore.template" .gitignore
    log "✅ .gitignore generado"
}

# Mostrar resumen
show_summary() {
    local user password
    user="${PHPMYADMIN_AUTH_USER:-$(grep "^PHPMYADMIN_AUTH_USER=" "$ENV_FILE" | cut -d'=' -f2)}"
    password="${PHPMYADMIN_AUTH_PASSWORD:-$(grep "^PHPMYADMIN_AUTH_PASSWORD=" "$ENV_FILE" | cut -d'=' -f2)}"

    cat << EOF

${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}
${GREEN}✓ CONFIGURACIÓN COMPLETADA${NC}
${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}

${YELLOW}phpMyAdmin:${NC}
  URL: http://${DOMAINS[0]}/phpmyadmin/
  Auth HTTP → Usuario: $user | Contraseña: $password
  MySQL → Servidor: mysql | Usuario: root/wpuser_*

${YELLOW}Usuarios MySQL por sitio:${NC}
EOF

    for i in "${!DOMAINS[@]}"; do
        local site_num=$((i + 1))
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        local password_var="DB_PASSWORD_${site_num}"
        local password="${!password_var}"
        echo "  ${domain}:"
        echo "    Base de datos: ${domain_sanitized}"
        echo "    Usuario: wpuser_${domain_sanitized}"
        echo "    Contraseña: ${password}"
    done

    cat << EOF

${YELLOW}Usuarios SFTP independientes:${NC}
  Host: $SERVER_IP:2222
  Puerto: 2222
EOF

    for i in "${!DOMAINS[@]}"; do
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        local password_var="SFTP_${domain_sanitized^^}_PASSWORD"
        local password="${!password_var}"
        echo "  ${domain}:"
        echo "    Usuario: sftp_${domain_sanitized}"
        echo "    Carpeta: ${domain_sanitized}"
        echo "    Directorio enjaulado: /${domain_sanitized}"
        echo "    Comando: sftp -P 2222 sftp_${domain_sanitized}@$SERVER_IP"
    done

    cat << EOF

${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}

${GREEN}Siguiente paso:${NC} ./scripts/setup.sh

EOF
}

# Main
main() {
    log "🚀 Iniciando generación de configuraciones..."

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

    log "✅ Todas las configuraciones generadas exitosamente"
    show_summary
}

main "$@"