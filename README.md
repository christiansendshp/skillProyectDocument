# project-documentation

Compact, coordinated project memory for AI coding agents. It creates six
stable files at project initialization, keeps startup context bounded while
preserving cold history, and lets multiple agents (Claude Code, Codex,
OpenCode, Antigravity, others) take tasks without overlapping.

The repository name and legacy installation folder `skillProyectDocument`
remain supported during transition. The canonical skill name is
`project-documentation`.

## Contract files

Every project receives these exact files:

| File | Compact responsibility |
|---|---|
| `AGENTS.md` (project root) | Rules, selective-reading policy, task-taking protocol |
| `docs/Agentslog.md` | Append-only ledger; source of truth for task ownership |
| `docs/ProductDescription.md` | Current functional truth |
| `docs/Stack_Tecnologies.md` | Current technical truth; legacy spelling retained |
| `docs/Roadmap.md` | Hierarchical plan (Markdown tables) + Gaps/Bugs/Technical Debt |
| `docs/Features.md` | Index of verified capabilities |

Additional detail may live under `docs/features/`, `docs/decisions/`, or
`docs/history/` and is loaded only when referenced by the current task.

## Commands

POSIX:

```sh
sh scripts/project_docs.sh init /path/to/project
sh scripts/project_docs.sh context /path/to/project
sh scripts/project_docs.sh check /path/to/project
```

PowerShell:

```powershell
& scripts/project_docs.ps1 init C:\path\to\project
& scripts/project_docs.ps1 context C:\path\to\project
& scripts/project_docs.ps1 check C:\path\to\project
```

Both launchers also provide:

| Command | Purpose |
|---|---|
| `link [--create <list>]` | Point other agent files (`CLAUDE.md`, `.cursorrules`, ...) at `AGENTS.md`; run automatically at the end of `init` |
| `init [--classic]` | Create the contract files. A project the skill does not manage yet starts in Factory mode (seven files plus `docs/specs/` and `docs/brain/tasks/`); `--classic` creates the six-file project; an existing project keeps its mode |
| `migrate [--factory]` | Merge a legacy `docs/Agents.md` into root `AGENTS.md`, fix a root case-only filename, add missing `Roadmap.md` sections, convert a per-entry YAML Roadmap back to tables, retrofit a `Name` column onto a pre-Name Roadmap — idempotent; with `--factory` also add the Factory section, the default roster, `docs/Brain.md` and the Factory folders without replacing anything |
| `claim <agent> <task-id> <summary>` | Take a Roadmap task before your first edit; fails if another agent already owns it (the holder may retake a task in `REVIEW`) |
| `pause <agent> <task-id> <category> <detail>` | Release a task (`LIMITE`\|`ESPERA_RESPUESTA`\|`BLOQUEO`\|`OTRO`) |
| `handoff <agent> <task-id> <summary> <verify> [reviewer]` | Code complete and your own verification passed: move the task to `REVIEW` (ledger only, the Roadmap row stays `IN_PROGRESS`) |
| `review <agent> <task-id> <PASS\|FAIL> <note> [verify]` | Answer a pending handoff; `FAIL` returns the task to its holder, who retakes it with `claim`; reviewing your own handoff warns |
| `assign <agent> <task-id> <to-agent>` | Hand a task out without starting it (`ASSIGNED`; the row stays `TODO` with the new Owner) |
| `done <agent> <task-id> <summary> <files> <verify>` | Close a task, record it in `Features.md`, clear it from the Roadmap; only the holder, the reviewer who passed it, or anyone on a stale or forced task |
| `status` | List every open (`IN_PROGRESS`/`PAUSE`/`REVIEW`/`ASSIGNED`) task with its stage, owner, age, reason |
| `mode` | Print whether Factory or Classic mode applies (and why); in Factory mode, the effective settings. See `references/factory.md` |
| `append-log` | Manual/legacy ledger entry outside the claim lifecycle |
| `rotate` | Archive an oversized ledger, hash-verified, carrying open tasks forward |

Initialization is idempotent and never overwrites existing content —
`AGENTS.md` gets the skill's rules inserted in a delimited block on first run
and is left untouched afterward. `context` emits at most 8 KiB, including
every open task. The hot log rotates after 200 entries or 128 KiB.

Environment variables (all optional):

| Variable | Effect |
|---|---|
| `PROJECT_DOCS_STALE_HOURS` (default `24`) | How long an unattended `IN_PROGRESS` or `REVIEW` entry is considered abandoned and reclaimable |
| `PROJECT_DOCS_MIN_WORK_MINUTES` (default `5`) | `done` and `check` warn about a task claimed and closed less than this apart; `0` silences it |
| `PROJECT_DOCS_REQUIRE_INDEPENDENT_REVIEW=1` | Reviewing your own handoff becomes an error instead of a warning |
| `PROJECT_DOCS_FORCE=1` | `done` lets any agent close a task another agent holds |

An optional `## Agent identity` table in `AGENTS.md` lists one stable id per
agent plus aliases; with it, `claim`, `pause`, `handoff`, `review`, `assign`
and `done` normalise an alias to the id and warn about unknown names.

## Changelog

- **Review stage, handoff and agent identity**: the ledger can now say who an
  agent is, when it develops, when it hands over for review and how the
  review ended, in words `check` accepts. `REVIEW` is a ledger state (the
  Roadmap `Status` values and columns do not change; the row stays
  `IN_PROGRESS`); `handoff` and `review PASS|FAIL` write it, `assign` writes
  `ASSIGNED`. `done` now checks who is closing (holder, the reviewer who
  passed it, a stale or forced task, or a never-claimed one) and warns about
  closing without a passing review and about empty verify markers such as
  `none` or `n/a`. An optional `## Agent identity` roster normalises aliases
  to one id. A new warning says when work was claimed and closed minutes
  apart. Everything is opt-in: a project that never uses `REVIEW`,
  `ASSIGNED` or the roster behaves as before (verified by running both
  versions on the same project). Also fixed: `status` and `rotate` printed an
  empty `Name` because `read` merged empty tab-separated fields.
- **Name/Description taxonomy**: every Roadmap row now carries a `Name` cell
  (right after `ID`) — short, descriptive, 10 words or fewer — with the rest
  of the detail in `Description` (or the row's own free-text column for
  `## Near term`, which has no `Description`). `claim`/`pause`/`done` refuse
  a row whose Name is missing or over 10 words, and copy it verbatim into
  the matching Agentslog entry (`| agent | TASK-ID | STATUS | Name`), so the
  log can never say something different from the Roadmap. `check` enforces
  both: every table's Name column exists and stays within the limit, and an
  Agentslog entry's Name agrees with its ID's current Roadmap Name. `migrate`
  retrofits a pre-Name Roadmap non-destructively (old text becomes
  `Description`; a derived first-10-words `Name` is flagged for review).
- **Markdown hardening**: reverted `docs/Roadmap.md` to pure Markdown
  tables (superseding the per-entry YAML schema below) — zero YAML/JSON in
  any contract file, so line-based tools never misparse an
  indentation-sensitive block. Added canonical IDs (`BR-xxx` business
  rules, `ADR-xxx` technical decisions, `Fxx-GAP-xx`/`Fxx-BUG-xx`/
  `Fxx-DEBT-xx` gaps/bugs/debt), a strict epistemic `Status` enum
  (`CONFIRMED`/`HYPOTHESIS`/`UNKNOWN`) on every fact table distinct from
  Roadmap's workflow `Status` (`TODO`/`IN_PROGRESS`/`PAUSE`/`DONE`),
  `## Out of scope` sections, and a `check` that validates required table
  headers, the `<!-- context:end -->` delimiter, ID format, and both
  `Status` vocabularies. `migrate` converts a YAML-format Roadmap back to
  tables non-destructively. `claim` now inserts the moved row as the last
  row of the `## Active work` table and removes the empty-table placeholder
  (it used to land below the blank line, detached from the table, which broke
  Markdown rendering). This repository's own `docs/` were migrated to the new
  format.
- **Human + AI Roadmap schema** (2026-09, superseded above): `docs/Roadmap.md`
  briefly moved from Markdown tables to a per-entry `### TYPE-ID — Title` +
  fenced `yaml` block format with a full type taxonomy and explicit
  dependencies/blockers/decisions. Reverted after `check`'s
  indentation-sensitive parsing proved too fragile for line-based tooling.
- **Multi-agent coordination protocol**: single root `AGENTS.md` (replaces
  `docs/Agents.md`), `link`/`migrate` commands, `claim`/`pause`/`done`/`status`
  task lifecycle backed by the Agentslog, `Roadmap.md` `## Plan` +
  `## Gaps, Bugs & Technical Debt`, `references/intake.md`, and an extended
  `check`.

See `SKILL.md` for the agent workflow, `references/workflow.md` for command
detail, `references/intake.md` for the new-app questionnaire, and
`references/adapters.md` for runtime installation.
