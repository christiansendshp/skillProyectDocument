# Runtime adapters

Install the skill once with canonical folder name `project-documentation`.
Accept `skillProyectDocument` as a legacy folder during transition, but never
load both copies.

The rules source is a single root `AGENTS.md`, read directly by Codex and
OpenCode. Every other runtime's own file (`CLAUDE.md`, `.cursorrules`, etc.)
gets a short redirect block pointing at it, installed by `link`.

| Runtime | Thin entry point |
|---|---|
| Claude Code | `.claude/skills/project-documentation/SKILL.md` plus a `CLAUDE.md` block importing `@AGENTS.md` |
| Codex | installed skill plus root `AGENTS.md` directly |
| OpenCode | root `AGENTS.md`, configured as the sole instruction source (`adapters/opencode.json`) |
| Antigravity | `.antigravity/rules.md` block pointing at `AGENTS.md` |
| Gemini, Cursor, Windsurf, Cline, Copilot | `GEMINI.md` / `.cursorrules` / `.windsurfrules` / `.clinerules` / `.github/copilot-instructions.md` block pointing at `AGENTS.md` |

Adapters intentionally contain only these operations: `init`, `context`,
`link`, `migrate`, `claim`, `pause`, `done`, `status`, `append-log`, and
`rotate`, plus `check`. `SKILL.md` remains the canonical workflow; adapters
must not inline the full reference material.

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

Use the same launcher for every other command (`link`, `migrate`, `claim`,
`pause`, `done`, `status`, `append-log`, `rotate`, `check`).

## Merge, do not overwrite

`AGENTS.md`: if the target already has one with user content, `init`/`migrate`
insert the skill's rules inside a delimited, idempotent block
(`<!-- project-documentation:start -->` ... `:end -->`) and preserve the rest
byte for byte; they never overwrite it wholesale.

Other agent files (`CLAUDE.md`, `.cursorrules`, OpenCode instructions,
Antigravity rules, etc.): `link` merges the same kind of short delimited block
— just a pointer to `AGENTS.md`, not the full rules — and leaves the rest of
the file untouched. It never creates a file that doesn't already exist unless
asked explicitly (`link --create <list>`).

The legacy `init_docs.sh` and `check_docs.sh` wrappers remain available for
existing automation. New integrations should call `project_docs.sh` or
`project_docs.ps1`.
