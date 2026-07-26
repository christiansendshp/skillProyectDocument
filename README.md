# skillProyectDocument

**Una skill que crea 6 archivos básicos de documentación para el desarrollo de
apps con agentes de IA en forma colaborativa.**

Es portable y agnóstica de lenguaje y framework: **obliga** a cualquier agente
(Claude Code, Codex, OpenCode, Antigravity) a crear y mantener esos 6 documentos
—antes de escribir código y después de cada cambio— para que varios agentes puedan
trabajar sobre el mismo proyecto sin pisarse, con trazabilidad y decisiones registradas.

## Los 6 documentos (en `docs/`, nombres exactos)

| Archivo | Rol |
|---|---|
| `Agents.md` | Reglas de operación para los agentes del repo. |
| `Agentslog.md` | Bitácora append-only; una entrada por cada cambio de código. |
| `ProductDescription.md` | El producto en términos funcionales (cero tecnología). |
| `Stack_Tecnologies.md` | Stack, arquitectura y decisiones técnicas. |
| `Roadmap.md` | Único lugar donde vive el trabajo pendiente (IDs `F01-S02-T03`). |
| `Features.md` | Catálogo de lo ya implementado y testeado. |

## Estructura de la skill

```
skillProyectDocument/
├── README.md               # este archivo
├── SKILL.md                # entrada canónica (Agent Skills / Claude Code)
├── templates/              # los 6 documentos con placeholders
├── references/             # workflow.md (protocolo) + adapters.md (instalación)
├── scripts/                # init_docs.sh (crea) + check_docs.sh (valida)
└── adapters/               # entradas delgadas por runtime -> apuntan a SKILL.md
```

## Uso directo de los scripts

```sh
# Crear los 6 documentos en un proyecto (idempotente, no pisa lo existente)
sh scripts/init_docs.sh /ruta/al/proyecto

# Validar existencia + secciones mínimas (exit 0 = OK, 1 = falta algo)
sh scripts/check_docs.sh /ruta/al/proyecto
```

## Instalación por runtime

Suponiendo que copiaste (o clonaste) `skillProyectDocument/` dentro del repo del
proyecto. Detalle en `references/adapters.md`.

### Claude Code
```sh
mkdir -p .claude/skills && cp -r skillProyectDocument .claude/skills/ && cp skillProyectDocument/adapters/CLAUDE.md ./CLAUDE.md
```

### Codex
```sh
cp skillProyectDocument/adapters/AGENTS.md ./AGENTS.md
```

### OpenCode
```sh
cp skillProyectDocument/adapters/AGENTS.md ./AGENTS.md && cp skillProyectDocument/adapters/opencode.json ./opencode.json
```

### Antigravity
```sh
mkdir -p .antigravity && cp skillProyectDocument/adapters/.antigravity/rules.md .antigravity/rules.md
```

> Si el proyecto ya tiene `CLAUDE.md` / `AGENTS.md` / reglas propias, **no las
> reemplaces**: agregá la sección "Documentación obligatoria" del adapter y dejá el
> resto intacto.

## Cómo funciona

1. El agente recibe un pedido de crear/modificar código.
2. El adapter del runtime dispara la lectura de `SKILL.md`.
3. La skill obliga a: crear/leer los 6 documentos → codear → actualizar los
   documentos → escribir en `Agentslog.md` → `check_docs.sh` verde. Sin eso, la
   tarea no se da por cerrada.
