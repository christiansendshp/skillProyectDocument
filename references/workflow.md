# workflow.md — protocolo detallado

Detalle largo del comportamiento que impone `skillProyectDocument`. El resumen
operativo vive en `SKILL.md`; acá está el porqué y los casos borde.

## Dónde viven los documentos

Por defecto, en `docs/` en la raíz del proyecto. Si el proyecto ya usa la raíz
para estos archivos (algunos monorepos lo hacen), respetá esa ubicación y dejalo
anotado en `Agents.md`. Lo importante es que existan y estén sincronizados; la
carpeta es secundaria. Los scripts asumen `docs/`.

## Protocolo de arranque (lectura obligatoria)

Antes de escribir una línea de código, leer en este orden:

1. `Agents.md` — reglas del repo (rama, qué requiere aprobación, convenciones).
2. `ProductDescription.md` — qué se está construyendo y para quién.
3. `Stack_Tecnologies.md` — con qué, y qué decisiones ya están tomadas.
4. `Features.md` — qué ya existe y funciona (no reimplementar).
5. `Roadmap.md` — qué falta y cuál es la próxima tarea.
6. Últimas 20 entradas de `Agentslog.md` — qué se tocó recién y por qué.

El orden importa: `Agents.md` puede cambiar todas las reglas siguientes; el
`Agentslog.md` va último porque es contexto reciente, no norma.

## Ciclo de una tarea

1. Elegí una tarea `PENDIENTE` del `Roadmap.md` (respetando dependencias).
2. Marcala `EN CURSO` con tu `<ID-agente>` y timestamp. Commit chico solo de esa marca
   si trabajás en paralelo con otros agentes.
3. Implementá.
4. Testeá contra el **criterio de aceptación** de la tarea. Sin test que lo
   verifique, la tarea no pasa a `COMPLETADO`.
5. Actualizá documentación:
   - `Roadmap.md`: nuevo estado. Si la funcionalidad quedó 100% cerrada y testeada,
     mové su resumen a `Features.md` y dejá en el Roadmap solo la referencia.
   - `Features.md`: alta de la feature (si corresponde).
   - `Stack_Tecnologies.md`: si cambiaron deps, entidades o decisiones técnicas
     (nueva fila en la tabla de decisiones; no editar filas viejas).
6. Escribí la entrada en `Agentslog.md` (una por cambio de código).
7. Corré `scripts/check_docs.sh <proyecto>`; debe dar exit 0.

## Multi-agente: evitar trabajo pisado

- `Roadmap.md` es el semáforo: una tarea `EN CURSO` con ID de otro agente **no se toca**.
- Antes de empezar, revisá las últimas entradas de `Agentslog.md` para ver qué se
  modificó recién.
- **Conflicto de criterios:** no decidas en silencio ni pises la decisión del otro.
  Registrá **ambas** opciones en `Agentslog.md` (con pros/cons) y escalá al humano.
  La decisión final se refleja como fila nueva en la tabla de decisiones de
  `Stack_Tecnologies.md`.

## Gate de cierre

Una tarea NO está terminada si:

- `check_docs.sh` devuelve exit ≠ 0, o
- falta la entrada en `Agentslog.md` correspondiente al cambio.

## Anti-deriva (documentación siempre veraz)

Si al leer el código detectás que contradice lo documentado:

1. Corregí la documentación en el **mismo commit** que el cambio de código.
2. Registrá la discrepancia detectada y cómo se resolvió en `Agentslog.md`.

La documentación nunca se deja desactualizada "para después".

## Ingeniería inversa (proyecto existente sin docs)

Si falta alguno de los 6 archivos en un repo con código:

1. Corré `init_docs.sh` para traer el/los template(s) faltante(s).
2. Completá su contenido **leyendo el código real** (no inventes): stack real,
   entidades reales, features que ya existen → `Features.md`, lo pendiente → `Roadmap.md`.
3. Dejá una entrada en `Agentslog.md` explicando que se reconstruyó la doc por
   ingeniería inversa y qué quedó como supuesto a confirmar.

## Reglas transversales

- **Nada se borra:** obsoleto → `docs/old/` con `git mv`.
- Documentación en español; código/commits en inglés (salvo que `Agents.md` diga otra cosa).
- Cero secretos ni valores reales de entorno en ningún archivo.
- Placeholders `<!-- COMPLETAR: ... -->`: nunca dejar contenido inventado en su lugar;
  si no hay dato, se deja el placeholder o se pregunta al humano.
