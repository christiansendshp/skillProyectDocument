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

<!-- context:end -->

## Near term

Work further out than `## Plan`'s next eligible task. Promote a row into
`## Plan` manually when it becomes actionable; `claim` does not read this
table.

| ID | Outcome | Acceptance check | Status | Depends on |
|---|---|---|---|---|
| — | — | — | TODO | — |

## Plan

**Vision:** a compact, Markdown-only project memory that any AI agent can read and edit with line-based tools, and that several agents can share without overlapping work.

F01 (multi-agent coordination protocol) and F02 (per-entry YAML Roadmap schema, later reverted) are closed; their verified capabilities live in `Features.md` and their history in `Agentslog.md`.

### F03 — Markdown hardening

#### F03-E01 — Pure-Markdown contract files

| ID | Outcome | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|

## Gaps, Bugs & Technical Debt

Errors, defects, or significant technical debt found by any agent. Same
trailing columns as above, so an entry can be `claim`ed and `done` like any
task. ID prefix marks the kind: `Fxx-GAP-xx` (missing capability),
`Fxx-BUG-xx` (defect), `Fxx-DEBT-xx` (technical debt).

| ID | Severity | Phase | Description | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|---|
| F03-DEBT-01 | Low | F03 | The table cell splitter in `check` and in the `claim`/`pause`/`done` positional edits (sh and ps1) treats every vertical bar as a column separator, escaped or not, so a literal bar in any cell corrupts the row. Workaround: word the cell without a bar (documented in `references/workflow.md`) | TODO | — | — | — |
| F03-DEBT-02 | Low | F03 | `migrate` emits EPIC headings at `#####` even when the project has no THEME heading, skipping heading levels (`###` then `#####`); the template uses `####`. Cosmetic only, headings are never parsed | TODO | — | — | — |
| F03-DEBT-03 | Medium | F03 | The root `AGENTS.md` block is about 4.5 KiB, over half of the 8 KiB `context` budget, so five maximum-size log entries alone (about 3.5 KiB) already exceed what is left and `context` fails. Fix by shrinking the rules block or splitting rarely-needed rules into `references/` | TODO | — | — | — |

## Out of scope

- Any YAML or JSON block inside the six canonical files.
- Enforcing cross-references between IDs: a Depends on cell is informational, `check` does not validate it.
- An end-to-end test of the `AGENTS.md`/`Agents.md` case collision on case-insensitive filesystems (needs Linux or CI).
