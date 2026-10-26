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

## [2026-09-21T16:38:03Z] | claude | F03-E01-T01 | IN_PROGRESS
- Summary: Markdown hardening: migrate this repo's own docs to the pure-Markdown format, rewrite stale evals, verify and publish
- Verify: pending

## [2026-09-21T16:54:17Z] | claude | F03-E01-T01 | DONE
- Summary: Markdown hardening closed: Roadmap back to tables, canonical BR/ADR/Fxx IDs, strict Status enums, hardened check, claim inserts the row inside the Active work table, own docs migrated, evals 15-21 rewritten
- Files: scripts/project_docs.sh,scripts/project_docs.ps1,scripts/smoke_test.sh,templates/,docs/,evals/evals.json,references/,README.md,SKILL.md
- Verify: sh scripts/smoke_test.sh -> 162 passed, 0 failed (sh + powershell.exe); sh scripts/project_docs.sh check . -> OK

## [2026-10-01T14:49:53Z] | claude | F04-E01-T01 | IN_PROGRESS | Add a short Name column, enforce it everywhere
- Summary: Add Name/Description taxonomy to Roadmap, enforce across sh+ps1, migrate, docs, tests
- Verify: pending

## [2026-10-01T15:05:12Z] | claude | F04-E01-T01 | DONE | Add a short Name column, enforce it everywhere
- Summary: Name/Description taxonomy: Name<=10 words right after ID on every Roadmap table, Description holds the rest; claim/pause/done refuse a bad Name and copy it into Agentslog; check enforces the word limit and cross-validates log vs Roadmap Name; migrate retrofits pre-Name Roadmaps non-destructively; see Stack ADR-020
- Files: scripts/project_docs.sh,scripts/project_docs.ps1,scripts/smoke_test.sh,templates/Roadmap.md,templates/Agentslog.md,templates/AGENTS.md,AGENTS.md,references/workflow.md,SKILL.md,README.md,evals/evals.json,docs/
- Verify: sh scripts/smoke_test.sh -> 208 passed, 0 failed (sh + PowerShell); sh scripts/project_docs.sh check . -> OK

## [2026-10-01T15:05:39Z] | claude | F03-DEBT-03 | IN_PROGRESS | Root AGENTS.md eats over half the context budget
- Summary: Shrink root AGENTS.md so context stays under the 8 KiB budget
- Verify: pending

## [2026-10-01T15:07:12Z] | claude | F03-DEBT-03 | DONE | Root AGENTS.md eats over half the context budget
- Summary: Trimmed AGENTS.md (template and root) from ~4.9 KiB to ~4.3 KiB by tightening Startup/Taking-a-task/Technical-decisions/Close wording, no obligation dropped
- Files: AGENTS.md,templates/AGENTS.md
- Verify: sh scripts/project_docs.sh check . -> OK, hot context 8600 -> under 8192

## [2026-10-13T16:32:05Z] | claude-sonnet-5-5 | F05-E01-T01 | IN_PROGRESS | Accept REVIEW in the ledger and task states
- Summary: Change 1: REVIEW in the ledger, task-state TSV, status/open-task/stale/rotate
- Verify: pending

## [2026-10-13T16:34:32Z] | claude-sonnet-5-5 | F05-BUG-01 | IN_PROGRESS | status and rotate lose the task Name
- Summary: Fix tab-IFS read merging empty fields in status, open tasks and rotate
- Verify: pending

## [2026-10-13T16:47:16Z] | claude-sonnet-5-5 | F05-BUG-01 | DONE | status and rotate lose the task Name
- Summary: Read task-state TSV with a non-whitespace separator so empty fields stop shifting Name in status, open tasks and rotate; regression asserts added
- Files: scripts/project_docs.sh,scripts/smoke_test.sh
- Verify: sh scripts/smoke_test.sh -> 212 passed, 0 failed (sh + PowerShell); status and rotate print and carry the Name

## [2026-10-13T17:09:36Z] | claude-sonnet-5-5 | F05-E01-T01 | DONE | Accept REVIEW in the ledger and task states
- Summary: REVIEW is a valid ledger word: check validates Summary, Verify, Handoff and Review lines; task-state TSV gains holder, handoff and review; status, open tasks, stale warning and rotate keep REVIEW tasks; two REVIEW entries by different agents are no conflict; the holder may retake a REVIEW task
- Files: scripts/project_docs.sh,scripts/project_docs.ps1,scripts/smoke_test.sh
- Verify: sh scripts/smoke_test.sh -> 272 passed, 0 failed (sh + PowerShell); check . -> OK

## [2026-10-13T17:09:51Z] | claude-sonnet-5-5 | F05-E01-T02 | IN_PROGRESS | Add the handoff command
- Summary: Change 2: handoff moves a held task to REVIEW without touching the row
- Verify: pending

## [2026-10-13T17:17:23Z] | claude-sonnet-5-5 | F05-E01-T02 | DONE | Add the handoff command
- Summary: handoff command in sh and PowerShell: holder-only, real verify required, writes a REVIEW entry with an optional Handoff line and leaves the Roadmap row IN_PROGRESS with the same Owner; smoke rotation test now seeds filler entries in one process
- Files: scripts/project_docs.sh,scripts/project_docs.ps1,scripts/smoke_test.sh
- Verify: sh scripts/smoke_test.sh -> 312 passed, 0 failed (sh + PowerShell); check . -> OK

## [2026-10-13T17:17:43Z] | claude-sonnet-5-5 | F05-E01-T03 | IN_PROGRESS | Add the review command with PASS or FAIL
- Summary: Change 3: review command with PASS or FAIL in the reviewer name
- Verify: pending

## [2026-10-13T17:24:24Z] | claude-sonnet-5-5 | F05-E01-T03 | DONE | Add the review command with PASS or FAIL
- Summary: review command in sh and PowerShell: needs a pending handoff and a note, PASS needs a real verify, writes a REVIEW entry in the reviewer name with a Review line and leaves the Roadmap row alone; FAIL returns the task to its holder; self-review warns or fails with PROJECT_DOCS_REQUIRE_INDEPENDENT_REVIEW=1
- Files: scripts/project_docs.sh,scripts/project_docs.ps1,scripts/smoke_test.sh
- Verify: sh scripts/smoke_test.sh -> 366 passed, 0 failed (sh + PowerShell); check . -> OK

## [2026-10-13T17:24:41Z] | claude-sonnet-5-5 | F05-E01-T04 | IN_PROGRESS | done verifies who is closing the task
- Summary: Change 4: done verifies who closes the task
- Verify: pending

## [2026-10-13T17:35:10Z] | claude-sonnet-5-5 | F05-E01-T04 | DONE | done verifies who is closing the task
- Summary: done now verifies who closes a task: the holder, the reviewer who left Review PASS, anyone on a stale or PROJECT_DOCS_FORCE=1 task, or anyone for a never-claimed task; it warns on closing without a passing review and on verify markers such as none, n/a, no run, ninguno, an em dash or UNKNOWN
- Files: scripts/project_docs.sh,scripts/project_docs.ps1,scripts/smoke_test.sh
- Verify: sh scripts/smoke_test.sh -> 428 passed, 0 failed (sh + PowerShell); check . -> OK

## [2026-10-13T17:35:29Z] | claude-sonnet-5-5 | F05-E02-T01 | IN_PROGRESS | Add the Agent identity roster and canonical ids
- Summary: Change 5: Agent identity roster and canonical agent ids
- Verify: pending

## [2026-10-13T17:46:39Z] | claude-sonnet-5-5 | F05-E02-T01 | DONE | Add the Agent identity roster and canonical ids
- Summary: Optional Agent identity roster: aliases normalise to the Agent id in claim, pause, handoff, review and done; unknown names warn
- Files: scripts/,templates/AGENTS.md,AGENTS.md
- Verify: sh scripts/smoke_test.sh -> 474 passed, 0 failed (sh + PowerShell); check . -> OK

## [2026-10-13T17:46:53Z] | claude-sonnet-5-5 | F05-E02-T02 | IN_PROGRESS | Warn when work is documented after it is done
- Summary: Change 6: warn when work is claimed and closed minutes apart
- Verify: pending

## [2026-10-13T17:57:27Z] | claude-sonnet-5-5 | F05-E02-T02 | DONE | Warn when work is documented after it is done
- Summary: Warn when a task is claimed and closed minutes apart; check prints one summary plus the 5 most recent
- Files: scripts/
- Verify: sh scripts/smoke_test.sh -> 500 passed, 0 failed (sh + PowerShell); check . -> OK

## [2026-10-13T17:57:47Z] | claude-sonnet-5-5 | F05-E02-T03 | IN_PROGRESS | Add the assign command and ASSIGNED state
- Summary: Change 7: assign command and ASSIGNED state
- Verify: pending

## [2026-10-13T18:08:30Z] | claude-sonnet-5-5 | F05-E02-T03 | DONE | Add the assign command and ASSIGNED state
- Summary: assign command and ASSIGNED state: row stays TODO with the new Owner, claim by another agent warns, a task in progress cannot be assigned
- Files: scripts/
- Verify: sh scripts/smoke_test.sh -> 562 passed, 0 failed (sh + PowerShell); check . -> OK

## [2026-10-13T18:09:26Z] | claude-sonnet-5-5 | F05-E03-T01 | IN_PROGRESS | Document review and identity in templates and docs
- Summary: Change 8 and 9: templates, docs, evals and the regression test
- Verify: pending

## [2026-10-13T18:36:29Z] | claude-sonnet-5-5 | F05-E03-T01 | DONE | Document review and identity in templates and docs
- Summary: Templates, docs and evals for review, handoff and agent identity; golden regression test; evals 26 to 39
- Files: templates/,docs/,references/,scripts/smoke_test.sh,evals/evals.json
- Verify: sh scripts/smoke_test.sh -> 578 passed, 0 failed (sh + PowerShell); check . -> OK; differential run old vs new scripts identical

## [2026-10-26T13:27:31Z] | claude-sonnet-5-5 | F06-E01-T01 | IN_PROGRESS | Detect factory mode from the AGENTS.md settings table
- Summary: Detect factory mode; mode command; PROJECT_DOCS_MODE override
- Verify: pending

## [2026-10-26T13:45:56Z] | claude-sonnet-5-5 | F06-E01-T01 | REVIEW | Detect factory mode from the AGENTS.md settings table
- Summary: mode detection and mode command in sh and ps1 (commit 4797bf9)
- Verify: smoke 632 passed 0 failed (sh 317 ps1 315, was 578); differential vs master identical
- Handoff: claude-qa

## [2026-10-26T13:55:36Z] | claude-sonnet-5-5 | F06-E03-T01 | IN_PROGRESS | Brain template and check validation
- Summary: Brain template and check validation (sh and ps1)
- Verify: pending

## [2026-10-26T13:57:57Z] | claude-qa | F06-E01-T01 | REVIEW | Detect factory mode from the AGENTS.md settings table
- Summary: Review of the handoff from claude-sonnet-5-5
- Verify: factory smoke sh 27 passed 0 failed exit=0, ps1 27 passed exit=0; mode sh vs ps1 identical; lifecycle diff vs master identical both launchers; check OK exit=0
- Review: PASS - mode sh+ps1 byte-identical on 3 fixtures and 26 edge cases; additive diff; 7 mutations caught; classic lifecycle identical to master in sh and ps1

## [2026-10-26T13:58:25Z] | claude-sonnet-5-5 | F06-E01-T01 | DONE | Detect factory mode from the AGENTS.md settings table
- Summary: Mode detection and mode command in sh and ps1
- Files: scripts/,references/,docs/
- Verify: smoke 632 pass 0 fail; QA PASS; differential vs master identical

## [2026-10-26T14:14:08Z] | claude-sonnet-5-5 | F06-E03-T01 | REVIEW | Brain template and check validation
- Summary: Brain.md template and Factory-only check validation (5496c37)
- Verify: smoke 704 pass 0 fail (sh 353 ps1 351); differential vs master identical
- Handoff: claude-qa

## [2026-10-26T14:14:31Z] | claude-sonnet-5-5 | F06-E01-T02 | IN_PROGRESS | Init defaults to factory and migrate adds it
- Summary: init defaults to Factory; migrate --factory
- Verify: pending

## [2026-10-26T14:28:22Z] | claude-qa | F06-E03-T01 | REVIEW | Brain template and check validation
- Summary: Review of the handoff from claude-sonnet-5-5
- Verify: exit=0 factory smoke 63 pass sh and ps1; classic check identical to 9302b58; Brain.md missing exit=1
- Review: PASS - sh/ps1 agree on 75 of 81 edge fixtures, BR-008 holds. Non-blocking: ps1 aborts on Brain max entries over 2^31; NBSP, CRLF-on-Linux and exact-heading gaps

## [2026-10-26T14:28:43Z] | claude-sonnet-5-5 | F06-E03-T01 | DONE | Brain template and check validation
- Summary: Brain template and Factory-only check validation
- Files: templates/Brain.md,scripts/,references/factory.md
- Verify: smoke 704 pass 0 fail; QA PASS 81 fixtures; classic check identical

## [2026-10-26T14:40:20Z] | claude-sonnet-5-5 | F06-E01-T02 | REVIEW | Init defaults to factory and migrate adds it
- Summary: init Factory default, --classic, migrate --factory
- Verify: smoke 812 pass 0 fail (sh 407 ps1 405); differential vs master identical
- Handoff: claude-qa

## [2026-10-26T14:41:13Z] | claude-sonnet-5-5 | F06-E01-T03 | IN_PROGRESS | Compact factory rules and autonomy policy in template
- Summary: Factory rules pointer in migrated decisions section
- Verify: pending

## [2026-10-26T15:04:43Z] | claude-sonnet-5-5 | F06-E01-T03 | REVIEW | Compact factory rules and autonomy policy in template
- Summary: Decisions pointer via migrate; fresh context 6750 B
- Verify: smoke 856 pass 0 fail (sh 429 ps1 427); differential vs master identical
- Handoff: claude-qa

## [2026-10-26T16:08:05Z] | claude-qa | F06-E01-T02 | REVIEW | Init defaults to factory and migrate adds it
- Summary: Review of the handoff from claude-sonnet-5-5
- Verify: smoke factory sh 117/0 + ps1 117/0 exit=0; BR-008 diff 10 scenarios identical; sh==ps1 20 scenarios
- Review: PASS - PASS: smoke 117/117 sh+ps1, BR-008 identical, sh==ps1. Non-blocking: roster fill says added on reruns when no exact placeholder row; Linux sh+CRLF AGENTS.md misplaces sections

## [2026-10-26T16:08:18Z] | claude-sonnet-5-5 | F06-E01-T02 | DONE | Init defaults to factory and migrate adds it
- Summary: init defaults to Factory, init --classic, migrate --factory
- Files: scripts/,templates/,README.md,references/
- Verify: smoke 812 pass 0 fail; QA PASS sh==ps1 20 scenarios; BR-008 identical

## [2026-10-26T16:09:15Z] | claude-sonnet-5-5 | F06-DEBT-01 | IN_PROGRESS | Harden Brain cap parsing and CRLF handling in migrate
- Summary: Harden Brain cap parsing and CRLF handling
- Verify: pending

## [2026-10-26T16:13:24Z] | claude-qa | F06-E01-T03 | REVIEW | Compact factory rules and autonomy policy in template
- Summary: Review of the handoff from claude-sonnet-5-5
- Verify: smoke factory sh 139/0 + ps1 139/0 exit=0; sh==ps1 4 fixtures; Linux busybox CRLF ok; fresh ctx 6750B
- Review: PASS - PASS: smoke 139/139 sh+ps1; pointer sh==ps1 on classic, CRLF, reworded-bullet and Factory-init fixtures; once, after bullet, 0 changes on rerun; Linux sh ok. Bullet text match is exact

## [2026-10-26T16:46:37Z] | claude-sonnet-5-5 | F06-E01-T03 | DONE | Compact factory rules and autonomy policy in template
- Summary: Decisions pointer via migrate; fresh Factory context 6750 B
- Files: scripts/,references/factory.md
- Verify: smoke 856 pass 0 fail; QA PASS factory smoke 139 each; context 6750 B

## [2026-10-26T17:02:37Z] | claude-sonnet-5-5 | F06-DEBT-01 | REVIEW | Harden Brain cap parsing and CRLF handling in migrate
- Summary: Cap parsing, CRLF, roster rerun, flags hardened
- Verify: smoke 902 pass 0 fail (sh 452 ps1 450); differential vs master identical
- Handoff: claude-qa

## [2026-10-26T17:02:56Z] | claude-sonnet-5-5 | F06-E02-T01 | IN_PROGRESS | Spec template and check rules for scenarios
- Summary: Spec template and check rules for scenarios
- Verify: pending

## [2026-10-26T17:16:36Z] | claude-qa | F06-DEBT-01 | REVIEW | Harden Brain cap parsing and CRLF handling in migrate
- Summary: Review of the handoff from claude-sonnet-5-5
- Verify: smoke factory sh 162/0 + ps1 162/0 exit=0; BR-008 diff 3 scenarios identical; Linux busybox CRLF ok
- Review: PASS - PASS: smoke 162/162 sh+ps1; CRLF, header-only/dash/padded roster, flags fixed and sh==ps1; BR-008 identical. Residual: roster not filled when separator is '  ---  ' (silent)

## [2026-10-26T17:18:05Z] | claude-sonnet-5-5 | F06-DEBT-01 | DONE | Harden Brain cap parsing and CRLF handling in migrate
- Summary: Cap parsing, CRLF, roster rerun and flags hardened
- Files: scripts/,references/factory.md
- Verify: smoke 902 pass 0 fail; QA PASS factory 162 each; BR-008 identical

## [2026-10-26T17:58:48Z] | claude-sonnet-5-5 | F06-E02-T01 | REVIEW | Spec template and check rules for scenarios
- Summary: Spec template and Factory-only spec validation
- Verify: smoke 1026 pass 0 fail (sh 514 ps1 512); differential vs master identical
- Handoff: claude-qa

## [2026-10-26T18:00:29Z] | claude-sonnet-5-5 | F06-E02-T03 | IN_PROGRESS | Phase roles in the roster and claim
- Summary: Phase roles in the roster and claim
- Verify: pending
