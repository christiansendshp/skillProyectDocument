# TAREA — Convertir `project-documentation` en el protocolo de una IA Factory

Repositorio: `github.com/christiansendshp/skillProyectDocument` (rama base `master`).
Este documento es la **fuente de verdad de la tarea**. Si algo de acá contradice
una regla del `AGENTS.md` de la skill, gana `AGENTS.md`, salvo en lo que este
documento cambia explícitamente (sección 4). Todo lo que este documento no
decide, lo decidís vos con la opción más conservadora y reversible, y lo
registrás como `ADR-xxx`.

Idioma: este documento está en español; **todo lo que escribas en el repo
(SKILL.md, templates, references, docs, mensajes de los scripts) sigue en
inglés**, como el resto de la skill. Las palabras clave en español que ya
existen (`LIMITE`, `ESPERA_RESPUESTA`, `BLOQUEO`, `OTRO`) se mantienen.

---

## 1. Objetivo

Que cualquier agente (Claude Code, Codex, OpenCode, Antigravity, otros) que use
la skill en el futuro quede **obligado por los scripts**, no por buena voluntad,
a trabajar como una línea de producción:

1. **Casi sin humanos.** El agente elige trabajo, decide, testea, revisa (con
   otro agente) y cierra. El humano solo interviene en *red lines* y lo hace de
   forma asíncrona, sin frenar la fábrica.
2. **TDD verificable.** Spec ejecutable → test que falla (RED) → código mínimo
   (GREEN) → revisión independiente → cierre. Cada paso deja evidencia que
   `check` y los comandos validan.
3. **Brain (memoria) para gastar menos contexto.** Memoria de trabajo por tarea,
   memoria de lecciones aprendidas reutilizable, y un comando que arma el
   paquete mínimo de contexto para una tarea.
4. **Proceso proporcional al tamaño.** Las tareas chicas van por un carril
   rápido; el ciclo completo queda para lo que lo justifica.
5. **Varias CLIs sin API, sin que los límites frenen.** Los agentes son CLIs
   con planes de suscripción (hoy Claude Code y Gemini CLI, este último con la
   cuota más baja). Gemini revisa cuando tiene cuota; si se queda sin cuota,
   Claude cubre los dos papeles. Un dispatcher local pasa el turno de una CLI a
   otra usando el ledger como canal.

Resultado verificable al final: sección 9 (Definition of Done).

---

## 2. Restricciones que no se rompen (compatibilidad)

Salen de los propios `BR`/`ADR` de la skill. Romper una es un bug.

| # | Restricción | Origen | Consecuencia para el diseño |
|---|---|---|---|
| R1 | Solo POSIX `sh` y Windows PowerShell 5.1, en paridad de comandos y de bytes de salida. Sin Python, Node, jq, red ni base de datos. `git` solo como opcional (ya se usa así en `migrate`) | Stack: Out of scope, ADR-022 | El brain es Markdown + búsqueda determinística con `awk`/`grep`. **Nada de embeddings, vector DB ni servidores MCP de memoria** |
| R2 | Archivos de contrato en Markdown puro (tablas y listas). Nunca YAML ni JSON. Nunca un `\|` dentro de una celda | BR-004, ADR-018, F03-DEBT-01 | Brain, spec y memoria de trabajo usan tablas y listas |
| R3 | `context` emite como máximo 8 KiB | BR-002 (invariante crítico) | **Medido hoy:** proyecto nuevo = 5127 B; el repo de la skill = 7573 B. El brain **no** entra en `context`: va a un comando nuevo, `recall`, con presupuesto propio |
| R4 | `init`/`link` nunca sobrescriben contenido existente | BR-001 | `migrate --factory` inserta, no reemplaza |
| R5 | Un proyecto que no usa lo nuevo se comporta exactamente igual (misma salida de `check`, `status`, `context`, `rotate`) | BR-007 | Todo lo nuevo se activa solo con **Factory mode**. Sin la sección `## Factory` en `AGENTS.md`, cero cambios de comportamiento |
| R6 | Estados del ledger fijos: `IN_PROGRESS`, `PAUSE`, `REVIEW`, `ASSIGNED`, `DONE`. Columnas del Roadmap fijas (edición posicional desde el final) | ADR-003, ADR-021 | Las fases van como **línea** del ledger (`- Phase: RED`), no como estados nuevos. El Roadmap no gana columnas |
| R7 | `AGENTS.md` es la única fuente de reglas; los adapters solo redirigen | ADR-007 | Las reglas de la fábrica viven en `AGENTS.md` (compactas) y el detalle en `references/factory.md` de la skill |
| R8 | Línea de base de tests: `sh scripts/smoke_test.sh` → 290 passed, 0 failed (los casos de PowerShell corren si hay `pwsh`/`powershell.exe`) | Stack: Critical commands | Nunca puede bajar. Cada comando nuevo lleva casos sh **y** ps1 |

### Choques entre lo pedido y la skill actual, y cómo se resuelven

| Choque | Resolución |
|---|---|
| `AGENTS.md` hoy dice "Escalate to the human when a choice affects product behavior, cost, security or an external commitment" | En Factory mode se reemplaza por la **política de autonomía** (4.2). Comportamiento de producto ambiguo → el agente decide, lo registra como `BR` en `HYPOTHESIS` cubierto por tests, y aparece en `digest`. Solo las red lines esperan a un humano, sin bloquear la fábrica |
| El gate humano del spec (propuesto antes) | Lo reemplaza un **review independiente de otro agente** (`spec-critic`, rol QA o SPEC, id distinto del autor) |
| Revisión independiente sin humanos | Factory mode exige al menos dos ids en `## Agent identity` (uno con rol QA). Un subagente con id propio cuenta |
| Más reglas en `AGENTS.md` = más bytes en `context` | La sección `## Factory` del template no supera ~1,2 KiB. El repo de la skill (7573 B) tiene que compactar su `## Active work`/summaries **antes** de adoptar Factory mode |
| BR-007 (nada cambia sin opt-in) vs "obligar a los agentes del futuro" | Los **scripts** respetan BR-007 (sin `## Factory`, modo clásico). El **SKILL.md** obliga: `init` crea proyectos nuevos en Factory mode por defecto, y un agente que abre un proyecto sin `## Factory` corre `migrate --factory`, salvo que `AGENTS.md` declare `Mode: CLASSIC` |
| El ciclo completo cuesta demasiado en tareas chicas | **Carril rápido** (D-17): sin spec formal ni RED, con límites de tamaño que el script verifica en `handoff` |
| Revisión de otro modelo con un plan de Gemini de cuota baja | **Revisión cross-model preferida, nunca bloqueante** (D-18): Gemini revisa solo lo que más vale; si no tiene cuota, revisa Claude con otro id. Queda marcado y Gemini lo audita después si le sobra cuota |
| Sin API: los agentes son CLIs que no se hablan entre sí | **Dispatcher local** (D-19): un loop en PowerShell y sh que lee el ledger con `next`, lanza la CLI que corresponde en modo no interactivo y detecta límites por la salida. Los agentes nunca se llaman entre sí |
| Un `PAUSE` solo lo puede escribir el dueño de la tarea | El dispatcher es el supervisor del proceso de esa CLI: cuando la CLI se corta por límite, escribe `pause <ese agente> <tarea> LIMITE ...` en su nombre. La regla existente ya permite que **cualquier** agente retome un `LIMITE` enseguida |

---

## 3. Decisiones cerradas (no preguntar)

Registrá cada una como fila `ADR-023` en adelante en `docs/Stack_Tecnologies.md`
de la skill (Status `CONFIRMED`, fuente: `docs/features/ia-factory.md`).

| ID | Decisión |
|---|---|
| D-01 | **Activación:** sección `## Factory` en `AGENTS.md` con una tabla `Setting \| Value`. Si existe y `Mode` = `FACTORY`, los scripts aplican las reglas de fábrica como **errores**. Si no existe, o `Mode` = `CLASSIC`, todo sigue como hoy. Variable `PROJECT_DOCS_MODE=classic\|factory` la pisa (para tests) |
| D-02 | **`init` crea en Factory mode por defecto**; `init --classic` crea el proyecto clásico de seis archivos. `migrate --factory` agrega a un proyecto existente la sección `## Factory`, `docs/Brain.md`, `docs/specs/` y `docs/brain/tasks/` (idempotente, sin sobrescribir) |
| D-03 | **Settings y defaults:** `Mode` FACTORY · `Require TDD` YES · `Independent review` YES · `WIP per agent` 1 · `Max fix attempts` 3 · `Fast lane max files` 5 · `Fast lane max lines` 150 · `Fast lane protected paths` `prisma/ migrations/ auth/ rls/ security/` · `Preferred reviewer` (vacío) · `Fallback reviewer` (vacío) · `Recall budget bytes` 4096 · `Brain max entries` 80. **Una fila ausente toma el default**, así el template solo trae las filas que un agente necesita leer y `context` no crece de más |
| D-04 | **Fases:** `SPEC → RED → GREEN → REVIEW → DONE` (el refactor vive dentro de GREEN). La fase actual de una tarea es la última línea `- Phase:` de su ledger; sin ninguna, es `SPEC` |
| D-05 | **Roles** del roster: `SPEC`, `TEST`, `DEV`, `QA`, `OPS`, más `BOTH` (cualquiera) y `DEVELOPER` como alias legacy de `DEV`. Fase→rol: SPEC→SPEC, RED→TEST, GREEN→DEV, REVIEW→QA. Sin roster en Factory mode → `check` falla |
| D-06 | **Evidencia de tests determinística:** todo `verify` de fase lleva el marcador `exit=N`. Pasar de RED a GREEN exige `exit=` distinto de 0. `handoff` y `done` en Factory exigen `exit=0` |
| D-07 | **Tests inmutables en GREEN:** al pasar a GREEN se registra `- Red: <sha>` (`git rev-parse HEAD`) y los paths de tests del spec. `handoff` falla si `git diff --name-only <sha>..HEAD` toca alguno de esos paths. Sin git → WARN y el reviewer tiene que declarar `tests unchanged` en su nota |
| D-08 | **Tareas sin test** (docs, config, infra): el spec declara `Level: NONE` con `Justification` no vacía; el reviewer igual tiene que dar PASS. Bugs (`Fxx-BUG-xx`): el RED es un test que reproduce el bug, siempre |
| D-09 | **Brain = archivos Markdown en git**, recuperación por palabras clave y prefijos de path, sin dependencias. Memoria externa (MCP, vector DB) queda en `## Out of scope` |
| D-10 | **Presupuestos:** `context` ≤ 8 KiB (sin cambios) + `recall` ≤ `Recall budget bytes` (4096). Arranque de tarea ≤ 12 KiB en total |
| D-11 | **Red lines** = `pause <agent> <id> ESPERA_RESPUESTA "RED-LINE: <detalle>"`. No se crea categoría nueva. El agente toma otra tarea inmediatamente |
| D-12 | **Decisión de producto autónoma** = fila `BR-xxx` en `HYPOTHESIS` con fuente `agent:<id> <TASK-ID>`, más al menos un escenario de test que la fije |
| D-13 | **Límite de intentos:** con 3 `Review: FAIL` o 3 vueltas GREEN→RED en la misma tarea, `claim` del DEV falla y obliga a `pause ... BLOQUEO`, con lección obligatoria en el brain |
| D-14 | **WIP:** en Factory, `claim` falla si el agente ya tiene otra tarea `IN_PROGRESS` y supera `WIP per agent` |
| D-15 | **La memoria de trabajo se borra al `done`** (git es la recuperación, como dice `references/workflow.md`), después de destilar lecciones al brain |
| D-16 | **Rama:** trabajás en `feat/ia-factory` creada desde `master`. Merge según `AUTO_MERGE` del prompt (default NO: dejás el PR listo) |
| D-17 | **Carril rápido (FAST):** una fila del Roadmap va por FAST si su `Description` contiene el token `Lane: FAST`. Sin spec, sin RED; review de cualquier otro id. El script verifica el tamaño en `handoff` (4.3.1). Si la tarea se pasa del carril, vuelve a NORMAL desde SPEC |
| D-18 | **Revisión cross-model preferida, nunca bloqueante.** `Preferred reviewer` hace las reviews del carril NORMAL (spec y código). Si está en cooldown por límite, o falló dos corridas seguidas en esa review, la hace `Fallback reviewer`. `review` agrega `- Cross-model: NO` cuando el `Model` del roster del reviewer y del holder empiezan con la misma palabra. El carril FAST nunca usa `Preferred reviewer` (ahorra su cuota) |
| D-19 | **Dispatcher** = `scripts/factory_dispatch.ps1` y `.sh`, fuera del núcleo `project_docs`. Lee `.factory/dispatch.md`, corre **una CLI a la vez** (sin carreras sobre la copia de trabajo y cuidando la cuota) y guarda su estado en `.factory/state.md` y logs en `.factory/runs/` (ambos en `.gitignore`) |
| D-20 | **Límites:** se detectan por exit code ≠ 0 más una coincidencia de texto configurable por agente. Cooldown hasta la hora de reset si la salida la trae (Claude Code imprime `resets <hora>`); si no, `Cooldown minutes`. Tope opcional `Max runs per day` por agente. Con todos los agentes en cooldown, el dispatcher duerme hasta el reset más cercano |
| D-21 | **Roster por defecto para un plan Claude + Gemini:** `claude-spec` (SPEC), `claude-test` (TEST), `claude-dev` (DEV), `claude-qa` (QA, fallback) y `gemini-qa` (QA, preferido). Los ids distintos de Claude son corridas separadas de `claude -p` con contexto limpio: separan funciones sin costo de plan extra |

---

## 4. Diseño

### 4.1 Factory mode en `AGENTS.md`

El template `templates/AGENTS.md` gana esta sección (texto objetivo; podés
pulirlo, **no agrandarlo más de ~1,5 KiB**). En modo Factory, la sección
"Technical and product decisions" del template remite a `## Factory` en vez de
"Escalate to the human". Las filas que no están (por ejemplo `Recall budget
bytes`) toman su default (D-03).

```markdown
## Factory

Settings read by the scripts; a missing row takes its default. Detail: the
skill's `references/factory.md`.

| Setting | Value |
|---|---|
| Mode | FACTORY |
| Require TDD | YES |
| Independent review | YES |
| WIP per agent | 1 |
| Max fix attempts | 3 |
| Fast lane max files | 5 |
| Fast lane max lines | 150 |
| Fast lane protected paths | prisma/ migrations/ auth/ rls/ security/ |
| Preferred reviewer | — |
| Fallback reviewer | — |

- Never ask which task to take: run `next <agent>`; never stay idle.
- Small changes with no business rule, schema, auth or API change go FAST
  (`Lane: FAST` in the row Description): no spec or RED, still tested and
  reviewed. Outgrown limits send the task back to SPEC.
- Phases: SPEC -> RED -> GREEN -> REVIEW -> DONE. Move with `advance`, review
  with `handoff`/`review`, close with `retro` then `done`.
- GREEN never edits the tests recorded at RED; a wrong test goes back to SPEC.
- Decide reversible choices yourself. Record product guesses as HYPOTHESIS
  `BR-xxx` rows pinned by a test.
- Red lines (pause `ESPERA_RESPUESTA` "RED-LINE: ..." and take other work):
  main or production deploy, destructive data operations, secrets, new paid
  services, weakening auth or tenant isolation, personal-data handling rules.
- Context: `context`, then `recall <task>`; read more only where recall
  points. `checkpoint` before pausing, compacting or changing phase.
```

### 4.2 Política de autonomía

| Clase de decisión | Qué hace el agente | Dónde queda |
|---|---|---|
| Técnica, reversible, dentro de la tarea | Decide | Código; `ADR-xxx` si es duradera |
| Técnica duradera o de arquitectura | Decide la opción más reversible | `ADR-xxx` `HYPOTHESIS` → `CONFIRMED` cuando un test o un deploy la valida |
| Producto ambiguo | Busca primero filas `DEFAULT` del brain; si no hay, elige el comportamiento más estricto/conservador | `BR-xxx` `HYPOTHESIS` + escenario de test (D-12) + `digest` |
| Pregunta que bloquea la tarea | No la rodea en silencio | Fila `Fxx-GAP-xx` + `Depends on`; la tarea queda en `pause BLOQUEO`; el agente sigue con otra |
| Red line (D-11) | Prepara todo hasta el borde y pausa | `ESPERA_RESPUESTA "RED-LINE: ..."` + `digest` |

### 4.3 Línea de producción

| Fase | Rol | Entra | Sale | Gate que valida el script |
|---|---|---|---|---|
| SPEC | SPEC | Fila del Roadmap | `docs/specs/<TASK-ID>.md` | `advance RED` exige: spec existe; secciones requeridas sin `UNKNOWN`; ≥1 escenario; cada escenario con `Level`; `NONE` con `Justification`; último `REVIEW` de la tarea con `Review: PASS` de un agente distinto del autor |
| RED | TEST | Spec aprobado | Tests commiteados que fallan; paths en `## Tests` del spec | `advance GREEN` exige `exit=` ≠ 0, `## Tests` no vacío y con paths existentes, árbol limpio si hay git; registra `- Red: <sha>` |
| GREEN | DEV | Tests en rojo | Código mínimo + refactor | `handoff` exige `exit=0`, tests intactos (D-07), checkpoint presente |
| REVIEW | QA (+ auditores) | Handoff | `review PASS\|FAIL` | Reviewer ≠ holder (error en Factory); FAIL suma un intento (D-13) |
| DONE | holder o reviewer | `Review: PASS` | `retro` + `done` | `done` exige `retro` registrado, `exit=0` y review PASS |

**Comandos nuevos o extendidos** (sh y ps1, misma salida):

| Comando | Comportamiento |
|---|---|
| `advance <agent> <task-id> <next-phase> <verify> [to-agent]` | Solo el holder. Valida el gate de la fase actual, escribe una entrada `ASSIGNED` con `- Phase: <next>` y `- Assign: <to-agent o el primer id del roster con el rol de la fase>`. El siguiente agente hace `claim` (hoy `claim` sobre `ASSIGNED` ajeno ya funciona con warning; en Factory, sin warning si el rol coincide). La fila del Roadmap sigue `IN_PROGRESS` en `## Active work` durante todas las fases, igual que en REVIEW (ADR-021); solo cambia `Owner` |
| `claim` (Factory) | Agrega `- Phase: <fase actual>`. Falla si el rol del agente no corresponde a la fase, si supera WIP (D-14) o si se agotaron los intentos (D-13) |
| `handoff` / `review` / `done` (Factory) | Las advertencias actuales (self-review, cierre sin review PASS, verify vacío) pasan a ser **errores**. Se suman los gates de la tabla |
| `next <agent>` | Imprime el ID de la próxima tarea elegible para el rol del agente, o `none`. Orden: tareas `ASSIGNED` a él → reviews pendientes con `Handoff` a él (o sin destinatario, si es QA) → tareas `PAUSE LIMITE` de su rol → tareas en su fase sin dueño → próxima `TODO` del Epic de mayor prioridad (rol SPEC para NORMAL, rol DEV para FAST, BOTH para ambas) → solo para `Preferred reviewer`, tareas `DONE` con `Cross-model: NO` todavía sin auditar (4.8). Saltea `PAUSE` con `RED-LINE` o `BLOQUEO` sin resolver |
| `status` (Factory) | Agrega la fase y el carril a cada tarea abierta |

#### 4.3.1 Carril rápido (FAST)

**Cuándo.** El agente que crea la fila decide el carril. Va por FAST si se
cumplen todas estas condiciones:

- no crea ni cambia una regla `BR`;
- no toca schema, migraciones, autenticación, RLS/tenants ni un contrato de API público;
- entra en `Fast lane max files` y `Fast lane max lines`.

**Flujo.**

| Paso | Qué pasa | Qué valida el script |
|---|---|---|
| `claim` | Rol DEV o BOTH. Registra `- Lane: FAST` y `- Base: <sha>` (`git rev-parse HEAD`) | Que la fila tenga `Lane: FAST` |
| Trabajo | Si cambia comportamiento, agrega o extiende al menos un test (un comportamiento, un nivel) | — |
| `handoff` | Reviewer por defecto: `Fallback reviewer` | `exit=0`; el diff desde `Base` respeta máximo de archivos y de líneas (agregadas + borradas) y no toca `Fast lane protected paths`; si la fila es `Fxx-BUG-xx`, el diff incluye al menos un archivo de test (paths con `.spec.`, `.test.`, `/test/`, `/tests/` o `/e2e/`) |
| `review` | Cualquier id distinto del holder | Mismas reglas que NORMAL |
| `retro` + `done` | `learned` puede ser `none` salvo que hubo un FAIL | Mismas reglas que NORMAL |

**Si la tarea se pasa del carril**, `handoff` falla con `task outgrew FAST
lane`. El agente guarda el trabajo en la rama `wip/<TASK-ID>`, saca `Lane:
FAST` de la fila, vuelve el código a `Base` y la tarea arranca en SPEC. El
código guardado vuelve recién en GREEN, cuando ya hay tests que fallan.

**Sin git**, los controles de tamaño quedan en WARN y el reviewer tiene que
escribir `fast lane ok` en su nota.

### 4.4 Spec ejecutable: `templates/Spec.md` → `docs/specs/<TASK-ID>.md`

Lo crea `advance` o el agente SPEC si no existe. Secciones (Markdown puro):

```markdown
# Spec <TASK-ID> — <Name>

## Summary
- Goal: ...
- Rules: BR-xxx, BR-yyy
- Tags: palabras clave y prefijos de path para recall
<!-- context:end -->

## Scenarios
| ID | Given | When | Then | Level | Justification |
|---|---|---|---|---|---|
| S01 | ... | ... | ... | UNIT | — |

## Tests
- path/to/file.spec.ts (S01, S02)

## Out of scope
- ...
```

`Level` ∈ `UNIT`, `INTEGRATION`, `CONTRACT`, `E2E`, `NONE`. Regla "un
comportamiento, un nivel": cada escenario tiene un único nivel responsable.
`check` (Factory): toda tarea en fase ≥ RED tiene spec válido; `Justification`
obligatoria con `NONE`.

### 4.5 Brain: tres niveles de memoria

| Nivel | Archivo | Qué guarda | Quién lo lee |
|---|---|---|---|
| Trabajo (por tarea) | `docs/brain/tasks/<TASK-ID>.md` | Paso actual, próximo paso, archivos tocados, intentos, hallazgos | `recall` y quien retoma la tarea en frío. Se borra al `done` (D-15) |
| Episódica | `docs/Agentslog.md` + `docs/history/` | Qué pasó y quién (ya existe) | `context` (últimas 5) |
| Lecciones y mapa | `docs/Brain.md` (7.º archivo de contrato, solo en Factory) | Errores a evitar, patrones, recetas, defaults de decisión, mapa módulo→archivos/tests | `recall`, filtrado por la tarea |

**`templates/Brain.md`:**

```markdown
# Brain

## Operational summary
- Entries: 3 of 80
- Last gc: —
<!-- context:end -->

## Entries
| ID | Name | Kind | Trigger | Lesson | Evidence | Status | Hits | Last used |
|---|---|---|---|---|---|---|---|---|
| LRN-001 | Prefer the most reversible option | DEFAULT | * | When two options are equivalent choose the one cheaper to undo and record it as an ADR | seed | CONFIRMED | 0 | — |
| LRN-002 | Ambiguous product rule takes the stricter behavior | DEFAULT | * | Record it as a HYPOTHESIS BR row and pin it with a scenario | seed | CONFIRMED | 0 | — |
| LRN-003 | Reproduce a bug before fixing it | PATTERN | bug fix regression | The RED test of a BUG task reproduces the reported failure first | seed | CONFIRMED | 0 | — |
```

- `Kind` ∈ `PITFALL`, `PATTERN`, `RECIPE`, `DEFAULT`, `MAP`. `Status` epistémico
  (`CONFIRMED` si lo probó un test o un verify; si no, `HYPOTHESIS`).
- `Trigger`: palabras en minúscula y prefijos de path separados por espacio;
  `*` = siempre se incluye. `Evidence`: `log:TASK-ID`, sha o path de test.
- `Name` ≤ 10 palabras (misma regla que el Roadmap). IDs `LRN-xxx`, nunca se reusan.

**Comandos del brain:**

| Comando | Comportamiento |
|---|---|
| `checkpoint <agent> <task-id> <step> <next>` | Crea o actualiza `docs/brain/tasks/<TASK-ID>.md`: reescribe `## Now` (Step, Next, Attempts, Updated) y agrega una línea a `## Trail`. En Factory, `pause` y `advance` fallan si la tarea no tiene `## Now` |
| `recall <task-id>` | Emite, en este orden y hasta el presupuesto: (1) la fila del Roadmap; (2) `## Summary` del spec; (3) `## Now` de la memoria de trabajo; (4) filas del brain que coinciden. Termina con `recall: N of M brain entries shown` |
| `learn <agent> <task-id> <kind> <name> <trigger> <lesson>` | Agrega una fila con el próximo `LRN-xxx`, `Evidence` = `log:<task-id>`, `Status` = `HYPOTHESIS`, `Hits` 0. Rechaza `\|`, Name > 10 palabras y Kind inválido |
| `retro <agent> <task-id> <used-ids\|none> <learned-ids\|none>` | Se registra en `## Retro` de la memoria de trabajo. Rechaza `learned` = `none` si la tarea tuvo un `Review: FAIL`, un `PAUSE BLOQUEO` o más de un ciclo RED→GREEN |
| `done` (Factory) | Exige `retro`. Suma 1 a `Hits` y fecha `Last used` de cada id usado, agrega `- Brain: used ...; learned ...` a la entrada `DONE` y borra la memoria de trabajo |
| `rotate` (Factory) | Si el brain supera `Brain max entries`, archiva en `docs/history/brain-archive-<fecha>.md` las filas con menos `Hits` y `Last used` más viejo hasta quedar en el 75 % del máximo (nunca las `DEFAULT` con `*`). Mismo hash SHA-256 que la rotación del ledger |
| `check` (Factory) | Valida enums, formato `LRN-xxx`, tope de filas y ausencia de `\|`. **WARN** de promoción para filas `CONFIRMED` con `Hits` ≥ 5: candidatas a regla en `AGENTS.md`, `ADR` o `BR` |

**Algoritmo de `recall` (determinístico e idéntico en sh y ps1):**

1. Tokens de la tarea: palabras en minúscula de ≥ 4 letras de `Name`,
   `Description` y `Depends on` de la fila, más todo `Tags:` del spec.
2. Puntaje de una fila del brain = cantidad de tokens de su `Trigger` presentes
   en los tokens de la tarea (un prefijo de path coincide si algún token
   empieza con él). `*` = puntaje 1.
3. Se incluyen las filas con puntaje ≥ 1, ordenadas por puntaje desc, `Hits`
   desc, ID asc.
4. Si se pasa del presupuesto, se descartan **filas enteras** desde el final.
   Nunca se corta una fila ni las secciones 1–3. Si las secciones 1–3 solas
   superan el presupuesto, `recall` falla con un mensaje que pide compactar el
   spec o la memoria de trabajo.

### 4.6 Economía de contexto (reglas para los agentes, en `references/factory.md`)

- Arranque: `context` (≤ 8 KiB) + `recall <task>` (≤ 4 KiB). Nada más hasta que
  la tarea lo pida.
- Leer por rango y buscar antes de abrir: las filas `MAP` del brain dicen qué
  archivos y qué comando de test corresponden a cada módulo.
- A un subagente se le pasa solo la salida de `recall` y el path del spec, nunca
  el historial de la conversación.
- `checkpoint` antes de pausar, de cambiar de fase, de una compactación del
  runtime o de cualquier salida de herramienta larga. Después de compactar se
  recarga con `recall`.
- Cada transición de fase es un commit `<TASK-ID> <PHASE>: <summary>`. Entre
  máquinas, el claim se commitea y pushea enseguida (regla existente).

### 4.7 `digest`: revisión humana asíncrona

`digest [since-ISO]` (≤ 4 KiB): `BR`/`ADR` en `HYPOTHESIS` con fuente
`agent:`, pausas `RED-LINE` abiertas, `Fxx-GAP` abiertos, lecciones nuevas,
tareas cerradas por carril, cantidad de `Review: FAIL`, reviews NORMAL con
`Cross-model: NO` y cuántas ya auditó el `Preferred reviewer`. Es lo único que
un humano necesita leer, y es la entrada natural de un tablero externo.

### 4.8 Revisión cross-model con fallback

Objetivo: aprovechar el modelo de cuota baja donde más rinde y que su límite
nunca frene la fábrica.

| Situación | Quién revisa | Marca en el ledger |
|---|---|---|
| Spec o código del carril NORMAL, `Preferred reviewer` con cuota | `Preferred reviewer` (`gemini-qa`) | — |
| Lo mismo, pero `Preferred reviewer` en cooldown, o con 2 corridas fallidas en esa review | `Fallback reviewer` (`claude-qa`) | `- Cross-model: NO` |
| Carril FAST | `Fallback reviewer`, directo | `- Cross-model: NO` (no se audita) |
| `Preferred reviewer` con cuota y sin reviews pendientes | Audita tareas NORMAL en `DONE` con `Cross-model: NO` | Entrada `append-log` con estado `AUDIT`. Si encuentra un problema, crea una fila `Fxx-BUG-xx`; nunca reabre la tarea |

- `handoff` en Factory sin reviewer explícito usa `Preferred reviewer` en
  NORMAL y `Fallback reviewer` en FAST (si están vacíos, cualquier QA vía `next`).
- `review` escribe `- Cross-model: NO` comparando la primera palabra de la
  columna `Model` del roster para reviewer y holder.
- El prompt que recibe el revisor es mínimo: salida de `recall`, el spec y el
  diff desde `Red` (NORMAL) o `Base` (FAST). Nada de historial: menos tokens.

### 4.9 Dispatcher: cómo se pasan el turno las CLIs

**Principio:** el ledger es el canal. Ningún agente llama a otro. El
dispatcher pregunta `next` por cada agente y lanza la CLI que corresponde en
modo no interactivo. Cuando una corrida termina, el dispatcher vuelve a
preguntar enseguida: el traspaso dev → revisor tarda lo que tarda arrancar la
siguiente CLI.

**Configuración** `.factory/dispatch.md` (Markdown, se commitea; lo crean
`init` y `migrate --factory` desde `templates/dispatch.md`). Valores por
defecto para un plan Claude + Gemini:

| Agent id | Plan | Command | Limit text | Cooldown minutes | Max runs per day | Covers for |
|---|---|---|---|---|---|---|
| gemini-qa | gemini | `gemini --approval-mode=yolo -p "Read {PROMPT_FILE} and follow it"` | RESOURCE_EXHAUSTED; quota; 429 | 60 | 20 | — |
| claude-spec | claude | `claude -p "Read {PROMPT_FILE} and follow it" --permission-mode acceptEdits` | hit your session limit; hit your weekly limit; hit your opus limit | 60 | — | — |
| claude-test | claude | igual que claude-spec | igual | 60 | — | — |
| claude-dev | claude | igual que claude-spec | igual | 60 | — | — |
| claude-qa | claude | igual que claude-spec | igual | 60 | — | gemini-qa |

- En el template real cada fila lleva el comando completo ("igual" es solo
  para abreviar acá).
- **`Plan`** agrupa los ids que comparten cuota: si `claude-dev` llega al
  límite, entran en cooldown todos los `claude-*`.
- **`Limit text`**: subcadenas separadas por `;`, sin distinguir mayúsculas.
  Nunca `|` (R2).
- **`Covers for`**: ese agente toma las reviews del agente cubierto cuando el
  plan del cubierto está en cooldown o el cubierto falló dos veces esa review. Si algún día
  querés que Gemini cubra algo de Claude, alcanza con esta columna y un rol
  `BOTH` en el roster.
- **Flags verificados** (octubre de 2026; el agente los confirma con `--help`
  en la máquina antes de fijarlos):
  - `claude -p` corre sin interfaz con el login de la suscripción, sale con
    código ≠ 0 si falla, e imprime el corte por límite como
    `You've hit your session limit · resets 3:45pm` (también `weekly` y
    `Opus`). Además reintenta solo los 429 temporales.
  - **No usar `--bare`**: no lee el login de la suscripción y exige una API key.
  - Los comandos de shell que no son edición necesitan `--allowedTools` o
    reglas `permissions.allow` en `.claude/settings.json` del proyecto. La
    alternativa es `--permission-mode auto --permission-prompts none`, si tu
    versión y tu plan lo permiten.
  - `gemini -p` corre sin interfaz. YOLO solo se activa por flag
    (`--yolo` o `--approval-mode=yolo`). Exit codes: 0 ok, 1 error o falla de
    API, 42 entrada inválida, 53 límite de turnos.

**Prompt de cada corrida** (`templates/dispatch-prompt.md`, en inglés). El
dispatcher lo completa y lo escribe en `.factory/runs/<run-id>.prompt.md`:

```markdown
You are {AGENT} (role {ROLE}) in {PROJECT}. Task {TASK}, phase {PHASE}, lane {LANE}.
Nobody is watching: never ask questions; follow AGENTS.md ## Factory.
1. Run `context`, then `recall {TASK}`. Read more only where recall points.
2. Do only your phase and close it with its command: advance, handoff,
   review, or retro then done.
3. Run `checkpoint` before every long step. If you cannot finish, pause with
   the right category.
```

**Loop** (`factory_dispatch.ps1 <project> [--watch] [--once]` y su par `.sh`):

1. Carga config y estado. Saca los cooldowns vencidos y reinicia los
   contadores diarios a la medianoche local.
2. Recorre la tabla en orden. Para cada agente cuyo plan no está en cooldown,
   pide `next <agent>`. Para un agente con `Covers for`, si el cubierto no está
   disponible, también toma las reviews que `next <cubierto>` devolvería.
3. Al primer candidato, escribe el prompt, corre el comando con `Run timeout
   minutes` (default 60) y guarda la salida en `.factory/runs/`.
4. Clasifica el resultado:
   - **Exit 0 y el ledger de la tarea cambió:** éxito.
   - **La salida coincide con `Limit text`:** cooldown del plan hasta la hora
     de `resets <hora>` si está, o `Cooldown minutes`. Si el agente era dueño
     de una tarea `IN_PROGRESS`, escribe
     `pause <agent> <task> LIMITE "limit until <hora>"`.
   - **Cualquier otro caso:** suma una falla para ese agente y esa tarea.
     Con 2 en una review, habilita el fallback. Con 3 en una tarea propia,
     escribe `pause <agent> <task> BLOQUEO "dispatcher: 3 runs without progress"`.
5. Vuelve al paso 1 enseguida. Sin candidatos:
   - con cooldowns abiertos, duerme hasta el reset más cercano;
   - con `--watch`, duerme `Idle seconds` (default 300) y vuelve a mirar;
   - en otro caso, termina con un resumen.
6. **Freno manual:** si existe `.factory/STOP`, termina después de la
   corrida en curso.

En tests, `PROJECT_DOCS_DISPATCH_NO_SLEEP=1` imprime
`sleep until <hora>` en vez de dormir. `--once` hace una sola iteración.

En Windows se deja corriendo en una terminal, o como tarea del Programador de
tareas al iniciar sesión.

---

## 5. Archivos a tocar

| Archivo | Cambio |
|---|---|
| `scripts/project_docs.sh` y `.ps1` | Detección de modo; `advance`, `next`, `checkpoint`, `recall`, `learn`, `retro`, `digest`; extensiones de `init`, `migrate`, `claim`, `pause`, `handoff`, `review`, `done`, `status`, `rotate`, `check`. Paridad de bytes |
| `templates/AGENTS.md` | Sección `## Factory` (4.1); "Technical and product decisions" remite a ella en Factory; roles nuevos en el texto del roster |
| `templates/Brain.md`, `templates/Spec.md`, `templates/WorkingMemory.md` | Nuevos |
| `references/factory.md` | Nuevo: fases, gates, autonomía, brain, economía de contexto, ejemplos de una tarea completa |
| `references/workflow.md` | Comandos nuevos; Gate de `check` en Factory; los siete archivos en Factory |
| `references/adapters.md`, `adapters/*`, `agents/openai.yaml` | Mencionar `recall` en el arranque; el `default_prompt` habla de fases y `next` |
| `SKILL.md` | Contrato en Factory (siete archivos + `docs/specs/` + `docs/brain/tasks/`); arranque `context` + `recall`; "abrir un proyecto sin `## Factory` → `migrate --factory` salvo `Mode: CLASSIC`"; ciclo de cierre con `retro` |
| `README.md` | Changelog "IA Factory mode"; tabla de comandos |
| `scripts/factory_dispatch.ps1` y `.sh` | Nuevos (4.9). Fuera del núcleo: solo leen la config, llaman a `project_docs` y lanzan las CLIs configuradas |
| `templates/dispatch.md`, `templates/dispatch-prompt.md` | Nuevos (4.9) |
| `.gitignore` del proyecto | `init`/`migrate --factory` agregan un bloque delimitado e idempotente con `.factory/state.md` y `.factory/runs/` (crean el archivo si no existe), igual que `link` con los archivos de agentes |
| `scripts/tests/fake_cli.sh` y `.ps1` | Nuevos: CLIs falsas para testear el dispatcher sin cuota real (sección 7) |
| `scripts/smoke_test.sh` | Casos de la sección 7 |
| `evals/evals.json` | Evals nuevos (sección 7); los que hoy afirman "exactly six files" corren con `init --classic` o se ajustan |
| `docs/*` de la skill | Dogfooding: Roadmap F06, ADR-023+, `BR` nuevos (abajo), Features vía `done` |

`BR` nuevos para `docs/ProductDescription.md` de la skill:

- `BR-008`: Sin sección `## Factory` (o con `Mode: CLASSIC`) los scripts se comportan exactamente como antes. Reformula BR-007 incluyendo Factory.
- `BR-009`: En Factory, ninguna tarea llega a `DONE` sin spec válido, evidencia RED (`exit` ≠ 0), evidencia GREEN (`exit=0`), tests intactos desde RED y review PASS de otro agente.
- `BR-010`: `recall` nunca supera `Recall budget bytes` y nunca corta una fila.
- `BR-011`: El brain nunca supera `Brain max entries` después de `rotate`.
- `BR-012`: Una tarea FAST nunca llega a `DONE` si su diff superó los límites del carril o tocó un path protegido.
- `BR-013`: El límite de cuota de un agente nunca bloquea una tarea: o la retoma el agente que lo cubre, o queda en `PAUSE LIMITE` retomable al vencer el cooldown.

---

## 6. Plan para el Roadmap de la skill

Cargá estas filas en `docs/Roadmap.md` de la skill **antes** de empezar
(`## Plan`, fase nueva `### F06 — IA Factory mode`). Copialas tal cual: los
`Name` tienen ≤ 10 palabras y ninguna celda lleva barras verticales. Acá van
las cuatro primeras columnas; completá cada fila con `TODO`, `—`, `—`, `—` en
`Status`, `Owner`, `Depends on`, `Pause reason`. Las dependencias entre tareas
las decidís vos al cargarlas (el orden de abajo es el sugerido).

**F06-E01 — Factory mode and autonomy policy**

| ID | Name | Description | Acceptance check |
|---|---|---|---|
| F06-E01-T01 | Detect factory mode from the AGENTS.md settings table | Parse the ## Factory table in sh and ps1; env PROJECT_DOCS_MODE overrides | Classic fixture output byte-identical to master scripts; factory fixture detected |
| F06-E01-T02 | Init defaults to factory and migrate adds it | init creates seven files plus folders; init --classic creates six; migrate --factory idempotent | Smoke cases pass in sh and ps1 |
| F06-E01-T03 | Compact factory rules and autonomy policy in template | Section 4.1 text; decisions section points to it in factory | Fresh factory project context at or below 6912 bytes |
| F06-E01-T04 | Add next command for autonomous task selection | Order and skips per section 4.3 | Smoke cases for every role return the expected ID |
| F06-E01-T05 | Enforce WIP and fix attempt limits in claim | D-13 and D-14 | Smoke cases refuse the claim with a clear message |

**F06-E02 — Spec and TDD production line**

| ID | Name | Description | Acceptance check |
|---|---|---|---|
| F06-E02-T01 | Spec template and check rules for scenarios | templates/Spec.md and check per section 4.4 | Invalid specs fail check; valid spec passes |
| F06-E02-T02 | Phase lines and advance command with gates | Section 4.3 table; writes ASSIGNED with Phase | Every gate has a passing and a failing smoke case |
| F06-E02-T03 | Phase roles in the roster and claim | D-05 roles; DEVELOPER alias of DEV | Role mismatch refused in factory and ignored in classic |
| F06-E02-T04 | Exit markers and immutable tests from RED sha | D-06 and D-07 including the no-git warning | Changing a recorded test after RED makes handoff fail |
| F06-E02-T05 | Turn review warnings into errors in factory | Self-review, close without PASS, empty verify | Same cases warn in classic and fail in factory |
| F06-E02-T06 | Fast lane with size limits and promotion to SPEC | Section 4.3.1; Lane and Base lines; BUG rows need a test file | Every fast lane limit has a passing and a failing smoke case |

**F06-E03 — Brain and context economy**

| ID | Name | Description | Acceptance check |
|---|---|---|---|
| F06-E03-T01 | Brain template and check validation | templates/Brain.md with seed rows; enums, LRN ids, cap | check fails on each invalid row kind |
| F06-E03-T02 | Working memory files and checkpoint command | docs/brain/tasks; pause and advance require Now | Smoke cases create, update and require the file |
| F06-E03-T03 | Recall command with deterministic ranking and budget | Algorithm in section 4.5 | Same bytes in sh and ps1; never above budget; whole rows only |
| F06-E03-T04 | Learn and retro commands with mandatory lessons | retro rules and done integration per section 4.5 | learned none refused after a FAIL; Hits updated on done |
| F06-E03-T05 | Brain garbage collection in rotate and promotion warning | Archive to 75 percent of cap with SHA-256 check | Over-cap fixture ends under cap; archive verified |

**F06-E04 — Digest and status**

| ID | Name | Description | Acceptance check |
|---|---|---|---|
| F06-E04-T01 | Digest command for asynchronous human review | Contents per section 4.7, at most 4 KiB | Fixture with every item kind lists them all |
| F06-E04-T02 | Show phase in status output | Factory only, phase and lane | Classic status unchanged byte for byte |
| F06-E04-T03 | Cross-model marker, default reviewers and audits | Section 4.8; handoff default reviewer by lane; AUDIT entries | Same-model review marked; audit never reopens a task |

**F06-E06 — CLI dispatcher**

| ID | Name | Description | Acceptance check |
|---|---|---|---|
| F06-E06-T01 | Dispatch config templates and gitignore block | templates/dispatch.md and dispatch-prompt.md; init and migrate add them | Idempotent on a second run; gitignore block not duplicated |
| F06-E06-T02 | Dispatcher loop in PowerShell with limit detection | Section 4.9 steps 1 to 6 | All dispatcher smoke cases pass through ps1 |
| F06-E06-T03 | Dispatcher loop in sh with identical behavior | Same as the PowerShell loop | Same logs and ledger results as ps1 on the same script |
| F06-E06-T04 | Fake CLIs and dispatcher smoke tests | scripts/tests fake_cli in sh and ps1 driven by a script file | Cases 18 to 25 of section 7 pass |

**F06-E05 — Docs, evals and dogfooding**

| ID | Name | Description | Acceptance check |
|---|---|---|---|
| F06-E05-T01 | Document factory mode across skill and references | Files in section 5 | Every new command documented in SKILL, README and workflow |
| F06-E05-T02 | Add factory evals and adjust six-file evals | Section 7 list | evals.json valid; each new eval maps to a smoke case |
| F06-E05-T03 | Dogfood a full factory lifecycle end to end | Section 8 | Section 9 checklist fully met |

---

## 7. Tests obligatorios

Cada caso, en sh **y** ps1 (la paridad de bytes se compara donde ya se hace hoy):

1. Proyecto clásico: `check`, `status`, `context`, `rotate` idénticos a los scripts de `master` sobre el mismo fixture (corrida diferencial, como en BR-007).
2. `init` por defecto → siete archivos + `## Factory` + carpetas; `init --classic` → seis.
3. `migrate --factory` dos veces → la segunda no cambia nada; nunca pisa contenido.
4. `claim` falla por WIP, por rol que no coincide con la fase y por intentos agotados.
5. `advance SPEC→RED` falla sin spec, con `UNKNOWN`, sin escenarios, con `NONE` sin justificación y sin review PASS de otro agente; pasa con todo en regla.
6. `advance RED→GREEN` falla con `exit=0` o sin `## Tests`; pasa con `exit=1` y registra `- Red:`.
7. `handoff` falla si cambió un test registrado desde el sha de RED (fixture con git); pasa si no cambió; sin git, WARN.
8. `handoff`/`done` en Factory fallan sin `exit=0`; self-review falla.
9. `checkpoint` crea y actualiza; `pause` en Factory falla sin `## Now`.
10. `learn` asigna el próximo `LRN-xxx`; rechaza `|`, Name largo y Kind inválido.
11. `retro` rechaza `learned none` después de un FAIL; `done` falla sin retro; `done` suma `Hits` y borra la memoria de trabajo.
12. `recall`: orden determinístico, dentro del presupuesto, solo filas enteras, mensaje `N of M`, error si las secciones 1–3 no entran.
13. `rotate` con brain sobre el tope → queda en el 75 %, archivo verificado; las `DEFAULT` con `*` no se archivan.
14. `check` en Factory: brain inválido, spec inválido, roster ausente → error; `Hits` ≥ 5 → WARN de promoción.
15. `next` devuelve la tarea correcta por rol y saltea `RED-LINE` y `BLOQUEO`.
16. `digest` lista cada tipo de ítem y no supera 4 KiB.
17. `context` de un proyecto Factory recién creado ≤ 6912 bytes (la sección Factory sola mide ~1,4 KiB; quedan 1,25 KiB de margen sobre 8 KiB).

Carril rápido y revisión cross-model:

18. FAST: `handoff` falla por demasiados archivos, demasiadas líneas, un path
    protegido y un BUG sin archivo de test; pasa dentro de los límites; sin
    git, WARN.
19. FAST que se pasa del carril: el mensaje es `task outgrew FAST lane` y el
    flujo de vuelta a SPEC deja `check` en verde.
20. `review` de un reviewer con el mismo `Model` que el holder escribe
    `- Cross-model: NO`; con otro modelo, no.
21. `handoff` sin reviewer usa `Preferred reviewer` en NORMAL y
    `Fallback reviewer` en FAST.

Dispatcher, con CLIs falsas (`fake_cli` lee de un archivo una acción por
corrida: `ok:<comando de project_docs>`, `limit:<texto>`, `fail`):

22. Traspaso: corrida de `claude-dev` hace `handoff` → la siguiente iteración
    lanza `gemini-qa` sobre la misma tarea, sin intervención.
23. Límite de Gemini (`RESOURCE_EXHAUSTED`) → cooldown del plan `gemini` →
    `claude-qa` revisa esa tarea → queda `Cross-model: NO`.
24. Límite de Claude (`You've hit your session limit · resets 3:45pm`) → todos
    los `claude-*` en cooldown hasta las 15:45 → `pause ... LIMITE` escrito
    para el dueño → con `PROJECT_DOCS_DISPATCH_NO_SLEEP=1` imprime
    `sleep until`. Al vencer, `next claude-dev` devuelve la tarea pausada.
25. Fallas: 2 fallas en una review → fallback; 3 fallas en una tarea propia →
    `pause BLOQUEO`; `Max runs per day` respetado; `.factory/STOP` detiene el
    loop; sin trabajo y con `Preferred reviewer` libre → corre la auditoría.

---

## 8. Dogfooding final

1. Proyecto temporal con `init` (Factory) y el roster de D-21: `claude-spec`,
   `claude-test`, `claude-dev`, `claude-qa` (Model Claude) y `gemini-qa`
   (Model Gemini). `Preferred reviewer` = `gemini-qa`, `Fallback reviewer` =
   `claude-qa`.
2. Todo lo que sigue corre **a través del dispatcher con CLIs falsas**, sin
   tocar comandos a mano: una tarea NORMAL con un test real mínimo (un script
   `sh` que hace `exit 1` en RED y `exit 0` en GREEN): SPEC → review de spec
   de `gemini-qa` → RED → GREEN → review FAIL → GREEN → límite de Gemini a
   mitad de camino → review PASS de `claude-qa` → retro con lección → done.
3. Una tarea FAST de punta a punta, y otra FAST que se pasa del carril y vuelve
   a SPEC.
4. Una red line: tarea pausada con `RED-LINE:`, `next` la saltea y `digest` la
   muestra.
5. Medí y anotá en el reporte: bytes de `context`, bytes de `recall`, filas de
   brain mostradas, corridas por agente y cuántas reviews hizo cada modelo.
6. Si en la máquina hay `claude` y `gemini` reales, una corrida `--once` real
   por cada uno sobre una tarea FAST trivial, para confirmar los flags. Si no
   hay, decilo en el reporte.
7. Proyecto clásico existente → `migrate --factory` → `check` pasa.
8. El repo de la skill adopta Factory mode: primero compactá su `## Active
   work` y summaries para que `context` quede ≤ 8 KiB con la sección nueva,
   después `migrate --factory`, y que `check .` pase.

---

## 9. Definition of Done

- [ ] Todas las filas F06 en `DONE` (en `Features.md` vía `done`), sin `PAUSE`
      abiertas salvo `BLOQUEO` documentados con su `Fxx-GAP`.
- [ ] `sh scripts/smoke_test.sh` → 0 failed, más de 290 casos; los casos ps1
      corrieron (si no hay `pwsh` en el entorno, decilo en el reporte y dejá
      `Fxx-DEBT` para correrlos en Windows).
- [ ] `sh scripts/project_docs.sh check .` pasa en el repo de la skill.
- [ ] `evals/evals.json` es JSON válido y suma los evals nuevos.
- [ ] Corrida diferencial del modo clásico idéntica a `master`.
- [ ] Mediciones de la sección 8 dentro de los presupuestos.
- [ ] El dogfooding de la sección 8 corrió entero a través del dispatcher, sin
      comandos a mano, incluido el límite de Gemini cubierto por `claude-qa`.
- [ ] ADR-023+ (una por cada D-01 a D-21) y BR-008 a BR-013 registrados;
      `## Out of scope` actualizado (memoria externa, embeddings, correr CLIs
      en paralelo).
- [ ] Rama `feat/ia-factory` pusheada y PR abierto con el reporte final.

---

## 10. Prohibido

- Bajar la línea de base de tests, saltear casos o marcarlos como skip para
  que pase.
- Agregar dependencias (Python, Node, jq, curl, servicios) o meter YAML/JSON en
  archivos de contrato. El dispatcher solo puede lanzar las CLIs que figuran
  en `.factory/dispatch.md`.
- Usar API keys o `claude --bare`: los agentes corren con el login de la
  suscripción de cada CLI.
- Gastar cuota real de Claude o Gemini en los tests: el dispatcher se prueba
  con CLIs falsas.
- Romper la paridad sh/ps1 o dejar un comando solo en uno de los dos.
- Cambiar estados del ledger o columnas del Roadmap.
- Relajar `check` para que un caso pase.
- Tocar `master` directamente, hacer force-push o reescribir historia.
- Inventar lo que no está decidido: si no es reversible, `Fxx-GAP` + `BLOQUEO`
  y seguí con otra fila.
