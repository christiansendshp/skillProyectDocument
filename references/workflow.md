# Compact project-memory workflow

## Principles

- Keep the contract files present from project initialization onward:
  `AGENTS.md` at the project root; `Agentslog.md`, `ProductDescription.md`,
  `Stack_Tecnologies.md`, `Roadmap.md`, `Features.md` under `docs/`.
- Separate hot context from cold history.
- Document one logical change, not every individual edit or tool call.
- Point to code, tests, commits, issues, and detailed files instead of copying
  their contents.
- Use `CONFIRMED`, `UNKNOWN`, `HYPOTHESIS`, or `N/A` for facts whose certainty
  matters.
- Never store secrets, credentials, real environment values, or sensitive
  command output.
- No agent works on a task without an ID in `Roadmap.md`. Every new
  user-requested task or action is added to the Roadmap before it is
  executed.

## Context budget

The `context` command emits:

1. all of `AGENTS.md`;
2. the bounded `Operational summary` blocks from Product, Stack, and Features;
3. active Roadmap rows (`## Active work`);
4. `## Open tasks` — every task whose latest log state is `IN_PROGRESS` or
   `PAUSE`, one compact line each (`TASK-ID | agent | STATUS | age | reason`),
   so a task taken out of the five latest entries below is still visible;
5. the five latest Agentslog entries, capped to the hot ledger.

The result must remain at or below 8 KiB. If it exceeds the limit, compact the
summaries or split detail into `docs/features/` or `docs/history/`. Never
truncate repository rules silently.

Read full documents only by task:

| Task changes or needs | Read/update |
|---|---|
| user outcomes, roles, domain rules | `ProductDescription.md` |
| dependencies, architecture, security, data, commands | `Stack_Tecnologies.md` |
| full pending work, acceptance criteria | `Roadmap.md` (`## Plan`) |
| existing verified behavior | `Features.md` |
| recent coordination or a referenced past decision | `Agentslog.md` or its archive |

## New project

1. Run `init`; it creates only missing files and links other agent files to
   `AGENTS.md` (see Redirected agent files below).
2. Replace known placeholders with confirmed facts from the request or
   project.
3. Leave unknowns explicit instead of delaying harmless implementation.
4. Add the task to `Roadmap.md` with an ID (`## Plan`, or `## Active work` if
   it starts immediately) before implementing.
5. `claim` it, implement, verify, update affected truth, then `done`.

## Existing project

1. Run `init` to recover only missing contract files; run `migrate` first if
   `docs/Agents.md` still exists (see Migrating an existing project).
2. Run `context`.
3. Reconstruct facts from source files, dependency manifests, tests, and
   configuration. Mark uncertain inferences as `HYPOTHESIS` with a
   verification step.
4. Do not rewrite intact project documentation merely to match the templates.

## "I want an app" flow

Triggered when the user asks to create a new app, system, or product, and
when installing the skill mid-project with Product/Stack still mostly
`UNKNOWN` after reconstruction from code:

1. `init` (creates the six files and links agent files); `migrate` first if
   the project uses the legacy `docs/Agents.md` format.
2. Fill Product and Stack with whatever the request or the project already
   gives.
3. Ask the user only what's missing, in one batch, using
   `references/intake.md`. Never re-ask an answered field.
4. With the answers, build the complete `## Plan` in `Roadmap.md`
   (Fase -> Epic -> Tarea) and put the first task in `## Active work`.
5. Only then `claim` and start implementing.

Small, unrelated tasks do not trigger this questionnaire; use the existing
"never block on unknowns" rule instead.

## Task IDs

- New convention: `F01-E01-T01` (Fase-Epic-Tarea); subtasks append
  `.01` (`F01-E01-T01.01`); defects use `F01-BUG-001` or `F01-GAP-001`.
- Legacy `F0x-Sxx-Txx` IDs (no explicit Epic) remain valid exactly as written;
  never rewrite an existing ID to the new shape.
- IDs are stable and never reused, in either convention.
- `check` validates that an ID referenced by the log exists in `Roadmap.md` or
  `Features.md`; it never validates ID shape, so legacy IDs always pass.

## Roadmap structure

- `## Active work` (before `<!-- context:end -->`): only tasks in progress,
  paused, or next to take.
- `## Near term`: work further out; promoted into `## Plan` manually when it
  becomes actionable. `claim` does not read this table.
- `## Plan`: the full Fase -> Epic -> Tarea -> Subtarea hierarchy of pending
  work, organized under `###`/`####` headings.
- `## Gaps and defects`: errors or significant gaps found by any agent, with
  ID, severity, and phase.

Every row `claim`/`pause`/`done` can touch — in `## Active work`, `## Plan`,
and `## Gaps and defects` — ends in the same four columns, in this order:
Status, Owner, Depends on, Pause reason. `claim` edits by column position
from the end, so keep that order when adding rows by hand.

Item states: `TODO`, `IN_PROGRESS` (taken), `PAUSE`, `DONE`. There is no
separate `BLOCKED` state: a blocked item is `PAUSE` with category `BLOQUEO`.

## Taking and closing a task

- `claim <project> <agent> <task-id> <summary>`: fails if the ID is not in
  `Roadmap.md`, or if its last log state is `IN_PROGRESS` by another agent
  (unless that claim is stale) or `PAUSE` not yet retakeable. On success it
  appends an `IN_PROGRESS` log entry and moves/updates the Roadmap row
  (`## Plan` -> `## Active work`, or in place for `## Active work`/`## Gaps
  and defects`).
- `pause <project> <agent> <task-id> <category> <detail>`: category is one of
  `LIMITE`, `ESPERA_RESPUESTA`, `BLOQUEO`, `OTRO`; detail must be non-empty.
  Only the current owner may pause.
- `done <project> <agent> <task-id> <summary> <files> <verify>`: `verify`
  must be non-empty. Appends a `DONE` entry, removes the task's Roadmap row,
  and adds it to `Features.md#Verified capabilities`. When every task under
  an Epic is `DONE`, the Epic itself also gets a Features row.
- `status <project>`: lists every `IN_PROGRESS`/`PAUSE` task with owner, age,
  and reason; flags stale `IN_PROGRESS` claims.
- Retaking a `PAUSE`: `LIMITE` can be reclaimed by any agent immediately;
  `ESPERA_RESPUESTA` and `BLOQUEO` only once the blocking reason is resolved
  (recorded in a new entry's Summary). An `IN_PROGRESS` untouched for longer
  than `PROJECT_DOCS_STALE_HOURS` (default 24) is considered abandoned and can
  be reclaimed by another agent.
- Locking: `claim`/`pause`/`done` take a short-lived lock (`docs/.lock`) so
  concurrent runs in the *same working copy* don't race. Across machines,
  commit and push a `claim` entry immediately so other agents see it before
  they claim.

## Ledger

Use one log entry per state change:

```markdown
## [YYYY-MM-DDTHH:mm:ssZ] | agent | TASK-ID | IN_PROGRESS
- Summary: what the agent will do or did
- Files: paths or component names (optional)
- Verify: command and result, or "pending" (required for DONE)
- Pause: CATEGORY - detail (required for PAUSE)
```

Keep entries under six lines and approximately 700 characters. The ledger is
append-only and is the source of truth for who owns a task; a task's current
state is whatever its latest entry says. The Roadmap's Status/Owner columns
are kept in sync by `claim`/`pause`/`done`, not edited by hand.

`append-log` remains available, unchanged, for entries outside the claim
lifecycle (its own header/Follow-up format); prefer `claim`/`pause`/`done` for
anything with a task ID.

## Rotation

The hot ledger rotates after 200 entries or 128 KiB. Rotation must:

1. copy the complete ledger to a unique `docs/history/Agentslog-*.md`;
2. verify the archived copy by hash;
3. replace the hot ledger atomically;
4. record the archive path and hash in the new ledger, and re-open a compact
   entry for every task still `IN_PROGRESS`/`PAUSE` at rotation time (their
   full history stays in the archive).

Archives are immutable. Read one only when a current entry or decision points
to it, or when `check` needs to confirm an older `DONE` for a Features ID.

## Redirected agent files

`link` (also run at the end of `init`) points other agent-specific files at
`AGENTS.md` without duplicating its rules:

- Detects, at the project root: `CLAUDE.md`, `GEMINI.md`, `.cursorrules`
  (or `.cursor/rules/` if in use), `.windsurfrules`, `.clinerules`,
  `.github/copilot-instructions.md`, `.antigravity/rules.md`.
- In each, inserts (or updates in place) a short delimited block
  (`<!-- project-documentation:start -->` ... `:end -->`) pointing to
  `AGENTS.md` as the rules source and prevailing on conflict; `CLAUDE.md` also
  gets the native `@AGENTS.md` import. The rest of the file is untouched.
- Never creates a file that doesn't already exist, unless asked explicitly:
  `link <project> --create claude,gemini,cursor,windsurf,cline,copilot,antigravity`.

## Migrating an existing project

`migrate <project>` is idempotent and handles the legacy layout:

1. If the project root has a case-only variant of `AGENTS.md` (e.g.
   `Agents.md` on a case-sensitive filesystem), renames it in two steps
   (`git mv` when available) so the rename is tracked.
2. Ensures the six contract files exist (same as `init`).
3. If `docs/Agents.md` still exists, merges its content into `AGENTS.md`'s
   managed block (preserving custom rules, never duplicating the skill's own
   template) and removes `docs/Agents.md`.
4. Adds any missing `Roadmap.md` sections (`## Plan`, `## Gaps and defects`,
   the `Pause reason` column) without touching existing content.

While a project still has `docs/Agents.md`, `check` fails with a message
pointing at `migrate`.

## Content maintenance

- Product keeps stable functional truth, not implementation plans.
- Stack keeps current technical truth plus a compact decision table. Put long
  ADRs in `docs/decisions/` and link them.
- Roadmap's `## Active work` stays small; full pending detail lives in
  `## Plan`. Remove completed detail after preserving the verified capability
  in Features and the change in Agentslog (this is what `done` does).
- Features is an index. Put long runbooks or feature specifications in
  `docs/features/` and link them.
- Git is the recovery mechanism for normal deletions. Archive only audit
  history and superseded decisions that remain useful; do not enforce
  "nothing is ever deleted."

## Gate

Run `check` after documentation updates. It exits non-zero only on errors:

- missing `AGENTS.md` at the root, a leftover `docs/Agents.md`, or more than
  one case variant of `AGENTS.md` coexisting;
- a missing required section in any contract file, or the 8 KiB context
  budget exceeded;
- an Agentslog entry with a state outside `IN_PROGRESS`/`PAUSE`/`DONE`;
- a `PAUSE` entry without a valid category or non-empty detail;
- a `DONE` entry with an empty or `"pending"` Verify;
- two different agents both holding an open `IN_PROGRESS` on the same ID (a
  concurrent-claim conflict, typically from a git merge race);
- a log ID that exists in neither `Roadmap.md` nor `Features.md`;
- a `Features.md` ID with no matching `DONE` in the hot log or, if rotated
  away, in `docs/history/`;
- the ledger overdue for rotation.

Warnings (do not fail the gate): `UNKNOWN` fields in Operational summaries; an
agent file missing its `link` block; a stale `IN_PROGRESS` claim.

A task is not complete while `check` exits non-zero.
