---
name: skillProyectDocument
description: >
  Crea y mantiene los 6 archivos de documentación obligatorios de todo proyecto
  (Agents.md, Agentslog.md, ProductDescription.md, Stack_Tecnologies.md,
  Roadmap.md, Features.md). Usá esta skill SIEMPRE que se pida crear una app,
  iniciar un proyecto, armar/scaffoldear un repo, agregar una funcionalidad,
  refactorizar o modificar código —aunque el usuario NO mencione documentación—.
  Es OBLIGATORIA antes de escribir cualquier línea de código y al cerrar cada
  cambio. Si dudás si aplica, aplica.
---

# skillProyectDocument

Skill agnóstica de lenguaje, framework y dominio. Su único trabajo es garantizar
que todo proyecto tenga —y mantenga vivos— **6 archivos de documentación
obligatorios**, y que ningún agente escriba código sin leerlos primero ni cierre
una tarea sin actualizarlos.

## CUÁNDO SE DISPARA (leer con atención — el fallo típico es no dispararse)

Activá esta skill ante CUALQUIERA de estas señales, mencione o no el usuario la
palabra "documentación":

- "creá/armá/generá una app / un proyecto / un backend / un frontend / un script".
- "agregá / implementá / sacá una funcionalidad", "arreglá este bug", "refactorizá".
- "modificá / cambiá / tocá" cualquier archivo de código.
- Abrís un repo para trabajar en él (aunque sea para una sola línea).

Ante la duda, **se dispara**. Es más barato leer los 6 archivos de más que dejar
el proyecto sin trazabilidad.

## Los 6 archivos (nombres EXACTOS, respetar mayúsculas y guión bajo)

Viven en `docs/` del proyecto (configurable; ver `references/workflow.md`).

1. **`Agents.md`** — reglas de operación para todos los agentes del repo.
2. **`Agentslog.md`** — bitácora append-only; una entrada por cada cambio de código.
3. **`ProductDescription.md`** — el producto en términos funcionales (cero tecnología).
4. **`Stack_Tecnologies.md`** — la verdad técnica (stack, arquitectura, decisiones).
5. **`Roadmap.md`** — el único lugar donde vive el trabajo pendiente.
6. **`Features.md`** — catálogo de lo ya implementado y testeado.

Plantillas base: `templates/` de esta skill. Copialas con `scripts/init_docs.sh`.

## PROTOCOLO — proyecto nuevo

1. `sh scripts/init_docs.sh <ruta-proyecto>` → crea `docs/` con los 6 archivos
   desde `templates/` (idempotente; no pisa lo existente).
2. Completá `ProductDescription.md` y `Stack_Tecnologies.md` entrevistando al
   usuario o infiriendo del pedido. Reemplazá los `<!-- COMPLETAR: ... -->`.
   **Nunca inventes** dependencias, entidades ni decisiones.
3. Desglosá el pedido en `Roadmap.md` con IDs (`F01-S02-T03`) y criterios de
   aceptación, **antes** de codear.
4. Recién ahí, empezá a escribir código.
5. Escribí la primera entrada en `Agentslog.md`.

## PROTOCOLO — proyecto existente

1. Leé los 6 archivos en este ORDEN: `Agents.md` → `ProductDescription.md` →
   `Stack_Tecnologies.md` → `Features.md` → `Roadmap.md` → últimas 20 entradas de
   `Agentslog.md`.
2. Si falta alguno → generalo por ingeniería inversa del repo antes de continuar
   (`init_docs.sh` crea el que falte; completá su contenido leyendo el código).
3. Tomá una tarea del `Roadmap.md` y marcala `EN CURSO` con tu ID de agente y
   timestamp (evita trabajo pisado en multi-agente).
4. Implementá.
5. Testeá contra el criterio de aceptación de la tarea.
6. Actualizá `Roadmap.md`; si la funcionalidad quedó 100% completa y testeada,
   moves su resumen a `Features.md`. Actualizá `Stack_Tecnologies.md` si cambió
   algo técnico (deps, entidades, decisiones).
7. Escribí la entrada correspondiente en `Agentslog.md`.

## GATE DE CIERRE (no negociable)

Una tarea NO está terminada si:

- `sh scripts/check_docs.sh <ruta-proyecto>` devuelve exit code ≠ 0, **o**
- no escribiste tu entrada en `Agentslog.md` para este cambio.

## ANTI-DERIVA

Si el código contradice lo documentado, se corrige la **documentación** en el
mismo commit y se registra la discrepancia en `Agentslog.md`. La documentación
nunca queda desactualizada a propósito.

## REGLAS TRANSVERSALES

- **Nada se borra.** Contenido obsoleto se mueve a `docs/old/` con `git mv`.
- Documentación en **español**; nombres de archivos/código/variables/commits en
  **inglés** (salvo que `Agents.md` del proyecto diga lo contrario).
- Cero secretos, credenciales ni valores reales de entorno en ningún archivo.
- Los nombres de entidades en el código deben coincidir con el **Glosario** de
  `ProductDescription.md`.

## MÁS DETALLE

- Protocolo completo (arranque, cierre, multi-agente): `references/workflow.md`.
- Instalación por runtime (Claude Code, Codex, OpenCode, Antigravity):
  `references/adapters.md` y la carpeta `adapters/`.
- Verificación: `scripts/check_docs.sh` valida existencia + secciones mínimas.
