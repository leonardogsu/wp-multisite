# WordPress Multi-Site - Documentación Técnica

## 🎯 Descripción General

Sistema automatizado para desplegar múltiples sitios WordPress independientes en un único servidor Ubuntu 24.04, utilizando arquitectura containerizada con Docker.

---

## 📋 Script Principal: `auto-install.sh`

### Función
Orquestador completo que automatiza la instalación end-to-end del sistema.

### Flujo de Ejecución
```
1. Verificar requisitos (root, Ubuntu 24.04, RAM, disco)
2. Recopilar información (IP, dominios, backup)
3. Actualizar sistema e instalar dependencias
4. Instalar Docker + Docker Compose
5. Configurar firewall (80, 443, 2222)
6. Crear estructura de directorios
7. Verificar MySQL existente (prevenir conflictos)
8. Generar credenciales (.env, contraseñas)
9. Copiar plantillas y scripts
10. Ejecutar generate-config.sh (configuraciones)
11. Ejecutar setup.sh (WordPress + DB)
12. Configurar backup automático (opcional)
```

### Scripts Invocados
- `generate-config.sh`: Genera todas las configuraciones a partir de plantillas
- `setup.sh`: Descarga WordPress, configura sitios, inicia contenedores

---

## 🏗️ Arquitectura Final

### Contenedores Docker
```
┌─────────────────────────────────────────────┐
│               NGINX (Puerto 80/443)         │
│  - Reverse proxy                            │
│  - Virtual hosts por dominio                │
│  - phpMyAdmin en /phpmyadmin/               │
└──────────────┬──────────────────────────────┘
               │
       ┌───────┴────────┐
       │                │
┌──────▼──────┐  ┌─────▼──────┐
│     PHP     │  │ phpMyAdmin │
│ (FPM 8.2)   │  │            │
└──────┬──────┘  └─────┬──────┘
       │                │
       └────────┬───────┘
                │
        ┌───────▼────────┐
        │     MySQL      │
        │   (Puerto 3306)│
        └────────────────┘

┌────────────────────┐
│   SFTP (Puerto     │
│   2222)            │
│ - Usuarios aislados│
│ - Directorios      │
│   independientes   │
└────────────────────┘

┌────────────────────┐
│   Certbot          │
│ - Renovación SSL   │
│ - Cada 12h         │
└────────────────────┘
```

### Red
- **Red interna**: `wordpress-network` (bridge)
- **Puertos expuestos**: 80 (HTTP), 443 (HTTPS), 2222 (SFTP)

---

## 📁 Estructura de Directorios

```
/opt/wordpress-multisite/
│
├── .env                          # Variables de entorno
├── .credentials                  # Respaldo credenciales
├── docker-compose.yml            # Orquestación contenedores
│
├── scripts/                      # Scripts de gestión
│   ├── generate-config.sh        # Genera configuraciones
│   ├── setup.sh                  # Instala WordPress
│   ├── setup-ssl.sh              # Configura certificados SSL
│   └── backup.sh                 # Backup automático
│
├── templates/                    # Plantillas de configuración
│   ├── docker-compose.yml.template
│   ├── nginx.conf.template
│   ├── vhost-http.conf.template
│   ├── vhost-https.conf.template
│   ├── phpmyadmin-http.conf.template
│   ├── phpmyadmin-https.conf.template
│   ├── wp-config.php.template
│   ├── php.ini.template
│   ├── www.conf.template
│   ├── my.cnf.template
│   └── gitignore.template
│
├── www/                          # Sitios WordPress
│   ├── sitio1/                   # Dominio 1
│   │   ├── wp-admin/
│   │   ├── wp-content/
│   │   ├── wp-includes/
│   │   └── wp-config.php
│   ├── sitio2/                   # Dominio 2
│   └── sitioN/                   # Dominio N
│
├── nginx/                        # Configuración Nginx
│   ├── nginx.conf                # Configuración global
│   ├── conf.d/                   # Virtual hosts
│   │   ├── dominio1.com.conf
│   │   ├── dominio2.com.conf
│   │   └── dominioN.com.conf
│   └── auth/                     # Autenticación HTTP
│       └── .htpasswd             # phpMyAdmin
│
├── php/                          # Configuración PHP
│   ├── php.ini                   # Límites, uploads, etc
│   └── www.conf                  # PHP-FPM pool
│
├── mysql/                        # Configuración MySQL
│   ├── my.cnf                    # Configuración servidor
│   └── init/                     # Scripts inicialización
│       └── 01-init-databases.sql # Crea bases de datos
│
├── certbot/                      # Certificados SSL
│   ├── conf/                     # Let's Encrypt
│   └── www/                      # Challenge ACME
│
├── logs/                         # Logs del sistema
│   ├── nginx/
│   └── backup.log
│
└── backups/                      # Backups automáticos
    ├── YYYYMMDD_HHMMSS/
    │   ├── databases/
    │   │   ├── wp_sitio1.sql
    │   │   └── wp_sitioN.sql
    │   └── files/
    │       ├── sitio1.tar.gz
    │       └── sitioN.tar.gz
    └── latest -> YYYYMMDD_HHMMSS
```

---

## ⚙️ Configuración por Servicio

### NGINX
**Archivos:**
- `nginx/nginx.conf`: Configuración global (workers, buffers)
- `nginx/conf.d/dominio.conf`: Virtual host por dominio

**Características:**
- FastCGI para PHP-FPM
- phpMyAdmin en `/phpmyadmin/` del primer dominio
- Logs separados por dominio
- SSL/TLS configurado (después de `setup-ssl.sh`)

### PHP-FPM
**Archivos:**
- `php/php.ini`: Límites (memory_limit=256M, upload_max_filesize=100M)
- `php/www.conf`: Pool de procesos (pm.max_children=50)

**Montajes:**
- `/var/www/html` → `./www` (código WordPress)

### MySQL
**Archivos:**
- `mysql/my.cnf`: Optimizaciones (innodb_buffer_pool_size, max_connections)
- `mysql/init/01-init-databases.sql`: Crea bases de datos `wp_sitio1`, `wp_sitio2`, ...

**Usuarios:**
- `root` / `${MYSQL_ROOT_PASSWORD}`: Administración total
- `wpuser` / `${DB_PASSWORD}`: Usuario WordPress (permisos en todas las DB)

**Bases de Datos:**
```
wp_sitio1  → WordPress sitio 1
wp_sitio2  → WordPress sitio 2
wp_sitioN  → WordPress sitio N
```

### WordPress
**Archivos por sitio:**
- `www/sitioN/wp-config.php`: Configuración generada desde plantilla
    - DB_NAME: `wp_sitio{N}`
    - DB_USER: `wpuser`
    - DB_HOST: `mysql` (hostname del contenedor)
    - Salts únicos por sitio

### phpMyAdmin
**Acceso:**
- URL: `http://primer-dominio.com/phpmyadmin/`
- Autenticación HTTP: `.htpasswd`
- Usuario MySQL: `root` o `wpuser`

**Variables:**
- `PMA_HOST=mysql`
- `PMA_ABSOLUTE_URI`: URL completa (evita problemas de redirección)

### SFTP
**Configuración:**
- Puerto: `2222`
- Usuarios: `sftp_sitio1`, `sftp_sitio2`, ..., `sftp_sitioN`
- Directorio enjaulado: `/sitioN` (cada usuario solo ve su sitio)
- UID/GID: `33:33` (www-data)

**Montajes:**
```
./www/sitio1 → /home/sftp_sitio1/sitio1
./www/sitio2 → /home/sftp_sitio2/sitio2
./www/sitioN → /home/sftp_sitioN/sitioN
```

**Conexión:**
```bash
sftp -P 2222 sftp_sitio1@SERVER_IP
```

---

## 🔐 Variables de Entorno (.env)

```bash
# Servidor
SERVER_IP=X.X.X.X

# Dominios (mínimo 1)
DOMAIN_1=dominio1.com
DOMAIN_2=dominio2.com
DOMAIN_N=dominioN.com

# MySQL
MYSQL_ROOT_PASSWORD=xxxxx
DB_PASSWORD=xxxxx

# phpMyAdmin
PHPMYADMIN_AUTH_USER=phpmyadmin
PHPMYADMIN_AUTH_PASSWORD=xxxxx
PMA_ABSOLUTE_URI=http://dominio1.com/phpmyadmin/

# SFTP (usuarios independientes)
SFTP_SITIO1_PASSWORD=xxxxx
SFTP_SITIO2_PASSWORD=xxxxx
SFTP_SITIO3_PASSWORD=xxxxx
```

---

## 🔄 Sistema de Plantillas

### Propósito
Separar configuración de código para facilitar mantenimiento y personalización.

### Variables Sustituidas con `envsubst`
- `${DOMAIN}`: Nombre del dominio
- `${SITE_NUM}`: Número del sitio (1, 2, 3...)
- `${DB_PASSWORD}`: Contraseña MySQL
- `${MYSQL_ROOT_PASSWORD}`: Contraseña root MySQL
- `${SERVER_IP}`: IP del servidor
- `${SFTP_VOLUMES}`: Volúmenes SFTP (generados dinámicamente)
- `${SFTP_USERS}`: Usuarios SFTP (generados dinámicamente)
- `${SALT_KEYS}`: Claves de seguridad WordPress (generadas por API)

### Protección de Variables PHP/Nginx
Las variables con `$$` en plantillas se convierten a `$` después de `envsubst`:
```
$$uri → $uri (Nginx)
$$request_uri → $request_uri (Nginx)
```

---

## 🚀 Flujo Completo de Instalación

```
Usuario ejecuta: sudo bash auto-install.sh
    │
    ├─► Verifica requisitos sistema
    ├─► Solicita: IP, dominios, backup
    ├─► Instala Docker + dependencias
    ├─► Crea estructura en /opt/wordpress-multisite/
    ├─► Genera .env con contraseñas
    │
    ├─► Ejecuta: generate-config.sh
    │       ├─► Genera docker-compose.yml
    │       ├─► Genera nginx.conf + vhosts
    │       ├─► Genera php.ini + www.conf
    │       └─► Genera my.cnf + init SQL
    │
    ├─► Ejecuta: setup.sh
    │       ├─► Descarga WordPress (español)
    │       ├─► Crea www/sitio1/, www/sitio2/, ...
    │       ├─► Genera wp-config.php por sitio
    │       ├─► Inicia contenedores Docker
    │       ├─► Espera MySQL (healthcheck)
    │       ├─► Crea usuario wpuser
    │       ├─► Verifica conexiones PHP→MySQL
    │       └─► Muestra resumen con credenciales
    │
    └─► (Opcional) Configura backup cron
```

---

## 🔧 Comandos de Gestión

```bash
# Estado contenedores
docker compose ps

# Ver logs
docker compose logs -f [servicio]

# Reiniciar servicios
docker compose restart [servicio]

# Acceso MySQL
docker compose exec mysql mysql -uroot -p

# Backup manual
./scripts/backup.sh

# Configurar SSL
./scripts/setup-ssl.sh
```

---

## 🎯 Casos de Uso

### Detección de Errores
1. **Conexión MySQL falla**: Verificar `wp-config.php` (DB_PASSWORD, DB_HOST)
2. **phpMyAdmin 404**: Revisar `PMA_ABSOLUTE_URI` en `.env`
3. **SFTP no conecta**: Verificar puerto 2222 en firewall
4. **Permisos WordPress**: Ejecutar `chown -R www-data:www-data www/`

### Mejoras Comunes
1. **Agregar dominio**:
    - Añadir `DOMAIN_N` en `.env`
    - Ejecutar `generate-config.sh` y `setup.sh`
2. **Cambiar versión PHP**: Modificar imagen en `docker-compose.yml.template`
3. **Optimizar MySQL**: Ajustar `my.cnf.template`
4. **Añadir Redis**: Agregar servicio en `docker-compose.yml.template`

### Debugging
- Logs: `logs/nginx/`, `docker compose logs`
- Conexiones DB: Scripts de test en `setup.sh`
- Variables: Revisar `.env` y exportaciones en scripts

---

## 📌 Notas Importantes

1. **WordPress en español**: Descarga desde `https://es.wordpress.org/latest-es_ES.tar.gz`
2. **Usuarios SFTP aislados**: Cada sitio tiene usuario independiente con directorio enjaulado
3. **Bases de datos separadas**: Cada sitio usa `wp_sitioN` (independientes)
4. **SSL manual**: Requiere ejecutar `setup-ssl.sh` después de apuntar DNS
5. **Backup incluye**: Archivos WordPress + dumps MySQL por sitio
6. **Permisos**: UID/GID 33:33 (www-data) en todos los archivos

---

## 🆘 Resolución Rápida

| Problema | Solución |
|----------|----------|
| MySQL no inicia | `docker compose logs mysql` - verificar contraseñas en `.env` |
| NGINX 502 | PHP-FPM caído - `docker compose restart php` |
| WordPress error DB | Verificar `wpuser` existe y tiene permisos |
| SFTP permiso denegado | Verificar contraseña en `.env` - `SFTP_SITIO{N}_PASSWORD` |
| phpMyAdmin acceso | Revisar `.htpasswd` y `PMA_ABSOLUTE_URI` |

---

**Versión**: 2.0 (Refactorizado con plantillas)  
**Compatibilidad**: Ubuntu 24.04 LTS  
**Docker**: 24.x+ con Compose Plugin