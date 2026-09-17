# Agents log

Recent append-only ledger. Keep one entry per logical change, no more than six
lines or roughly 700 characters. Older segments live in `docs/history/`.

## Entry format

```markdown
## [YYYY-MM-DDTHH:mm:ssZ] | agent | TASK-ID | DONE
- Summary: observable outcome
- Files: compact paths or component names
- Verify: command and result
- Follow-up: none or one pointer
```

## Entries

## [2026-09-15T17:11:42Z] | claude-sonnet-5 | F01-E02-T01 | IN_PROGRESS
- Summary: Start multiagent coordination protocol per prompt-mejora-skillProyectDocument.md; claiming shared-primitives refactor first
- Files: docs/Roadmap.md docs/Stack_Tecnologies.md
- Verify: pending
- Follow-up: none

## [2026-09-15T18:10:05Z] | claude-sonnet-5 | F01-E02-T01 | DONE
- Summary: Shared primitives built and unit-tested: path-based contract file table (root AGENTS.md + docs/), idempotent marker-block insert/replace, single-pass Agentslog scanner (task/status/agent/ts/pause/conflict/ever-done), unified 7-col Roadmap row editor used by claim/pause/done
- Files: scripts/project_docs.sh,scripts/project_docs.ps1
- Verify: sh -n and PowerShell parser both OK; manual claim/pause/done/rotate tests pass

## [2026-09-15T18:10:05Z] | claude-sonnet-5 | F01-E02-T02 | IN_PROGRESS
- Summary: migrate + link commands, sh and ps1
- Verify: pending

## [2026-09-15T18:10:06Z] | claude-sonnet-5 | F01-E02-T02 | DONE
- Summary: migrate merges legacy docs/Agents.md into root AGENTS.md and fixes root case variants; link inserts/updates a redirect block in CLAUDE.md/GEMINI.md/.cursorrules/.windsurfrules/.clinerules/copilot-instructions.md/.antigravity rules.md, auto-run at end of init
- Files: scripts/project_docs.sh,scripts/project_docs.ps1,adapters/
- Verify: manual tests: migrate preserves custom docs/Agents.md content and is idempotent (sh+ps1); link merges into custom CLAUDE.md/.cursorrules byte-for-byte and is idempotent (sh+ps1)

## [2026-09-15T18:10:18Z] | claude-sonnet-5 | F01-E02-T03 | IN_PROGRESS
- Summary: Roadmap/Agentslog rework
- Verify: pending

## [2026-09-15T18:10:21Z] | claude-sonnet-5 | F01-E02-T03 | DONE
- Summary: claim/pause/done/status implemented sh+ps1 with docs/.lock atomicity; new ID convention documented (legacy IDs never rewritten); log states IN_PROGRESS/PAUSE/DONE, BLOCKED represented as PAUSE+BLOQUEO; context adds Open tasks section; rotate carries open tasks forward as re-seeded entries
- Files: scripts/project_docs.sh,scripts/project_docs.ps1,templates/Roadmap.md,templates/Agentslog.md
- Verify: manual tests: claim conflict/stale/LIMITE-PAUSE reclaim, conflicting-concurrent-claim detection, rotation-with-open-task, all pass sh+ps1

## [2026-09-15T18:10:26Z] | claude-sonnet-5 | F01-E02-T04 | IN_PROGRESS
- Summary: Intake questionnaire + quiero una app flow
- Verify: pending

## [2026-09-15T18:10:30Z] | claude-sonnet-5 | F01-E02-T04 | DONE
- Summary: references/intake.md added; SKILL.md/workflow.md document the new-app flow (init+link+migrate, fill from request, ask only missing via intake.md, build full Plan, then claim); check reports UNKNOWN count as a warning
- Files: references/intake.md,SKILL.md,references/workflow.md,scripts/project_docs.sh,scripts/project_docs.ps1
- Verify: check prints WARN: N UNKNOWN field(s) without failing, verified sh+ps1

## [2026-09-15T18:10:40Z] | claude-sonnet-5 | F01-E02-T05 | IN_PROGRESS
- Summary: check extended + templates/adapters/openai.yaml/README updated
- Verify: pending

## [2026-09-15T18:10:41Z] | claude-sonnet-5 | F01-E02-T05 | DONE
- Summary: check now errors on: missing root AGENTS.md, leftover docs/Agents.md, root AGENTS.md case-variant coexistence, invalid log status, PAUSE without category/detail, DONE without Verify, conflicting concurrent claims, log IDs missing from Roadmap/Features, Features IDs without a DONE (hot log or docs/history fallback); warns on UNKNOWN fields, missing link blocks, stale claims. Templates, adapters/, agents/openai.yaml, README.md updated
- Files: scripts/project_docs.sh,scripts/project_docs.ps1,templates/,adapters/,agents/openai.yaml,README.md
- Verify: manual tests cover every error/warning condition sh+ps1; case-variant coexistence verified by construction (untestable on Windows/macOS filesystems)

## [2026-09-15T18:13:36Z] | claude-sonnet-5 | F01-E02-T06 | IN_PROGRESS
- Summary: evals.json additions + smoke_test.sh
- Verify: pending

## [2026-09-15T18:13:37Z] | claude-sonnet-5 | F01-E02-T06 | DONE
- Summary: evals.json extended from 3 to 14 scenarios; scripts/smoke_test.sh runs the full lifecycle against sh and, when pwsh/powershell.exe is on PATH, ps1 too
- Files: evals/evals.json,scripts/smoke_test.sh
- Verify: sh scripts/smoke_test.sh -> 72 passed, 0 failed (sh + powershell.exe)

## [2026-09-16T16:07:12Z] | claude | F02-E01-T01 | IN_PROGRESS
- Summary: Full per-entry YAML rewrite of Roadmap.md and claim/pause/done/status/context/check/migrate in sh+ps1, per the Human+AI Roadmap schema prompt
- Verify: pending

## [2026-09-16T16:11:44Z] | claude | F02-E01-T01 | DONE
- Summary: Rewrote docs/Roadmap.md to per-entry YAML blocks (full type taxonomy, hierarchy via parent, dependencies/blockers/decisions, owner/executor/assigned_agent, states, progress, acceptance_criteria, DoD, next_action); reworked claim/pause/done/status/context/check/migrate in sh+ps1 to parse/edit YAML entries; moved task-selection/decision-escalation/DoD-verification rules into AGENTS.md; added references/roadmap-schema.md
- Files: scripts/project_docs.sh, scripts/project_docs.ps1, templates/Roadmap.md, templates/AGENTS.md, references/roadmap-schema.md, references/workflow.md, references/intake.md, SKILL.md, README.md, evals/evals.json, scripts/smoke_test.sh
- Verify: sh scripts/smoke_test.sh -> 116 passed, 0 failed (sh + powershell.exe)

## [2026-09-16T16:11:44Z] | rollup | F02-E01 | DONE
- Summary: all direct children of F02-E01 are DONE
- Files: -
- Verify: rollup from F02-E01-T01

## [2026-09-16T16:20:09Z] | claude | F02-E01-T01 | DONE
- Summary: Post-close advisor review found a destructive bug: the template's inert DEC-01 example (a headless yaml fence) was a live, done-removable entry; fixed the template, added a defensive backward-walk guard in done, rejected claim on DECISION targets, added check_roadmap_headless_blocks, and capped the Active work summary at 20 entries (ADR-014..017)
- Files: scripts/project_docs.sh, scripts/project_docs.ps1, templates/Roadmap.md, references/workflow.md, scripts/smoke_test.sh
- Verify: sh scripts/smoke_test.sh -> pending re-run
- Follow-up: none

## [2026-09-16T16:24:35Z] | claude | F02-E01-T01 | DONE
- Summary: Re-ran full smoke test suite after the advisor-review fixes (ADR-014..017): 138 passed, 0 failed (sh + powershell.exe), including the new regression tests for the headless-fence bug, DECISION claim rejection, and pause OTRO
- Files: scripts/project_docs.sh, scripts/project_docs.ps1, templates/Roadmap.md, references/workflow.md, scripts/smoke_test.sh
- Verify: sh scripts/smoke_test.sh -> 138 passed, 0 failed (sh + powershell.exe)
- Follow-up: none
