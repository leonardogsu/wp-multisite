#!/bin/bash

echo "=========================================="
echo "DIAGNÓSTICO WORDPRESS MULTISITE"
echo "=========================================="
echo ""

echo "1. ESTADO DE CONTENEDORES"
echo "─────────────────────────"
docker compose ps
echo ""

echo "2. ARCHIVO .env"
echo "─────────────────────────"
cat .env
echo ""

echo "3. NGINX - Configuración generada"
echo "─────────────────────────"
echo "=== nginx/nginx.conf ==="
cat nginx/nginx.conf
echo ""
echo "=== Archivos en nginx/conf.d/ ==="
ls -la nginx/conf.d/
echo ""
echo "=== Primer vhost (primero encontrado) ==="
cat nginx/conf.d/*.conf | head -100
echo ""

echo "4. LOGS DE NGINX"
echo "─────────────────────────"
docker compose logs nginx --tail=50
echo ""

echo "5. LOGS DE PHP"
echo "─────────────────────────"
docker compose logs php --tail=50
echo ""

echo "6. LOGS DE PHPMYADMIN"
echo "─────────────────────────"
docker compose logs phpmyadmin --tail=50
echo ""

echo "7. LOGS DE FTP"
echo "─────────────────────────"
docker compose logs ftp --tail=50
echo ""

echo "8. LOGS DE MYSQL"
echo "─────────────────────────"
docker compose logs mysql --tail=30
echo ""

echo "9. TEST DESDE NGINX A PHP"
echo "─────────────────────────"
docker compose exec nginx wget -O- http://php:9000 2>&1 || echo "No se pudo conectar"
echo ""

echo "10. TEST DESDE NGINX A PHPMYADMIN"
echo "─────────────────────────"
docker compose exec nginx wget -O- http://phpmyadmin:80 2>&1 | head -20 || echo "No se pudo conectar"
echo ""

echo "11. VERIFICAR PUERTOS ABIERTOS"
echo "─────────────────────────"
docker compose exec nginx netstat -tuln | grep LISTEN || ss -tuln | grep LISTEN
echo ""

echo "12. CONFIGURACIÓN PHP-FPM"
echo "─────────────────────────"
cat php/www.conf
echo ""

echo "13. VERIFICAR ARCHIVOS .htpasswd"
echo "─────────────────────────"
ls -la nginx/auth/
cat nginx/auth/.htpasswd 2>/dev/null || echo "No existe .htpasswd"
echo ""

echo "14. DOCKER-COMPOSE.YML GENERADO"
echo "─────────────────────────"
cat docker-compose.yml
echo ""

echo "=========================================="
echo "FIN DEL DIAGNÓSTICO"
echo "=========================================="