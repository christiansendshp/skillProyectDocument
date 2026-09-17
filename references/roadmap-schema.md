# Roadmap schema reference

`docs/Roadmap.md` describes **what exists, what must be built, what state
it's in, and how work relates** — a planning and status document. It never
describes agent behavior (how to pick a task, when to ask a human, when to
commit); that belongs in `AGENTS.md`. This file is the full reference for
`docs/Roadmap.md`'s structure; `AGENTS.md` and `references/workflow.md` link
here instead of repeating it.

## 1. Format

Every entry is:

````markdown
### TYPE-ID — Title

```yaml
id: TYPE-ID
type: TYPE
...
```
````

A `###` heading immediately followed by one blank line and one fenced `yaml`
block, then one blank line before the next entry. The heading is for humans
skimming the file; the YAML block is what tooling and agents parse. Headings
are always `###` regardless of hierarchy depth — depth is carried by the
`parent` field, never by heading level (see §3).

Two sections hold entries:

- `## Plan` — the hierarchical spine (VISION, PHASE, THEME, EPIC, FEATURE,
  TASK, SUBTASK), depth-first order for readability.
- `## Cross-cutting` — GAP, BUG, IMPROVEMENT, REFACTOR, SPIKE, DECISION,
  BLOCKER, DEPENDENCY, TECH_DEBT, DOC, TEST, SECURITY, UX.

`claim`/`pause`/`done` locate an entry by its top-level `id:` line (column 0
inside the fence) and edit a small set of fields in place; everything else in
the block is preserved verbatim. `done` removes the whole entry (heading +
block) and records it in `Features.md` — see §17.

## 2. Type taxonomy

| Type | Represents | Typical relation |
|---|---|---|
| `VISION` | The project's overall direction; at most one, root of the spine | parent of `PHASE` |
| `PHASE` | A major stage of work | child of `VISION`, parent of `THEME`/`EPIC` |
| `THEME` | A grouping of related epics within a phase (optional level) | child of `PHASE`, parent of `EPIC` |
| `EPIC` | A body of work delivering one coherent capability | child of `PHASE`/`THEME`, parent of `FEATURE`/`TASK` |
| `FEATURE` | A user-facing capability, usually decomposed into tasks | child of `EPIC`, parent of `TASK` |
| `TASK` | A concrete, independently completable unit of work | child of `EPIC`/`FEATURE`, parent of `SUBTASK` |
| `SUBTASK` | A smaller step inside a `TASK` | child of `TASK` |
| `GAP` | A missing capability or requirement found during work | `affects` any spine entry |
| `BUG` | A defect in existing behavior | `affects` any spine entry, has `expected_behavior` |
| `IMPROVEMENT` | A non-urgent enhancement to existing behavior | `affects` any spine entry |
| `REFACTOR` | Internal restructuring with no behavior change | `affects` any spine entry |
| `SPIKE` | A time-boxed investigation to reduce uncertainty | `affects`/feeds a `DECISION` or `TASK` |
| `DECISION` | A first-class pending or resolved choice | `blocks` any entry waiting on it |
| `BLOCKER` | An explicit obstacle that isn't a decision or a task | `blocks` any entry |
| `DEPENDENCY` | An external dependency (vendor, team, other system) | `blocks` any entry |
| `TECH_DEBT` | Known shortcut or deferred cleanup | `affects` any spine entry |
| `DOC` | Documentation work | `affects` any spine entry |
| `TEST` | Test-coverage work | `affects` any spine entry |
| `SECURITY` | A security-relevant gap or task | `affects` any spine entry |
| `UX` | A usability/UX issue or improvement | `affects` any spine entry |

The taxonomy is extensible: a project may add a type not listed here as long
as it's documented in this table and `check`'s type-enum validation is
updated (see `references/workflow.md`'s Gate section).

## 3. Hierarchy vs. type

The spine (`VISION -> PHASE -> THEME -> EPIC -> FEATURE -> TASK -> SUBTASK`)
is carried entirely by the `parent` field, never by heading nesting or by
type alone — a `TASK` can be a direct child of an `EPIC` (skipping
`FEATURE`/`THEME`) when those levels aren't useful for a given project.
Cross-cutting types (`GAP`, `BUG`, `DECISION`, `BLOCKER`, ...) are not part of
the spine; they reference it via `affects`, `depends_on`, `blocks`, or
`blocked_by`.

```text
PHASE-02
└── THEME-03
    └── EPIC-07
        └── FEATURE-15
            └── TASK-42
                ├── SUBTASK-42.1
                └── SUBTASK-42.2

GAP-21    affects: [FEATURE-15]
DEC-07    blocks:  [TASK-42]
```

## 4. Identification

Every entry has a stable, unique `id`. Convention: `TYPE-NN` (`PHASE-01`,
`EPIC-04`, `TASK-42`), subtasks append a dot-suffix (`SUBTASK-42.1`), and
abbreviated prefixes for common cross-cutting types (`DEC-07`, `BLOCK-03`).
An ID never changes during an entry's lifetime except through an explicit
migration. Legacy `F01-E01-T01`-style IDs from the previous table format stay
valid exactly as written and are never rewritten (ADR-001, unchanged by this
schema).

## 5. Field reference

Base fields, present on every entry:

| Field | Meaning |
|---|---|
| `id` | Stable unique identifier (required) |
| `type` | One of the taxonomy in §2 (required) |
| `title` | Short human title (required; also in the heading) |
| `status` | See §6 (required) |
| `description` | Free-text detail; `problem`/`goal`/`expected_behavior` may be used instead or alongside for a `BUG`/`GAP` |
| `created_at` / `updated_at` | ISO-8601 UTC timestamps; `updated_at` is refreshed by `claim`/`pause`/`done` |

Hierarchy and relation fields:

| Field | Meaning |
|---|---|
| `parent` | Direct parent in the spine (spine types only) |
| `phase` / `theme` / `epic` / `feature` | Optional denormalized shortcuts to ancestor IDs, for entries that want to be found without walking `parent` |
| `depends_on` | IDs this entry needs finished/decided first |
| `blocks` | IDs this entry prevents from proceeding |
| `blocked_by` | IDs currently blocking this entry (kept in sync with the blocking entry's `blocks`) |
| `affects` | For cross-cutting types: spine IDs this entry relates to |

Ownership (see §11), status/priority/progress (§6, §7, §12), acceptance
and completion (§13, §14), technical guidance (§15), and continuity (§16) —
detailed in their own sections below. Not every field applies to every type;
§2's table plus the examples in this file show what's typical per type. A
field with no value yet is either omitted or left `UNKNOWN`/empty
(`depends_on: []`) — never invented.

## 6. States

Base vocabulary, for spine and cross-cutting entries other than `DECISION`:

```text
IDEA BACKLOG READY IN_PROGRESS REVIEW TESTING BLOCKED DONE CANCELLED DEFERRED
```

`DECISION` entries use a type-specific vocabulary instead (documented
exception, per the base rule that a type may define special states when it
needs them): `PENDING`, `DECIDED`, `CANCELLED`. Do not invent additional
states outside these two vocabularies — automation and other agents rely on
exact matches.

`claim`/`pause`/`done` map onto this vocabulary:

| Action | Resulting `status` |
|---|---|
| `claim` | `IN_PROGRESS` |
| `pause LIMITE` / `pause OTRO` | `READY` (released, no structural blocker) |
| `pause ESPERA_RESPUESTA` / `pause BLOQUEO` | `BLOCKED` |
| `done` | `DONE`, then the entry is removed from Roadmap.md |

This Roadmap `status` is a *planning* state. It's distinct from an
`docs/Agentslog.md` entry's status (`IN_PROGRESS`/`PAUSE`/`DONE`), which
tracks claim/ownership lifecycle only — the log remains the authority on who
currently holds a task; see `references/workflow.md`.

## 7. Priority

`priority` is free-form but should stay short and ordered (`P0`-`P3`, or
`HIGH`/`MEDIUM`/`LOW`) — pick one convention per project and keep it.
`check` does not validate priority values.

## 8. Dependencies

```yaml
depends_on:
  - TASK-31
  - DEC-07
blocks:
  - TASK-48
  - FEATURE-22
blocked_by:
  - DEC-07
```

Both the inline flow form (`depends_on: [TASK-31, DEC-07]`) and the block
form above are accepted. A dependency can point to any valid entry ID —
`TASK`, `SUBTASK`, `FEATURE`, `EPIC`, `DECISION`, `BLOCKER`, `DEPENDENCY`, or
any other type. `check` reports a dangling reference when a `depends_on`,
`blocks`, `blocked_by`, `parent`, or `affects` value doesn't match any ID
currently in `Roadmap.md` or `Features.md`.

## 9. Decisions

```yaml
id: DEC-007
type: DECISION
title: Definir estrategia de sincronización
status: PENDING
decision_required: true
question: ...
options:
  - ...
  - ...
decision_owner:
decision:
decision_reason:
decision_date:
```

A task blocked on a decision names it in `blocked_by: [DEC-007]`; the
decision's own `blocks` field (optional) can list what it's holding up.
Resolving a decision means filling `decision`, `decision_reason`,
`decision_owner`, `decision_date`, and setting `status: DECIDED` — done by
hand, not by a CLI command. **Rules for when an AI agent may decide versus
must escalate to a human live in `AGENTS.md`, never here** — this file only
represents that a decision exists and its current state.

## 10. Blockers

```yaml
id: TASK-42
status: BLOCKED
blocked_by:
  - DEC-007
```

Represent a blocker as a reference (`blocked_by: [DEC-007]` or
`blocked_by: [BLOCK-03]`), never as free text, whenever a structured entry
can hold the reason. A standalone `BLOCKER` entry is for an obstacle that
isn't itself a task or a decision (e.g. "staging environment down"). The
distinctions this schema can express:

| Situation | Representation |
|---|---|
| Pending work, not started | `status: BACKLOG` or `IDEA` |
| Ready to start | `status: READY` |
| In development | `status: IN_PROGRESS` |
| Blocked structurally | `status: BLOCKED`, `blocked_by: [...]` |
| Waiting on a decision | `status: BLOCKED`, `blocked_by: [DEC-...]` |
| Waiting on a dependency | `status: BLOCKED`, `blocked_by: [DEP-...]` |
| Finished and verified | `status: DONE` (then moved to `Features.md`) |

## 11. Ownership: Human + AI

```yaml
owner:
  type: HUMAN
  name: Cristian
executor: AI
assigned_agent: Codex
```

`owner` is who is accountable for the work — often a human, sometimes a team.
`executor` is who actually performs it (`HUMAN` or `AI`). `assigned_agent`
names the specific agent when `executor: AI`. These are three different
facts; never assume `owner` and `executor` are the same entity. `claim` sets
`executor`/`assigned_agent`/`status`/`updated_at` — it never touches `owner`.

## 12. Progress

```yaml
progress: 65
progress_source: calculated
progress_basis:
  completed_subtasks: 5
  total_subtasks: 8
```

`progress` is 0-100. It is informational, not a state: `DONE` means
`acceptance_criteria` and `definition_of_done` are satisfied, never simply
`progress: 100`. `claim`/`pause`/`done` do not compute or write `progress`;
an agent updates it by hand as work advances.

## 13. Acceptance criteria

```yaml
acceptance_criteria:
  - id: AC-1
    description: A user can create a project with an empty name rejected client-side.
    status: pending
  - id: AC-2
    description: The API returns 400 with a field-level error for an empty name.
    status: pending
```

Prefer concrete, checkable criteria over vague descriptions. `done` does not
parse or verify this list — verifying it is the agent's job before running
`done` (see `AGENTS.md`).

## 14. Definition of done

```yaml
definition_of_done:
  - implementation_complete
  - tests_green
  - documentation_updated
  - roadmap_updated
```

This lists the conditions specific to *this* entry for considering it
finished. General operational steps that apply to every task (how to run
tests, when to update which doc, when to commit/push) belong in `AGENTS.md`,
not repeated per entry — an entry's `definition_of_done` should only name
what's specific to it.

## 15. Technical context

```yaml
technical_context:
  frontend: ...
  backend: ...
  database: ...
  api: ...
files:
  - src/booking/CreateForm.tsx
modules:
  - booking
apis:
  - POST /api/bookings
database:
  - bookings
```

Orientation for whoever picks up the entry, not a restriction on what they
may look at or change.

## 16. Next action

```yaml
next_action: >
  Analizar el formulario actual de creación de proyectos y agregar el
  selector de estrategia utilizando el patrón existente para campos
  configurables.
```

The concrete next step, updated whenever an agent pauses or hands off work —
this is what makes a task resumable by a different agent or session without
reconstructing context from the log.

## 17. Relation to other documents

- **`Roadmap.md`** — planning, state, relations, pending work (this file).
- **`Features.md`** — capabilities implemented and verified. `done` removes
  the finished entry from Roadmap.md and appends a row here; when every
  direct child of an `EPIC` has been closed, the epic itself also gets a
  rollup row. Features never duplicates Roadmap's planning detail — it's a
  compact index pointing at `log:<id>`.
- **`Agentslog.md`** — append-only history: who did what, when, decisions
  taken in the moment, problems and their resolution. It is the source of
  truth for current task ownership; Roadmap's `status`/`executor` fields on a
  claimed entry mirror it but the log wins on conflict.
- **`AGENTS.md`** — agent behavior: how to pick a task, resolve dependencies,
  decide when a decision needs a human, run tests, and when to commit, push,
  or update which document. None of that belongs in `Roadmap.md`.

No document duplicates another's core content: don't restate Features'
verified behavior in Roadmap, don't restate Agentslog's history in Roadmap,
don't put agent behavior rules in Roadmap.

## 18. Migrating the previous table format

`migrate` converts the old `ID | Outcome | Acceptance check | Status | Owner
| Depends on | Pause reason` rows (`## Active work`, `## Plan`, `## Gaps and
defects`) into this format, non-destructively:

| Old column | New field |
|---|---|
| `Outcome` | `description` |
| `Acceptance check` | one `acceptance_criteria` item |
| `Status` | `status` (`TODO` -> `BACKLOG`, `IN_PROGRESS` -> `IN_PROGRESS`, `PAUSE` -> `BLOCKED`, `DONE` -> dropped, entry already closed) |
| `Owner` | `assigned_agent` (the old column mixed agent + timestamp; it was never the accountability `owner` this schema defines — leave `owner` unset for a human to fill in) |
| `Depends on` | `depends_on` |
| `Pause reason` | folded into `description` as a note, since it isn't a stable structured blocker |
| `Severity`/`Phase` (Gaps and defects only) | `severity` / `phase` |

`type` is inferred `TASK` for `## Active work`/`## Plan` rows, `GAP` for
`## Gaps and defects` rows (or `BUG` when the old `Description` clearly names
a defect — left as `GAP` by default; adjust by hand). Old `Fase`/`Epic`
markdown headings become `PHASE`/`EPIC` entries with placeholder titles taken
from the heading text; child rows get `parent` set accordingly. Running
`migrate` twice is a no-op — it recognizes and skips content already in the
new format.

## 19. Complete example

````markdown
## Plan

### PHASE-01 — Booking core

```yaml
id: PHASE-01
type: PHASE
title: Booking core
status: IN_PROGRESS
description: >
  The minimum booking flow: create, list, cancel.
```

### EPIC-03 — Project creation

```yaml
id: EPIC-03
type: EPIC
title: Project creation
status: IN_PROGRESS
parent: PHASE-01
priority: P1
owner:
  type: HUMAN
  name: Cristian
progress: 40
progress_source: calculated
progress_basis:
  completed_subtasks: 2
  total_subtasks: 5
```

### TASK-42 — Add sync-strategy selector to the creation form

```yaml
id: TASK-42
type: TASK
title: Add sync-strategy selector to the creation form
status: BLOCKED
parent: EPIC-03
priority: P1
owner:
  type: HUMAN
  name: Cristian
executor: AI
assigned_agent: Codex
depends_on: []
blocked_by:
  - DEC-007
description: >
  The creation form needs a way to choose how the new project syncs with
  the external calendar (poll vs. webhook).
acceptance_criteria:
  - id: AC-1
    description: The form shows a strategy selector with both options.
    status: pending
  - id: AC-2
    description: The chosen strategy is persisted on the project record.
    status: pending
definition_of_done:
  - implementation_complete
  - tests_green
  - roadmap_updated
technical_context:
  frontend: src/booking/CreateForm.tsx
  backend: src/booking/projectService.ts
files:
  - src/booking/CreateForm.tsx
next_action: >
  Blocked on DEC-007. Once decided, add the selector using the existing
  pattern for configurable fields in CreateForm.tsx.
created_at: 2026-09-10T12:00:00Z
updated_at: 2026-09-16T09:30:00Z
```

## Cross-cutting

### DEC-007 — Define sync strategy

```yaml
id: DEC-007
type: DECISION
title: Define sync strategy
status: PENDING
decision_required: true
question: Should new projects sync via polling or a webhook by default?
options:
  - Polling every 5 minutes (simple, higher latency)
  - Webhook (real-time, requires public endpoint)
blocks:
  - TASK-42
```
````

This shows the full range this schema needs to answer, per entry: what it
is, why it exists, where it belongs, what state and progress it's in, who's
responsible, who executes it, what it depends on, what it blocks, why it's
blocked, whether a decision is pending, what "done" means, what technical
context to read first, and what the next concrete step is.
