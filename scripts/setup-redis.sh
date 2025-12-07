#!/bin/bash

###########################################
# WordPress Redis Cache Setup Script
# Configura Redis Object Cache para sitios WordPress
###########################################

set -euo pipefail

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Variables
INSTALL_DIR="/opt/wordpress-multisite"
CONTAINER_PHP="php"
CONTAINER_REDIS="redis"
REDIS_HOST="redis"
REDIS_PORT="6379"

print_header() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }

# Verificar que estamos en el directorio correcto
check_environment() {
    print_header "VERIFICANDO ENTORNO"

    if [[ ! -f "$INSTALL_DIR/docker-compose.yml" ]]; then
        print_error "No se encontró docker-compose.yml en $INSTALL_DIR"
        exit 1
    fi

    cd "$INSTALL_DIR"

    # Verificar contenedor PHP
    if ! docker compose ps --status running | grep -q "$CONTAINER_PHP"; then
        print_error "Contenedor PHP no está corriendo"
        exit 1
    fi
    print_success "Contenedor PHP activo"

    # Verificar contenedor Redis
    if ! docker compose ps --status running | grep -q "$CONTAINER_REDIS"; then
        print_error "Contenedor Redis no está corriendo"
        print_info "Ejecuta: docker compose up -d redis"
        exit 1
    fi
    print_success "Contenedor Redis activo"

    # Test de conexión Redis
    if docker compose exec -T redis redis-cli ping | grep -q "PONG"; then
        print_success "Redis responde correctamente"
    else
        print_error "Redis no responde"
        exit 1
    fi
}

# Listar sitios WordPress disponibles
list_sites() {
    print_info "Sitios WordPress disponibles:"
    echo ""

    local count=0
    for dir in "$INSTALL_DIR/www"/*/; do
        if [[ -f "${dir}wp-config.php" ]]; then
            local site_name=$(basename "$dir")
            ((count++))
            echo "  $count) $site_name"
        fi
    done

    if [[ $count -eq 0 ]]; then
        print_error "No se encontraron sitios WordPress"
        exit 1
    fi

    echo ""
    echo "  a) Todos los sitios"
    echo ""
}

# Configurar Redis para un sitio específico
configure_redis_for_site() {
    local site_name="$1"
    local site_path="/var/www/html/$site_name"
    local wp_config_path="$INSTALL_DIR/www/$site_name/wp-config.php"

    print_info "Configurando Redis para: $site_name"

    # Verificar que existe wp-config.php
    if [[ ! -f "$wp_config_path" ]]; then
        print_warning "wp-config.php no encontrado en $site_name, saltando..."
        return 1
    fi

    # Verificar si ya está configurado
    if grep -q "WP_REDIS_HOST" "$wp_config_path" 2>/dev/null; then
        print_warning "Redis ya configurado en $site_name"
        read -p "  ¿Reconfigurar? (s/n): " reconfig
        if [[ ! $reconfig =~ ^[Ss]$ ]]; then
            return 0
        fi
        # Eliminar configuración anterior
        sed -i '/WP_REDIS_/d' "$wp_config_path"
        sed -i '/WP_CACHE/d' "$wp_config_path"
    fi

    # Generar prefijo único para este sitio (evita colisiones en Redis)
    local redis_prefix="${site_name}_"

    # Agregar configuración de Redis antes de "/* That's all, stop editing! */"
    # o antes de "require_once ABSPATH"
    local redis_config="
/* Redis Object Cache Configuration */
define('WP_REDIS_HOST', '${REDIS_HOST}');
define('WP_REDIS_PORT', ${REDIS_PORT});
define('WP_REDIS_PREFIX', '${redis_prefix}');
define('WP_REDIS_DATABASE', 0);
define('WP_REDIS_TIMEOUT', 1);
define('WP_REDIS_READ_TIMEOUT', 1);
define('WP_CACHE', true);
"

    # Insertar configuración
    if grep -q "That's all, stop editing!" "$wp_config_path"; then
        sed -i "/That's all, stop editing!/i\\${redis_config}" "$wp_config_path"
    elif grep -q "require_once ABSPATH" "$wp_config_path"; then
        sed -i "/require_once ABSPATH/i\\${redis_config}" "$wp_config_path"
    else
        # Agregar al final antes de ?>
        sed -i "/^?>$/i\\${redis_config}" "$wp_config_path"
    fi

    print_success "Configuración Redis agregada a wp-config.php"

    # Descargar e instalar plugin Redis Object Cache
    print_info "Instalando plugin Redis Object Cache..."

    docker compose exec -T php sh -c "
        cd $site_path

        # Crear directorio de plugins si no existe
        mkdir -p wp-content/plugins

        # Descargar plugin si no existe
        if [ ! -d 'wp-content/plugins/redis-cache' ]; then
            cd wp-content/plugins
            wget -q https://downloads.wordpress.org/plugin/redis-cache.latest-stable.zip -O redis-cache.zip
            unzip -q redis-cache.zip
            rm redis-cache.zip
            echo 'Plugin descargado'
        else
            echo 'Plugin ya existe'
        fi

        # Copiar object-cache.php drop-in
        if [ -f 'wp-content/plugins/redis-cache/includes/object-cache.php' ]; then
            cp wp-content/plugins/redis-cache/includes/object-cache.php wp-content/object-cache.php
            echo 'Drop-in object-cache.php instalado'
        fi
    " 2>/dev/null || {
        print_warning "No se pudo instalar automáticamente el plugin"
        print_info "Instálalo manualmente desde wp-admin → Plugins → Añadir nuevo → 'Redis Object Cache'"
        return 0
    }

    # Corregir permisos
    chown -R 82:82 "$INSTALL_DIR/www/$site_name/wp-content/plugins/" 2>/dev/null || true
    chown 82:82 "$INSTALL_DIR/www/$site_name/wp-content/object-cache.php" 2>/dev/null || true

    print_success "Plugin Redis Object Cache instalado"

    # Verificar conexión desde el sitio
    print_info "Verificando conexión Redis..."

    docker compose exec -T php sh -c "
        php -r \"
            \\\$redis = new Redis();
            try {
                \\\$redis->connect('$REDIS_HOST', $REDIS_PORT, 1);
                echo 'Conexión Redis OK';
            } catch (Exception \\\$e) {
                echo 'Error: ' . \\\$e->getMessage();
            }
        \"
    " 2>/dev/null && print_success "Conexión Redis verificada" || print_warning "No se pudo verificar conexión"

    echo ""
    print_success "✓ Redis configurado para $site_name"
    print_info "  Prefijo: ${redis_prefix}"
    print_info "  Activar plugin en: http://${site_name}/wp-admin/plugins.php"

    return 0
}

# Verificar estado de Redis para todos los sitios
check_redis_status() {
    print_header "ESTADO DE REDIS"

    # Info del servidor Redis
    print_info "Servidor Redis:"
    docker compose exec -T redis redis-cli INFO server 2>/dev/null | grep -E "^(redis_version|uptime|connected_clients)" | sed 's/^/  /'

    echo ""
    print_info "Memoria Redis:"
    docker compose exec -T redis redis-cli INFO memory 2>/dev/null | grep -E "^(used_memory_human|maxmemory_human)" | sed 's/^/  /'

    echo ""
    print_info "Estadísticas:"
    docker compose exec -T redis redis-cli INFO stats 2>/dev/null | grep -E "^(keyspace_hits|keyspace_misses)" | sed 's/^/  /'

    # Calcular hit rate
    local hits=$(docker compose exec -T redis redis-cli INFO stats 2>/dev/null | grep "keyspace_hits" | cut -d: -f2 | tr -d '\r')
    local misses=$(docker compose exec -T redis redis-cli INFO stats 2>/dev/null | grep "keyspace_misses" | cut -d: -f2 | tr -d '\r')

    if [[ -n "$hits" && -n "$misses" && $((hits + misses)) -gt 0 ]]; then
        local hit_rate=$(echo "scale=2; $hits * 100 / ($hits + $misses)" | bc 2>/dev/null || echo "N/A")
        echo "  hit_rate: ${hit_rate}%"
    fi

    echo ""
    print_info "Keys por sitio:"
    docker compose exec -T redis redis-cli KEYS "*" 2>/dev/null | cut -d'_' -f1 | sort | uniq -c | sed 's/^/  /' || echo "  (sin datos)"
}

# Limpiar caché Redis
flush_redis() {
    local site_name="${1:-}"

    if [[ -z "$site_name" ]]; then
        print_warning "¿Limpiar TODA la caché de Redis?"
        read -p "Esto afectará todos los sitios (escribe 'SI' para confirmar): " confirm
        if [[ "$confirm" == "SI" ]]; then
            docker compose exec -T redis redis-cli FLUSHALL
            print_success "Caché Redis limpiada completamente"
        else
            print_info "Operación cancelada"
        fi
    else
        print_info "Limpiando caché para: $site_name"
        docker compose exec -T redis redis-cli KEYS "${site_name}_*" | xargs -r docker compose exec -T redis redis-cli DEL
        print_success "Caché limpiada para $site_name"
    fi
}

# Mostrar uso
show_usage() {
    cat << EOF
Uso: $0 [comando] [opciones]

Comandos:
    install [sitio]     Instalar y configurar Redis para un sitio
    install-all         Instalar Redis en todos los sitios
    status              Ver estado de Redis
    flush [sitio]       Limpiar caché (de un sitio o todos)
    list                Listar sitios disponibles
    help                Mostrar esta ayuda

Ejemplos:
    $0 install angel_guaman_net
    $0 install-all
    $0 status
    $0 flush angel_guaman_net
    $0 flush               # Limpia todo

EOF
}

# Main
main() {
    print_header "WORDPRESS REDIS CACHE SETUP"

    local command="${1:-}"
    local site="${2:-}"

    case "$command" in
        install)
            check_environment
            if [[ -z "$site" ]]; then
                list_sites
                read -p "Selecciona sitio (nombre o número): " site_input

                # Si es número, convertir a nombre
                if [[ "$site_input" =~ ^[0-9]+$ ]]; then
                    site=$(ls -1 "$INSTALL_DIR/www" | sed -n "${site_input}p")
                else
                    site="$site_input"
                fi
            fi

            if [[ -d "$INSTALL_DIR/www/$site" ]]; then
                configure_redis_for_site "$site"
            else
                print_error "Sitio no encontrado: $site"
                exit 1
            fi
            ;;

        install-all)
            check_environment
            print_info "Instalando Redis en todos los sitios..."
            echo ""

            for dir in "$INSTALL_DIR/www"/*/; do
                if [[ -f "${dir}wp-config.php" ]]; then
                    local site_name=$(basename "$dir")
                    configure_redis_for_site "$site_name"
                    echo ""
                fi
            done

            print_header "✓ COMPLETADO"
            print_success "Redis configurado en todos los sitios"
            ;;

        status)
            check_environment
            check_redis_status
            ;;

        flush)
            check_environment
            flush_redis "$site"
            ;;

        list)
            list_sites
            ;;

        help|--help|-h)
            show_usage
            ;;

        *)
            # Modo interactivo
            check_environment
            echo ""
            echo "¿Qué deseas hacer?"
            echo ""
            echo "  1) Instalar Redis en un sitio"
            echo "  2) Instalar Redis en todos los sitios"
            echo "  3) Ver estado de Redis"
            echo "  4) Limpiar caché"
            echo "  5) Salir"
            echo ""
            read -p "Opción: " option

            case "$option" in
                1)
                    list_sites
                    read -p "Nombre del sitio: " site
                    configure_redis_for_site "$site"
                    ;;
                2)
                    main "install-all"
                    ;;
                3)
                    check_redis_status
                    ;;
                4)
                    list_sites
                    read -p "Nombre del sitio (vacío = todos): " site
                    flush_redis "$site"
                    ;;
                5)
                    exit 0
                    ;;
                *)
                    print_error "Opción no válida"
                    ;;
            esac
            ;;
    esac
}

main "$@"