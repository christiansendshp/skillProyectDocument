# Roadmap

Keep `## Active work` small: only tasks in progress, paused, or next to take.
Full pending work lives in `## Plan`. Verified completed capability belongs in
`Features.md`; history belongs in `Agentslog.md`.

Every row below uses the same trailing four columns — Status, Owner, Depends
on, Pause reason — so `claim`/`pause`/`done` can edit them by position
regardless of table. `claim` moves a row from `## Plan` (or `## Gaps and
defects`) into `## Active work`; `done` removes it once verified.

## Active work

| ID | Outcome | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|
| — | — | — | — | — | — | — |

<!-- context:end -->

## Near term

Work further out than `## Plan`'s next eligible task. Promote a row into
`## Plan` manually when it becomes actionable; `claim` does not read this
table.

| ID | Outcome | Acceptance check | Status | Depends on |
|---|---|---|---|---|
| — | — | — | TODO | — |

## Plan

Full Fase -> Epic -> Tarea -> Subtarea hierarchy for pending work. IDs are
stable and never reused. New convention: `F01-E01-T01` (Fase-Epic-Tarea),
subtasks `F01-E01-T01.01`. Legacy `F0x-Sxx-Txx` IDs (no explicit Epic) remain
valid as written; never rewrite them to the new shape.

### F01 — UNKNOWN phase name

#### F01-E01 — UNKNOWN epic name

| ID | Outcome | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|
| F01-E01-T01 | UNKNOWN | UNKNOWN | TODO | — | — | — |

## Gaps and defects

Errors or significant gaps found by any agent. Same trailing columns as
above, so a defect can be `claim`ed and `done` like any task.

| ID | Severity | Phase | Description | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|---|
| — | — | — | — | — | — | — | — |
