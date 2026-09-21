# project-documentation

Compact, coordinated project memory for AI coding agents. It creates six
stable files at project initialization, keeps startup context bounded while
preserving cold history, and lets multiple agents (Claude Code, Codex,
OpenCode, Antigravity, others) take tasks without overlapping.

The repository name and legacy installation folder `skillProyectDocument`
remain supported during transition. The canonical skill name is
`project-documentation`.

## Contract files

Every project receives these exact files:

| File | Compact responsibility |
|---|---|
| `AGENTS.md` (project root) | Rules, selective-reading policy, task-taking protocol |
| `docs/Agentslog.md` | Append-only ledger; source of truth for task ownership |
| `docs/ProductDescription.md` | Current functional truth |
| `docs/Stack_Tecnologies.md` | Current technical truth; legacy spelling retained |
| `docs/Roadmap.md` | Hierarchical plan (Markdown tables) + Gaps/Bugs/Technical Debt |
| `docs/Features.md` | Index of verified capabilities |

Additional detail may live under `docs/features/`, `docs/decisions/`, or
`docs/history/` and is loaded only when referenced by the current task.

## Commands

POSIX:

```sh
sh scripts/project_docs.sh init /path/to/project
sh scripts/project_docs.sh context /path/to/project
sh scripts/project_docs.sh check /path/to/project
```

PowerShell:

```powershell
& scripts/project_docs.ps1 init C:\path\to\project
& scripts/project_docs.ps1 context C:\path\to\project
& scripts/project_docs.ps1 check C:\path\to\project
```

Both launchers also provide:

| Command | Purpose |
|---|---|
| `link [--create <list>]` | Point other agent files (`CLAUDE.md`, `.cursorrules`, ...) at `AGENTS.md`; run automatically at the end of `init` |
| `migrate` | Merge a legacy `docs/Agents.md` into root `AGENTS.md`, fix a root case-only filename, add missing `Roadmap.md` sections, convert a per-entry YAML Roadmap back to tables — idempotent |
| `claim <agent> <task-id> <summary>` | Take a Roadmap task; fails if another agent already owns it |
| `pause <agent> <task-id> <category> <detail>` | Release a task (`LIMITE`\|`ESPERA_RESPUESTA`\|`BLOQUEO`\|`OTRO`) |
| `done <agent> <task-id> <summary> <files> <verify>` | Close a task, record it in `Features.md`, clear it from the Roadmap |
| `status` | List every open (`IN_PROGRESS`/`PAUSE`) task, owner, age, reason |
| `append-log` | Manual/legacy ledger entry outside the claim lifecycle |
| `rotate` | Archive an oversized ledger, hash-verified, carrying open tasks forward |

Initialization is idempotent and never overwrites existing content —
`AGENTS.md` gets the skill's rules inserted in a delimited block on first run
and is left untouched afterward. `context` emits at most 8 KiB, including
every open task. The hot log rotates after 200 entries or 128 KiB.

`PROJECT_DOCS_STALE_HOURS` (default `24`) overrides how long an unattended
`IN_PROGRESS` claim is considered abandoned and reclaimable.

## Changelog

- **Markdown hardening**: reverted `docs/Roadmap.md` to pure Markdown
  tables (superseding the per-entry YAML schema below) — zero YAML/JSON in
  any contract file, so line-based tools never misparse an
  indentation-sensitive block. Added canonical IDs (`BR-xxx` business
  rules, `ADR-xxx` technical decisions, `Fxx-GAP-xx`/`Fxx-BUG-xx`/
  `Fxx-DEBT-xx` gaps/bugs/debt), a strict epistemic `Status` enum
  (`CONFIRMED`/`HYPOTHESIS`/`UNKNOWN`) on every fact table distinct from
  Roadmap's workflow `Status` (`TODO`/`IN_PROGRESS`/`PAUSE`/`DONE`),
  `## Out of scope` sections, and a `check` that validates required table
  headers, the `<!-- context:end -->` delimiter, ID format, and both
  `Status` vocabularies. `migrate` converts a YAML-format Roadmap back to
  tables non-destructively. `claim` now inserts the moved row as the last
  row of the `## Active work` table and removes the empty-table placeholder
  (it used to land below the blank line, detached from the table, which broke
  Markdown rendering). This repository's own `docs/` were migrated to the new
  format.
- **Human + AI Roadmap schema** (2026-09, superseded above): `docs/Roadmap.md`
  briefly moved from Markdown tables to a per-entry `### TYPE-ID — Title` +
  fenced `yaml` block format with a full type taxonomy and explicit
  dependencies/blockers/decisions. Reverted after `check`'s
  indentation-sensitive parsing proved too fragile for line-based tooling.
- **Multi-agent coordination protocol**: single root `AGENTS.md` (replaces
  `docs/Agents.md`), `link`/`migrate` commands, `claim`/`pause`/`done`/`status`
  task lifecycle backed by the Agentslog, `Roadmap.md` `## Plan` +
  `## Gaps, Bugs & Technical Debt`, `references/intake.md`, and an extended
  `check`.

See `SKILL.md` for the agent workflow, `references/workflow.md` for command
detail, `references/intake.md` for the new-app questionnaire, and
`references/adapters.md` for runtime installation.
