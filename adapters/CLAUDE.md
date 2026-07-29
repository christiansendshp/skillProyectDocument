# Compact project documentation

Use the `project-documentation` skill before and after every logical software
change, even when documentation was not requested. Accept
`.claude/skills/skillProyectDocument/` only as a legacy installation path.

Before coding, run the skill's `project_docs.sh init .` and `context .`. Read the
bounded context output; open full Product, Stack, Features, or history only when
the task needs it.

After coding, update only affected truths, append one compact Agentslog entry,
run `rotate`, and require `check` to pass.

Keep the exact six files under `docs/`: `Agents.md`, `Agentslog.md`,
`ProductDescription.md`, `Stack_Tecnologies.md`, `Roadmap.md`, and
`Features.md`. Never invent facts or record secrets.
