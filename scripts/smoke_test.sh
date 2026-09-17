#!/usr/bin/env sh
# Smoke test for project_docs.sh and, if a PowerShell interpreter is
# available, project_docs.ps1. Exercises the scenarios in evals/evals.json
# end to end. Exit code is non-zero if any assertion fails.
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SH_BIN="$SCRIPT_DIR/project_docs.sh"
PS1_BIN="$SCRIPT_DIR/project_docs.ps1"
# A space in every project path here is deliberate: the prompt requires
# spaces-in-path support (eval #1), and it is otherwise easy for a quoting
# mistake in either script to go unnoticed.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/project-docs-smoke.XXXXXX")/a project dir"
mkdir -p "$WORK"
PASS=0
FAIL=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT HUP INT TERM

ok() { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

assert_success() {
  desc="$1"; shift
  if "$@" >"$WORK/.out" 2>&1; then ok "$desc"; else bad "$desc (exit $?): $(tail -n 3 "$WORK/.out")"; fi
}

assert_failure() {
  desc="$1"; shift
  if "$@" >"$WORK/.out" 2>&1; then bad "$desc (unexpectedly succeeded)"; else ok "$desc"; fi
}

assert_contains() {
  desc="$1"; file="$2"; needle="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then ok "$desc"; else bad "$desc (missing '$needle' in $file)"; fi
}

assert_not_exists() {
  desc="$1"; path="$2"
  if [ ! -e "$path" ]; then ok "$desc"; else bad "$desc ($path still exists)"; fi
}

assert_not_exists_pattern() {
  desc="$1"; file="$2"; needle="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then bad "$desc (still contains '$needle')"; else ok "$desc"; fi
}

run_suite() {
  label="$1"
  run() { "$RUNNER" "$@"; }

  proj="$WORK/${label}_proj"
  mkdir -p "$proj"

  echo "== $label: init idempotency (eval 1) =="
  assert_success "$label init creates six files" run init "$proj"
  h1="$(file_hash "$proj/AGENTS.md")"
  assert_success "$label second init" run init "$proj"
  h2="$(file_hash "$proj/AGENTS.md")"
  [ "$h1" = "$h2" ] && ok "$label second init leaves AGENTS.md unchanged" || bad "$label second init changed AGENTS.md"

  echo "== $label: link merges into custom files (eval 5) =="
  printf '# custom claude rules\nnever ship on friday\n' > "$proj/CLAUDE.md"
  printf 'use tabs\n' > "$proj/.cursorrules"
  assert_success "$label link merges CLAUDE.md/.cursorrules" run link "$proj"
  assert_contains "$label CLAUDE.md keeps custom content" "$proj/CLAUDE.md" "never ship on friday"
  assert_contains "$label .cursorrules keeps custom content" "$proj/.cursorrules" "use tabs"
  hc1="$(file_hash "$proj/CLAUDE.md")"
  assert_success "$label second link" run link "$proj"
  hc2="$(file_hash "$proj/CLAUDE.md")"
  [ "$hc1" = "$hc2" ] && ok "$label second link leaves CLAUDE.md unchanged" || bad "$label second link changed CLAUDE.md"

  echo "== $label: claim/pause/reclaim/done lifecycle (evals 6-8) =="
  seed_task "$proj"
  assert_success "$label claim by agentA" run claim "$proj" agentA SMOKE-T01 "start"
  assert_contains "$label claim leaves owner untouched" "$proj/docs/Roadmap.md" "name: Cristian"
  assert_failure "$label second claim by agentB fails" run claim "$proj" agentB SMOKE-T01 "steal"
  assert_success "$label pause LIMITE" run pause "$proj" agentA SMOKE-T01 LIMITE "context limit"
  assert_success "$label reclaim after LIMITE" run claim "$proj" agentB SMOKE-T01 "resume"
  assert_success "$label pause ESPERA_RESPUESTA" run pause "$proj" agentB SMOKE-T01 ESPERA_RESPUESTA "waiting on user"
  assert_failure "$label claim during ESPERA_RESPUESTA fails" run claim "$proj" agentC SMOKE-T01 "steal again"
  assert_success "$label owner reclaims after ESPERA_RESPUESTA" run claim "$proj" agentB SMOKE-T01 "resume again"
  assert_success "$label done requires non-empty verify" run done "$proj" agentB SMOKE-T01 "implemented" "src/x" "tests pass"
  assert_contains "$label Features.md records capability" "$proj/docs/Features.md" "SMOKE-T01"

  echo "== $label: done rejects empty verify / check flags bad log state (eval 11) =="
  seed_task2 "$proj"
  assert_failure "$label done with empty verify is rejected" run done "$proj" agentA SMOKE-T02 "x" "y" ""
  assert_success "$label append-log with bad status" run append-log "$proj" agentA SMOKE-T02 BOGUS "bad" "-" pending
  assert_failure "$label check fails on invalid status" run check "$proj"

  echo "== $label: rotation carries an open task forward (evals 9-10) =="
  proj2="$WORK/${label}_rotate"
  mkdir -p "$proj2"
  run init "$proj2" >/dev/null 2>&1
  seed_task "$proj2"
  run done "$proj2" seed SMOKE-T01 "seed close" "n/a" "n/a" >/dev/null 2>&1
  seed_task2 "$proj2"
  run claim "$proj2" agentD SMOKE-T02 "stay open across rotation" >/dev/null 2>&1
  i=1
  while [ "$i" -le 205 ]; do
    run append-log "$proj2" filler SMOKE-T01 DONE "filler $i" "n/a" "n/a" >/dev/null 2>&1
    i=$((i + 1))
  done
  assert_success "$label context stays open task visible" run context "$proj2"
  grep -q "SMOKE-T02" "$WORK/.out" && ok "$label Open tasks section lists SMOKE-T02" || bad "$label Open tasks section missing SMOKE-T02"
  assert_success "$label rotate archives the ledger" run rotate "$proj2"
  assert_success "$label status still shows SMOKE-T02 after rotation" run status "$proj2"
  grep -q "SMOKE-T02" "$WORK/.out" && ok "$label status lists SMOKE-T02 after rotation" || bad "$label status missing SMOKE-T02 after rotation"
  assert_success "$label check passes after rotation" run check "$proj2"

  echo "== $label: migrate legacy docs/Agents.md (eval 12) =="
  proj3="$WORK/${label}_migrate"
  mkdir -p "$proj3/docs"
  printf '# Agents\n\n## Repository rules\n- Custom rule: only Bob touches billing.\n' > "$proj3/docs/Agents.md"
  assert_failure "$label check fails before migrate" run check "$proj3"
  grep -q "migrate" "$WORK/.out" && ok "$label check message names migrate" || bad "$label check message doesn't mention migrate"
  assert_success "$label migrate" run migrate "$proj3"
  assert_contains "$label AGENTS.md keeps custom rule" "$proj3/AGENTS.md" "Bob"
  assert_not_exists "$label docs/Agents.md removed" "$proj3/docs/Agents.md"
  assert_success "$label check passes after migrate" run check "$proj3"
  hm1="$(file_hash "$proj3/AGENTS.md")"
  assert_success "$label second migrate" run migrate "$proj3"
  hm2="$(file_hash "$proj3/AGENTS.md")"
  [ "$hm1" = "$hm2" ] && ok "$label second migrate leaves AGENTS.md unchanged" || bad "$label second migrate changed AGENTS.md"

  echo "== $label: init preserves a hand-written AGENTS.md (eval 13) =="
  proj4="$WORK/${label}_ownagents"
  mkdir -p "$proj4"
  printf '# Repo rules\nonly deploy on tuesdays\n' > "$proj4/AGENTS.md"
  assert_success "$label init merges into existing AGENTS.md" run init "$proj4"
  assert_contains "$label existing AGENTS.md content kept" "$proj4/AGENTS.md" "only deploy on tuesdays"

  echo "== $label: epic rollup via parent (eval 21) =="
  proj5="$WORK/${label}_epic"
  mkdir -p "$proj5"
  run init "$proj5" >/dev/null 2>&1
  seed_epic_and_task "$proj5"
  assert_success "$label claim epic child task" run claim "$proj5" agentE SMOKE-EPIC-T01 "start"
  assert_success "$label done epic child task" run done "$proj5" agentE SMOKE-EPIC-T01 "implemented" "n/a" "verified"
  assert_contains "$label Features.md has epic rollup row" "$proj5/docs/Features.md" "SMOKE-EPIC-01"
  grep -q "| SMOKE-EPIC-01 | DONE" "$proj5/docs/Agentslog.md" && ok "$label Agentslog has a DONE entry for the epic id" || bad "$label Agentslog missing DONE entry for the epic id"
  assert_not_exists_pattern "$label epic entry removed from Roadmap.md" "$proj5/docs/Roadmap.md" "id: SMOKE-EPIC-01"
  assert_success "$label check passes after epic rollup" run check "$proj5"

  echo "== $label: dangling reference detection (evals 15-16) =="
  proj6="$WORK/${label}_refs"
  mkdir -p "$proj6"
  run init "$proj6" >/dev/null 2>&1
  seed_dangling_ref "$proj6"
  assert_failure "$label check fails on dangling parent/depends_on" run check "$proj6"
  grep -q "parent references unknown ID: SMOKE-NOPE-01" "$WORK/.out" && ok "$label check names the dangling parent" || bad "$label check doesn't name the dangling parent"
  grep -q "depends_on references unknown ID: SMOKE-MISSING-01" "$WORK/.out" && ok "$label check names the dangling depends_on" || bad "$label check doesn't name the dangling depends_on"

  echo "== $label: legacy table-format Roadmap.md migration (eval 20) =="
  proj7="$WORK/${label}_roadmapmigrate"
  mkdir -p "$proj7/docs"
  seed_legacy_roadmap "$proj7"
  assert_failure "$label check fails before Roadmap migrate" run check "$proj7"
  grep -q "migrate" "$WORK/.out" && ok "$label check message names migrate (Roadmap)" || bad "$label check message doesn't mention migrate (Roadmap)"
  assert_success "$label migrate converts legacy Roadmap.md" run migrate "$proj7"
  for id in SMOKE-LEG-T01 SMOKE-LEG-T02 SMOKE-LEG-F01 SMOKE-LEG-F01-E01 SMOKE-LEG-F01-E01-T01 SMOKE-LEG-GAP-01; do
    assert_contains "$label converted entry keeps id $id" "$proj7/docs/Roadmap.md" "id: $id"
  done
  assert_contains "$label converted GAP keeps severity" "$proj7/docs/Roadmap.md" "severity: high"
  assert_success "$label check passes after Roadmap migrate" run check "$proj7"
  hr1="$(file_hash "$proj7/docs/Roadmap.md")"
  assert_success "$label second Roadmap migrate" run migrate "$proj7"
  hr2="$(file_hash "$proj7/docs/Roadmap.md")"
  [ "$hr1" = "$hr2" ] && ok "$label second migrate leaves Roadmap.md unchanged" || bad "$label second migrate changed Roadmap.md"

  echo "== $label: pause OTRO =="
  proj8="$WORK/${label}_otro"
  mkdir -p "$proj8"
  run init "$proj8" >/dev/null 2>&1
  seed_entry "$proj8" SMOKE-OTRO-01 "Smoke otro task"
  run claim "$proj8" agentF SMOKE-OTRO-01 "start" >/dev/null 2>&1
  assert_success "$label pause OTRO" run pause "$proj8" agentF SMOKE-OTRO-01 OTRO "switching tasks"
  assert_contains "$label pause OTRO sets status READY" "$proj8/docs/Roadmap.md" "status: READY"
  assert_failure "$label different agent cannot reclaim OTRO" run claim "$proj8" agentG SMOKE-OTRO-01 "steal"
  assert_success "$label same agent reclaims after OTRO" run claim "$proj8" agentF SMOKE-OTRO-01 "resume"

  echo "== $label: claim rejects a DECISION entry =="
  proj9="$WORK/${label}_decision"
  mkdir -p "$proj9"
  run init "$proj9" >/dev/null 2>&1
  seed_decision "$proj9"
  assert_failure "$label claim on a DECISION fails" run claim "$proj9" agentH SMOKE-DEC-01 "try to work it"

  echo "== $label: a headless yaml block cannot corrupt neighbors (regression) =="
  proj10="$WORK/${label}_headless"
  mkdir -p "$proj10"
  run init "$proj10" >/dev/null 2>&1
  seed_task "$proj10"
  seed_headless_entry "$proj10" SMOKE-HEADLESS-01
  assert_success "$label done on a headless-but-idded entry succeeds" run done "$proj10" agentI SMOKE-HEADLESS-01 "closed" "n/a" "n/a"
  assert_contains "$label neighboring entry survives" "$proj10/docs/Roadmap.md" "id: SMOKE-T01"
  assert_contains "$label Cross-cutting heading survives" "$proj10/docs/Roadmap.md" "## Cross-cutting"
  seed_no_id_fence "$proj10"
  assert_failure "$label check flags a yaml block with no id field" run check "$proj10"
  grep -q "no top-level id: field" "$WORK/.out" && ok "$label check names the missing id field" || bad "$label check doesn't name the missing id field"
}

file_hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else cksum "$1"; fi
}

# Seeds insert a per-entry YAML block (the Roadmap's actual format, see
# references/roadmap-schema.md) right before "## Cross-cutting", not a table
# row — Roadmap.md has no table spine to seed into any more.
seed_entry() {
  proj="$1"; id="$2"; title="$3"
  file="$proj/docs/Roadmap.md"
  awk -v id="$id" -v title="$title" '
    /^## Cross-cutting/ && !done {
      print ""
      print "### " id " - " title
      print ""
      print "```yaml"
      print "id: " id
      print "type: TASK"
      print "title: " title
      print "status: READY"
      print "owner:"
      print "  type: HUMAN"
      print "  name: Cristian"
      print "acceptance_criteria:"
      print "  - id: AC-1"
      print "    description: works"
      print "    status: pending"
      print "```"
      print ""
      done = 1
    }
    { print }
  ' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

seed_task() { seed_entry "$1" SMOKE-T01 "Smoke task one"; }
seed_task2() { seed_entry "$1" SMOKE-T02 "Smoke task two"; }

# EPIC + one TASK child linked by `parent`, for the epic-rollup scenario.
seed_epic_and_task() {
  proj="$1"
  file="$proj/docs/Roadmap.md"
  awk '
    /^## Cross-cutting/ && !done {
      print ""
      print "### SMOKE-EPIC-01 - Smoke epic"
      print ""
      print "```yaml"
      print "id: SMOKE-EPIC-01"
      print "type: EPIC"
      print "title: Smoke epic"
      print "status: IN_PROGRESS"
      print "```"
      print ""
      print "### SMOKE-EPIC-T01 - Smoke epic task"
      print ""
      print "```yaml"
      print "id: SMOKE-EPIC-T01"
      print "type: TASK"
      print "title: Smoke epic task"
      print "status: READY"
      print "parent: SMOKE-EPIC-01"
      print "```"
      print ""
      done = 1
    }
    { print }
  ' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# One entry whose parent/depends_on name IDs that exist nowhere.
seed_dangling_ref() {
  proj="$1"
  file="$proj/docs/Roadmap.md"
  cat >> "$file" <<'EOF'

### SMOKE-BAD-01 - Dangling refs

```yaml
id: SMOKE-BAD-01
type: TASK
title: Dangling refs
status: BACKLOG
parent: SMOKE-NOPE-01
depends_on: [SMOKE-MISSING-01]
```
EOF
}

# A full legacy table-format Roadmap.md (Active work, Near term, Plan with
# Fase/Epic headings, Gaps and defects) for the migrate conversion test.
seed_legacy_roadmap() {
  proj="$1"
  cat > "$proj/docs/Roadmap.md" <<EOF
# Roadmap

## Active work

| ID | Outcome | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|
| SMOKE-LEG-T01 | Legacy task | works | TODO | - | - | - |

<!-- context:end -->

## Near term

| ID | Outcome | Acceptance check | Status | Depends on |
|---|---|---|---|---|
| SMOKE-LEG-T02 | Legacy near term task | works | TODO | - |

## Plan

### SMOKE-LEG-F01 — Legacy phase

#### SMOKE-LEG-F01-E01 — Legacy epic

| ID | Outcome | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|
| SMOKE-LEG-F01-E01-T01 | Legacy epic task | works | TODO | - | - | - |

## Gaps and defects

| ID | Severity | Phase | Description | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|---|
| SMOKE-LEG-GAP-01 | high | SMOKE-LEG-F01 | Legacy gap | TODO | - | - | - |
EOF
}

# A DECISION entry, for the "claim must reject DECISION" test.
seed_decision() {
  proj="$1"
  file="$proj/docs/Roadmap.md"
  awk '
    /^## Cross-cutting/ && !done {
      print ""
      print "### SMOKE-DEC-01 - Smoke decision"
      print ""
      print "```yaml"
      print "id: SMOKE-DEC-01"
      print "type: DECISION"
      print "title: Smoke decision"
      print "status: PENDING"
      print "decision_required: true"
      print "```"
      print ""
      done = 1
    }
    { print }
  ' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# A yaml block WITH a valid id but with NO preceding "### " heading,
# inserted right after "## Cross-cutting" — regression fixture for the bug
# where done's backward heading-search would otherwise walk past it into
# unrelated content. Addressable (has an id), unlike seed_no_id_fence below.
seed_headless_entry() {
  proj="$1"; id="$2"
  file="$proj/docs/Roadmap.md"
  awk -v id="$id" '
    /^## Cross-cutting/ && !done {
      print "```yaml"
      print "id: " id
      print "type: TASK"
      print "title: Headless"
      print "status: READY"
      print "```"
      print ""
      done = 1
    }
    { print }
  ' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# A yaml block with no id: field at all, for the "check flags a headless
# block" test — this one is never addressable by any command.
seed_no_id_fence() {
  proj="$1"
  file="$proj/docs/Roadmap.md"
  cat >> "$file" <<'EOF'

```yaml
type: TASK
title: No id field
status: READY
```
EOF
}

echo "### sh: $SH_BIN ###"
RUNNER="sh_runner"
sh_runner() { sh "$SH_BIN" "$@"; }
run_suite sh

PWSH=""
if command -v pwsh >/dev/null 2>&1; then PWSH="pwsh"
elif command -v powershell.exe >/dev/null 2>&1; then PWSH="powershell.exe"
fi

# A native Windows powershell.exe/pwsh cannot resolve a POSIX-style path
# (e.g. /c/Users/...) as produced by `pwd` under git-bash/MSYS; convert to a
# Windows path first when a converter is available.
to_native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

if [ -n "$PWSH" ]; then
  PS1_BIN_NATIVE="$(to_native_path "$PS1_BIN")"
  echo "### ps1 ($PWSH): $PS1_BIN_NATIVE ###"
  RUNNER="ps1_runner"
  ps1_runner() {
    cmd="$1"; proj="$2"; shift 2
    proj_native="$(to_native_path "$proj")"
    ps_cmd="& '$PS1_BIN_NATIVE' '$cmd' '$proj_native'"
    for a in "$@"; do
      esc="$(printf '%s' "$a" | sed "s/'/''/g")"
      ps_cmd="$ps_cmd '$esc'"
    done
    "$PWSH" -NoProfile -NonInteractive -Command "$ps_cmd"
  }
  run_suite ps1
else
  echo "### ps1: skipped (no pwsh or powershell.exe on PATH) ###"
fi

echo
echo "----- Known Windows limitation -----"
echo "Eval 14 (AGENTS.md/Agents.md case-variant coexistence) requires a"
echo "case-sensitive filesystem and cannot run here; check's detection logic"
echo "is exercised via list_case_variants/Get-CaseVariants directly instead"
echo "of an end-to-end case-collision reproduction."

echo
echo "===== smoke test: $PASS passed, $FAIL failed ====="
[ "$FAIL" -eq 0 ]
