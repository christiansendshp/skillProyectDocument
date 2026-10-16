# Agents log

Append-only ledger and the source of truth for task ownership. The current
state of a `TASK-ID` is whatever its latest entry says. Never edit a past
entry; record a state change as a new entry. Keep one entry per logical
change, no more than six lines or roughly 700 characters. Older segments live
in `docs/history/`.

## Entry format

```markdown
## [YYYY-MM-DDTHH:mm:ssZ] | agent | TASK-ID | IN_PROGRESS | Name
- Summary: what the agent will do or did
- Files: paths or component names (optional)
- Verify: command and result, or "pending" (required for DONE and REVIEW)
- Pause: CATEGORY - detail (required for PAUSE; CATEGORY is one of LIMITE,
  ESPERA_RESPUESTA, BLOQUEO, OTRO)
- Handoff: reviewer agent or role (optional, REVIEW)
- Review: PASS|FAIL - detail (optional, REVIEW)
- Assign: agent (required for ASSIGNED)
```

`Name` is the same short (<= 10 word) title as the task's Roadmap row —
`claim`/`pause`/`done` copy it in automatically, never type it by hand, and
`check` errors if a later entry's Name drifts from the Roadmap row's current
one. Entry states: `IN_PROGRESS` (taken), `PAUSE`, `REVIEW`, `ASSIGNED`,
`DONE`. Write entries with `claim`, `pause`, `handoff`, `review`, `assign`
and `done`; use `append-log` only for entries outside a task's lifecycle (its
header status is free text, commonly `DONE`, and carries no Name field).

The state of a task is its LAST entry. `REVIEW` is the review stage: the
developer's `handoff` writes a REVIEW entry (with an optional `Handoff:`
line), the reviewer answers with a REVIEW entry carrying `Review: PASS` or
`Review: FAIL`. A `FAIL` means the task is back with its developer, who
retakes it with `claim`. The Roadmap row stays `IN_PROGRESS` the whole time:
the stage lives only here.

## Entries
