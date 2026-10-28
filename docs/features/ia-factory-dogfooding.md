# IA Factory: dogfooding report (F06-E05-T03)

Section 8 of [ia-factory.md](ia-factory.md) asks for a full lifecycle run through the
dispatcher, measured. This is that run. It is repeatable:

```sh
sh scripts/tests/dogfood.sh sh    # POSIX sh launchers
sh scripts/tests/dogfood.sh ps1   # PowerShell 5.1 launchers
```

Each prints its expectations (`ok`/`FAIL`), then its measurements, and exits 1 if one fails.
Last run, on the final scripts (`e44780f`): **sh 21 passed, 0 failed; ps1 21 passed, 0 failed**,
with the same counts in both.

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
| `context` of this repository after adopting Factory mode | 7771 bytes right after adopting it; 7974 to 8078 along the lane of the last task, already showing only the latest entry (ADR-080); once 8204, which fails (see below) | 7761; 8066 | 8192 |
| `recall` of this task in this repository | 1305 bytes at GREEN (1373 at the final review), 3 of 10 brain rows | 1325 (1393) | 4096 |

`gemini-qa` wrote two reviews (the `PASS` of the spec and the `FAIL` of the code) and its third
run, the one that hit the quota, wrote none; of the two reviews by `claude-qa` one is the fast
task and the other the covered review of the normal task. The run ended with 17 runs, not with
an agent waiting for a person.

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
`.factory/dispatch.md` and the `.gitignore` block. `Preferred reviewer` stays empty: the only QA
agent of this repository has the model of its developer, so an audit would be a self-audit. The
brain holds the three default lessons and seven that this work taught (heredocs and
backslashes, `git` renames, PowerShell case, atomic locks, focused runs, where the dispatcher
lives, and trying a new gate on tasks that lack its path). `check .` passes and `context` is 7771 bytes (sh) right after the adoption.

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
- The review of this report found that a task whose scenarios are all `Level: NONE` (docs, config,
  infra) could not reach GREEN, and therefore could not be closed once `done` required GREEN
  (ADR-090): `advance` now lets RED go to GREEN with no failing test when every scenario is `NONE`
  and no test file is listed, except for a `Fxx-BUG-xx` row (ADR-091).
- Retaking a task that was claimed before the project moved to Factory mode wrote a `Phase: SPEC`
  that `done` then refused, so `claim` now keeps such a task without phase and lane (ADR-092).
- Two dispatcher cases failed under load by one second, because the clock was read twice for one
  decision: it is read once now (ADR-094); the dispatcher suite then passed 3 times in sh and in
  ps1 while other runs loaded the machine.
- The same review found that a lifecycle entry could still be written by hand with `append-log`,
  also in `in_progress` or `Done`, which PowerShell accepts: in Factory mode `append-log` now
  writes only `AUDIT` (ADR-093).
- `context` of this repository failed at 8204 bytes while the only entry shown was a handoff with
  a long `Verify`: ADR-080 shows fewer entries but not shorter ones. With `AGENTS.md` at 5.9 KB the
  room for the latest entry is about 400 bytes, so the entries of this repository are kept short.

## Appendix: what the real run left behind (step 6)

The dispatcher output of the four `--once` runs (the line "2 failure(s)" counts the failed
run that preceded the log below, made while setting the experiment up):

```
dispatch: run 1: claude-dev on F91-E01-T01
dispatch: run 1 ok
dispatch: run 1: gemini-qa on F91-E01-T01
dispatch: run 1 failed (exit 1), 2 failure(s) for gemini-qa on F91-E01-T01
dispatch: run 1: claude-qa on F91-E01-T01 (covers gemini-qa)
dispatch: run 1 ok
dispatch: run 1: claude-dev on F91-E01-T01
dispatch: run 1 ok
```

The output of the real `gemini -p` run, saved by the dispatcher in `.factory/runs/` (the stack
trace lines are left out):

```
Error authenticating: IneligibleTierError: This client is no longer supported for Gemini Code
Assist for individuals. To continue using Gemini, please migrate to the Antigravity suite of
products: https://antigravity.google
```

The ledger of that project at the end (trimmed to the headers and the lines that matter):

```
## [..T04:05:34Z] | claude-dev | F91-E01-T01 | IN_PROGRESS | Create the hello file
- Phase: GREEN / - Lane: FAST / - Base: 8d5d4f3...
## [..T04:06:03Z] | claude-dev | F91-E01-T01 | REVIEW | Create the hello file
- Verify: grep -qx hello hello.txt exit=0 / - Handoff: gemini-qa
## [..T04:07:58Z] | claude-qa | F91-E01-T01 | REVIEW | Create the hello file
- Review: PASS - hello.txt is exactly 'hello\n'; acceptance met / - Cross-model: NO
## [..T04:09:03Z] | claude-dev | F91-E01-T01 | DONE | Create the hello file
- Brain: used none; learned none / - Cross-model: NO
```
