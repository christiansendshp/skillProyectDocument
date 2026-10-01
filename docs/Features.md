# Features

## Operational summary

- Verified capabilities: 14
- Latest verification: `sh scripts/project_docs.sh check . -> OK, hot context 8600 -> under 8192` (2026-10-01)
- Known limitation: the AGENTS.md/Agents.md case collision cannot be tested end to end on Windows or macOS.

<!-- context:end -->

## Verified capabilities

Use one row per stable capability. Link long specifications or runbooks from
`docs/features/`.

| ID | Capability | Verification | Source or detail | Updated |
|---|---|---|---|---|
| F01-E02-T01 | Shared primitives built and unit-tested: path-based contract file table (root AGENTS.md + docs/), idempotent marker-block insert/replace, single-pass Agentslog scanner (task/status/agent/ts/pause/conflict/ever-done), unified 7-col Roadmap row editor used by claim/pause/done | sh -n and PowerShell parser both OK; manual claim/pause/done/rotate tests pass | log:F01-E02-T01 | 2026-09-15 |
| F01-E02-T02 | migrate merges legacy docs/Agents.md into root AGENTS.md and fixes root case variants; link inserts/updates a redirect block in CLAUDE.md/GEMINI.md/.cursorrules/.windsurfrules/.clinerules/copilot-instructions.md/.antigravity rules.md, auto-run at end of init | manual tests: migrate preserves custom docs/Agents.md content and is idempotent (sh+ps1); link merges into custom CLAUDE.md/.cursorrules byte-for-byte and is idempotent (sh+ps1) | log:F01-E02-T02 | 2026-09-15 |
| F01-E02-T03 | claim/pause/done/status implemented sh+ps1 with docs/.lock atomicity; new ID convention documented (legacy IDs never rewritten); log states IN_PROGRESS/PAUSE/DONE, BLOCKED represented as PAUSE+BLOQUEO; context adds Open tasks section; rotate carries open tasks forward as re-seeded entries | manual tests: claim conflict/stale/LIMITE-PAUSE reclaim, conflicting-concurrent-claim detection, rotation-with-open-task, all pass sh+ps1 | log:F01-E02-T03 | 2026-09-15 |
| F01-E02-T04 | references/intake.md added; SKILL.md/workflow.md document the new-app flow (init+link+migrate, fill from request, ask only missing via intake.md, build full Plan, then claim); check reports UNKNOWN count as a warning | check prints WARN: N UNKNOWN field(s) without failing, verified sh+ps1 | log:F01-E02-T04 | 2026-09-15 |
| F01-E02-T05 | check now errors on: missing root AGENTS.md, leftover docs/Agents.md, root AGENTS.md case-variant coexistence, invalid log status, PAUSE without category/detail, DONE without Verify, conflicting concurrent claims, log IDs missing from Roadmap/Features, Features IDs without a DONE (hot log or docs/history fallback); warns on UNKNOWN fields, missing link blocks, stale claims. Templates, adapters/, agents/openai.yaml, README.md updated | manual tests cover every error/warning condition sh+ps1; case-variant coexistence verified by construction (untestable on Windows/macOS filesystems) | log:F01-E02-T05 | 2026-09-15 |
| F01-E02-T06 | evals.json extended from 3 to 14 scenarios; scripts/smoke_test.sh runs the full lifecycle against sh and, when pwsh/powershell.exe is on PATH, ps1 too | sh scripts/smoke_test.sh -> 72 passed, 0 failed (sh + powershell.exe) | log:F01-E02-T06 | 2026-09-15 |
| F01-E02 | Epic complete | all tasks DONE | log:F01-E02-T06 | 2026-09-15 |
| F02-E01-T01 | Rewrote docs/Roadmap.md to per-entry YAML blocks (full type taxonomy, hierarchy via parent, dependencies/blockers/decisions, owner/executor/assigned_agent, states, progress, acceptance_criteria, DoD, next_action); reworked claim/pause/done/status/context/check/migrate in sh+ps1 to parse/edit YAML entries; moved task-selection/decision-escalation/DoD-verification rules into AGENTS.md; added references/roadmap-schema.md. Superseded by F03-E01-T01: the YAML schema was reverted to Markdown tables and that file removed | sh scripts/smoke_test.sh -> 116 passed, 0 failed (sh + powershell.exe) | log:F02-E01-T01 | 2026-09-16 |
| F02-E01 | Epic complete | all tasks DONE | log:F02-E01-T01 | 2026-09-16 |
| F03-E01-T01 | Markdown hardening closed: Roadmap back to tables, canonical BR/ADR/Fxx IDs, strict Status enums, hardened check, claim inserts the row inside the Active work table, own docs migrated, evals 15-21 rewritten | sh scripts/smoke_test.sh -> 162 passed, 0 failed (sh + powershell.exe); sh scripts/project_docs.sh check . -> OK | log:F03-E01-T01 | 2026-09-21 |
| F03-E01 | Epic complete | all tasks DONE | log:F03-E01-T01 | 2026-09-21 |
| F04-E01-T01 | Name/Description taxonomy: Name<=10 words right after ID on every Roadmap table, Description holds the rest; claim/pause/done refuse a bad Name and copy it into Agentslog; check enforces the word limit and cross-validates log vs Roadmap Name; migrate retrofits pre-Name Roadmaps non-destructively; see Stack ADR-020 | sh scripts/smoke_test.sh -> 208 passed, 0 failed (sh + PowerShell); sh scripts/project_docs.sh check . -> OK | log:F04-E01-T01 | 2026-10-01 |
| F04-E01 | Epic complete | all tasks DONE | log:F04-E01-T01 | 2026-10-01 |
| F03-DEBT-03 | Trimmed AGENTS.md (template and root) from ~4.9 KiB to ~4.3 KiB by tightening Startup/Taking-a-task/Technical-decisions/Close wording, no obligation dropped | sh scripts/project_docs.sh check . -> OK, hot context 8600 -> under 8192 | log:F03-DEBT-03 | 2026-10-01 |
