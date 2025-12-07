#!/bin/bash

###########################################
# WordPress Security Permissions Script v3
# Compatible con SFTP (atmoz/sftp)
# Permisos híbridos: seguro + funcional
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
# UID/GID para compatibilidad con SFTP y PHP-FPM Alpine (wordpress:php-fpm-alpine usa 82:82)
SFTP_UID="82"
SFTP_GID="82"

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

Script de seguridad WordPress compatible con SFTP.
Aplica permisos híbridos: estrictos en core, permisivos en wp-content.

Opciones:
    --container  Nombre del contenedor PHP (default: php)
    --path       Ruta dentro del contenedor (default: /var/www/html)
    --user       Usuario web (default: www-data)
    --group      Grupo web (default: www-data)
    --sftp-uid   UID del usuario SFTP (default: 82)
    --sftp-gid   GID del usuario SFTP (default: 82)
    --strict     Modo estricto (sin compatibilidad SFTP)
    --help       Muestra esta ayuda

Ejemplos:
    # Securizar un sitio (compatible con SFTP)
    $0 --path /var/www/html/angel_guaman_net

    # Securizar sin compatibilidad SFTP (máxima seguridad)
    $0 --path /var/www/html/angel_guaman_net --strict

    # Securizar todos los sitios
    $0 --path /var/www/html

Permisos aplicados:
    ┌─────────────────────────┬────────────┬─────────────┐
    │ Ubicación               │ Normal     │ --strict    │
    ├─────────────────────────┼────────────┼─────────────┤
    │ wp-admin/               │ 755/644    │ 755/644     │
    │ wp-includes/            │ 755/644    │ 755/644     │
    │ Archivos raíz (*.php)   │ 644        │ 644         │
    │ wp-config.php           │ 440        │ 440         │
    │ wp-content/             │ 775/664    │ 755/644     │
    │ wp-content/uploads/     │ 775/664    │ 755/644     │
    │ wp-content/plugins/     │ 775/664    │ 755/644     │
    │ wp-content/themes/      │ 775/664    │ 755/644     │
    └─────────────────────────┴────────────┴─────────────┘

EOF
    exit 1
}

STRICT_MODE=false

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

    if ! docker exec "$CONTAINER_NAME" test -d "$WP_PATH_CONTAINER" 2>/dev/null; then
        print_error "La ruta '$WP_PATH_CONTAINER' no existe dentro del contenedor"
        list_wordpress_sites
        exit 1
    fi

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
    print_info "Modo: $([[ $STRICT_MODE == true ]] && echo 'ESTRICTO (sin SFTP)' || echo 'NORMAL (compatible SFTP)')"
    print_info "Analizando permisos actuales..."

    echo ""
    print_info "═══ ARCHIVOS CRÍTICOS ═══"

    for file in wp-config.php .htaccess index.php; do
        if docker exec "$CONTAINER_NAME" test -f "$WP_PATH_CONTAINER/$file" 2>/dev/null; then
            local info=$(docker exec "$CONTAINER_NAME" ls -la "$WP_PATH_CONTAINER/$file" 2>/dev/null | awk '{print $1, $3":"$4, $9}')
            echo "  $file: $info"
        fi
    done

    echo ""
    print_info "═══ DIRECTORIOS PRINCIPALES ═══"

    for dir in wp-content wp-content/themes wp-content/plugins wp-content/uploads wp-admin wp-includes; do
        if docker exec "$CONTAINER_NAME" test -d "$WP_PATH_CONTAINER/$dir" 2>/dev/null; then
            local info=$(docker exec "$CONTAINER_NAME" ls -lad "$WP_PATH_CONTAINER/$dir" 2>/dev/null | awk '{print $1, $3":"$4}')
            echo "  $dir/: $info"
        fi
    done

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

    echo ""
    local current_owner=$(docker exec "$CONTAINER_NAME" stat -c "%U:%G" "$WP_PATH_CONTAINER" 2>/dev/null || echo "desconocido")
    print_info "Propietario actual: $current_owner"
}

###########################################
# Aplicar securización HÍBRIDA
###########################################

apply_security() {
    print_header "APLICANDO SECURIZACIÓN"

    if [[ $STRICT_MODE == true ]]; then
        print_warning "MODO ESTRICTO: SFTP no podrá escribir en wp-content"
        echo ""
        echo "  📂 SITIO: $WP_PATH_CONTAINER"
        echo ""
        echo "  🔒 PERMISOS (máxima seguridad):"
        echo "     • Todos los directorios: 755"
        echo "     • Todos los archivos: 644"
        echo "     • wp-config.php: 440"
        echo ""
    else
        print_info "MODO NORMAL: Compatible con SFTP"
        echo ""
        echo "  📂 SITIO: $WP_PATH_CONTAINER"
        echo ""
        echo "  🔒 PERMISOS HÍBRIDOS:"
        echo ""
        echo "     CORE (solo lectura - máxima seguridad):"
        echo "     • wp-admin/: 755/644"
        echo "     • wp-includes/: 755/644"
        echo "     • Archivos raíz: 644"
        echo "     • wp-config.php: 440"
        echo ""
        echo "     CONTENIDO (escritura habilitada - SFTP compatible):"
        echo "     • wp-content/: 775/664"
        echo "     • wp-content/uploads/: 775/664"
        echo "     • wp-content/plugins/: 775/664"
        echo "     • wp-content/themes/: 775/664"
        echo ""
    fi

    echo "  👤 PROPIETARIO: $SFTP_UID:$SFTP_GID (compatible con SFTP)"
    echo ""

    read -p "¿Continuar con la securización? (escribe 'SI' para confirmar): " confirm

    if [[ "${confirm}" != "SI" ]]; then
        print_warning "Operación cancelada"
        exit 0
    fi

    echo ""
    print_info "Iniciando securización..."
    echo ""

    # 1. Cambiar propietario a UID:GID numérico (compatible con SFTP)
    print_info "[1/8] Cambiando propietario a $SFTP_UID:$SFTP_GID..."
    docker exec "$CONTAINER_NAME" chown -R "$SFTP_UID":"$SFTP_GID" "$WP_PATH_CONTAINER" 2>/dev/null && \
        print_success "Propietario actualizado" || \
        print_warning "No se pudo cambiar el propietario"

    # 2. Permisos base para TODOS los directorios (755)
    print_info "[2/8] Estableciendo permisos 755 para todos los directorios..."
    docker exec "$CONTAINER_NAME" sh -c "find '$WP_PATH_CONTAINER' -type d -exec chmod 755 {} + 2>/dev/null" && \
        print_success "Permisos de directorios base establecidos"

    # 3. Permisos base para TODOS los archivos (644)
    print_info "[3/8] Estableciendo permisos 644 para todos los archivos..."
    docker exec "$CONTAINER_NAME" sh -c "find '$WP_PATH_CONTAINER' -type f -exec chmod 644 {} + 2>/dev/null" && \
        print_success "Permisos de archivos base establecidos"

    # 4. Securizar wp-config.php (siempre estricto)
    if docker exec "$CONTAINER_NAME" test -f "$WP_PATH_CONTAINER/wp-config.php" 2>/dev/null; then
        print_info "[4/8] Securizando wp-config.php (440)..."
        docker exec "$CONTAINER_NAME" chmod 440 "$WP_PATH_CONTAINER/wp-config.php" 2>/dev/null && \
            print_success "wp-config.php securizado (440)"
    else
        print_warning "[4/8] wp-config.php no encontrado"
    fi

    # 5. Securizar .htaccess
    if docker exec "$CONTAINER_NAME" test -f "$WP_PATH_CONTAINER/.htaccess" 2>/dev/null; then
        print_info "[5/8] Securizando .htaccess (644)..."
        docker exec "$CONTAINER_NAME" chmod 644 "$WP_PATH_CONTAINER/.htaccess" 2>/dev/null && \
            print_success ".htaccess securizado"
    else
        print_info "[5/8] .htaccess no encontrado (normal con Nginx)"
    fi

    # 6, 7, 8: Aplicar permisos especiales a wp-content (solo si NO es modo estricto)
    if [[ $STRICT_MODE == false ]]; then
        # 6. wp-content principal
        if docker exec "$CONTAINER_NAME" test -d "$WP_PATH_CONTAINER/wp-content" 2>/dev/null; then
            print_info "[6/8] Configurando wp-content/ para SFTP (775/664)..."
            docker exec "$CONTAINER_NAME" sh -c "
                chmod 775 '$WP_PATH_CONTAINER/wp-content'
            " 2>/dev/null && print_success "wp-content/ configurado"
        fi

        # 7. Subdirectorios de wp-content que necesitan escritura
        print_info "[7/8] Configurando subdirectorios de wp-content..."
        for subdir in uploads plugins themes upgrade cache; do
            if docker exec "$CONTAINER_NAME" test -d "$WP_PATH_CONTAINER/wp-content/$subdir" 2>/dev/null; then
                docker exec "$CONTAINER_NAME" sh -c "
                    find '$WP_PATH_CONTAINER/wp-content/$subdir' -type d -exec chmod 775 {} + 2>/dev/null
                    find '$WP_PATH_CONTAINER/wp-content/$subdir' -type f -exec chmod 664 {} + 2>/dev/null
                " 2>/dev/null
                print_success "  wp-content/$subdir/ → 775/664"
            fi
        done

        # 8. Crear directorios faltantes con permisos correctos
        print_info "[8/8] Verificando/creando directorios necesarios..."
        for subdir in uploads plugins themes upgrade; do
            if ! docker exec "$CONTAINER_NAME" test -d "$WP_PATH_CONTAINER/wp-content/$subdir" 2>/dev/null; then
                docker exec "$CONTAINER_NAME" sh -c "
                    mkdir -p '$WP_PATH_CONTAINER/wp-content/$subdir'
                    chown $SFTP_UID:$SFTP_GID '$WP_PATH_CONTAINER/wp-content/$subdir'
                    chmod 775 '$WP_PATH_CONTAINER/wp-content/$subdir'
                " 2>/dev/null
                print_success "  Creado: wp-content/$subdir/"
            fi
        done
    else
        print_info "[6/8] Modo estricto: wp-content mantiene 755/644"
        print_info "[7/8] Modo estricto: sin permisos especiales"
        print_info "[8/8] Modo estricto: completado"
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

    # Verificar 777
    local final_777_files=$(docker exec "$CONTAINER_NAME" sh -c "find '$WP_PATH_CONTAINER' -maxdepth 4 -type f -perm 0777 2>/dev/null | wc -l")
    local final_777_dirs=$(docker exec "$CONTAINER_NAME" sh -c "find '$WP_PATH_CONTAINER' -maxdepth 4 -type d -perm 0777 2>/dev/null | wc -l")

    if [[ $final_777_files -eq 0 ]]; then
        print_success "No hay archivos con permisos 777"
    else
        print_warning "Aún hay $final_777_files archivos con permisos 777"
    fi

    if [[ $final_777_dirs -eq 0 ]]; then
        print_success "No hay directorios con permisos 777"
    else
        print_warning "Aún hay $final_777_dirs directorios con permisos 777"
    fi

    # Verificar wp-config.php
    if docker exec "$CONTAINER_NAME" test -f "$WP_PATH_CONTAINER/wp-config.php" 2>/dev/null; then
        local wpconfig_perms=$(docker exec "$CONTAINER_NAME" stat -c "%a" "$WP_PATH_CONTAINER/wp-config.php" 2>/dev/null)

        if [[ "$wpconfig_perms" == "440" ]] || [[ "$wpconfig_perms" == "400" ]]; then
            print_success "wp-config.php tiene permisos seguros ($wpconfig_perms)"
        else
            print_warning "wp-config.php tiene permisos $wpconfig_perms"
        fi
    fi

    # Verificar propietario
    local final_owner=$(docker exec "$CONTAINER_NAME" stat -c "%u:%g" "$WP_PATH_CONTAINER" 2>/dev/null)
    if [[ "$final_owner" == "$SFTP_UID:$SFTP_GID" ]]; then
        print_success "Propietario correcto: $final_owner (compatible SFTP)"
    else
        print_info "Propietario actual: $final_owner"
    fi

    # Verificar permisos de wp-content (solo si no es modo estricto)
    if [[ $STRICT_MODE == false ]]; then
        echo ""
        print_info "═══ VERIFICACIÓN SFTP ═══"

        if docker exec "$CONTAINER_NAME" test -d "$WP_PATH_CONTAINER/wp-content" 2>/dev/null; then
            local wpcontent_perms=$(docker exec "$CONTAINER_NAME" stat -c "%a" "$WP_PATH_CONTAINER/wp-content" 2>/dev/null)
            if [[ "$wpcontent_perms" == "775" ]]; then
                print_success "wp-content/: $wpcontent_perms (SFTP puede escribir)"
            else
                print_warning "wp-content/: $wpcontent_perms (SFTP podría tener problemas)"
            fi
        fi

        for subdir in uploads plugins themes; do
            if docker exec "$CONTAINER_NAME" test -d "$WP_PATH_CONTAINER/wp-content/$subdir" 2>/dev/null; then
                local subdir_perms=$(docker exec "$CONTAINER_NAME" stat -c "%a" "$WP_PATH_CONTAINER/wp-content/$subdir" 2>/dev/null)
                if [[ "$subdir_perms" == "775" ]]; then
                    print_success "wp-content/$subdir/: $subdir_perms ✓"
                else
                    print_warning "wp-content/$subdir/: $subdir_perms"
                fi
            fi
        done
    fi

    # Resumen de seguridad
    echo ""
    print_info "═══ RESUMEN DE SEGURIDAD ═══"

    echo ""
    echo "  PROTEGIDO (solo lectura):"
    echo "    • wp-admin/"
    echo "    • wp-includes/"
    echo "    • wp-config.php (440)"
    echo "    • Archivos PHP raíz"

    if [[ $STRICT_MODE == false ]]; then
        echo ""
        echo "  ESCRITURA HABILITADA (SFTP/WordPress):"
        echo "    • wp-content/uploads/"
        echo "    • wp-content/plugins/"
        echo "    • wp-content/themes/"
        echo "    • wp-content/upgrade/"
    fi
}

###########################################
# Main
###########################################

main() {
    print_header "WORDPRESS SECURITY v3 - SFTP COMPATIBLE"

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
            --sftp-uid)
                SFTP_UID="$2"
                shift 2
                ;;
            --sftp-gid)
                SFTP_GID="$2"
                shift 2
                ;;
            --strict)
                STRICT_MODE=true
                shift
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

    # Normalizar path
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
    print_info "Modo: $([[ $STRICT_MODE == true ]] && echo 'ESTRICTO' || echo 'SFTP COMPATIBLE')"
    echo ""

    if [[ $STRICT_MODE == false ]]; then
        print_success "SFTP debería funcionar correctamente en wp-content/"
        echo ""
    fi

    print_info "📋 Recomendaciones adicionales:"
    echo "  1. Actualiza WordPress, temas y plugins regularmente"
    echo "  2. Usa contraseñas fuertes para todos los usuarios"
    echo "  3. Instala un plugin de seguridad (Wordfence, Sucuri)"
    echo "  4. Realiza backups periódicos automáticos"
    echo "  5. Activa SSL/HTTPS en tu sitio"
    echo ""
}

main "$@"