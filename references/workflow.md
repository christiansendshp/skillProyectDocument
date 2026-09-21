# Compact project-memory workflow

## Principles

- Keep the contract files present from project initialization onward:
  `AGENTS.md` at the project root; `Agentslog.md`, `ProductDescription.md`,
  `Stack_Tecnologies.md`, `Roadmap.md`, `Features.md` under `docs/`.
- Every contract file is plain Markdown — tables and bulleted lists, never
  YAML or JSON — so line-based tools (`sed`, `awk`, diff/patch) never
  misparse an indentation-sensitive block.
- Never put a literal `|` (escaped as `\|` or not) inside a table cell: the
  scripts split every row on each bar, so it corrupts the row. Word the cell
  without one (known limitation, `F03-DEBT-01`).
- Separate hot context from cold history.
- Document one logical change, not every individual edit or tool call.
- Point to code, tests, commits, issues, and detailed files instead of
  copying their contents.
- Two disjoint `Status` vocabularies exist by design, never mixed: every
  fact table in `ProductDescription.md`/`Stack_Tecnologies.md` uses the
  **epistemic** one — exactly `CONFIRMED` (verified against code, a test,
  or an explicit requirement), `HYPOTHESIS` (a reasonable but unproven
  inference), or `UNKNOWN` (undefined; needs investigation); every work-item
  table in `Roadmap.md` uses the **workflow** one — exactly `TODO`,
  `IN_PROGRESS`, `PAUSE`, or `DONE`.
- Never store secrets, credentials, real environment values, or sensitive
  command output.
- No agent works on a task without an ID in `Roadmap.md`. Every new
  user-requested task or action is added to the Roadmap before it is
  executed.

## Context budget

The `context` command emits, in order:

1. all of `AGENTS.md`;
2. the bounded `Operational summary` blocks from `ProductDescription.md`,
   `Stack_Tecnologies.md`, and `Features.md` — each is everything from
   `## Operational summary` up to and including its `<!-- context:end -->`
   marker, extracted with `awk`/`sed`, nothing beyond it;
3. `## Active work` from `Roadmap.md` (same `<!-- context:end -->`-bounded
   extraction) — keep this table small by design: only tasks in progress,
   paused, or next to take, never the full `## Plan`;
4. `## Open tasks` — every task whose latest Agentslog state is
   `IN_PROGRESS` or `PAUSE`, one compact line each
   (`TASK-ID | agent | STATUS | age | reason`), so a task pushed out of the
   five latest entries below is still visible;
5. the five latest Agentslog entries, capped to the hot ledger.

The result must remain at or below 8 KiB (`CONTEXT_LIMIT` in the script);
`context`/`check` fail loudly if it doesn't. If it exceeds the limit,
compact the `## Active work` table or the Operational summaries, or split
detail into `docs/features/` or `docs/history/`. Never truncate repository
rules silently, and never let `## Active work` grow into a second `## Plan`.

Read full documents only by task:

| Task changes or needs | Read/update |
|---|---|
| user outcomes, roles, domain rules, `BR-xxx` | `ProductDescription.md` |
| dependencies, architecture, security, data, commands, `ADR-xxx` | `Stack_Tecnologies.md` |
| full pending work, hierarchy, dependencies, acceptance criteria | `Roadmap.md` (`## Plan`, `## Gaps, Bugs & Technical Debt`) |
| existing verified behavior | `Features.md` |
| recent coordination or a referenced past decision | `Agentslog.md` or its archive |

## New project

1. Run `init`; it creates only missing files and links other agent files to
   `AGENTS.md` (see Redirected agent files below).
2. Replace known placeholders with confirmed facts from the request or
   project, using `CONFIRMED`/`HYPOTHESIS`/`UNKNOWN` honestly.
3. Leave unknowns explicit instead of delaying harmless implementation.
4. Add the task to `Roadmap.md` with an ID under `## Plan` before
   implementing (status `TODO`, or straight to `IN_PROGRESS` via `claim` if
   it starts immediately).
5. `claim` it, implement, verify, update affected truth, then `done`.

## Existing project

1. Run `init` to recover only missing contract files; run `migrate` first if
   `docs/Agents.md` still exists, or `docs/Roadmap.md` still uses the old
   per-entry YAML block format (see Migrating an existing project).
2. Run `context`.
3. Reconstruct facts from source files, dependency manifests, tests, and
   configuration. Mark uncertain inferences as `HYPOTHESIS` with a
   verification step.
4. Do not rewrite intact project documentation merely to match the
   templates.

## "I want an app" flow

Triggered when the user asks to create a new app, system, or product, and
when installing the skill mid-project with Product/Stack still mostly
`UNKNOWN` after reconstruction from code:

1. `init` (creates the six files and links agent files); `migrate` first if
   the project uses the legacy `docs/Agents.md` format or a YAML Roadmap.
2. Fill Product and Stack with whatever the request or the project already
   gives, aligning each answer to a `ProductDescription.md`/
   `Stack_Tecnologies.md` section (see `references/intake.md`).
3. Ask the user only what's missing, in one batch, using
   `references/intake.md`. Never re-ask an answered field.
4. With the answers, build the complete `## Plan` in `Roadmap.md` (PHASE
   heading -> EPIC heading -> TASK rows, `## Taking and closing a task`
   below) and leave the first task's row `TODO`, ready to `claim`.
5. Only then `claim` and start implementing.

Small, unrelated tasks do not trigger this questionnaire; use the existing
"never block on unknowns" rule instead.

## Task and rule IDs

- Business rules: `BR-001`, `BR-002`, ... in `ProductDescription.md`.
- Technical decisions: `ADR-001`, `ADR-002`, ... in `Stack_Tecnologies.md`.
- Roadmap tasks: `F01-E01-T01` (Fase-Epic-Tarea); subtasks append a
  dot-suffix (`F01-E01-T01.01`). Legacy `F0x-Sxx-Txx` IDs (no explicit
  Epic) remain valid exactly as written — `migrate` never rewrites an
  existing ID.
- Gaps, bugs, and technical debt: `Fxx-GAP-xx` (missing capability),
  `Fxx-BUG-xx` (defect), `Fxx-DEBT-xx` (technical debt) in `Roadmap.md`'s
  `## Gaps, Bugs & Technical Debt` table.
- IDs are stable and never reused, in any convention.
- `check` validates ID *format* in the sections above (`BR-xxx`, `ADR-xxx`,
  a Roadmap Plan row starting `Fnn`), and validates that every fact table's
  `Status` cell is epistemic and every Roadmap `Status` cell is workflow. It
  does not track cross-references between IDs (a table's Depends on/Blocked
  by cell is informational, not enforced) — that level of relational
  integrity was tried in the per-entry YAML schema this skill used briefly
  and reverted; plain Markdown tables trade it for parse robustness.

## Roadmap structure

- `## Active work`: small, positionally-edited table — only tasks in
  progress, paused, or next to take.
- `## Near term`: work not yet in `## Plan`'s critical path; promoted by
  hand, never read by `claim`.
- `## Plan`: the full `VISION -> PHASE -> THEME -> EPIC -> FEATURE -> TASK
  -> SUBTASK` hierarchy. `PHASE`/`THEME`/`EPIC`/`FEATURE` are Markdown
  headings (`###`/`####`/`#####`/`######`) — presentational only, never
  parsed by the scripts, so nesting them deeper or shallower never needs a
  script change. `TASK`/`SUBTASK` rows live in a table right after the
  `EPIC` (or `FEATURE`) heading they belong to.
- `## Gaps, Bugs & Technical Debt`: flat table for unforeseen work found by
  any agent, `claim`/`done`-able like any task.
- `## Out of scope`: explicit exclusions, to counter the tendency to
  over-engineer beyond what was asked.

Every row across these tables ends in the same four columns — Status,
Owner, Depends on, Pause reason — so `claim`/`pause`/`done` edit them by
position regardless of which table or how many columns precede them.

## Taking and closing a task

- `claim <project> <agent> <task-id> <summary>`: fails if the ID is not a
  Roadmap row, or if its last log state is `IN_PROGRESS` by another agent
  (unless that claim is stale) or `PAUSE` not yet retakeable. On success it
  appends an `IN_PROGRESS` log entry, and moves the row (if it was in
  `## Plan`/`## Gaps, Bugs & Technical Debt`) or updates it in place into
  `## Active work` with Status `IN_PROGRESS` and Owner `<agent>@<timestamp>`.
- `pause <project> <agent> <task-id> <category> <detail>`: category is one
  of `LIMITE`, `ESPERA_RESPUESTA`, `BLOQUEO`, `OTRO`; detail must be
  non-empty. Only the current owner may pause. Sets the row's Status to
  `PAUSE`, Owner to `<agent>@<timestamp>`, Pause reason to `<category>`.
- `done <project> <agent> <task-id> <summary> <files> <verify>`: `verify`
  must be non-empty. Appends a `DONE` log entry, removes the row from
  `Roadmap.md`, and adds it to `Features.md#Verified capabilities`. When
  its ID is a task under an epic (`F01-E01-T01`, inferred from the ID
  shape) and no other Roadmap row still shares that epic prefix, the epic
  is rolled up too with its own Features row.
- `status <project>`: lists every `IN_PROGRESS`/`PAUSE` task with owner,
  age, and reason; flags stale `IN_PROGRESS` claims.
- Retaking a `PAUSE`: `LIMITE` can be reclaimed by any agent immediately;
  `ESPERA_RESPUESTA` and `BLOQUEO` only once the blocking reason is
  resolved (recorded in a new entry's Summary). An `IN_PROGRESS` untouched
  for longer than `PROJECT_DOCS_STALE_HOURS` (default 24) is considered
  abandoned and can be reclaimed by another agent. Age is computed from the
  entry's ISO-8601 timestamp using GNU `date -d` (sh) or
  `[DateTime]::Parse` (PowerShell); on a system with neither GNU nor a
  compatible `date`, age shows as `?h` and staleness never triggers
  automatically — pause and reclaim by hand instead.
- Locking: `claim`/`pause`/`done` take a short-lived lock (`docs/.lock`) so
  concurrent runs in the *same working copy* don't race. Across machines,
  commit and push a `claim` entry immediately so other agents see it before
  they claim.
- A task's Acceptance check cell must be a real, non-placeholder statement
  before `done` closes it — `UNKNOWN`/`—` there means the task isn't
  actually specified yet, and closing it would be reporting false
  completion.

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
state is whatever its latest entry says. Never edit a past entry — record a
state change as a new one. The Roadmap's Status/Owner cells are kept in sync
by `claim`/`pause`/`done`, not edited by hand.

`append-log` remains available, unchanged, for entries outside the claim
lifecycle (its own header/Follow-up format); prefer `claim`/`pause`/`done`
for anything with a task ID.

## Rotation

The hot ledger rotates after 200 entries or 128 KiB (`run 'rotate'`, or
`check` reports `ROTATE REQUIRED` when it's overdue and blocks the gate
until you do). Rotation must:

1. copy the complete ledger to a unique `docs/history/Agentslog-*.md`;
2. verify the archived copy by hash;
3. replace the hot ledger atomically with a fresh header plus the archive
   pointer and its hash;
4. re-open a compact entry for every task still `IN_PROGRESS`/`PAUSE` at
   rotation time, pointing back at the archive for the full history — a
   paused task is never silently dropped by rotation.

Archives are immutable — never edit a file under `docs/history/`. Read one
only when a current entry or decision points to it, or when `check` needs
to confirm an older `DONE` for a Features ID that rotated out of the hot
log.

## Redirected agent files

`link` (also run at the end of `init`) points other agent-specific files at
`AGENTS.md` without duplicating its rules:

- Detects, at the project root: `CLAUDE.md`, `GEMINI.md`, `.cursorrules`
  (or `.cursor/rules/` if in use), `.windsurfrules`, `.clinerules`,
  `.github/copilot-instructions.md`, `.antigravity/rules.md`.
- In each, inserts (or updates in place) a short delimited block
  (`<!-- project-documentation:start -->` ... `:end -->`) pointing to
  `AGENTS.md` as the rules source and prevailing on conflict; `CLAUDE.md`
  also gets the native `@AGENTS.md` import. The rest of the file is
  untouched.
- Never creates a file that doesn't already exist, unless asked explicitly:
  `link <project> --create claude,gemini,cursor,windsurf,cline,copilot,antigravity`.

See `references/adapters.md` for the per-runtime compatibility notes (Claude
Code, Cursor, Antigravity, OpenCode, Codex, and other adapters).

## Migrating an existing project

`migrate <project>` is idempotent and handles both legacy layouts:

1. If the project root has a case-only variant of `AGENTS.md` (e.g.
   `Agents.md` on a case-sensitive filesystem), renames it in two steps
   (`git mv` when available) so the rename is tracked.
2. Ensures the six contract files exist (same as `init`).
3. If `docs/Agents.md` still exists, merges its content into `AGENTS.md`'s
   managed block (preserving custom rules, never duplicating the skill's
   own template) and removes `docs/Agents.md`.
4. If `docs/Roadmap.md` still uses the short-lived per-entry `yaml` block
   format this skill used before reverting to tables, converts every entry
   into `## Plan`/`## Gaps, Bugs & Technical Debt` rows non-destructively:
   every ID is preserved; `PHASE`/`THEME`/`EPIC`/`FEATURE` entries become
   headings, placed under their nearest `PHASE` ancestor by walking the
   `parent` chain; `TASK`/`SUBTASK` entries become rows under their nearest
   `EPIC`; cross-cutting entries (`GAP`, `BUG`, `DECISION`, `BLOCKER`, ...)
   become Gaps/Bugs/Technical-Debt rows — a `DECISION`'s `question`/
   `options` fields have no table equivalent and are dropped after
   converting its ID and title, so review any migrated `DECISION` row by
   hand. An entry whose `parent` chain never reaches a `PHASE` is kept
   under a synthesized `F00-ORPHANED` heading for manual placement, never
   silently dropped.
5. Ensures `## Gaps, Bugs & Technical Debt` and `## Out of scope` exist in
   `docs/Roadmap.md`, adding an empty placeholder section if not.

While a project still has `docs/Agents.md`, or `docs/Roadmap.md` still uses
the per-entry YAML format, `check` fails with a message pointing at
`migrate`.

## Content maintenance

- Product keeps stable functional truth (`BR-xxx` rules, flows, glossary,
  explicit `## Out of scope`), not implementation plans.
- Stack keeps current technical truth plus a compact `ADR-xxx` decision
  table and critical commands. Put long ADR write-ups in `docs/decisions/`
  and link them.
- Roadmap keeps only entries relevant to planning; `done` removes a closed
  row after preserving the verified capability in Features and the change
  in Agentslog. Never put agent-behavior rules (task selection, when to ask
  a human, commit/push timing) in Roadmap.md — those belong in `AGENTS.md`.
- Features is an index. Put long runbooks or feature specifications in
  `docs/features/` and link them.
- Git is the recovery mechanism for normal deletions. Archive only audit
  history and superseded decisions that remain useful; do not enforce
  "nothing is ever deleted."

## Gate

Run `check` after documentation updates. It exits non-zero only on errors:

- missing `AGENTS.md` at the root, a leftover `docs/Agents.md`, or more
  than one case variant of `AGENTS.md` coexisting;
- a missing required section or required table header in any contract
  file, the `<!-- context:end -->` marker missing from
  ProductDescription/Stack/Roadmap, or the 8 KiB context budget exceeded;
- `docs/Roadmap.md` still using the pre-revert per-entry YAML format;
- an invalid ID format: a Business rules row not shaped `BR-xxx`, a
  Technical decisions row not shaped `ADR-xxx`, or a Roadmap `## Plan` row
  not starting `Fnn`;
- a fact-table row (Product/Stack) whose Status is outside
  `CONFIRMED`/`HYPOTHESIS`/`UNKNOWN`, or a Roadmap row whose Status is
  outside `TODO`/`IN_PROGRESS`/`PAUSE`/`DONE`;
- an Agentslog entry with a state outside `IN_PROGRESS`/`PAUSE`/`DONE`;
- a `PAUSE` entry without a valid category or non-empty detail;
- a `DONE` entry with an empty or `"pending"` Verify;
- two different agents both holding an open `IN_PROGRESS` on the same ID (a
  concurrent-claim conflict, typically from a git merge race);
- a log ID that exists in neither `Roadmap.md` nor `Features.md`;
- a `Features.md` ID with no matching `DONE` in the hot log or, if rotated
  away, in `docs/history/`;
- the ledger overdue for rotation.

Warnings (do not fail the gate): `UNKNOWN` fields in Operational summaries
(expected on a fresh, not-yet-filled template — but should be zero on a
project's own maintained docs); an agent file missing its `link` block; a
stale `IN_PROGRESS` claim.

A task is not complete while `check` exits non-zero.
