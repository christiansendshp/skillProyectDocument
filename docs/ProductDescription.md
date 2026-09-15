# Product description

## Operational summary

- Product: `project-documentation` skill — compact, file-based project memory for AI coding agents.
- Primary user: AI agents (Claude Code, Codex, OpenCode, Antigravity, others) and the developers who install the skill.
- Core outcome: agents share one durable, bounded project memory and coordinate task ownership without overlap.
- Critical invariant: `context` output stays <= 8 KiB; `init`/`link` never overwrite existing user content.

<!-- context:end -->

## Users and outcomes

| User or role | Needed outcome | Status | Source |
|---|---|---|---|
| AI agent (any runtime) | Load product/stack/task context in one bounded read | CONFIRMED | SKILL.md |
| Multiple concurrent agents | Take tasks without duplicating work | HYPOTHESIS | prompt-mejora-skillProyectDocument.md |
| Developer installing the skill | One rules file (`AGENTS.md`) works across runtimes | HYPOTHESIS | prompt-mejora-skillProyectDocument.md |

## Business rules

| ID | Rule | Status | Source or verification |
|---|---|---|---|
| BR-001 | `init` never overwrites an existing contract file | CONFIRMED | evals/evals.json #1 |
| BR-002 | `context` output must stay at or below 8 KiB | CONFIRMED | scripts/project_docs.sh build_context |
| BR-003 | Every new user-requested task is added to the Roadmap with an ID before execution | HYPOTHESIS | prompt-mejora-skillProyectDocument.md §4 |

## Main flows

| Flow | Start -> outcome | Status |
|---|---|---|
| UNKNOWN | UNKNOWN | UNKNOWN |

## Glossary

| Term | Meaning | Status |
|---|---|---|
| UNKNOWN | UNKNOWN | UNKNOWN |

## Out of scope

- `UNKNOWN`
