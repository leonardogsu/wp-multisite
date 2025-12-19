# GUÍA RÁPIDA: Acceso Seguro a Netdata con Túnel SSH

## 🎯 ¿Qué es esto?

Una forma **súper segura** de ver Netdata en tu navegador, cifrando toda la conexión con SSH.

---

## 📋 REQUISITOS

- ✅ Haber instalado el sistema con Netdata
- ✅ Tener acceso SSH al servidor
- ✅ Conocer la IP del servidor

---

## 🚀 PASOS RÁPIDOS

### **1. Abrir Terminal/PowerShell**

#### En Linux/Mac:
```bash
ssh -L 19999:localhost:19999 ubuntu@146.59.228.174
```

#### En Windows (PowerShell):
```powershell
ssh -L 19999:localhost:19999 root@146.59.228.174
```

**Reemplaza:** `TU_IP_SERVIDOR` con tu IP real, ejemplo:
```bash
ssh -L 19999:localhost:19999 root@146.59.228.174
```

---

### **2. Introducir Contraseña SSH**

Te pedirá tu contraseña SSH (o clave privada):
```
root@146.59.228.174's password: _
```

Introduce tu contraseña y presiona Enter.

---

### **3. Mantener la Conexión Abierta**

Una vez conectado, verás algo como:
```
root@servidor:~#
```

**⚠️ IMPORTANTE: NO CIERRES ESTA VENTANA**

Deja esta terminal abierta en segundo plano mientras uses Netdata.

---

### **4. Abrir tu Navegador**

En tu navegador favorito, ve a:
```
http://localhost:19999
```

**¡Listo!** Verás el dashboard de Netdata del servidor remoto.

---

## 🎨 VISTA PREVIA DEL DASHBOARD

```
┌────────────────────────────────────────────────────────────┐
│ Netdata Real-Time Performance Monitoring                   │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  System Overview                       [Last Updated: 1s]  │
│                                                            │
│  ┌─ CPU ──────────────┐  ┌─ RAM ──────────────┐          │
│  │ ████████░░ 80%      │  │ ██████░░ 6.2/8 GB  │          │
│  └─────────────────────┘  └─────────────────────┘          │
│                                                            │
│  ┌─ Network Traffic ──────────────────────────────────┐   │
│  │  ▲ 2.3 Mbps      ▼ 5.7 Mbps                        │   │
│  └────────────────────────────────────────────────────┘   │
│                                                            │
│  ┌─ Docker Containers ────────────────────────────────┐   │
│  │  nginx   [██░░] 5%   45 MB                         │   │
│  │  mysql   [████] 12%  512 MB                        │   │
│  │  php     [██░░] 8%   128 MB                        │   │
│  └────────────────────────────────────────────────────┘   │
│                                                            │
│  ┌─ Disk I/O ─────────────────────────────────────────┐   │
│  │  Read: 125 MB/s    Write: 43 MB/s                  │   │
│  └────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────┘
```

---

## 💡 CARACTERÍSTICAS DEL DASHBOARD

### 📊 Métricas en Tiempo Real
- Actualización cada **1 segundo**
- Gráficos interactivos (zoom, pan)
- Histórico de hasta 1 hora visible

### 🐳 Docker
- Estado de cada contenedor
- CPU y RAM por contenedor
- Tráfico de red por contenedor

### 🗄️ MySQL
- Queries por segundo
- Conexiones activas
- Uso de caché
- Tablas bloqueadas

### 🌐 Nginx
- Requests/segundo
- Códigos de respuesta (200, 404, 500, etc.)
- Conexiones activas
- Tiempo de respuesta

### 🐘 PHP-FPM
- Procesos activos/idle
- Memoria por proceso
- Requests procesados
- Tiempo de respuesta promedio

---

## 🔐 ¿POR QUÉ ES SEGURO?

```
TU ORDENADOR                      SERVIDOR
     │                               │
     │   SSH Cifrado (Puerto 22)     │
     ├───────────────────────────────┤
     │   Netdata (Puerto 19999)      │
     │   ↑ NO accesible desde fuera  │
     │                               │
     └─ localhost:19999 ────────────┘
        ↑ Sólo tú puedes acceder
```

**Ventajas:**
- ✅ Todo el tráfico está **cifrado** con SSH
- ✅ Netdata **NO está expuesto** a Internet
- ✅ **Solo tú** puedes acceder (con tu clave SSH)
- ✅ **No necesita** configuración SSL adicional
- ✅ **No hay** que abrir puertos extra

---

## 🎮 COMANDOS ÚTILES

### Túnel en Primer Plano (Recomendado)
```bash
ssh -L 19999:localhost:19999 root@123.45.67.89
```
**Uso:** Puedes usar la terminal mientras el túnel está activo.

---

### Túnel en Segundo Plano
```bash
ssh -fN -L 19999:localhost:19999 root@123.45.67.89
```
**Flags:**
- `-f`: Va a segundo plano después de conectar
- `-N`: No ejecuta comandos, solo crea el túnel

**Para cerrar el túnel:**
```bash
# Ver procesos SSH activos
ps aux | grep "ssh.*19999"

# Matar el proceso (reemplaza [PID] con el número del proceso)
kill [PID]
```

---

### Crear Alias para Acceso Rápido (Linux/Mac)

Edita tu `~/.bashrc` o `~/.zshrc`:
```bash
nano ~/.bashrc
```

Añade al final:
```bash
# Alias para Netdata
alias netdata-servidor='ssh -L 19999:localhost:19999 root@123.45.67.89'
```

Guarda y recarga:
```bash
source ~/.bashrc
```

**Ahora solo ejecuta:**
```bash
netdata-servidor
```

---

## 🔧 SOLUCIÓN DE PROBLEMAS

### Problema 1: "Connection refused"
**Causa:** Netdata no está corriendo en el servidor

**Solución:**
```bash
# Conectarse al servidor
ssh root@TU_IP

# Verificar estado
systemctl status netdata

# Si no está activo, iniciar
systemctl start netdata
```

---

### Problema 2: "Port 19999 already in use"
**Causa:** Ya tienes un túnel abierto o algo usando ese puerto

**Solución:**
```bash
# Ver qué está usando el puerto
lsof -i :19999

# O buscar procesos SSH
ps aux | grep ssh

# Matar el proceso
kill [PID]
```

---

### Problema 3: "Permission denied"
**Causa:** No tienes acceso SSH al servidor

**Solución:**
- Verifica tu clave SSH
- Verifica el usuario (¿es `root` o tu usuario?)
- Verifica la IP del servidor

---

### Problema 4: El navegador no carga localhost:19999
**Causa:** El túnel se cerró o no se estableció correctamente

**Solución:**
1. Verifica que la terminal SSH siga abierta
2. Refresca la página del navegador
3. Si nada funciona, cierra el túnel y créalo de nuevo

---

## 📱 ACCESO DESDE DIFERENTES DISPOSITIVOS

### Desde Windows con PuTTY:

1. **Abrir PuTTY**
2. **Session:**
    - Host Name: `TU_IP_SERVIDOR`
    - Port: `22`

3. **Connection → SSH → Tunnels:**
    - Source port: `19999`
    - Destination: `localhost:19999`
    - Click **"Add"**

4. **Volver a Session** y click **"Open"**
5. **Login** con tus credenciales
6. **Abrir navegador:** `http://localhost:19999`

---

### Desde Mac/Linux:
```bash
ssh -L 19999:localhost:19999 root@TU_IP
```

---

### Desde Android (usando Termux):
```bash
# Instalar Termux desde F-Droid o Play Store
# Instalar OpenSSH
pkg install openssh

# Crear túnel
ssh -L 19999:localhost:19999 root@TU_IP

# Abrir navegador en Android
# http://localhost:19999
```

---

### Desde iPad/iPhone (usando Blink Shell):
```bash
# Instalar Blink Shell desde App Store
# Configurar conexión SSH
# Crear túnel
ssh -L 19999:localhost:19999 root@TU_IP

# Abrir Safari
# http://localhost:19999
```

---

## 🎯 CASO DE USO REAL

**Escenario:** Quieres monitorear tu servidor mientras trabajas en casa

```bash
# 1. Abrir terminal (una sola vez)
ssh -L 19999:localhost:19999 root@123.45.67.89

# 2. Abrir navegador
# http://localhost:19999

# 3. Dejar abierto en una pestaña todo el día
# Podrás ver:
# - Picos de CPU cuando llegan visitas
# - Uso de RAM cuando MySQL hace queries
# - Tráfico de red en tiempo real
# - Estado de contenedores Docker
# - Espacio en disco disponible
```

**Mantén la terminal SSH abierta y la pestaña del navegador también.**  
**¡Monitoreo en tiempo real todo el día!**

---

## 📊 QÚE PUEDES HACER EN NETDATA

### Explorar Métricas
- Click en cualquier gráfico para ver más detalles
- Zoom in/out con la rueda del ratón
- Pan arrastrando el gráfico
- Ver valores exactos pasando el ratón

### Filtrar por Tiempo
- Últimos 60 segundos (por defecto)
- Últimos 5 minutos
- Última hora
- Personalizado

### Alertas
- Ver alertas activas
- Configurar umbrales
- Recibir notificaciones

### Exportar Datos
- Descargar CSV
- Compartir gráficos
- API para integración

---

## 🚨 IMPORTANTE: SEGURIDAD

### ✅ HACER:
- Usar túnel SSH siempre que sea posible
- Mantener Netdata actualizado
- Usar claves SSH fuertes
- Cerrar el túnel cuando no lo uses

### ❌ NO HACER:
- No expongas el puerto 19999 públicamente sin protección
- No uses contraseñas SSH débiles
- No compartas tu clave privada SSH
- No dejes túneles abiertos en ordenadores compartidos

---

## 📚 RECURSOS ADICIONALES

### Documentación Oficial:
- https://learn.netdata.cloud/docs/

### Configurar Alertas:
- https://learn.netdata.cloud/docs/alerting/

### API de Netdata:
- https://learn.netdata.cloud/docs/rest-api/

---

## ✨ RESUMEN RÁPIDO

```bash
# En tu ordenador:
ssh -L 19999:localhost:19999 root@TU_IP

# En tu navegador:
http://localhost:19999

# ¡Disfruta del monitoreo en tiempo real!
```

**Todo está cifrado. Todo es seguro. Simple y efectivo.** 🔒

---

## 💬 PREGUNTAS FRECUENTES

### ¿Puedo acceder desde varios ordenadores a la vez?
✅ Sí, cada ordenador crea su propio túnel SSH independiente.

### ¿Se puede ver Netdata sin túnel SSH?
✅ Sí, yendo directamente a `http://TU_IP:19999`, pero **no es seguro**.

### ¿Netdata consume muchos recursos?
❌ No, usa ~50-100 MB de RAM y <1% CPU normalmente.

### ¿Puedo desinstalar Netdata después?
✅ Sí: `/usr/libexec/netdata/netdata-uninstaller.sh --yes --force`

### ¿Funciona con móviles?
✅ Sí, usando apps SSH como Termux (Android) o Blink Shell (iOS).

### ¿Necesito saber SSH avanzado?
❌ No, solo necesitas el comando básico que te mostramos aquí.

---

**Última actualización:** 29 de octubre de 2025  
**Versión del documento:** 1.0