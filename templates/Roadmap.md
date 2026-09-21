# Roadmap

Keep `## Active work` small: only tasks in progress, paused, or next to take.
Full pending work lives in `## Plan`. Verified completed capability belongs in
`Features.md`; history belongs in `Agentslog.md`.

Every row below uses the same trailing four columns — Status, Owner, Depends
on, Pause reason — so `claim`/`pause`/`done` can edit them by position
regardless of table. `claim` moves a row from `## Plan` (or `## Gaps, Bugs &
Technical Debt`) into `## Active work`; `done` removes it once verified.

Status here is workflow state, not the epistemic Status used in
`ProductDescription.md`/`Stack_Tecnologies.md`: exactly one of `TODO`,
`IN_PROGRESS`, `PAUSE`, `DONE`. Branch/PR is not a column here — note it in
the `done`/`claim` call's summary or the Agentslog entry, so row shape stays
stable for positional edits.

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

Full VISION -> PHASE -> THEME -> EPIC -> FEATURE -> TASK -> SUBTASK hierarchy
for pending work. THEME and FEATURE are optional heading levels — omit
whichever a project doesn't need. IDs are stable and never reused.
Convention: `F01-E01-T01` (Fase-Epic-Tarea), subtasks `F01-E01-T01.01`.
Legacy `F0x-Sxx-Txx` IDs (no explicit Epic) remain valid as written; never
rewrite them to the new shape. A task row needs a real (non-placeholder)
Acceptance check before `done` can close it.

**Vision:** `UNKNOWN`

### F01 — UNKNOWN phase name

<!-- optional: #### F01-TH01 — UNKNOWN theme name -->

#### F01-E01 — UNKNOWN epic name

<!-- optional: ##### F01-E01-FT01 — UNKNOWN feature name, grouping the rows below -->

| ID | Outcome | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|
| F01-E01-T01 | UNKNOWN | UNKNOWN | TODO | — | — | — |

## Gaps, Bugs & Technical Debt

Errors, defects, or significant technical debt found by any agent. Same
trailing columns as above, so an entry can be `claim`ed and `done` like any
task. ID prefix marks the kind: `Fxx-GAP-xx` (missing capability),
`Fxx-BUG-xx` (defect), `Fxx-DEBT-xx` (technical debt).

| ID | Severity | Phase | Description | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|---|
| — | — | — | — | — | — | — | — |

## Out of scope

- `UNKNOWN`
