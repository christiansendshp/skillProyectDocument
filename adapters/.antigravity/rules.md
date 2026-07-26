# Reglas del workspace — skillProyectDocument (Antigravity)

> Reglas persistentes del workspace. Adapter autosuficiente: el protocolo completo
> está acá en línea. Si existe `skillProyectDocument/SKILL.md` en el repo, esa es
> la fuente canónica.

## Regla dura (siempre activa)

Antes de crear o modificar **cualquier** código, leé los 6 documentos obligatorios;
después de cada cambio, actualizalos. Vale aunque el pedido no mencione documentación.

## Los 6 documentos (en `docs/`, nombres exactos)

`Agents.md` · `Agentslog.md` · `ProductDescription.md` · `Stack_Tecnologies.md` ·
`Roadmap.md` · `Features.md`.

## Orden de lectura antes de codear

`Agents.md` → `ProductDescription.md` → `Stack_Tecnologies.md` → `Features.md` →
`Roadmap.md` → últimas 20 entradas de `Agentslog.md`.

## Flujo de trabajo

- **Proyecto nuevo:** crear `docs/` con los 6 archivos desde `templates/`; completar
  `ProductDescription.md` y `Stack_Tecnologies.md` sin inventar; desglosar el pedido
  en `Roadmap.md` con IDs (`F01-S02-T03`) y criterios de aceptación; recién ahí codear.
- **Proyecto existente:** leer los 6 en orden; reconstruir el que falte por ingeniería
  inversa; tomar una tarea del `Roadmap.md` (`EN CURSO` con ID + timestamp); implementar;
  testear contra el criterio de aceptación; actualizar docs; escribir en `Agentslog.md`.

## Gate de cierre

Una tarea no está terminada si `scripts/check_docs.sh` falla o si falta la entrada en
`Agentslog.md`.

## Reglas transversales

- Nada se borra: obsoleto → `docs/old/` con `git mv`.
- Documentación en español; código/variables/commits en inglés.
- Cero secretos ni valores reales de entorno.
- Conflicto de criterios: registrar ambas opciones en `Agentslog.md` y escalar al humano.

Detalle: `skillProyectDocument/SKILL.md` y `references/workflow.md`.
