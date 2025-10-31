#!/bin/bash

################################################################################
# Script de Setup - Descarga WordPress y configura sitios
# Versión refactorizada usando plantillas
# VERSIÓN CORREGIDA - Con nombres basados en dominio
################################################################################

set -euo pipefail

# Configuración
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd || pwd)"
readonly TEMPLATE_DIR="${PROJECT_DIR}/templates"
readonly ENV_FILE=".env"
readonly WP_DOWNLOAD="/tmp/latest.tar.gz"

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

# Banner
show_banner() {
    log "╔══════════════════════════════════════════════════╗"
    log "SETUP DE WORDPRESS MULTI-SITE"
    log "╚══════════════════════════════════════════════════╝"
    echo ""
}

# Verificar requisitos
check_requirements() {
    cd "$PROJECT_DIR" || error "No se pudo acceder al directorio del proyecto"
    [[ -f "$ENV_FILE" ]] || error "Archivo .env no encontrado en $PROJECT_DIR"
    [[ -d "$TEMPLATE_DIR" ]] || error "Directorio templates/ no encontrado en $TEMPLATE_DIR"
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

# Descargar WordPress
download_wordpress() {
    log "Paso 1: Descargando WordPress en español..."

    # Eliminar archivo previo para asegurar versión en español
    rm -f "$WP_DOWNLOAD"

    wget -q https://es.wordpress.org/latest-es_ES.tar.gz -O "$WP_DOWNLOAD" || \
        error "Error al descargar WordPress"

    # Verificar que descargamos la versión correcta
    if file "$WP_DOWNLOAD" | grep -q "gzip"; then
        log "✓ WordPress en español descargado correctamente"
    else
        error "Error: archivo descargado no es válido"
    fi
}

# Configurar un sitio individual
setup_site() {
    local site_num="$1"
    local domain="$2"
    local domain_sanitized=$(sanitize_domain_name "$domain")
    local site_dir="www/${domain_sanitized}"

    log "  Configurando sitio $site_num: $domain → ${domain_sanitized}"

    # Crear directorio si no existe
    if [[ -d "$site_dir" ]]; then
        warning "    Directorio ya existe, omitiendo..."
        return 0
    fi

    mkdir -p "$site_dir"

    # Extraer WordPress
    tar -xzf "$WP_DOWNLOAD" -C /tmp/
    cp -r /tmp/wordpress/* "$site_dir/"
    log "    ✓ WordPress extraído"

    # Generar wp-config.php usando plantilla
    log "    Generando wp-config.php..."

    local salt_keys
    salt_keys=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)

    # Verificar que la plantilla existe
    if [[ ! -f "${TEMPLATE_DIR}/wp-config.php.template" ]]; then
        error "Plantilla wp-config.php.template no encontrada"
    fi

    # Exportar variables para envsubst
    export DOMAIN="$domain"
    export SITE_NUM="$site_num"
    export DOMAIN_SANITIZED="$domain_sanitized"
    export DB_NAME="${domain_sanitized}"
    export DB_USER="wpuser_${domain_sanitized}"

    # Obtener la contraseña específica del sitio
    local db_password_var="DB_PASSWORD_${site_num}"
    export DB_PASSWORD="${!db_password_var}"

    export DATE="$(date)"
    export SALT_KEYS="$salt_keys"

    # Variables SFTP
    local sftp_password_var="SFTP_${domain_sanitized^^}_PASSWORD"
    export SFTP_USER="sftp_${domain_sanitized}"
    export SFTP_PASSWORD="${!sftp_password_var}"
    export SFTP_HOST="${SERVER_IP}"
    export SFTP_PORT="2222"

    # Generar wp-config.php
    envsubst '${DOMAIN} ${SITE_NUM} ${DOMAIN_SANITIZED} ${DB_NAME} ${DB_USER} ${DB_PASSWORD} ${DATE} ${SALT_KEYS} ${SFTP_USER} ${SFTP_PASSWORD} ${SFTP_HOST} ${SFTP_PORT}' \
      < "${TEMPLATE_DIR}/wp-config.php.template" > "${site_dir}/wp-config.php"

    unset DOMAIN SITE_NUM DOMAIN_SANITIZED DB_NAME DB_USER DB_PASSWORD DATE SALT_KEYS SFTP_USER SFTP_PASSWORD SFTP_HOST SFTP_PORT

    log "    ✓ wp-config.php generado"
}

# Configurar todos los sitios
setup_sites() {
    log "Paso 2: Configurando sitios..."

    for i in "${!DOMAINS[@]}"; do
        local site_num=$((i + 1))
        setup_site "$site_num" "${DOMAINS[$i]}"
    done

    # Limpiar archivos temporales
    rm -rf /tmp/wordpress
}

# Ajustar permisos
set_permissions() {
    log "Paso 3: Ajustando permisos..."

    chown -R www-data:www-data www/ 2>/dev/null || chown -R 33:33 www/
    find www/ -type d -exec chmod 755 {} \;
    find www/ -type f -exec chmod 644 {} \;

    log "✓ Permisos ajustados"
}

# Iniciar contenedores Docker
start_containers() {
    log "Paso 4: Iniciando contenedores Docker..."

    # Detener si están corriendo
    if docker compose ps -q 2>/dev/null | grep -q .; then
        log "  Deteniendo contenedores existentes..."
        docker compose down
    fi

    # Iniciar
    log "  Iniciando contenedores..."
    docker compose up -d || error "Error al iniciar contenedores"

    log "✓ Contenedores iniciados"
}

# Esperar a MySQL
wait_for_mysql() {
    log "Paso 5: Esperando a que MySQL esté listo..."

    local max_attempts=90
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        # Intentar conectarse a MySQL
        if docker compose exec -T mysql mysqladmin ping -h localhost -u root -p"${MYSQL_ROOT_PASSWORD}" &>/dev/null; then
            log "✅ MySQL está listo"
            log "  Esperando 10s adicionales para scripts de inicialización..."
            sleep 10
            return 0
        fi

        attempt=$((attempt + 1))

        if [[ $((attempt % 10)) -eq 0 ]]; then
            log "  Intento $attempt de $max_attempts..."
        fi

        sleep 2
    done

    error "❌ Timeout esperando a MySQL. Ver logs: docker compose logs mysql"
}

# Verificar bases de datos
verify_databases() {
    log "Paso 6: Verificando bases de datos..."

    # Verificar cada base de datos y crear usuarios
    for i in "${!DOMAINS[@]}"; do
        local site_num=$((i + 1))
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        local db_name="${domain_sanitized}"
        local db_user="wpuser_${domain_sanitized}"
        local db_password_var="DB_PASSWORD_${site_num}"
        local db_password="${!db_password_var}"

        log "  Configurando: $domain → DB: $db_name | Usuario: $db_user"

        # Eliminar usuario previo si existe
        docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
            -e "DROP USER IF EXISTS '${db_user}'@'%';" 2>/dev/null || true

        # Crear base de datos si no existe
        docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
            -e "CREATE DATABASE IF NOT EXISTS $db_name CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || {
            warning "    No se pudo crear $db_name"
            continue
        }

        # Crear usuario específico del sitio
        docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
            -e "CREATE USER '${db_user}'@'%' IDENTIFIED BY '${db_password}';" || {
            warning "    No se pudo crear usuario $db_user"
            continue
        }

        # Otorgar permisos
        docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
            -e "GRANT ALL PRIVILEGES ON $db_name.* TO '${db_user}'@'%';" || {
            warning "    No se pudieron otorgar permisos a $db_name"
            continue
        }

        log "    ✓ $db_name configurada con usuario $db_user"
    done

    # Aplicar cambios
    docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
        -e "FLUSH PRIVILEGES;" || warning "No se pudo ejecutar FLUSH PRIVILEGES"

    log "✅ Verificación de bases de datos completada"
}

# Verificar conexión desde PHP
verify_php_connection() {
    log "Paso 7: Verificando conexión desde PHP..."

    for i in "${!DOMAINS[@]}"; do
        local site_num=$((i + 1))
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        local db_name="${domain_sanitized}"
        local db_user="wpuser_${domain_sanitized}"
        local db_password_var="DB_PASSWORD_${site_num}"
        local db_password="${!db_password_var}"
        local test_script="www/${domain_sanitized}/test-db.php"

        log "  Probando conexión a $db_name..."

        # Crear script de prueba
        cat > "$test_script" << EOF
<?php
\$host = 'mysql';
\$user = '${db_user}';
\$pass = '${db_password}';
\$db = '${db_name}';

\$conn = new mysqli(\$host, \$user, \$pass, \$db);

if (\$conn->connect_error) {
    echo "ERROR: " . \$conn->connect_error . "\n";
    exit(1);
}

echo "OK\n";
\$conn->close();
EOF

        # Ejecutar test
        local result
        result=$(docker compose exec -T php php "/var/www/html/${domain_sanitized}/test-db.php" 2>&1)

        if echo "$result" | grep -q "^OK"; then
            log "    ✓ Conexión exitosa a $db_name"
        else
            warning "    ⚠ Problema de conexión a $db_name"
            if [[ -n "$result" ]]; then
                echo "$result" | head -5 | while IFS= read -r line; do
                    warning "      $line"
                done
            fi
        fi

        rm -f "$test_script"
    done

    log "✅ Verificación de conexiones PHP completada"
}

# Mostrar información final
show_summary() {
    log "╔══════════════════════════════════════════════════╗"
    log "SETUP COMPLETADO EXITOSAMENTE"
    log "╚══════════════════════════════════════════════════╝"
    echo ""

    info "Contenedores en ejecución:"
    docker compose ps
    echo ""

    info "Sitios configurados:"
    for i in "${!DOMAINS[@]}"; do
        local site_num=$((i + 1))
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        echo "  $site_num. ${domain} → http://${domain}"
        echo "      Carpeta: ${domain_sanitized}"
        echo "      Base de datos: ${domain_sanitized}"
        echo "      Usuario DB: wpuser_${domain_sanitized}"
    done
    echo ""

    info "CREDENCIALES:"
    echo "  MySQL Root: root / ${MYSQL_ROOT_PASSWORD}"
    echo ""
    echo "  Usuarios MySQL por sitio:"
    for i in "${!DOMAINS[@]}"; do
        local site_num=$((i + 1))
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        local password_var="DB_PASSWORD_${site_num}"
        local password="${!password_var:-N/A}"
        echo "    ${domain}: wpuser_${domain_sanitized} / ${password}"
    done
    echo ""
    echo "  SFTP (usuarios independientes):"
    for i in "${!DOMAINS[@]}"; do
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        local password_var="SFTP_${domain_sanitized^^}_PASSWORD"
        local password="${!password_var:-N/A}"
        echo "    ${domain}: sftp_${domain_sanitized} / ${password}"
    done
    echo ""

    info "ACCESO A SERVICIOS:"
    echo ""
    echo "  phpMyAdmin: http://${DOMAINS[0]}/phpmyadmin/"
    echo "  SFTP: ${SERVER_IP}:2222"
    echo ""
    echo "  Accesos SFTP por sitio:"
    for i in "${!DOMAINS[@]}"; do
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        echo "    ${domain}: sftp -P 2222 sftp_${domain_sanitized}@${SERVER_IP}"
        echo "    Directorio: /${domain_sanitized}"
    done
    echo ""

    warning "PRÓXIMOS PASOS:"
    echo "  1. Apuntar DNS de dominios a: ${SERVER_IP}"
    echo "  2. Ejecutar: ./scripts/setup-ssl.sh"
    echo "  3. Completar instalación WordPress en:"
    for domain in "${DOMAINS[@]}"; do
        echo "     - http://$domain/wp-admin/install.php"
    done
    echo ""

    info "COMANDOS ÚTILES:"
    echo "  Ver logs: docker compose logs [servicio]"
    echo "  MySQL CLI: docker compose exec mysql mysql -uroot -p${MYSQL_ROOT_PASSWORD}"
    echo "  Gestión: docker compose [start|stop|restart]"
    echo ""
}

# Main
main() {
    show_banner
    check_requirements
    load_env
    download_wordpress
    setup_sites
    set_permissions
    start_containers
    wait_for_mysql
    verify_databases
    verify_php_connection
    show_summary
}

main "$@"