# project-documentation

Compact project memory for AI coding agents. It creates six stable files at
project initialization and keeps startup context bounded while preserving cold
history.

The repository name and legacy installation folder `skillProyectDocument`
remain supported during transition. The canonical skill name is
`project-documentation`.

## Contract files

Every project receives these exact files under `docs/`:

| File | Compact responsibility |
|---|---|
| `Agents.md` | Rules and selective-reading policy |
| `Agentslog.md` | Recent logical changes |
| `ProductDescription.md` | Current functional truth |
| `Stack_Tecnologies.md` | Current technical truth; legacy spelling retained |
| `Roadmap.md` | Active and near-term work |
| `Features.md` | Index of verified capabilities |

Additional detail may live under `docs/features/`, `docs/decisions/`, or
`docs/history/` and is loaded only when referenced by the current task.

## Commands

POSIX:

```sh
sh scripts/project_docs.sh init /path/to/project
sh scripts/project_docs.sh context /path/to/project
sh scripts/project_docs.sh check /path/to/project
```

PowerShell:

```powershell
& scripts/project_docs.ps1 init C:\path\to\project
& scripts/project_docs.ps1 context C:\path\to\project
& scripts/project_docs.ps1 check C:\path\to\project
```

Both launchers also provide `append-log` and `rotate`. Initialization is
idempotent and never overwrites an existing contract file. `context` emits at
most 8 KiB. The hot log must rotate after 200 entries or 128 KiB; the archive is
hash-verified before the current ledger is replaced.

See `SKILL.md` for the agent workflow and `references/adapters.md` for runtime
installation.
