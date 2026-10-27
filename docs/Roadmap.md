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

| ID | Name | Description | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|---|
| F06-E05-T03 | Dogfood a full factory lifecycle end to end | Section 8 | Section 9 checklist fully met | IN_PROGRESS | claude-sonnet-5-5@2026-10-27T19:24:43Z | F06-E05-T02 | — |

<!-- context:end -->

## Near term

Work further out than `## Plan`'s next eligible task. Promote a row into
`## Plan` manually when it becomes actionable; `claim` does not read this
table.

| ID | Name | Acceptance check | Status | Depends on |
|---|---|---|---|---|
| — | — | — | TODO | — |

## Plan

**Vision:** a compact, Markdown-only project memory that any AI agent can read and edit with line-based tools, and that several agents can share without overlapping work.

F01 (multi-agent coordination protocol) and F02 (per-entry YAML Roadmap schema, later reverted) are closed; their verified capabilities live in `Features.md` and their history in `Agentslog.md`.

### F03 — Markdown hardening

#### F03-E01 — Pure-Markdown contract files

| ID | Name | Description | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|---|

### F04 — Name and Description taxonomy

#### F04-E01 — Short Name, long Description

| ID | Name | Description | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|---|

### F05 — Review stage and agent identity

Spec: the handoff prompt in the PM Hub repo (docs/prompts/skill-review-handoff-and-identity.md). Everything lives in the ledger; Roadmap Status values and columns do not change.

#### F05-E01 — Review stage in the ledger

| ID | Name | Description | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|---|

#### F05-E02 — Agent identity and warnings

| ID | Name | Description | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|---|

#### F05-E03 — Templates, docs and evals

| ID | Name | Description | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|---|

### F06 — IA Factory mode

Spec: docs/features/ia-factory.md (closed decisions D-01 to D-21 are ADR-023 onward).

#### F06-E01 — Factory mode and autonomy policy

| ID | Name | Description | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|---|

#### F06-E02 — Spec and TDD production line

| ID | Name | Description | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|---|

#### F06-E03 — Brain and context economy

| ID | Name | Description | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|---|

#### F06-E04 — Digest and status

| ID | Name | Description | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|---|

#### F06-E06 — CLI dispatcher

| ID | Name | Description | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|---|

#### F06-E05 — Docs, evals and dogfooding

| ID | Name | Description | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|---|

## Gaps, Bugs & Technical Debt

Errors, defects, or significant technical debt found by any agent. Same
trailing columns as above, so an entry can be `claim`ed and `done` like any
task. ID prefix marks the kind: `Fxx-GAP-xx` (missing capability),
`Fxx-BUG-xx` (defect), `Fxx-DEBT-xx` (technical debt).

| ID | Name | Severity | Phase | Description | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|---|---|
| F03-DEBT-01 | A literal bar in a table cell corrupts the row | Low | F03 | The table cell splitter in `check` and in the `claim`/`pause`/`done` positional edits (sh and ps1) treats every vertical bar as a column separator, escaped or not, so a literal bar in any cell corrupts the row. Workaround: word the cell without a bar (documented in `references/workflow.md`) | TODO | — | — | — |
| F03-DEBT-02 | migrate skips a heading level without a THEME | Low | F03 | `migrate` emits EPIC headings at `#####` even when the project has no THEME heading, skipping heading levels (`###` then `#####`); the template uses `####`. Cosmetic only, headings are never parsed | TODO | — | — | — |
| F05-DEBT-01 | Age rounds differently in sh and PowerShell | Low | F05 | status and the stale checks compute age in whole hours: sh truncates toward zero and PowerShell floors, so an entry timestamped in the future shows 0h in sh and -1h in PowerShell. Only visible with a wrong clock or a hand-written future timestamp | TODO | — | — | — |
| F05-DEBT-02 | The em dash verify marker is untested in PowerShell | Low | F05 | The smoke test passes arguments to PowerShell through a command string, which mangles a non-ASCII argument, so the em dash verify marker is only exercised through the sh launcher; the PowerShell comparison itself is covered by the other markers | TODO | — | — | — |
| F05-DEBT-03 | A rotation can fake an instant close | Low | F05 | rotate re-opens a task that was in REVIEW as an IN_PROGRESS entry stamped with the time of its last entry, so a done within 5 minutes of that last entry looks like a task claimed and closed minutes apart. Rare; fix by ignoring carried-forward IN_PROGRESS entries when measuring | TODO | — | — | — |

## Out of scope

- Any YAML or JSON block inside the six canonical files.
- Enforcing cross-references between IDs: a Depends on cell is informational, `check` does not validate it.
- An end-to-end test of the `AGENTS.md`/`Agents.md` case collision on case-insensitive filesystems (needs Linux or CI).
