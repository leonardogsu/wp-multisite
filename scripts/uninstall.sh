#!/bin/bash

################################################################################
# WordPress Multi-Site - Desinstalador
# Elimina completamente la instalación
################################################################################

set -e

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}"
cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║           ⚠️  DESINSTALACIÓN COMPLETA  ⚠️                     ║
║                                                               ║
║     ESTA ACCIÓN ELIMINARÁ PERMANENTEMENTE:                    ║
║     - Todos los contenedores Docker                           ║
║     - Todas las bases de datos                                ║
║     - Todos los sitios WordPress                              ║
║     - Todas las configuraciones                               ║
║     - Todos los backups                                       ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

echo ""
echo -e "${YELLOW}¿Estás COMPLETAMENTE SEGURO de que deseas continuar?${NC}"
echo "Esta acción NO se puede deshacer."
echo ""
read -p "Escribe 'ELIMINAR TODO' para confirmar: " confirm

if [ "$confirm" != "ELIMINAR TODO" ]; then
    echo ""
    echo -e "${GREEN}Desinstalación cancelada.${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}Segunda confirmación requerida.${NC}"
read -p "¿Realmente deseas eliminar TODOS los datos? (escribe 'sí'): " confirm2

if [ "$confirm2" != "sí" ]; then
    echo ""
    echo -e "${GREEN}Desinstalación cancelada.${NC}"
    exit 0
fi

# Verificar root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Este script debe ejecutarse como root (usa sudo)${NC}" 
   exit 1
fi

INSTALL_DIR="/opt/wordpress-multisite"

if [ ! -d "$INSTALL_DIR" ]; then
    echo -e "${YELLOW}El directorio $INSTALL_DIR no existe.${NC}"
    read -p "¿Continuar de todos modos? (s/n): " continue_anyway
    if [[ ! $continue_anyway =~ ^[Ss]$ ]]; then
        exit 0
    fi
fi

echo ""
echo -e "${RED}═══════════════════════════════════════════════════${NC}"
echo -e "${RED}INICIANDO DESINSTALACIÓN...${NC}"
echo -e "${RED}═══════════════════════════════════════════════════${NC}"
echo ""

# Cambiar al directorio del proyecto
cd "$INSTALL_DIR" 2>/dev/null || true

# Paso 1: Detener y eliminar contenedores
echo -e "${YELLOW}[1/7] Deteniendo contenedores Docker...${NC}"
if [ -f docker-compose.yml.template.yml ]; then
    docker compose down -v 2>/dev/null || true
    echo -e "${GREEN}✓ Contenedores detenidos${NC}"
else
    echo -e "${YELLOW}⚠ docker-compose.yml no encontrado${NC}"
fi

# Paso 2: Eliminar imágenes Docker relacionadas
echo ""
echo -e "${YELLOW}[2/7] ¿Eliminar también las imágenes Docker? (liberará más espacio)${NC}"
read -p "(s/n): " remove_images
if [[ $remove_images =~ ^[Ss]$ ]]; then
    docker rmi nginx:alpine wordpress:php8.2-fpm-alpine mysql:8.0 phpmyadmin:latest certbot/certbot:latest delfer/alpine-ftp-server 2>/dev/null || true
    echo -e "${GREEN}✓ Imágenes eliminadas${NC}"
else
    echo -e "${YELLOW}⊗ Imágenes conservadas${NC}"
fi

# Paso 3: Eliminar configuración de cron
echo ""
echo -e "${YELLOW}[3/7] Eliminando tareas de cron...${NC}"
crontab -l 2>/dev/null | grep -v "backup.sh" | crontab - 2>/dev/null || true
echo -e "${GREEN}✓ Tareas de cron eliminadas${NC}"

# Paso 4: Eliminar reglas del firewall
echo ""
echo -e "${YELLOW}[4/7] ¿Eliminar reglas del firewall UFW?${NC}"
read -p "(s/n): " remove_firewall
if [[ $remove_firewall =~ ^[Ss]$ ]]; then
    ufw delete allow 80/tcp 2>/dev/null || true
    ufw delete allow 443/tcp 2>/dev/null || true
    ufw delete allow 21/tcp 2>/dev/null || true
    ufw delete allow 21000:21010/tcp 2>/dev/null || true
    echo -e "${GREEN}✓ Reglas de firewall eliminadas${NC}"
else
    echo -e "${YELLOW}⊗ Reglas de firewall conservadas${NC}"
fi

# Paso 5: Crear backup final (opcional)
echo ""
echo -e "${YELLOW}[5/7] ¿Crear un backup final antes de eliminar? (recomendado)${NC}"
read -p "(s/n): " create_backup
if [[ $create_backup =~ ^[Ss]$ ]]; then
    FINAL_BACKUP="/root/wordpress-multisite-final-backup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$FINAL_BACKUP"
    cp -r "$INSTALL_DIR" "$FINAL_BACKUP/" 2>/dev/null || true
    echo -e "${GREEN}✓ Backup guardado en: $FINAL_BACKUP${NC}"
else
    echo -e "${YELLOW}⊗ Sin backup final${NC}"
fi

# Paso 6: Eliminar directorio del proyecto
echo ""
echo -e "${YELLOW}[6/7] Eliminando directorio del proyecto...${NC}"
cd /tmp
rm -rf "$INSTALL_DIR"
echo -e "${GREEN}✓ Directorio eliminado${NC}"

# Paso 7: Eliminar logs
echo ""
echo -e "${YELLOW}[7/7] Eliminando logs...${NC}"
rm -f /var/log/wordpress-multisite-install.log
echo -e "${GREEN}✓ Logs eliminados${NC}"

# Resumen final
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}DESINSTALACIÓN COMPLETADA${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""

echo "Elementos eliminados:"
echo "  ✓ Contenedores Docker"
echo "  ✓ Bases de datos"
echo "  ✓ Sitios WordPress"
echo "  ✓ Configuraciones"
echo "  ✓ Directorio del proyecto"
echo "  ✓ Logs del sistema"

if [[ $create_backup =~ ^[Ss]$ ]]; then
    echo ""
    echo "Backup final guardado en:"
    echo "  $FINAL_BACKUP"
fi

if [[ ! $remove_images =~ ^[Ss]$ ]]; then
    echo ""
    echo -e "${YELLOW}Nota: Las imágenes Docker se conservaron${NC}"
    echo "Para eliminarlas manualmente:"
    echo "  docker images"
    echo "  docker rmi <imagen_id>"
fi

echo ""
echo -e "${GREEN}El sistema ha sido desinstalado completamente.${NC}"
echo ""
