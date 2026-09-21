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
| BR-004 | The six canonical files contain only Markdown (tables and lists), never YAML or JSON | CONFIRMED | ADR-018; `check` rejects the per-entry YAML Roadmap format |
| BR-005 | `done` refuses an empty verify, and `check` fails while any rule above is violated | CONFIRMED | evals/evals.json #11 |

## Main flows

| Flow | Start -> outcome | Status |
|---|---|---|
| Start a project | `init` creates the six files and links other agent files; `context` gives a bounded start (8 KiB) | CONFIRMED |
| Take and close a task | `claim` then work then `done` (or `pause`); the Agentslog records every state change | CONFIRMED |
| Validate and archive | `check` gates completion; `rotate` archives an oversized ledger with a SHA-256 check | CONFIRMED |

## Glossary

| Term | Meaning | Status |
|---|---|---|
| Contract files | The six canonical files: root `AGENTS.md` plus `Agentslog`, `ProductDescription`, `Stack_Tecnologies`, `Roadmap`, and `Features` under `docs/` | CONFIRMED |
| Hot context | The bounded slice that `context` emits, at most 8 KiB | CONFIRMED |
| Epistemic Status | `CONFIRMED`, `HYPOTHESIS`, or `UNKNOWN`, used on facts in Product and Stack | CONFIRMED |
| Workflow Status | `TODO`, `IN_PROGRESS`, `PAUSE`, or `DONE`, used on work items in Roadmap | CONFIRMED |

## Out of scope

- YAML or JSON inside any of the six canonical files.
- A server, database, or hosted service.
- Cross-machine locking: `claim` locks one working copy only, so other machines rely on committing the claim.
