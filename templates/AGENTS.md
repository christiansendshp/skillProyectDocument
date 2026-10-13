## Repository rules

- Scope: all AI agents and contributors in this repository.
- Work branch: `UNKNOWN` — confirm from repository or user instructions.
- Approval boundaries: follow the active runtime and repository instructions.
- Never expose secrets or real environment values in documentation.
- Treat `UNKNOWN` and `HYPOTHESIS` as unresolved, not as facts.
- **No agent writes a single line of code before checking the `BR-xxx` rules
  in `docs/ProductDescription.md` and the constraints in
  `docs/Stack_Tecnologies.md`.** A change that contradicts a `CONFIRMED` rule
  or constraint is a bug, not a judgment call.
- Every new task or action is added to `docs/Roadmap.md` with an ID before
  it is executed. No agent works on anything without an ID.
- This file is the single rules source; `CLAUDE.md`, `.cursorrules` and other
  agent files only point here, and on conflict this file prevails.

## Startup

In order, skipping nothing:

1. Read this file completely.
2. Run `context` (at most 8 KiB: this file, `## Active work`, open tasks, the
   five latest Agentslog entries).
3. `claim <agent> <task-id> <summary>` the task you will work on, adding its
   Roadmap row first if it has no ID.
4. Develop, reading full `ProductDescription.md`, `Stack_Tecnologies.md`,
   `Roadmap.md#Plan` or `Features.md` only when the task needs it.
5. Validate with `check`. Do not report completion while it fails.
6. Close with `done <agent> <task-id> <summary> <files> <verify>`.

## Taking a task

1. Prefer a row already in `## Active work`/`## Near term`, or the next
   eligible `TODO` row in `## Plan` under the highest-priority open Epic,
   unless the user names another task.
2. New work: add a row first (`## Plan` or `## Gaps, Bugs & Technical Debt`)
   with a `Name` (<= 10 words, descriptive) and the rest in `Description`.
   `claim`/`pause`/`done` refuse a missing or too-long Name and copy it into
   the Agentslog entry; never retype it (`references/workflow.md`).
3. `claim` fails on another agent's non-stale `IN_PROGRESS`, or a `PAUSE` only
   that agent can resolve. Owner is written as `<agent>@<timestamp>`.
4. To stop early: `pause <agent> <task-id> <category> "<detail>"` (`LIMITE`,
   `ESPERA_RESPUESTA`, `BLOQUEO`, `OTRO`); keep the Acceptance check accurate
   so another agent can resume cold.
5. Close only when the Acceptance check is actually met. A placeholder
   (`UNKNOWN`/`—`) Acceptance check cannot honestly be marked done.

## Technical and product decisions

- Durable technical decisions go in `docs/Stack_Tecnologies.md` as an
  `ADR-xxx` row; decide yourself only if reversible and implementation-scoped.
- Escalate to the human when a choice affects product behavior, cost,
  security or an external commitment; record the outcome either way.
- A significant question that blocks a task goes in
  `## Gaps, Bugs & Technical Debt`, referenced from the task's Depends on
  cell; never silently work around it.

## Close

1. Update only the project truths the change affects.
2. Use `claim`/`pause`/`done` for task state, `append-log` only outside the
   lifecycle.
3. Run `rotate`, then `check`. Do not report completion while it fails.

## Multi-agent coordination

- `docs/Agentslog.md` is the source of truth for who holds a task and wins
  over a Roadmap row's Status/Owner cells.
- Do not modify work another agent actively holds without coordinating.

## Agent identity

One stable id per agent, always the same text; aliases match case-insensitively.
Kind: HUMAN or AI. Role: DEVELOPER, QA or BOTH. No rows, no checks.

| Agent id | Kind | Model | Role | Aliases |
|---|---|---|---|---|
| — | — | — | — | — |

## Project conventions

- Code style: `UNKNOWN` — infer from checked-in configuration.
- Test command: `UNKNOWN` — record the confirmed command in Stack.
- Documentation language: match the project unless the user specifies one.
