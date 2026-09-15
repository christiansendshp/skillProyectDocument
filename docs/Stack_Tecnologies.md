# Stack technologies

> The legacy filename `Stack_Tecnologies.md` is intentionally preserved.

## Operational summary

- Runtime: POSIX `sh` scripts + Windows PowerShell 5.1/7 scripts, invoked as a CLI.
- Architecture: template-driven file scaffolding; Roadmap/Agentslog are markdown files parsed with `awk` (sh) and text ops (ps1).
- Data: markdown files under `docs/` (and root `AGENTS.md`); no database.
- Test command: `evals/evals.json` scenarios; smoke test script (added this initiative).
- Delivery: portable skill folder (`SKILL.md` + `scripts/` + `templates/` + `adapters/`), copied or symlinked into each runtime.

<!-- context:end -->

## Components

| Area | Technology and version | Source | Status |
|---|---|---|---|
| Application | `sh` (POSIX, no bashisms) + Windows PowerShell 5.1/7 | scripts/ | CONFIRMED |
| Data | Markdown files (UTF-8, no BOM) | templates/, docs/ | CONFIRMED |
| Infrastructure | N/A (no runtime service) | — | N/A |

## Architecture anchors

| Concern | Current truth | Authoritative artifact |
|---|---|---|
| Boundaries | `scripts/project_docs.{sh,ps1}` is the only logic; adapters only redirect to it | scripts/, adapters/ |
| Data flow | `init` scaffolds -> agent edits docs -> `append-log`/`claim`/`pause`/`done` records state -> `context` reads bounded slices -> `check` validates -> `rotate` archives | references/workflow.md |
| Security | No secrets in docs by rule; nothing else applies | references/workflow.md |

## Commands

| Purpose | Command | Status |
|---|---|---|
| Smoke test | `sh scripts/smoke_test.sh` (added this initiative) | HYPOTHESIS |
| Lint or check | `sh scripts/project_docs.sh check .` / `& scripts/project_docs.ps1 check .` | CONFIRMED |

## Environment variables

Names and purpose only; never store real values.

| Name | Purpose | Required |
|---|---|---|
| `PROJECT_DOCS_STALE_HOURS` | Overrides the default 24h threshold for an abandoned `IN_PROGRESS` claim | No |

## Decisions

Keep this table compact. Link long records from `docs/decisions/`.

| ID | Date | Decision | Reason | Status | Detail |
|---|---|---|---|---|---|
| ADR-001 | 2026-09-15 | New Roadmap ID convention `F01-E01-T01` (subtasks `.01`, defects `F01-BUG-001`/`F01-GAP-001`); legacy `F01-S01-T01` IDs stay valid verbatim, never rewritten | Prompt requires Epic/Subtask levels while staying backward compatible | CONFIRMED | prompt-mejora-skillProyectDocument.md §4 |
| ADR-002 | 2026-09-15 | `check` validates that a log/Features ID exists in Roadmap or Features; it never validates ID shape | An ID-shape regex would reject every pre-existing legacy ID | CONFIRMED | ADR-001 |
| ADR-003 | 2026-09-15 | Log entry states stay `IN_PROGRESS`/`PAUSE`/`DONE`; `BLOCKED` is represented as `PAUSE` with category `BLOQUEO` | Prompt §73 offers both options; §91 already defines `BLOQUEO` as a pause category | CONFIRMED | prompt-mejora-skillProyectDocument.md §5 |
| ADR-004 | 2026-09-15 | Roadmap keeps `## Near term`; `## Blocked` folds into `## Plan` (status `PAUSE`/`BLOQUEO`) | `check` already requires `## Near term`; avoids an unnecessary template migration | CONFIRMED | prompt-mejora-skillProyectDocument.md §4 |
| ADR-005 | 2026-09-15 | Stale `IN_PROGRESS` threshold defaults to 24h, overridable via `PROJECT_DOCS_STALE_HOURS` (identical name in sh and ps1) | Prompt asks for a configurable default | CONFIRMED | prompt-mejora-skillProyectDocument.md §5 |
| ADR-006 | 2026-09-15 | `context`'s open-task list uses one fixed short line per task: `TASK-ID \| agent \| STATUS \| age \| reason` | §101 (list all open tasks) and the 8 KiB hard limit conflict; a compact fixed format resolves it | CONFIRMED | prompt-mejora-skillProyectDocument.md §5 |
| ADR-007 | 2026-09-15 | Rules file consolidates to a single root `AGENTS.md`; `docs/Agents.md` and `adapters/AGENTS.md` are merged into it | Prompt decision closed (§2); one file all runtimes read | CONFIRMED | prompt-mejora-skillProyectDocument.md §2 |
