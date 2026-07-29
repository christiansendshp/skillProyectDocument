# Compact project-memory workflow

## Principles

- Keep the six contract files present from project initialization onward.
- Separate hot context from cold history.
- Document one logical change, not every individual edit or tool call.
- Point to code, tests, commits, issues, and detailed files instead of copying
  their contents.
- Use `CONFIRMED`, `UNKNOWN`, `HYPOTHESIS`, or `N/A` for facts whose certainty
  matters.
- Never store secrets, credentials, real environment values, or sensitive
  command output.

## Context budget

The `context` command emits:

1. all of `Agents.md`;
2. the bounded `Operational summary` blocks from Product, Stack, and Features;
3. active Roadmap rows;
4. the five latest Agentslog entries, capped to the hot ledger.

The result must remain at or below 8 KiB. If it exceeds the limit, compact the
summaries or split detail into `docs/features/` or `docs/history/`. Never
truncate repository rules silently.

Read full documents only by task:

| Task changes or needs | Read/update |
|---|---|
| user outcomes, roles, domain rules | `ProductDescription.md` |
| dependencies, architecture, security, data, commands | `Stack_Tecnologies.md` |
| active scope, ownership, acceptance criteria | `Roadmap.md` |
| existing verified behavior | `Features.md` |
| recent coordination or a referenced past decision | `Agentslog.md` or its archive |

## New project

1. Run `init`; it creates only missing files.
2. Replace known placeholders with confirmed facts from the request or project.
3. Leave unknowns explicit instead of delaying harmless implementation.
4. Add the initial active Roadmap task with an acceptance check.
5. Implement, verify, update affected truth, and append one log entry.

## Existing project

1. Run `init` to recover only missing contract files.
2. Run `context`.
3. Reconstruct facts from source files, dependency manifests, tests, and
   configuration. Mark uncertain inferences as `HYPOTHESIS` with a verification
   step.
4. Do not rewrite intact project documentation merely to match the templates.

## Multi-agent coordination

- Use Roadmap ownership only for work that may overlap.
- Format owner as `<agent>@<timestamp>`.
- Do not touch a row owned by another active agent unless coordinating.
- Store decisions in Stack; store the resulting action and pointers in the log.
- Escalate incompatible concurrent decisions instead of silently overwriting
  another agent's work.

## Ledger and rotation

Use one log entry per logical change:

```markdown
## [YYYY-MM-DDTHH:mm:ssZ] | agent | TASK-ID | DONE
- Summary: observable outcome
- Files: compact paths or component names
- Verify: command and result
- Follow-up: none or one pointer
```

Keep entries under six lines and approximately 700 characters. The hot ledger
rotates after 200 entries or 128 KiB. Rotation must:

1. copy the complete ledger to a unique `docs/history/Agentslog-*.md`;
2. verify the archived copy by hash;
3. replace the hot ledger atomically;
4. record the archive path and hash in the new ledger.

Archives are immutable. Read one only when a current entry or decision points to
it.

## Content maintenance

- Product keeps stable functional truth, not implementation plans.
- Stack keeps current technical truth plus a compact decision table. Put long
  ADRs in `docs/decisions/` and link them.
- Roadmap contains active and near-term work. Remove completed detail after
  preserving the verified capability in Features and the change in Agentslog.
- Features is an index. Put long runbooks or feature specifications in
  `docs/features/` and link them.
- Git is the recovery mechanism for normal deletions. Archive only audit history
  and superseded decisions that remain useful; do not enforce “nothing is ever
  deleted.”

## Gate

Run `check` after documentation updates. It verifies the six files, required
sections, the 8 KiB context budget, and ledger rotation thresholds. A task is
not complete while the command exits non-zero.
