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

Every contract file is plain, structured Markdown — tables and bulleted
lists, never YAML or JSON — so line-based tools (`sed`, `awk`, diff/patch)
never misparse an indentation-sensitive block. Keep these exact files:

- `AGENTS.md` (project root): repository rules, context-loading policy, and
  the task-taking protocol. The single rules source every runtime reads.
- `docs/Agentslog.md`: append-only ledger and source of truth for task
  ownership.
- `docs/ProductDescription.md`: current functional truth, `BR-xxx` business
  rules, and an explicit `## Out of scope` list.
- `docs/Stack_Tecnologies.md`: current technical truth, `ADR-xxx` decisions,
  and critical commands. The misspelling is retained for backward
  compatibility.
- `docs/Roadmap.md`: `## Active work`/`## Near term`/`## Plan` (hierarchical
  work: PHASE -> EPIC -> TASK -> SUBTASK, with optional THEME/FEATURE
  heading levels) and `## Gaps, Bugs & Technical Debt` (unforeseen work,
  IDs `Fxx-GAP-xx`/`Fxx-BUG-xx`/`Fxx-DEBT-xx`) as Markdown tables — see
  `references/workflow.md`.
- `docs/Features.md`: compact index of verified capabilities.

`ProductDescription.md`, `Stack_Tecnologies.md`, and `Roadmap.md` each carry
a dense `## Operational summary`/`## Active work` block closed by
`<!-- context:end -->`; only that block is hot context. Every fact-table
`Status` column in Product/Stack is epistemic — exactly `CONFIRMED`,
`HYPOTHESIS`, or `UNKNOWN` — a different axis from the workflow `Status`
(`TODO`/`IN_PROGRESS`/`PAUSE`/`DONE`) in Roadmap's work-item tables. Every
Roadmap row's `Name` is a short, descriptive title of 10 words or fewer; the
rest of the detail goes in `Description` (or the row's own free-text
column). `claim`/`pause`/`done` refuse a row whose Name is missing or too
long, and copy it verbatim into the matching Agentslog entry, so the log
always names a task the same way the Roadmap does.

**No agent writes a single line of code before checking the `BR-xxx` rules
in `ProductDescription.md` and the constraints in `Stack_Tecnologies.md`.**

Projects may contain any additional files. Put cold history under
`docs/history/` and detailed feature material under `docs/features/`; do not
load those folders unless the current task needs them.

## Start every project or session

1. Locate the project root. Prefer the runtime-native launcher:
   - POSIX: `sh <skill>/scripts/project_docs.sh init <project>`
   - PowerShell: `& <skill>/scripts/project_docs.ps1 init <project>`
   `init` also runs `link`, which points other agent files (`CLAUDE.md`,
   `.cursorrules`, etc.) at `AGENTS.md` without overwriting their content. If
   the project still has `docs/Agents.md` or a Roadmap in the old per-entry
   YAML format, run `migrate` first.
2. Run `context` with the same launcher. Keep its output at or below 8 KiB.
3. Read the complete `AGENTS.md`, the `## Active work` table, every open task
   (`IN_PROGRESS`/`PAUSE`), and the five latest log entries — all included by
   `context`.
4. `claim <agent> <task-id> <summary>` the task before developing it. It
   fails if another agent already owns the task.
5. Develop, reading full Product, Stack, `Roadmap.md`'s `## Plan`, or
   Features beyond their short summaries only when the task changes or
   depends on functional, technical, or verification details.
6. Validate with `check`; close with `done` (see below). Do not report
   completion while `check` fails.

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
