# adapters.md — cómo se instala en cada runtime

La skill vive **una sola vez** en `skillProyectDocument/`. Cada runtime la
consume vía un archivo de entrada delgado que **apunta** a `SKILL.md`, sin
duplicar contenido. Si un runtime no soporta "skills", su adapter incluye el
protocolo completo en línea (es autosuficiente).

| Runtime | Punto de entrada | Nota |
|---|---|---|
| Claude Code | `.claude/skills/skillProyectDocument/SKILL.md` + `CLAUDE.md` | `CLAUDE.md` referencia la skill |
| Codex | `AGENTS.md` en la raíz | Cargado automáticamente |
| OpenCode | `AGENTS.md` + `opencode.json` | Mismo `AGENTS.md` que Codex |
| Antigravity | `.antigravity/rules.md` | Reglas persistentes del workspace |

Cada adapter contiene, como mínimo: la regla dura ("antes de codear, leé los 6
archivos; después de codear, actualizalos"), la lista de los 6 archivos, y un
puntero explícito a `SKILL.md`.

## Claude Code

Copiar la skill dentro del repo del proyecto:

```sh
mkdir -p .claude/skills
cp -r /ruta/a/skillProyectDocument .claude/skills/skillProyectDocument
cp /ruta/a/skillProyectDocument/adapters/CLAUDE.md ./CLAUDE.md   # o mergear si ya existe
```

Claude Code autodescubre `.claude/skills/*/SKILL.md`. El `CLAUDE.md` en la raíz
refuerza el trigger para que la skill se dispare aunque el pedido no mencione docs.

## Codex

```sh
cp /ruta/a/skillProyectDocument/adapters/AGENTS.md ./AGENTS.md   # o mergear
```

Codex carga `AGENTS.md` de la raíz automáticamente. El adapter es autosuficiente:
trae el protocolo completo, así no depende de soporte de skills.

## OpenCode

```sh
cp /ruta/a/skillProyectDocument/adapters/AGENTS.md ./AGENTS.md
cp /ruta/a/skillProyectDocument/adapters/opencode.json ./opencode.json   # o mergear
```

OpenCode usa el mismo `AGENTS.md` que Codex y respeta `opencode.json` para
instrucciones y permisos (p.ej. permitir `git mv`, pedir confirmación en deploy).

## Antigravity

```sh
mkdir -p .antigravity
cp /ruta/a/skillProyectDocument/adapters/.antigravity/rules.md .antigravity/rules.md
```

`.antigravity/rules.md` son reglas persistentes del workspace; el adapter incluye
el protocolo completo en línea.

## Convivencia con instrucciones existentes

Si el proyecto ya tiene `CLAUDE.md` / `AGENTS.md` / reglas propias, **no las pises**:
agregá una sección "Documentación obligatoria (skillProyectDocument)" con la regla
dura y el puntero a `SKILL.md`. La skill complementa, no reemplaza, las reglas del repo.
