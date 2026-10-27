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
| F06-E02-T04 | Exit markers and immutable tests from RED sha | D-06 and D-07 including the no-git warning | Changing a recorded test after RED makes handoff fail | IN_PROGRESS | claude-sonnet-5-5@2026-10-27T03:04:06Z | F06-E02-T02 | — |
| F06-E03-T03 | Recall command with deterministic ranking and budget | Algorithm in section 4.5 | Same bytes in sh and ps1; never above budget; whole rows only | IN_PROGRESS | claude-sonnet-5-5@2026-10-27T03:03:57Z | F06-E03-T01, F06-E03-T02, F06-E02-T01 | — |
| F06-E03-T04 | Learn and retro commands with mandatory lessons | retro rules and done integration per section 4.5 | learned none refused after a FAIL; Hits updated on done | IN_PROGRESS | claude-sonnet-5-5@2026-10-27T03:03:59Z | F06-E03-T03 | — |
| F06-E03-T05 | Brain garbage collection in rotate and promotion warning | Archive to 75 percent of cap with SHA-256 check | Over-cap fixture ends under cap; archive verified | IN_PROGRESS | claude-sonnet-5-5@2026-10-27T03:04:01Z | F06-E03-T01 | — |
| F06-E02-T06 | Fast lane with size limits and promotion to SPEC | Section 4.3.1; Lane and Base lines; BUG rows need a test file | Every fast lane limit has a passing and a failing smoke case | IN_PROGRESS | claude-sonnet-5-5@2026-10-27T03:04:04Z | F06-E02-T04, F06-E02-T05 | — |
| F06-E04-T02 | Show phase in status output | Factory only, phase and lane | Classic status unchanged byte for byte | IN_PROGRESS | claude-sonnet-5-5@2026-10-27T02:50:46Z | F06-E02-T02 | — |
| F06-E04-T03 | Cross-model marker, default reviewers and audits | Section 4.8; handoff default reviewer by lane; AUDIT entries | Same-model review marked; audit never reopens a task | IN_PROGRESS | claude-sonnet-5-5@2026-10-27T02:50:47Z | F06-E02-T05, F06-E02-T06 | — |
| F06-E04-T01 | Digest command for asynchronous human review | Contents per section 4.7, at most 4 KiB | Fixture with every item kind lists them all | IN_PROGRESS | claude-sonnet-5-5@2026-10-27T02:50:49Z | F06-E03-T04, F06-E04-T03 | — |
| F06-E01-T06 | Next returns a reviewed task to its holder | next gives a task in REVIEW with an answer back to the agent that holds it, first of all and even with no attempts left, so it can close, retake or pause it | The holder is offered the task after PASS and after FAIL; nobody else is | IN_PROGRESS | claude-sonnet-5-5@2026-10-27T02:50:51Z | F06-E01-T04 | — |
| F06-E06-T01 | Dispatch config templates and gitignore block | templates/dispatch.md and dispatch-prompt.md; init and migrate add them | Idempotent on a second run; gitignore block not duplicated | IN_PROGRESS | claude-sonnet-5-5@2026-10-27T02:50:52Z | F06-E01-T02 | — |
| F06-E06-T02 | Dispatcher loop in PowerShell with limit detection | Section 4.9 steps 1 to 6 | All dispatcher smoke cases pass through ps1 | IN_PROGRESS | claude-sonnet-5-5@2026-10-27T02:50:58Z | F06-E06-T01, F06-E01-T04, F06-E04-T03 | — |
| F06-E06-T03 | Dispatcher loop in sh with identical behavior | Same as the PowerShell loop | Same logs and ledger results as ps1 on the same script | IN_PROGRESS | claude-sonnet-5-5@2026-10-27T02:50:59Z | F06-E06-T02 | — |
| F06-E06-T04 | Fake CLIs and dispatcher smoke tests | scripts/tests fake_cli in sh and ps1 driven by a script file | Cases 18 to 25 of section 7 pass | IN_PROGRESS | claude-sonnet-5-5@2026-10-27T02:51:01Z | F06-E06-T03 | — |
| F06-E05-T01 | Document factory mode across skill and references | Files in section 5 | Every new command documented in SKILL, README and workflow | IN_PROGRESS | claude-sonnet-5-5@2026-10-27T03:24:30Z | F06-E06-T04 | — |
| F06-E05-T02 | Add factory evals and adjust six-file evals | Section 7 list | evals.json valid; each new eval maps to a smoke case | IN_PROGRESS | claude-sonnet-5-5@2026-10-27T03:27:40Z | F06-E05-T01 | — |
| F06-E01-T07 | Context drops older log entries to fit in Factory mode | In Factory mode context shows fewer than five latest entries when the whole would pass 8 KiB, and says so in the heading; it still fails when the rest does not fit | The dogfooding run ends with context and check inside the budget; classic context is unchanged | IN_PROGRESS | claude-sonnet-5-5@2026-10-27T03:39:12Z | F06-E01-T06 | — |

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
| F06-E05-T03 | Dogfood a full factory lifecycle end to end | Section 8 | Section 9 checklist fully met | TODO | — | F06-E05-T02 | — |

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
| F06-DEBT-02 | Bind the spec review to the spec content | Low | F06 | QA found that a spec edited after its Review: PASS still opens the SPEC to RED gate because nothing hashes the spec; record a SHA-256 of the spec at the SPEC handoff and compare it at advance | TODO | — | — | — |
| F06-DEBT-03 | Reject test paths outside the project | Low | F06 | QA found that a tracked test path such as ../root.test.sh in a sub-project, an absolute path or a drive path passes the spec check and the RED gate; the spec rules should require a relative path without .. segments | TODO | — | — | — |
| F06-DEBT-04 | Make the docs lock exclusive and race free | Medium | F06 | QA found that the PowerShell lock (New-Item on docs/.lock) is not exclusive, so four parallel learn calls lost a lesson, and that the sh lock can read a vanished directory as stale through the stat -f fallback and stop with File: unbound variable; use an exclusive create and treat an unreadable age as a retry. The dispatcher runs one CLI at a time, so this only matters for people running commands by hand next to it | TODO | — | — | — |

## Out of scope

- Any YAML or JSON block inside the six canonical files.
- Enforcing cross-references between IDs: a Depends on cell is informational, `check` does not validate it.
- An end-to-end test of the `AGENTS.md`/`Agents.md` case collision on case-insensitive filesystems (needs Linux or CI).
