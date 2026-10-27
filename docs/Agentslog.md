# Agents log

Append-only ledger and the source of truth for task ownership. Older
segments live in `docs/history/`.

## Entry format

```markdown
## [YYYY-MM-DDTHH:mm:ssZ] | agent | TASK-ID | IN_PROGRESS | Name
- Summary: what the agent will do or did
- Files: paths or component names (optional)
- Verify: command and result, or "pending" (required for DONE and REVIEW)
- Pause: CATEGORY - detail (required for PAUSE)
- Handoff: reviewer agent or role (optional, REVIEW)
- Review: PASS|FAIL - detail (optional, REVIEW)
- Assign: agent (required for ASSIGNED)
```

## Previous segment

- Archive: `docs/history/Agentslog-20261027-001.md`
- SHA-256: `11cef1c3f5897516f230df8350beb96bf8623a060c25e99d3c55c176b8f651f2`

## Entries

## [2026-10-27T19:24:43Z] | claude-sonnet-5-5 | F06-E05-T03 | IN_PROGRESS | Dogfood a full factory lifecycle end to end
- Summary: carried forward from docs/history/Agentslog-20261027-001.md at rotation
