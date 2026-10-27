# Brain

Reusable lessons and a map of the project, kept in git and read by `recall`
(never loaded whole). `learn` appends rows, `retro` records which ones a task
used, `rotate` archives the least used rows when the file passes its cap.

## Operational summary

- Entries: 9 of 80
- Last gc: —

<!-- context:end -->

## Entries

| ID | Name | Kind | Trigger | Lesson | Evidence | Status | Hits | Last used |
|---|---|---|---|---|---|---|---|---|
| LRN-001 | Prefer the most reversible option | DEFAULT | * | When two options are equivalent choose the one cheaper to undo and record it as an ADR | seed | CONFIRMED | 0 | — |
| LRN-002 | Ambiguous product rule takes the stricter behavior | DEFAULT | * | Record it as a HYPOTHESIS BR row and pin it with a scenario | seed | CONFIRMED | 0 | — |
| LRN-003 | Reproduce a bug before fixing it | PATTERN | bug fix regression | The RED test of a BUG task reproduces the reported failure first | seed | CONFIRMED | 0 | — |
| LRN-004 | A shell heredoc loses backslashes in a patch script | PITFALL | heredoc backslash patch script node | Write patch scripts with the file tool, use String.raw for the text, and replace with split and join, never a string with a dollar sign. | log:F06-E05-T03 | HYPOTHESIS | 0 | — |
| LRN-005 | git shows only the new name of a renamed file | PITFALL | git diff rename protected path tests | Pass --no-renames wherever a check decides from the files that changed, or a move hides the old path. | log:F06-E05-T03 | HYPOTHESIS | 0 | — |
| LRN-006 | PowerShell comparisons and hashtables ignore letter case | PITFALL | powershell ps1 compare eq match hashtable | Use -ceq, -cin and -cmatch when the case matters and remember that hashtable keys are case insensitive. | log:F06-E05-T03 | HYPOTHESIS | 0 | — |
| LRN-007 | Run every case through both launchers and focus the runs | PATTERN | smoke test sh ps1 parity focus | Write each case once for sh and ps1, run only the new block while iterating (SMOKE_ONLY), and the full smoke once at the end. | log:F06-E05-T03 | HYPOTHESIS | 0 | — |
| LRN-008 | Where the dispatcher and its tests live | MAP | dispatcher dogfood fake cli diff regression | scripts/factory_dispatch.sh and .ps1 are the dispatcher; scripts/tests has fake_cli, dogfood.sh and diff_regression.sh; SMOKE_ONLY=dispatch runs its cases. | log:F06-E05-T03 | HYPOTHESIS | 0 | — |
| LRN-009 | A lock created after a test is not exclusive | PITFALL | lock mkdir exclusive race takeover docs | Create the lock with one atomic call (mkdir), and take an old lock over behind a marker that reads its age again. | log:F06-E05-T03 | HYPOTHESIS | 0 | — |
