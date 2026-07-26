#!/usr/bin/env sh
# check_docs.sh — valida que existan los 6 documentos obligatorios y sus secciones
# mínimas. Exit 0 = OK; exit 1 = falta algo. Sin dependencias externas.
#
# Uso: sh scripts/check_docs.sh <ruta-proyecto>   (por defecto, el directorio actual)
set -u

TARGET="${1:-.}"
DOCS_DIR="$TARGET/docs"
fail=0

need() {
  # $1 = archivo ; $2.. = substrings requeridos (secciones/marcadores mínimos)
  f="$1"
  shift
  path="$DOCS_DIR/$f"
  if [ ! -f "$path" ]; then
    echo "FALTA archivo: docs/$f"
    fail=1
    return
  fi
  for marker in "$@"; do
    if ! grep -qF -- "$marker" "$path"; then
      echo "docs/$f: falta sección/marcador requerido: '$marker'"
      fail=1
    fi
  done
}

need Agents.md \
  "## Reglas duras" "## Protocolo de arranque" "## Protocolo de cierre" \
  "## Trabajo colaborativo multi-agente" "## Prohibido"

need Agentslog.md "**Qué hice:**" "**Estado:**"

need ProductDescription.md \
  "## Usuarios y roles" "## Funcionalidades" "## Reglas de negocio" \
  "## Glosario" "## Fuera de alcance"

need Stack_Tecnologies.md \
  "## Backend" "## Base de datos" "## Seguridad" "## Variables de entorno" \
  "## Testing" "## Decisiones técnicas"

need Roadmap.md "## Cómo se usa" "## Funcionalidades"

need Features.md "## Features"

if [ "$fail" -eq 0 ]; then
  echo "check_docs: OK — los 6 documentos existen con sus secciones mínimas."
  exit 0
else
  echo "check_docs: FALLÓ — completá lo indicado arriba." >&2
  exit 1
fi
