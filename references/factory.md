# Factory mode

Factory mode turns the protocol into a production line: an agent picks work,
decides, tests, is reviewed by another agent and closes, with a human only
looking at red lines, asynchronously. It is opt-in and enforced by the scripts.
The full design is in `docs/features/ia-factory.md` (decisions D-01 to D-21 are
ADR-023 to ADR-043 in `docs/Stack_Tecnologies.md`).

## Activation

Factory mode is on when the project `AGENTS.md` has a `## Factory` section
whose `Mode` is `FACTORY`. Without the section, or with `Mode` `CLASSIC` (or any
value that is not `FACTORY`), every command behaves exactly as it did before
Factory mode existed (BR-008).

```markdown
## Factory

| Setting | Value |
|---|---|
| Mode | FACTORY |
| WIP per agent | 1 |
```

A row that is missing, empty or just an em dash takes its default:

| Setting | Default |
|---|---|
| Mode | FACTORY (when the section exists) |
| Require TDD | YES |
| Independent review | YES |
| WIP per agent | 1 |
| Max fix attempts | 3 |
| Fast lane max files | 5 |
| Fast lane max lines | 150 |
| Fast lane protected paths | prisma/ migrations/ auth/ rls/ security/ |
| Preferred reviewer | (empty) |
| Fallback reviewer | (empty) |
| Recall budget bytes | 4096 |
| Brain max entries | 80 |

A numeric setting must be a whole number from 1 to 999999999 (leading zeros are
ignored); anything else, including 0, text or a huge number, takes the default.

`PROJECT_DOCS_MODE=classic` or `factory` overrides the file (it exists for
tests and for forcing one mode from a script); any other value is ignored.

`mode <project>` prints which mode applies and where it came from (`env`,
`AGENTS.md` or `default`); in Factory mode it also prints every effective
setting, one `Name = value` line each.

## The brain file

In Factory mode `docs/Brain.md` is the seventh contract file: reusable lessons
and a module map, one row per entry, read by `recall` and never loaded whole.
`templates/Brain.md` ships three seed rows. Columns: `ID`, `Name`, `Kind`,
`Trigger`, `Lesson`, `Evidence`, `Status`, `Hits`, `Last used`.

- `ID` is `LRN-xxx` (three digits or more) and is never reused.
- `Name` has at most 10 words, like a Roadmap Name.
- `Kind` is `PITFALL`, `PATTERN`, `RECIPE`, `DEFAULT` or `MAP`.
- `Trigger`, `Lesson` and `Evidence` are never empty; `*` as a `Trigger` means
  always include the row.
- `Status` is `CONFIRMED` or `HYPOTHESIS`; `Hits` is a number; `Last used` is
  `YYYY-MM-DD` or an em dash.
- A `|` never appears inside a cell, so a row with another column count is an
  error.

`check` validates all of this only in Factory mode and fails when the table has
more rows than `Brain max entries`. In classic mode the file is ignored.

## Starting a project and migrating one

`init <project>` creates a project the skill does not manage yet in Factory
mode: the six contract files, `docs/Brain.md`, a `## Factory` section and the
default roster in `AGENTS.md`, and the folders `docs/specs/` and
`docs/brain/tasks/`. `init <project> --classic` (or `PROJECT_DOCS_MODE=classic`)
creates the six-file project instead. A project the skill already manages
never changes mode on its own: `init` leaves it as it is, even with
`PROJECT_DOCS_MODE=factory`.

`migrate <project> --factory` brings an existing project to Factory mode and is
idempotent. It adds the `## Factory` section before `## Agent identity`, adds
the section or fills an empty roster with the default one, and creates
`docs/Brain.md`, `docs/specs/` and `docs/brain/tasks/` when missing. Nothing
the project wrote is replaced. If a `Mode` row already says anything other than
`FACTORY`, the command keeps it and tells you to edit it. `migrate` without the
flag never adds Factory files.

Both launchers take the flags after the project (`init <project> --classic`) or
with no project at all (`init --classic` works on the current folder). Flags
are case-sensitive. If `AGENTS.md` has CRLF line endings, `migrate --factory`
rewrites it with LF and says so, because the section inserts match whole lines.

The classic block tells agents to escalate product and cost choices to a human.
In Factory mode `## Factory` replaces that, so a new Factory project's block
has a pointer bullet instead, and `migrate --factory` adds the same bullet right
after the classic one (it never edits or removes it, and skips a block whose
bullet was reworded).

The `## Factory` section of `templates/AGENTS.factory.md` stays under 1.5 KiB
and a fresh Factory project's `context` stays at or below 6912 bytes, which
leaves room for the active work of a real project.

## Specs

Work that goes through the SPEC phase has an executable spec in
`docs/specs/<TASK-ID>.md`, made from `templates/Spec.md` (replace `{TASK}` and
`{NAME}`; every unfilled field says `UNKNOWN`). Sections, in this order:

- `## Summary` with `- Goal:`, `- Rules:` (`BR-xxx` ids or an em dash) and
  `- Tags:` (words and path prefixes `recall` matches), then the
  `<!-- context:end -->` marker.
- `## Scenarios`, a table `ID | Given | When | Then | Level | Justification`.
  IDs are `S01`, `S02`, ... (unique). `Level` is `UNIT`, `INTEGRATION`,
  `CONTRACT`, `E2E` or `NONE`; each scenario has one level (one behavior, one
  level). `NONE` needs a `Justification` (docs, config, infra).
- `## Tests`, one line per test file: `- path/to/file.spec (S01, S02)`. It may
  be empty until the RED phase; every scenario id it names must exist.
- `## Out of scope`.

In Factory mode `check` validates every file in `docs/specs/`: a missing
section, a bad table, an unknown level or a test entry that names a missing
scenario is an error. Fields still `UNKNOWN` are one warning per spec, since a
draft is normal during SPEC; `advance` refuses to leave SPEC while any is left.
Only `docs/specs/*.md` files (lower case extension, no leading dot) are specs.
In classic mode `docs/specs/` is ignored.

## Roles and the phase of a task

The `## Agent identity` table gives each agent one role: `SPEC`, `TEST`, `DEV`,
`QA`, `OPS` or `BOTH` (any phase; `DEVELOPER` is the old name of `DEV`). A task
moves through the phases `SPEC`, `RED`, `GREEN`, `REVIEW`, `DONE`, and each
phase belongs to one role: SPEC to `SPEC`, RED to `TEST`, GREEN to `DEV`,
REVIEW to `QA`. A task's phase is the last `- Phase:` line of its ledger
entries; with none, it is `SPEC`.

In Factory mode:

- `claim` records `- Phase: <phase>` and refuses an agent whose role does not
  match the phase (or that is not in the table), with a message naming the role
  the phase needs. A task assigned to another agent id can be claimed without a
  warning when the role matches.
- `check` fails when the roster has fewer than two agents, none with the role
  `QA` (or `BOTH`), or a role outside the list above (roles are upper case).

A task whose phase is none of those four is refused whoever asks. `rotate` carries
the phase of every open task into the new ledger segment.

In classic mode none of this applies: `claim` ignores roles and writes no phase.

## Working memory and checkpoint

`checkpoint <project> <agent> <task-id> <step> <next>` keeps the working memory
of a task in `docs/brain/tasks/<TASK-ID>.md` (made from
`templates/WorkingMemory.md` the first time). It rewrites `## Now` (`Step`,
`Next`, `Attempts` = the task's `Review: FAIL` count, `Updated`) and adds one
`- <time> <agent>: <step>` line to `## Trail`; `## Retro` is filled by `retro`.
Run it before any long step, before pausing, before compacting and before a
phase change: whoever resumes the task cold, including after a runtime
compaction, reads this file (through `recall`) instead of the whole history.
In Factory mode `pause` refuses a task that has no `## Now`. `check` validates
the files. A `|` in `step` or `next` becomes `/`, like in the PowerShell
launcher. The command exists only in Factory mode.

## Moving a task between phases: advance

`advance <project> <agent> <task-id> <next-phase> <verify> [to-agent]` is how a
task changes phase. Only the agent that holds the task (status `IN_PROGRESS`)
can run it, the task needs a working memory (`checkpoint`), and it writes an
`ASSIGNED` entry with `- Phase: <next-phase>` and `- Assign: <agent>`. The Roadmap row
stays `IN_PROGRESS` and only its owner changes. `to-agent` must have the role of
the new phase (or `BOTH`); without it the first roster agent with that role is
used. The next agent runs `claim`.

| From | To | What the script checks |
|---|---|---|
| SPEC | RED | `docs/specs/<TASK-ID>.md` exists, passes the spec rules and has no `UNKNOWN` left; the last review of the spec was `PASS` from an agent other than the one advancing (`Independent review` `NO` drops this) |
| RED | GREEN | the verify has `exit=N` with N not 0; the spec lists test files; they exist and, with git, are committed and unchanged; the entry records `- Red: <sha>` and `- Tests: <paths>` |
| RED or GREEN | SPEC | nothing extra: a wrong test or spec goes back to the spec |
| GREEN | RED | nothing extra: the tests were wrong |

SPEC to GREEN (no RED) is only allowed when `Require TDD` is `NO`. GREEN to REVIEW is
`handoff` and REVIEW to DONE is `done`. A spec review is the normal `handoff` to a
reviewer and `review PASS`; the author then retakes the task with `claim`.
Without git the RED to GREEN gate cannot check that the tests are committed: it
warns and records no `Red` sha. `rotate` carries the phase and the spec reviewer
(`- Spec-pass:`) of every open task. The command exists only in Factory mode.

## Evidence, reviews and limits

**Exit markers.** In Factory mode every `verify` that closes a step carries
`exit=N`, the exit code of the command that was run. `advance` from RED to GREEN
needs an `exit=` other than 0 (the tests must fail first); `handoff`, `review
PASS` and `done` need `exit=0`. The first `exit=` in the text counts.

**Tests do not change in GREEN.** `handoff` of a GREEN task compares the test
files recorded at RED (the `- Tests:` line, with the `- Red: <sha>` of the commit)
against that sha, committed or not, and refuses if any differs: a wrong test goes
back to SPEC with `advance`. Without git it only warns, and the reviewer has to
write `tests unchanged` in the note of the `review PASS`. `handoff` also needs a
working memory (`checkpoint`) and is for SPEC and GREEN only; RED leaves with
`advance`.

**Reviews are independent.** In Factory mode the warnings of classic mode are
errors: a review by the agent that holds the task (unless `Independent review` is
`NO`), a reviewer whose role is not `QA` or `BOTH` (a `SPEC` agent may review a
spec), a reviewer that is not in the roster, and a `done` with no `Review: PASS`,
with no ledger entries or whose verify has no `exit=0`.

**Limits per agent and per task.** `claim` refuses an agent that already has
`WIP per agent` tasks in progress (a task waiting for review does not count) and
refuses a task that used `Max fix attempts`: each `Review: FAIL` and each move from
GREEN back to RED is one attempt. Then the holder runs `pause ... BLOQUEO` (allowed
from REVIEW in Factory mode) and writes the lesson; the count starts again after a
`BLOQUEO` pause. `rotate` carries the attempts, `Red` and `Tests` of open tasks.
In classic mode the ledger lines `Phase`, `Spec-pass`, `Red`, `Tests` and
`Attempts` are ignored and never carried.
