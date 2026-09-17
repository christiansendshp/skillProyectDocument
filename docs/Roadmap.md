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

### F01 — Multi-agent coordination protocol

```yaml
id: F01
type: PHASE
title: Multi-agent coordination protocol
status: BACKLOG
```

### F01-E02 — Coordination commands and docs

```yaml
id: F01-E02
type: EPIC
title: Coordination commands and docs
status: BACKLOG
parent: F01
```

### F02 — Human + AI Roadmap schema

```yaml
id: F02
type: PHASE
title: Human + AI Roadmap schema
status: IN_PROGRESS
description: >
  Evolve docs/Roadmap.md from Markdown tables into a per-entry yaml-block
  format with a full type taxonomy, explicit dependencies/blockers/
  decisions, and Human+AI ownership fields, per "Prompt — Evolucionar skill
  de Roadmap para proyectos Human + AI.md".
```

## Cross-cutting

No entries yet. Add a `### TYPE-ID — Title` heading and `yaml` block here for a GAP, BUG, DECISION, BLOCKER, or other cross-cutting entry when one is found.
