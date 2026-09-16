# Agents log

Append-only ledger and the source of truth for task ownership. The current
state of a `TASK-ID` is whatever its latest entry says. Never edit a past
entry; record a state change as a new entry. Keep one entry per logical
change, no more than six lines or roughly 700 characters. Older segments live
in `docs/history/`.

## Entry format

```markdown
## [YYYY-MM-DDTHH:mm:ssZ] | agent | TASK-ID | IN_PROGRESS
- Summary: what the agent will do or did
- Files: paths or component names (optional)
- Verify: command and result, or "pending" (required for DONE)
- Pause: CATEGORY - detail (required for PAUSE; CATEGORY is one of LIMITE,
  ESPERA_RESPUESTA, BLOQUEO, OTRO)
```

Entry states: `IN_PROGRESS` (taken), `PAUSE`, `DONE`. Write entries with
`claim`, `pause`, and `done`; use `append-log` only for entries outside a
task's claim lifecycle (its header status is free text, commonly `DONE`).

## Entries
