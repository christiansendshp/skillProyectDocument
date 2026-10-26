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

The classic block tells agents to escalate product and cost choices to a human.
In Factory mode `## Factory` replaces that, so a new Factory project's block
has a pointer bullet instead, and `migrate --factory` adds the same bullet right
after the classic one (it never edits or removes it, and skips a block whose
bullet was reworded).

The `## Factory` section of `templates/AGENTS.factory.md` stays under 1.5 KiB
and a fresh Factory project's `context` stays at or below 6912 bytes, which
leaves room for the active work of a real project.
