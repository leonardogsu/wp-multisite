#!/bin/bash

################################################################################
# Script de Verificación Pre-Instalación
# Verifica que el sistema cumple con los requisitos antes de instalar
################################################################################

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

errors=0
warnings=0

echo -e "${BLUE}"
cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║          Verificación de Requisitos del Sistema              ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"
echo ""

# Verificar que se ejecuta como root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}✗ Este script debe ejecutarse como root (usa sudo)${NC}"
   exit 1
else
    echo -e "${GREEN}✓ Ejecutándose como root${NC}"
fi

# Verificar Ubuntu 24.04
echo -n "Verificando versión de Ubuntu... "
if grep -q "24.04" /etc/os-release; then
    echo -e "${GREEN}✓ Ubuntu 24.04 LTS${NC}"
else
    echo -e "${YELLOW}⚠ No es Ubuntu 24.04 LTS${NC}"
    warnings=$((warnings + 1))
    grep "PRETTY_NAME" /etc/os-release
fi

# Verificar arquitectura
echo -n "Verificando arquitectura... "
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "aarch64" ]; then
    echo -e "${GREEN}✓ $ARCH${NC}"
else
    echo -e "${RED}✗ Arquitectura no soportada: $ARCH${NC}"
    errors=$((errors + 1))
fi

# Verificar RAM
echo -n "Verificando memoria RAM... "
ram_mb=$(free -m | awk 'NR==2{print $2}')
ram_gb=$((ram_mb / 1024))
if [ $ram_mb -ge 8000 ]; then
    echo -e "${GREEN}✓ ${ram_gb}GB (${ram_mb}MB)${NC}"
elif [ $ram_mb -ge 4000 ]; then
    echo -e "${YELLOW}⚠ ${ram_gb}GB (${ram_mb}MB) - Mínimo cumplido pero se recomienda 8GB${NC}"
    warnings=$((warnings + 1))
else
    echo -e "${RED}✗ Solo ${ram_gb}GB (${ram_mb}MB) - Insuficiente (mínimo 4GB)${NC}"
    errors=$((errors + 1))
fi

# Verificar espacio en disco
echo -n "Verificando espacio en disco... "
disk_avail_gb=$(df / | awk 'NR==2{print int($4/1024/1024)}')
if [ $disk_avail_gb -ge 20 ]; then
    echo -e "${GREEN}✓ ${disk_avail_gb}GB disponibles${NC}"
elif [ $disk_avail_gb -ge 10 ]; then
    echo -e "${YELLOW}⚠ ${disk_avail_gb}GB disponibles - Se recomienda al menos 20GB${NC}"
    warnings=$((warnings + 1))
else
    echo -e "${RED}✗ Solo ${disk_avail_gb}GB disponibles - Insuficiente (mínimo 20GB)${NC}"
    errors=$((errors + 1))
fi

# Verificar conexión a internet
echo -n "Verificando conexión a internet... "
if ping -c 1 8.8.8.8 &> /dev/null; then
    echo -e "${GREEN}✓ Conectado${NC}"
else
    echo -e "${RED}✗ Sin conexión a internet${NC}"
    errors=$((errors + 1))
fi

# Verificar resolución DNS
echo -n "Verificando resolución DNS... "
if host google.com &> /dev/null; then
    echo -e "${GREEN}✓ DNS funcional${NC}"
else
    echo -e "${RED}✗ DNS no funciona correctamente${NC}"
    errors=$((errors + 1))
fi

# Verificar puertos disponibles
echo -n "Verificando puertos (80, 443, 21)... "
ports_in_use=""
for port in 80 443 21; do
    if ss -tuln 2>/dev/null | grep -q ":$port " || netstat -tuln 2>/dev/null | grep -q ":$port "; then
        ports_in_use="$ports_in_use $port"
    fi
done

if [ -z "$ports_in_use" ]; then
    echo -e "${GREEN}✓ Todos disponibles${NC}"
else
    echo -e "${YELLOW}⚠ Puertos en uso:$ports_in_use${NC}"
    echo "  Esto puede causar conflictos. Considera detener servicios que usen estos puertos."
    warnings=$((warnings + 1))
fi

# Verificar si Docker ya está instalado
echo -n "Verificando Docker... "
if command -v docker &> /dev/null; then
    echo -e "${YELLOW}⚠ Docker ya está instalado: $(docker --version)${NC}"
    warnings=$((warnings + 1))
else
    echo -e "${GREEN}✓ Docker no instalado (se instalará)${NC}"
fi

# Verificar espacio de swap
echo -n "Verificando swap... "
swap_mb=$(free -m | awk 'NR==3{print $2}')
if [ $swap_mb -ge 2000 ]; then
    echo -e "${GREEN}✓ ${swap_mb}MB de swap${NC}"
elif [ $swap_mb -eq 0 ]; then
    echo -e "${YELLOW}⚠ Sin swap configurado${NC}"
    warnings=$((warnings + 1))
else
    echo -e "${YELLOW}⚠ Solo ${swap_mb}MB de swap${NC}"
    warnings=$((warnings + 1))
fi

# Verificar CPU
echo -n "Verificando CPU... "
cpu_cores=$(nproc)
if [ $cpu_cores -ge 2 ]; then
    echo -e "${GREEN}✓ $cpu_cores cores${NC}"
else
    echo -e "${YELLOW}⚠ Solo $cpu_cores core - Se recomiendan al menos 2${NC}"
    warnings=$((warnings + 1))
fi

# Verificar systemd
echo -n "Verificando systemd... "
if command -v systemctl &> /dev/null; then
    echo -e "${GREEN}✓ systemd disponible${NC}"
else
    echo -e "${RED}✗ systemd no disponible${NC}"
    errors=$((errors + 1))
fi

# Verificar kernel
echo -n "Verificando versión del kernel... "
kernel_version=$(uname -r)
echo -e "${GREEN}✓ $kernel_version${NC}"

# Resumen
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo -e "${BLUE}RESUMEN DE LA VERIFICACIÓN${NC}"
echo "═══════════════════════════════════════════════════════════════"
echo ""

if [ $errors -eq 0 ] && [ $warnings -eq 0 ]; then
    echo -e "${GREEN}✓ ¡Perfecto! El sistema cumple con todos los requisitos.${NC}"
    echo ""
    echo "Puedes proceder con la instalación ejecutando:"
    echo -e "  ${BLUE}sudo ./auto-install.sh${NC}"
    echo ""
    exit 0
elif [ $errors -eq 0 ]; then
    echo -e "${YELLOW}⚠ $warnings advertencia(s) encontrada(s)${NC}"
    echo ""
    echo "El sistema cumple con los requisitos mínimos, pero hay algunas advertencias."
    echo "Puedes continuar con la instalación, pero considera resolver las advertencias."
    echo ""
    echo "Para continuar con la instalación:"
    echo -e "  ${BLUE}sudo ./auto-install.sh${NC}"
    echo ""
    exit 0
else
    echo -e "${RED}✗ $errors error(es) crítico(s) encontrado(s)${NC}"
    if [ $warnings -gt 0 ]; then
        echo -e "${YELLOW}⚠ $warnings advertencia(s) encontrada(s)${NC}"
    fi
    echo ""
    echo "Debes resolver los errores antes de continuar con la instalación."
    echo ""
    exit 1
fi
