# Compact project documentation

Use the `project-documentation` skill whenever creating, opening, or changing a
software project. The legacy installation folder `skillProyectDocument` is also
accepted; do not install both.

Before coding:

1. Locate the skill folder (`project-documentation` first, legacy folder second).
2. Run its `scripts/project_docs.ps1 init .` on PowerShell or
   `sh scripts/project_docs.sh init .` on POSIX.
3. Run `context` with the same launcher and use that bounded output as startup
   context.
4. Read full Product, Stack, Features, or cold history only when relevant.

After each logical change:

1. Update only affected truths in the six files under `docs/`.
2. Append one compact ledger entry using `append-log`.
3. Run `rotate`, then `check`; do not report completion if `check` fails.

The exact six filenames are `Agents.md`, `Agentslog.md`,
`ProductDescription.md`, `Stack_Tecnologies.md`, `Roadmap.md`, and
`Features.md`. Preserve the legacy spelling of `Stack_Tecnologies.md`.

Never document secrets or copy details already authoritative in code, tests,
commits, or issues. Use `UNKNOWN` or `HYPOTHESIS` instead of inventing facts.
