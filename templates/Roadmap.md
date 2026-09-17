# Roadmap

Every entry is a `### TYPE-ID — Title` heading followed by a fenced `yaml`
block; the block is the source of truth, the heading is for humans skimming
the file. IDs are stable and never reused except through an explicit
migration. See `references/roadmap-schema.md` for the full type taxonomy,
field reference, state vocabulary, and a complete worked example.

Hierarchy and type are separate. `## Plan` holds the VISION -> PHASE -> THEME
-> EPIC -> FEATURE -> TASK -> SUBTASK spine, linked by each entry's `parent`
field, not by heading depth (headings stay flat `###`). `## Cross-cutting`
holds GAP, BUG, IMPROVEMENT, REFACTOR, SPIKE, DECISION, BLOCKER, DEPENDENCY,
TECH_DEBT, DOC, TEST, SECURITY, and UX entries, which relate to any level via
`affects`, `depends_on`, `blocks`, or `blocked_by` instead of `parent`.

`claim`/`pause`/`done` edit an entry's `status`, `executor`, `assigned_agent`,
and `updated_at` fields in place; `done` also removes the whole entry
(heading + block) and records it in `Features.md`. Every other field is
edited by hand. Legacy `F01-E01-T01`-style rows from the previous table
format remain valid exactly as written; `migrate` converts them into this
format without discarding data.

This file only holds Roadmap *content* (what exists, what state it's in, how
entries relate). Agent behavior — how to pick the next task, when a decision
needs a human, how to run tests, when to commit — belongs in `AGENTS.md`, not
here.

## Plan

### PHASE-01 — UNKNOWN phase name

```yaml
id: PHASE-01
type: PHASE
title: UNKNOWN phase name
status: BACKLOG
description: >
  UNKNOWN
```

### EPIC-01 — UNKNOWN epic name

```yaml
id: EPIC-01
type: EPIC
title: UNKNOWN epic name
status: BACKLOG
parent: PHASE-01
description: >
  UNKNOWN
```

### TASK-01 — UNKNOWN task name

```yaml
id: TASK-01
type: TASK
title: UNKNOWN task name
status: BACKLOG
parent: EPIC-01
owner:
  type: UNKNOWN
  name: UNKNOWN
executor: UNKNOWN
depends_on: []
description: >
  UNKNOWN
acceptance_criteria:
  - id: AC-1
    description: UNKNOWN
    status: pending
definition_of_done:
  - acceptance_criteria_met
next_action: >
  UNKNOWN
```

## Cross-cutting

No entries yet. Add a `### TYPE-ID — Title` heading and `yaml` block here for
a GAP, BUG, DECISION, BLOCKER, or other cross-cutting entry when one is
found — same shape as `## Plan` entries above. A `DECISION` example is in
`references/roadmap-schema.md` §9.

Never add a fenced `yaml` block without a `### TYPE-ID — Title` heading
directly above it: tooling locates every entry by scanning for ` ```yaml `
fences, so a headless one becomes a real, addressable (and `done`-removable)
entry.
