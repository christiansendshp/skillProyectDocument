#!/usr/bin/env sh
# init_docs.sh — crea los 6 documentos obligatorios en <proyecto>/docs desde
# templates/, solo si faltan. Idempotente: no pisa archivos existentes.
#
# Uso: sh scripts/init_docs.sh <ruta-proyecto>   (por defecto, el directorio actual)
set -eu

TARGET="${1:-.}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/../templates"
DOCS_DIR="$TARGET/docs"

FILES="Agents.md Agentslog.md ProductDescription.md Stack_Tecnologies.md Roadmap.md Features.md"

if [ ! -d "$TEMPLATES_DIR" ]; then
  echo "ERROR: no encuentro templates/ en $TEMPLATES_DIR" >&2
  exit 1
fi

mkdir -p "$DOCS_DIR"

created=0
for f in $FILES; do
  if [ -f "$DOCS_DIR/$f" ]; then
    echo "= ya existe, no se toca: docs/$f"
  else
    cp "$TEMPLATES_DIR/$f" "$DOCS_DIR/$f"
    echo "+ creado: docs/$f"
    created=$((created + 1))
  fi
done

echo "init_docs: $created archivo(s) creado(s) en $DOCS_DIR"
