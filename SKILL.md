---
name: project-documentation
description: >-
  Initialize and maintain a compact project memory for AI-assisted software
  work, and coordinate task ownership across multiple agents (Claude Code,
  Codex, OpenCode, Antigravity, others). Use whenever an agent creates, opens,
  scaffolds, implements, fixes, refactors, or otherwise changes a project, or
  when the user asks to build a new app, system, or product, even when
  documentation is not requested. Create missing project documents before
  coding, load only the bounded task-relevant context, claim work before
  starting it, record each logical change, and validate the documentation
  before closing the task.
---

# Project Documentation

Maintain a small, durable project memory without loading the full history into
every agent turn, and let every agent take tasks without overlapping.

## Contract

Keep these exact files:

- `AGENTS.md` (project root): repository rules, context-loading policy, and
  the task-taking protocol. The single rules source every runtime reads.
- `docs/Agentslog.md`: append-only ledger and source of truth for task
  ownership.
- `docs/ProductDescription.md`: current functional truth.
- `docs/Stack_Tecnologies.md`: current technical truth. The misspelling is
  retained for backward compatibility.
- `docs/Roadmap.md`: active work, the full pending plan, and gaps/defects.
- `docs/Features.md`: compact index of verified capabilities.

Projects may contain any additional files. Put cold history under
`docs/history/` and detailed feature material under `docs/features/`; do not
load those folders unless the current task needs them.

## Start every project or session

1. Locate the project root. Prefer the runtime-native launcher:
   - POSIX: `sh <skill>/scripts/project_docs.sh init <project>`
   - PowerShell: `& <skill>/scripts/project_docs.ps1 init <project>`
   `init` also runs `link`, which points other agent files (`CLAUDE.md`,
   `.cursorrules`, etc.) at `AGENTS.md` without overwriting their content. If
   the project still has `docs/Agents.md`, run `migrate` first.
2. Run `context` with the same launcher. Keep its output at or below 8 KiB.
3. Read the complete `AGENTS.md`, the active Roadmap rows, every open task
   (`IN_PROGRESS`/`PAUSE`), and the five latest log entries — all included by
   `context`.
4. Read Product, Stack, `Roadmap.md`'s `## Plan`, or Features beyond their
   short summaries only when the task changes or depends on functional,
   technical, or verification details.
5. Add any new user-requested task to the Roadmap with an ID before executing
   it, then `claim <agent> <task-id> <summary>`. It fails if another agent
   already owns the task.

Never block an unrelated small task merely to fill unknown documentation.
Represent missing knowledge explicitly as `UNKNOWN` or `HYPOTHESIS`, including
a source or verification step. Never present inference as confirmed fact.

## Building a new app or product

When the user asks to create a new app, system, or product: run `init` (and
`migrate` if needed), fill Product and Stack from the request, ask only what's
missing using `references/intake.md`, build the full `## Plan` in the Roadmap
from the answers, then `claim` the first task. See `references/workflow.md`
for the detailed flow.

## Close each logical change

1. Update only the documents affected by the change:
   - functional truth -> `ProductDescription.md`
   - technical truth or decision -> `Stack_Tecnologies.md`
   - verified capability -> `Features.md` (via `done`)
2. If you must stop before finishing, `pause <agent> <task-id> <category>
   <detail>` (category: `LIMITE`, `ESPERA_RESPUESTA`, `BLOQUEO`, or `OTRO`).
   Otherwise `done <agent> <task-id> <summary> <files> <verify>` — it records
   the capability and clears the task from the Roadmap. Use `append-log` only
   for entries outside the claim lifecycle.
3. Run `rotate`. It archives and verifies an oversized ledger before resetting
   the hot log, carrying forward any still-open task.
4. Run `check`. Do not report completion while it fails.

Do not duplicate implementation detail already discoverable in code, tests,
commits, or issues. Record stable facts, decisions, verification commands,
task state, and pointers to authoritative artifacts.

## Compatibility

The canonical skill name is `project-documentation`. Accept the legacy
installation folder `skillProyectDocument` during transition. Do not create two
active copies of the skill.

Use `references/workflow.md` for edge cases and command details,
`references/intake.md` when starting a new app or product, and
`references/adapters.md` only when installing or updating a runtime adapter.
