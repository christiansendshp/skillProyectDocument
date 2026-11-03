# Dispatcher configuration

Read by `scripts/factory_dispatch.sh` and `scripts/factory_dispatch.ps1`. Committed with the
project. The dispatcher asks `next <agent>` for each agent of the `## Agents` table, in order, and
runs the command of the first one that has work. Nobody calls anybody: the ledger in
`docs/Agentslog.md` is the channel.

Keep every cell free of the pipe character. Edit the commands to match the CLIs installed on
the machine (confirm each flag with the CLI's own `--help` before relying on it).

## Settings

| Key | Value |
|---|---|
| Run timeout minutes | 60 |
| Idle seconds | 300 |

## Agents

`Plan` groups the agent ids that share one quota: when one of them hits its limit, every agent
with the same plan cools down. `Limit text` holds substrings, separated by a semicolon, that
mark a quota cut in the output of a failed run (case is ignored). `Max runs per day` caps the
runs of an agent per local day (a dash means no cap). `Covers for` names the agent whose
reviews this agent takes while the plan of the other is cooling down or it failed its review
twice (a dash means none). `{PROMPT_FILE}` becomes the path of the prompt written for the run.

| Agent id | Plan | Command | Limit text | Cooldown minutes | Max runs per day | Covers for |
|---|---|---|---|---|---|---|
| gemini-qa | gemini | `gemini --approval-mode=yolo -p "Read {PROMPT_FILE} and follow it"` | RESOURCE_EXHAUSTED; quota; 429 | 60 | 20 | — |
| claude-spec | claude | `claude -p "Read {PROMPT_FILE} and follow it" --permission-mode acceptEdits` | hit your session limit; hit your weekly limit; hit your opus limit | 60 | — | — |
| claude-test | claude | `claude -p "Read {PROMPT_FILE} and follow it" --permission-mode acceptEdits` | hit your session limit; hit your weekly limit; hit your opus limit | 60 | — | — |
| claude-dev | claude | `claude -p "Read {PROMPT_FILE} and follow it" --permission-mode acceptEdits` | hit your session limit; hit your weekly limit; hit your opus limit | 60 | — | — |
| claude-qa | claude | `claude -p "Read {PROMPT_FILE} and follow it" --permission-mode acceptEdits` | hit your session limit; hit your weekly limit; hit your opus limit | 60 | — | gemini-qa |

## Notes

- Never use `claude --bare` here: it does not read the subscription login and asks for an API key.
- Shell commands other than file edits need `--allowedTools` or `permissions.allow` rules in the
  project's `.claude/settings.json` (the agents run `scripts/project_docs.sh` or `.ps1`).
- `gemini -p` runs without a screen; YOLO is only on with the `--approval-mode=yolo` flag.
- The agent CLIs run without `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `GEMINI_API_KEY` and
  `GOOGLE_API_KEY` in their environment, so they use the login of their subscription.
- A `Cooldown minutes` cell that is not a number (or is 0) takes 60 minutes.
- To stop the dispatcher after the run in progress, create the file `.factory/STOP`.
