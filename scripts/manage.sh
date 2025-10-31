#!/bin/bash

################################################################################
# WordPress Multi-Site - Gestor del Sistema
# Menú interactivo para gestionar todos los aspectos del sistema
################################################################################

set -e

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Verificar que estamos en el directorio correcto
if [ ! -f .env ]; then
    echo -e "${RED}Error: Este script debe ejecutarse desde el directorio del proyecto${NC}"
    exit 1
fi

source .env

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

pause() {
    echo ""
    read -p "Presiona Enter para continuar..."
}

# Función para mostrar el banner
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║        WordPress Multi-Site - Gestor del Sistema             ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# Función para mostrar el estado del sistema
show_status() {
    show_banner
    echo -e "${BLUE}═══ ESTADO DEL SISTEMA ═══${NC}"
    echo ""
    
    # Estado de contenedores
    log "Contenedores Docker:"
    docker compose ps
    echo ""
    
    # Uso de recursos
    log "Uso de recursos:"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"
    echo ""
    
    # Espacio en disco
    log "Espacio en disco:"
    df -h / | grep -v Filesystem
    echo ""
    
    # Dominios configurados
    DOMAINS=($(grep "^DOMAIN_" .env | cut -d'=' -f2))
    log "Sitios configurados: ${#DOMAINS[@]}"
    for i in "${!DOMAINS[@]}"; do
        echo "  $((i+1)). ${DOMAINS[$i]}"
    done
    echo ""
    
    pause
}

# Función para gestionar contenedores
manage_containers() {
    while true; do
        show_banner
        echo -e "${BLUE}═══ GESTIÓN DE CONTENEDORES ═══${NC}"
        echo ""
        echo "  1. Ver estado de contenedores"
        echo "  2. Iniciar todos los contenedores"
        echo "  3. Detener todos los contenedores"
        echo "  4. Reiniciar todos los contenedores"
        echo "  5. Ver logs de todos los contenedores"
        echo "  6. Ver logs de un contenedor específico"
        echo "  7. Reiniciar un contenedor específico"
        echo "  0. Volver al menú principal"
        echo ""
        read -p "Selecciona una opción: " option
        
        case $option in
            1)
                docker compose ps
                pause
                ;;
            2)
                log "Iniciando contenedores..."
                docker compose start
                success "Contenedores iniciados"
                pause
                ;;
            3)
                log "Deteniendo contenedores..."
                docker compose stop
                success "Contenedores detenidos"
                pause
                ;;
            4)
                log "Reiniciando contenedores..."
                docker compose restart
                success "Contenedores reiniciados"
                pause
                ;;
            5)
                docker compose logs --tail=50
                pause
                ;;
            6)
                echo ""
                echo "Contenedores disponibles:"
                docker compose ps --format "{{.Service}}" | nl
                echo ""
                read -p "Nombre del contenedor: " container
                docker compose logs "$container" --tail=50
                pause
                ;;
            7)
                echo ""
                echo "Contenedores disponibles:"
                docker compose ps --format "{{.Service}}" | nl
                echo ""
                read -p "Nombre del contenedor: " container
                log "Reiniciando $container..."
                docker compose restart "$container"
                success "Contenedor reiniciado"
                pause
                ;;
            0)
                break
                ;;
            *)
                error "Opción inválida"
                pause
                ;;
        esac
    done
}

# Función para gestionar bases de datos
manage_databases() {
    while true; do
        show_banner
        echo -e "${BLUE}═══ GESTIÓN DE BASES DE DATOS ═══${NC}"
        echo ""
        echo "  1. Listar bases de datos"
        echo "  2. Crear backup de todas las bases de datos"
        echo "  3. Crear backup de una base de datos específica"
        echo "  4. Restaurar una base de datos"
        echo "  5. Acceder a MySQL CLI"
        echo "  6. Optimizar todas las bases de datos"
        echo "  0. Volver al menú principal"
        echo ""
        read -p "Selecciona una opción: " option
        
        case $option in
            1)
                docker compose exec mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES;"
                pause
                ;;
            2)
                log "Creando backup de todas las bases de datos..."
                ./scripts/backup.sh
                success "Backup completado"
                pause
                ;;
            3)
                echo ""
                docker compose exec mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES;"
                echo ""
                read -p "Nombre de la base de datos: " dbname
                DATE=$(date +%Y%m%d_%H%M%S)
                mkdir -p backups/manual
                docker compose exec -T mysql mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" "$dbname" > "backups/manual/${dbname}_${DATE}.sql"
                gzip "backups/manual/${dbname}_${DATE}.sql"
                success "Backup guardado en: backups/manual/${dbname}_${DATE}.sql.gz"
                pause
                ;;
            4)
                echo ""
                ls -1 backups/
                echo ""
                read -p "Directorio del backup: " backup_dir
                ls -1 "backups/$backup_dir/"*.sql.gz
                echo ""
                read -p "Archivo de backup: " backup_file
                read -p "Nombre de la base de datos destino: " dbname
                gunzip -c "backups/$backup_dir/$backup_file" | docker compose exec -T mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$dbname"
                success "Base de datos restaurada"
                pause
                ;;
            5)
                echo ""
                warning "Estás entrando a MySQL CLI. Escribe 'exit' para salir."
                pause
                docker compose exec mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD"
                ;;
            6)
                log "Optimizando bases de datos..."
                DOMAINS=($(grep "^DOMAIN_" .env | cut -d'=' -f2))
                for i in "${!DOMAINS[@]}"; do
                    SITE_NUM=$((i + 1))
                    DB_NAME="wp_sitio$SITE_NUM"
                    echo "  Optimizando $DB_NAME..."
                    docker compose exec mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "OPTIMIZE TABLE $DB_NAME.*;"
                done
                success "Bases de datos optimizadas"
                pause
                ;;
            0)
                break
                ;;
            *)
                error "Opción inválida"
                pause
                ;;
        esac
    done
}

# Función para gestionar SSL
manage_ssl() {
    while true; do
        show_banner
        echo -e "${BLUE}═══ GESTIÓN DE CERTIFICADOS SSL ═══${NC}"
        echo ""
        echo "  1. Ver certificados instalados"
        echo "  2. Obtener/renovar certificados"
        echo "  3. Renovar certificados manualmente"
        echo "  4. Ver fecha de expiración"
        echo "  0. Volver al menú principal"
        echo ""
        read -p "Selecciona una opción: " option
        
        case $option in
            1)
                docker compose run --rm certbot certificates
                pause
                ;;
            2)
                ./scripts/setup-ssl.sh
                pause
                ;;
            3)
                log "Renovando certificados..."
                docker compose run --rm certbot renew
                docker compose exec nginx nginx -s reload
                success "Certificados renovados"
                pause
                ;;
            4)
                DOMAINS=($(grep "^DOMAIN_" .env | cut -d'=' -f2))
                for DOMAIN in "${DOMAINS[@]}"; do
                    if [ -d "certbot/conf/live/$DOMAIN" ]; then
                        echo "$DOMAIN:"
                        openssl x509 -enddate -noout -in "certbot/conf/live/$DOMAIN/cert.pem"
                    fi
                done
                pause
                ;;
            0)
                break
                ;;
            *)
                error "Opción inválida"
                pause
                ;;
        esac
    done
}

# Función para gestionar sitios WordPress
manage_sites() {
    while true; do
        show_banner
        echo -e "${BLUE}═══ GESTIÓN DE SITIOS WORDPRESS ═══${NC}"
        echo ""
        
        DOMAINS=($(grep "^DOMAIN_" .env | cut -d'=' -f2))
        echo "Sitios configurados:"
        for i in "${!DOMAINS[@]}"; do
            echo "  $((i+1)). ${DOMAINS[$i]}"
        done
        echo ""
        
        echo "  a. Añadir nuevo sitio"
        echo "  d. Ver detalles de un sitio"
        echo "  p. Ajustar permisos de un sitio"
        echo "  c. Limpiar caché de un sitio"
        echo "  0. Volver al menú principal"
        echo ""
        read -p "Selecciona una opción: " option
        
        case $option in
            a)
                warning "Esta función requiere configuración manual adicional"
                echo "Pasos necesarios:"
                echo "1. Editar .env y añadir nuevo dominio"
                echo "2. Ejecutar ./scripts/generate-config.sh"
                echo "3. Crear directorio www/sitioX"
                echo "4. Instalar WordPress en el nuevo sitio"
                echo "5. Configurar DNS"
                echo "6. Obtener certificado SSL"
                pause
                ;;
            d)
                read -p "Número del sitio (1-${#DOMAINS[@]}): " site_num
                if [ $site_num -ge 1 ] && [ $site_num -le ${#DOMAINS[@]} ]; then
                    DOMAIN="${DOMAINS[$((site_num-1))]}"
                    echo ""
                    echo "Dominio: $DOMAIN"
                    echo "Directorio: www/sitio$site_num"
                    echo "Base de datos: wp_sitio$site_num"
                    echo "URL: https://$DOMAIN"
                    echo ""
                    if [ -d "www/sitio$site_num" ]; then
                        echo "WordPress instalado: Sí"
                        du -sh "www/sitio$site_num"
                    else
                        echo "WordPress instalado: No"
                    fi
                else
                    error "Número de sitio inválido"
                fi
                pause
                ;;
            p)
                read -p "Número del sitio (1-${#DOMAINS[@]}): " site_num
                if [ $site_num -ge 1 ] && [ $site_num -le ${#DOMAINS[@]} ]; then
                    log "Ajustando permisos para sitio$site_num..."
                    chown -R www-data:www-data "www/sitio$site_num/"
                    find "www/sitio$site_num/" -type d -exec chmod 755 {} \;
                    find "www/sitio$site_num/" -type f -exec chmod 644 {} \;
                    success "Permisos ajustados"
                else
                    error "Número de sitio inválido"
                fi
                pause
                ;;
            c)
                read -p "Número del sitio (1-${#DOMAINS[@]}): " site_num
                if [ $site_num -ge 1 ] && [ $site_num -le ${#DOMAINS[@]} ]; then
                    log "Limpiando caché para sitio$site_num..."
                    rm -rf "www/sitio$site_num/wp-content/cache/*" 2>/dev/null || true
                    docker compose exec php php -r "if(function_exists('opcache_reset')) opcache_reset();"
                    success "Caché limpiado"
                else
                    error "Número de sitio inválido"
                fi
                pause
                ;;
            0)
                break
                ;;
            *)
                error "Opción inválida"
                pause
                ;;
        esac
    done
}

# Función para gestionar backups
manage_backups() {
    while true; do
        show_banner
        echo -e "${BLUE}═══ GESTIÓN DE BACKUPS ═══${NC}"
        echo ""
        echo "  1. Crear backup completo ahora"
        echo "  2. Listar backups existentes"
        echo "  3. Ver detalles de un backup"
        echo "  4. Eliminar backups antiguos"
        echo "  5. Restaurar backup"
        echo "  6. Ver configuración de backup automático"
        echo "  0. Volver al menú principal"
        echo ""
        read -p "Selecciona una opción: " option
        
        case $option in
            1)
                ./scripts/backup.sh
                pause
                ;;
            2)
                echo ""
                ls -lht backups/ | head -20
                pause
                ;;
            3)
                echo ""
                ls -1 backups/
                echo ""
                read -p "Directorio del backup: " backup_dir
                if [ -f "backups/$backup_dir/backup_info.txt" ]; then
                    cat "backups/$backup_dir/backup_info.txt"
                    echo ""
                    echo "Archivos:"
                    ls -lh "backups/$backup_dir/"
                else
                    error "Backup no encontrado"
                fi
                pause
                ;;
            4)
                echo ""
                read -p "Eliminar backups más antiguos de cuántos días? (30): " days
                days=${days:-30}
                log "Buscando backups más antiguos de $days días..."
                find backups/ -maxdepth 1 -type d -mtime +$days -exec rm -rf {} \;
                success "Backups antiguos eliminados"
                pause
                ;;
            5)
                warning "La restauración debe hacerse manualmente. Ver README.md"
                pause
                ;;
            6)
                echo ""
                crontab -l | grep backup || echo "No hay cron configurado"
                pause
                ;;
            0)
                break
                ;;
            *)
                error "Opción inválida"
                pause
                ;;
        esac
    done
}

# Función para ver logs
view_logs() {
    while true; do
        show_banner
        echo -e "${BLUE}═══ VISUALIZACIÓN DE LOGS ═══${NC}"
        echo ""
        echo "  1. Logs de Nginx (acceso)"
        echo "  2. Logs de Nginx (errores)"
        echo "  3. Logs de PHP-FPM"
        echo "  4. Logs de MySQL"
        echo "  5. Logs de todos los contenedores"
        echo "  6. Logs de instalación"
        echo "  0. Volver al menú principal"
        echo ""
        read -p "Selecciona una opción: " option
        
        case $option in
            1)
                tail -f logs/nginx/access.log
                ;;
            2)
                tail -f logs/nginx/error.log
                ;;
            3)
                docker compose logs -f php
                ;;
            4)
                docker compose logs -f mysql
                ;;
            5)
                docker compose logs -f
                ;;
            6)
                tail -f /var/log/wordpress-multisite-install.log
                ;;
            0)
                break
                ;;
            *)
                error "Opción inválida"
                pause
                ;;
        esac
    done
}

# Menú principal
main_menu() {
    while true; do
        show_banner
        echo -e "${BLUE}═══ MENÚ PRINCIPAL ═══${NC}"
        echo ""
        echo "  1. Ver estado del sistema"
        echo "  2. Gestión de contenedores"
        echo "  3. Gestión de bases de datos"
        echo "  4. Gestión de certificados SSL"
        echo "  5. Gestión de sitios WordPress"
        echo "  6. Gestión de backups"
        echo "  7. Ver logs"
        echo "  8. Mostrar credenciales"
        echo "  9. Ayuda y documentación"
        echo "  0. Salir"
        echo ""
        read -p "Selecciona una opción: " option
        
        case $option in
            1)
                show_status
                ;;
            2)
                manage_containers
                ;;
            3)
                manage_databases
                ;;
            4)
                manage_ssl
                ;;
            5)
                manage_sites
                ;;
            6)
                manage_backups
                ;;
            7)
                view_logs
                ;;
            8)
                show_banner
                echo -e "${BLUE}═══ CREDENCIALES DEL SISTEMA ═══${NC}"
                echo ""
                if [ -f .credentials ]; then
                    cat .credentials
                else
                    echo "MySQL Root: root / $MYSQL_ROOT_PASSWORD"
                    echo "MySQL User: wpuser / $DB_PASSWORD"
                    [ -n "$FTP_PASSWORD" ] && echo "FTP: ftpuser / $FTP_PASSWORD"
                fi
                echo ""
                pause
                ;;
            9)
                show_banner
                echo -e "${BLUE}═══ AYUDA Y DOCUMENTACIÓN ═══${NC}"
                echo ""
                echo "Documentación completa en: README.md"
                echo ""
                echo "Comandos útiles:"
                echo "  - docker compose ps     : Ver estado"
                echo "  - docker compose logs   : Ver logs"
                echo "  - docker compose restart: Reiniciar"
                echo ""
                echo "Ubicación de archivos importantes:"
                echo "  - Configuraciones: $(pwd)"
                echo "  - Sitios WordPress: $(pwd)/www/"
                echo "  - Backups: $(pwd)/backups/"
                echo "  - Logs: $(pwd)/logs/"
                echo ""
                pause
                ;;
            0)
                echo ""
                success "¡Hasta luego!"
                exit 0
                ;;
            *)
                error "Opción inválida"
                pause
                ;;
        esac
    done
}

# Verificar si se ejecuta como root para ciertas operaciones
if [[ $EUID -ne 0 ]]; then
    warning "Algunas funciones requieren permisos de root (sudo)"
    echo ""
    pause
fi

# Iniciar menú principal
main_menu
