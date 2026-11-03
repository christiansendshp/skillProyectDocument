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
3. `claim <agent> <task-id> <summary>` the task before your first edit, adding
   its Roadmap row first if it has no ID. Documenting afterwards (claim and
   done back to back) is allowed, but the board cannot show the work while it
   happens.
4. Develop, reading full `ProductDescription.md`, `Stack_Tecnologies.md`,
   `Roadmap.md#Plan` or `Features.md` only when the task needs it.
5. Validate with `check`. Do not report completion while it fails.
6. With a reviewer, `handoff <agent> <task-id> <summary> <verify> [reviewer]`
   once the code is complete and your own verification passed; without one, go
   to `done`.
7. `done <agent> <task-id> <summary> <files> <verify>` only after
   verification, and after `review PASS` if there was a handoff.

## Taking a task

1. Prefer a row already in `## Active work`/`## Near term`, or the next
   eligible `TODO` row in `## Plan` under the highest-priority open Epic,
   unless the user names another task.
2. New work: add a row first (`## Plan` or `## Gaps, Bugs & Technical Debt`)
   with a `Name` (<= 10 words, descriptive) and the rest in `Description`.
   The commands refuse a missing or too-long Name and copy it into the
   Agentslog entry; never retype it (`references/workflow.md`).
3. `claim` fails on another agent's non-stale `IN_PROGRESS` or `REVIEW`, or a
   `PAUSE` only that agent can resolve. Owner is written as `<agent>@<timestamp>`.
4. To stop early: `pause <agent> <task-id> <category> "<detail>"` (`LIMITE`,
   `ESPERA_RESPUESTA`, `BLOQUEO`, `OTRO`); keep the Acceptance check accurate
   so another agent can resume cold.
5. A reviewer answers with `review <agent> <task-id> PASS|FAIL <note>
   [verify]`; after FAIL the developer retakes the task with `claim`.
6. Close only when the Acceptance check is actually met. A placeholder
   (`UNKNOWN`/`—`) Acceptance check cannot honestly be marked done.
7. `docs/Agentslog.md` is the source of truth for who holds a task and wins over
   a Roadmap row's Status/Owner cells; do not modify work another agent holds.

## Technical and product decisions

- Durable technical decisions go in `docs/Stack_Tecnologies.md` as an
  `ADR-xxx` row; decide yourself only if reversible and implementation-scoped.
- In Factory mode the autonomy policy in `## Factory` replaces asking a human.
- A significant question that blocks a task goes in
  `## Gaps, Bugs & Technical Debt`, referenced from the task's Depends on
  cell; never silently work around it.

## Close

1. Update only the project truths the change affects.
2. Use `claim`/`pause`/`handoff`/`review`/`done` for task state, `append-log`
   only outside the lifecycle.
3. Run `rotate`, then `check`. Do not report completion while it fails.

## Factory

Settings read by the scripts; a missing row takes its default. Detail: the
skill's `references/factory.md`.

| Setting | Value |
|---|---|
| Mode | FACTORY |
| Require TDD | YES |
| Independent review | YES |
| WIP per agent | 1 |
| Max fix attempts | 3 |
| Fast lane max files | 5 |
| Fast lane max lines | 150 |
| Fast lane protected paths | prisma/ migrations/ auth/ rls/ security/ |
| Preferred reviewer | — |
| Fallback reviewer | — |

- Never ask which task to take: run `next <agent>`; never stay idle.
- Small changes with no business rule, schema, auth or API change go FAST
  (`Lane: FAST` in the row Description): no spec or RED, still tested and
  reviewed. Outgrown limits send the task back to SPEC.
- Phases: SPEC -> RED -> GREEN -> REVIEW -> DONE. Move with `advance`, review
  with `handoff`/`review`, close with `retro` then `done`.
- GREEN never edits the tests recorded at RED; a wrong test goes back to SPEC.
- Decide reversible choices yourself. Record product guesses as HYPOTHESIS
  `BR-xxx` rows pinned by a test.
- Red lines (pause `ESPERA_RESPUESTA` "RED-LINE: ..." and take other work):
  main or production deploy, destructive data operations, secrets, new paid
  services, weakening auth or tenant isolation, personal-data handling rules.
- Context: `context`, then `recall <task>`; read more only where recall
  points. `checkpoint` before pausing, compacting or changing phase.

## Agent identity

One stable id per agent, always the same text; aliases match case-insensitively.
Kind: HUMAN or AI. Role: SPEC, TEST, DEV, QA, OPS or BOTH (DEVELOPER is a legacy
alias of DEV). Factory mode needs two ids at least, one with role QA.

| Agent id | Kind | Model | Role | Aliases |
|---|---|---|---|---|
| claude-spec | AI | Claude | SPEC | — |
| claude-test | AI | Claude | TEST | — |
| claude-dev | AI | Claude | DEV | — |
| claude-qa | AI | Claude | QA | — |
| gemini-qa | AI | Gemini | QA | — |

## Project conventions

- Code style: `UNKNOWN` — infer from checked-in configuration.
- Test command: `UNKNOWN` — record the confirmed command in Stack.
- Documentation language: match the project unless the user specifies one.
