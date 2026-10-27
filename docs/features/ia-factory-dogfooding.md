# IA Factory: dogfooding report (F06-E05-T03)

Section 8 of [ia-factory.md](ia-factory.md) asks for a full lifecycle run through the
dispatcher, measured. This is that run. It is repeatable:

```sh
sh scripts/tests/dogfood.sh sh    # POSIX sh launchers
sh scripts/tests/dogfood.sh ps1   # PowerShell 5.1 launchers
```

Each prints its expectations (`ok`/`FAIL`), then its measurements, and exits 1 if one fails.
Last run, on the final scripts: **sh 21 passed, 0 failed; ps1 21 passed, 0 failed**, with the
same counts in both.

## What ran (steps 1 to 5)

A temporary Factory project (`init`, git, the roster of D-21: `claude-spec`, `claude-test`,
`claude-dev`, `claude-qa` with Model Claude and `gemini-qa` with Model Gemini; `Preferred
reviewer` `gemini-qa`, `Fallback reviewer` `claude-qa`, `Fast lane max files` 2). The driver
only sets this up and then calls the dispatcher with `--once`, one run at a time, reading
`context`, `recall`, `status`, `digest`, `check` and `next` between runs. Every change to the
project is made by a fake agent that the dispatcher launched (`scripts/tests/fake_cli.*`
following a script with one line per run). The only thing moved by hand is the clock: the
cooldown of the gemini plan is set to expire before the last run.

| Task | What the run showed |
|---|---|
| F90-E01-T01, normal lane | SPEC written by `claude-spec` and reviewed by `gemini-qa` -> `advance` to RED -> `claude-test` writes a real test (`sh tests/check.sh`), commits it and advances with the real `exit=2` -> `claude-dev` implements, hands off with the real `exit=0` -> `gemini-qa` fails the review (a debug line) -> `claude-dev` fixes it and `learn`s the lesson -> Gemini runs out of quota (`RESOURCE_EXHAUSTED`) in the middle -> the gemini plan cools down -> `claude-qa` covers the review (`Cross-model: NO`) -> `retro` with the lesson used and the lesson learned -> `done` -> the quota is back and `gemini-qa` audits it with an `AUDIT` entry |
| F90-E01-T02, fast lane | `claude-dev` claims, changes, tests, hands off; the handoff goes to the `Fallback reviewer`; `claude-qa` passes it; `retro` and `done` |
| F90-E01-T03, fast lane that outgrows | three files with a limit of two: `handoff` fails with `task outgrew FAST lane`, the work is saved in a branch, `advance ... SPEC` sends it back, the row loses `Lane: FAST`, `claude-spec` takes it; `check` stays green |
| F90-E01-T04, red line | `claude-spec` pauses it with `RED-LINE: deletes production data`; `next` never offers it again; `digest` lists it |

17 dispatcher runs and 26 ledger entries took the four tasks to their end states. A classic
project created with `init --classic` was then brought over with `migrate --factory` (step 7):
the mode changed, `check` passed and a second `migrate --factory` changed nothing.

## Measurements

| Measure | sh | ps1 | Budget |
|---|---|---|---|
| Dispatcher runs | 17 | 17 | — |
| Runs per agent (`claude-spec`, `claude-test`, `claude-dev`, `claude-qa`, `gemini-qa`) | 4, 1, 6, 2, 4 | 4, 1, 6, 2, 4 | — |
| Reviews written by `gemini-qa` / `claude-qa` | 2 / 2 | 2 / 2 | — |
| `context` of a fresh Factory project | 6750 bytes | the same file content | 6912 |
| Largest `context` during the run | 8185 bytes | 8186 bytes (console encoding) | 8192 |
| `recall` of the normal task in GREEN | 913 bytes, 2 of 3 brain rows | 913 bytes, 2 of 3 | 4096 (`Recall budget bytes`) |
| `digest` at the end | 405 bytes | 405 bytes | 4096 |
| `context` of this repository after adopting Factory mode | 7765 bytes | — | 8192 |
| `recall` of this task in this repository | 1192 bytes, 3 of 9 brain rows | — | 4096 |

The two `gemini-qa` reviews were one `FAIL` and one that never happened because the quota ran
out: the second `claude-qa` review is the covered one. The run ended with 17 runs, not with an
agent waiting for a person.

## The real CLIs (step 6)

Both CLIs are installed on the machine where the branch was built: `claude` 2.1.309 and
`gemini` 0.42.0. The flags of the default `.factory/dispatch.md` were confirmed with each
CLI's `--help`: `claude -p`, `--permission-mode acceptEdits`, `--allowedTools` (and `--bare`,
which is not used), `gemini -p` and `--approval-mode=yolo`.

A real run through the dispatcher (`factory_dispatch.sh <project> --once`, four times) on a
trivial fast-lane task ("create hello.txt") in a Factory project whose `dispatch.md` held the
real commands, with `Fallback reviewer` `gemini-qa`:

1. `claude-dev` (real `claude -p`, `--allowedTools "Bash(sh *)" "Bash(git *)"`) claimed the
   task, created the file, wrote a checkpoint and handed it off. Run ok.
2. `gemini-qa` (real `gemini -p`) failed twice with `IneligibleTierError: This client is no
   longer supported for Gemini Code Assist for individuals` and exit 1. That is not a quota
   text, so the dispatcher counted two failures and then left the review to `claude-qa`,
   which `dispatch.md` lists as covering `gemini-qa`.
3. `claude-qa` (real `claude -p`) reviewed it: PASS, with `Cross-model: NO` in the entry.
4. `claude-dev` closed it with `retro` and `done`. `check` passed.

So Claude Code works end to end with the subscription login and no API key, and an unusable
Gemini CLI does not stop the factory: the cost is two failed runs and a same-model review
that the ledger marks. The Gemini CLI of this machine cannot be used until its account is
moved to a supported product; the commands in `templates/dispatch.md` are right for a Gemini
CLI that works, but the Gemini side of the cross-model review was only exercised with fakes.

## The repository adopts Factory mode (step 8)

This repository now runs in Factory mode. To make room for the new section its `AGENTS.md`
was compacted (the rules are the same; the two "startup" lists and the "taking a task" list
that repeated each other were merged, `Work branch` and `Test command` were filled in with what
is confirmed, and the roster has the new roles), `rotate` archived the ledger of 229 entries
to `docs/history/Agentslog-20261027-001.md`, and `migrate --factory` added the `## Factory`
section, `docs/Brain.md`, the `docs/specs/` and `docs/brain/tasks/` folders,
`.factory/dispatch.md` and the `.gitignore` block. `Preferred reviewer` is `claude-qa`. The
brain holds the three default lessons and six that this work taught (heredocs and
backslashes, `git` renames, PowerShell case, atomic locks, focused runs, where the dispatcher
lives). `check .` passes and `context` is 7765 bytes.

The last task of the branch, this one, was closed with the Factory rules of the repository
itself: `checkpoint`, a `handoff` with `exit=0`, a review by `claude-qa`, `retro` with the
lessons used and learned, and `done`.

## What the run changed

The dogfooding found things the unit-level cases had not:

- `context` died with a hard error at 8348 bytes after two tasks had paused. An agent that
  starts without context cannot work, so Factory mode now shows fewer of the five latest
  entries and says so (ADR-080).
- Nothing gave a reviewed task back to its developer, so the loop ended after the review.
  `next` now returns it first (F06-E01-T06, ADR-068).
- A pair of agent and task that failed three times, without being able to pause, could have
  looped for ever: the dispatcher now skips it (ADR-071, ADR-081).
- `learn` accepted a tab that broke the brain rows in sh, `done` accepted a stale
  `learned none`, git hid renames from the size and test checks, a rotation dropped the audit
  queue, the PowerShell lock was not exclusive: all fixed after the QA reviews (ADR-073 to
  ADR-089).
