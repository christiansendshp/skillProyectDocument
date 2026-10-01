<!-- project-documentation:start -->
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
- This file is the single rules source. Other agent files in this repository
  (`CLAUDE.md`, `.cursorrules`, etc.) only point here; on conflict this file
  prevails.

## Startup

Follow this sequence in order; do not skip a step:

1. Read this file completely.
2. Run `context` (stays at or below 8 KiB: this file, `## Active work`, every
   open task `IN_PROGRESS`/`PAUSE`, and the five latest Agentslog entries).
3. `claim <agent> <task-id> <summary>` the task you'll work on — from
   `## Active work`/`## Near term`/`## Plan`/`## Gaps, Bugs & Technical Debt`
   in `docs/Roadmap.md`, or a new row you add first if it has no ID yet.
4. Develop, reading full `ProductDescription.md`, `Stack_Tecnologies.md`,
   `Roadmap.md#Plan`, or `Features.md` only when the task needs it.
5. Validate with `check`. Do not report completion while `check` fails.
6. Close with `done <agent> <task-id> <summary> <files> <verify>`.

## Taking a task

1. Prefer a `docs/Roadmap.md` row already in `## Active work`/`## Near term`,
   or the next eligible `TODO` row in `## Plan` under the highest-priority
   open Epic, unless the user names a different task.
2. New work with no ID: add a `docs/Roadmap.md` row first (`## Plan` or
   `## Gaps, Bugs & Technical Debt`) before touching code. Give it a `Name`
   (<= 10 words, descriptive); put the rest in `Description`.
   `claim`/`pause`/`done` refuse a missing or too-long Name and copy it into
   the Agentslog entry — never retype a task's name by hand (details:
   `references/workflow.md`).
3. `claim` fails on another agent's non-stale `IN_PROGRESS`, or a `PAUSE`
   only that agent can resolve. It writes Owner as `<agent>@<timestamp>`.
4. To stop before finishing: `pause <agent> <task-id> <category> "<detail>"`
   (`LIMITE`, `ESPERA_RESPUESTA`, `BLOQUEO`, `OTRO`). Leave the row's
   Acceptance check cell accurate so another agent can resume cold.
5. Close only once the Acceptance check is actually met — not merely
   attempted — with `done <agent> <task-id> <summary> <files> <verify>`. A
   placeholder (`UNKNOWN`/`—`) Acceptance check cannot honestly be marked
   done; fill it in by hand first.

## Technical and product decisions

- Durable technical decisions go in `docs/Stack_Tecnologies.md` as a new
  `ADR-xxx` row — decide it yourself only if reversible and scoped to
  implementation detail.
- Escalate to the human when the choice affects product behavior, cost,
  security, or an external commitment; record the outcome either way.
- A significant unresolved question that blocks a task: record it in
  `## Gaps, Bugs & Technical Debt`, referenced from the blocked task's
  Depends on cell; never silently work around it.

## Close

1. Update only the project truths affected by the change.
2. Use `claim`/`pause`/`done` to record task state; `append-log` only for
   entries outside the task lifecycle.
3. Run `rotate`, then `check`. Do not report completion while `check` fails.

## Multi-agent coordination

- `docs/Agentslog.md` is the source of truth for who currently holds a task;
  a Roadmap row's Status/Owner cells track its latest state, but the log
  wins on conflict.
- Do not modify work actively owned by another agent without coordinating.

## Project conventions

- Code style: `UNKNOWN` — infer from checked-in configuration.
- Test command: `UNKNOWN` — record the confirmed command in Stack.
- Documentation language: match the project unless the user specifies one.
<!-- project-documentation:end -->
