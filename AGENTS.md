<!-- project-documentation:start -->
## Repository rules

- Scope: all AI agents and contributors in this repository.
- Work branch: `UNKNOWN` — confirm from repository or user instructions.
- Approval boundaries: follow the active runtime and repository instructions.
- Never expose secrets or real environment values in documentation.
- Treat `UNKNOWN` and `HYPOTHESIS` as unresolved, not as facts.
- **No agent writes a single line of code before checking the `BR-xxx` rules
  in `docs/ProductDescription.md` and the constraints in
  `docs/Stack_Tecnologies.md`.** A change that contradicts a `CONFIRMED`
  business rule or a stack constraint is a bug, not a judgment call.
- Every new task or action requested by the user is added to `docs/Roadmap.md`
  with an ID before it is executed. No agent works on anything without an ID.
- This file is the single rules source. Other agent files in this repository
  (`CLAUDE.md`, `.cursorrules`, etc.) only point here; on conflict this file
  prevails.

## Startup

Follow this sequence in order; do not skip a step:

1. Read this file (`AGENTS.md`) completely.
2. Run `context`; keep its output at or below 8 KiB. It already includes this
   file, the `## Active work` table, every open task (`IN_PROGRESS`/`PAUSE`),
   and the five latest Agentslog entries.
3. `claim <agent> <task-id> <summary>` the task you'll work on — from
   `## Active work`/`## Near term`/`## Plan`/`## Gaps, Bugs & Technical Debt`
   in `docs/Roadmap.md`, or a new entry you add first if the user's request
   has no ID yet.
4. Develop, reading full `ProductDescription.md`, `Stack_Tecnologies.md`,
   `Roadmap.md#Plan`, or `Features.md` only when relevant to the task at
   hand — not the whole file up front.
5. Validate with `check`. Do not report completion while `check` fails.
6. Close with `done <agent> <task-id> <summary> <files> <verify>`.

## Taking a task

1. Prefer a `docs/Roadmap.md` row already in `## Active work`/`## Near term`,
   or the next eligible `TODO` row in `## Plan` under the highest-priority
   open Epic, unless the user names a different task.
2. New user-requested work with no ID: add a row to `docs/Roadmap.md` first
   (`## Plan` for hierarchical work, `## Gaps, Bugs & Technical Debt` for a
   defect or debt item) before touching any code.
3. `claim` fails if another agent's row is `IN_PROGRESS` and not stale, or
   `PAUSE`d for a reason only that agent can resolve. It writes the Owner
   cell as `<agent>@<timestamp>`.
4. To stop before finishing: `pause <agent> <task-id> <category> "<detail>"`
   (`LIMITE`, `ESPERA_RESPUESTA`, `BLOQUEO`, `OTRO`). Leave the row's
   Acceptance check cell accurate so another agent can resume cold.
5. Close only once the Acceptance check is actually met — not merely
   attempted — with `done <agent> <task-id> <summary> <files> <verify>`. A
   task with a placeholder (`UNKNOWN`/`—`) Acceptance check cannot honestly
   be marked done; fill it in by hand first.

## Technical and product decisions

- Durable technical/architectural decisions go in `docs/Stack_Tecnologies.md`
  as a new `ADR-xxx` row (`## Technical decisions (ADRs)`) — decide it
  yourself only if reversible and scoped to implementation detail.
- Escalate to the human when the choice affects product behavior, cost,
  security, or an external commitment; record the outcome as the ADR row
  (or a `docs/ProductDescription.md` `BR-xxx` rule, if it constrains
  product behavior) either way.
- A significant unresolved question that blocks a task: record it as a row
  in `## Gaps, Bugs & Technical Debt` and reference its ID from the blocked
  task's Depends on cell; never silently work around it.

## Close

1. Update only the affected project truths (`ProductDescription.md`,
   `Stack_Tecnologies.md`) for the current change.
2. Use `claim`/`pause`/`done` to record task state; use `append-log` only for
   entries outside the task lifecycle.
3. Run `rotate`, then `check`. Do not report completion while `check` fails.

## Multi-agent coordination

- `docs/Agentslog.md` is the source of truth for who currently holds a task;
  a Roadmap row's Status/Owner cells are kept in sync with its latest state,
  but the log wins on conflict.
- Do not modify work actively owned by another agent without coordinating.

## Project conventions

- Code style: `UNKNOWN` — infer from checked-in configuration.
- Test command: `UNKNOWN` — record the confirmed command in Stack.
- Documentation language: match the project unless the user specifies one.
<!-- project-documentation:end -->
