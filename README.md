# WordPress Multi-Site - Documentación Técnica

## 🎯 Descripción General

Sistema automatizado para desplegar múltiples sitios WordPress independientes en un único servidor Ubuntu 24.04, utilizando arquitectura containerizada con Docker.

**Soporte completo para dominios y subdominios** (ej: `ejemplo.com`, `blog.ejemplo.com`, `dev.proyecto.net`, `www.sitio.com.mx`)

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
│   ├── ejemplo_com/              # ejemplo.com → ejemplo_com
│   │   ├── wp-admin/
│   │   ├── wp-content/
│   │   ├── wp-includes/
│   │   └── wp-config.php
│   ├── blog_ejemplo_com/         # blog.ejemplo.com → blog_ejemplo_com
│   ├── dev_proyecto_net/         # dev.proyecto.net → dev_proyecto_net
│   └── www_sitio_com_mx/         # www.sitio.com.mx → www_sitio_com_mx
│
├── nginx/                        # Configuración Nginx
│   ├── nginx.conf                # Configuración global
│   ├── conf.d/                   # Virtual hosts
│   │   ├── ejemplo.com.conf      # ejemplo.com
│   │   ├── blog.ejemplo.com.conf # blog.ejemplo.com
│   │   ├── dev.proyecto.net.conf # dev.proyecto.net
│   │   └── www.sitio.com.mx.conf # www.sitio.com.mx
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
    │   │   ├── ejemplo_com.sql
    │   │   ├── blog_ejemplo_com.sql
    │   │   ├── dev_proyecto_net.sql
    │   │   └── www_sitio_com_mx.sql
    │   └── files/
    │       ├── ejemplo_com.tar.gz
    │       ├── blog_ejemplo_com.tar.gz
    │       ├── dev_proyecto_net.tar.gz
    │       └── www_sitio_com_mx.tar.gz
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
- `mysql/init/01-init-databases.sql`: Crea bases de datos por dominio (sanitizados)

**Usuarios:**
- `root` / `${MYSQL_ROOT_PASSWORD}`: Administración total
- `wpuser_{dominio_sanitizado}` / `${DB_PASSWORD_N}`: Usuario por sitio con contraseña independiente

**Bases de Datos:**
```
ejemplo_com        → WordPress para ejemplo.com
blog_ejemplo_com   → WordPress para blog.ejemplo.com
dev_proyecto_net   → WordPress para dev.proyecto.net
www_sitio_com_mx   → WordPress para www.sitio.com.mx
```

**Nomenclatura:**
- Puntos (`.`) → guiones bajos (`_`)
- Guiones (`-`) → guiones bajos (`_`)
- Todo en minúsculas

### WordPress
**Archivos por sitio:**
- `www/{dominio_sanitizado}/wp-config.php`: Configuración generada desde plantilla
    - DB_NAME: `{dominio_sanitizado}` (ej: `blog_ejemplo_com`)
    - DB_USER: `wpuser_{dominio_sanitizado}` (ej: `wpuser_blog_ejemplo_com`)
    - DB_PASSWORD: `${DB_PASSWORD_N}` (contraseña única por sitio)
    - DB_HOST: `mysql` (hostname del contenedor)
    - Salts únicos por sitio (API WordPress)
    - Credenciales SFTP independientes por sitio

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
- Usuarios: `sftp_{dominio_sanitizado}` (ej: `sftp_blog_ejemplo_com`)
- Directorio enjaulado: `/{dominio_sanitizado}` (cada usuario solo ve su sitio)
- UID/GID: `33:33` (www-data)
- Contraseñas independientes por sitio: `${SFTP_{DOMINIO_SANITIZADO}_PASSWORD}`

**Montajes:**
```
./www/ejemplo_com       → /home/sftp_ejemplo_com/ejemplo_com
./www/blog_ejemplo_com  → /home/sftp_blog_ejemplo_com/blog_ejemplo_com
./www/dev_proyecto_net  → /home/sftp_dev_proyecto_net/dev_proyecto_net
```

**Conexión:**
```bash
# Ejemplo para blog.ejemplo.com
sftp -P 2222 sftp_blog_ejemplo_com@SERVER_IP
```

---

## 🔐 Variables de Entorno (.env)

```bash
# Servidor
SERVER_IP=X.X.X.X

# Dominios (mínimo 1, soporta subdominios)
DOMAIN_1=ejemplo.com
DOMAIN_2=blog.ejemplo.com
DOMAIN_3=dev.proyecto.net
DOMAIN_4=www.sitio.com.mx

# MySQL
MYSQL_ROOT_PASSWORD=xxxxx

# Contraseñas de base de datos por sitio
DB_PASSWORD_1=xxxxx  # Para ejemplo.com
DB_PASSWORD_2=xxxxx  # Para blog.ejemplo.com
DB_PASSWORD_3=xxxxx  # Para dev.proyecto.net
DB_PASSWORD_4=xxxxx  # Para www.sitio.com.mx

# phpMyAdmin
PHPMYADMIN_AUTH_USER=phpmyadmin
PHPMYADMIN_AUTH_PASSWORD=xxxxx
PMA_ABSOLUTE_URI=http://ejemplo.com/phpmyadmin/

# SFTP (usuarios independientes por dominio)
SFTP_EJEMPLO_COM_PASSWORD=xxxxx
SFTP_BLOG_EJEMPLO_COM_PASSWORD=xxxxx
SFTP_DEV_PROYECTO_NET_PASSWORD=xxxxx
SFTP_WWW_SITIO_COM_MX_PASSWORD=xxxxx
```

---

## 🔄 Sistema de Plantillas

### Propósito
Separar configuración de código para facilitar mantenimiento y personalización.

### Variables Sustituidas con `envsubst`
- `${DOMAIN}`: Nombre del dominio original (ej: `blog.ejemplo.com`)
- `${DOMAIN_SANITIZED}`: Dominio sanitizado (ej: `blog_ejemplo_com`)
- `${SITE_NUM}`: Número del sitio (1, 2, 3...)
- `${DB_PASSWORD}`: Contraseña MySQL específica del sitio
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

### Sanitización de Nombres de Dominio
Los dominios y subdominios se convierten en identificadores válidos para:
- Nombres de directorios
- Nombres de bases de datos MySQL
- Nombres de usuario MySQL/SFTP
- Variables de entorno

**Reglas de sanitización:**
```
Entrada              → Salida
──────────────────────────────────────
ejemplo.com          → ejemplo_com
blog.ejemplo.com     → blog_ejemplo_com
dev.proyecto.net     → dev_proyecto_net
www.sitio.com.mx     → www_sitio_com_mx
sub-dominio.web.io   → sub_dominio_web_io
```

**Transformaciones aplicadas:**
1. Puntos (`.`) → guiones bajos (`_`)
2. Guiones (`-`) → guiones bajos (`_`)
3. Conversión a minúsculas
4. Eliminación de caracteres especiales

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
1. **Agregar dominio o subdominio**:
    - Añadir `DOMAIN_N` en `.env` (soporta subdominios: `blog.ejemplo.com`)
    - Ejecutar `generate-config.sh` y `setup.sh`
    - El sistema automáticamente sanitiza el nombre
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
2. **Soporte de subdominios**: Sistema valida y acepta cualquier subdominio válido (ej: `dev.proyecto.net`, `blog.ejemplo.com`)
3. **Sanitización automática**: Los dominios se convierten automáticamente a nombres válidos para directorios/BD (`.` y `-` → `_`)
4. **Usuarios SFTP aislados**: Cada sitio tiene usuario independiente con directorio enjaulado y contraseña única
5. **Bases de datos separadas**: Cada sitio usa su propia base de datos con usuario dedicado
6. **SSL manual**: Requiere ejecutar `setup-ssl.sh` después de apuntar DNS (soporta subdominios)
7. **Backup incluye**: Archivos WordPress + dumps MySQL por sitio
8. **Permisos**: UID/GID 33:33 (www-data) en todos los archivos

---

## 🆘 Resolución Rápida

| Problema | Solución |
|----------|----------|
| MySQL no inicia | `docker compose logs mysql` - verificar contraseñas en `.env` |
| NGINX 502 | PHP-FPM caído - `docker compose restart php` |
| WordPress error DB | Verificar `wpuser_{dominio_sanitizado}` existe y tiene permisos |
| SFTP permiso denegado | Verificar contraseña en `.env` - `SFTP_{DOMINIO_SANITIZADO}_PASSWORD` |
| phpMyAdmin acceso | Revisar `.htpasswd` y `PMA_ABSOLUTE_URI` |
| Subdominio no resuelve | Verificar DNS apunta a `$SERVER_IP` y virtual host existe en `nginx/conf.d/` |

---

**Versión**: 2.1 (Refactorizado con plantillas + Soporte completo de subdominios)  
**Compatibilidad**: Ubuntu 24.04 LTS  
**Docker**: 24.x+ con Compose Plugin