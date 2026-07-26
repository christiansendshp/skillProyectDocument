# AGENTS.md

> Adapter autosuficiente de la skill `skillProyectDocument` para Codex y OpenCode.
> Contiene el protocolo completo en línea (no depende de soporte nativo de skills).
> Si en el repo existe `skillProyectDocument/SKILL.md`, esa es la fuente canónica;
> este archivo la resume y la apunta.

## Regla dura

Antes de escribir o modificar **cualquier** código —crear una app, agregar/quitar
una funcionalidad, arreglar un bug, refactorizar—, **leé los 6 documentos**
obligatorios; **después** de cada cambio, actualizalos. Aplica aunque el pedido no
mencione documentación. Ante la duda, aplica.

## Los 6 documentos obligatorios (en `docs/`, nombres exactos)

1. `Agents.md` — reglas de operación del repo.
2. `Agentslog.md` — bitácora append-only; una entrada por cada cambio de código.
3. `ProductDescription.md` — el producto en términos funcionales (cero tecnología).
4. `Stack_Tecnologies.md` — stack, arquitectura y decisiones técnicas.
5. `Roadmap.md` — único lugar donde vive el trabajo pendiente (IDs `F01-S02-T03`).
6. `Features.md` — catálogo de lo ya implementado y testeado.

## Al iniciar (proyecto nuevo)

1. Crear `docs/` con los 6 archivos (usar `skillProyectDocument/templates/` o
   `sh skillProyectDocument/scripts/init_docs.sh .`).
2. Completar `ProductDescription.md` y `Stack_Tecnologies.md` (sin inventar).
3. Desglosar el pedido en `Roadmap.md` con IDs y criterios de aceptación, antes de codear.
4. Codear. Primera entrada en `Agentslog.md`.

## Al trabajar (proyecto existente)

1. Leer en orden: `Agents.md` → `ProductDescription.md` → `Stack_Tecnologies.md` →
   `Features.md` → `Roadmap.md` → últimas 20 entradas de `Agentslog.md`.
2. Si falta un documento, reconstruirlo por ingeniería inversa antes de seguir.
3. Tomar una tarea del `Roadmap.md` y marcarla `EN CURSO` con `<ID-agente>` + timestamp.
4. Implementar y testear contra el criterio de aceptación.
5. Actualizar `Roadmap.md` (y `Features.md` / `Stack_Tecnologies.md` si corresponde).
6. Escribir la entrada en `Agentslog.md`.

## Gate de cierre

Una tarea no está terminada si `sh skillProyectDocument/scripts/check_docs.sh .`
falla (exit ≠ 0) o si no escribiste tu entrada en `Agentslog.md`.

## Reglas transversales

- Nada se borra: obsoleto → `docs/old/` con `git mv`.
- Documentación en español; código, variables y commits en inglés (salvo que
  `Agents.md` diga otra cosa).
- Cero secretos ni valores reales de entorno.
- Conflicto de criterios en multi-agente: registrar ambas opciones en `Agentslog.md`
  y escalar al humano; no decidir en silencio.

Fuente canónica y detalle: `skillProyectDocument/SKILL.md` + `references/`.
