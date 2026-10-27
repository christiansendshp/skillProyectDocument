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
`link`, `migrate`, `claim`, `pause`, `handoff`, `review`, `assign`, `done`,
`status`, `append-log`, and `rotate`, plus `check`; in Factory mode also `next`
and `recall` at the start, and `checkpoint`, `advance`, `learn`, `retro` and
`digest` as the task goes. `SKILL.md` remains the canonical workflow; adapters
must not inline the full reference material.

The dispatcher (`scripts/factory_dispatch.sh` or `.ps1`) is not an adapter: it
runs the CLI of each agent listed in `.factory/dispatch.md` (for example `claude -p`
and `gemini -p`, never `claude --bare`) so that CLIs that cannot call each other
take turns through the ledger. Give each CLI the agent id of its row.

## One agent id per runtime

Every runtime must pass the same text as the `<agent>` argument in every
session, and must not invent one each time: the ledger compares names by exact
equality, so `claude-sonnet-5` and `claude-sonnet-5-5` are two different
agents. List the ids (and the aliases a runtime may still use) in the optional
`## Agent identity` table of the project `AGENTS.md`; the commands then
normalise an alias to its id and `check` warns about unknown names. Put the
id in the runtime's own redirect file or settings so it survives a restart.

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
`pause`, `handoff`, `review`, `assign`, `done`, `status`, `append-log`,
`rotate`, `check`, and in Factory mode `mode`, `next`, `checkpoint`, `advance`,
`recall`, `learn`, `retro`, `digest`).

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
