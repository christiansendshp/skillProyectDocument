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
| ADR-008 | 2026-09-16 | Roadmap entries become per-entry `### TYPE-ID — Title` heading + fenced `yaml` block (no table spine); hierarchy is carried by `parent`, never by heading depth or `type` | User explicitly chose the full-rewrite option over a hybrid table+YAML design; spine depth (7 levels) exceeds Markdown's 6 heading levels, and the prompt explicitly warns against conflating type with hierarchical position | CONFIRMED | Prompt — Evolucionar skill de Roadmap...md §3, §19 |
| ADR-009 | 2026-09-16 | Roadmap `status` (IDEA/BACKLOG/READY/IN_PROGRESS/REVIEW/TESTING/BLOCKED/DONE/CANCELLED/DEFERRED) is a separate vocabulary from Agentslog's claim-lifecycle status (IN_PROGRESS/PAUSE/DONE, unchanged); `pause` maps category to Roadmap status: `LIMITE`/`OTRO` -> `READY` (released, no structural blocker), `ESPERA_RESPUESTA`/`BLOQUEO` -> `BLOCKED` | Roadmap tracks planning state, the log tracks who holds the pen — conflating them would force one vocabulary to serve two different questions | CONFIRMED | Prompt — Evolucionar skill de Roadmap...md §10 |
| ADR-010 | 2026-09-16 | `DECISION` entries use `status: PENDING/DECIDED/CANCELLED` (a documented per-type exception) instead of a separate `decision_status` field | The prompt's own example (§7) writes `status: PENDING` directly; a second field tracking the same fact risks drift | CONFIRMED | Prompt — Evolucionar skill de Roadmap...md §7, §10 |
| ADR-011 | 2026-09-16 | `claim` writes `executor`/`assigned_agent`/`status`/`updated_at`; it never writes `owner` | Prompt §9 explicitly separates who is accountable (`owner`, often human) from who executes (`executor`/`assigned_agent`); the old table's single Owner cell conflated them | CONFIRMED | Prompt — Evolucionar skill de Roadmap...md §9 |
| ADR-012 | 2026-09-16 | Epic rollup detects "no children left" via each remaining entry's `parent` field (not ID-prefix matching), and — unlike the old rollup — also writes a normal synthetic `DONE` log entry for the epic and removes the epic's own Roadmap entry, instead of leaving it dangling next to its own Features.md row | New IDs (`TASK-42`, `parent: EPIC-07`) don't encode lineage in the ID string the way legacy `F01-E01-T01` IDs did, so prefix matching can't detect completeness; a first-class `EPIC` entry (unlike the old bare heading) would otherwise stay in Roadmap.md marked open while Features.md already calls it done. `check_roadmap_features_ids`'s existing prefix-shape fallback (`epic_history_done`) is kept, unchanged, only to keep validating Features.md rows written by the pre-rewrite code | CONFIRMED | ADR-008 |
| ADR-013 | 2026-09-16 | `## Active work`/`## Near term` are dropped as physical Roadmap.md sections; `docs/Roadmap.md` keeps only `## Plan` and `## Cross-cutting`. `context`'s "Active work" is now computed by scanning entry `status` (anything not `IDEA`/`BACKLOG`/`DONE`/`CANCELLED`/`DEFERRED`) | Per-entry YAML blocks have no natural "move between sections" operation the way a table row did; a computed projection avoids dual bookkeeping (physical section vs. entry `status` drifting apart) | CONFIRMED | Prompt — Evolucionar skill de Roadmap...md §17 |
| ADR-014 | 2026-09-16 | `roadmap_ids`/`roadmap_entries` address an entry by its top-level `id:` line alone, with no requirement that a `### ` heading precede the yaml fence; `claim`/`done` therefore treat *any* well-formed fence as a real entry | Advisor review caught that the template's own inert "Example shape" fence (no heading above it) was silently a live, `done`-removable `DEC-01` entry in every fresh `init`. Fixed at the root by dropping the executable-looking example from the template (points at `references/roadmap-schema.md` #9 instead) | CONFIRMED | advisor review, 2026-09-16 |
| ADR-015 | 2026-09-16 | `done`'s backward search for an entry's `### ` heading aborts (falls back to deleting only the yaml fence) if it crosses a `## ` section heading or another fence first, instead of walking into unrelated content | Same review: a heading-less-but-idded yaml fence would otherwise cause `roadmap_remove_entry`/`Remove-RoadmapEntry` to delete the *previous* entry's heading and everything between it and the headless fence — defense in depth beyond ADR-014's template fix, for any hand-written headless block | CONFIRMED | advisor review, 2026-09-16 |
| ADR-016 | 2026-09-16 | `claim` rejects a `type: DECISION` target outright (`claim failed: ... is a DECISION; resolve it by hand`) | A `DECISION`'s status vocabulary (PENDING/DECIDED/CANCELLED, ADR-010) doesn't include `IN_PROGRESS`; letting `claim` write it produced a state `check` immediately rejected. Decisions are resolved by hand per `AGENTS.md`'s "Decisions and blockers" section, not via the claim lifecycle | CONFIRMED | advisor review, 2026-09-16 |
| ADR-017 | 2026-09-16 | `check` now also errors on a fenced `yaml` block with no top-level `id:` line at all (`check_roadmap_headless_blocks`/`Test-RoadmapHeadlessBlocks`), and the computed `## Active work` summary is capped at 20 entries (`... and N more`) | An id-less block is invisible to every id-based primitive and would otherwise fail silently instead of erroring; an uncapped Active work summary can single-handedly blow the 8 KiB context budget once a real project's Plan grows past ~30-40 entries | CONFIRMED | advisor review, 2026-09-16 |
