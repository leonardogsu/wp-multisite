#!/bin/bash

################################################################################
# WordPress Multi-Site - Instalador Automático (REFACTORIZADO)
# Versión optimizada para eficiencia
# Para Ubuntu 24.04 LTS
################################################################################

set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURACIÓN Y CONSTANTES
# ══════════════════════════════════════════════════════════════════════════════

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_NAME="wordpress-multisite"
readonly INSTALL_DIR="/opt/$PROJECT_NAME"
readonly LOG_FILE="/var/log/${PROJECT_NAME}-install.log"
readonly CONFIG_FILE="$SCRIPT_DIR/config.yml"

# Colores (usando tput para mayor compatibilidad)
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
declare -A DOMAIN_SANITIZED=()  # Caché de nombres sanitizados
declare -A SFTP_PASSWORDS=()    # Asociativo: domain -> password
declare -A DB_PASSWORDS=()      # Asociativo: domain -> password
declare SERVER_IP="" IP_VERSION="" MYSQL_ROOT_PASSWORD=""
declare SETUP_CRON=false INSTALL_NETDATA=false INSTALL_REDIS=false UNATTENDED_MODE=false

# ══════════════════════════════════════════════════════════════════════════════
# FUNCIONES DE UTILIDAD (OPTIMIZADAS)
# ══════════════════════════════════════════════════════════════════════════════

# Logging unificado - una sola función con prefijo variable
_log() {
    local level="$1" color="$2" msg="${*:3}"
    printf '%b[%s][%s]%b %s\n' "$color" "$(date +%T)" "$level" "$NC" "$msg" | tee -a "$LOG_FILE"
}
log()     { _log "INFO" "$GREEN" "$@"; }
error()   { _log "ERROR" "$RED" "$@"; exit 1; }
warning() { _log "WARN" "$YELLOW" "$@"; }
info()    { _log "INFO" "$BLUE" "$@"; }
success() { _log "OK" "$GREEN" "✓ $*"; }
banner()  { echo -e "${CYAN}$*${NC}" | tee -a "$LOG_FILE"; }

# Sanitizar dominio con caché (SIN subshell)
sanitize_domain() {
    local domain="$1"
    local sanitized="${domain//./_}"
    sanitized="${sanitized//-/_}"
    sanitized="${sanitized//[^a-zA-Z0-9_]/}"
    echo "$sanitized"
}

# Pre-poblar caché de dominios sanitizados (llamar después de cargar DOMAINS)
populate_domain_cache() {
    for domain in "${DOMAINS[@]}"; do
        DOMAIN_SANITIZED[$domain]=$(sanitize_domain "$domain")
    done
}

# Generar contraseña (bash puro cuando sea posible)
generate_password() {
    local length="${1:-32}"
    if command -v pwgen &>/dev/null; then
        pwgen -s "$length" 1
    else
        # Fallback bash puro
        head -c 100 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$length"
    fi
}

# Ejecutar apt silenciosamente
apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >> "$LOG_FILE" 2>&1
}

# Verificar comando existe
cmd_exists() { command -v "$1" &>/dev/null; }

# ══════════════════════════════════════════════════════════════════════════════
# EXPORTAR VARIABLES (una sola función centralizada)
# ══════════════════════════════════════════════════════════════════════════════

export_credentials() {
    export MYSQL_ROOT_PASSWORD SERVER_IP IP_VERSION

    local i=1
    for domain in "${DOMAINS[@]}"; do
        local san="${DOMAIN_SANITIZED[$domain]}"
        export "DB_PASSWORD_$i=${DB_PASSWORDS[$domain]}"
        export "SFTP_${san^^}_PASSWORD=${SFTP_PASSWORDS[$domain]}"
        ((i++))
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# YQ INSTALLATION (simplificado)
# ══════════════════════════════════════════════════════════════════════════════

install_yq() {
    # Verificar si ya está instalado correctamente
    if cmd_exists yq && [[ "$(yq --version 2>&1)" == *"mikefarah"* ]]; then
        return 0
    fi

    log "Instalando yq..."

    # Remover versión incompatible
    rm -f /usr/local/bin/yq /usr/bin/yq 2>/dev/null || true
    apt-get remove -y yq >> "$LOG_FILE" 2>&1 || true

    # Mapeo de arquitectura
    local arch_map=([amd64]="amd64" [arm64]="arm64" [armhf]="arm" [i386]="386")
    local arch
    arch=$(dpkg --print-architecture)
    local yq_arch="${arch_map[$arch]:-}"

    [[ -z "$yq_arch" ]] && error "Arquitectura no soportada: $arch"

    wget -qO /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}" \
        && chmod +x /usr/local/bin/yq \
        && ln -sf /usr/local/bin/yq /usr/bin/yq 2>/dev/null || true

    /usr/local/bin/yq --version >> "$LOG_FILE" 2>&1 || error "yq installation failed"
    success "yq instalado"
}

# ══════════════════════════════════════════════════════════════════════════════
# VERIFICACIONES DEL SISTEMA (consolidadas)
# ══════════════════════════════════════════════════════════════════════════════

check_prerequisites() {
    banner "══ PASO 1: Verificación de requisitos ══"

    # Root check
    [[ $EUID -eq 0 ]] || error "Ejecutar como root (sudo)"

    # Ubuntu check
    if ! grep -q "24.04" /etc/os-release 2>/dev/null; then
        warning "Diseñado para Ubuntu 24.04 LTS"
        [[ $UNATTENDED_MODE == false ]] && { read -rp "¿Continuar? (s/n): " c; [[ $c =~ ^[Ss]$ ]] || exit 1; }
    else
        success "Ubuntu 24.04 LTS"
    fi

    # RAM & Disk (lectura única de /proc y df)
    local ram_mb disk_gb
    ram_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    disk_gb=$(df / --output=avail | tail -1 | awk '{print int($1/1024/1024)}')

    [[ $ram_mb -lt 4000 ]] && warning "RAM: ${ram_mb}MB (recomendado 8GB+)" || success "RAM: ${ram_mb}MB"
    [[ $disk_gb -lt 20 ]] && warning "Disco: ${disk_gb}GB (recomendado 20GB+)" || success "Disco: ${disk_gb}GB"

    # Config file check
    if [[ -f "$CONFIG_FILE" ]]; then
        success "Config YAML encontrado"
        UNATTENDED_MODE=true
        install_yq
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# DETECCIÓN DE IP (optimizada)
# ══════════════════════════════════════════════════════════════════════════════

detect_ips() {
    local -n ipv4_ref=$1 ipv6_ref=$2

    # IPv4 - intentar servicios externos, luego local
    ipv4_ref=$(curl -4s --max-time 5 ifconfig.me 2>/dev/null) || \
    ipv4_ref=$(ip -4 route get 1 2>/dev/null | awk '{print $7; exit}') || \
    ipv4_ref=""

    # IPv6
    ipv6_ref=$(curl -6s --max-time 5 ifconfig.me 2>/dev/null) || \
    ipv6_ref=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2; exit}' | cut -d/ -f1) || \
    ipv6_ref=""
}

# ══════════════════════════════════════════════════════════════════════════════
# CARGAR CONFIGURACIÓN YAML
# ══════════════════════════════════════════════════════════════════════════════

load_yaml_config() {
    [[ -f "$CONFIG_FILE" ]] || return 1

    log "Cargando configuración YAML..."

    # Leer todo de una vez (menos llamadas a yq)
    local config
    config=$(yq eval -o=json '.' "$CONFIG_FILE" 2>/dev/null) || error "YAML inválido"

    # Extraer valores con jq (más eficiente que múltiples llamadas a yq)
    IP_VERSION=$(echo "$config" | jq -r '.server.ip_version // "ipv4"' | tr '[:upper:]' '[:lower:]')
    local ip_addr
    ip_addr=$(echo "$config" | jq -r '.server.ip_address // ""')

    # IP detection si no está especificada
    if [[ -n "$ip_addr" && "$ip_addr" != "null" ]]; then
        SERVER_IP="$ip_addr"
    else
        local ipv4="" ipv6=""
        detect_ips ipv4 ipv6

        case "$IP_VERSION" in
            ipv4) SERVER_IP="$ipv4"; [[ -z "$SERVER_IP" ]] && error "IPv4 no detectada" ;;
            ipv6) SERVER_IP="$ipv6"; [[ -z "$SERVER_IP" ]] && error "IPv6 no detectada" ;;
            both|dual) SERVER_IP="${ipv4:-$ipv6}"; [[ -z "$SERVER_IP" ]] && error "IP no detectada" ;;
            *) error "ip_version inválida: $IP_VERSION" ;;
        esac
    fi
    success "IP ($IP_VERSION): $SERVER_IP"

    # Cargar dominios (una sola llamada a yq)
    mapfile -t DOMAINS < <(echo "$config" | jq -r '.domains[]? // empty')
    [[ ${#DOMAINS[@]} -eq 0 ]] && error "No hay dominios configurados"
    success "Dominios: ${#DOMAINS[@]}"

    # Opciones booleanas
    SETUP_CRON=$(echo "$config" | jq -r '.options.setup_cron // false')
    INSTALL_NETDATA=$(echo "$config" | jq -r '.options.install_netdata // false')
    INSTALL_REDIS=$(echo "$config" | jq -r '.options.install_redis // false')

    # Normalizar booleanos
    [[ "$SETUP_CRON" == "true" ]] && SETUP_CRON=true || SETUP_CRON=false
    [[ "$INSTALL_NETDATA" == "true" ]] && INSTALL_NETDATA=true || INSTALL_NETDATA=false
    [[ "$INSTALL_REDIS" == "true" ]] && INSTALL_REDIS=true || INSTALL_REDIS=false
}

# ══════════════════════════════════════════════════════════════════════════════
# ENTRADA INTERACTIVA (simplificada)
# ══════════════════════════════════════════════════════════════════════════════

gather_interactive_input() {
    banner "══ PASO 2: Recopilación de información ══"

    if [[ $UNATTENDED_MODE == true ]]; then
        load_yaml_config
    else
        # Detección IP
        local ipv4="" ipv6=""
        detect_ips ipv4 ipv6

        echo -e "\nDirecciones IP detectadas:"
        [[ -n "$ipv4" ]] && echo "  1) IPv4: $ipv4" || echo "  1) IPv4: (no detectada)"
        [[ -n "$ipv6" ]] && echo "  2) IPv6: $ipv6" || echo "  2) IPv6: (no detectada)"
        echo "  3) Manual"

        while true; do
            read -rp "Selecciona [1-3]: " choice
            case "$choice" in
                1) [[ -n "$ipv4" ]] && { SERVER_IP="$ipv4"; IP_VERSION="ipv4"; break; } ;;
                2) [[ -n "$ipv6" ]] && { SERVER_IP="$ipv6"; IP_VERSION="ipv6"; break; } ;;
                3) read -rp "IP: " SERVER_IP
                   read -rp "¿IPv4 o IPv6? (4/6): " v
                   IP_VERSION=$([[ "$v" == "6" ]] && echo "ipv6" || echo "ipv4")
                   break ;;
            esac
        done

        # Dominios
        echo -e "\nIngresa dominios (Enter vacío para terminar):"
        while read -rp "  Dominio: " domain && [[ -n "$domain" ]]; do
            if [[ $domain =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
                DOMAINS+=("$domain")
            else
                warning "Formato inválido"
            fi
        done
        [[ ${#DOMAINS[@]} -eq 0 ]] && error "Se requiere al menos un dominio"

        # Opciones (lectura simplificada)
        read -rp "¿Backup automático? (s/n): " r; [[ $r =~ ^[Ss]$ ]] && SETUP_CRON=true
        read -rp "¿Instalar Netdata? (s/n): " r; [[ $r =~ ^[Ss]$ ]] && INSTALL_NETDATA=true
        read -rp "¿Instalar Redis? (s/n): " r; [[ $r =~ ^[Ss]$ ]] && INSTALL_REDIS=true
    fi

    # Pre-calcular nombres sanitizados
    populate_domain_cache

    show_config_summary
}

show_config_summary() {
    banner "══ RESUMEN ══"
    echo "  IP ($IP_VERSION): $SERVER_IP"
    echo "  Sitios: ${#DOMAINS[@]}"
    for domain in "${DOMAINS[@]}"; do
        echo "    - $domain → ${DOMAIN_SANITIZED[$domain]}"
    done
    echo "  phpMyAdmin: ✓ | SFTP: ✓ (2222)"
    $INSTALL_NETDATA && echo "  Netdata: ✓ (19999)"
    $INSTALL_REDIS && echo "  Redis: ✓"
    echo "  Backup: $($SETUP_CRON && echo 'Sí' || echo 'No')"

    if [[ $UNATTENDED_MODE == false ]]; then
        read -rp "¿Continuar? (s/n): " c
        [[ $c =~ ^[Ss]$ ]] || error "Cancelado"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# INSTALACIÓN DE PAQUETES (consolidada)
# ══════════════════════════════════════════════════════════════════════════════

install_packages() {
    banner "══ PASO 3: Instalación de paquetes ══"

    export DEBIAN_FRONTEND=noninteractive

    log "Actualizando sistema..."
    apt-get update -qq >> "$LOG_FILE" 2>&1
    apt-get upgrade -y -qq >> "$LOG_FILE" 2>&1 || true
    success "Sistema actualizado"

    log "Instalando dependencias..."
    apt_install apt-transport-https ca-certificates curl gnupg lsb-release \
        software-properties-common git wget unzip pwgen jq ufw cron \
        apache2-utils openssh-client
    success "Dependencias instaladas"

    # yq si no está
    cmd_exists yq || install_yq
}

install_docker() {
    banner "══ PASO 4: Docker ══"

    if cmd_exists docker; then
        success "Docker ya instalado: $(docker --version)"
    else
        log "Instalando Docker..."

        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        local codename
        codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $codename stable" > /etc/apt/sources.list.d/docker.list

        apt-get update -qq >> "$LOG_FILE" 2>&1
        apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        success "Docker instalado"
    fi

    docker compose version &>/dev/null || error "Docker Compose no disponible"
    success "Docker Compose disponible"
}

# ══════════════════════════════════════════════════════════════════════════════
# FIREWALL (simplificado)
# ══════════════════════════════════════════════════════════════════════════════

configure_firewall() {
    banner "══ PASO 5: Firewall ══"

    ufw --force reset >> "$LOG_FILE" 2>&1
    ufw default deny incoming >> "$LOG_FILE" 2>&1
    ufw default allow outgoing >> "$LOG_FILE" 2>&1

    # Puertos en un loop
    local ports=("22/tcp:SSH" "80/tcp:HTTP" "443/tcp:HTTPS" "2222/tcp:SFTP")
    for p in "${ports[@]}"; do
        ufw allow "${p%:*}" comment "${p#*:}" >> "$LOG_FILE" 2>&1
    done

    ufw --force enable >> "$LOG_FILE" 2>&1
    success "Firewall configurado (22, 80, 443, 2222)"
}

# ══════════════════════════════════════════════════════════════════════════════
# NETDATA (condicional)
# ══════════════════════════════════════════════════════════════════════════════

install_netdata() {
    $INSTALL_NETDATA || return 0

    banner "══ Netdata ══"

    if curl -fsSL https://get.netdata.cloud/kickstart.sh -o /tmp/netdata.sh; then
        bash /tmp/netdata.sh --non-interactive --stable-channel --disable-telemetry >> "$LOG_FILE" 2>&1 || {
            warning "Error instalando Netdata"
            return 1
        }
        rm -f /tmp/netdata.sh

        # Configurar solo localhost
        local conf="/etc/netdata/netdata.conf"
        [[ -f "$conf" ]] && sed -i 's/^[[:space:]]*bind socket to IP =.*/    bind socket to IP = 127.0.0.1/' "$conf"

        systemctl restart netdata 2>/dev/null || true
        success "Netdata instalado (acceso solo por túnel SSH)"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# ESTRUCTURA Y CREDENCIALES
# ══════════════════════════════════════════════════════════════════════════════

setup_structure() {
    banner "══ PASO 6: Estructura de directorios ══"

    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    # Crear todos los directorios de una vez
    mkdir -p nginx/{conf.d,auth} php mysql/{init,data} www certbot/{conf,www} \
             logs/{nginx,php,mysql} scripts backups templates

    success "Estructura creada"
}

check_mysql_volume() {
    banner "══ PASO 7: Verificación MySQL ══"

    if docker volume inspect mysql-data &>/dev/null; then
        warning "Volumen MySQL existente"
        if [[ $UNATTENDED_MODE == false ]]; then
            read -rp "¿Eliminar datos anteriores? (s/n): " r
            [[ $r =~ ^[Ss]$ ]] && docker volume rm mysql-data >> "$LOG_FILE" 2>&1 || true
        fi
    else
        success "Sin volumen MySQL previo"
    fi
}

generate_all_credentials() {
    banner "══ PASO 8: Generación de credenciales ══"

    MYSQL_ROOT_PASSWORD=$(generate_password 32)

    # Generar credenciales para todos los dominios
    for domain in "${DOMAINS[@]}"; do
        DB_PASSWORDS[$domain]=$(generate_password 32)
        SFTP_PASSWORDS[$domain]=$(generate_password 24)
    done

    # ════════════════════════════════════════════════════════════════════
    # ARCHIVO .credentials (formato legible)
    # ════════════════════════════════════════════════════════════════════
    local cred_file="$INSTALL_DIR/.credentials"
    {
        cat << HEADER
# CREDENCIALES DEL SISTEMA
# Generadas: $(date)
# GUARDAR EN LUGAR SEGURO

MySQL Root Password: $MYSQL_ROOT_PASSWORD

# Credenciales por sitio
HEADER

        for domain in "${DOMAINS[@]}"; do
            local san="${DOMAIN_SANITIZED[$domain]}"
            cat << SITE

=== ${domain} ===
Carpeta: ${san}
Base de datos: ${san}
Usuario DB: wpuser_${san}
Password DB: ${DB_PASSWORDS[$domain]}
Usuario SFTP: sftp_${san}
Password SFTP: ${SFTP_PASSWORDS[$domain]}
SITE
        done
    } > "$cred_file"
    chmod 600 "$cred_file"
    chown root:root "$cred_file"

    # ════════════════════════════════════════════════════════════════════
    # ARCHIVO .env (formato para docker-compose y scripts)
    # ════════════════════════════════════════════════════════════════════
    {
        cat << ENV_HEADER
# Variables de entorno
# Generadas: $(date)

# MySQL
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD

# Servidor
SERVER_IP=$SERVER_IP
IP_VERSION=$IP_VERSION

# Opciones
INSTALL_PHPMYADMIN=true
INSTALL_SFTP=true

# Dominios
ENV_HEADER

        local i=1
        for domain in "${DOMAINS[@]}"; do
            echo "DOMAIN_$i=$domain"
            ((i++))
        done

        echo ""
        echo "# Database passwords por sitio"
        i=1
        for domain in "${DOMAINS[@]}"; do
            echo "DB_PASSWORD_$i=${DB_PASSWORDS[$domain]}"
            ((i++))
        done

        echo ""
        echo "# SFTP - Usuarios independientes por sitio"
        for domain in "${DOMAINS[@]}"; do
            local san="${DOMAIN_SANITIZED[$domain]}"
            local san_upper="${san^^}"
            echo "SFTP_${san_upper}_PASSWORD=${SFTP_PASSWORDS[$domain]}"
        done
    } > .env
    chmod 600 .env
    chown root:root .env

    export_credentials
    success "Credenciales generadas"
}

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURACIÓN Y SETUP
# ══════════════════════════════════════════════════════════════════════════════

copy_templates() {
    banner "══ PASO 9: Templates y scripts ══"

    [[ -d "$SCRIPT_DIR/templates" ]] && cp -r "$SCRIPT_DIR/templates"/* templates/
    [[ -d "$SCRIPT_DIR/scripts" ]] && { cp -r "$SCRIPT_DIR/scripts"/* scripts/; chmod +x scripts/*.sh; }

    success "Templates copiados"
}

run_configuration() {
    banner "══ PASO 10: Generación de configuraciones ══"
    export_credentials
    ./scripts/generate-config.sh || error "Error en generate-config.sh"
    success "Configuraciones generadas"
}

run_wordpress_setup() {
    banner "══ PASO 11: WordPress Setup ══"
    export_credentials
    ./scripts/setup.sh || error "Error en setup.sh"
    success "WordPress instalado"
}

# ══════════════════════════════════════════════════════════════════════════════
# PERMISOS WORDPRESS (optimizado - un solo loop)
# ══════════════════════════════════════════════════════════════════════════════

set_wordpress_permissions() {
    banner "══ PASO 12: Permisos WordPress ══"

    sleep 3  # Esperar contenedores

    for domain in "${DOMAINS[@]}"; do
        local san="${DOMAIN_SANITIZED[$domain]}"
        local site_path="$INSTALL_DIR/www/$san"

        log "Permisos para $domain..."

        # Permisos desde contenedor PHP
        docker compose exec -T php sh -c "
            [ -d '/var/www/html/$san' ] || exit 0
            chown -R www-data:www-data /var/www/html/$san
            find /var/www/html/$san -type d -exec chmod 755 {} \;
            find /var/www/html/$san -type f -exec chmod 644 {} \;
            mkdir -p /var/www/html/$san/wp-content/{uploads,plugins,themes,upgrade}
            chmod -R 775 /var/www/html/$san/wp-content
        " 2>/dev/null || true

        # Permisos híbridos desde host
        if [[ -d "$site_path" ]]; then
            chown -R 82:82 "$site_path"
            find "$site_path" -type d -exec chmod 755 {} \;
            find "$site_path" -type f -exec chmod 644 {} \;
            [[ -f "$site_path/wp-config.php" ]] && chmod 440 "$site_path/wp-config.php"

            # wp-content con escritura
            if [[ -d "$site_path/wp-content" ]]; then
                chmod 775 "$site_path/wp-content"
                for subdir in uploads plugins themes upgrade cache; do
                    [[ -d "$site_path/wp-content/$subdir" ]] && {
                        find "$site_path/wp-content/$subdir" -type d -exec chmod 775 {} \;
                        find "$site_path/wp-content/$subdir" -type f -exec chmod 664 {} \;
                    }
                done
            fi
        fi

        success "$domain"
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# REDIS + COOKIES (CORREGIDO)
# ══════════════════════════════════════════════════════════════════════════════

setup_redis() {
    $INSTALL_REDIS || return 0

    banner "══ PASO 13: Redis + Cookies ══"

    # Verificar/iniciar Redis
    if ! docker compose ps --status running 2>/dev/null | grep -q redis; then
        log "Iniciando contenedor Redis..."
        docker compose up -d redis >> "$LOG_FILE" 2>&1
        sleep 5
    fi

    # Verificar conexión
    docker compose exec -T redis redis-cli ping 2>/dev/null | grep -q PONG || error "Redis no responde"
    success "Redis activo"

    for domain in "${DOMAINS[@]}"; do
        local san="${DOMAIN_SANITIZED[$domain]}"
        local site_path="$INSTALL_DIR/www/$san"
        local wp_config="$site_path/wp-config.php"

        log "Configurando Redis para $domain..."

        [[ -f "$wp_config" ]] || { warning "wp-config.php no encontrado para $domain"; continue; }

        # ════════════════════════════════════════════════════════════════
        # 1. LIMPIAR CONFIGURACIÓN ANTERIOR
        # ════════════════════════════════════════════════════════════════
        sed -i '/WP_REDIS_/d; /WP_CACHE/d; /COOKIEHASH/d; /COOKIE_DOMAIN/d' "$wp_config"
        sed -i '/COOKIEPATH/d; /SITECOOKIEPATH/d; /ADMIN_COOKIE_PATH/d' "$wp_config"
        sed -i '/PLUGINS_COOKIE_PATH/d; /USER_COOKIE/d; /PASS_COOKIE/d' "$wp_config"
        sed -i '/AUTH_COOKIE/d; /SECURE_AUTH_COOKIE/d; /LOGGED_IN_COOKIE/d; /TEST_COOKIE/d' "$wp_config"
        sed -i '/Redis Object Cache/d; /Cookie Configuration/d' "$wp_config"
        sed -i '/^$/N;/^\n$/d' "$wp_config"

        # ════════════════════════════════════════════════════════════════
        # 2. GENERAR CONFIGURACIÓN COMPLETA
        # ════════════════════════════════════════════════════════════════
        local cookie_hash site_domain
        cookie_hash=$(echo -n "$san" | md5sum | cut -c1-8)
        site_domain="${san//_/.}"

        local config_block
        read -r -d '' config_block << CONFIGEOF || true

/* Redis Object Cache Configuration - $domain */
define('WP_REDIS_CLIENT', 'predis');
define('WP_REDIS_HOST', 'redis');
define('WP_REDIS_PORT', 6379);
define('WP_REDIS_PREFIX', '${san}_');
define('WP_REDIS_DATABASE', 0);
define('WP_REDIS_TIMEOUT', 1);
define('WP_REDIS_READ_TIMEOUT', 1);
define('WP_CACHE', true);

/* Cookie Configuration - $domain (hash: $cookie_hash) */
define('COOKIE_DOMAIN', '$site_domain');
define('COOKIEPATH', '/');
define('SITECOOKIEPATH', '/');
define('ADMIN_COOKIE_PATH', '/wp-admin');
define('PLUGINS_COOKIE_PATH', '/wp-content/plugins');
define('COOKIEHASH', '$cookie_hash');
define('USER_COOKIE', 'wpuser_$cookie_hash');
define('PASS_COOKIE', 'wppass_$cookie_hash');
define('AUTH_COOKIE', 'wpauth_$cookie_hash');
define('SECURE_AUTH_COOKIE', 'wpsecauth_$cookie_hash');
define('LOGGED_IN_COOKIE', 'wplogin_$cookie_hash');
define('TEST_COOKIE', 'wptest_$cookie_hash');

CONFIGEOF

        # ════════════════════════════════════════════════════════════════
        # 3. INSERTAR EN WP-CONFIG (método robusto)
        # ════════════════════════════════════════════════════════════════
        local insert_marker="" line_num=0

        # Buscar mejor punto de inserción
        for marker in "That's all, stop editing!" "if ( ! defined( 'ABSPATH' ) )" \
                      "if ( !defined('ABSPATH') )" "require_once ABSPATH"; do
            if grep -qF "$marker" "$wp_config"; then
                insert_marker="$marker"
                break
            fi
        done

        if [[ -n "$insert_marker" ]]; then
            line_num=$(grep -nF "$insert_marker" "$wp_config" | head -1 | cut -d: -f1)
            if [[ -n "$line_num" && "$line_num" -gt 0 ]]; then
                { head -n $((line_num - 1)) "$wp_config"; echo "$config_block"; tail -n +"$line_num" "$wp_config"; } > "${wp_config}.new"
                mv "${wp_config}.new" "$wp_config"
            else
                echo "$config_block" >> "$wp_config"
            fi
        else
            echo "$config_block" >> "$wp_config"
        fi

        # ════════════════════════════════════════════════════════════════
        # 4. INSTALAR PLUGIN (desde HOST, no desde contenedor)
        # ════════════════════════════════════════════════════════════════
        local plugin_dir="$site_path/wp-content/plugins"
        local plugin_path="$plugin_dir/redis-cache"

        mkdir -p "$plugin_dir"

        if [[ ! -d "$plugin_path" ]]; then
            local plugin_zip="/tmp/redis-cache-${san}.zip"
            if curl -fsSL "https://downloads.wordpress.org/plugin/redis-cache.latest-stable.zip" -o "$plugin_zip" 2>/dev/null; then
                unzip -q -o "$plugin_zip" -d "$plugin_dir" 2>/dev/null && rm -f "$plugin_zip"
                [[ -d "$plugin_path" ]] && success "  Plugin instalado" || warning "  Error extrayendo plugin"
            else
                warning "  No se pudo descargar plugin (instalar desde wp-admin)"
            fi
        fi

        # ════════════════════════════════════════════════════════════════
        # 5. COPIAR DROP-IN
        # ════════════════════════════════════════════════════════════════
        local dropin_src="$plugin_path/includes/object-cache.php"
        local dropin_dst="$site_path/wp-content/object-cache.php"

        [[ -f "$dropin_src" ]] && cp "$dropin_src" "$dropin_dst" && success "  Drop-in copiado"

        # ════════════════════════════════════════════════════════════════
        # 6. PERMISOS
        # ════════════════════════════════════════════════════════════════
        chown 82:82 "$wp_config" && chmod 440 "$wp_config"
        [[ -d "$plugin_path" ]] && { chown -R 82:82 "$plugin_path"; chmod -R 755 "$plugin_path"; find "$plugin_path" -type f -exec chmod 644 {} \;; }
        [[ -f "$dropin_dst" ]] && { chown 82:82 "$dropin_dst"; chmod 644 "$dropin_dst"; }

        success "✓ $domain (hash: $cookie_hash, prefix: ${san}_)"
    done

    echo ""
    info "Activar en wp-admin: Plugins > Redis Object Cache > Enable"
    info "Comandos: docker compose exec redis redis-cli INFO stats"
}

# ══════════════════════════════════════════════════════════════════════════════
# BACKUP CRON
# ══════════════════════════════════════════════════════════════════════════════

configure_backup() {
    $SETUP_CRON || return 0

    banner "══ PASO 14: Backup automático ══"

    [[ -f "$INSTALL_DIR/scripts/backup.sh" ]] || error "backup.sh no encontrado"
    chmod +x "$INSTALL_DIR/scripts/backup.sh"
    mkdir -p "$INSTALL_DIR/logs"

    # Configurar cron
    (crontab -l 2>/dev/null | grep -v "backup.sh"; cat << EOF
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 6 * * * cd $INSTALL_DIR && ./scripts/backup.sh >> $INSTALL_DIR/logs/backup.log 2>&1
EOF
    ) | crontab -

    systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true
    success "Backup diario configurado (2:00 AM)"
}

# ══════════════════════════════════════════════════════════════════════════════
# RESUMEN FINAL (compacto)
# ══════════════════════════════════════════════════════════════════════════════

show_summary() {
    banner "╔══════════════════════════════════════════════════════════════════════╗"
    banner "║                    ✓ INSTALACIÓN COMPLETADA ✓                        ║"
    banner "╚══════════════════════════════════════════════════════════════════════╝"

    echo -e "\n${GREEN}Credenciales:${NC}"
    echo "  MySQL Root: $MYSQL_ROOT_PASSWORD"

    for domain in "${DOMAINS[@]}"; do
        local san="${DOMAIN_SANITIZED[$domain]}"
        echo -e "\n  ${CYAN}$domain${NC} → $san"
        echo "    DB: wpuser_$san / ${DB_PASSWORDS[$domain]}"
        echo "    SFTP: sftp_$san / ${SFTP_PASSWORDS[$domain]}"
    done

    echo -e "\n${GREEN}Servicios:${NC}"
    echo "  phpMyAdmin: http://${DOMAINS[0]}/phpmyadmin/"
    echo "  SFTP: $SERVER_IP:2222"
    $INSTALL_NETDATA && echo "  Netdata: ssh -L 19999:localhost:19999 root@$SERVER_IP"
    $INSTALL_REDIS && echo "  Redis: docker compose exec redis redis-cli INFO"

    echo -e "\n${GREEN}Próximos pasos:${NC}"
    echo "  1. DNS → $SERVER_IP"
    echo "  2. SSL: cd $INSTALL_DIR && ./scripts/setup-ssl.sh"
    echo "  3. WordPress: http://DOMINIO/wp-admin/install.php"

    echo -e "\n${YELLOW}Credenciales guardadas en: $INSTALL_DIR/.credentials${NC}\n"
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

main() {
    mkdir -p "$(dirname "$LOG_FILE")"

    check_prerequisites
    gather_interactive_input
    install_packages
    install_docker
    configure_firewall
    install_netdata
    setup_structure
    check_mysql_volume
    generate_all_credentials
    copy_templates
    run_configuration
    run_wordpress_setup
    set_wordpress_permissions
    setup_redis
    configure_backup
    show_summary
}

main "$@"