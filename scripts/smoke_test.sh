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
  seed_active_row "$proj" SMOKE-T01 "Smoke task one"
  assert_success "$label claim by agentA" run claim "$proj" agentA SMOKE-T01 "start"
  assert_contains "$label claim sets owner" "$proj/docs/Roadmap.md" "agentA@"
  assert_failure "$label second claim by agentB fails" run claim "$proj" agentB SMOKE-T01 "steal"
  assert_success "$label pause LIMITE" run pause "$proj" agentA SMOKE-T01 LIMITE "context limit"
  assert_success "$label reclaim after LIMITE" run claim "$proj" agentB SMOKE-T01 "resume"
  assert_success "$label pause ESPERA_RESPUESTA" run pause "$proj" agentB SMOKE-T01 ESPERA_RESPUESTA "waiting on user"
  assert_failure "$label claim during ESPERA_RESPUESTA fails" run claim "$proj" agentC SMOKE-T01 "steal again"
  assert_success "$label owner reclaims after ESPERA_RESPUESTA" run claim "$proj" agentB SMOKE-T01 "resume again"
  assert_success "$label done requires non-empty verify" run done "$proj" agentB SMOKE-T01 "implemented" "src/x" "tests pass"
  assert_contains "$label Features.md records capability" "$proj/docs/Features.md" "SMOKE-T01"

  echo "== $label: claim moves a Plan-section row into Active work =="
  seed_plan_row "$proj" SMOKE-PLAN-01 "Smoke plan task"
  assert_success "$label claim on a Plan row" run claim "$proj" agentJ SMOKE-PLAN-01 "start"
  awk '/^## Active work/{a=1;next} /^## Near term/{a=0} a' "$proj/docs/Roadmap.md" > "$WORK/.active"
  grep -q "SMOKE-PLAN-01" "$WORK/.active" && ok "$label claimed row now under Active work" || bad "$label claimed row missing from Active work"
  awk '/^## Plan/{a=1;next} /^## Gaps/{a=0} a' "$proj/docs/Roadmap.md" > "$WORK/.plan"
  grep -q "SMOKE-PLAN-01" "$WORK/.plan" && bad "$label claimed row still duplicated under Plan" || ok "$label claimed row removed from Plan"
  # Markdown rendering: the moved row must sit inside the Active work table
  # (directly under another table line), not detached below a blank line, and
  # the empty-table placeholder row must be gone.
  awk '/SMOKE-PLAN-01/ { if (prev ~ /^\|/) print "attached"; exit } { prev=$0 }' "$WORK/.active" | grep -q attached \
    && ok "$label claimed row is attached to the Active work table" \
    || bad "$label claimed row is detached from the Active work table (blank line above it)"
  grep -q '^| — |' "$WORK/.active" && bad "$label Active work placeholder row left behind" || ok "$label Active work placeholder row removed"
  assert_success "$label done closes the moved row" run done "$proj" agentJ SMOKE-PLAN-01 "implemented" "n/a" "verified"

  echo "== $label: done rejects empty verify / check flags bad log state (eval 11) =="
  seed_active_row "$proj" SMOKE-T02 "Smoke task two"
  assert_failure "$label done with empty verify is rejected" run done "$proj" agentA SMOKE-T02 "x" "y" ""
  assert_success "$label append-log with bad status" run append-log "$proj" agentA SMOKE-T02 BOGUS "bad" "-" pending
  assert_failure "$label check fails on invalid status" run check "$proj"

  echo "== $label: rotation carries an open task forward (evals 9-10) =="
  proj2="$WORK/${label}_rotate"
  mkdir -p "$proj2"
  run init "$proj2" >/dev/null 2>&1
  seed_active_row "$proj2" SMOKE-T01 "Smoke task one"
  run done "$proj2" seed SMOKE-T01 "seed close" "n/a" "n/a" >/dev/null 2>&1
  seed_active_row "$proj2" SMOKE-T02 "Smoke task two"
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

  echo "== $label: epic rollup via ID prefix (eval 21) =="
  proj5="$WORK/${label}_epic"
  mkdir -p "$proj5"
  run init "$proj5" >/dev/null 2>&1
  seed_epic_and_task "$proj5"
  assert_success "$label claim epic child task" run claim "$proj5" agentE F90-E01-T01 "start"
  assert_success "$label done epic child task" run done "$proj5" agentE F90-E01-T01 "implemented" "n/a" "verified"
  assert_contains "$label Features.md has epic rollup row" "$proj5/docs/Features.md" "F90-E01"
  assert_not_exists_pattern "$label epic task row removed from Roadmap.md" "$proj5/docs/Roadmap.md" "F90-E01-T01"
  assert_success "$label check passes after epic rollup" run check "$proj5"

  echo "== $label: pause OTRO =="
  proj8="$WORK/${label}_otro"
  mkdir -p "$proj8"
  run init "$proj8" >/dev/null 2>&1
  seed_active_row "$proj8" SMOKE-OTRO-01 "Smoke otro task"
  run claim "$proj8" agentF SMOKE-OTRO-01 "start" >/dev/null 2>&1
  assert_success "$label pause OTRO" run pause "$proj8" agentF SMOKE-OTRO-01 OTRO "switching tasks"
  assert_contains "$label pause OTRO sets Pause reason cell" "$proj8/docs/Roadmap.md" "| OTRO |"
  assert_failure "$label different agent cannot reclaim OTRO" run claim "$proj8" agentG SMOKE-OTRO-01 "steal"
  assert_success "$label same agent reclaims after OTRO" run claim "$proj8" agentF SMOKE-OTRO-01 "resume"

  echo "== $label: migrate converts a legacy per-entry YAML Roadmap.md (Markdown hardening) =="
  proj7="$WORK/${label}_yamlmigrate"
  mkdir -p "$proj7/docs"
  run init "$proj7" >/dev/null 2>&1
  seed_yaml_roadmap "$proj7"
  assert_failure "$label check fails before YAML Roadmap migrate" run check "$proj7"
  grep -q "migrate" "$WORK/.out" && ok "$label check message names migrate (YAML Roadmap)" || bad "$label check message doesn't mention migrate (YAML Roadmap)"
  assert_success "$label migrate converts YAML Roadmap.md to tables" run migrate "$proj7"
  for id in SMOKE-YAML-F01 SMOKE-YAML-F01-E01 SMOKE-YAML-F01-E01-T01 SMOKE-YAML-F01-E01-T02 SMOKE-YAML-GAP-01; do
    assert_contains "$label converted row keeps id $id" "$proj7/docs/Roadmap.md" "$id"
  done
  awk '/^## Active work/{a=1;next} /^## Near term/{a=0} a' "$proj7/docs/Roadmap.md" > "$WORK/.active"
  grep -q "SMOKE-YAML-F01-E01-T01" "$WORK/.active" && ok "$label IN_PROGRESS entry routed to Active work" || bad "$label IN_PROGRESS entry not routed to Active work"
  assert_contains "$label orphaned entry kept under F00-ORPHANED" "$proj7/docs/Roadmap.md" "F00-ORPHANED"
  assert_contains "$label converted GAP keeps severity" "$proj7/docs/Roadmap.md" "| high |"
  assert_success "$label check passes after YAML Roadmap migrate" run check "$proj7"
  hr1="$(file_hash "$proj7/docs/Roadmap.md")"
  assert_success "$label second YAML migrate is a no-op" run migrate "$proj7"
  hr2="$(file_hash "$proj7/docs/Roadmap.md")"
  [ "$hr1" = "$hr2" ] && ok "$label second migrate leaves Roadmap.md unchanged" || bad "$label second migrate changed Roadmap.md"

  echo "== $label: check hardening -- canonical IDs and epistemic/workflow Status =="
  proj9="$WORK/${label}_hardening"
  mkdir -p "$proj9"
  run init "$proj9" >/dev/null 2>&1
  assert_success "$label fresh scaffold passes check" run check "$proj9"

  proj9br="$WORK/${label}_bad_br"
  mkdir -p "$proj9br"
  run init "$proj9br" >/dev/null 2>&1
  seed_replace "$proj9br/docs/ProductDescription.md" "| BR-001 |" "| RULE-1 |"
  assert_failure "$label check rejects a non-BR-xxx business rule ID" run check "$proj9br"
  grep -q "invalid ID format: RULE-1" "$WORK/.out" && ok "$label check names the bad Business rules ID" || bad "$label check doesn't name the bad Business rules ID"

  proj9adr="$WORK/${label}_bad_adr"
  mkdir -p "$proj9adr"
  run init "$proj9adr" >/dev/null 2>&1
  seed_replace "$proj9adr/docs/Stack_Tecnologies.md" "| ADR-001 |" "| DECISION-1 |"
  assert_failure "$label check rejects a non-ADR-xxx decision ID" run check "$proj9adr"
  grep -q "invalid ID format: DECISION-1" "$WORK/.out" && ok "$label check names the bad ADR ID" || bad "$label check doesn't name the bad ADR ID"

  proj9plan="$WORK/${label}_bad_plan_id"
  mkdir -p "$proj9plan"
  run init "$proj9plan" >/dev/null 2>&1
  seed_replace "$proj9plan/docs/Roadmap.md" "| F01-E01-T01 |" "| TASK-01 |"
  assert_failure "$label check rejects a Plan row not shaped Fnn..." run check "$proj9plan"
  grep -q "invalid ID format: TASK-01" "$WORK/.out" && ok "$label check names the bad Plan row ID" || bad "$label check doesn't name the bad Plan row ID"

  proj9epi="$WORK/${label}_bad_epistemic"
  mkdir -p "$proj9epi"
  run init "$proj9epi" >/dev/null 2>&1
  seed_replace "$proj9epi/docs/ProductDescription.md" "| BR-001 | UNKNOWN | UNKNOWN | UNKNOWN |" "| BR-001 | UNKNOWN | N/A | UNKNOWN |"
  assert_failure "$label check rejects a non-epistemic Status value" run check "$proj9epi"
  grep -q "invalid epistemic Status: N/A" "$WORK/.out" && ok "$label check names the bad epistemic Status" || bad "$label check doesn't name the bad epistemic Status"

  proj9wf="$WORK/${label}_bad_workflow"
  mkdir -p "$proj9wf"
  run init "$proj9wf" >/dev/null 2>&1
  seed_replace "$proj9wf/docs/Roadmap.md" "| F01-E01-T01 | UNKNOWN | UNKNOWN | UNKNOWN | TODO |" "| F01-E01-T01 | UNKNOWN | UNKNOWN | UNKNOWN | CONFIRMED |"
  assert_failure "$label check rejects a non-workflow Roadmap Status value" run check "$proj9wf"
  grep -q "invalid workflow Status: CONFIRMED" "$WORK/.out" && ok "$label check names the bad workflow Status" || bad "$label check doesn't name the bad workflow Status"

  proj9ctx="$WORK/${label}_no_context_end"
  mkdir -p "$proj9ctx"
  run init "$proj9ctx" >/dev/null 2>&1
  seed_replace "$proj9ctx/docs/ProductDescription.md" "<!-- context:end -->" ""
  assert_failure "$label check rejects a missing context:end delimiter" run check "$proj9ctx"
  grep -q "missing '<!-- context:end -->'" "$WORK/.out" && ok "$label check names the missing context:end delimiter" || bad "$label check doesn't name the missing context:end delimiter"

  proj9scope="$WORK/${label}_no_out_of_scope"
  mkdir -p "$proj9scope"
  run init "$proj9scope" >/dev/null 2>&1
  seed_replace "$proj9scope/docs/Roadmap.md" "## Out of scope" "## Not Out of Scope"
  assert_failure "$label check rejects a missing Out of scope section" run check "$proj9scope"
  grep -q "missing '## Out of scope'" "$WORK/.out" && ok "$label check names the missing Out of scope section" || bad "$label check doesn't name the missing Out of scope section"

  echo "== $label: Name <= 10 words, obligue: claim/pause/done refuse a bad Name =="
  proj10="$WORK/${label}_name"
  mkdir -p "$proj10"
  run init "$proj10" >/dev/null 2>&1
  seed_replace "$proj10/docs/Roadmap.md" "| F01-E01-T01 | UNKNOWN | UNKNOWN | UNKNOWN | TODO |" \
    "| F01-E01-T01 | This Name has way too many words to pass the ten word limit rule | detail | real accept | TODO |"
  assert_failure "$label claim refuses a Name over 10 words" run claim "$proj10" agentN F01-E01-T01 "start"
  grep -q "over the 10-word limit" "$WORK/.out" && ok "$label claim error names the 10-word limit" || bad "$label claim error doesn't mention the 10-word limit"
  seed_replace "$proj10/docs/Roadmap.md" \
    "| F01-E01-T01 | This Name has way too many words to pass the ten word limit rule | detail | real accept | TODO |" \
    "| F01-E01-T01 | Build the demo onboarding flow | detail | real accept | TODO |"
  assert_success "$label claim succeeds with a short Name" run claim "$proj10" agentN F01-E01-T01 "start"
  assert_contains "$label Agentslog entry carries the Roadmap Name verbatim" "$proj10/docs/Agentslog.md" "IN_PROGRESS | Build the demo onboarding flow"
  assert_success "$label done succeeds and logs the same Name" run done "$proj10" agentN F01-E01-T01 "implemented" "x" "verified"
  assert_contains "$label done entry also carries the Name" "$proj10/docs/Agentslog.md" "DONE | Build the demo onboarding flow"
  assert_success "$label check passes after a clean Name lifecycle" run check "$proj10"

  echo "== $label: Agentslog Name must match the Roadmap Name (obligue) =="
  proj11="$WORK/${label}_namedrift"
  mkdir -p "$proj11"
  run init "$proj11" >/dev/null 2>&1
  seed_replace "$proj11/docs/Roadmap.md" "| F01-E01-T01 | UNKNOWN | UNKNOWN | UNKNOWN | TODO |" \
    "| F01-E01-T01 | Build the demo onboarding flow | detail | real accept | TODO |"
  run claim "$proj11" agentN F01-E01-T01 "start" >/dev/null 2>&1
  seed_replace "$proj11/docs/Roadmap.md" "| F01-E01-T01 | Build the demo onboarding flow | detail | real accept | IN_PROGRESS" \
    "| F01-E01-T01 | A totally different name now | detail | real accept | IN_PROGRESS"
  assert_failure "$label check rejects a Roadmap Name that drifted from the log" run check "$proj11"
  grep -q "does not match docs/Roadmap.md Name" "$WORK/.out" && ok "$label check names the Agentslog/Roadmap Name mismatch" || bad "$label check doesn't name the Agentslog/Roadmap Name mismatch"

  echo "== $label: check rejects a table with no Name column and an empty Name =="
  proj12="$WORK/${label}_noname"
  mkdir -p "$proj12"
  run init "$proj12" >/dev/null 2>&1
  seed_replace "$proj12/docs/Roadmap.md" \
    "| ID | Name | Description | Acceptance check | Status | Owner | Depends on | Pause reason |" \
    "| ID | Outcome | Description | Acceptance check | Status | Owner | Depends on | Pause reason |"
  assert_failure "$label check rejects a Roadmap table with no Name column" run check "$proj12"
  grep -q "has no Name column" "$WORK/.out" && ok "$label check names the missing Name column" || bad "$label check doesn't name the missing Name column"

  proj13="$WORK/${label}_emptyname"
  mkdir -p "$proj13"
  run init "$proj13" >/dev/null 2>&1
  seed_replace "$proj13/docs/Roadmap.md" "| F01-E01-T01 | UNKNOWN | UNKNOWN | UNKNOWN | TODO |" \
    "| F01-E01-T01 |  | UNKNOWN | UNKNOWN | TODO |"
  assert_failure "$label check rejects an empty Name" run check "$proj13"
  grep -q "has an empty Name" "$WORK/.out" && ok "$label check names the empty Name row" || bad "$label check doesn't name the empty Name row"

  echo "== $label: migrate retrofits a pre-Name-column Roadmap.md =="
  proj14="$WORK/${label}_prename"
  mkdir -p "$proj14/docs"
  run init "$proj14" >/dev/null 2>&1
  seed_pre_name_roadmap "$proj14"
  assert_failure "$label check fails before the Name-column migrate" run check "$proj14"
  grep -q "has no Name column" "$WORK/.out" && ok "$label check names the pre-Name table" || bad "$label check doesn't name the pre-Name table"
  assert_success "$label migrate adds the Name column" run migrate "$proj14"
  assert_contains "$label task Description keeps the full old Outcome text" "$proj14/docs/Roadmap.md" \
    "A fairly long legacy outcome sentence that definitely exceeds the ten word limit"
  assert_contains "$label Gaps Description is preserved verbatim" "$proj14/docs/Roadmap.md" \
    "A gap description that also runs quite long past the word limit here"
  assert_contains "$label Near term Outcome became Name verbatim" "$proj14/docs/Roadmap.md" "Short near term idea"
  assert_success "$label check passes after the Name-column migrate" run check "$proj14"
  hp1="$(file_hash "$proj14/docs/Roadmap.md")"
  assert_success "$label second Name-column migrate is a no-op" run migrate "$proj14"
  hp2="$(file_hash "$proj14/docs/Roadmap.md")"
  [ "$hp1" = "$hp2" ] && ok "$label second migrate leaves Roadmap.md unchanged" || bad "$label second migrate changed Roadmap.md"
  assert_success "$label claim works on a migrated Gaps row" run claim "$proj14" agentN F70-GAP-01 "start"
}

file_hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else cksum "$1"; fi
}

# Replaces the first occurrence of a literal string in a file (portable, no
# sed -i dependency across the shells this runs under). Uses index()/substr()
# rather than sub(), which treats its first argument as an ERE -- "old" here
# is routinely full of "|" (table cells), and "|" means alternation in a
# regex, not a literal pipe; sub() would then match a zero-width string at
# position 0 and just prepend "new" in front of the untouched line.
seed_replace() {
  file="$1"; old="$2"; new="$3"
  awk -v old="$old" -v new="$new" '
    !done {
      i = index($0, old)
      if (i > 0) { $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); done = 1 }
    }
    { print }
  ' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# Inserts a row directly into "## Active work" (right after its header
# separator), so claim/pause/done exercise the in-place edit path. $title is
# used as the row's Name (keep it <= 10 words; callers that need a longer
# Name build their own row).
seed_active_row() {
  proj="$1"; id="$2"; title="$3"
  file="$proj/docs/Roadmap.md"
  awk -v id="$id" -v title="$title" '
    /^## Active work/ { active = 1 }
    /^## Near term/ { active = 0 }
    active && /^\|---/ && !done { print; print "| " id " | " title " | details | works | TODO | — | — | — |"; done = 1; next }
    { print }
  ' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# Inserts a row into "## Plan" right after the template's own default
# F01-E01 epic table row, so claim exercises the Plan -> Active work move.
seed_plan_row() {
  proj="$1"; id="$2"; title="$3"
  file="$proj/docs/Roadmap.md"
  awk -v id="$id" -v title="$title" '
    { print }
    /^\| F01-E01-T01 \|/ && !done { print "| " id " | " title " | details | works | TODO | — | — | — |"; done = 1 }
  ' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# A PHASE heading + EPIC heading + one TASK row using the Fnn-Enn-Tnn
# convention, appended before "## Gaps, Bugs & Technical Debt", for the
# epic-rollup regression (rollup is inferred from the ID shape, not a
# stored field).
seed_epic_and_task() {
  proj="$1"
  file="$proj/docs/Roadmap.md"
  awk '
    /^## Gaps, Bugs & Technical Debt/ && !done {
      print "### F90 — Smoke phase"
      print ""
      print "#### F90-E01 — Smoke epic"
      print ""
      print "| ID | Name | Description | Acceptance check | Status | Owner | Depends on | Pause reason |"
      print "|---|---|---|---|---|---|---|---|"
      print "| F90-E01-T01 | Smoke epic task | details | works | TODO | — | — | — |"
      print ""
      done = 1
    }
    { print }
  ' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# A pre-Name-column Roadmap.md in the Markdown-hardened (table) shape this
# skill shipped before the Name/Description split, with a long Outcome and a
# long Gaps Description so the derived Name is a visibly truncated fragment
# -- exercises the Name-column retrofit migration end to end.
seed_pre_name_roadmap() {
  proj="$1"
  cat > "$proj/docs/Roadmap.md" <<'EOF'
# Roadmap

## Active work

| ID | Outcome | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|
| — | — | — | — | — | — | — |

<!-- context:end -->

## Near term

| ID | Outcome | Acceptance check | Status | Depends on |
|---|---|---|---|---|
| SMOKE-PRENAME-NT01 | Short near term idea | UNKNOWN | TODO | — |

## Plan

**Vision:** `UNKNOWN`

### F70 — Pre-name phase

#### F70-E01 — Pre-name epic

| ID | Outcome | Acceptance check | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|
| F70-E01-T01 | A fairly long legacy outcome sentence that definitely exceeds the ten word limit | Old accept | TODO | — | — | — |

## Gaps, Bugs & Technical Debt

| ID | Severity | Phase | Description | Status | Owner | Depends on | Pause reason |
|---|---|---|---|---|---|---|---|
| F70-GAP-01 | Low | F70 | A gap description that also runs quite long past the word limit here | TODO | — | — | — |

## Out of scope

- none
EOF
}

# A full per-entry YAML Roadmap.md (the short-lived schema this skill used
# before reverting to tables): a PHASE, an EPIC, an IN_PROGRESS TASK with a
# multi-line description and acceptance criteria, an orphaned TASK whose
# parent resolves nowhere, and a cross-cutting GAP. Exercises the YAML ->
# table migrate direction end to end.
seed_yaml_roadmap() {
  proj="$1"
  cat > "$proj/docs/Roadmap.md" <<'EOF'
# Roadmap

## Plan

### SMOKE-YAML-F01 — Smoke YAML phase

```yaml
id: SMOKE-YAML-F01
type: PHASE
title: Smoke YAML phase
status: BACKLOG
```

### SMOKE-YAML-F01-E01 — Smoke YAML epic

```yaml
id: SMOKE-YAML-F01-E01
type: EPIC
title: Smoke YAML epic
status: BACKLOG
parent: SMOKE-YAML-F01
```

### SMOKE-YAML-F01-E01-T01 — In-progress migrated task

```yaml
id: SMOKE-YAML-F01-E01-T01
type: TASK
title: In-progress migrated task
status: IN_PROGRESS
parent: SMOKE-YAML-F01-E01
assigned_agent: "migbot"
description: >
  A task that was mid-flight when the schema reverted.
acceptance_criteria:
  - id: AC-1
    description: passes the migrate regression test
    status: pending
```

### SMOKE-YAML-F01-E01-T02 — Orphaned task with bad parent

```yaml
id: SMOKE-YAML-F01-E01-T02
type: TASK
title: Orphaned task with bad parent
status: BACKLOG
parent: SMOKE-YAML-NOPE-01
```

## Cross-cutting

### SMOKE-YAML-GAP-01 — Migrated gap

```yaml
id: SMOKE-YAML-GAP-01
type: GAP
title: Migrated gap
status: BACKLOG
severity: high
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
