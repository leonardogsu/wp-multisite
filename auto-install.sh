#!/bin/bash

################################################################################
# WordPress Multi-Site - Instalador Automático Completo
# Versión refactorizada usando sistema de plantillas
# Para Ubuntu 24.04 LTS
# VERSIÓN ACTUALIZADA - SFTP + NETDATA + Nombres basados en dominio
################################################################################

set -euo pipefail

# Configuración
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_NAME="wordpress-multisite"
readonly INSTALL_DIR="/opt/$PROJECT_NAME"
readonly LOG_FILE="/var/log/${PROJECT_NAME}-install.log"

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
declare MYSQL_ROOT_PASSWORD=""
declare SETUP_CRON=false
declare INSTALL_NETDATA=false

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
║                                                                       ║
╚═══════════════════════════════════════════════════════════════════════╝
EOF
    echo ""
    log "Iniciando instalación automática completa..."
    log "Logs: $LOG_FILE"
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
        read -rp "¿Continuar? (s/n): " continue
        [[ $continue =~ ^[Ss]$ ]] || error "Instalación cancelada"
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

# Recopilar información del usuario
gather_user_input() {
    banner "═══════════════════════════════════════════════════════════════════════"
    banner "  PASO 2: Recopilación de información"
    banner "═══════════════════════════════════════════════════════════════════════"
    echo ""

    # Detectar IP
    info "Detectando IP pública..."
    SERVER_IP=$(curl -s --max-time 10 ifconfig.me || curl -s --max-time 10 icanhazip.com || echo "")

    if [[ -z "$SERVER_IP" ]]; then
        read -rp "Ingresa la IP del servidor: " SERVER_IP
    else
        echo "  IP detectada: $SERVER_IP"
        read -rp "  ¿Es correcta? (s/n): " confirm
        if [[ ! $confirm =~ ^[Ss]$ ]]; then
            read -rp "  Ingresa la IP correcta: " SERVER_IP
        fi
    fi

    # Dominios
    echo ""
    info "Ingresa los dominios (Enter vacío para terminar):"
    local counter=1
    while true; do
        read -rp "  Dominio $counter: " domain
        [[ -z "$domain" ]] && break

        if [[ $domain =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
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

    # Mostrar resumen
    echo ""
    banner "═══════════════════════════════════════════════════════════════════════"
    banner "  RESUMEN DE CONFIGURACIÓN"
    banner "═══════════════════════════════════════════════════════════════════════"
    echo "  IP: $SERVER_IP"
    echo "  Sitios: ${#DOMAINS[@]}"
    for domain in "${DOMAINS[@]}"; do
        local domain_sanitized=$(sanitize_domain_name "$domain")
        echo "    - $domain → ${domain_sanitized}"
    done
    echo ""
    success "  ✓ phpMyAdmin: INCLUIDO"
    success "  ✓ SFTP Server: INCLUIDO (puerto 2222)"
    [[ $INSTALL_NETDATA == true ]] && success "  ✓ Netdata: INCLUIDO (puerto 19999)"
    echo "  Backup: $([[ $SETUP_CRON == true ]] && echo 'Sí' || echo 'No')"
    echo "  Directorio: $INSTALL_DIR"
    echo ""

    read -rp "¿Continuar? (s/n): " confirm
    [[ $confirm =~ ^[Ss]$ ]] || error "Instalación cancelada"

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
        read -rp "¿Eliminar datos anteriores? (s/n): " remove_data

        if [[ $remove_data =~ ^[Ss]$ ]]; then
            docker volume rm mysql-data >> "$LOG_FILE" 2>&1 || true
            success "✓ Volumen eliminado"
        else
            info "Usando volumen existente"
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

    success "✓ Permisos de WordPress configurados"
    info "  - Todo wp-content: 775 (escritura completa habilitada)"
    info "  - Subdirectorios se crearán automáticamente con permisos correctos"
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
    echo "  1. Apuntar DNS a: $SERVER_IP"
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
    configure_backup
    show_final_summary
}

main "$@"