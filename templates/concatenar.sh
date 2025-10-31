#!/bin/bash

# Script para concatenar archivos .template con marcadores
# Uso: ./concatenar_templates.sh [directorio] [archivo_salida]

# Configuración por defecto
DIRECTORIO="${1:-.}"
ARCHIVO_SALIDA="${2:-templates_concatenados.txt}"

# Limpiar archivo de salida si existe
> "$ARCHIVO_SALIDA"

# Contador de archivos procesados
contador=0

echo "Buscando archivos .template en: $DIRECTORIO"
echo "Archivo de salida: $ARCHIVO_SALIDA"
echo "----------------------------------------"

# Buscar y procesar archivos .template
while IFS= read -r -d '' archivo; do
    # Obtener el path completo del archivo
    path_completo=$(realpath "$archivo")

    # Escribir marcador de inicio
    echo "╔════════════════════════════════════════════════════════════════" >> "$ARCHIVO_SALIDA"
    echo "║ INICIO: $path_completo" >> "$ARCHIVO_SALIDA"
    echo "╚════════════════════════════════════════════════════════════════" >> "$ARCHIVO_SALIDA"
    echo "" >> "$ARCHIVO_SALIDA"

    # Concatenar el contenido del archivo
    cat "$archivo" >> "$ARCHIVO_SALIDA"

    # Agregar línea en blanco si el archivo no termina con salto de línea
    if [ -n "$(tail -c 1 "$archivo")" ]; then
        echo "" >> "$ARCHIVO_SALIDA"
    fi

    # Escribir marcador de fin
    echo "" >> "$ARCHIVO_SALIDA"
    echo "╔════════════════════════════════════════════════════════════════" >> "$ARCHIVO_SALIDA"
    echo "║ FIN: $path_completo" >> "$ARCHIVO_SALIDA"
    echo "╚════════════════════════════════════════════════════════════════" >> "$ARCHIVO_SALIDA"
    echo "" >> "$ARCHIVO_SALIDA"
    echo "" >> "$ARCHIVO_SALIDA"

    # Incrementar contador
    ((contador++))
    echo "Procesado: $archivo"

done < <(find "$DIRECTORIO" -type f -name "*.template" -print0 | sort -z)

# Mostrar resumen
echo "----------------------------------------"
echo "✓ Total de archivos concatenados: $contador"
echo "✓ Archivo generado: $ARCHIVO_SALIDA"

# Verificar si no se encontraron archivos
if [ $contador -eq 0 ]; then
    echo "⚠ No se encontraron archivos .template en el directorio especificado"
    rm -f "$ARCHIVO_SALIDA"
    exit 1
fi