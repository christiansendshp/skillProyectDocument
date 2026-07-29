# Compact project documentation

For every software project or change, use `project-documentation` (or the legacy
`skillProyectDocument` installation path). Run `init` and `context` before
coding. Use the bounded context output and load full documents only when
task-relevant.

After each logical change, update only affected truths, append one compact entry
to `docs/Agentslog.md`, run `rotate`, and require `check` to pass.

Maintain the exact six contract files under `docs/`: `Agents.md`,
`Agentslog.md`, `ProductDescription.md`, `Stack_Tecnologies.md`, `Roadmap.md`,
and `Features.md`. Never invent facts or record secrets.
