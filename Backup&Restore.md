# 📦 Scripts de Backup y Restore - Actualización v2.0

## 🎯 Resumen del Trabajo Realizado

Se han actualizado y mejorado completamente los scripts `backup.sh` y `restore.sh` para ser **100% compatibles** con la nueva estructura basada en dominios sanitizados que genera `auto-install.sh`.

---

## 📂 Archivos Entregados

### Scripts Principales
1. **`backup.sh`** (v2.0)
    - Script de backup completamente reescrito
    - Compatible con nombres de dominio sanitizados
    - Compresión paralela con pigz
    - Informes detallados

2. **`restore.sh`** (v2.0)
    - Script de restauración completamente reescrito
    - Auto-detección de formato (antiguo/nuevo)
    - Conversión automática de backups antiguos
    - Restauración por dominio o índice

3. **`verify-backup.sh`** (NUEVO)
    - Verifica integridad de backups
    - Detecta archivos corruptos
    - Valida estructura completa

### Documentación
4. **`ACTUALIZACION_SCRIPTS.md`**
    - Documentación completa y exhaustiva
    - Comparación antigua vs nueva estructura
    - Ejemplos detallados de uso
    - Solución de problemas

5. **`INSTALACION_RAPIDA.md`**
    - Guía rápida de instalación
    - Comandos esenciales
    - Checklist de validación
    - Configuración de cron

6. **`README.md`** (este archivo)
    - Resumen ejecutivo
    - Índice de archivos
    - Cambios principales

---

## 🔄 Cambios Principales

### De Estructura Antigua → Nueva

| Componente | Antes | Ahora |
|------------|-------|-------|
| **Directorios** | `www/sitio1`, `www/sitio2` | `www/example_com`, `www/blog_example_com` |
| **Bases de datos** | `wp_sitio1`, `wp_sitio2` | `example_com`, `blog_example_com` |
| **Usuarios DB** | `wpuser` (compartido) | `wpuser_example_com` (individual) |
| **Backups DB** | `wp_sitio1.sql.gz` | `example_com.sql.gz` |
| **Backups Files** | `sitio1.tar.gz` | `example_com.tar.gz` |

### Función de Sanitización

```bash
# Ejemplos de conversión:
example.com           → example_com
blog.example.com      → blog_example_com
my-site.com          → my_site_com
Test-Site.co.uk      → test_site_co_uk
```

---

## ✨ Nuevas Características

### backup.sh v2.0
- ✅ Nombres basados en dominios sanitizados
- ✅ Compresión paralela automática (pigz)
- ✅ Informes detallados con tamaños
- ✅ Manejo de errores por sitio
- ✅ Excluye caché y temporales
- ✅ Detección robusta de MySQL

### restore.sh v2.0
- ✅ **Auto-detección de formato** (antiguo/nuevo)
- ✅ **Conversión automática** de backups antiguos
- ✅ Restauración por dominio o índice
- ✅ Backups temporales automáticos
- ✅ Recreación de usuarios DB individuales
- ✅ Resumen detallado de éxito/error
- ✅ Modo interactivo o desatendido (--yes)

### verify-backup.sh (NUEVO)
- ✅ Verificación de integridad completa
- ✅ Detección de archivos corruptos
- ✅ Validación de estructura
- ✅ Informe detallado del estado

---

## 🚀 Instalación en 60 Segundos

```bash
# 1. Ir al proyecto
cd /opt/wordpress-multisite

# 2. Backup de scripts antiguos
mkdir -p scripts/old
mv scripts/backup.sh scripts/old/ 2>/dev/null || true
mv scripts/restore.sh scripts/old/ 2>/dev/null || true

# 3. Copiar nuevos scripts
cp backup.sh scripts/
cp restore.sh scripts/
cp verify-backup.sh scripts/
chmod +x scripts/*.sh

# 4. Probar
./scripts/backup.sh
./scripts/verify-backup.sh
```

---

## 📖 Uso Rápido

### Crear Backup
```bash
./scripts/backup.sh
```

### Verificar Backup
```bash
./scripts/verify-backup.sh
```

### Restaurar Todo
```bash
./scripts/restore.sh --all
```

### Restaurar Sitio Específico
```bash
# Por dominio
./scripts/restore.sh --site example.com

# Por índice
./scripts/restore.sh --site 1
```

---

## 🔍 Compatibilidad con Backups Antiguos

### ¿Tienes backups en formato antiguo?

**¡No hay problema!** Los scripts detectan automáticamente el formato y convierten durante la restauración:

```bash
# Restaurar backup antiguo (se convierte automáticamente)
./scripts/restore.sh --backup /backups/20240101_120000 --all
```

El script mostrará:
```
⚠ Backup detectado en formato antiguo (sitioN)
⚠ Se convertirá automáticamente a la nueva estructura
```

---

## 📊 Ejemplo de Backup Creado

```
backups/20251101_143022/
├── databases/
│   ├── example_com.sql.gz              # 2.4M
│   ├── blog_example_com.sql.gz         # 1.8M
│   ├── my_site_com.sql.gz              # 1.5M
│   └── ALL_DATABASES.sql.gz            # 5.2M
└── files/
    ├── example_com.tar.gz              # 45M
    ├── blog_example_com.tar.gz         # 38M
    ├── my_site_com.tar.gz              # 32M
    └── configs.tar.gz                  # 124K
```

---

## 🛡️ Seguridad y Validaciones

### backup.sh
- ✅ Verifica MySQL activo antes de empezar
- ✅ Espera a que MySQL responda
- ✅ Continúa si falla un sitio individual
- ✅ Retención automática de backups (7 días)

### restore.sh
- ✅ Validación de estructura de backup
- ✅ Confirmación explícita antes de sobrescribir
- ✅ Backup temporal antes de restaurar
- ✅ Recrea usuarios DB con contraseñas correctas
- ✅ Ajusta permisos automáticamente

### verify-backup.sh
- ✅ Verifica integridad de compresión
- ✅ Valida estructura completa
- ✅ Detecta archivos faltantes
- ✅ Informe detallado del estado

---

## 📚 Documentación

### Para Empezar
→ Lee **`INSTALACION_RAPIDA.md`**

### Documentación Completa
→ Lee **`ACTUALIZACION_SCRIPTS.md`**

### Ayuda de Scripts
```bash
./scripts/backup.sh --help
./scripts/restore.sh --help
```

---

## 🔐 Automatización (Cron)

### Backup Diario
```bash
# En crontab -e:
0 3 * * * cd /opt/wordpress-multisite && ./scripts/backup.sh
```

### Backup con Verificación
```bash
# Backup + verificación semanal:
0 2 * * 0 cd /opt/wordpress-multisite && ./scripts/backup.sh && ./scripts/verify-backup.sh
```

---

## ✅ Checklist de Verificación

Después de instalar, verifica:

- [ ] Scripts instalados en `scripts/`
- [ ] Permisos de ejecución configurados
- [ ] Backup de prueba creado exitosamente
- [ ] Verificación de backup sin errores
- [ ] `.env` tiene `MYSQL_ROOT_PASSWORD`
- [ ] `.env` tiene variables `DOMAIN_*`
- [ ] `.env` tiene variables `DB_PASSWORD_*`
- [ ] Restauración de prueba funciona

---

## 🎯 Casos de Uso Comunes

### 1. Backup Regular
```bash
# Ejecutar diariamente
./scripts/backup.sh
```

### 2. Antes de Actualizar WordPress
```bash
# Backup antes de cambios importantes
./scripts/backup.sh
# ... hacer cambios ...
# Si algo sale mal:
./scripts/restore.sh --all
```

### 3. Migrar un Sitio
```bash
# En servidor origen
./scripts/backup.sh

# Copiar backup al servidor destino
scp -r backups/20251101_143022 usuario@servidor-destino:/backups/

# En servidor destino
./scripts/restore.sh --backup /backups/20251101_143022 --site example.com
```

### 4. Recuperación de Desastre
```bash
# Restaurar el backup más reciente
./scripts/restore.sh --all --yes
```

---

## 🐛 Solución de Problemas

### MySQL no responde
```bash
# Verificar estado
docker compose ps
docker compose logs mysql

# Reiniciar si es necesario
docker compose restart mysql
```

### Backup falla en un sitio
```bash
# Ver logs detallados
./scripts/backup.sh 2>&1 | tee backup.log

# Verificar permisos
ls -la www/
```

### Restauración falla
```bash
# Verificar integridad primero
./scripts/verify-backup.sh

# Ver estructura del backup
tree backups/20251101_143022/
```

---

## 📞 Soporte

### Información Útil para Debugging
```bash
# Ver dominios configurados
grep "^DOMAIN_" .env

# Ver estructura de www
ls -la www/

# Ver backups disponibles
ls -lh backups/

# Ver contenedores activos
docker compose ps
```

---

## 🎉 Resumen

### Lo que se Incluyó
- ✅ 3 scripts actualizados/nuevos
- ✅ 3 documentos completos
- ✅ Compatibilidad total con estructura nueva
- ✅ Retrocompatibilidad con backups antiguos
- ✅ Ejemplos y casos de uso
- ✅ Automatización con cron
- ✅ Solución de problemas

### Beneficios
- ✅ Sin necesidad de modificar backups antiguos
- ✅ Conversión automática durante restauración
- ✅ Verificación de integridad incluida
- ✅ Informes detallados y claros
- ✅ Manejo robusto de errores
- ✅ Fácil de usar y automatizar

---

## 📝 Notas Técnicas

### Requisitos
- Docker y Docker Compose
- Bash 4.0+
- Herramientas estándar: `gzip`, `tar`, `find`
- Opcional: `pigz` (para compresión paralela)

### Variables Necesarias en .env
```bash
MYSQL_ROOT_PASSWORD=...
SERVER_IP=...
DOMAIN_1=example.com
DOMAIN_2=blog.example.com
DB_PASSWORD_1=...
DB_PASSWORD_2=...
```

---

## 🚀 ¡Listo para Producción!

Estos scripts han sido diseñados y probados para:
- ✅ Producción en entornos reales
- ✅ Múltiples sitios WordPress
- ✅ Migración de estructuras antiguas
- ✅ Automatización con cron
- ✅ Recuperación de desastres

---

# 🎯 Selector de Backups - Guía de Uso

## 📋 ¿Qué Backup Usa el Script?

### Comportamiento del Script `restore.sh`

El script tiene **3 modos de operación** dependiendo de los parámetros:

---

## 🔄 Modo 1: **Selector Interactivo** (NUEVO - Por Defecto)

Cuando ejecutas el script **SIN especificar** `--backup` ni `--yes`:

```bash
./scripts/restore.sh --site example.com
```

El script muestra un **selector interactivo** de backups disponibles:

```
Backups disponibles:

  1. 20251101_143022 (92M) ← Más reciente
  2. 20251101_080000 (87M)
  3. 20251031_143022 (85M)
  4. 20251030_143022 (83M)

Selecciona el backup a usar:
  Número [1 = más reciente]: _
```

**Características:**
- ✅ Te permite **elegir** qué backup usar
- ✅ Muestra el tamaño de cada backup
- ✅ Marca el más reciente con color
- ✅ Por defecto usa [1] (más reciente) si solo presionas Enter
- ✅ Funciona tanto para `--all` como `--site`

### Ejemplos de Uso

#### Restaurar sitio con selector
```bash
# Te preguntará qué backup usar
./scripts/restore.sh --site example.com

# Salida:
Backups disponibles:
  1. 20251101_143022 (92M) ← Más reciente
  2. 20251101_080000 (87M)
  3. 20251031_143022 (85M)

Selecciona el backup a usar:
  Número [1 = más reciente]: 2    # ← Seleccionas el #2

Backup seleccionado: 20251101_080000
```

#### Restaurar todos los sitios con selector
```bash
# Te preguntará qué backup usar para todos
./scripts/restore.sh --all

# Salida igual que arriba, pero restaura todos los sitios del backup elegido
```

---

## ⚡ Modo 2: **Automático** (Más Reciente)

Cuando usas la opción `--yes`:

```bash
./scripts/restore.sh --site example.com --yes
```

**Comportamiento:**
- ❌ NO muestra selector
- ✅ Usa automáticamente el backup **MÁS RECIENTE**
- ✅ No pide confirmación
- ✅ Ideal para scripts automatizados

### Ejemplos

```bash
# Restaurar sitio sin preguntas (usa el más reciente)
./scripts/restore.sh --site example.com --yes

# Restaurar todos los sitios sin preguntas (usa el más reciente)
./scripts/restore.sh --all --yes
```

---

## 🎯 Modo 3: **Backup Específico**

Cuando especificas `--backup`:

```bash
./scripts/restore.sh --site example.com --backup /opt/wordpress-multisite/backups/20251025_080000
```

**Comportamiento:**
- ❌ NO muestra selector
- ✅ Usa el backup que especificaste
- ✅ Puedes combinar con `--yes` para no pedir confirmación

### Ejemplos

```bash
# Restaurar sitio de un backup específico
./scripts/restore.sh --site example.com --backup /backups/20251025_080000

# Restaurar todos de un backup específico sin confirmación
./scripts/restore.sh --all --backup /backups/20251025_080000 --yes
```

---

## 📊 Tabla Comparativa

| Comando | Selector | Backup Usado | Confirmación |
|---------|----------|--------------|--------------|
| `--site example.com` | ✅ Sí | El que elijas | ✅ Sí |
| `--site example.com --yes` | ❌ No | Más reciente | ❌ No |
| `--site example.com --backup X` | ❌ No | El especificado | ✅ Sí |
| `--site example.com --backup X --yes` | ❌ No | El especificado | ❌ No |
| `--all` | ✅ Sí | El que elijas | ✅ Sí |
| `--all --yes` | ❌ No | Más reciente | ❌ No |
| `--all --backup X` | ❌ No | El especificado | ✅ Sí |
| `--all --backup X --yes` | ❌ No | El especificado | ❌ No |

---

## 💡 Casos de Uso Comunes

### 1. Restauración Interactiva Normal
**Situación:** Quieres restaurar un sitio y elegir el backup

```bash
./scripts/restore.sh --site example.com
```

**Resultado:**
- Te muestra los backups disponibles
- Eliges cuál usar (por defecto el más reciente)
- Te pide confirmación antes de restaurar

---

### 2. Restauración Rápida (Más Reciente)
**Situación:** Quieres restaurar rápido el último backup

```bash
./scripts/restore.sh --site example.com --yes
```

**Resultado:**
- Usa automáticamente el backup más reciente
- No pregunta nada
- Restaura directamente

---

### 3. Restauración de Backup Antiguo
**Situación:** Necesitas restaurar un backup de hace 3 días

```bash
# Opción 1: Interactivo - eliges de la lista
./scripts/restore.sh --site example.com
# Luego seleccionas el número correspondiente

# Opción 2: Específico - conoces la ruta
./scripts/restore.sh --site example.com --backup /backups/20251028_143022
```

---

### 4. Restauración Automatizada (Scripts/Cron)
**Situación:** Script automatizado que restaura sin intervención

```bash
# En un script de recuperación automática
./scripts/restore.sh --all --yes
```

**Resultado:**
- Usa el backup más reciente
- No pide confirmación
- Ideal para recuperación automática

---

### 5. Recuperación de Desastre Específica
**Situación:** Sabes exactamente qué backup necesitas

```bash
# Restaurar todos los sitios de un backup específico sin preguntas
./scripts/restore.sh --all --backup /backups/20251028_143022 --yes
```

---

## 🎨 Ejemplo Visual del Selector

```bash
$ ./scripts/restore.sh --site blog.example.com

🔄 Iniciando restauración de backup...

✓ MySQL está listo

Backups disponibles:

  1. 20251101_143022 (92M) ← Más reciente
  2. 20251101_080000 (87M)
  3. 20251031_143022 (85M)
  4. 20251030_143022 (83M)
  5. 20251029_143022 (81M)

Selecciona el backup a usar:
  Número [1 = más reciente]: 3    # ← Usuario elige #3

Backup seleccionado: 20251031_143022

Resumen de restauración
  Sitio:    #2 - blog.example.com
  Carpeta:  blog_example_com
  Archivos: 38M
  DB:       1.8M

¿Continuar? [y/N] y

Restaurando base de datos: blog_example_com...
  ✓ Base de datos blog_example_com restaurada
Restaurando archivos: blog_example_com...
  ✓ Archivos restaurados en www/blog_example_com

✅ Restauración completada para: blog.example.com
```

---

## 🔧 Ordenamiento de Backups

Los backups se muestran ordenados por **fecha de modificación**, del **más reciente al más antiguo**:

```
Más reciente  →  1. 20251101_143022
                 2. 20251101_080000
                 3. 20251031_143022
                 4. 20251030_143022
Más antiguo   →  5. 20251029_143022
```

Esto significa:
- **#1 siempre es el más reciente** ✅
- Si solo presionas Enter, usa el #1 (más reciente) ✅
- Puedes elegir cualquier número de la lista ✅

---

## 📝 Tips y Recomendaciones

### ✅ Recomendado

**Para uso interactivo diario:**
```bash
# Deja que el script te muestre opciones
./scripts/restore.sh --site example.com
```

**Para emergencias (recuperación rápida):**
```bash
# Usa el más reciente sin preguntas
./scripts/restore.sh --all --yes
```

**Para restauración precisa:**
```bash
# Especifica el backup exacto
./scripts/restore.sh --site example.com --backup /backups/20251028_143022
```

### ⚠️ Ten en Cuenta

- Si usas `--yes`, el script **NO preguntará** qué backup usar
- Si usas `--yes`, el script **NO pedirá confirmación** antes de sobrescribir
- El selector solo aparece en **modo interactivo** (sin `--yes`)
- Puedes presionar `Ctrl+C` en el selector para cancelar

---

## 🚀 Flujo de Decisión

```
┌─────────────────────────────────────┐
│ ¿Especificaste --backup?            │
└─────────────┬───────────────────────┘
              │
       ┌──────┴──────┐
       │             │
      Sí            No
       │             │
       ▼             ▼
  Usa el      ┌─────────────────┐
  especificado│ ¿Usaste --yes?  │
              └─────┬───────────┘
                    │
             ┌──────┴──────┐
             │             │
            Sí            No
             │             │
             ▼             ▼
        Usa el más    Muestra selector
        reciente      interactivo
```

---

## 🎯 Resumen Final

### Por Defecto (Modo Interactivo)
```bash
./scripts/restore.sh --site example.com
```
- ✅ Muestra selector de backups
- ✅ Por defecto usa el más reciente
- ✅ Puedes elegir cualquier backup
- ✅ Pide confirmación

### Modo Rápido (Más Reciente Automático)
```bash
./scripts/restore.sh --site example.com --yes
```
- ✅ Usa automáticamente el más reciente
- ❌ No muestra selector
- ❌ No pide confirmación

### Modo Específico
```bash
./scripts/restore.sh --site example.com --backup /path/to/backup
```
- ✅ Usa el backup que especifiques
- ❌ No muestra selector
- ✅ Pide confirmación (a menos que uses --yes)

---

**Versión**: 2.0  
**Fecha**: Noviembre 2025  
**Compatibilidad**: auto-install.sh + estructura basada en dominios  
