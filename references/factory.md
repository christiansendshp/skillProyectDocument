# Factory mode

Factory mode turns the protocol into a production line: an agent picks work,
decides, tests, is reviewed by another agent and closes, with a human only
looking at red lines, asynchronously. It is opt-in and enforced by the scripts.
The full design is in `docs/features/ia-factory.md` (decisions D-01 to D-21 are
ADR-023 to ADR-043 in `docs/Stack_Tecnologies.md`).

## Activation

Factory mode is on when the project `AGENTS.md` has a `## Factory` section
whose `Mode` is `FACTORY` (in any letter case). Without the section, or with `Mode`
`CLASSIC` (or any value that is not `FACTORY`), every command behaves exactly as it did before
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
`AGENTS.md` or `default`); in Factory mode it also prints every setting as it is
written in `AGENTS.md`, one `Name = value` line each (a value the scripts cannot
use, such as `abc` for a number, is shown as written and the default applies).

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
default roster in `AGENTS.md`, the folders `docs/specs/` and
`docs/brain/tasks/`, the dispatcher configuration `.factory/dispatch.md` and a
block in `.gitignore` for the files the dispatcher generates (see "The
dispatcher"). `init <project> --classic` (or `PROJECT_DOCS_MODE=classic`)
creates the six-file project instead. A project the skill already manages
never changes mode on its own: `init` leaves it as it is, even with
`PROJECT_DOCS_MODE=factory`.

`migrate <project> --factory` brings an existing project to Factory mode and is
idempotent. It adds the `## Factory` section before `## Agent identity`, adds
the section or fills an empty roster with the default one, and creates
`docs/Brain.md`, `docs/specs/`, `docs/brain/tasks/` and `.factory/dispatch.md`
when missing, and appends the `.gitignore` block once. Nothing the project wrote
is replaced. If a `Mode` row already says anything other than
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
leaves room for the active work of a real project. When the five latest ledger
entries would take `context` past 8192 bytes, Factory mode shows fewer (four, three,
two or one) and says so in the heading (`the latest 3 only, to stay within 8192
bytes`) instead of failing; it fails, as classic mode does, only when the rules, the
summaries, the active work and the open tasks do not fit, and then the summaries are
what has to be compacted.

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
  be empty until the RED phase; every scenario id it names must exist, and the path
  must be relative and inside the project (no leading slash, no drive letter, no `..`
  segment).
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
| SPEC | RED | `docs/specs/<TASK-ID>.md` exists, passes the spec rules and has no `UNKNOWN` left; the last review of the spec was `PASS` from an agent other than the one advancing, and the spec is still the one that review saw: `handoff` of a spec records its SHA-256 (`- Spec-sha:`) and a changed file needs a new handoff (`Independent review` `NO` drops both) |
| RED | GREEN | the verify has `exit=N` with N not 0; the spec lists test files; they exist and, with git, are committed and unchanged; the entry records `- Red: <sha>` and `- Tests: <paths>` |
| RED or GREEN | SPEC | nothing extra: a wrong test or spec goes back to the spec |
| GREEN | RED | nothing extra: the tests were wrong |

SPEC to GREEN (no RED) is only allowed when `Require TDD` is `NO`. GREEN to REVIEW is
`handoff` and REVIEW to DONE is `done`. A spec review is the normal `handoff` to a
reviewer and `review PASS`; the author then retakes the task with `claim`.
Without git the RED to GREEN gate cannot check that the tests are committed: it
warns and records no `Red` sha. `rotate` carries the phase, the spec reviewer
(`- Spec-pass:`) and the spec hash of every open task. The command exists only in Factory mode.

## Evidence, reviews and limits

**Exit markers.** In Factory mode every `verify` that closes a step carries
`exit=N`, the exit code of the command that was run. `advance` from RED to GREEN
needs an `exit=` other than 0 (the tests must fail first); `handoff`, `review
PASS` and `done` need `exit=0`. A marker is `exit=` and digits with no letter,
digit or underscore right before or after (`pre_exit=0` and `exit=0x2` are not
markers); the first valid marker in the text counts.

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

## Recall: what to read before a task

`recall <project> <task-id>` prints, within `Recall budget bytes` (4096 by
default), what an agent needs to start or resume a task without reading the
history. Run it after `context` and read more only where it points.

1. `## Task`: the Roadmap row (id, name, description, acceptance check, status,
   owner, dependencies).
2. `## Spec summary`: the `## Summary` of the spec, if there is one.
3. `## Now`: the `## Now` of the working memory, if there is one.
4. `## Brain`: the brain rows that match the task, then `recall: N of M brain
   entries shown`.

Which rows match is deterministic and the same in both launchers. The task
tokens are the lower case ASCII words of four or more letters of the row name,
description and `Depends on`, plus every word of the `- Tags:` line of the spec
(path prefixes included). A row scores one point per distinct word of its
`Trigger` that is a task token; a trigger word with a `/` is a path prefix and
matches any task token that starts with it; `*` scores one. Rows with at least
one point are ordered by score, then `Hits` (more first), then id (ascending),
and are printed whole until the next one would not fit the budget; a row is
never cut. If the first three parts alone do not fit, `recall` fails and asks to
shorten the spec `Summary` or the working memory.

## Learning: learn and retro

`learn <project> <agent> <task-id> <kind> <name> <trigger> <lesson>` adds a row
to `docs/Brain.md` with the next `LRN-xxx` (ids of archived rows count, so an id
is never reused), `Evidence` `log:<task-id>`, `Status` `HYPOTHESIS` and `Hits`
0. It refuses a `|` in any argument, an unknown kind, a name over 10 words, an
empty name, trigger or lesson, the trigger `*` for a kind other than `DEFAULT`,
a name the brain already has, an unknown task and a brain that already holds
`Brain max entries` rows (run `rotate`). The trigger is stored in lower case, and a
tab in the text is written as a space (every command reads a tab in `Brain.md` as a
space).

`retro <project> <agent> <task-id> <used-ids|none> <learned-ids|none>` records in
the `## Retro` of the working memory which lessons the task used and which it
left (`LRN-001, LRN-003`, sorted, without repeats). Used ids must exist in the
brain; learned ids must have been written for this task. A task that had a
`Review: FAIL`, a `BLOQUEO` pause or a move from GREEN back to RED cannot say
`learned none`: it must `learn` what went wrong first. `rotate` carries that fact
(`- Struggled: yes`).

In Factory mode `done` needs the retro, and applies the rule of `retro` again: a
task that struggled after it recorded `learned none` must `learn` and run `retro` again
before it can close. It adds `- Brain: used ...; learned ...`
to the `DONE` entry, adds one hit and today's date to each used lesson and
deletes the working memory (git keeps its history).

## The brain stays small: rotate and check

`rotate` also looks at the brain. When it holds more rows than `Brain max entries`
it moves the least used rows (fewest hits, then oldest `Last used`, then lowest id)
to `docs/history/brain-archive-<date>-<seq>.md` until 75 percent of the maximum is
left. It never moves a `DEFAULT` row whose trigger is `*`. The archive is
verified with SHA-256 like the ledger archive, and the `Operational summary` of
the brain records the count and the archive (`- Last gc:`). `check` warns about
`CONFIRMED` rows with five or more hits: they are candidates to become a rule in
`AGENTS.md`, an ADR or a BR.

## Choosing work without asking: next

`next <project> <agent>` prints the id of the task the agent should work on now,
or `none`. An agent never asks which task to take and never idles: it runs `next`,
then `claim`. The answer is the first of:

1. a task the agent already holds: `IN_PROGRESS`, so a crashed run resumes, or
   `REVIEW` with an answer (`PASS` or `FAIL`), which is the holder's to close with
   `retro` and `done`, to retake with `claim`, or to pause with `BLOQUEO`; the
   answered review is returned even when no fix attempts are left;
2. a task assigned to it (`ASSIGNED`) in a phase of its role;
3. a review waiting for it: a `REVIEW` task without an answer, handed to it or to
   nobody, that it did not develop, when its role can review that phase;
4. a task paused by a quota limit (`PAUSE LIMITE`) in a phase of its role: any
   agent of the role may resume it;
5. a task assigned to another agent, in a phase of its role;
6. the first `TODO` row of `## Active work`, `## Near term`, `## Plan` and then
   `## Gaps, Bugs & Technical Debt`, in file order, whose `Depends on` ids are all
   closed (no longer in the Roadmap) and whose lane fits the role (SPEC for the
   normal lane, DEV for FAST; `BOTH` takes either);
7. only for the `Preferred reviewer`, when nothing else is left: the first closed
   normal-lane task marked `Cross-model: NO` that has no audit yet (see "Who
   reviews").

Tasks with no fix attempts left, `PAUSE` with `BLOQUEO` or a `RED-LINE`, and
tasks that are not yours are skipped. An agent that is not in the roster gets an
error.

## The fast lane

A row whose `Description` contains `Lane: FAST` skips the spec and RED. The
agent that adds the row decides: no business rule, schema, auth or public API
change, and small. The task is DEV work in phase GREEN from the start:

- `claim` writes `- Phase: GREEN`, `- Lane: FAST` and `- Base: <sha>` (the head
  at the first claim; later claims keep it). Without git there is no Base.
- Work as usual, with at least one test for any change of behavior, and keep a
  working memory (`checkpoint`).
- `handoff` compares the change since `Base` with the lane: at most `Fast lane
  max files` files and `Fast lane max lines` lines (added plus deleted), nothing
  under `Fast lane protected paths` (a prefix matches at any directory), and for
  a `Fxx-BUG-xx` row at least one test file (`.spec.`, `.test.`, `/test/`,
  `/tests/`, `/e2e/`). The ledger, Roadmap, Features, Brain, working memory,
  `docs/history/` and `docs/specs/` do not count. A rename counts as a delete and
  an add, so moving a file out of a protected path is seen. If git fails the
  handoff stops. Without git it only warns, and the reviewer has to write `fast
  lane ok` in the note.
- Review, `retro` and `done` are the same as in the normal lane; a FAST task
  with a `Review: FAIL` also has to `learn` something.

When a task outgrows the lane `handoff` fails with `task outgrew FAST lane`.
Save the work in the branch `wip/<TASK-ID>`, take `Lane: FAST` out of the row,
go back to the `Base` sha and run `advance <agent> <task-id> SPEC "..."`; the
SPEC agent claims it and the normal lane starts. `advance` takes a FAST task
only back to SPEC. `check` requires a spec without `UNKNOWN` fields for every
task in RED or GREEN of the normal lane, and none for a FAST task.

## Status with the phase and the lane

In Factory mode `status` adds a last field to every open task: the phase and the
lane, for example `F03-E01-T02 | Parse the invoice | claude-dev | IN_PROGRESS | 2h | - | GREEN NORMAL`.
A task that waits for a review or has an answer shows `REVIEW`; a task with no
recorded phase shows `SPEC`. In classic mode the output is the one it always was.

## Who reviews: cross-model marker, default reviewer, audits

- `handoff` with no reviewer in Factory mode addresses the review to `Preferred
  reviewer` (normal lane) or to `Fallback reviewer` (FAST). A setting that is
  empty, or names the agent that is handing off, leaves the handoff with no
  addressee: any QA agent takes it through `next`.
- `review` writes `- Cross-model: NO` when the first word of the `Model` column
  of the reviewer and of the holder is the same (lower case); two agents whose
  `Model` is empty or an em dash count as the same model, because nothing shows
  that they differ. A review by another model has no marker. `done` copies the marker to the DONE entry and
  `rotate` carries it.
- The `Preferred reviewer` is offered the audit of every closed normal-lane task
  marked `Cross-model: NO` that has no audit yet, but only when `next` has nothing
  else for it. It records the audit with `append-log <agent> <task-id> AUDIT
  "<summary>" "<files>" "<verify>"`. An `AUDIT` entry is valid only in Factory
  mode, never reopens a task and takes the task out of the audit queue. `rotate` carries a
  closed task that still waits for its audit as a `DONE` entry, so the queue survives
  a rotation; it does so only when a `Preferred reviewer` is set (nobody else audits) and
  for the 20 latest at most, so a queue nobody works off cannot keep the ledger over its
  limit. A problem
  found by the audit goes in as a new `Fxx-BUG-xx` row.

## digest: what a person reads

`digest [since]` (`since` is `YYYY-MM-DD` or a UTC timestamp) prints at most 4 KiB
for the human who looks in from time to time: business rules and decisions
still `HYPOTHESIS` that an agent wrote, open red lines (`PAUSE` with a `RED-LINE:`
detail), open `Fxx-GAP-xx` rows, lessons still `HYPOTHESIS`, tasks closed per
lane, failed reviews and the normal-lane tasks reviewed by one model, with how
many the preferred reviewer already audited. A longer digest is cut on a whole
line and ends with `digest: truncated, N more lines, read the ledger and the Roadmap`.

## Autonomy and red lines

In Factory mode an agent never waits for an answer from a person. What it does with a
doubt depends on the kind of doubt:

| Kind of decision | What the agent does | Where it stays |
|---|---|---|
| Technical, reversible, inside the task | Decides | The code; an `ADR-xxx` if it lasts |
| Technical and lasting, or architecture | Decides the most reversible option | An `ADR-xxx` row `HYPOTHESIS`, `CONFIRMED` once a test or a deploy proves it |
| Ambiguous product behavior | Looks for a `DEFAULT` lesson in the brain; if there is none, takes the stricter, more conservative behavior | A `BR-xxx` row `HYPOTHESIS` pinned by a scenario and a test, and the `digest` |
| A question that blocks the task | Does not work around it in silence | An `Fxx-GAP-xx` row in `## Gaps, Bugs & Technical Debt`, named in the `Depends on` of the task; the task goes to `pause BLOQUEO` and the agent takes other work |
| A red line | Prepares everything up to the edge and stops | `pause ESPERA_RESPUESTA "RED-LINE: <what and why>"`, listed by `digest` |

Red lines are: a deploy to main or to production, a destructive operation on data, any
secret, a new paid service, a weaker auth or tenant isolation, and rules about personal
data. The procedure:

```sh
sh scripts/project_docs.sh checkpoint . claude-dev F02-E01-T05 "ready up to the deploy" "wait for a person"
sh scripts/project_docs.sh pause . claude-dev F02-E01-T05 ESPERA_RESPUESTA "RED-LINE: deploys to production"
sh scripts/project_docs.sh next . claude-dev        # the next task, never this one
```

`next` skips a pause whose detail starts with `RED-LINE:` and every `BLOQUEO`; the person
answers by recording the decision (a `BR`, an `ADR` or the answer in the `Fxx-GAP` row) and
the owner retakes the task with `claim`.

## Context economy

- Start with `context` (at most 8 KiB) and `recall <task-id>` (within `Recall budget
  bytes`). Read nothing else until the task asks for it.
- Search and read by range before opening a file; the `MAP` lessons of the brain say
  which files and which test command belong to a module.
- Give a subagent the output of `recall` and the path of the spec, never the history of
  the conversation.
- Run `checkpoint` before pausing, before changing phase, before the runtime compacts
  the conversation and before any long tool output; after a compaction reload with
  `recall`.
- Each change of phase is a commit named `<TASK-ID> <PHASE>: <summary>`, and a `claim`
  is committed and pushed at once when machines share the repository.

## One task from start to finish

The normal lane with three agents and a reviewer, each line a command (`.` is the project,
`sh scripts/project_docs.sh` the launcher):

```sh
# claude-spec
next . claude-spec                                   # F02-E01-T03
claim . claude-spec F02-E01-T03 "spec the CSV export"
recall . F02-E01-T03
#   write docs/specs/F02-E01-T03.md from templates/Spec.md
checkpoint . claude-spec F02-E01-T03 "spec written" "hand it to a reviewer"
handoff . claude-spec F02-E01-T03 "spec ready" "exit=0" gemini-qa
# gemini-qa
review . gemini-qa F02-E01-T03 PASS "the scenarios cover the rules" "exit=0"
# claude-spec again
claim . claude-spec F02-E01-T03 "continue after the review"
advance . claude-spec F02-E01-T03 RED "spec reviewed, exit=0"      # assigned to the test agent
# claude-test
claim . claude-test F02-E01-T03 "write the failing tests"
#   write the tests listed in the spec, run them, commit them
checkpoint . claude-test F02-E01-T03 "tests written, they fail" "implement"
advance . claude-test F02-E01-T03 GREEN "the tests fail first, exit=1"   # assigned to the developer
# claude-dev
claim . claude-dev F02-E01-T03 "implement the export"
#   code, run the tests, never edit the recorded tests
handoff . claude-dev F02-E01-T03 "export implemented" "tests pass, exit=0" gemini-qa
# gemini-qa
review . gemini-qa F02-E01-T03 PASS "tests unchanged, the code reads well" "exit=0"
# claude-dev closes it
retro . claude-dev F02-E01-T03 LRN-001 none
done . claude-dev F02-E01-T03 "CSV export" "src/export.sh tests/" "exit=0"
```

After a `Review: FAIL` the developer runs `claim` again, fixes what the note says, `learn`s
what went wrong (mandatory) and hands off again. A fast-lane task skips the first two
blocks and starts at `claim` by the developer.

## The dispatcher: passing the turn between CLIs

`scripts/factory_dispatch.sh` and `scripts/factory_dispatch.ps1` (same behavior, same
log) keep a Factory project moving when the agents are CLIs that cannot call each
other, such as Claude Code and Gemini CLI on their own subscriptions. The ledger is
the channel: the dispatcher asks `next <agent>` for each agent, in the order of
`.factory/dispatch.md`, runs the command of the first one that has work and, when
the run ends, asks again at once. It uses no API key and no network call of its own,
and it is not part of the `project_docs` core: it only calls the core commands and
the CLIs written in `.factory/dispatch.md`.

```
factory_dispatch.sh  <project> [--watch] [--once]
factory_dispatch.ps1 <project> [--watch] [--once]
```

- `--once` makes one run and stops. `--watch` keeps looking for new work every `Idle
  seconds` instead of ending when there is none. Creating `.factory/STOP` ends the
  loop after the run in progress.
- `init` and `migrate --factory` create `.factory/dispatch.md` from
  `templates/dispatch.md` (never over an existing file) and add a block to
  `.gitignore` for `.factory/state.md` and `.factory/runs/`, which the dispatcher
  generates. Commit `dispatch.md`, not those two.

### The configuration

`.factory/dispatch.md` has two tables. `## Settings`: `Run timeout minutes`
(default 60) and `Idle seconds` (default 300). `## Agents`, one row per agent id of
the roster, in the order they are asked:

| Column | Meaning |
|---|---|
| Agent id | The id in the roster |
| Plan | Agents that share a quota share a plan: when one hits the limit, the whole plan cools down |
| Command | The non-interactive command, in backticks; `{PROMPT_FILE}` is replaced by the prompt of the run |
| Limit text | Substrings, separated by a semicolon, that a failed run prints when the quota is out |
| Cooldown minutes | How long the plan waits when the output gives no reset time |
| Max runs per day | A cap per agent and local day; a dash means none |
| Covers for | The agent whose reviews this one takes while the covered plan cools down or the covered agent failed that review twice |

Confirm each flag with the CLI's own `--help` before fixing it. Never use `claude
--bare`: it does not read the subscription login. Shell commands other than file edits
need `--allowedTools` or `permissions.allow` rules in the project's
`.claude/settings.json`.

### What a run does

1. State: expired cooldowns and the counters of other days are dropped.
2. The first agent whose plan is not cooling down, that has runs left today and whose
   `next` is a task is chosen. A task where the agent failed three times is skipped,
   and a review where it failed twice is left to the agent that covers it.
3. The prompt (`templates/dispatch-prompt.md` filled with the agent, role, task, phase
   and lane) is written to `.factory/runs/<run-id>.prompt.md`, the command runs in the
   project with `FACTORY_AGENT`, `FACTORY_TASK`, `FACTORY_PROJECT` and
   `FACTORY_PROMPT_FILE` in its environment, and its output is saved next to the prompt.
4. A run that exits with 0 and changed the ledger is good. A run that fails and prints
   one of the limit texts puts its plan in cooldown until the `resets 3:45pm` time of
   the output, or for `Cooldown minutes`; if the agent held the task, the dispatcher
   runs `checkpoint` and `pause <agent> <task> LIMITE "limit until HH:MM"` for it. Any
   other result is a failure of that agent on that task; the third one on a task it
   holds is a `pause BLOQUEO "dispatcher: 3 runs without progress"`.
5. With no one to run and a cooldown open, the dispatcher prints `sleep until HH:MM`
   and waits (`PROJECT_DOCS_DISPATCH_NO_SLEEP=1` prints it and stops, for tests).

The agent CLIs start without `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `GEMINI_API_KEY` and
`GOOGLE_API_KEY` in their environment, so each one uses the login of its subscription; a
Gemini CLI that signs in with an API key must use another way to sign in. A `Cooldown
minutes` or `Max runs per day` cell that is not a number takes 60 minutes or no cap, and a
`Cooldown minutes` of 0 counts as 60. The dispatcher writes `checkpoint` and then the
pause itself, and the pause can still be refused (a Roadmap Name over ten words, a working
memory file that is not one). After three failures it then logs `could not block`, keeps
the failure counter and skips that agent on that task, so nothing loops; delete the
`fails:` row of `.factory/state.md` to try again. After a quota limit it logs `could not
pause` and the plan simply waits for its cooldown; the agent runs again when it ends.
Waits are made in steps of at most 30 seconds, so `.factory/STOP` is read during a
cooldown.

Log lines all start with `dispatch:`. To retry a pair that failed three times without
a pause, delete its `fails:` row from `.factory/state.md`.

### Tests with fake CLIs

`scripts/tests/fake_cli.sh` and `fake_cli.ps1` stand in for the real CLIs. They read
from the file in `FAKE_CLI_SCRIPT` the first line that starts with `<agent>: ` (and
remove it) and run its actions separated by ` ;; `: `ok:<core command>` (the project is
added; a failure ends the line), `tryok:<core command>` (the same, a failure does not end
the line), `exec:<command line>` (runs it in the project, for example a test; its exit
code is the value of `{EXIT}` in the actions that follow, and of `tryok`), `write:<path>=<text>`
(a backslash and n in the text is a new line), `git:<args>`, `env:<NAME>` (prints the variable the dispatcher
handed over, to prove that API keys are not), `limit:<text>` and `fail:<text>`. The smoke
test drives the dispatcher with them, so no real quota is ever spent; `scripts/tests/dogfood.sh`
runs a whole lifecycle with them.
