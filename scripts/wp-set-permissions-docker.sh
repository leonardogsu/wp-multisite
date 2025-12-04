#!/bin/bash

###########################################
# WordPress Security Permissions Script v2
# Versión adaptada para contenedores Docker
# Con soporte para múltiples sitios
###########################################

set -euo pipefail

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# Variables configurables
CONTAINER_NAME="php"
WP_PATH_CONTAINER="/var/www/html"
WEB_USER="www-data"
WEB_GROUP="www-data"

###########################################
# Funciones auxiliares
###########################################

print_header() {
    echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

show_usage() {
    cat << EOF
Uso: $0 [opciones]

Opciones:
    --container Nombre o ID del contenedor (default: php)
    --path      Ruta dentro del contenedor (default: /var/www/html)
    --user      Usuario del servidor web (default: www-data)
    --group     Grupo del servidor web (default: www-data)
    --help      Muestra esta ayuda

Ejemplos:
    # Securizar un sitio específico
    $0 --path /var/www/html/manidec_com

    # Securizar toda la instalación
    $0 --path /var/www/html

    # Con contenedor personalizado
    $0 --container mi-php --path /var/www/html/aiconvolution_com

EOF
    exit 1
}

list_wordpress_sites() {
    print_info "Buscando sitios WordPress en el contenedor..."
    echo ""

    local sites=$(docker exec "$CONTAINER_NAME" sh -c "
        for dir in /var/www/html/*/; do
            if [ -f \"\${dir}wp-config.php\" ] || [ -d \"\${dir}wp-content\" ]; then
                basename \"\$dir\"
            fi
        done
    " 2>/dev/null || echo "")

    if [[ -n "$sites" ]]; then
        echo "Sitios WordPress encontrados:"
        echo "$sites" | while read -r site; do
            echo "  • /var/www/html/$site"
        done
        echo ""
    fi
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        print_error "Docker no está instalado o no está en el PATH"
        exit 1
    fi
}

check_container() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            print_error "El contenedor '$CONTAINER_NAME' no existe"
            exit 1
        else
            print_error "El contenedor '$CONTAINER_NAME' existe pero no está corriendo"
            print_info "Inicia el contenedor con: docker start $CONTAINER_NAME"
            exit 1
        fi
    fi
    print_success "Contenedor '$CONTAINER_NAME' encontrado y corriendo"
}

validate_wordpress() {
    print_info "Validando ruta: $WP_PATH_CONTAINER"

    # Verificar si la ruta existe
    if ! docker exec "$CONTAINER_NAME" test -d "$WP_PATH_CONTAINER" 2>/dev/null; then
        print_error "La ruta '$WP_PATH_CONTAINER' no existe dentro del contenedor"
        list_wordpress_sites
        exit 1
    fi

    # Verificar si es una instalación de WordPress
    local has_wpconfig=$(docker exec "$CONTAINER_NAME" test -f "$WP_PATH_CONTAINER/wp-config.php" && echo "yes" || echo "no")
    local has_wpcontent=$(docker exec "$CONTAINER_NAME" test -d "$WP_PATH_CONTAINER/wp-content" && echo "yes" || echo "no")
    local has_wpsettings=$(docker exec "$CONTAINER_NAME" test -f "$WP_PATH_CONTAINER/wp-settings.php" && echo "yes" || echo "no")

    if [[ "$has_wpconfig" == "no" ]] && [[ "$has_wpcontent" == "no" ]] && [[ "$has_wpsettings" == "no" ]]; then
        print_error "No se detectó WordPress en '$WP_PATH_CONTAINER'"
        print_info "Debe contener al menos uno de: wp-config.php, wp-content/, wp-settings.php"
        echo ""
        list_wordpress_sites
        exit 1
    fi

    print_success "Instalación de WordPress detectada en: $WP_PATH_CONTAINER"
}

###########################################
# Análisis del estado actual
###########################################

analyze_current_state() {
    print_header "ANÁLISIS DEL ESTADO ACTUAL"

    print_info "Sitio: $WP_PATH_CONTAINER"
    print_info "Analizando permisos actuales..."

    # Verificar archivos críticos
    echo ""
    print_info "═══ ARCHIVOS CRÍTICOS ═══"

    for file in wp-config.php .htaccess index.php; do
        if docker exec "$CONTAINER_NAME" test -f "$WP_PATH_CONTAINER/$file" 2>/dev/null; then
            local info=$(docker exec "$CONTAINER_NAME" ls -la "$WP_PATH_CONTAINER/$file" 2>/dev/null | awk '{print $1, $3":"$4, $9}')
            echo "  $file: $info"
        fi
    done

    # Verificar directorios principales
    echo ""
    print_info "═══ DIRECTORIOS PRINCIPALES ═══"

    for dir in wp-content wp-content/themes wp-content/plugins wp-content/uploads wp-admin wp-includes; do
        if docker exec "$CONTAINER_NAME" test -d "$WP_PATH_CONTAINER/$dir" 2>/dev/null; then
            local info=$(docker exec "$CONTAINER_NAME" ls -lad "$WP_PATH_CONTAINER/$dir" 2>/dev/null | awk '{print $1, $3":"$4}')
            echo "  $dir/: $info"
        fi
    done

    # Buscar problemas de seguridad
    echo ""
    print_info "Buscando problemas de seguridad..."

    local count_777_files=$(docker exec "$CONTAINER_NAME" sh -c "find '$WP_PATH_CONTAINER' -maxdepth 3 -type f -perm 0777 2>/dev/null | wc -l")
    local count_777_dirs=$(docker exec "$CONTAINER_NAME" sh -c "find '$WP_PATH_CONTAINER' -maxdepth 3 -type d -perm 0777 2>/dev/null | wc -l")

    if [[ $count_777_files -gt 0 ]]; then
        print_warning "Archivos con permisos 777: $count_777_files (MUY INSEGURO)"
    else
        print_success "No hay archivos con permisos 777"
    fi

    if [[ $count_777_dirs -gt 0 ]]; then
        print_warning "Directorios con permisos 777: $count_777_dirs (MUY INSEGURO)"
    else
        print_success "No hay directorios con permisos 777"
    fi

    # Verificar wp-config.php
    if docker exec "$CONTAINER_NAME" test -f "$WP_PATH_CONTAINER/wp-config.php" 2>/dev/null; then
        local wpconfig_perms=$(docker exec "$CONTAINER_NAME" stat -c "%a" "$WP_PATH_CONTAINER/wp-config.php" 2>/dev/null)
        echo ""
        print_info "wp-config.php actual: permisos=$wpconfig_perms"

        if [[ "$wpconfig_perms" != "440" ]] && [[ "$wpconfig_perms" != "400" ]] && [[ "$wpconfig_perms" != "600" ]]; then
            print_warning "  → Permisos recomendados: 440"
        else
            print_success "  → Permisos correctos"
        fi
    fi

    # Verificar propietario
    echo ""
    local current_owner=$(docker exec "$CONTAINER_NAME" stat -c "%U:%G" "$WP_PATH_CONTAINER" 2>/dev/null || echo "desconocido")
    print_info "Propietario actual: $current_owner"

    if [[ "$current_owner" != "$WEB_USER:$WEB_GROUP" ]]; then
        print_warning "  → Se cambiará a: $WEB_USER:$WEB_GROUP"
    else
        print_success "  → Propietario correcto"
    fi
}

###########################################
# Aplicar securización
###########################################

apply_security() {
    print_header "APLICANDO SECURIZACIÓN"

    print_info "Los siguientes cambios serán aplicados:"
    echo ""
    echo "  📂 SITIO: $WP_PATH_CONTAINER"
    echo ""
    echo "  🔒 PERMISOS:"
    echo "     • Directorios: 755 (rwxr-xr-x)"
    echo "     • Archivos: 644 (rw-r--r--)"
    echo "     • wp-config.php: 440 (r--r-----)"
    echo ""
    echo "  👤 PROPIETARIO:"
    echo "     • Usuario: $WEB_USER"
    echo "     • Grupo: $WEB_GROUP"
    echo ""
    echo "  📁 EXCEPCIONES:"
    echo "     • wp-content/uploads mantendrá capacidad de escritura"
    echo ""

    read -p "¿Continuar con la securización? (escribe 'SI' para confirmar): " confirm

    if [[ "${confirm}" != "SI" ]]; then
        print_warning "Operación cancelada"
        exit 0
    fi

    echo ""
    print_info "Iniciando securización..."
    echo ""

    # 1. Cambiar propietario
    print_info "[1/6] Cambiando propietario a $WEB_USER:$WEB_GROUP..."
    if docker exec "$CONTAINER_NAME" chown -R "$WEB_USER":"$WEB_GROUP" "$WP_PATH_CONTAINER" 2>/dev/null; then
        print_success "Propietario actualizado"
    else
        print_warning "No se pudo cambiar el propietario (puede ser normal en algunos contenedores)"
    fi

    # 2. Permisos para directorios
    print_info "[2/6] Estableciendo permisos 755 para directorios..."
    docker exec "$CONTAINER_NAME" sh -c "find '$WP_PATH_CONTAINER' -type d -exec chmod 755 {} + 2>/dev/null" && \
        print_success "Permisos de directorios actualizados"

    # 3. Permisos para archivos
    print_info "[3/6] Estableciendo permisos 644 para archivos..."
    docker exec "$CONTAINER_NAME" sh -c "find '$WP_PATH_CONTAINER' -type f -exec chmod 644 {} + 2>/dev/null" && \
        print_success "Permisos de archivos actualizados"

    # 4. Securizar wp-config.php
    if docker exec "$CONTAINER_NAME" test -f "$WP_PATH_CONTAINER/wp-config.php" 2>/dev/null; then
        print_info "[4/6] Securizando wp-config.php (440)..."
        docker exec "$CONTAINER_NAME" chmod 440 "$WP_PATH_CONTAINER/wp-config.php" 2>/dev/null && \
            print_success "wp-config.php securizado"
    else
        print_warning "[4/6] wp-config.php no encontrado"
    fi

    # 5. Securizar .htaccess
    if docker exec "$CONTAINER_NAME" test -f "$WP_PATH_CONTAINER/.htaccess" 2>/dev/null; then
        print_info "[5/6] Securizando .htaccess (644)..."
        docker exec "$CONTAINER_NAME" chmod 644 "$WP_PATH_CONTAINER/.htaccess" 2>/dev/null && \
            print_success ".htaccess securizado"
    else
        print_info "[5/6] .htaccess no encontrado (normal con Nginx)"
    fi

    # 6. Configurar uploads
    if docker exec "$CONTAINER_NAME" test -d "$WP_PATH_CONTAINER/wp-content/uploads" 2>/dev/null; then
        print_info "[6/6] Configurando wp-content/uploads..."
        docker exec "$CONTAINER_NAME" sh -c "
            chmod 755 '$WP_PATH_CONTAINER/wp-content/uploads' 2>/dev/null
            find '$WP_PATH_CONTAINER/wp-content/uploads' -type d -exec chmod 755 {} + 2>/dev/null
            find '$WP_PATH_CONTAINER/wp-content/uploads' -type f -exec chmod 644 {} + 2>/dev/null
        " && print_success "wp-content/uploads configurado"
    else
        print_info "[6/6] wp-content/uploads no existe"
    fi

    echo ""
    print_success "¡Securización completada!"
    sleep 1
}

###########################################
# Verificación final
###########################################

verify_security() {
    print_header "VERIFICACIÓN FINAL"

    local final_777_files=$(docker exec "$CONTAINER_NAME" sh -c "find '$WP_PATH_CONTAINER' -maxdepth 3 -type f -perm 0777 2>/dev/null | wc -l")
    local final_777_dirs=$(docker exec "$CONTAINER_NAME" sh -c "find '$WP_PATH_CONTAINER' -maxdepth 3 -type d -perm 0777 2>/dev/null | wc -l")

    if [[ $final_777_files -eq 0 ]]; then
        print_success "No quedan archivos con permisos 777"
    else
        print_warning "Aún hay $final_777_files archivos con permisos 777"
    fi

    if [[ $final_777_dirs -eq 0 ]]; then
        print_success "No quedan directorios con permisos 777"
    else
        print_warning "Aún hay $final_777_dirs directorios con permisos 777"
    fi

    if docker exec "$CONTAINER_NAME" test -f "$WP_PATH_CONTAINER/wp-config.php" 2>/dev/null; then
        local wpconfig_perms=$(docker exec "$CONTAINER_NAME" stat -c "%a" "$WP_PATH_CONTAINER/wp-config.php" 2>/dev/null)

        if [[ "$wpconfig_perms" == "440" ]] || [[ "$wpconfig_perms" == "400" ]]; then
            print_success "wp-config.php tiene permisos seguros ($wpconfig_perms)"
        else
            print_warning "wp-config.php tiene permisos $wpconfig_perms"
        fi
    fi

    local final_owner=$(docker exec "$CONTAINER_NAME" stat -c "%U:%G" "$WP_PATH_CONTAINER" 2>/dev/null)
    if [[ "$final_owner" == "$WEB_USER:$WEB_GROUP" ]]; then
        print_success "Propietario correcto: $final_owner"
    else
        print_info "Propietario actual: $final_owner"
    fi
}

###########################################
# Main
###########################################

main() {
    print_header "WORDPRESS SECURITY - DOCKER VERSION"

    # Parsear argumentos
    while [[ $# -gt 0 ]]; do
        case $1 in
            --container)
                CONTAINER_NAME="$2"
                shift 2
                ;;
            --path)
                WP_PATH_CONTAINER="$2"
                shift 2
                ;;
            --user)
                WEB_USER="$2"
                shift 2
                ;;
            --group)
                WEB_GROUP="$2"
                shift 2
                ;;
            --help)
                show_usage
                ;;
            *)
                print_error "Opción desconocida: $1"
                show_usage
                ;;
        esac
    done

    # Normalizar path (eliminar / final si existe)
    WP_PATH_CONTAINER="${WP_PATH_CONTAINER%/}"

    # Validaciones
    check_docker
    check_container
    validate_wordpress

    # Ejecutar fases
    analyze_current_state
    apply_security
    verify_security

    print_header "✓ FINALIZADO"
    print_success "WordPress securizado correctamente"
    echo ""
    print_info "Sitio: $WP_PATH_CONTAINER"
    print_info "Contenedor: $CONTAINER_NAME"
    echo ""
    print_info "📋 Recomendaciones adicionales:"
    echo "  1. Actualiza WordPress, temas y plugins regularmente"
    echo "  2. Usa contraseñas fuertes para todos los usuarios"
    echo "  3. Instala un plugin de seguridad (Wordfence, Sucuri)"
    echo "  4. Realiza backups periódicos automáticos"
    echo "  5. Activa SSL/HTTPS en tu sitio"
    echo ""
}

main "$@"