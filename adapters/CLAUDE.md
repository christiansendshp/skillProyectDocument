# CLAUDE.md

## Documentación obligatoria (skillProyectDocument)

Este repo usa la skill **`skillProyectDocument`** (en
`.claude/skills/skillProyectDocument/SKILL.md`). Es de uso obligatorio.

**Regla dura:** antes de escribir o modificar **cualquier** código —crear una app,
agregar/quitar una funcionalidad, arreglar un bug, refactorizar—, leé los 6 archivos
de documentación; después de cada cambio, actualizalos. Aplica aunque el pedido no
mencione documentación.

**Los 6 archivos** (en `docs/`, nombres exactos):
`Agents.md`, `Agentslog.md`, `ProductDescription.md`, `Stack_Tecnologies.md`,
`Roadmap.md`, `Features.md`.

**Antes de codear** (orden de lectura):
`Agents.md` → `ProductDescription.md` → `Stack_Tecnologies.md` → `Features.md` →
`Roadmap.md` → últimas 20 entradas de `Agentslog.md`. Si falta alguno, crealo con
`sh .claude/skills/skillProyectDocument/scripts/init_docs.sh .` y completalo.

**Después de codear:** actualizá `Roadmap.md` (y `Features.md` si se cerró una
funcionalidad, y `Stack_Tecnologies.md` si cambió algo técnico), escribí la entrada
en `Agentslog.md`, y corré
`sh .claude/skills/skillProyectDocument/scripts/check_docs.sh .` (debe dar exit 0).

**Gate de cierre:** una tarea no está terminada si `check_docs.sh` falla o si no
escribiste tu entrada en `Agentslog.md`.

El protocolo completo está en `.claude/skills/skillProyectDocument/SKILL.md` y en
su carpeta `references/`.
