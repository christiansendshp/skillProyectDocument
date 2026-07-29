---
name: project-documentation
description: >-
  Initialize and maintain a compact six-file project memory for AI-assisted
  software work. Use whenever an agent creates, opens, scaffolds, implements,
  fixes, refactors, or otherwise changes a project, even when documentation is
  not requested. Create missing project documents before coding, load only the
  bounded task-relevant context, record each logical change, and validate the
  documentation before closing the task.
---

# Project Documentation

Maintain a small, durable project memory without loading the full history into
every agent turn.

## Contract

Keep these exact files in `<project>/docs/`:

- `Agents.md`: repository rules and context-loading policy.
- `Agentslog.md`: recent append-only work ledger.
- `ProductDescription.md`: current functional truth.
- `Stack_Tecnologies.md`: current technical truth. The misspelling is retained
  for backward compatibility.
- `Roadmap.md`: active and near-term work only.
- `Features.md`: compact index of verified capabilities.

Projects may contain any additional files. Put cold history under
`docs/history/` and detailed feature material under `docs/features/`; do not
load those folders unless the current task needs them.

## Start every project or session

1. Locate the project root. Prefer the runtime-native launcher:
   - POSIX: `sh <skill>/scripts/project_docs.sh init <project>`
   - PowerShell: `& <skill>/scripts/project_docs.ps1 init <project>`
2. Run `context` with the same launcher. Keep its output at or below 8 KiB.
3. Read the complete `docs/Agents.md`, the active Roadmap rows, and at most the
   five latest log entries included by `context`.
4. Read Product, Stack, or Features beyond their short summaries only when the
   task changes or depends on functional, technical, or verification details.
5. Mark a Roadmap item `IN_PROGRESS` before implementation when multiple agents
   may work concurrently.

Never block an unrelated small task merely to fill unknown documentation.
Represent missing knowledge explicitly as `UNKNOWN` or `HYPOTHESIS`, including
a source or verification step. Never present inference as confirmed fact.

## Close each logical change

1. Update only the documents affected by the change:
   - functional truth -> `ProductDescription.md`
   - technical truth or decision -> `Stack_Tecnologies.md`
   - active work state -> `Roadmap.md`
   - verified capability -> `Features.md`
2. Append one compact ledger entry for the logical change. Prefer `append-log`;
   keep the entry under six lines and roughly 700 characters.
3. Run `rotate`. It archives and verifies an oversized ledger before resetting
   the hot log.
4. Run `check`. Do not report completion while it fails.

Do not duplicate implementation detail already discoverable in code, tests,
commits, or issues. Record stable facts, decisions, verification commands,
task state, and pointers to authoritative artifacts.

## Compatibility

The canonical skill name is `project-documentation`. Accept the legacy
installation folder `skillProyectDocument` during transition. Do not create two
active copies of the skill.

Use `references/workflow.md` for edge cases and command details. Read
`references/adapters.md` only when installing or updating a runtime adapter.
