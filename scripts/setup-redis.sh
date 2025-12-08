#!/bin/bash

###########################################
# WordPress Redis Cache Setup Script
# Configura Redis Object Cache para sitios WordPress
###########################################

set -euo pipefail

# Evitar que los globs sin coincidencia iteren con el literal
shopt -s nullglob

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
REDIS_CLIENT="predis"
REDIS_HOST="redis"
REDIS_PORT="6379"

# Array global de sitios
SITES=()

# Variables para limpieza
TEMP_FILES=()

# Función de limpieza
cleanup() {
    for f in "${TEMP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null || true
    done
}

# Registrar trap para limpieza
trap cleanup EXIT

# Funciones de impresión - todas van a stderr para no interferir con capturas de stdout
print_header() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo -e "${BLUE}  $1${NC}" >&2
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n" >&2
}

print_success() { echo -e "${GREEN}✓${NC} $1" >&2; }
print_error()   { echo -e "${RED}✗${NC} $1" >&2; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1" >&2; }
print_info()    { echo -e "${BLUE}ℹ${NC} $1" >&2; }

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

# Rellenar array SITES con los sitios válidos
get_sites() {
    SITES=()
    for dir in "$INSTALL_DIR/www"/*/; do
        [[ -f "${dir}wp-config.php" ]] && SITES+=("$(basename "$dir")")
    done
}

# Validar si un sitio existe
validate_site() {
    local site_name="$1"
    get_sites

    for s in "${SITES[@]}"; do
        if [[ "$s" == "$site_name" ]]; then
            return 0
        fi
    done
    return 1
}

# Listar sitios WordPress disponibles
list_sites() {
    get_sites

    if ((${#SITES[@]} == 0)); then
        print_error "No se encontraron sitios WordPress en $INSTALL_DIR/www"
        return 1
    fi

    print_info "Sitios WordPress disponibles:"
    echo "" >&2
    local i=1
    for site_name in "${SITES[@]}"; do
        echo "  $i) $site_name" >&2
        ((i++))
    done

    echo "" >&2
    echo "  a) Todos los sitios" >&2
    echo "" >&2
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

    # Generar prefijo único para este sitio
    local redis_prefix="${site_name}_"

    # Crear archivo temporal con la configuración
    local temp_config
    temp_config=$(mktemp)
    TEMP_FILES+=("$temp_config")

    cat > "$temp_config" << REDIS_EOF

/* Redis Object Cache Configuration */
define('WP_REDIS_CLIENT', '${REDIS_CLIENT}');
define('WP_REDIS_HOST', '${REDIS_HOST}');
define('WP_REDIS_PORT', ${REDIS_PORT});
define('WP_REDIS_PREFIX', '${redis_prefix}');
define('WP_REDIS_DATABASE', 0);
define('WP_REDIS_TIMEOUT', 1);
define('WP_REDIS_READ_TIMEOUT', 1);
define('WP_CACHE', true);

REDIS_EOF

    # Insertar antes de "That's all, stop editing!" o "require_once ABSPATH"
    local wp_config_new="${wp_config_path}.new"
    TEMP_FILES+=("$wp_config_new")

    if grep -q "That's all, stop editing!" "$wp_config_path"; then
        local line_num
        line_num=$(grep -n "That's all, stop editing!" "$wp_config_path" | head -1 | cut -d: -f1)
        head -n $((line_num - 1)) "$wp_config_path" > "$wp_config_new"
        cat "$temp_config" >> "$wp_config_new"
        tail -n +${line_num} "$wp_config_path" >> "$wp_config_new"
        mv "$wp_config_new" "$wp_config_path"
    elif grep -q "require_once ABSPATH" "$wp_config_path"; then
        local line_num
        line_num=$(grep -n "require_once ABSPATH" "$wp_config_path" | head -1 | cut -d: -f1)
        head -n $((line_num - 1)) "$wp_config_path" > "$wp_config_new"
        cat "$temp_config" >> "$wp_config_new"
        tail -n +${line_num} "$wp_config_path" >> "$wp_config_new"
        mv "$wp_config_new" "$wp_config_path"
    else
        # Si no encuentra ninguno, agregar al final
        cat "$temp_config" >> "$wp_config_path"
    fi

    rm -f "$temp_config"

    # Corregir permisos
    if ! chown 82:82 "$wp_config_path" 2>/dev/null; then
        print_warning "No se pudieron cambiar permisos de wp-config.php (puede requerir sudo)"
    fi
    chmod 644 "$wp_config_path" 2>/dev/null || true

    print_success "Configuración Redis agregada a wp-config.php"

    # Descargar e instalar plugin Redis Object Cache
    install_redis_plugin "$site_name" "$site_path"

    # Verificar conexión desde el contenedor Redis
    verify_redis_connection

    echo "" >&2
    print_success "Redis configurado para $site_name"
    print_info "  Prefijo: ${redis_prefix}"
    print_info "  Activar plugin en: http://${site_name}/wp-admin/plugins.php"

    return 0
}

# Instalar plugin Redis Object Cache
install_redis_plugin() {
    local site_name="$1"
    local site_path="$2"

    print_info "Instalando plugin Redis Object Cache..."

    docker compose exec -T php sh -c "
        set -e
        cd $site_path

        # Crear directorio de plugins si no existe
        mkdir -p wp-content/plugins

        # Descargar plugin si no existe
        if [ ! -d 'wp-content/plugins/redis-cache' ]; then
            cd wp-content/plugins
            wget -q https://downloads.wordpress.org/plugin/redis-cache.latest-stable.zip -O redis-cache.zip
            unzip -q redis-cache.zip
            rm -f redis-cache.zip
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

    # Corregir host en object-cache.php
    fix_object_cache_host "$site_name"

    print_success "Plugin Redis Object Cache instalado"
}

# Corregir el host en object-cache.php para que sea 'redis'
fix_object_cache_host() {
    local site_name="$1"
    local object_cache_path="$INSTALL_DIR/www/$site_name/wp-content/object-cache.php"

    if [[ ! -f "$object_cache_path" ]]; then
        print_warning "object-cache.php no encontrado, no se puede corregir host"
        return 1
    fi

    # Verificar si el host ya es correcto
    if grep -q "'host' => 'redis'" "$object_cache_path" 2>/dev/null; then
        print_success "Host en object-cache.php ya es correcto ('redis')"
        return 0
    fi

    # Corregir el host usando sed
    # Busca el patrón 'host' => 'cualquier_valor' y lo reemplaza por 'host' => 'redis'
    if sed -i "s/'host' => '[^']*'/'host' => 'redis'/g" "$object_cache_path" 2>/dev/null; then
        print_success "Host corregido a 'redis' en object-cache.php"
    else
        print_warning "No se pudo corregir el host en object-cache.php"
        return 1
    fi

    # También corregir si usa comillas dobles
    sed -i 's/"host" => "[^"]*"/"host" => "redis"/g' "$object_cache_path" 2>/dev/null || true

    return 0
}

# Verificar conexión Redis usando redis-cli (más confiable que PHP)
verify_redis_connection() {
    print_info "Verificando conexión Redis..."

    # Usar redis-cli que es más confiable que depender de extensiones PHP
    local result
    result=$(docker compose exec -T redis redis-cli ping 2>/dev/null) || result=""

    if [[ "$result" == *"PONG"* ]]; then
        print_success "Conexión Redis verificada (PONG)"
        return 0
    else
        print_warning "No se pudo verificar conexión Redis"
        return 1
    fi
}

# Reparar/reinstalar object-cache.php para un sitio
repair_object_cache() {
    local site_name="$1"
    local site_path="/var/www/html/$site_name"
    local object_cache_local="$INSTALL_DIR/www/$site_name/wp-content/object-cache.php"
    local plugin_path="$INSTALL_DIR/www/$site_name/wp-content/plugins/redis-cache"

    if [[ -z "$site_name" ]]; then
        print_error "Debes especificar un sitio"
        return 1
    fi

    if [[ ! -d "$INSTALL_DIR/www/$site_name" ]]; then
        print_error "Sitio no encontrado: $site_name"
        return 1
    fi

    print_info "Reparando object-cache.php para: $site_name"

    # Verificar si existe el plugin
    if [[ ! -d "$plugin_path" ]]; then
        print_warning "Plugin redis-cache no instalado, descargando..."

        docker compose exec -T php sh -c "
            set -e
            cd $site_path
            mkdir -p wp-content/plugins
            cd wp-content/plugins
            wget -q https://downloads.wordpress.org/plugin/redis-cache.latest-stable.zip -O redis-cache.zip
            unzip -q redis-cache.zip
            rm -f redis-cache.zip
            echo 'Plugin descargado'
        " 2>/dev/null || {
            print_error "No se pudo descargar el plugin redis-cache"
            return 1
        }

        chown -R 82:82 "$plugin_path" 2>/dev/null || true
    fi

    # Eliminar object-cache.php actual si existe
    if [[ -f "$object_cache_local" ]]; then
        print_info "Eliminando object-cache.php actual..."
        rm -f "$object_cache_local"
    fi

    # Copiar object-cache.php fresco desde el plugin
    local plugin_object_cache="$plugin_path/includes/object-cache.php"

    if [[ ! -f "$plugin_object_cache" ]]; then
        print_error "No se encontró object-cache.php en el plugin"
        return 1
    fi

    cp "$plugin_object_cache" "$object_cache_local"
    print_success "object-cache.php copiado desde el plugin"

    # Corregir el host para que sea 'redis'
    fix_object_cache_host "$site_name"

    # Corregir permisos
    chown 82:82 "$object_cache_local" 2>/dev/null || true
    chmod 644 "$object_cache_local" 2>/dev/null || true

    # Verificar que wp-config.php tiene la configuración de Redis
    local wp_config_path="$INSTALL_DIR/www/$site_name/wp-config.php"
    if ! grep -q "WP_REDIS_HOST" "$wp_config_path" 2>/dev/null; then
        print_warning "wp-config.php no tiene configuración de Redis"
        print_info "Ejecuta: $0 install $site_name"
    else
        print_success "wp-config.php tiene configuración de Redis"
    fi

    # Verificar conexión
    verify_redis_connection

    print_success "object-cache.php reparado para $site_name"

    return 0
}

# Reparar todos los sitios
repair_all_object_cache() {
    print_info "Reparando object-cache.php en todos los sitios..."
    echo "" >&2

    get_sites

    if ((${#SITES[@]} == 0)); then
        print_error "No se encontraron sitios WordPress"
        return 1
    fi

    local success_count=0
    local fail_count=0

    for site_name in "${SITES[@]}"; do
        if repair_object_cache "$site_name"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
        echo "" >&2
    done

    print_header "RESUMEN DE REPARACIÓN"
    print_success "Sitios reparados: $success_count"
    if ((fail_count > 0)); then
        print_warning "Sitios con errores: $fail_count"
    fi
}

# Verificar estado de Redis para todos los sitios
check_redis_status() {
    print_header "ESTADO DE REDIS"

    # Info del servidor Redis
    print_info "Servidor Redis:"
    docker compose exec -T redis redis-cli INFO server 2>/dev/null | grep -E "^(redis_version|uptime_in_seconds|connected_clients)" | sed 's/^/  /' >&2

    echo "" >&2
    print_info "Memoria Redis:"
    docker compose exec -T redis redis-cli INFO memory 2>/dev/null | grep -E "^(used_memory_human|maxmemory_human)" | sed 's/^/  /' >&2

    echo "" >&2
    print_info "Estadísticas:"
    docker compose exec -T redis redis-cli INFO stats 2>/dev/null | grep -E "^(keyspace_hits|keyspace_misses)" | sed 's/^/  /' >&2

    # Calcular hit rate
    local hits
    local misses
    hits=$(docker compose exec -T redis redis-cli INFO stats 2>/dev/null | grep "keyspace_hits" | cut -d: -f2 | tr -d '\r')
    misses=$(docker compose exec -T redis redis-cli INFO stats 2>/dev/null | grep "keyspace_misses" | cut -d: -f2 | tr -d '\r')

    if [[ -n "${hits:-}" && -n "${misses:-}" && $((hits + misses)) -gt 0 ]]; then
        local hit_rate
        hit_rate=$(echo "scale=2; $hits * 100 / ($hits + $misses)" | bc 2>/dev/null || echo "N/A")
        echo "  hit_rate: ${hit_rate}%" >&2
    fi

    echo "" >&2
    print_info "Keys por sitio:"
    docker compose exec -T redis sh -c '
        redis-cli --scan --pattern "*_*" 2>/dev/null | cut -d"_" -f1 | sort | uniq -c
    ' 2>/dev/null | sed 's/^/  /' >&2 || echo "  (sin datos)" >&2

    echo "" >&2
    print_info "Estado de object-cache.php por sitio:"
    get_sites
    for site_name in "${SITES[@]}"; do
        local oc_path="$INSTALL_DIR/www/$site_name/wp-content/object-cache.php"
        if [[ -f "$oc_path" ]]; then
            if grep -q "'host' => 'redis'" "$oc_path" 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} $site_name - object-cache.php OK (host=redis)" >&2
            else
                local current_host
                current_host=$(grep -oP "'host' => '\K[^']+" "$oc_path" 2>/dev/null || echo "desconocido")
                echo -e "  ${YELLOW}⚠${NC} $site_name - object-cache.php host incorrecto ($current_host)" >&2
            fi
        else
            echo -e "  ${RED}✗${NC} $site_name - object-cache.php NO EXISTE" >&2
        fi
    done
}

# Limpiar caché Redis
flush_redis() {
    local site_name="${1:-}"

    if [[ -z "$site_name" ]]; then
        print_warning "¿Limpiar TODA la caché de Redis?"
        read -p "Esto afectará todos los sitios (escribe 'SI' para confirmar): " confirm
        if [[ "$confirm" == "SI" ]]; then
            if docker compose exec -T redis redis-cli FLUSHALL | grep -q "OK"; then
                print_success "Caché Redis limpiada completamente"
            else
                print_error "Error al limpiar caché"
            fi
        else
            print_info "Operación cancelada"
        fi
    else
        print_info "Limpiando caché para: $site_name"
        local deleted
        deleted=$(docker compose exec -T redis sh -c "
            keys=\$(redis-cli --scan --pattern '${site_name}_*' 2>/dev/null)
            if [ -n \"\$keys\" ]; then
                count=\$(printf '%s\n' \$keys | wc -w)
                printf '%s\n' \$keys | xargs -r -n 100 redis-cli DEL >/dev/null 2>&1
                echo \$count
            else
                echo 0
            fi
        " 2>/dev/null)
        print_success "Caché limpiada para $site_name ($deleted keys eliminadas)"
    fi
}

# Mostrar uso
show_usage() {
    cat << EOF >&2
Uso: $0 [comando] [opciones]

Comandos:
    install [sitio]     Instalar y configurar Redis para un sitio
    install-all         Instalar Redis en todos los sitios
    repair [sitio]      Reparar/reinstalar object-cache.php (corrige host a 'redis')
    repair-all          Reparar object-cache.php en todos los sitios
    status              Ver estado de Redis y object-cache.php
    flush [sitio]       Limpiar caché (de un sitio o todos)
    list                Listar sitios disponibles
    help                Mostrar esta ayuda

Ejemplos:
    $0 install midominio_com
    $0 install-all
    $0 repair midominio_com
    $0 repair-all
    $0 status
    $0 flush midominio_com
    $0 flush                    # Limpia todo (requiere confirmación)

Notas:
    - El comando 'repair' reinstala object-cache.php y asegura que
      el host sea 'redis' para conexión correcta con el contenedor.
    - El comando 'status' muestra el estado del host en cada sitio.

EOF
}

# Seleccionar sitio interactivamente
select_site() {
    # Mostrar lista de sitios (va a stderr para que no se capture)
    list_sites || return 1

    read -p "Selecciona sitio (nombre o número): " site_input

    # Si es número, convertir a nombre usando el array SITES
    if [[ "$site_input" =~ ^[0-9]+$ ]]; then
        local idx=$((site_input - 1))
        if (( idx < 0 || idx >= ${#SITES[@]} )); then
            print_error "Índice fuera de rango"
            return 1
        fi
        # Solo esto va a stdout para ser capturado
        echo "${SITES[$idx]}"
    else
        # Validar que el sitio existe
        if validate_site "$site_input"; then
            # Solo esto va a stdout para ser capturado
            echo "$site_input"
        else
            print_error "Sitio no encontrado: $site_input"
            return 1
        fi
    fi
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
                site=$(select_site) || exit 1
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
            echo "" >&2

            get_sites
            if ((${#SITES[@]} == 0)); then
                print_error "No se encontraron sitios WordPress en $INSTALL_DIR/www"
                exit 1
            fi

            for site_name in "${SITES[@]}"; do
                configure_redis_for_site "$site_name"
                echo "" >&2
            done

            print_header "COMPLETADO"
            print_success "Redis configurado en todos los sitios"
            ;;

        repair)
            check_environment
            if [[ -z "$site" ]]; then
                site=$(select_site) || exit 1
            fi
            repair_object_cache "$site"
            ;;

        repair-all)
            check_environment
            repair_all_object_cache
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
            # Listar no requiere contenedores
            list_sites
            ;;

        help|--help|-h)
            show_usage
            ;;

        *)
            # Modo interactivo
            check_environment
            echo "" >&2
            echo "¿Qué deseas hacer?" >&2
            echo "" >&2
            echo "  1) Instalar Redis en un sitio" >&2
            echo "  2) Instalar Redis en todos los sitios" >&2
            echo "  3) Reparar object-cache.php en un sitio" >&2
            echo "  4) Reparar object-cache.php en todos los sitios" >&2
            echo "  5) Ver estado de Redis" >&2
            echo "  6) Limpiar caché" >&2
            echo "  7) Salir" >&2
            echo "" >&2
            read -p "Opción: " option

            case "$option" in
                1)
                    site=$(select_site) || exit 1
                    configure_redis_for_site "$site"
                    ;;
                2)
                    main "install-all"
                    ;;
                3)
                    site=$(select_site) || exit 1
                    repair_object_cache "$site"
                    ;;
                4)
                    repair_all_object_cache
                    ;;
                5)
                    check_redis_status
                    ;;
                6)
                    list_sites || true
                    read -p "Nombre del sitio (vacío = todos): " site
                    flush_redis "$site"
                    ;;
                7)
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