# Runtime adapters

Install the skill once with canonical folder name `project-documentation`.
Accept `skillProyectDocument` as a legacy folder during transition, but never
load both copies.

| Runtime | Thin entry point |
|---|---|
| Claude Code | `.claude/skills/project-documentation/SKILL.md` plus merged `CLAUDE.md` block |
| Codex | installed skill plus merged root `AGENTS.md` block |
| OpenCode | merged root `AGENTS.md`; configure it as the sole instruction source |
| Antigravity | merged `.antigravity/rules.md` block |

Adapters intentionally contain only four operations: `init`, `context`,
`append-log`, and `rotate` plus `check`. `SKILL.md` remains the canonical
workflow; adapters must not inline the full reference material.

## Launchers

POSIX:

```sh
sh path/to/project-documentation/scripts/project_docs.sh init .
sh path/to/project-documentation/scripts/project_docs.sh context .
```

PowerShell:

```powershell
& path\to\project-documentation\scripts\project_docs.ps1 init .
& path\to\project-documentation\scripts\project_docs.ps1 context .
```

Use `append-log`, `rotate`, and `check` with the same launcher.

## Merge, do not overwrite

If the target already has `AGENTS.md`, `CLAUDE.md`, OpenCode instructions, or
Antigravity rules, merge the compact adapter block. Preserve existing
repository instructions and approval boundaries.

The legacy `init_docs.sh` and `check_docs.sh` wrappers remain available for
existing automation. New integrations should call `project_docs.sh` or
`project_docs.ps1`.
