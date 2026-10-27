# Features

## Operational summary

- Verified capabilities: 38
- Latest verification: `commit a711b68; full smoke sh 1069 passed 0 failed, ps1 1067 passed 0 failed; QA PASS; exit=0` (2026-10-27)
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
| F05-BUG-01 | Read task-state TSV with a non-whitespace separator so empty fields stop shifting Name in status, open tasks and rotate; regression asserts added | sh scripts/smoke_test.sh -> 212 passed, 0 failed (sh + PowerShell); status and rotate print and carry the Name | log:F05-BUG-01 | 2026-10-13 |
| F05-E01-T01 | REVIEW is a valid ledger word: check validates Summary, Verify, Handoff and Review lines; task-state TSV gains holder, handoff and review; status, open tasks, stale warning and rotate keep REVIEW tasks; two REVIEW entries by different agents are no conflict; the holder may retake a REVIEW task | sh scripts/smoke_test.sh -> 272 passed, 0 failed (sh + PowerShell); check . -> OK | log:F05-E01-T01 | 2026-10-13 |
| F05-E01-T02 | handoff command in sh and PowerShell: holder-only, real verify required, writes a REVIEW entry with an optional Handoff line and leaves the Roadmap row IN_PROGRESS with the same Owner; smoke rotation test now seeds filler entries in one process | sh scripts/smoke_test.sh -> 312 passed, 0 failed (sh + PowerShell); check . -> OK | log:F05-E01-T02 | 2026-10-13 |
| F05-E01-T03 | review command in sh and PowerShell: needs a pending handoff and a note, PASS needs a real verify, writes a REVIEW entry in the reviewer name with a Review line and leaves the Roadmap row alone; FAIL returns the task to its holder; self-review warns or fails with PROJECT_DOCS_REQUIRE_INDEPENDENT_REVIEW=1 | sh scripts/smoke_test.sh -> 366 passed, 0 failed (sh + PowerShell); check . -> OK | log:F05-E01-T03 | 2026-10-13 |
| F05-E01-T04 | done now verifies who closes a task: the holder, the reviewer who left Review PASS, anyone on a stale or PROJECT_DOCS_FORCE=1 task, or anyone for a never-claimed task; it warns on closing without a passing review and on verify markers such as none, n/a, no run, ninguno, an em dash or UNKNOWN | sh scripts/smoke_test.sh -> 428 passed, 0 failed (sh + PowerShell); check . -> OK | log:F05-E01-T04 | 2026-10-13 |
| F05-E01 | Epic complete | all tasks DONE | log:F05-E01-T04 | 2026-10-13 |
| F05-E02-T01 | Optional Agent identity roster: aliases normalise to the Agent id in claim, pause, handoff, review and done; unknown names warn | sh scripts/smoke_test.sh -> 474 passed, 0 failed (sh + PowerShell); check . -> OK | log:F05-E02-T01 | 2026-10-13 |
| F05-E02-T02 | Warn when a task is claimed and closed minutes apart; check prints one summary plus the 5 most recent | sh scripts/smoke_test.sh -> 500 passed, 0 failed (sh + PowerShell); check . -> OK | log:F05-E02-T02 | 2026-10-13 |
| F05-E02-T03 | assign command and ASSIGNED state: row stays TODO with the new Owner, claim by another agent warns, a task in progress cannot be assigned | sh scripts/smoke_test.sh -> 562 passed, 0 failed (sh + PowerShell); check . -> OK | log:F05-E02-T03 | 2026-10-13 |
| F05-E02 | Epic complete | all tasks DONE | log:F05-E02-T03 | 2026-10-13 |
| F05-E03-T01 | Templates, docs and evals for review, handoff and agent identity; golden regression test; evals 26 to 39 | sh scripts/smoke_test.sh -> 578 passed, 0 failed (sh + PowerShell); check . -> OK; differential run old vs new scripts identical | log:F05-E03-T01 | 2026-10-13 |
| F05-E03 | Epic complete | all tasks DONE | log:F05-E03-T01 | 2026-10-13 |
| F06-E01-T01 | Mode detection and mode command in sh and ps1 | smoke 632 pass 0 fail; QA PASS; differential vs master identical | log:F06-E01-T01 | 2026-10-26 |
| F06-E03-T01 | Brain template and Factory-only check validation | smoke 704 pass 0 fail; QA PASS 81 fixtures; classic check identical | log:F06-E03-T01 | 2026-10-26 |
| F06-E01-T02 | init defaults to Factory, init --classic, migrate --factory | smoke 812 pass 0 fail; QA PASS sh==ps1 20 scenarios; BR-008 identical | log:F06-E01-T02 | 2026-10-26 |
| F06-E01-T03 | Decisions pointer via migrate; fresh Factory context 6750 B | smoke 856 pass 0 fail; QA PASS factory smoke 139 each; context 6750 B | log:F06-E01-T03 | 2026-10-26 |
| F06-DEBT-01 | Cap parsing, CRLF, roster rerun and flags hardened | smoke 902 pass 0 fail; QA PASS factory 162 each; BR-008 identical | log:F06-DEBT-01 | 2026-10-26 |
| F06-E02-T03 | Phase roles in roster and claim; rotate carries phase | smoke 1238 pass 0 fail; QA PASS factory 330 each; rotate classic identical | log:F06-E02-T03 | 2026-10-26 |
| F06-E02-T01 | Spec template and Factory-only spec validation | smoke 1494 pass 0 fail; QA PASS factory 458 each; sh==ps1 25 fixtures | log:F06-E02-T01 | 2026-10-26 |
| F06-E03-T02 | Working memory, checkpoint command, pause gate | smoke 1494 pass 0 fail; QA PASS factory 458 each; lock race fixed | log:F06-E03-T02 | 2026-10-26 |
| F06-E02-T02 | advance command with SPEC and RED gates | smoke 1700 pass 0 fail; QA PASS retake: classic rotate identical | log:F06-E02-T02 | 2026-10-27 |
| F06-E02-T05 | Review warnings are errors in Factory mode | smoke 1700 pass 0 fail; QA PASS factory 561 sh; classic flow identical | log:F06-E02-T05 | 2026-10-27 |
| F06-E01-T05 | WIP per agent and fix attempts in claim | smoke 1700 pass 0 fail; QA PASS races, rotate, BLOQUEO reset | log:F06-E01-T05 | 2026-10-27 |
| F06-E01-T04 | next command: the task an agent should work on by role, phase and priority; reviewed by claude-qa (PASS) | commit a711b68; full smoke sh 1069 passed 0 failed, ps1 1067 passed 0 failed; QA PASS; exit=0 | log:F06-E01-T04 | 2026-10-27 |
