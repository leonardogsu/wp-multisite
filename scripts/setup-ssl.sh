#!/bin/bash

################################################################################
# Script de gestión de certificados SSL con Let's Encrypt
# Versión mejorada - siempre verifica y corrige estructura de archivos
################################################################################

set -e

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Cargar variables
if [ ! -f .env ]; then
    error "Archivo .env no encontrado"
fi

source .env

log "═══════════════════════════════════════════════════"
log "CONFIGURACIÓN DE CERTIFICADOS SSL"
log "═══════════════════════════════════════════════════"
echo ""

# Verificar que los contenedores estén corriendo
if ! docker compose ps | grep -q "Up"; then
    error "Los contenedores no están corriendo. Ejecuta primero: ./scripts/setup.sh"
fi

# Verificar si phpMyAdmin está habilitado
PHPMYADMIN_ENABLED=false
if grep -q "INSTALL_PHPMYADMIN=true" .env 2>/dev/null; then
    PHPMYADMIN_ENABLED=true
    info "phpMyAdmin detectado - se configurará SSL para él también"
fi

# Obtener dominios
DOMAINS=($(grep "^DOMAIN_" .env | cut -d'=' -f2))

if [ ${#DOMAINS[@]} -eq 0 ]; then
    error "No se encontraron dominios en .env"
fi

info "Dominios a procesar: ${DOMAINS[@]}"
echo ""

################################################################################
# VERIFICACIÓN DE CERTIFICADOS EXISTENTES
################################################################################

log "═══════════════════════════════════════════════════"
log "VERIFICACIÓN DE CERTIFICADOS EXISTENTES"
log "═══════════════════════════════════════════════════"
echo ""

EXISTING_CERTS=()
MISSING_CERTS=()

for DOMAIN in "${DOMAINS[@]}"; do
    if [ -d "certbot/conf/live/$DOMAIN" ] && [ -f "certbot/conf/live/$DOMAIN/fullchain.pem" ]; then
        EXISTING_CERTS+=("$DOMAIN")

        # Obtener fecha de expiración
        EXPIRY=$(openssl x509 -enddate -noout -in "certbot/conf/live/$DOMAIN/cert.pem" 2>/dev/null | cut -d= -f2 || echo "Desconocida")

        # Calcular días restantes
        if [ "$EXPIRY" != "Desconocida" ]; then
            EXPIRY_TIMESTAMP=$(date -d "$EXPIRY" +%s 2>/dev/null || echo "0")
            CURRENT_TIMESTAMP=$(date +%s)
            DAYS_LEFT=$(( ($EXPIRY_TIMESTAMP - $CURRENT_TIMESTAMP) / 86400 ))

            if [ $DAYS_LEFT -lt 30 ]; then
                warning "  ✓ $DOMAIN - Certificado existente (⚠ Expira en $DAYS_LEFT días)"
            else
                success "  ✓ $DOMAIN - Certificado existente (Expira en $DAYS_LEFT días)"
            fi
        else
            success "  ✓ $DOMAIN - Certificado existente"
        fi
    else
        MISSING_CERTS+=("$DOMAIN")
        warning "  ✗ $DOMAIN - Sin certificado"
    fi
done

echo ""

# Determinar si se puede saltar la generación de certificados
SKIP_CERT_GENERATION=false

if [ ${#EXISTING_CERTS[@]} -eq ${#DOMAINS[@]} ]; then
    success "Todos los dominios (${#EXISTING_CERTS[@]}/${#DOMAINS[@]}) ya tienen certificados SSL"
    echo ""
    warning "OPCIONES:"
    echo "  1. Usar certificados existentes y solo actualizar configuración Nginx (RECOMENDADO)"
    echo "  2. Regenerar certificados desde cero (consume límite de Let's Encrypt)"
    echo ""
    read -p "¿Qué deseas hacer? (1/2): " cert_option

    if [[ "$cert_option" == "1" ]]; then
        SKIP_CERT_GENERATION=true
        # Todos los certificados existentes son "exitosos"
        SUCCESSFUL_CERTS=("${EXISTING_CERTS[@]}")
        FAILED_CERTS=()

        success "✓ Se usarán los certificados existentes"
        info "Saltando directamente a la configuración de Nginx..."
        echo ""
    else
        info "Se procederá a regenerar los certificados"
        echo ""
    fi
elif [ ${#EXISTING_CERTS[@]} -gt 0 ]; then
    info "Certificados existentes: ${#EXISTING_CERTS[@]}/${#DOMAINS[@]}"
    info "Se procesarán todos los dominios (puedes omitir los existentes individualmente)"
    echo ""
else
    info "No se encontraron certificados existentes"
    info "Se procederá a obtener certificados para todos los dominios"
    echo ""
fi

################################################################################
# OBTENER CERTIFICADOS (si no se omitió)
################################################################################

if [ "$SKIP_CERT_GENERATION" = false ]; then
    # Solicitar email solo si vamos a generar certificados
    read -p "Ingresa tu email para Let's Encrypt: " EMAIL

    if [ -z "$EMAIL" ]; then
        error "Email es requerido para Let's Encrypt"
    fi

    # Validar formato de email básico
    if [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        error "Formato de email inválido"
    fi

    log "Email configurado: $EMAIL"
    echo ""

    warning "IMPORTANTE: Antes de continuar, asegúrate de que:"
    echo "  1. Los DNS de tus dominios apuntan a este servidor ($SERVER_IP)"
    echo "  2. Los puertos 80 y 443 están abiertos en el firewall"
    echo "  3. Los sitios WordPress responden correctamente en HTTP"
    echo ""
    read -p "¿Continuar con la obtención de certificados SSL? (s/n): " confirm
    if [[ ! $confirm =~ ^[Ss]$ ]]; then
        error "Proceso cancelado por el usuario"
    fi

    echo ""

    log "═══════════════════════════════════════════════════"
    log "PASO 1: Obtención de certificados SSL"
    log "═══════════════════════════════════════════════════"
    echo ""

    SUCCESSFUL_CERTS=()
    FAILED_CERTS=()

    for DOMAIN in "${DOMAINS[@]}"; do
        log "Procesando dominio: $DOMAIN"

        # Verificar si ya existe el certificado
        if [ -d "certbot/conf/live/$DOMAIN" ]; then
            warning "  Certificado ya existe para $DOMAIN"

            # Mostrar fecha de expiración
            EXPIRY=$(openssl x509 -enddate -noout -in "certbot/conf/live/$DOMAIN/cert.pem" 2>/dev/null | cut -d= -f2 || echo "Desconocida")
            info "  Expira: $EXPIRY"

            read -p "  ¿Renovar/Recrear certificado? (s/n): " renew
            if [[ ! $renew =~ ^[Ss]$ ]]; then
                log "  Omitiendo $DOMAIN (usando certificado existente)"
                SUCCESSFUL_CERTS+=("$DOMAIN")
                echo ""
                continue
            fi

            # Si el usuario quiere renovar, eliminar certificados existentes
            log "  Eliminando certificados existentes..."
            rm -rf "certbot/conf/live/$DOMAIN"
            rm -rf "certbot/conf/archive/$DOMAIN"
            rm -rf "certbot/conf/renewal/$DOMAIN.conf"
            success "  ✓ Certificados anteriores eliminados"
        fi

        # Probar conectividad HTTP primero
        log "  Verificando que $DOMAIN es accesible vía HTTP..."
        if curl -s -f -o /dev/null --max-time 5 "http://$DOMAIN" 2>/dev/null; then
            success "  ✓ Dominio accesible vía HTTP"
        else
            warning "  ⚠ No se pudo verificar acceso HTTP a $DOMAIN"
            warning "  Esto puede causar que la validación de Let's Encrypt falle"
            read -p "  ¿Continuar de todos modos? (s/n): " continue_anyway
            if [[ ! $continue_anyway =~ ^[Ss]$ ]]; then
                warning "  Omitiendo $DOMAIN"
                FAILED_CERTS+=("$DOMAIN")
                echo ""
                continue
            fi
        fi

        # Obtener certificado - IMPORTANTE: usar --entrypoint certbot
        log "  Solicitando certificado SSL para $DOMAIN y www.$DOMAIN..."
        echo "  (Esto puede tardar 1-2 minutos...)"

        if docker compose run --rm --entrypoint certbot certbot certonly \
            --webroot \
            --webroot-path=/var/www/certbot \
            --email "$EMAIL" \
            --agree-tos \
            --no-eff-email \
            --force-renewal \
            -d "$DOMAIN" \
            -d "www.$DOMAIN" 2>&1 | tee /tmp/certbot_${DOMAIN}.log; then

            # Verificar que el certificado se creó correctamente
            if [ -d "certbot/conf/live/$DOMAIN" ] && [ -f "certbot/conf/live/$DOMAIN/fullchain.pem" ]; then
                success "  ✓ Certificado obtenido exitosamente para $DOMAIN"
                SUCCESSFUL_CERTS+=("$DOMAIN")
            else
                warning "  ✗ El proceso terminó pero no se encontró el certificado"
                warning "  Verifica el log: /tmp/certbot_${DOMAIN}.log"
                FAILED_CERTS+=("$DOMAIN")
            fi
        else
            warning "  ✗ Error al obtener certificado para $DOMAIN"
            warning "  Causas comunes:"
            echo "    - DNS no apunta a $SERVER_IP"
            echo "    - Puerto 80 bloqueado"
            echo "    - Nginx no está funcionando correctamente"
            warning "  Revisa el log: /tmp/certbot_${DOMAIN}.log"
            FAILED_CERTS+=("$DOMAIN")
        fi

        echo ""
    done

    # Resumen de certificados obtenidos
    echo ""
    log "═══════════════════════════════════════════════════"
    log "RESUMEN DE CERTIFICADOS"
    log "═══════════════════════════════════════════════════"
    echo ""

    if [ ${#SUCCESSFUL_CERTS[@]} -gt 0 ]; then
        success "Certificados exitosos (${#SUCCESSFUL_CERTS[@]}):"
        for domain in "${SUCCESSFUL_CERTS[@]}"; do
            echo "  ✓ $domain"
        done
        echo ""
    fi

    if [ ${#FAILED_CERTS[@]} -gt 0 ]; then
        warning "Certificados fallidos (${#FAILED_CERTS[@]}):"
        for domain in "${FAILED_CERTS[@]}"; do
            echo "  ✗ $domain"
        done
        echo ""
        warning "Los dominios fallidos NO se configurarán con HTTPS"
        echo ""
    fi

    if [ ${#SUCCESSFUL_CERTS[@]} -eq 0 ]; then
        error "No se obtuvo ningún certificado. Verifica DNS y conectividad."
    fi
else
    log "═══════════════════════════════════════════════════"
    log "PASO 1: Obtención de certificados SSL (OMITIDO)"
    log "═══════════════════════════════════════════════════"
    echo ""
    info "Usando certificados existentes para: ${SUCCESSFUL_CERTS[@]}"
    echo ""
fi

################################################################################
# ACTIVAR HTTPS EN NGINX
################################################################################

log "═══════════════════════════════════════════════════"
log "PASO 2: Activación de HTTPS en Nginx"
log "═══════════════════════════════════════════════════"
echo ""

for i in "${!SUCCESSFUL_CERTS[@]}"; do
    DOMAIN="${SUCCESSFUL_CERTS[$i]}"
    SITE_NUM=$((i + 1))
    CONFIG_FILE="nginx/conf.d/${DOMAIN}.conf"

    if [ ! -f "$CONFIG_FILE" ]; then
        warning "  Configuración no encontrada: $CONFIG_FILE"
        continue
    fi

    log "Actualizando configuración para $DOMAIN (sitio $SITE_NUM)..."

    # Crear backup
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup-$(date +%Y%m%d-%H%M%S)"

    # Verificar si hay bloques HTTPS comentados que necesiten procesarse
    NEEDS_PROCESSING=false

    if grep -q "^#.*listen.*443.*ssl" "$CONFIG_FILE" || grep -q "^#[[:space:]]*}" "$CONFIG_FILE"; then
        NEEDS_PROCESSING=true
        info "  → Detectado bloque HTTPS con contenido comentado - procesando..."
    elif ! grep -q "^[[:space:]]*listen 443 ssl" "$CONFIG_FILE"; then
        NEEDS_PROCESSING=true
        info "  → HTTPS no activado - procesando..."
    else
        info "  → HTTPS completamente activado - verificando variables..."
    fi

    if $NEEDS_PROCESSING; then
        # Crear archivo temporal para la nueva configuración
        TEMP_FILE=$(mktemp)

        # Variables para rastrear el estado
        IN_HTTPS_BLOCK=false
        BRACE_COUNT=0
        FOUND_HTTPS_START=false

        while IFS= read -r line; do
            # Detectar inicio del bloque HTTPS comentado
            if [[ "$line" =~ ^#[[:space:]]*server[[:space:]]*\{[[:space:]]*$ ]] && ! $FOUND_HTTPS_START; then
                # Leer la siguiente línea para confirmar que es el bloque HTTPS
                next_line=""
                if IFS= read -r next_line; then
                    if [[ "$next_line" =~ listen[[:space:]]+443[[:space:]]+ssl ]]; then
                        FOUND_HTTPS_START=true
                        IN_HTTPS_BLOCK=true
                        BRACE_COUNT=1

                        # Descomentar la línea actual (server {)
                        echo "server {" >> "$TEMP_FILE"
                        # Descomentar la siguiente línea (listen 443)
                        uncommented_next="${next_line//#[[:space:]]/}"
                        echo "$uncommented_next" >> "$TEMP_FILE"
                        continue
                    else
                        # No es el bloque HTTPS, escribir ambas líneas sin modificar
                        echo "$line" >> "$TEMP_FILE"
                        echo "$next_line" >> "$TEMP_FILE"
                        continue
                    fi
                fi
            fi

            # Detectar inicio del bloque HTTPS ya descomentado pero con contenido comentado dentro
            if [[ "$line" =~ ^[[:space:]]*server[[:space:]]*\{[[:space:]]*$ ]] && ! $FOUND_HTTPS_START; then
                # Leer la siguiente línea para confirmar que es el bloque HTTPS
                next_line=""
                if IFS= read -r next_line; then
                    if [[ "$next_line" =~ ^[[:space:]]*listen[[:space:]]+443[[:space:]]+ssl ]]; then
                        FOUND_HTTPS_START=true
                        IN_HTTPS_BLOCK=true
                        BRACE_COUNT=1

                        # Escribir la línea actual (server {)
                        echo "$line" >> "$TEMP_FILE"
                        # Escribir la siguiente línea (listen 443)
                        echo "$next_line" >> "$TEMP_FILE"
                        continue
                    else
                        # No es el bloque HTTPS, escribir ambas líneas sin modificar
                        echo "$line" >> "$TEMP_FILE"
                        echo "$next_line" >> "$TEMP_FILE"
                        continue
                    fi
                fi
            fi

            # Si estamos dentro del bloque HTTPS, descomentar y contar llaves
            if $IN_HTTPS_BLOCK; then
                # Descomentar la línea
                uncommented="${line//#[[:space:]]/}"

                # Contar llaves en la línea descomentada
                # Contar { que se abren
                open_braces=$(echo "$uncommented" | grep -o '{' | wc -l)
                # Contar } que se cierran
                close_braces=$(echo "$uncommented" | grep -o '}' | wc -l)

                BRACE_COUNT=$((BRACE_COUNT + open_braces - close_braces))

                # Escribir la línea descomentada
                if [[ -n "$uncommented" ]]; then
                    echo "$uncommented" >> "$TEMP_FILE"
                else
                    echo "" >> "$TEMP_FILE"
                fi

                # Si el contador de llaves llega a 0, terminamos el bloque HTTPS
                if [ $BRACE_COUNT -eq 0 ]; then
                    IN_HTTPS_BLOCK=false
                    success "  ✓ Bloque HTTPS procesado completamente"
                fi
            else
                # Fuera del bloque HTTPS, escribir la línea tal cual
                echo "$line" >> "$TEMP_FILE"
            fi
        done < "$CONFIG_FILE"

        # Reemplazar archivo original
        mv "$TEMP_FILE" "$CONFIG_FILE"
        success "  ✓ Archivo procesado y estructura corregida"
    fi

    # CRÍTICO: Reemplazar las variables $DOMAIN y $SITE_NUM con valores reales
    sed -i "s/\$DOMAIN/${DOMAIN}/g" "$CONFIG_FILE"
    sed -i "s/\$SITE_NUM/${SITE_NUM}/g" "$CONFIG_FILE"

    success "  ✓ Configuración actualizada para $DOMAIN"
done

echo ""

################################################################################
# ACTIVAR REDIRECCIÓN HTTP → HTTPS
################################################################################

log "═══════════════════════════════════════════════════"
log "PASO 3: Activación de redirección HTTP → HTTPS"
log "═══════════════════════════════════════════════════"
echo ""

warning "Esto redirigirá TODO el tráfico HTTP a HTTPS"
read -p "¿Activar redirección ahora? (s/n): " enable_redirect

if [[ $enable_redirect =~ ^[Ss]$ ]]; then
    for DOMAIN in "${SUCCESSFUL_CERTS[@]}"; do
        CONFIG_FILE="nginx/conf.d/${DOMAIN}.conf"

        log "  Activando redirección para $DOMAIN..."

        # Descomentar la línea de redirección en el bloque HTTP (puerto 80)
        sed -i 's/^[[:space:]]*#[[:space:]]*return 301 https/    return 301 https/g' "$CONFIG_FILE"

        success "  ✓ Redirección activada para $DOMAIN"
    done
    echo ""
    info "Redirección HTTP → HTTPS activada"
else
    echo ""
    info "Redirección NO activada. Para activarla manualmente:"
    echo "  Edita los archivos nginx/conf.d/*.conf"
    echo "  Descomenta la línea: # return 301 https://\$server_name\$request_uri;"
fi

echo ""

################################################################################
# VALIDAR Y RECARGAR NGINX
################################################################################

log "═══════════════════════════════════════════════════"
log "PASO 4: Validación y recarga de Nginx"
log "═══════════════════════════════════════════════════"
echo ""

log "Validando configuración de Nginx..."
if docker compose exec nginx nginx -t 2>&1 | grep -q "syntax is ok"; then
    success "✓ Configuración de Nginx válida"

    log "Recargando Nginx..."
    if docker compose exec nginx nginx -s reload; then
        success "✓ Nginx recargado exitosamente"
    else
        error "Error al recargar Nginx"
    fi
else
    error "La configuración de Nginx tiene errores. Revisa los archivos de configuración."
fi

################################################################################
# RESUMEN FINAL
################################################################################

echo ""
log "═══════════════════════════════════════════════════"
log "✓ CONFIGURACIÓN SSL COMPLETADA"
log "═══════════════════════════════════════════════════"
echo ""

success "Certificados SSL instalados y activos:"
for DOMAIN in "${SUCCESSFUL_CERTS[@]}"; do
    echo "  ✓ https://$DOMAIN"
    echo "  ✓ https://www.$DOMAIN"

    # Mostrar expiración
    if [ -f "certbot/conf/live/$DOMAIN/cert.pem" ]; then
        EXPIRY=$(openssl x509 -enddate -noout -in "certbot/conf/live/$DOMAIN/cert.pem" 2>/dev/null | cut -d= -f2)
        echo "     Expira: $EXPIRY"
    fi

    # Mostrar acceso a phpMyAdmin si está habilitado
    if [ "$PHPMYADMIN_ENABLED" = true ]; then
        echo "     phpMyAdmin: https://$DOMAIN/phpmyadmin/"
    fi
    echo ""
done

if [ ${#FAILED_CERTS[@]} -gt 0 ]; then
    echo ""
    warning "Dominios sin SSL (aún accesibles por HTTP):"
    for domain in "${FAILED_CERTS[@]}"; do
        echo "  → http://$domain"
    done
fi

echo ""
info "═══ INFORMACIÓN IMPORTANTE ═══"
echo ""
echo "  • Los certificados SSL se renovarán automáticamente cada 12 horas"
echo "  • Los certificados son válidos por 90 días"
echo "  • Let's Encrypt tiene límite de 5 certificados por dominio por semana"
echo ""
echo "  Comandos útiles:"
echo "    - Ver certificados: docker compose run --rm --entrypoint certbot certbot certificates"
echo "    - Renovar manualmente: docker compose run --rm --entrypoint certbot certbot renew"
echo "    - Ver logs de certbot: docker compose exec certbot cat /var/log/letsencrypt/letsencrypt.log"
echo "    - Ver logs de Nginx: docker compose logs nginx"
echo "    - Probar configuración: docker compose exec nginx nginx -t"
echo ""

if [ "$PHPMYADMIN_ENABLED" = true ]; then
    info "═══ ACCESO A PHPMYADMIN ═══"
    echo ""
    echo "  Ahora phpMyAdmin está disponible con SSL:"
    for DOMAIN in "${SUCCESSFUL_CERTS[@]}"; do
        echo "    https://$DOMAIN/phpmyadmin/"
    done
    echo ""
    echo "  Credenciales HTTP (primera capa):"
    PHPMYADMIN_USER=$(grep "^PHPMYADMIN_AUTH_USER=" .env | cut -d'=' -f2)
    echo "    Usuario: $PHPMYADMIN_USER"
    echo "    (Contraseña en .env)"
    echo ""
fi

success "¡Tus sitios ahora están protegidos con SSL/TLS!"
echo ""