#!/bin/bash

################################################################################
# WordPress Multi-Site - Instalador Automático Completo
# Versión refactorizada usando sistema de plantillas
# Para Ubuntu 24.04 LTS
# VERSIÓN ACTUALIZADA - SFTP + NETDATA + Nombres basados en dominio
# + IPv4/IPv6 selection + YAML configuration
################################################################################

set -euo pipefail

# Configuración
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_NAME="wordpress-multisite"
readonly INSTALL_DIR="/opt/$PROJECT_NAME"
readonly LOG_FILE="/var/log/${PROJECT_NAME}-install.log"
readonly CONFIG_FILE="$SCRIPT_DIR/config.yml"

# Colores
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Variables globales
declare -a DOMAINS=()
declare -a SFTP_PASSWORDS=()
declare -a DB_PASSWORDS=()
declare SERVER_IP=""
declare IP_VERSION=""
declare MYSQL_ROOT_PASSWORD=""
declare SETUP_CRON=false
declare INSTALL_NETDATA=false
declare INSTALL_REDIS=false
declare UNATTENDED_MODE=false

# Crear directorio de logs
mkdir -p "$(dirname "$LOG_FILE")"

# Funciones de logging
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; exit 1; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "$LOG_FILE"; }
info() { echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$LOG_FILE"; }
banner() { echo -e "${CYAN}$*${NC}" | tee -a "$LOG_FILE"; }

# Función para sanitizar nombre de dominio
sanitize_domain_name() {
    local domain="$1"
    # Convertir puntos en guiones bajos y eliminar caracteres especiales
    echo "$domain" | tr '.' '_' | tr '-' '_' | sed 's/[^a-zA-Z0-9_]//g'
}

# Función para instalar yq (versión Go de Mike Farah)
install_yq() {
    log "Instalando yq (versión Go de Mike Farah)..."

    # Eliminar versión antigua si existe (la de apt es incompatible)
    if command -v yq &>/dev/null; then
        local yq_version
        yq_version=$(yq --version 2>&1 || echo "")
        # Si no es la versión de Mike Farah, eliminarla
        if [[ ! "$yq_version" =~ "github.com/mikefarah/yq" ]]; then
            warning "Versión incompatible de yq detectada, reemplazando..."
            apt-get remove -y yq >> "$LOG_FILE" 2>&1 || true
            rm -f /usr/local/bin/yq 2>/dev/null || true
            rm -f /usr/bin/yq 2>/dev/null || true
        else
            success "✓ yq (versión correcta) ya instalado"
            return 0
        fi
    fi

    # Detectar arquitectura
    local arch
    arch=$(dpkg --print-architecture)
    local yq_arch=""

    case "$arch" in
        amd64) yq_arch="amd64" ;;
        arm64) yq_arch="arm64" ;;
        armhf) yq_arch="arm" ;;
        i386)  yq_arch="386" ;;
        *)     error "Arquitectura no soportada: $arch" ;;
    esac

    # Descargar última versión de yq
    local yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}"

    if wget -q "$yq_url" -O /usr/local/bin/yq >> "$LOG_FILE" 2>&1; then
        chmod +x /usr/local/bin/yq

        # Verificar instalación
        if /usr/local/bin/yq --version >> "$LOG_FILE" 2>&1; then
            success "✓ yq instalado correctamente"
            # Asegurar que está en el PATH
            if [[ ! -L /usr/bin/yq ]]; then
                ln -sf /usr/local/bin/yq /usr/bin/yq 2>/dev/null || true
            fi
            return 0
        else
            error "yq se descargó pero no funciona correctamente"
        fi
    else
        error "No se pudo descargar yq desde $yq_url"
    fi
}

# Verificar root
check_root() {
    [[ $EUID -eq 0 ]] || error "Este script debe ejecutarse como root (usa sudo)"
}

# Banner principal
show_main_banner() {
    clear
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════════════╗
║                                                                       ║
║            WordPress Multi-Site Instalador Automático                ║
║                     Para Ubuntu 24.04 LTS                             ║
║                                                                       ║
║                  Instalación Completamente Automatizada               ║
║                   Incluye: phpMyAdmin + SFTP Server                   ║
║                   + IPv4/IPv6 + YAML Configuration                    ║
║                                                                       ║
╚═══════════════════════════════════════════════════════════════════════╝
EOF
    echo ""
    log "Iniciando instalación automática completa..."
    log "Logs: $LOG_FILE"

    # Verificar si existe archivo de configuración
    if [[ -f "$CONFIG_FILE" ]]; then
        success "✓ Archivo de configuración encontrado: $CONFIG_FILE"
        UNATTENDED_MODE=true
        log "Modo: DESATENDIDO (configuración desde YAML)"

        # Instalar yq si no está disponible o es versión incorrecta (necesario para modo desatendido)
        install_yq
    else
        info "Archivo de configuración no encontrado: $CONFIG_FILE"
        log "Modo: INTERACTIVO"
    fi

    echo ""
    sleep 2
}

# Verificar requisitos del sistema
verify_system_requirements() {
    banner "═══════════════════════════════════════════════════════════════════════"
    banner "  PASO 1: Verificación de requisitos del sistema"
    banner "═══════════════════════════════════════════════════════════════════════"
    echo ""

    # Ubuntu 24.04
    info "Verificando Ubuntu..."
    if ! grep -q "24.04" /etc/os-release; then
        warning "Diseñado para Ubuntu 24.04 LTS"
        if [[ $UNATTENDED_MODE == false ]]; then
            read -rp "¿Continuar? (s/n): " continue
            [[ $continue =~ ^[Ss]$ ]] || error "Instalación cancelada"
        else
            warning "Continuando en modo desatendido..."
        fi
    else
        success "✓ Ubuntu 24.04 LTS"
    fi

    # RAM
    info "Verificando RAM..."
    local ram_mb
    ram_mb=$(free -m | awk 'NR==2{print $2}')
    if [[ $ram_mb -lt 4000 ]]; then
        warning "Se recomienda 8GB+ RAM. Sistema: ${ram_mb}MB"
    else
        success "✓ RAM: ${ram_mb}MB"
    fi

    # Disco
    info "Verificando espacio..."
    local disk_gb
    disk_gb=$(df / | awk 'NR==2{print int($4/1024/1024)}')
    if [[ $disk_gb -lt 20 ]]; then
        warning "Se recomienda 20GB+ libres. Disponible: ${disk_gb}GB"
    else
        success "✓ Espacio: ${disk_gb}GB"
    fi

    echo ""
    sleep 2
}

# Detectar direcciones IP (IPv4 e IPv6)
detect_ip_addresses() {
    local ipv4=""
    local ipv6=""

    # Detectar IPv4
    ipv4=$(curl -4 -s --max-time 10 ifconfig.me 2>/dev/null || \
           curl -4 -s --max-time 10 icanhazip.com 2>/dev/null || \
           ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || \
           echo "")

    # Detectar IPv6
    ipv6=$(curl -6 -s --max-time 10 ifconfig.me 2>/dev/null || \
           curl -6 -s --max-time 10 icanhazip.com 2>/dev/null || \
           ip -6 addr show scope global | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^fe80' | head -n1 || \
           echo "")

    echo "$ipv4|$ipv6"
}

# Cargar configuración desde YAML
load_config_from_yaml() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi

    log "Cargando configuración desde $CONFIG_FILE..."

    # Verificar que yq esté instalado (versión correcta)
    if ! command -v yq &>/dev/null; then
        error "yq no está instalado. Esto no debería ocurrir."
    fi

    # Verificar que sea la versión correcta
    local yq_version
    yq_version=$(yq --version 2>&1 || echo "")
    if [[ ! "$yq_version" =~ "github.com/mikefarah/yq" ]]; then
        error "Versión incorrecta de yq. Se requiere la versión Go de Mike Farah."
    fi

    # Cargar IP version
    local ip_version_config
    ip_version_config=$(yq eval '.server.ip_version' "$CONFIG_FILE" 2>/dev/null || echo "ipv4")
    IP_VERSION="${ip_version_config,,}"  # convertir a minúsculas

    # Cargar IP address (si está especificada)
    local ip_address_config
    ip_address_config=$(yq eval '.server.ip_address' "$CONFIG_FILE" 2>/dev/null || echo "")

    if [[ -n "$ip_address_config" && "$ip_address_config" != "null" ]]; then
        SERVER_IP="$ip_address_config"
        success "✓ IP desde config: $SERVER_IP"
    else
        # Detectar automáticamente según versión
        local detected_ips
        detected_ips=$(detect_ip_addresses)
        local ipv4="${detected_ips%%|*}"
        local ipv6="${detected_ips##*|}"

        case "$IP_VERSION" in
            ipv4)
                SERVER_IP="$ipv4"
                [[ -z "$SERVER_IP" ]] && error "No se pudo detectar IPv4"
                ;;
            ipv6)
                SERVER_IP="$ipv6"
                [[ -z "$SERVER_IP" ]] && error "No se pudo detectar IPv6"
                ;;
            both|dual)
                # Preferir IPv4 si está disponible
                SERVER_IP="${ipv4:-$ipv6}"
                [[ -z "$SERVER_IP" ]] && error "No se pudo detectar ninguna IP"
                ;;
            *)
                error "ip_version inválida en config: $IP_VERSION (usa: ipv4, ipv6, both)"
                ;;
        esac
        success "✓ IP detectada ($IP_VERSION): $SERVER_IP"
    fi

    # Cargar dominios
    local domain_count
    domain_count=$(yq eval '.domains | length' "$CONFIG_FILE" 2>/dev/null || echo "0")

    if [[ "$domain_count" -eq 0 ]]; then
        error "No hay dominios configurados en $CONFIG_FILE"
    fi

    for ((i=0; i<domain_count; i++)); do
        local domain
        domain=$(yq eval ".domains[$i]" "$CONFIG_FILE" 2>/dev/null)
        if [[ -n "$domain" && "$domain" != "null" ]]; then
            DOMAINS+=("$domain")
        fi
    done

    success "✓ Dominios cargados: ${#DOMAINS[@]}"

    # Cargar opciones
    local setup_cron_config
    setup_cron_config=$(yq eval '.options.setup_cron' "$CONFIG_FILE" 2>/dev/null || echo "false")
    [[ "$setup_cron_config" == "true" ]] && SETUP_CRON=true || SETUP_CRON=false

    local install_netdata_config
    install_netdata_config=$(yq eval '.options.install_netdata' "$CONFIG_FILE" 2>/dev/null || echo "false")
    [[ "$install_netdata_config" == "true" ]] && INSTALL_NETDATA=true || INSTALL_NETDATA=false

    local install_redis_config
    install_redis_config=$(yq eval '.options.install_redis' "$CONFIG_FILE" 2>/dev/null || echo "false")
    [[ "$install_redis_config" == "true" ]] && INSTALL_REDIS=true || INSTALL_REDIS=false

    success "✓ Configuración cargada desde YAML"
    return 0
}

# Recopilar información del usuario (modo interactivo)
gather_user_input() {
    banner "═══════════════════════════════════════════════════════════════════════"
    banner "  PASO 2: Recopilación de información"
    banner "═══════════════════════════════════════════════════════════════════════"
    echo ""

    # Si hay archivo YAML, cargar desde ahí
    if [[ $UNATTENDED_MODE == true ]]; then
        load_config_from_yaml || error "Error al cargar configuración desde YAML"
    else
        # Modo interactivo original con selección de IP
        info "Detectando direcciones IP..."
        local detected_ips
        detected_ips=$(detect_ip_addresses)
        local ipv4="${detected_ips%%|*}"
        local ipv6="${detected_ips##*|}"

        echo ""
        info "Direcciones IP detectadas:"
        [[ -n "$ipv4" ]] && echo "  1) IPv4: $ipv4" || echo "  1) IPv4: (no detectada)"
        [[ -n "$ipv6" ]] && echo "  2) IPv6: $ipv6" || echo "  2) IPv6: (no detectada)"
        echo "  3) Ingresar manualmente"
        echo ""

        local ip_choice
        while true; do
            read -rp "Selecciona opción [1-3]: " ip_choice
            case "$ip_choice" in
                1)
                    if [[ -n "$ipv4" ]]; then
                        SERVER_IP="$ipv4"
                        IP_VERSION="ipv4"
                        break
                    else
                        warning "IPv4 no disponible"
                    fi
                    ;;
                2)
                    if [[ -n "$ipv6" ]]; then
                        SERVER_IP="$ipv6"
                        IP_VERSION="ipv6"
                        break
                    else
                        warning "IPv6 no disponible"
                    fi
                    ;;
                3)
                    read -rp "Ingresa la IP del servidor: " SERVER_IP
                    read -rp "¿Es IPv4 o IPv6? (4/6): " version_choice
                    [[ "$version_choice" == "6" ]] && IP_VERSION="ipv6" || IP_VERSION="ipv4"
                    break
                    ;;
                *)
                    warning "Opción inválida"
                    ;;
            esac
        done

        success "IP seleccionada ($IP_VERSION): $SERVER_IP"

        # Dominios
        echo ""
        info "Ingresa los dominios (Enter vacío para terminar):"
        local counter=1
        while true; do
            read -rp "  Dominio $counter: " domain
            [[ -z "$domain" ]] && break

            if [[ $domain =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
                DOMAINS+=("$domain")
                ((counter++))
            else
                warning "    Formato inválido"
            fi
        done

        [[ ${#DOMAINS[@]} -gt 0 ]] || error "Debes ingresar al menos un dominio"

        # Backup automático
        echo ""
        read -rp "¿Configurar backup automático diario? (s/n): " setup_cron
        [[ $setup_cron =~ ^[Ss]$ ]] && SETUP_CRON=true || SETUP_CRON=false

        # Pregunta sobre Netdata
        echo ""
        read -rp "¿Instalar Netdata (monitoreo en tiempo real)? (s/n): " setup_netdata
        [[ $setup_netdata =~ ^[Ss]$ ]] && INSTALL_NETDATA=true || INSTALL_NETDATA=false

        # Pregunta sobre Redis
        echo ""
        read -rp "¿Instalar Redis (caché de objetos para WordPress)? (s/n): " setup_redis
        [[ $setup_redis =~ ^[Ss]$ ]] && INSTALL_REDIS=true || INSTALL_REDIS=false
    fi

    # Mostrar resumen (tanto para modo interactivo como desatendido)
    echo ""
    banner "═══════════════════════════════════════════════════════════════════════"
    banner "  RESUMEN DE CONFIGURACIÓN"
    banner "═══════════════════════════════════════════════════════════════════════"
    echo "  IP ($IP_VERSION): $SERVER_IP"
    echo "  Sitios: ${#DOMAINS[@]}"
    for domain in "${DOMAINS[@]}"; do
        local domain_sanitized=$(sanitize_domain_name "$domain")
        echo "    - $domain → ${domain_sanitized}"
    done
    echo ""
    success "  ✓ phpMyAdmin: INCLUIDO"
    success "  ✓ SFTP Server: INCLUIDO (puerto 2222)"
    [[ $INSTALL_NETDATA == true ]] && success "  ✓ Netdata: INCLUIDO (puerto 19999)"
    [[ $INSTALL_REDIS == true ]] && success "  ✓ Redis: INCLUIDO (caché de objetos)"
    echo "  Backup: $([[ $SETUP_CRON == true ]] && echo 'Sí' || echo 'No')"
    echo "  Directorio: $INSTALL_DIR"
    [[ $UNATTENDED_MODE == true ]] && echo "  Modo: DESATENDIDO"
    echo ""

    if [[ $UNATTENDED_MODE == false ]]; then
        read -rp "¿Continuar? (s/n): " confirm
        [[ $confirm =~ ^[Ss]$ ]] || error "Instalación cancelada"
    else
        info "Continuando en modo desatendido..."
    fi

    echo ""
    sleep 2
}

# Actualizar sistema
update_system() {
    banner "═══════════════════════════════════════════════════════════════════════"
    banner "  PASO 3: Actualización del sistema"
    banner "═══════════════════════════════════════════════════════════════════════"
    echo ""

    export DEBIAN_FRONTEND=noninteractive

    log "Actualizando repositorios..."
    apt-get update -qq >> "$LOG_FILE" 2>&1 || error "Error al actualizar"
    success "✓ Repositorios actualizados"

    log "Instalando actualizaciones..."
    apt-get upgrade -y -qq >> "$LOG_FILE" 2>&1 || warning "Algunas actualizaciones fallaron"
    success "✓ Sistema actualizado"

    log "Instalando dependencias..."
    apt-get install -y -qq \
        apt-transport-https ca-certificates curl gnupg lsb-release \
        software-properties-common git wget unzip pwgen jq ufw cron \
        apache2-utils openssh-client \
        >> "$LOG_FILE" 2>&1 || error "Error al instalar dependencias"
    success "✓ Dependencias instaladas"

    # Instalar yq si aún no está (para modo interactivo o por si acaso)
    if ! command -v yq &>/dev/null || [[ ! "$(yq --version 2>&1)" =~ "github.com/mikefarah/yq" ]]; then
        install_yq
    fi

    echo ""
    sleep 2
}

# Instalar Docker
install_docker() {
    banner "═══════════════════════════════════════════════════════════════════════"
    banner "  PASO 4: Instalación de Docker"
    banner "═══════════════════════════════════════════════════════════════════════"
    echo ""

    if command -v docker &>/dev/null; then
        warning "Docker ya instalado"
        docker --version | tee -a "$LOG_FILE"
    else
        log "Instalando Docker..."

        # Llave GPG
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        # Repositorio
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
            tee /etc/apt/sources.list.d/docker.list > /dev/null

        apt-get update -qq >> "$LOG_FILE" 2>&1

        # Instalar
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin >> "$LOG_FILE" 2>&1 || \
            error "Error al instalar Docker"

        success "✓ Docker instalado"
    fi

    # Verificar Docker Compose
    if ! docker compose version &>/dev/null; then
        error "Docker Compose no disponible"
    fi

    success "✓ Docker Compose disponible"
    echo ""
    sleep 2
}

# Configurar firewall
configure_firewall() {
    banner "═══════════════════════════════════════════════════════════════════════"
    banner "  PASO 5: Configuración del firewall"
    banner "═══════════════════════════════════════════════════════════════════════"
    echo ""

    log "Configurando UFW..."

    ufw --force reset >> "$LOG_FILE" 2>&1
    ufw default deny incoming >> "$LOG_FILE" 2>&1
    ufw default allow outgoing >> "$LOG_FILE" 2>&1

    # Puertos esenciales
    ufw allow 22/tcp comment 'SSH' >> "$LOG_FILE" 2>&1
    ufw allow 80/tcp comment 'HTTP' >> "$LOG_FILE" 2>&1
    ufw allow 443/tcp comment 'HTTPS' >> "$LOG_FILE" 2>&1
    ufw allow 2222/tcp comment 'SFTP' >> "$LOG_FILE" 2>&1

    ufw --force enable >> "$LOG_FILE" 2>&1

    success "✓ Firewall configurado"
    success "  - SSH: 22"
    success "  - HTTP: 80"
    success "  - HTTPS: 443"
    success "  - SFTP: 2222"

    echo ""
    sleep 2
}

# Instalar Netdata
install_netdata() {
    if [[ $INSTALL_NETDATA != true ]]; then
        return 0
    fi

    banner "═══════════════════════════════════════════════════════════════════════"
    banner "  INSTALACIÓN DE NETDATA"
    banner "═══════════════════════════════════════════════════════════════════════"
    echo ""

    log "Instalando Netdata..."

    # Descargar e instalar Netdata con opciones no interactivas
    if curl -fsSL https://get.netdata.cloud/kickstart.sh > /tmp/netdata-kickstart.sh; then
        chmod +x /tmp/netdata-kickstart.sh

        # Instalación no interactiva
        bash /tmp/netdata-kickstart.sh --non-interactive --stable-channel \
            --disable-telemetry >> "$LOG_FILE" 2>&1 || {
            warning "Error al instalar Netdata"
            return 1
        }

        rm -f /tmp/netdata-kickstart.sh

        # Configurar para SOLO escuchar en localhost (túnel SSH únicamente)
        if [[ -f /etc/netdata/netdata.conf ]]; then
            # Asegurar que solo escucha en localhost
            sed -i 's/^[[:space:]]*bind socket to IP =.*/    bind socket to IP = 127.0.0.1/' \
                /etc/netdata/netdata.conf 2>/dev/null || true

            # Verificar y forzar si no existe la línea
            if ! grep -q "bind socket to IP = 127.0.0.1" /etc/netdata/netdata.conf; then
                sed -i '/\[web\]/a\    bind socket to IP = 127.0.0.1' /etc/netdata/netdata.conf 2>/dev/null || true
            fi
        fi

        # Reiniciar servicio
        systemctl restart netdata || true

        # Verificar que está corriendo
        if systemctl is-active --quiet netdata; then
            success "✓ Netdata instalado y corriendo"
            success "  Configurado SOLO para acceso por túnel SSH (seguro)"
            info "  Acceso (ÚNICO método):"
            info "  ssh -L 19999:localhost:19999 root@$SERVER_IP"
            info "  Luego abrir en navegador: http://localhost:19999"
        else
            warning "Netdata instalado pero no está corriendo"
            info "  Iniciar manualmente: systemctl start netdata"
        fi
    else
        warning "No se pudo descargar el instalador de Netdata"
        return 1
    fi

    echo ""
    sleep 2
}

# Crear estructura de directorios
create_directories() {
    banner "═══════════════════════════════════════════════════════════════════════"
    banner "  PASO 6: Creación de estructura"
    banner "═══════════════════════════════════════════════════════════════════════"
    echo ""

    log "Creando directorios..."

    # Crear directorio principal
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    # Estructura completa
    mkdir -p {nginx/{conf.d,auth},php,mysql/{init,data},www,certbot/{conf,www},logs/{nginx,php,mysql},scripts,backups,templates}

    success "✓ Estructura creada en $INSTALL_DIR"
    echo ""
    sleep 2
}

# Verificar MySQL existente
check_existing_mysql() {
    banner "═══════════════════════════════════════════════════════════════════════"
    banner "  PASO 7: Verificación de MySQL"
    banner "═══════════════════════════════════════════════════════════════════════"
    echo ""

    log "Verificando volumen MySQL..."

    if docker volume inspect mysql-data &>/dev/null; then
        warning "Volumen MySQL existente detectado"

        if [[ $UNATTENDED_MODE == false ]]; then
            read -rp "¿Eliminar datos anteriores? (s/n): " remove_data
            if [[ $remove_data =~ ^[Ss]$ ]]; then
                docker volume rm mysql-data >> "$LOG_FILE" 2>&1 || true
                success "✓ Volumen eliminado"
            else
                info "Usando volumen existente"
            fi
        else
            warning "Modo desatendido: conservando volumen existente"
            info "Para eliminarlo, detén los contenedores y ejecuta: docker volume rm mysql-data"
        fi
    else
        success "✓ No hay volumen previo"
    fi

    echo ""
    sleep 2
}

# Generar credenciales
generate_credentials() {
    banner "═══════════════════════════════════════════════════════════════════════"
    banner "  PASO 8: Generación de credenciales"
    banner "═══════════════════════════════════════════════════════════════════════"
    echo ""

    log "Generando contraseñas..."
    MYSQL_ROOT_PASSWORD=$(pwgen -s 32 1)

    # Generar contraseña de DB y SFTP para cada sitio
    for i in "${!DOMAINS[@]}"; do
        DB_PASSWORDS+=("$(pwgen -s 32 1)")
        SFTP_PASSWORDS+=("$(pwgen -s 24 1)")
    done

    success "✓ Credenciales generadas"

    # Guardar credenciales
    local cred_file="$INSTALL_DIR/.credentials"
    cat > "$cred_file" << EOF
# CREDENCIALES DEL SISTEMA
# Generadas: $(date)
# GUARDAR EN LUGAR SEGURO

MySQL Root Password: $MYSQL_ROOT_PASSWORD

# Credenciales por sitio
EOF

    for i in "${!DOMAINS[@]}"; do
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        echo "" >> "$cred_file"
        echo "=== ${domain} ===" >> "$cred_file"
        echo "Carpeta: ${domain_sanitized}" >> "$cred_file"
        echo "Base de datos: ${domain_sanitized}" >> "$cred_file"
        echo "Usuario DB: wpuser_${domain_sanitized}" >> "$cred_file"
        echo "Password DB: ${DB_PASSWORDS[$i]}" >> "$cred_file"
        echo "Usuario SFTP: sftp_${domain_sanitized}" >> "$cred_file"
        echo "Password SFTP: ${SFTP_PASSWORDS[$i]}" >> "$cred_file"
    done

    chmod 600 "$cred_file"

    # Crear .env
    log "Creando .env..."
    cat > .env << EOF
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
EOF

    for i in "${!DOMAINS[@]}"; do
        echo "DOMAIN_$((i+1))=${DOMAINS[$i]}" >> .env
    done

    # Añadir contraseñas DB por sitio
    echo "" >> .env
    echo "# Database passwords por sitio" >> .env
    for i in "${!DOMAINS[@]}"; do
        echo "DB_PASSWORD_$((i+1))=${DB_PASSWORDS[$i]}" >> .env
    done

    # Añadir contraseñas SFTP por sitio
    echo "" >> .env
    echo "# SFTP - Usuarios independientes por sitio" >> .env
    for i in "${!DOMAINS[@]}"; do
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        echo "SFTP_${domain_sanitized^^}_PASSWORD=${SFTP_PASSWORDS[$i]}" >> .env
    done

    chown root:root .env
    chmod 600 .env

    # Exportar las variables para que estén disponibles en los scripts hijos
    export MYSQL_ROOT_PASSWORD
    export SERVER_IP
    export IP_VERSION

    # Exportar contraseñas DB
    for i in "${!DOMAINS[@]}"; do
        export "DB_PASSWORD_$((i+1))=${DB_PASSWORDS[$i]}"
    done

    # Exportar contraseñas SFTP
    for i in "${!DOMAINS[@]}"; do
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        export "SFTP_${domain_sanitized^^}_PASSWORD=${SFTP_PASSWORDS[$i]}"
    done

    success "✓ Archivo .env creado"
    echo ""
    sleep 2
}

# Copiar plantillas y scripts
copy_templates_and_scripts() {
    banner "═══════════════════════════════════════════════════════════════════════"
    banner "  PASO 9: Instalación de plantillas y scripts"
    banner "═══════════════════════════════════════════════════════════════════════"
    echo ""

    log "Copiando plantillas..."
    if [[ -d "$SCRIPT_DIR/templates" ]]; then
        cp -r "$SCRIPT_DIR/templates"/* templates/
        success "✓ Plantillas copiadas"
    else
        warning "Directorio templates/ no encontrado en $SCRIPT_DIR"
    fi

    log "Copiando scripts..."
    if [[ -d "$SCRIPT_DIR/scripts" ]]; then
        cp -r "$SCRIPT_DIR/scripts"/* scripts/
        chmod +x scripts/*.sh
        success "✓ Scripts copiados"
    else
        warning "Directorio scripts/ no encontrado en $SCRIPT_DIR"
    fi

    echo ""
    sleep 2
}

# Generar configuraciones
generate_configurations() {
    banner "═══════════════════════════════════════════════════════════════════════"
    banner "  PASO 10: Generación de configuraciones"
    banner "═══════════════════════════════════════════════════════════════════════"
    echo ""

    log "Generando archivos de configuración..."

    # Asegurar que las variables estén exportadas
    export MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}"
    export SERVER_IP="${SERVER_IP}"
    export IP_VERSION="${IP_VERSION}"

    # Exportar contraseñas DB
    for i in "${!DOMAINS[@]}"; do
        export "DB_PASSWORD_$((i+1))=${DB_PASSWORDS[$i]}"
    done

    # Exportar contraseñas SFTP
    for i in "${!DOMAINS[@]}"; do
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        export "SFTP_${domain_sanitized^^}_PASSWORD=${SFTP_PASSWORDS[$i]}"
    done

    ./scripts/generate-config.sh || error "Error al generar configuraciones"
    success "✓ Configuraciones generadas"

    echo ""
    sleep 2
}

# Setup WordPress
setup_wordpress() {
    banner "═══════════════════════════════════════════════════════════════════════"
    banner "  PASO 11: Instalación de WordPress"
    banner "═══════════════════════════════════════════════════════════════════════"
    echo ""

    log "Ejecutando setup de WordPress..."
    # Asegurar que las variables estén disponibles
    export MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}"
    export SERVER_IP="${SERVER_IP}"
    export IP_VERSION="${IP_VERSION}"

    # Exportar contraseñas DB
    for i in "${!DOMAINS[@]}"; do
        export "DB_PASSWORD_$((i+1))=${DB_PASSWORDS[$i]}"
    done

    # Exportar contraseñas SFTP
    for i in "${!DOMAINS[@]}"; do
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        export "SFTP_${domain_sanitized^^}_PASSWORD=${SFTP_PASSWORDS[$i]}"
    done

    ./scripts/setup.sh || error "Error en setup de WordPress"
    success "✓ WordPress instalado"

    echo ""
    sleep 2
}

# Configurar permisos de WordPress desde contenedores
set_wordpress_permissions() {
    banner "═══════════════════════════════════════════════════════════════════════"
    banner "  PASO 12: Configuración de permisos de WordPress"
    banner "═══════════════════════════════════════════════════════════════════════"
    echo ""

    log "Esperando que los contenedores estén listos..."
    sleep 5

    log "Configurando permisos desde contenedor PHP..."

    for i in "${!DOMAINS[@]}"; do
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")

        log "Configurando permisos para ${domain} (${domain_sanitized})..."

        # Ejecutar dentro del contenedor PHP
        docker compose exec -T php sh -c "
            # Verificar si el directorio existe
            if [ -d '/var/www/html/${domain_sanitized}' ]; then
                echo 'Configurando permisos para ${domain_sanitized}...'

                # Cambiar propietario a www-data (usuario de PHP-FPM)
                chown -R www-data:www-data /var/www/html/${domain_sanitized}

                # Permisos base
                find /var/www/html/${domain_sanitized} -type d -exec chmod 755 {} \;
                find /var/www/html/${domain_sanitized} -type f -exec chmod 644 {} \;

                # Crear directorios necesarios
                mkdir -p /var/www/html/${domain_sanitized}/wp-content/uploads
                mkdir -p /var/www/html/${domain_sanitized}/wp-content/plugins
                mkdir -p /var/www/html/${domain_sanitized}/wp-content/themes
                mkdir -p /var/www/html/${domain_sanitized}/wp-content/upgrade

                # Permisos COMPLETOS para wp-content (WordPress necesita crear subdirectorios)
                chmod -R 775 /var/www/html/${domain_sanitized}/wp-content
                chown -R www-data:www-data /var/www/html/${domain_sanitized}/wp-content

                # Asegurar que uploads tenga permisos recursivos
                if [ -d '/var/www/html/${domain_sanitized}/wp-content/uploads' ]; then
                    chmod -R 775 /var/www/html/${domain_sanitized}/wp-content/uploads
                    find /var/www/html/${domain_sanitized}/wp-content/uploads -type d -exec chmod 775 {} \;
                    find /var/www/html/${domain_sanitized}/wp-content/uploads -type f -exec chmod 664 {} \;
                fi

                echo 'Permisos configurados correctamente'
            else
                echo 'Advertencia: directorio ${domain_sanitized} no encontrado'
            fi
        " || warning "Error al configurar permisos para ${domain_sanitized}"

        # También configurar permisos desde el host para SFTP
        log "Ajustando permisos desde host para SFTP..."
        if [[ -d "$INSTALL_DIR/www/${domain_sanitized}/wp-content" ]]; then
            chmod -R 775 "$INSTALL_DIR/www/${domain_sanitized}/wp-content" 2>/dev/null || true
        fi
        success "✓ Permisos configurados para ${domain}"
    done

    success "✓ Permisos base de WordPress configurados"

    # ═══════════════════════════════════════════════════════════════════════
    # PERMISOS HÍBRIDOS: Seguros + SFTP Compatible
    # ═══════════════════════════════════════════════════════════════════════
    log "Aplicando permisos híbridos (seguros + SFTP compatible)..."

    # El contenedor wordpress:php-fpm-alpine usa UID:GID 82:82 (www-data en Alpine)
    # SFTP también debe usar 82:82 para compatibilidad

    for i in "${!DOMAINS[@]}"; do
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        local site_path="$INSTALL_DIR/www/${domain_sanitized}"

        if [[ -d "$site_path" ]]; then
            log "Aplicando permisos híbridos a ${domain}..."

            # 1. Propietario: 82:82 para todo (compatible SFTP y PHP-FPM Alpine)
            chown -R 82:82 "$site_path"

            # 2. CORE (solo lectura - máxima seguridad): 755 para dirs, 644 para archivos
            # Esto protege wp-admin, wp-includes y archivos PHP raíz
            find "$site_path" -type d -exec chmod 755 {} \;
            find "$site_path" -type f -exec chmod 644 {} \;

            # 3. wp-config.php: permisos más restrictivos (440)
            if [[ -f "$site_path/wp-config.php" ]]; then
                chmod 440 "$site_path/wp-config.php"
            fi

            # 4. WP-CONTENT (escritura habilitada - SFTP compatible): 775/664
            if [[ -d "$site_path/wp-content" ]]; then
                # Directorio principal wp-content
                chmod 775 "$site_path/wp-content"

                # Subdirectorios que necesitan escritura
                for subdir in uploads plugins themes upgrade cache languages; do
                    if [[ -d "$site_path/wp-content/$subdir" ]]; then
                        find "$site_path/wp-content/$subdir" -type d -exec chmod 775 {} \;
                        find "$site_path/wp-content/$subdir" -type f -exec chmod 664 {} \;
                    fi
                done

                # Crear directorios si no existen
                for subdir in uploads plugins themes upgrade; do
                    mkdir -p "$site_path/wp-content/$subdir"
                    chown 82:82 "$site_path/wp-content/$subdir"
                    chmod 775 "$site_path/wp-content/$subdir"
                done
            fi

            success "✓ Permisos híbridos aplicados a ${domain}"
        fi
    done

    echo ""
    success "✓ PERMISOS HÍBRIDOS CONFIGURADOS"
    echo ""
    info "  PROTEGIDO (solo lectura):"
    info "    • wp-admin/, wp-includes/: 755/644"
    info "    • Archivos PHP raíz: 644"
    info "    • wp-config.php: 440"
    echo ""
    info "  ESCRITURA HABILITADA (SFTP + WordPress):"
    info "    • wp-content/uploads/: 775/664"
    info "    • wp-content/plugins/: 775/664"
    info "    • wp-content/themes/: 775/664"
    info "    • wp-content/upgrade/: 775/664"
    echo ""
    info "  Propietario: 82:82 (www-data Alpine, compatible SFTP y PHP-FPM)"

    echo ""
    sleep 2
}

# Configurar Redis
setup_redis() {
    if [[ $INSTALL_REDIS != true ]]; then
        return 0
    fi

    banner "═══════════════════════════════════════════════════════════════════════"
    banner "  PASO 13: Instalación de Redis"
    banner "═══════════════════════════════════════════════════════════════════════"
    echo ""

    log "Verificando que Redis esté corriendo..."

    # Verificar que el contenedor Redis esté activo
    if ! docker compose ps --status running 2>/dev/null | grep -q "redis"; then
        warning "Contenedor Redis no está corriendo, iniciándolo..."
        docker compose up -d redis >> "$LOG_FILE" 2>&1 || {
            error "No se pudo iniciar Redis"
        }
        sleep 5
    fi

    # Verificar conexión a Redis
    if docker compose exec -T redis redis-cli ping 2>/dev/null | grep -q "PONG"; then
        success "✓ Redis está corriendo y responde"
    else
        error "Redis no responde"
    fi

    log "Configurando Redis para cada sitio WordPress..."

    for i in "${!DOMAINS[@]}"; do
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        local site_path="$INSTALL_DIR/www/${domain_sanitized}"
        local wp_config_path="$site_path/wp-config.php"
        local redis_prefix="${domain_sanitized}_"

        log "Configurando Redis para ${domain}..."

        # Verificar que existe wp-config.php
        if [[ ! -f "$wp_config_path" ]]; then
            warning "wp-config.php no encontrado para ${domain}, saltando..."
            continue
        fi

        # Verificar si ya está configurado
        if grep -q "WP_REDIS_HOST" "$wp_config_path" 2>/dev/null; then
            info "Redis ya configurado en ${domain}"
            continue
        fi

        # Insertar configuración de Redis usando método robusto
        # Crear archivo temporal con la configuración
        local temp_config=$(mktemp)
        cat > "$temp_config" << REDIS_EOF

/* Redis Object Cache Configuration */
define('WP_REDIS_CLIENT', 'predis');
define('WP_REDIS_HOST', 'redis');
define('WP_REDIS_PORT', 6379);
define('WP_REDIS_PREFIX', '${redis_prefix}');
define('WP_REDIS_DATABASE', 0);
define('WP_REDIS_TIMEOUT', 1);
define('WP_REDIS_READ_TIMEOUT', 1);
define('WP_CACHE', true);

REDIS_EOF

        # Insertar antes de "That's all, stop editing!" o "require_once ABSPATH"
        if grep -q "That's all, stop editing!" "$wp_config_path"; then
            # Obtener número de línea
            local line_num=$(grep -n "That's all, stop editing!" "$wp_config_path" | head -1 | cut -d: -f1)
            # Insertar configuración antes de esa línea
            head -n $((line_num - 1)) "$wp_config_path" > "${wp_config_path}.new"
            cat "$temp_config" >> "${wp_config_path}.new"
            tail -n +${line_num} "$wp_config_path" >> "${wp_config_path}.new"
            mv "${wp_config_path}.new" "$wp_config_path"
        elif grep -q "require_once ABSPATH" "$wp_config_path"; then
            local line_num=$(grep -n "require_once ABSPATH" "$wp_config_path" | head -1 | cut -d: -f1)
            head -n $((line_num - 1)) "$wp_config_path" > "${wp_config_path}.new"
            cat "$temp_config" >> "${wp_config_path}.new"
            tail -n +${line_num} "$wp_config_path" >> "${wp_config_path}.new"
            mv "${wp_config_path}.new" "$wp_config_path"
        else
            # Si no encuentra ninguno, agregar antes del cierre de PHP o al final
            cat "$temp_config" >> "$wp_config_path"
        fi

        rm -f "$temp_config"

        # Corregir permisos del archivo
        chown 82:82 "$wp_config_path"
        chmod 440 "$wp_config_path"

        # Descargar e instalar plugin Redis Object Cache
        docker compose exec -T php sh -c "
            cd /var/www/html/${domain_sanitized}

            # Crear directorio de plugins si no existe
            mkdir -p wp-content/plugins

            # Descargar plugin si no existe
            if [ ! -d 'wp-content/plugins/redis-cache' ]; then
                cd wp-content/plugins
                wget -q https://downloads.wordpress.org/plugin/redis-cache.latest-stable.zip -O redis-cache.zip 2>/dev/null
                if [ -f redis-cache.zip ]; then
                    unzip -q redis-cache.zip 2>/dev/null
                    rm -f redis-cache.zip
                fi
            fi

            # Copiar object-cache.php drop-in
            if [ -f 'wp-content/plugins/redis-cache/includes/object-cache.php' ]; then
                cp wp-content/plugins/redis-cache/includes/object-cache.php ../object-cache.php 2>/dev/null
            fi
        " >> "$LOG_FILE" 2>&1 || warning "No se pudo instalar plugin automáticamente para ${domain}"

        # Corregir permisos
        chown -R 82:82 "$site_path/wp-content/plugins/" 2>/dev/null || true
        chown 82:82 "$site_path/wp-content/object-cache.php" 2>/dev/null || true

        success "✓ Redis configurado para ${domain}"
    done

    echo ""
    success "✓ Redis instalado y configurado"
    info "  - Host: redis"
    info "  - Puerto: 6379"
    info "  - Cada sitio tiene su propio prefijo de caché"
    info "  - Plugin: Redis Object Cache (activar desde wp-admin)"

    echo ""
    sleep 2
}

# Configurar backup automático
configure_backup() {
    if [[ $SETUP_CRON != true ]]; then
        return 0
    fi

    banner "═══════════════════════════════════════════════════════════════════════"
    banner "  PASO 13: Configuración de backup automático"
    banner "═══════════════════════════════════════════════════════════════════════"
    echo ""

    # Verificar que el script de backup existe
    if [[ ! -f "$INSTALL_DIR/scripts/backup.sh" ]]; then
        error "Script de backup no encontrado en $INSTALL_DIR/scripts/backup.sh"
    fi

    # Asegurar permisos de ejecución
    chmod +x "$INSTALL_DIR/scripts/backup.sh"

    # Crear directorio de logs
    mkdir -p "$INSTALL_DIR/logs"
    chmod 755 "$INSTALL_DIR/logs"

    log "Configurando cron con variables de entorno..."

    # Crear archivo temporal con el cron completo
    local temp_cron=$(mktemp)

    # Obtener crontab actual y eliminar entradas antiguas de backup
    crontab -l -u root 2>/dev/null | grep -v "backup.sh" | grep -v "^PATH=" | grep -v "^SHELL=" > "$temp_cron" || true

    # Agregar variables de entorno y tarea cron mejorada
    cat >> "$temp_cron" << 'CRON_EOF'
# Variables de entorno para tareas cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SHELL=/bin/bash

# Backup automático diario de WordPress Multi-Site (2:00 AM)
CRON_EOF

    # Agregar la entrada de cron con creación del directorio de logs
    echo "0 2 * * * mkdir -p $INSTALL_DIR/logs && cd $INSTALL_DIR && ./scripts/backup.sh >> $INSTALL_DIR/logs/backup.log 2>&1" >> "$temp_cron"

    # Instalar el nuevo crontab
    crontab -u root "$temp_cron"
    rm -f "$temp_cron"

    # Reiniciar el servicio cron
    systemctl restart cron || systemctl restart crond

    # Verificar configuración
    if crontab -l 2>/dev/null | grep -q "backup.sh"; then
        success "✓ Backup automático configurado (2:00 AM diario)"
        success "✓ Variables de entorno PATH y SHELL configuradas"
        success "✓ Script backup.sh verificado con permisos de ejecución"
        success "✓ Directorio de logs creado en $INSTALL_DIR/logs"

        info "Configuración del cron:"
        echo ""
        crontab -l 2>/dev/null | grep -E "(PATH=|SHELL=|backup.sh)" | sed 's/^/  /'
        echo ""

        info "Prueba manual del backup:"
        echo "  cd $INSTALL_DIR && sudo ./scripts/backup.sh"
    else
        error "El cron no se configuró correctamente"
    fi

    echo ""
    sleep 2
}

# Resumen final
show_final_summary() {
    banner "╔═══════════════════════════════════════════════════════════════════════╗"
    banner "║                   ✓ INSTALACIÓN COMPLETADA ✓                         ║"
    banner "╚═══════════════════════════════════════════════════════════════════════╝"
    echo ""

    success "Instalado en: $INSTALL_DIR"
    echo ""

    info "═══ CREDENCIALES ═══"
    echo "  MySQL Root: root / $MYSQL_ROOT_PASSWORD"
    echo ""
    echo "  Credenciales por sitio:"
    for i in "${!DOMAINS[@]}"; do
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        echo ""
        echo "    ${domain}:"
        echo "      Carpeta: ${domain_sanitized}"
        echo "      DB: ${domain_sanitized}"
        echo "      Usuario DB: wpuser_${domain_sanitized} / ${DB_PASSWORDS[$i]}"
        echo "      Usuario SFTP: sftp_${domain_sanitized} / ${SFTP_PASSWORDS[$i]}"
    done
    echo ""
    warning "  También en: $INSTALL_DIR/.credentials"
    echo ""

    info "═══ SITIOS CONFIGURADOS ═══"
    for i in "${!DOMAINS[@]}"; do
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        echo "  $((i+1)). ${domain}"
        echo "     URL: http://${domain}"
        echo "     Carpeta: ${domain_sanitized}"
        echo ""
    done

    info "═══ SERVICIOS ═══"
    echo "  phpMyAdmin: http://${DOMAINS[0]}/phpmyadmin/"
    echo "  SFTP: $SERVER_IP:2222"

    if [[ $INSTALL_NETDATA == true ]]; then
        echo ""
        info "  Netdata (solo accesible por túnel SSH):"
        echo "    Comando: ssh -L 19999:localhost:19999 root@$SERVER_IP"
        echo "    Luego en navegador: http://localhost:19999"
    fi

    if [[ $INSTALL_REDIS == true ]]; then
        echo ""
        info "  Redis (caché de objetos):"
        echo "    Host interno: redis:6379"
        echo "    Plugin: Redis Object Cache (activar en cada wp-admin)"
        echo "    Ver estado: docker compose exec redis redis-cli INFO"
        echo "    Limpiar caché: docker compose exec redis redis-cli FLUSHALL"
    fi

    echo ""
    echo "  Accesos SFTP por sitio:"
    for i in "${!DOMAINS[@]}"; do
        local domain="${DOMAINS[$i]}"
        local domain_sanitized=$(sanitize_domain_name "$domain")
        echo "    ${domain}: sftp -P 2222 sftp_${domain_sanitized}@$SERVER_IP"
        echo "    Directorio: /${domain_sanitized}"
    done
    echo ""

    info "═══ PRÓXIMOS PASOS ═══"
    echo "  1. Apuntar DNS a: $SERVER_IP ($IP_VERSION)"
    echo "  2. Ejecutar: cd $INSTALL_DIR && sudo ./scripts/setup-ssl.sh"
    echo "  3. Instalar WordPress en cada dominio:"
    for domain in "${DOMAINS[@]}"; do
        echo "     - http://$domain/wp-admin/install.php"
    done
    echo ""

    info "═══ COMANDOS ═══"
    echo "  Ver estado: cd $INSTALL_DIR && docker compose ps"
    echo "  Ver logs: docker compose logs -f"
    echo "  Backup: ./scripts/backup.sh"
    if [[ $INSTALL_NETDATA == true ]]; then
        echo "  Netdata: systemctl status netdata"
    fi
    if [[ $INSTALL_REDIS == true ]]; then
        echo "  Redis status: docker compose exec redis redis-cli INFO"
        echo "  Redis config: ./scripts/setup-redis.sh"
    fi
    echo ""

    success "¡Sistema WordPress multi-sitio listo!"
    echo ""
}

# Main
main() {
    check_root
    show_main_banner
    verify_system_requirements
    gather_user_input
    update_system
    install_docker
    configure_firewall
    install_netdata
    create_directories
    check_existing_mysql
    generate_credentials
    copy_templates_and_scripts
    generate_configurations
    setup_wordpress
    set_wordpress_permissions
    setup_redis
    configure_backup
    show_final_summary
}

main "$@"