## Repository rules

- Scope: all AI agents and contributors in this repository.
- Work branch: `UNKNOWN` — confirm from repository or user instructions.
- Approval boundaries: follow the active runtime and repository instructions.
- Never expose secrets or real environment values in documentation.
- Treat `UNKNOWN` and `HYPOTHESIS` as unresolved, not as facts.
- Every new task or action requested by the user is added to `docs/Roadmap.md`
  with an ID before it is executed. No agent works on anything without an ID.
- This file is the single rules source. Other agent files in this repository
  (`CLAUDE.md`, `.cursorrules`, etc.) only point here; on conflict this file
  prevails.

## Startup

1. Run the project-documentation `init` command, then `link`.
2. Run `context`; keep its output at or below 8 KiB.
3. Read this file completely, the active Roadmap rows (`## Active work`), and
   every open task (`IN_PROGRESS` or `PAUSE`) plus the five latest log
   entries — `context` includes all of these.
4. Read full Product, Stack, `Roadmap.md#Plan`, or Features only when relevant
   to the task.

## Taking a task

1. Pick the first `TODO` row in `docs/Roadmap.md` (`## Active work` or
   `## Plan`) whose `Depends on` entries are all `DONE`, unless the user names
   a different task or requests new work.
2. If the user requests work with no ID yet, add it to `docs/Roadmap.md`
   first (`## Plan`, or `## Active work` if it starts immediately).
3. Run `claim <agent> <task-id> <summary>`. It fails if another agent already
   owns the task; if it fails, pick the next eligible task or coordinate with
   the owner shown by `status`.
4. If you must stop before finishing, run `pause <agent> <task-id> <category>
   "<detail>"` with category `LIMITE`, `ESPERA_RESPUESTA`, `BLOQUEO`, or
   `OTRO`.
5. When the acceptance check passes, run `done <agent> <task-id> <summary>
   <files> <verify>`. This records the capability in `Features.md` and
   removes the task detail from the Roadmap.

## Close

1. Update only the affected project truths (`ProductDescription.md`,
   `Stack_Tecnologies.md`) for the current change.
2. Use `claim`/`pause`/`done` to record task state; use `append-log` only for
   entries outside the task lifecycle.
3. Run `rotate`, then `check`. Do not report completion while `check` fails.

## Multi-agent coordination

- `docs/Agentslog.md` is the source of truth for who owns a task; the
  Roadmap's Status/Owner columns are kept in sync with its latest state.
- Do not modify work actively owned by another agent without coordinating.
- Record durable decisions in `Stack_Tecnologies.md` and link them from the
  log entry that acted on them.

## Project conventions

- Code style: `UNKNOWN` — infer from checked-in configuration.
- Test command: `UNKNOWN` — record the confirmed command in Stack.
- Documentation language: match the project unless the user specifies one.
