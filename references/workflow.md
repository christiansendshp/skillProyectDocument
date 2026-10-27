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

1. Run `init`; it creates only missing files (the seven files of Factory mode, or
   the six with `--classic`) and links other agent files to `AGENTS.md` (see
   Redirected agent files below).
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

1. `init` (creates the six files, or the seven of Factory mode, and links agent files); `migrate` first if
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
position regardless of which table or how many columns precede them. The
column right after `ID` is always `Name`: a short, descriptive title of 10
words or fewer, detected by header text (not position), so it works
regardless of how many columns a table has. Every other detail — the full
sentence, context, or reasoning — goes in `Description` (`## Near term` has
no `Description` column; keep its `Name` itself to 10 words or fewer).

## Taking and closing a task

- `claim <project> <agent> <task-id> <summary>`: fails if the ID is not a
  Roadmap row, if its Name is missing or over 10 words (fix the row by hand
  first), or if its last log state is `IN_PROGRESS` or `REVIEW` held by
  another agent (unless that entry is stale) or `PAUSE` not yet retakeable.
  The holder may always retake their own task, also from `REVIEW` (after a
  `FAIL`, or to withdraw the handoff). A task `ASSIGNED` to someone else
  can still be claimed, with a warning. On success it appends
  an `IN_PROGRESS` log entry carrying the row's Name, and moves the row (if
  it was in `## Plan`/`## Gaps, Bugs & Technical Debt`) or updates it in
  place into `## Active work` with Status `IN_PROGRESS` and Owner
  `<agent>@<timestamp>`.
- `pause <project> <agent> <task-id> <category> <detail>`: category is one
  of `LIMITE`, `ESPERA_RESPUESTA`, `BLOQUEO`, `OTRO`; detail must be
  non-empty. Only the current owner may pause. Sets the row's Status to
  `PAUSE`, Owner to `<agent>@<timestamp>`, Pause reason to `<category>`, and
  appends a log entry carrying the row's current Name.
- `handoff <project> <agent> <task-id> <summary> <verify> [reviewer]`: the
  developer says the code is complete and their own verification passed.
  Needs the task `IN_PROGRESS` and held by `<agent>` (the same checks as
  `pause`), a non-empty summary and a `verify` that is neither empty nor
  `pending`. Appends a `REVIEW` entry carrying the Name, Summary, Verify and,
  when a reviewer is named, a `- Handoff: <reviewer>` line. The Roadmap row is
  not touched: it stays `IN_PROGRESS` with the same Owner. Optional: a
  project without a reviewer goes straight from `claim` to `done`.
- `review <project> <agent> <task-id> <PASS|FAIL> <note> [verify]`: a
  reviewer answers a pending handoff (the last entry is a `REVIEW` with no
  result). `note` must be non-empty and `PASS` needs a real `verify`. Appends
  a `REVIEW` entry in the reviewer's name with `- Review: PASS|FAIL - note`;
  the Roadmap row is not touched. After `FAIL` the task is back with its
  holder, who retakes it with `claim`; nobody else can while the entry is not
  stale, and a reviewer cannot close a task they failed. Reviewing your own
  handoff prints `WARN: self-review` and succeeds, so a single-agent project
  does not freeze; `PROJECT_DOCS_REQUIRE_INDEPENDENT_REVIEW=1` makes it an
  error. With a roster, a reviewer whose role is `DEVELOPER` also warns.
- `assign <project> <agent> <task-id> <to-agent>`: records that `<agent>`
  assigned the task to `<to-agent>` (an `ASSIGNED` entry with a
  `- Assign: <to-agent>` line) and sets the Roadmap Owner to
  `<to-agent>@<timestamp>`. The row stays `TODO` and no work starts: the
  assignee still has to `claim`. A task that is `IN_PROGRESS`, `PAUSE` or in
  `REVIEW` cannot be assigned. An assignment is a request, not a lock.
- `done <project> <agent> <task-id> <summary> <files> <verify>`: `verify`
  must be non-empty. Only these agents may close a task: the holder, the
  reviewer who left `Review: PASS`, anyone once the last entry is stale
  (`PROJECT_DOCS_STALE_HOURS`), anyone with `PROJECT_DOCS_FORCE=1`, and anyone
  when the task has no ledger entries at all (a retroactive close, the normal
  case for batches). Otherwise `done failed: <id> is held by <agent>`. Warns,
  without failing, when the holder closes with a handoff still pending or a
  `Review: FAIL` ("closing without a passing review"), when `verify` says
  nothing (`none`, `n/a`, `no run`, `ninguno`, an em dash or `UNKNOWN`, any
  case), and when the task was claimed and closed less than
  `PROJECT_DOCS_MIN_WORK_MINUTES` (default 5) apart: claim before the first
  edit so the work is visible while it happens. Appends a `DONE` log entry carrying the row's Name,
  removes the row from `Roadmap.md`, and adds it to
  `Features.md#Verified capabilities`. When its ID is a task under an epic
  (`F01-E01-T01`, inferred from the ID shape) and no other Roadmap row still
  shares that epic prefix, the epic is rolled up too with its own Features
  row.
- `status <project>`: lists every open task (`IN_PROGRESS`, `PAUSE`,
  `REVIEW`, `ASSIGNED`) with its Name, holder, stage, age and reason; a
  `REVIEW` shows its stage and destination (`REVIEW->qa-agent`, or
  `REVIEW(PASS)->qa-agent` once passed) and a task back with its holder after
  `FAIL` shows as `IN_PROGRESS`. Flags stale `IN_PROGRESS` and `REVIEW`
  entries.
- Retaking a `PAUSE`: `LIMITE` can be reclaimed by any agent immediately;
  `ESPERA_RESPUESTA` and `BLOQUEO` only once the blocking reason is
  resolved (recorded in a new entry's Summary). An `IN_PROGRESS` or `REVIEW`
  untouched for longer than `PROJECT_DOCS_STALE_HOURS` (default 24) is considered
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
## [YYYY-MM-DDTHH:mm:ssZ] | agent | TASK-ID | IN_PROGRESS | Name
- Summary: what the agent will do or did
- Files: paths or component names (optional)
- Verify: command and result, or "pending" (required for DONE and REVIEW)
- Pause: CATEGORY - detail (required for PAUSE)
- Handoff: reviewer agent or role (optional, REVIEW)
- Review: PASS|FAIL - detail (optional, REVIEW)
- Assign: agent (required for ASSIGNED)
```

Keep entries under six lines and approximately 700 characters. The ledger is
append-only and is the source of truth for who owns a task; a task's current
state is whatever its latest entry says. Never edit a past entry — record a
state change as a new one. The Roadmap's Status/Owner cells are kept in sync
by `claim`/`pause`/`done`, not edited by hand.

`Name` is the same short (<= 10 word) title as the task's Roadmap row —
`claim`/`pause`/`done` copy it in automatically, never type it by hand.
`check` cross-validates: the most recent entry that carries a Name for a
given ID must match that ID's current Roadmap Name, so Agentslog can never
drift from the Roadmap's own naming — only a hand edit to one side without
the other produces that error. An entry with no Name field at all (history
from before this rule, or an `append-log` entry) is never treated as a
mismatch.

`append-log` remains available, unchanged, for entries outside the claim
lifecycle (its own header/Follow-up format, with no Name field); prefer
`claim`/`pause`/`handoff`/`review`/`done` for anything with a task ID.

### Review stage

The stage of a task lives only in the ledger; the Roadmap `Status` values
and columns do not change, and the row stays `IN_PROGRESS` throughout.

```
IN_PROGRESS (developer) --handoff--> REVIEW  (developer; optional Handoff line)
REVIEW (reviewer)  "- Review: PASS - detail"  --> ready for done
REVIEW (reviewer)  "- Review: FAIL - detail"  --> back with the developer
```

- A `REVIEW` entry needs a `Summary` and a `Verify` that is neither empty nor
  `pending`, like `DONE`: it is what the author verified. The one exception is
  an entry carrying `Review: FAIL`, whose reviewer verified nothing that
  passed, so its `Verify` is optional. If a `Review` line is present its
  result must be `PASS` or `FAIL` and its detail non-empty.
- The **holder** is the agent of the last `IN_PROGRESS` entry (for an
  `ASSIGNED` task, the assignee), also while the task is in `REVIEW`. The
  effective stage is `REVIEW` unless the last entry says `Review: FAIL`, which
  means the task is back with its holder.
- Conflict rule: two `REVIEW` entries by different agents (developer and
  reviewer) are normal. A third agent starting `IN_PROGRESS` on a task held by
  someone else right after a `REVIEW`, and not stale, is a
  `conflicting concurrent claim`.
- The task-state scan appends `holder`, `handoff` and `review` after the
  existing columns; consumers read the tab-separated line with a
  non-whitespace separator, because a tab is whitespace for `read` and merges
  empty fields.

## Factory mode

On when the project `AGENTS.md` has a `## Factory` section with `Mode` `FACTORY`
(`init` writes it for a new project); without it every command above behaves
exactly as described. `mode` prints which mode applies, and why. The full
description (phases, specs, the brain, the fast lane, the dispatcher) is in
`references/factory.md`. What changes in the commands above:

- `claim` also checks that the role of the agent matches the phase of the task,
  the work in progress (`WIP per agent`) and the fix attempts (`Max fix attempts`),
  and records the phase (and, for a fast-lane row, `Lane` and `Base`).
- `pause` from `REVIEW` is allowed to the holder, and needs a working memory
  (`checkpoint`) so the next agent can resume.
- `handoff`, `review` and `done` need `exit=0` in the verify; a self-review, a
  closing without a passing review and an empty verify are errors, not warnings.
  `handoff` of a GREEN task also checks that the tests recorded at RED did not
  change, and of a fast-lane task its size; `review` writes `Cross-model: NO` when the
  reviewer and the holder are the same model; `done` needs `retro`.
- `status` ends each line with the phase and the lane. `rotate` also archives the
  brain and carries the phase, the lane and the evidence of open tasks.
- `check` also validates `docs/Brain.md`, the specs, the working memories, the
  roster and the `Phase` of every open task.
- New commands, after the project path: `next <agent>`, `checkpoint <agent> <task-id>
  <step> <next>`, `advance <agent> <task-id> <phase> <verify> [to-agent]`, `recall
  <task-id>`, `learn <agent> <task-id> <kind> <name> <trigger> <lesson>`, `retro <agent>
  <task-id> <used-ids|none> <learned-ids|none>` and `digest [since]`. Environment:
  `PROJECT_DOCS_MODE` (`classic` or `factory`) forces the mode for one run and
  `PROJECT_DOCS_DISPATCH_NO_SLEEP=1` makes the dispatcher print its wait.

## Rotation

The hot ledger rotates after 200 entries or 128 KiB (`run 'rotate'`, or
`check` reports `ROTATE REQUIRED` when it's overdue and blocks the gate
until you do). Rotation must:

1. copy the complete ledger to a unique `docs/history/Agentslog-*.md`;
2. verify the archived copy by hash;
3. replace the hot ledger atomically with a fresh header plus the archive
   pointer and its hash;
4. re-open a compact entry for every task still `IN_PROGRESS`, `PAUSE`,
   `REVIEW` or `ASSIGNED` at rotation time, pointing back at the archive for
   the full history — a paused task is never silently dropped by rotation.
   A `REVIEW` task is re-opened as an `IN_PROGRESS` entry by its holder
   followed by the `REVIEW` entry with its `Handoff` and `Review` lines, so
   the holder keeps the right to close it.

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
6. Inserts a `Name` column into every Roadmap table that doesn't have one
   yet (detected by header, so this also retrofits whatever shape step 4
   just produced, in the same `migrate` run): an Active work/Plan task row
   keeps its old Outcome text verbatim as `Description` and gets a derived
   `Name` (its first 10 words); a Gaps/Bugs/Technical-Debt row keeps its
   `Description` and derives `Name` from it the same way; a `## Near term`
   row's Outcome is renamed to `Name` in place, not truncated — review a
   derived Name by hand, and shorten a Near term row that still exceeds 10
   words, the same way a migrated `DECISION` or `F00-ORPHANED` row needs
   manual review.

While a project still has `docs/Agents.md`, `docs/Roadmap.md` still uses the
per-entry YAML format, or a Roadmap table has no `Name` column, `check`
fails with a message pointing at `migrate`.

## Agent identity

Use one stable id per agent, always the same text, as the `<agent>` argument:
the ledger compares names by exact equality, so `claude-sonnet-5` cannot pause
what `claude-sonnet-5-5` claimed. The optional `## Agent identity` table in
the project root `AGENTS.md` records them:

```markdown
| Agent id | Kind | Model | Role | Aliases |
|---|---|---|---|---|
| claude-sonnet-5-5 | AI | Claude Sonnet 5.5 | BOTH | claude, claude-sonnet-5 |
```

`Kind` is `HUMAN` or `AI`; `Role` is `SPEC`, `TEST`, `DEV`, `QA`, `OPS` or `BOTH`
(`DEVELOPER` is the old name of `DEV`; in classic mode a review by an agent whose role
is `DEVELOPER` warns, and in Factory mode the roles decide who may take which phase).
The section
is not required by `check`, and `init` adds it to new projects only, never to
an existing `AGENTS.md` block.

With at least one data row, `claim`, `pause`, `handoff`, `review`, `assign`
and `done` normalise `<agent>` to its `Agent id` (matching id and aliases
without regard to case). An unknown name prints `WARN: unknown agent` and is
used as typed. `check` lists unknown names found in the hot ledger (at most 10
plus a count) and never fails on them; past entries are never rewritten.
Without the section, or with no rows, nothing is normalised and nothing
warns. Each runtime adapter must use the same id every session (see
`references/adapters.md`).

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

Run `check` after documentation updates. It exits non-zero only on errors (in
Factory mode also the ones listed in `references/factory.md`):

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
- a Roadmap table with an `ID` column but no `Name` column; a Roadmap row
  with an empty Name, or a Name over 10 words;
- an Agentslog entry with a state outside `IN_PROGRESS`/`PAUSE`/`REVIEW`/
  `ASSIGNED`/`DONE`, or an entry's own Name over 10 words;
- a `REVIEW` entry without a Summary or a real Verify (a `Review: FAIL` entry
  needs no Verify), with a `Review` result other than `PASS`/`FAIL` or
  without detail; an `ASSIGNED` entry without an Assign target;
- a `PAUSE` entry without a valid category or non-empty detail;
- a `DONE` entry with an empty or `"pending"` Verify;
- two different agents both holding an open `IN_PROGRESS` on the same ID, or
  a third agent starting one right after a non-stale `REVIEW` (a
  concurrent-claim conflict, typically from a git merge race);
- a log ID that exists in neither `Roadmap.md` nor `Features.md`;
- a `Features.md` ID with no matching `DONE` in the hot log or, if rotated
  away, in `docs/history/`;
- an Agentslog entry's Name that disagrees with its ID's current Roadmap
  Name (an entry with no Name field at all is never a mismatch);
- the ledger overdue for rotation.

Warnings (do not fail the gate): `UNKNOWN` fields in Operational summaries
(expected on a fresh, not-yet-filled template — but should be zero on a
project's own maintained docs); an agent file missing its `link` block; a
stale `IN_PROGRESS` claim or `REVIEW`; with a roster, agent names in the
ledger that are neither an id nor an alias; and one summary line plus at most
the 5 most recent tasks that were claimed and closed less than
`PROJECT_DOCS_MIN_WORK_MINUTES` apart (closing a batch afterwards is
legitimate, this only says so).

A task is not complete while `check` exits non-zero.
