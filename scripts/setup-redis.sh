#!/bin/bash

###########################################
# WordPress Redis Cache Monitoring Script
# Diagnóstico y monitoreo de Redis
###########################################

set -uo pipefail

shopt -s nullglob

# Colores
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Variables
readonly INSTALL_DIR="/opt/wordpress-multisite"
readonly CONTAINER_PHP="php"
readonly CONTAINER_REDIS="redis"

# Array de sitios
declare -a SITES

###########################################
# Funciones de utilidad
###########################################

print_header() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo -e "${BLUE}  $1${NC}" >&2
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n" >&2
}

print_success() { echo -e "${GREEN}✓${NC} $1" >&2; }
print_error()   { echo -e "${RED}✗${NC} $1" >&2; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1" >&2; }
print_info()    { echo -e "${BLUE}ℹ${NC} $1" >&2; }

###########################################
# Validación de entorno
###########################################

check_environment() {
    print_header "VERIFICANDO ENTORNO"

    # Verificar docker-compose.yml
    if [[ ! -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
        print_error "No se encontró docker-compose.yml en ${INSTALL_DIR}"
        exit 1
    fi

    cd "${INSTALL_DIR}" || exit 1

    # Verificar contenedor PHP
    if ! docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx "${CONTAINER_PHP}"; then
        print_error "Contenedor PHP no está corriendo"
        exit 1
    fi
    print_success "Contenedor PHP activo"

    # Verificar contenedor Redis
    if ! docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx "${CONTAINER_REDIS}"; then
        print_error "Contenedor Redis no está corriendo"
        print_info "Ejecuta: docker compose up -d redis"
        exit 1
    fi
    print_success "Contenedor Redis activo"

    # Verificar conectividad Redis
    if ! docker compose exec -T redis redis-cli ping 2>/dev/null | grep -q "PONG"; then
        print_error "Redis no responde"
        exit 1
    fi
    print_success "Redis responde correctamente"
}

###########################################
# Gestión de sitios
###########################################

get_sites() {
    SITES=()
    local site_dir

    for site_dir in "${INSTALL_DIR}/www"/*/; do
        if [[ -f "${site_dir}wp-config.php" ]]; then
            SITES+=("$(basename "${site_dir}")")
        fi
    done
}

list_sites() {
    get_sites

    if [[ ${#SITES[@]} -eq 0 ]]; then
        print_error "No se encontraron sitios WordPress en ${INSTALL_DIR}/www"
        return 1
    fi

    print_info "Sitios WordPress disponibles:"
    echo "" >&2

    local i=1
    for site_name in "${SITES[@]}"; do
        printf "  %d) %s\n" "$i" "$site_name" >&2
        ((i++))
    done
    echo "" >&2
}

###########################################
# Diagnóstico de sesiones
###########################################

diagnose_sessions() {
    print_header "DIAGNÓSTICO DE SESIONES"

    get_sites

    if [[ ${#SITES[@]} -eq 0 ]]; then
        print_error "No se encontraron sitios WordPress"
        return 1
    fi

    echo "" >&2
    local issues_found=0

    for site_name in "${SITES[@]}"; do
        local wp_config="${INSTALL_DIR}/www/${site_name}/wp-config.php"

        if [[ ! -f "${wp_config}" ]]; then
            print_warning "wp-config.php no encontrado para: ${site_name}"
            continue
        fi

        echo -e "${BLUE}━━━ ${site_name} ━━━${NC}" >&2

        # AUTH_COOKIE
        local auth_cookie
        if auth_cookie=$(grep -oP "define\('AUTH_COOKIE',\s*'\K[^']+" "${wp_config}" 2>/dev/null); then
            echo -e "  ${GREEN}AUTH_COOKIE: ${auth_cookie}${NC}" >&2
        else
            echo -e "  ${RED}AUTH_COOKIE: NO CONFIGURADO ⚠${NC}" >&2
            ((issues_found++))
        fi

        # COOKIEHASH
        local cookie_hash
        if cookie_hash=$(grep -oP "define\('COOKIEHASH',\s*'\K[^']+" "${wp_config}" 2>/dev/null); then
            echo -e "  ${GREEN}COOKIEHASH: ${cookie_hash}${NC}" >&2
        else
            echo -e "  ${RED}COOKIEHASH: NO CONFIGURADO ⚠${NC}" >&2
            ((issues_found++))
        fi

        # COOKIE_DOMAIN
        local cookie_domain
        if cookie_domain=$(grep -oP "define\('COOKIE_DOMAIN',\s*'\K[^']+" "${wp_config}" 2>/dev/null); then
            echo -e "  ${GREEN}COOKIE_DOMAIN: ${cookie_domain}${NC}" >&2
        else
            echo -e "  ${YELLOW}COOKIE_DOMAIN: NO CONFIGURADO${NC}" >&2
        fi

        # Redis prefix
        local redis_prefix
        if redis_prefix=$(grep -oP "define\('WP_REDIS_PREFIX',\s*'\K[^']+" "${wp_config}" 2>/dev/null); then
            echo -e "  ${GREEN}WP_REDIS_PREFIX: ${redis_prefix}${NC}" >&2
        else
            echo -e "  ${YELLOW}WP_REDIS_PREFIX: NO CONFIGURADO${NC}" >&2
        fi

        echo "" >&2
    done

    if [[ ${issues_found} -gt 0 ]]; then
        print_warning "Se encontraron ${issues_found} problemas de configuración"
    else
        print_success "Todas las cookies están configuradas correctamente"
    fi
}

###########################################
# Estado de Redis
###########################################

check_redis_status() {
    print_header "ESTADO DE REDIS"

    # Información del servidor
    print_info "Servidor Redis:"
    if ! docker compose exec -T redis redis-cli INFO server 2>/dev/null | \
         grep -E "^(redis_version|uptime_in_seconds|connected_clients)" | \
         sed 's/^/  /' >&2; then
        print_error "No se pudo obtener información del servidor"
        return 1
    fi

    echo "" >&2

    # Información de memoria
    print_info "Memoria Redis:"
    docker compose exec -T redis redis-cli INFO memory 2>/dev/null | \
        grep -E "^(used_memory_human|maxmemory_human)" | \
        sed 's/^/  /' >&2

    echo "" >&2

    # Keys por sitio
    print_info "Keys por sitio:"
    if ! docker compose exec -T redis redis-cli --scan --pattern "*_*" 2>/dev/null | \
         cut -d"_" -f1 | sort | uniq -c | sed 's/^/  /' >&2; then
        echo "  (sin datos)" >&2
    fi

    echo "" >&2

    # Estado de object-cache.php
    print_info "Estado de object-cache.php:"
    get_sites

    for site_name in "${SITES[@]}"; do
        local oc_path="${INSTALL_DIR}/www/${site_name}/wp-content/object-cache.php"

        if [[ ! -f "${oc_path}" ]]; then
            echo -e "  ${RED}✗${NC} ${site_name} - NO EXISTE" >&2
            continue
        fi

        if grep -q "'host' => 'redis'" "${oc_path}" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} ${site_name} - OK" >&2
        else
            echo -e "  ${YELLOW}⚠${NC} ${site_name} - host incorrecto" >&2
        fi
    done
}

###########################################
# Limpiar caché
###########################################

flush_redis() {
    local site_name="${1:-}"

    if [[ -z "${site_name}" ]]; then
        print_warning "¿Limpiar TODA la caché de Redis?"
        read -p "Escribe 'SI' para confirmar: " -r confirm

        if [[ "${confirm}" == "SI" ]]; then
            if docker compose exec -T redis redis-cli FLUSHALL >/dev/null 2>&1; then
                print_success "Caché Redis limpiada completamente"
            else
                print_error "No se pudo limpiar la caché"
                return 1
            fi
        else
            print_info "Operación cancelada"
        fi
    else
        # Validar que el sitio existe
        get_sites
        local site_exists=false
        for site in "${SITES[@]}"; do
            if [[ "${site}" == "${site_name}" ]]; then
                site_exists=true
                break
            fi
        done

        if [[ "${site_exists}" == false ]]; then
            print_error "Sitio no encontrado: ${site_name}"
            return 1
        fi

        print_info "Limpiando caché para: ${site_name}"

        # Contar keys antes
        local keys_before
        keys_before=$(docker compose exec -T redis redis-cli --scan --pattern "${site_name}_*" 2>/dev/null | wc -l)

        # Limpiar
        if docker compose exec -T redis sh -c "redis-cli --scan --pattern '${site_name}_*' | xargs -r redis-cli DEL" >/dev/null 2>&1; then
            print_success "Caché limpiada para ${site_name} (${keys_before} keys eliminadas)"
        else
            print_warning "No se encontraron keys para ${site_name}"
        fi
    fi
}

###########################################
# Ayuda
###########################################

show_usage() {
    cat << 'EOF' >&2
Uso: $0 [comando] [opciones]

Comandos disponibles:
    diagnose            Diagnosticar problemas de sesiones y cookies
    status              Ver estado de Redis (memoria, keys, conexiones)
    flush [sitio]       Limpiar caché de Redis (todo o un sitio específico)
    list                Listar sitios WordPress disponibles
    help                Mostrar esta ayuda

Ejemplos:
    $0 diagnose         # Analizar configuración de todos los sitios
    $0 status           # Ver estado actual de Redis
    $0 flush            # Limpiar toda la caché (requiere confirmación)
    $0 flush misite_com # Limpiar solo la caché de misite_com
    $0 list             # Mostrar sitios disponibles

EOF
}

###########################################
# Menú interactivo
###########################################

show_menu() {
    echo "" >&2
    echo "¿Qué deseas hacer?" >&2
    echo "" >&2
    echo "  1) Diagnosticar problemas de sesiones" >&2
    echo "  2) Ver estado de Redis" >&2
    echo "  3) Limpiar caché" >&2
    echo "  4) Salir" >&2
    echo "" >&2
    read -p "Opción: " -r option

    case "${option}" in
        1)
            diagnose_sessions
            ;;
        2)
            check_redis_status
            ;;
        3)
            list_sites
            read -p "Sitio (vacío=todos): " -r site
            flush_redis "${site}"
            ;;
        4)
            print_info "Saliendo..."
            exit 0
            ;;
        *)
            print_error "Opción no válida"
            return 1
            ;;
    esac
}

###########################################
# Main
###########################################

main() {
    print_header "WORDPRESS REDIS MONITORING"

    local command="${1:-}"
    local site="${2:-}"

    case "${command}" in
        diagnose)
            check_environment
            diagnose_sessions
            ;;
        status)
            check_environment
            check_redis_status
            ;;
        flush)
            check_environment
            flush_redis "${site}"
            ;;
        list)
            get_sites
            list_sites
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            check_environment
            show_menu
            ;;
    esac
}

# Ejecutar
main "$@"