# Stack technologies

> The legacy filename `Stack_Tecnologies.md` is intentionally preserved.

Every `Status` column in this file is epistemic — exactly one of `CONFIRMED`
(verified against code, a config file, or a command you ran), `HYPOTHESIS`
(a reasonable but unproven inference), or `UNKNOWN` (undefined; needs
investigation). This is a different axis from the workflow `Status` in
`Roadmap.md` (`TODO`/`IN_PROGRESS`/`PAUSE`/`DONE`).

## Operational summary

- Stack base: POSIX `sh` + Windows PowerShell 5.1 CLI scripts; no other dependency.
- Runtime: `scripts/project_docs.sh` and `.ps1`, kept at command parity.
- Datastore: Markdown files under `docs/` plus root `AGENTS.md`; no database.
- Deploy target: portable skill folder copied or symlinked into each agent runtime.
- Test command: `sh scripts/smoke_test.sh`.

<!-- context:end -->

## Architecture & Data

### Components

| Area | Technology and version | Status | Source |
|---|---|---|---|
| Application | `sh` (POSIX, no bashisms) and Windows PowerShell 5.1 | CONFIRMED | scripts/ |
| Data | Markdown files, UTF-8, no BOM | CONFIRMED | templates/, docs/ |
| Infrastructure | None: no service, network call, or external tool (no curl, python, node, or jq) | CONFIRMED | grep over scripts/ |

### Modules, schemas, ports & persistence

| Concern | Current truth | Status | Authoritative artifact |
|---|---|---|---|
| Module boundaries | `scripts/project_docs.{sh,ps1}` hold all logic; `adapters/` only redirect to `AGENTS.md`; `templates/` are copied by `init` | CONFIRMED | scripts/, adapters/, templates/ |
| Data schema | Six contract files, all plain Markdown (tables and bulleted lists); no YAML or JSON inside them, see ADR-018 | CONFIRMED | references/workflow.md |
| Ports and services | None | CONFIRMED | scripts/ |
| Persistence | Files under `docs/`; the hot ledger rotates into `docs/history/` verified by SHA-256 | CONFIRMED | references/workflow.md |
| Security boundary | No secrets in documentation by rule; nothing else applies | CONFIRMED | AGENTS.md |

## Critical commands

Deterministic commands only; a placeholder is `UNKNOWN`, never a guess.

| Purpose | Command | Status |
|---|---|---|
| Test | `sh scripts/smoke_test.sh` | CONFIRMED |
| Lint or check | `sh scripts/project_docs.sh check .` or `& scripts/project_docs.ps1 check .` | CONFIRMED |
| Typecheck | None (no typed or compiled code); syntax check: `sh -n scripts/project_docs.sh` | CONFIRMED |
| Build | None: the skill folder is used as-is | CONFIRMED |
| Migrations | `sh scripts/project_docs.sh migrate .` (docs layout migration, idempotent) | CONFIRMED |
| Dev server | None | CONFIRMED |

## Environment variables & secrets

Names and purpose only; never store a real or secret value, here or anywhere
in this repository's documentation.

| Variable | Purpose | Required | Example (Non-secret) |
|---|---|---|---|
| `PROJECT_DOCS_STALE_HOURS` | Hours after which an unattended `IN_PROGRESS` claim counts as abandoned and can be reclaimed | No | 24 |

## Technical decisions (ADRs)

Keep this table compact. Link long records from `docs/decisions/`. ADR-008 to
ADR-017 describe the per-entry YAML Roadmap schema that ADR-018 reverted; they
are kept condensed for history (the full original text is in git, commit
`e6d31c5`). A table cell must never contain a vertical bar, escaped or not
(see `F03-DEBT-01` in `Roadmap.md`).

| ID | Decision | Context/Reason | Status | Date |
|---|---|---|---|---|
| ADR-001 | New Roadmap ID convention `F01-E01-T01` (subtasks `.01`, defects `F01-BUG-001`/`F01-GAP-001`); legacy `F01-S01-T01` IDs stay valid verbatim, never rewritten | Prompt requires Epic/Subtask levels while staying backward compatible (source: prompt-mejora-skillProyectDocument.md §4) | CONFIRMED | 2026-09-15 |
| ADR-002 | `check` validates that a log/Features ID exists in Roadmap or Features; it never validates ID shape | An ID-shape regex would reject every pre-existing legacy ID. Partly superseded by ADR-019, which validates shape only for BR, ADR, and Plan rows (source: ADR-001) | CONFIRMED | 2026-09-15 |
| ADR-003 | Log entry states stay `IN_PROGRESS`/`PAUSE`/`DONE`; `BLOCKED` is represented as `PAUSE` with category `BLOQUEO` | Prompt §73 offers both options; §91 already defines `BLOQUEO` as a pause category (source: prompt-mejora-skillProyectDocument.md §5) | CONFIRMED | 2026-09-15 |
| ADR-004 | Roadmap keeps `## Near term`; `## Blocked` folds into `## Plan` (status `PAUSE`/`BLOQUEO`) | `check` already requires `## Near term`; avoids an unnecessary template migration (source: prompt-mejora-skillProyectDocument.md §4) | CONFIRMED | 2026-09-15 |
| ADR-005 | Stale `IN_PROGRESS` threshold defaults to 24h, overridable via `PROJECT_DOCS_STALE_HOURS` (identical name in sh and ps1) | Prompt asks for a configurable default (source: prompt-mejora-skillProyectDocument.md §5) | CONFIRMED | 2026-09-15 |
| ADR-006 | `context`'s open-task list uses one fixed short line per task: TASK-ID, agent, STATUS, age, reason, joined by vertical bars | §101 (list all open tasks) and the 8 KiB hard limit conflict; a compact fixed format resolves it (source: prompt-mejora-skillProyectDocument.md §5) | CONFIRMED | 2026-09-15 |
| ADR-007 | Rules file consolidates to a single root `AGENTS.md`; `docs/Agents.md` and `adapters/AGENTS.md` are merged into it | Prompt decision closed (§2); one file all runtimes read (source: prompt-mejora-skillProyectDocument.md §2) | CONFIRMED | 2026-09-15 |
| ADR-008 | [Superseded by ADR-018] Roadmap entries became a `### TYPE-ID — Title` heading plus a fenced `yaml` block; hierarchy carried by a `parent` field | Full-rewrite option chosen over a hybrid table and YAML design; the 7-level spine exceeded Markdown's 6 heading levels | CONFIRMED | 2026-09-16 |
| ADR-009 | [Superseded by ADR-018] Roadmap `status` used a 10-value planning vocabulary separate from the log's `IN_PROGRESS`/`PAUSE`/`DONE`; `pause` mapped category to `READY` or `BLOCKED` | The Roadmap tracked planning state, the log tracked who holds the pen | CONFIRMED | 2026-09-16 |
| ADR-010 | [Superseded by ADR-018] `DECISION` entries used `PENDING`/`DECIDED`/`CANCELLED` as a per-type status exception | The source prompt's own example wrote `status: PENDING` directly | CONFIRMED | 2026-09-16 |
| ADR-011 | [Superseded by ADR-018] `claim` wrote `executor`/`assigned_agent`/`status`/`updated_at` and never `owner` | The prompt separated the accountable human from the executing agent | CONFIRMED | 2026-09-16 |
| ADR-012 | [Superseded in part by ADR-018] Epic rollup detected "no children left" through each entry's `parent` field and also wrote a synthetic `DONE` log entry. Only the Features row for the epic survives, detected by ID prefix again | New IDs did not encode lineage in the ID string | CONFIRMED | 2026-09-16 |
| ADR-013 | [Superseded by ADR-018] `## Active work` and `## Near term` were dropped as physical Roadmap sections and computed from entry status | Per-entry YAML blocks had no natural move-between-sections operation | CONFIRMED | 2026-09-16 |
| ADR-014 | [Superseded by ADR-018] `roadmap_ids` addressed an entry by its top-level `id:` line alone, with no heading requirement | An inert example fence in the template had been a live, removable entry | CONFIRMED | 2026-09-16 |
| ADR-015 | [Superseded by ADR-018] `done`'s backward search for an entry heading aborted at a section heading or another fence | Defense in depth against deleting unrelated content | CONFIRMED | 2026-09-16 |
| ADR-016 | [Superseded by ADR-018] `claim` rejected a `DECISION` target | `DECISION` status vocabulary had no `IN_PROGRESS` | CONFIRMED | 2026-09-16 |
| ADR-017 | [Superseded by ADR-018] `check` errored on a `yaml` block without an `id:` line and capped the computed Active work summary at 20 entries | An id-less block was invisible to every id-based primitive; an uncapped summary could exceed the 8 KiB budget | CONFIRMED | 2026-09-16 |
| ADR-018 | Contract files revert to pure Markdown: `Roadmap.md` uses tables again (`## Active work`, `## Near term`, `## Plan` with PHASE/EPIC headings plus task-row tables, `## Gaps, Bugs & Technical Debt`, `## Out of scope`); no YAML or JSON inside the six canonical files. Roadmap Status is `TODO`/`IN_PROGRESS`/`PAUSE`/`DONE`. Supersedes ADR-008 to ADR-011 and ADR-013 to ADR-017 in full and ADR-012 in part | The per-entry YAML format was too fragile for the line-based tools (sed, awk, diff) the skill depends on: one indentation slip corrupted an entry. `migrate` converts a YAML Roadmap back to tables without losing IDs | CONFIRMED | 2026-09-21 |
| ADR-019 | `check` enforces canonical IDs (`BR-xxx` in Business rules, `ADR-xxx` in Technical decisions, a Roadmap Plan row starting `Fnn`) and two disjoint Status vocabularies: `CONFIRMED`/`HYPOTHESIS`/`UNKNOWN` in Product and Stack fact tables, `TODO`/`IN_PROGRESS`/`PAUSE`/`DONE` in Roadmap. Cross-references (a Depends on cell) stay informational | Plain tables trade relational integrity for parse robustness; the strict enums stop `N/A` or free text from passing as a fact | CONFIRMED | 2026-09-21 |
| ADR-020 | Every Roadmap table gets a `Name` column (<= 10 words) right after `ID`; the rest of the detail goes in `Description` (or the row's own free-text column for `## Near term`, which has none). `claim`/`pause`/`done` refuse a row whose Name is missing or too long and copy it verbatim into the Agentslog entry's header as a 5th field; `check` enforces the word limit per table and cross-validates that the log's Name for an ID still matches the Roadmap's. `migrate` retrofits a pre-Name Roadmap non-destructively: old Outcome/Description text is kept verbatim, a derived (first 10 words) Name is added and flagged for review | A free-text Outcome/Description cell let an agent bury the actual task under a paragraph, which defeats a compact Roadmap; a mandatory short Name, enforced at `claim` time rather than left to convention, forces a scannable title while the Agentslog copy (not a second manual field) keeps the two documents from disagreeing | CONFIRMED | 2026-10-01 |

## Out of scope

- A runtime service, database, or network dependency.
- Tooling beyond `sh` and PowerShell (no Python, Node, or jq).
- YAML or JSON inside the six canonical files.
