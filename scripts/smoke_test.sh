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
  # The cases below measure the classic (pre-factory) behavior. init now creates
  # a Factory project by default, so this suite pins the mode explicitly; the
  # factory behavior is covered by run_factory_suite.
  PROJECT_DOCS_MODE=classic; export PROJECT_DOCS_MODE

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
  # A task handed to review and already passed by another agent, so rotation has
  # to carry the holder, the handoff target and the review result forward.
  seed_active_row "$proj2" SMOKE-T03 "Smoke review task"
  run claim "$proj2" agentD SMOKE-T03 "reviewed across rotation" >/dev/null 2>&1
  seed_entry "$proj2" "$(now_ts)" agentD SMOKE-T03 REVIEW "Smoke review task" "- Summary: coded\n- Verify: unit tests pass\n- Handoff: qa-agent\n"
  seed_entry "$proj2" "$(now_ts)" qa-agent SMOKE-T03 REVIEW "Smoke review task" "- Summary: reviewed\n- Verify: reran tests\n- Review: PASS - fine\n"
  # A task assigned but not yet claimed: rotation must not drop the assignment.
  seed_active_row "$proj2" SMOKE-T04 "Smoke assigned task"
  run assign "$proj2" lead SMOKE-T04 agentZ >/dev/null 2>&1
  seed_fill "$proj2" SMOKE-T01 205
  assert_success "$label context stays open task visible" run context "$proj2"
  grep -q "SMOKE-T02" "$WORK/.out" && ok "$label Open tasks section lists SMOKE-T02" || bad "$label Open tasks section missing SMOKE-T02"
  grep -q "SMOKE-T03 | agentD | REVIEW(PASS)->qa-agent" "$WORK/.out" && ok "$label Open tasks lists the REVIEW task with its holder and stage" || bad "$label Open tasks missing the REVIEW task or its stage"
  grep -q "SMOKE-T04 | lead | ASSIGNED->agentZ" "$WORK/.out" && ok "$label Open tasks lists the ASSIGNED task and its assignee" || bad "$label Open tasks missing the ASSIGNED task"
  assert_success "$label rotate archives the ledger" run rotate "$proj2"
  assert_success "$label status still shows SMOKE-T02 after rotation" run status "$proj2"
  grep -q "SMOKE-T02" "$WORK/.out" && ok "$label status lists SMOKE-T02 after rotation" || bad "$label status missing SMOKE-T02 after rotation"
  # Regression (F05-BUG-01): status and rotate used to lose the Name because a
  # whitespace IFS merged the empty pausecat/conflict fields in the task-state TSV.
  grep -q "Smoke task two" "$WORK/.out" && ok "$label status prints the task Name after rotation" || bad "$label status lost the task Name after rotation"
  assert_contains "$label rotate carries the Name into the new ledger" "$proj2/docs/Agentslog.md" "| Smoke task two"
  grep -q "SMOKE-T03 | Smoke review task | agentD | REVIEW(PASS)->qa-agent" "$WORK/.out" && ok "$label status keeps the REVIEW task after rotation (holder, result, handoff)" || bad "$label status lost the REVIEW task after rotation: $(grep SMOKE-T03 "$WORK/.out")"
  assert_contains "$label rotate carries the Handoff line" "$proj2/docs/Agentslog.md" "- Handoff: qa-agent"
  grep -q "SMOKE-T04 | Smoke assigned task | lead | ASSIGNED->agentZ" "$WORK/.out" && ok "$label status keeps the ASSIGNED task after rotation" || bad "$label status lost the ASSIGNED task after rotation: $(grep SMOKE-T04 "$WORK/.out")"
  assert_contains "$label rotate carries the Assign line" "$proj2/docs/Agentslog.md" "- Assign: agentZ"
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

  echo "== $label: REVIEW stage in the ledger (Change 1) =="
  review_proj() {
    rp="$WORK/${label}_$1"
    mkdir -p "$rp"
    run init "$rp" >/dev/null 2>&1
    seed_replace "$rp/docs/Roadmap.md" "| F01-E01-T01 | UNKNOWN | UNKNOWN | UNKNOWN | TODO |" \
      "| F01-E01-T01 | Build the demo onboarding flow | detail | real accept | TODO |"
    run claim "$rp" dev F01-E01-T01 "start" >/dev/null 2>&1
  }
  n="Build the demo onboarding flow"
  review_proj rv_ok
  seed_entry "$rp" "$(now_ts)" dev F01-E01-T01 REVIEW "$n" "- Summary: coded\n- Verify: unit tests pass\n- Handoff: qa-agent\n"
  assert_success "$label check accepts a valid REVIEW entry" run check "$rp"
  assert_success "$label status lists the REVIEW task" run status "$rp"
  grep -q "dev | REVIEW->qa-agent" "$WORK/.out" && ok "$label status shows holder, stage and handoff target" || bad "$label status stage text wrong: $(cat "$WORK/.out")"
  assert_success "$label context renders" run context "$rp"
  grep -q "F01-E01-T01 | dev | REVIEW->qa-agent" "$WORK/.out" && ok "$label Open tasks shows the REVIEW stage and target" || bad "$label Open tasks stage text wrong"
  seed_entry "$rp" "$(now_ts)" qa-agent F01-E01-T01 REVIEW "$n" "- Summary: reviewed\n- Verify: reran tests\n- Review: PASS - fine\n"
  assert_success "$label two REVIEW entries by different agents are not a conflict" run check "$rp"
  assert_failure "$label a third agent cannot claim a task held in REVIEW" run claim "$rp" intruder F01-E01-T01 "steal"
  grep -q "REVIEW, held by dev" "$WORK/.out" && ok "$label claim error names the holder" || bad "$label claim error doesn't name the holder"
  assert_success "$label the holder can take a REVIEW task back" run claim "$rp" dev F01-E01-T01 "withdraw the handoff"

  review_proj rv_novfy
  seed_entry "$rp" "$(now_ts)" dev F01-E01-T01 REVIEW "$n" "- Summary: coded\n"
  assert_failure "$label REVIEW without Verify fails check" run check "$rp"
  grep -q "REVIEW entry missing Verify" "$WORK/.out" && ok "$label check names the missing REVIEW Verify" || bad "$label check doesn't name the missing REVIEW Verify"
  review_proj rv_pending
  seed_entry "$rp" "$(now_ts)" dev F01-E01-T01 REVIEW "$n" "- Summary: coded\n- Verify: pending\n"
  assert_failure "$label REVIEW with a pending Verify fails check" run check "$rp"
  review_proj rv_badres
  seed_entry "$rp" "$(now_ts)" qa F01-E01-T01 REVIEW "$n" "- Summary: x\n- Verify: ok\n- Review: MAYBE - hmm\n"
  assert_failure "$label Review result other than PASS/FAIL fails check" run check "$rp"
  review_proj rv_nodetail
  seed_entry "$rp" "$(now_ts)" qa F01-E01-T01 REVIEW "$n" "- Summary: x\n- Verify: ok\n- Review: PASS\n"
  assert_failure "$label Review without detail fails check" run check "$rp"
  review_proj rv_unknown
  seed_entry "$rp" "$(now_ts)" dev F01-E01-T01 BOGUS "$n" "- Summary: x\n- Verify: ok\n"
  assert_failure "$label an unknown ledger word is still rejected" run check "$rp"

  review_proj rv_fail
  seed_entry "$rp" "$(now_ts)" dev F01-E01-T01 REVIEW "$n" "- Summary: coded\n- Verify: tests pass\n- Handoff: qa-agent\n"
  seed_entry "$rp" "$(now_ts)" qa-agent F01-E01-T01 REVIEW "$n" "- Summary: broke it\n- Review: FAIL - two tests fail\n"
  assert_success "$label a Review: FAIL entry needs no Verify" run check "$rp"
  assert_success "$label status after FAIL" run status "$rp"
  grep -q "dev | IN_PROGRESS" "$WORK/.out" && ok "$label after FAIL the task is back with its holder (IN_PROGRESS)" || bad "$label after FAIL status is wrong: $(cat "$WORK/.out")"
  assert_failure "$label a third agent still cannot claim after FAIL" run claim "$rp" intruder F01-E01-T01 "steal"
  assert_success "$label the holder retakes the task after FAIL" run claim "$rp" dev F01-E01-T01 "fix the failing tests"

  echo "== $label: conflict rule and stale REVIEW =="
  review_proj rv_conflict
  seed_entry "$rp" "$(now_ts)" dev F01-E01-T01 REVIEW "$n" "- Summary: coded\n- Verify: ok\n"
  seed_entry "$rp" "$(now_ts)" intruder F01-E01-T01 IN_PROGRESS "$n" "- Summary: grabbed it\n- Verify: pending\n"
  assert_failure "$label a third agent starting work right after REVIEW is a conflict" run check "$rp"
  grep -q "conflicting concurrent claim" "$WORK/.out" && ok "$label check names the conflicting claim" || bad "$label check doesn't name the conflicting claim"
  review_proj rv_takeover
  seed_entry "$rp" "2026-10-01T10:00:00Z" dev F01-E01-T01 REVIEW "$n" "- Summary: coded\n- Verify: ok\n"
  seed_entry "$rp" "2026-10-05T10:00:00Z" intruder F01-E01-T01 IN_PROGRESS "$n" "- Summary: took over a stale review\n- Verify: pending\n"
  assert_success "$label taking over a REVIEW older than the stale threshold is not a conflict" run check "$rp"
  review_proj rv_stale
  seed_entry "$rp" "2026-10-01T10:00:00Z" dev F01-E01-T01 REVIEW "$n" "- Summary: coded\n- Verify: ok\n- Handoff: qa-agent\n"
  assert_success "$label check warns about a stale REVIEW without failing" run_env PROJECT_DOCS_STALE_HOURS=1 check "$rp"
  grep -q "has been in REVIEW for" "$WORK/.out" && ok "$label stale REVIEW warning text" || bad "$label stale REVIEW warning missing: $(cat "$WORK/.out")"
  assert_success "$label status marks a stale REVIEW" run_env PROJECT_DOCS_STALE_HOURS=1 status "$rp"
  grep -q "(stale)" "$WORK/.out" && ok "$label status shows (stale) on a REVIEW" || bad "$label status doesn't mark the stale REVIEW"

  echo "== $label: handoff command (Change 2) =="
  review_proj ho_ok
  owner_before="$(grep -o 'IN_PROGRESS | dev@[0-9TZ:-]*' "$rp/docs/Roadmap.md")"
  assert_failure "$label handoff by a non-holder fails" run handoff "$rp" other F01-E01-T01 "coded" "tests pass"
  grep -q "owned by dev, not other" "$WORK/.out" && ok "$label handoff error names the holder" || bad "$label handoff error doesn't name the holder"
  assert_failure "$label handoff with a pending verify fails" run handoff "$rp" dev F01-E01-T01 "coded" "pending"
  assert_failure "$label handoff with an empty verify fails" run handoff "$rp" dev F01-E01-T01 "coded" ""
  assert_failure "$label handoff with an empty summary fails" run handoff "$rp" dev F01-E01-T01 "" "tests pass"
  assert_failure "$label handoff on a task nobody claimed fails" run handoff "$rp" dev F01-E01-T09 "coded" "tests pass"
  assert_success "$label handoff by the holder succeeds" run handoff "$rp" dev F01-E01-T01 "code complete" "unit tests pass" qa-agent
  assert_contains "$label handoff writes a REVIEW entry carrying the Name" "$rp/docs/Agentslog.md" "| dev | F01-E01-T01 | REVIEW | Build the demo onboarding flow"
  assert_contains "$label handoff records the reviewer" "$rp/docs/Agentslog.md" "- Handoff: qa-agent"
  owner_after="$(grep -o 'IN_PROGRESS | dev@[0-9TZ:-]*' "$rp/docs/Roadmap.md")"
  [ -n "$owner_before" ] && [ "$owner_before" = "$owner_after" ] && ok "$label handoff leaves the Roadmap row IN_PROGRESS with the same Owner" || bad "$label handoff changed the Roadmap row: [$owner_before] -> [$owner_after]"
  assert_success "$label status shows the handed-off task" run status "$rp"
  grep -q "dev | REVIEW->qa-agent" "$WORK/.out" && ok "$label status shows the stage and target after handoff" || bad "$label status stage wrong after handoff: $(cat "$WORK/.out")"
  assert_success "$label context after handoff" run context "$rp"
  grep -q "F01-E01-T01 | dev | REVIEW->qa-agent" "$WORK/.out" && ok "$label Open tasks shows the handed-off task" || bad "$label Open tasks misses the handed-off task"
  assert_failure "$label a second handoff while in REVIEW fails" run handoff "$rp" dev F01-E01-T01 "again" "ok"
  assert_success "$label check passes after a handoff" run check "$rp"
  review_proj ho_noreviewer
  assert_success "$label handoff without a reviewer succeeds" run handoff "$rp" dev F01-E01-T01 "code complete" "unit tests pass"
  # Only the entries count: the ledger header documents the Handoff line in its
  # entry-format block.
  awk '/^## Entries/{p=1; next} p' "$rp/docs/Agentslog.md" > "$WORK/.entries"
  assert_not_exists_pattern "$label no Handoff line is written without a reviewer" "$WORK/.entries" "- Handoff:"
  assert_success "$label check passes after a handoff without a reviewer" run check "$rp"
  review_proj ho_paused
  run pause "$rp" dev F01-E01-T01 OTRO "switching" >/dev/null 2>&1
  assert_failure "$label handoff on a paused task fails" run handoff "$rp" dev F01-E01-T01 "code complete" "unit tests pass"

  echo "== $label: review command (Change 3) =="
  review_proj rvw_ok
  assert_failure "$label review without a pending handoff fails" run review "$rp" qa-agent F01-E01-T01 PASS "looks good" "reran the tests"
  grep -q "no pending handoff" "$WORK/.out" && ok "$label review error says there is no pending handoff" || bad "$label review error wrong: $(cat "$WORK/.out")"
  run handoff "$rp" dev F01-E01-T01 "code complete" "unit tests pass" qa-agent >/dev/null 2>&1
  assert_failure "$label review with a result other than PASS or FAIL fails" run review "$rp" qa-agent F01-E01-T01 MAYBE "hmm" "x"
  assert_failure "$label review with an empty note fails" run review "$rp" qa-agent F01-E01-T01 PASS "" "reran the tests"
  assert_failure "$label review PASS without a verify fails" run review "$rp" qa-agent F01-E01-T01 PASS "looks good"
  assert_failure "$label review PASS with a pending verify fails" run review "$rp" qa-agent F01-E01-T01 PASS "looks good" "pending"
  assert_success "$label review PASS by another agent succeeds" run review "$rp" qa-agent F01-E01-T01 PASS "looks good" "reran the tests"
  assert_contains "$label review writes a REVIEW entry in the reviewer name" "$rp/docs/Agentslog.md" "| qa-agent | F01-E01-T01 | REVIEW | Build the demo onboarding flow"
  assert_contains "$label review records the result and note" "$rp/docs/Agentslog.md" "- Review: PASS - looks good"
  assert_success "$label check passes after a review PASS" run check "$rp"
  assert_success "$label status after review PASS" run status "$rp"
  grep -q "dev | REVIEW(PASS)->qa-agent" "$WORK/.out" && ok "$label status shows REVIEW(PASS) for the holder" || bad "$label status after PASS wrong: $(cat "$WORK/.out")"
  assert_failure "$label a second review of an already reviewed handoff fails" run review "$rp" qa-agent F01-E01-T01 PASS "again" "x"
  assert_contains "$label the Roadmap row is untouched by review" "$rp/docs/Roadmap.md" "| IN_PROGRESS | dev@"

  review_proj rvw_fail
  run handoff "$rp" dev F01-E01-T01 "code complete" "unit tests pass" qa-agent >/dev/null 2>&1
  assert_success "$label review FAIL needs no verify" run review "$rp" qa-agent F01-E01-T01 FAIL "two tests fail"
  assert_contains "$label review FAIL is recorded" "$rp/docs/Agentslog.md" "- Review: FAIL - two tests fail"
  assert_success "$label check passes after a review FAIL" run check "$rp"
  assert_success "$label status after review FAIL" run status "$rp"
  grep -q "dev | IN_PROGRESS" "$WORK/.out" && ok "$label after FAIL the task is back with its holder" || bad "$label status after FAIL wrong: $(cat "$WORK/.out")"
  assert_failure "$label a third agent cannot claim after FAIL" run claim "$rp" intruder F01-E01-T01 "steal"
  assert_success "$label the holder retakes the task after FAIL with claim" run claim "$rp" dev F01-E01-T01 "fix the failing tests"
  assert_success "$label the holder can hand off again after retaking" run handoff "$rp" dev F01-E01-T01 "fixed" "unit tests pass" qa-agent

  review_proj rvw_self
  run handoff "$rp" dev F01-E01-T01 "code complete" "unit tests pass" >/dev/null 2>&1
  assert_success "$label self-review warns by default and does not fail" run review "$rp" dev F01-E01-T01 PASS "my own work is fine" "unit tests pass"
  grep -q "self-review" "$WORK/.out" && ok "$label self-review prints the warning" || bad "$label self-review warning missing: $(cat "$WORK/.out")"
  review_proj rvw_self_strict
  run handoff "$rp" dev F01-E01-T01 "code complete" "unit tests pass" >/dev/null 2>&1
  assert_failure "$label self-review fails with PROJECT_DOCS_REQUIRE_INDEPENDENT_REVIEW=1" run_env PROJECT_DOCS_REQUIRE_INDEPENDENT_REVIEW=1 review "$rp" dev F01-E01-T01 PASS "my own work is fine" "unit tests pass"
  grep -q "independent review is required" "$WORK/.out" && ok "$label strict self-review error text" || bad "$label strict self-review error wrong: $(cat "$WORK/.out")"
  assert_success "$label another agent still reviews under the strict setting" run_env PROJECT_DOCS_REQUIRE_INDEPENDENT_REVIEW=1 review "$rp" qa-agent F01-E01-T01 PASS "fine" "reran the tests"

  echo "== $label: done checks who closes the task (Change 4) =="
  review_proj dn_holder
  assert_failure "$label done by a third agent fails" run done "$rp" intruder F01-E01-T01 "implemented" "x" "tests pass"
  grep -q "done failed: F01-E01-T01 is held by dev" "$WORK/.out" && ok "$label done error names the holder" || bad "$label done error wrong: $(cat "$WORK/.out")"
  assert_contains "$label a refused done leaves the Roadmap row in place" "$rp/docs/Roadmap.md" "F01-E01-T01"
  assert_success "$label done by the holder succeeds without any handoff" run done "$rp" dev F01-E01-T01 "implemented" "x" "tests pass"

  review_proj dn_reviewer
  run handoff "$rp" dev F01-E01-T01 "code complete" "tests pass" qa-agent >/dev/null 2>&1
  run review "$rp" qa-agent F01-E01-T01 PASS "fine" "reran the tests" >/dev/null 2>&1
  assert_failure "$label done by a third agent fails after a review PASS" run done "$rp" intruder F01-E01-T01 "implemented" "x" "tests pass"
  assert_success "$label done by the reviewer who passed it succeeds" run done "$rp" qa-agent F01-E01-T01 "implemented" "x" "tests pass and reviewed"

  review_proj dn_holder_pass
  run handoff "$rp" dev F01-E01-T01 "code complete" "tests pass" qa-agent >/dev/null 2>&1
  run review "$rp" qa-agent F01-E01-T01 PASS "fine" "reran the tests" >/dev/null 2>&1
  assert_success "$label done by the holder after a review PASS succeeds" run done "$rp" dev F01-E01-T01 "implemented" "x" "tests pass and reviewed"
  grep -q "closing without a passing review" "$WORK/.out" && bad "$label done after a passing review should not warn" || ok "$label done after a passing review does not warn"

  review_proj dn_after_fail
  run handoff "$rp" dev F01-E01-T01 "code complete" "tests pass" qa-agent >/dev/null 2>&1
  run review "$rp" qa-agent F01-E01-T01 FAIL "two tests fail" >/dev/null 2>&1
  assert_failure "$label the reviewer cannot close a task they failed" run done "$rp" qa-agent F01-E01-T01 "implemented" "x" "tests pass"
  assert_success "$label the holder may still close after a FAIL, with a warning" run done "$rp" dev F01-E01-T01 "implemented" "x" "tests pass"
  grep -q "closing without a passing review (the last review was FAIL)" "$WORK/.out" && ok "$label done after FAIL warns" || bad "$label done after FAIL missing warning: $(cat "$WORK/.out")"

  review_proj dn_pending
  run handoff "$rp" dev F01-E01-T01 "code complete" "tests pass" qa-agent >/dev/null 2>&1
  assert_success "$label the holder may close with the handoff still pending" run done "$rp" dev F01-E01-T01 "implemented" "x" "tests pass"
  grep -q "closing without a passing review (the handoff is still pending)" "$WORK/.out" && ok "$label done with a pending handoff warns" || bad "$label done with a pending handoff missing warning: $(cat "$WORK/.out")"

  review_proj dn_force
  assert_success "$label PROJECT_DOCS_FORCE=1 lets any agent close" run_env PROJECT_DOCS_FORCE=1 done "$rp" intruder F01-E01-T01 "implemented" "x" "tests pass"
  review_proj dn_stale
  assert_success "$label anyone may close once the last entry is stale" run_env PROJECT_DOCS_STALE_HOURS=0 done "$rp" intruder F01-E01-T01 "implemented" "x" "tests pass"

  review_proj dn_retro
  seed_active_row "$rp" SMOKE-NEVER "Smoke never claimed"
  assert_success "$label closing a never-claimed task still works (retroactive close)" run done "$rp" anyone SMOKE-NEVER "implemented" "x" "tests pass"
  grep -q "WARN" "$WORK/.out" && bad "$label a retroactive close should not warn: $(cat "$WORK/.out")" || ok "$label a retroactive close does not warn"
  assert_success "$label check passes after a retroactive close" run check "$rp"

  mi=0
  for marker in none "N/A" "no run" ninguno UNKNOWN; do
    mi=$((mi + 1))
    review_proj dn_marker$mi
    assert_success "$label done with verify '$marker' succeeds" run done "$rp" dev F01-E01-T01 "implemented" "x" "$marker"
    grep -q "says nothing about what was checked" "$WORK/.out" && ok "$label verify '$marker' warns" || bad "$label verify '$marker' did not warn: $(cat "$WORK/.out")"
  done
  if [ "$label" = "sh" ]; then
    # The em dash cannot travel through the PowerShell command line unmangled,
    # so only the sh launcher exercises this literal.
    review_proj dn_marker_dash
    assert_success "$label done with an em dash verify succeeds" run done "$rp" dev F01-E01-T01 "implemented" "x" "—"
    grep -q "says nothing about what was checked" "$WORK/.out" && ok "$label an em dash verify warns" || bad "$label an em dash verify did not warn"
  fi
  review_proj dn_real_verify
  assert_success "$label a real verify does not warn" run done "$rp" dev F01-E01-T01 "implemented" "x" "sh scripts/smoke_test.sh passed"
  grep -q "says nothing about what was checked" "$WORK/.out" && bad "$label a real verify warned" || ok "$label a real verify does not warn"

  echo "== $label: agent identity roster (Change 5) =="
  roster_rows='| claude-sonnet-5-5 | AI | Claude Sonnet 5.5 | BOTH | claude, claude-sonnet-5 |\n| qa-bot | AI | QA bot | QA | — |\n| dev-bot | AI | Dev bot | DEVELOPER | — |'
  roster_proj() {
    rp="$WORK/${label}_$1"
    mkdir -p "$rp"
    run init "$rp" >/dev/null 2>&1
    seed_replace "$rp/docs/Roadmap.md" "| F01-E01-T01 | UNKNOWN | UNKNOWN | UNKNOWN | TODO |" \
      "| F01-E01-T01 | Build the demo onboarding flow | detail | real accept | TODO |"
    seed_replace "$rp/AGENTS.md" "| — | — | — | — | — |" "$roster_rows"
  }

  # Without a roster nothing changes.
  review_proj id_none
  assert_success "$label a new project ships the Agent identity section" grep -q "## Agent identity" "$rp/AGENTS.md"
  assert_failure "$label without a roster names are compared exactly (Dev is not dev)" run pause "$rp" Dev F01-E01-T01 OTRO "switching"
  seed_active_row "$rp" ID-T02 "Identity task two"
  assert_success "$label without a roster any name is accepted silently" run claim "$rp" stranger ID-T02 "start"
  grep -q "WARN" "$WORK/.out" && bad "$label an empty roster must not warn: $(cat "$WORK/.out")" || ok "$label an empty roster does not warn"
  assert_success "$label check passes without a roster" run check "$rp"
  grep -q "unknown agent" "$WORK/.out" && bad "$label check warned about agents without a roster" || ok "$label check does not warn about agents without a roster"

  old="$WORK/${label}_id_old"
  mkdir -p "$old"
  printf '<!-- project-documentation:start -->\n## Repository rules\n- old rules\n## Startup\n## Close\n<!-- project-documentation:end -->\n' > "$old/AGENTS.md"
  assert_success "$label init on a project that has the old block" run init "$old"
  grep -q "Agent identity" "$old/AGENTS.md" && bad "$label init must not add the roster to an existing block" || ok "$label init leaves an existing AGENTS.md block alone"
  assert_success "$label check does not require the roster section" run check "$old"

  # With a roster.
  roster_proj id_roster
  assert_success "$label claim by an alias is normalised" run claim "$rp" Claude F01-E01-T01 "start"
  assert_contains "$label the ledger header carries the Agent id" "$rp/docs/Agentslog.md" "| claude-sonnet-5-5 | F01-E01-T01 | IN_PROGRESS"
  assert_contains "$label the Roadmap Owner carries the Agent id" "$rp/docs/Roadmap.md" "claude-sonnet-5-5@"
  assert_success "$label another alias of the same agent can pause" run pause "$rp" claude-sonnet-5 F01-E01-T01 OTRO "switching"
  seed_active_row "$rp" ID-T02 "Identity task two"
  assert_success "$label an unknown agent still works but warns" run claim "$rp" stranger ID-T02 "start"
  grep -q 'unknown agent "stranger"' "$WORK/.out" && ok "$label the unknown agent warning names it" || bad "$label unknown agent warning missing: $(cat "$WORK/.out")"
  assert_contains "$label an unknown name is used as typed" "$rp/docs/Agentslog.md" "| stranger | ID-T02 | IN_PROGRESS"
  assert_success "$label check lists unknown ledger agents without failing" run check "$rp"
  grep -q 'unknown agent "stranger" in the ledger' "$WORK/.out" && ok "$label check names the unknown ledger agent" || bad "$label check unknown agent warning missing: $(cat "$WORK/.out")"
  grep -q 'unknown agent "claude' "$WORK/.out" && bad "$label check wrongly reported a known agent" || ok "$label check does not report known agents or aliases"

  roster_proj id_role
  run claim "$rp" claude-sonnet-5-5 F01-E01-T01 "start" >/dev/null 2>&1
  run handoff "$rp" claude-sonnet-5-5 F01-E01-T01 "code complete" "unit tests pass" >/dev/null 2>&1
  assert_success "$label a DEVELOPER may review but warns" run review "$rp" dev-bot F01-E01-T01 FAIL "not my area"
  grep -q "role DEVELOPER" "$WORK/.out" && ok "$label review by a DEVELOPER warns" || bad "$label DEVELOPER review warning missing: $(cat "$WORK/.out")"
  run claim "$rp" claude-sonnet-5-5 F01-E01-T01 "retake" >/dev/null 2>&1
  run handoff "$rp" claude-sonnet-5-5 F01-E01-T01 "fixed" "unit tests pass" >/dev/null 2>&1
  assert_success "$label a QA agent reviews without a role warning" run review "$rp" qa-bot F01-E01-T01 PASS "fine" "reran the tests"
  grep -q "role DEVELOPER" "$WORK/.out" && bad "$label a QA reviewer must not trigger the role warning" || ok "$label a QA reviewer triggers no role warning"

  echo "== $label: work documented after it is done (Change 6) =="
  review_proj ic_done
  assert_success "$label done right after claim succeeds" run done "$rp" dev F01-E01-T01 "implemented" "x" "tests pass"
  grep -q "F01-E01-T01 was claimed and closed" "$WORK/.out" && ok "$label done right after claim warns" || bad "$label instant-close warning missing: $(cat "$WORK/.out")"
  grep -q "claim before the first edit" "$WORK/.out" && ok "$label the warning says what to do" || bad "$label the warning does not say what to do"
  review_proj ic_silenced
  assert_success "$label PROJECT_DOCS_MIN_WORK_MINUTES=0 silences it" run_env PROJECT_DOCS_MIN_WORK_MINUTES=0 done "$rp" dev F01-E01-T01 "implemented" "x" "tests pass"
  grep -q "claimed and closed" "$WORK/.out" && bad "$label a zero threshold still warned" || ok "$label a zero threshold does not warn"
  review_proj ic_slow
  seed_active_row "$rp" SMOKE-SLOW "Smoke slow task"
  seed_entry "$rp" "2026-10-01T10:00:00Z" dev SMOKE-SLOW IN_PROGRESS "Smoke slow task" "- Summary: started days ago\n- Verify: pending\n"
  assert_success "$label done long after the claim succeeds" run done "$rp" dev SMOKE-SLOW "implemented" "x" "tests pass"
  grep -q "claimed and closed" "$WORK/.out" && bad "$label a slow close warned" || ok "$label a slow close does not warn"

  review_proj ic_check
  qn=1
  while [ "$qn" -le 6 ]; do
    seed_active_row "$rp" "SMOKE-Q$qn" "Smoke quick task $qn"
    run claim "$rp" dev "SMOKE-Q$qn" "start" >/dev/null 2>&1
    run done "$rp" dev "SMOKE-Q$qn" "implemented" "x" "tests pass" >/dev/null 2>&1
    qn=$((qn + 1))
  done
  assert_success "$label check does not fail on instant closes" run check "$rp"
  grep -q "6 of 6 closed tasks were closed within 5 min of their claim" "$WORK/.out" && ok "$label check prints one summary line" || bad "$label check summary missing: $(cat "$WORK/.out")"
  [ "$(grep -c 'was claimed and closed' "$WORK/.out")" -eq 5 ] && ok "$label check lists at most the 5 most recent" || bad "$label check listed $(grep -c 'was claimed and closed' "$WORK/.out") tasks instead of 5"
  grep -q "SMOKE-Q1 was claimed" "$WORK/.out" && bad "$label the oldest instant close should be left out of the list" || ok "$label the oldest instant close is left out of the list"
  assert_success "$label check is quiet when the threshold is 0" run_env PROJECT_DOCS_MIN_WORK_MINUTES=0 check "$rp"
  grep -q "closed within" "$WORK/.out" && bad "$label a zero threshold still printed the summary" || ok "$label a zero threshold prints no summary"

  echo "== $label: assign and ASSIGNED (Change 7) =="
  fresh_proj() {
    rp="$WORK/${label}_$1"
    mkdir -p "$rp"
    run init "$rp" >/dev/null 2>&1
    seed_replace "$rp/docs/Roadmap.md" "| F01-E01-T01 | UNKNOWN | UNKNOWN | UNKNOWN | TODO |" \
      "| F01-E01-T01 | Build the demo onboarding flow | detail | real accept | TODO |"
  }
  fresh_proj as_ok
  assert_success "$label assign records the assignment" run assign "$rp" lead F01-E01-T01 dev
  assert_contains "$label assign writes an ASSIGNED entry carrying the Name" "$rp/docs/Agentslog.md" "| lead | F01-E01-T01 | ASSIGNED | Build the demo onboarding flow"
  assert_contains "$label assign records the target" "$rp/docs/Agentslog.md" "- Assign: dev"
  assert_contains "$label assign leaves the row TODO and sets the Owner" "$rp/docs/Roadmap.md" "| TODO | dev@"
  awk '/^## Active work/{a=1;next} /^## Near term/{a=0} a' "$rp/docs/Roadmap.md" > "$WORK/.active"
  grep -q "F01-E01-T01" "$WORK/.active" && bad "$label assign must not move the row into Active work" || ok "$label assign leaves the row where it was"
  assert_success "$label check accepts an ASSIGNED entry" run check "$rp"
  assert_success "$label status after assign" run status "$rp"
  grep -q "lead | ASSIGNED->dev" "$WORK/.out" && ok "$label status shows who assigned and to whom" || bad "$label status after assign wrong: $(cat "$WORK/.out")"
  assert_success "$label context after assign" run context "$rp"
  grep -q "F01-E01-T01 | lead | ASSIGNED->dev" "$WORK/.out" && ok "$label Open tasks shows the assignment" || bad "$label Open tasks misses the assignment"
  assert_success "$label the assignee claims without a warning" run claim "$rp" dev F01-E01-T01 "start"
  grep -q "WARN" "$WORK/.out" && bad "$label the assignee should not be warned: $(cat "$WORK/.out")" || ok "$label claim by the assignee does not warn"
  awk '/^## Active work/{a=1;next} /^## Near term/{a=0} a' "$rp/docs/Roadmap.md" > "$WORK/.active"
  grep -q "F01-E01-T01" "$WORK/.active" && ok "$label the claimed row moved into Active work" || bad "$label the claimed row did not move into Active work"
  assert_contains "$label the Owner is now the claimant" "$rp/docs/Roadmap.md" "| IN_PROGRESS | dev@"

  fresh_proj as_other
  run assign "$rp" lead F01-E01-T01 dev >/dev/null 2>&1
  assert_success "$label another agent may still claim an assigned task" run claim "$rp" other F01-E01-T01 "start"
  grep -q "assigned to dev, not other" "$WORK/.out" && ok "$label claiming someone else's assignment warns" || bad "$label assignment warning missing: $(cat "$WORK/.out")"

  fresh_proj as_again
  run assign "$rp" lead F01-E01-T01 dev >/dev/null 2>&1
  assert_success "$label a task can be assigned again" run assign "$rp" lead F01-E01-T01 qa
  assert_success "$label status after re-assign" run status "$rp"
  grep -q "ASSIGNED->qa" "$WORK/.out" && ok "$label the latest assignment wins" || bad "$label re-assign not reflected: $(cat "$WORK/.out")"

  review_proj as_busy
  assert_failure "$label assign refuses a task somebody is working on" run assign "$rp" lead F01-E01-T01 other
  grep -q "held by dev" "$WORK/.out" && ok "$label assign error names the holder" || bad "$label assign error wrong: $(cat "$WORK/.out")"
  run handoff "$rp" dev F01-E01-T01 "code complete" "unit tests pass" >/dev/null 2>&1
  assert_failure "$label assign refuses a task in REVIEW" run assign "$rp" lead F01-E01-T01 other
  assert_failure "$label assign on an unknown task fails" run assign "$rp" lead NOPE-9 other
  assert_failure "$label assign needs a target" run assign "$rp" lead F01-E01-T01 ""

  fresh_proj as_noassign
  seed_entry "$rp" "$(now_ts)" lead F01-E01-T01 ASSIGNED "Build the demo onboarding flow" "- Summary: assigned\n"
  assert_failure "$label an ASSIGNED entry without an Assign line fails check" run check "$rp"
  grep -q "ASSIGNED entry missing Assign target" "$WORK/.out" && ok "$label check names the missing Assign target" || bad "$label missing Assign target message wrong: $(cat "$WORK/.out")"

  fresh_proj as_done
  run assign "$rp" lead F01-E01-T01 dev >/dev/null 2>&1
  assert_failure "$label a third agent cannot close an assigned task" run done "$rp" other F01-E01-T01 "implemented" "x" "tests pass"
  assert_success "$label the assignee can close it" run done "$rp" dev F01-E01-T01 "implemented" "x" "tests pass"

  echo "== $label: a project that uses none of the new words is unaffected (Change 9, regression) =="
  rg="$WORK/${label}_regress"
  mkdir -p "$rg"
  run init "$rg" >/dev/null 2>&1
  seed_active_row "$rg" SMOKE-RG1 "Regress task one"
  seed_active_row "$rg" SMOKE-RG2 "Regress task two"
  run claim "$rg" agentA SMOKE-RG1 "working on one" >/dev/null 2>&1
  run claim "$rg" agentB SMOKE-RG2 "working on two" >/dev/null 2>&1
  run pause "$rg" agentB SMOKE-RG2 LIMITE "context limit" >/dev/null 2>&1
  assert_success "$label regression: status runs" run status "$rg"
  printf '%s\n' "SMOKE-RG1 | Regress task one | agentA | IN_PROGRESS | 0h | -" "SMOKE-RG2 | Regress task two | agentB | PAUSE | 0h | LIMITE" > "$WORK/.golden"
  golden_eq "$WORK/.out" && ok "$label regression: status output is exactly what it was" || bad "$label regression: status output changed: $(cat "$WORK/.out")"
  assert_success "$label regression: context runs" run context "$rg"
  awk '/^## Open tasks/{p=1;next} /^## Latest agent entries/{p=0} p && NF' "$WORK/.out" > "$WORK/.open"
  printf '%s\n' "SMOKE-RG1 | agentA | IN_PROGRESS | 0h | -" "SMOKE-RG2 | agentB | PAUSE | 0h | LIMITE" > "$WORK/.golden"
  golden_eq "$WORK/.open" && ok "$label regression: the Open tasks section is exactly what it was" || bad "$label regression: Open tasks changed: $(cat "$WORK/.open")"
  assert_success "$label regression: check runs" run check "$rg"
  printf '%s\n' "WARN: 10 UNKNOWN field(s) in Operational summaries" "project_docs check: OK" > "$WORK/.golden"
  golden_eq "$WORK/.out" sorted && ok "$label regression: check output is exactly what it was" || bad "$label regression: check output changed: $(cat "$WORK/.out")"
  assert_success "$label regression: rotate runs" run rotate "$rg"
  printf '%s\n' "project_docs rotate: not required" > "$WORK/.golden"
  golden_eq "$WORK/.out" && ok "$label regression: rotate output is exactly what it was" || bad "$label regression: rotate output changed: $(cat "$WORK/.out")"
}

# ---------------------------------------------------------------------------
# Factory suite (F06). Runs with PROJECT_DOCS_MODE unset, so mode comes from the
# project itself; a case that needs the classic mode says so with run_env.
# ---------------------------------------------------------------------------
# Appends a "## Factory" settings table to a project AGENTS.md; each argument is
# one row body such as "Mode | FACTORY".
seed_factory_section() {
  fsp="$1"; shift
  { printf '\n## Factory\n\n| Setting | Value |\n|---|---|\n'; for fsr in "$@"; do printf '| %s |\n' "$fsr"; done; } >> "$fsp/AGENTS.md"
}

# Replaces the empty roster placeholder row with two agents, one of them QA: the
# least a Factory project needs to pass check (F06-E02-T03).
seed_min_roster() {
  smr="$1/AGENTS.md"
  awk '
    $0 == "| — | — | — | — | — |" && !done { print "| agent-dev | AI | Claude | BOTH | — |"; print "| agent-qa | AI | Claude | QA | — |"; done = 1; next }
    { print }
  ' "$smr" > "$smr.tmp"
  mv "$smr.tmp" "$smr"
}

run_factory_suite() {
  label="$1"
  run() { "$RUNNER" "$@"; }
  unset PROJECT_DOCS_MODE
  FMARK="factory-suite-start"
  # runo / runo_env run a command and leave its stdout+stderr in $WORK/.out.
  runo() { run "$@" >"$WORK/.out" 2>&1; return 0; }
  runo_env() { ( export "$1"; shift; run "$@" ) >"$WORK/.out" 2>&1; return 0; }
  echo "== $label: factory mode detection (F06-E01-T01) =="
  mode_proj() {
    mp="$WORK/${label}_$1"
    mkdir -p "$mp"
    run_env PROJECT_DOCS_MODE=classic init "$mp" >/dev/null 2>&1
  }
  expect_first_line() {  # expect_first_line "<description>" "<expected first line>"
    head -n 1 "$WORK/.out" | tr -d '\r' > "$WORK/.line1"
    printf '%s\n' "$2" > "$WORK/.golden"
    cmp -s "$WORK/.golden" "$WORK/.line1" && ok "$1" || bad "$1: got [$(cat "$WORK/.line1")]"
  }

  mode_proj md_classic
  assert_success "$label mode runs on a project without a Factory section" run mode "$mp"
  expect_first_line "$label no Factory section means CLASSIC" "project_docs mode: CLASSIC (default)"
  [ "$(wc -l < "$WORK/.out" | tr -d ' ')" -eq 1 ] && ok "$label classic mode prints one line only" || bad "$label classic mode printed extra lines: $(cat "$WORK/.out")"

  mode_proj md_factory
  seed_factory_section "$mp" "Mode | FACTORY"
  assert_success "$label mode runs on a Factory project" run mode "$mp"
  expect_first_line "$label Mode FACTORY is detected from AGENTS.md" "project_docs mode: FACTORY (AGENTS.md)"
  printf '%s\n' "project_docs mode: FACTORY (AGENTS.md)" "Mode = FACTORY" "Require TDD = YES" "Independent review = YES" \
    "WIP per agent = 1" "Max fix attempts = 3" "Fast lane max files = 5" "Fast lane max lines = 150" \
    "Fast lane protected paths = prisma/ migrations/ auth/ rls/ security/" "Preferred reviewer =" "Fallback reviewer =" \
    "Recall budget bytes = 4096" "Brain max entries = 80" > "$WORK/.golden"
  golden_eq "$WORK/.out" && ok "$label every missing setting takes its default (D-03)" || bad "$label default settings differ: $(cat "$WORK/.out")"

  mode_proj md_override
  seed_factory_section "$mp" "Mode | factory" "WIP per agent | 2" "Preferred reviewer | gemini-qa" "Fast lane protected paths | db/ infra/"
  runo mode "$mp"
  expect_first_line "$label the Mode value is case-insensitive" "project_docs mode: FACTORY (AGENTS.md)"
  grep -q '^WIP per agent = 2$' "$WORK/.out" && ok "$label a setting row overrides its default" || bad "$label WIP override missing: $(cat "$WORK/.out")"
  grep -q '^Preferred reviewer = gemini-qa$' "$WORK/.out" && ok "$label a reviewer id is read" || bad "$label reviewer missing: $(cat "$WORK/.out")"
  grep -q '^Fast lane protected paths = db/ infra/$' "$WORK/.out" && ok "$label a list setting keeps its spaces" || bad "$label protected paths wrong: $(cat "$WORK/.out")"
  grep -q '^Max fix attempts = 3$' "$WORK/.out" && ok "$label settings not overridden keep their default" || bad "$label default lost"

  mode_proj md_dash
  seed_factory_section "$mp" "Mode | FACTORY" "Preferred reviewer | —" "WIP per agent | —"
  runo mode "$mp"
  grep -q '^Preferred reviewer =$' "$WORK/.out" && ok "$label an em dash value means empty" || bad "$label dash value not empty: $(cat "$WORK/.out")"
  grep -q '^WIP per agent = 1$' "$WORK/.out" && ok "$label an empty numeric setting falls back to its default" || bad "$label empty WIP did not fall back: $(cat "$WORK/.out")"

  mode_proj md_nomode
  seed_factory_section "$mp" "WIP per agent | 3"
  runo mode "$mp"
  expect_first_line "$label a Factory section without a Mode row defaults to FACTORY" "project_docs mode: FACTORY (AGENTS.md)"

  mode_proj md_classicrow
  seed_factory_section "$mp" "Mode | CLASSIC" "WIP per agent | 3"
  runo mode "$mp"
  expect_first_line "$label Mode CLASSIC keeps the classic behavior" "project_docs mode: CLASSIC (AGENTS.md)"
  [ "$(wc -l < "$WORK/.out" | tr -d ' ')" -eq 1 ] && ok "$label Mode CLASSIC prints no settings" || bad "$label classic printed settings"

  mode_proj md_garbage
  seed_factory_section "$mp" "Mode | banana"
  runo mode "$mp"
  expect_first_line "$label an unknown Mode value is treated as CLASSIC (conservative)" "project_docs mode: CLASSIC (AGENTS.md)"

  mode_proj md_env
  assert_success "$label env factory on a classic project" run_env PROJECT_DOCS_MODE=factory mode "$mp"
  expect_first_line "$label PROJECT_DOCS_MODE=factory forces FACTORY" "project_docs mode: FACTORY (env)"
  grep -q '^Max fix attempts = 3$' "$WORK/.out" && ok "$label forced FACTORY uses the default settings" || bad "$label forced FACTORY settings missing"
  mode_proj md_env2
  seed_factory_section "$mp" "Mode | FACTORY"
  runo_env PROJECT_DOCS_MODE=classic mode "$mp"
  expect_first_line "$label PROJECT_DOCS_MODE=classic forces CLASSIC" "project_docs mode: CLASSIC (env)"
  runo_env PROJECT_DOCS_MODE=banana mode "$mp"
  expect_first_line "$label an invalid PROJECT_DOCS_MODE is ignored" "project_docs mode: FACTORY (AGENTS.md)"
  runo_env PROJECT_DOCS_MODE=FACTORY mode "$mp"
  expect_first_line "$label PROJECT_DOCS_MODE is case-insensitive" "project_docs mode: FACTORY (env)"

  echo "== $label: a classic fixture behaves as before, with no environment at all (BR-008) =="
  rg="$WORK/${label}_f_regress"
  mkdir -p "$rg"
  run_env PROJECT_DOCS_MODE=classic init "$rg" >/dev/null 2>&1
  seed_active_row "$rg" SMOKE-RG1 "Regress task one"
  seed_active_row "$rg" SMOKE-RG2 "Regress task two"
  run claim "$rg" agentA SMOKE-RG1 "working on one" >/dev/null 2>&1
  run claim "$rg" agentB SMOKE-RG2 "working on two" >/dev/null 2>&1
  run pause "$rg" agentB SMOKE-RG2 LIMITE "context limit" >/dev/null 2>&1
  runo status "$rg"
  printf '%s\n' "SMOKE-RG1 | Regress task one | agentA | IN_PROGRESS | 0h | -" "SMOKE-RG2 | Regress task two | agentB | PAUSE | 0h | LIMITE" > "$WORK/.golden"
  golden_eq "$WORK/.out" && ok "$label classic status is exactly what it was" || bad "$label classic status changed: $(cat "$WORK/.out")"
  runo check "$rg"
  printf '%s\n' "WARN: 10 UNKNOWN field(s) in Operational summaries" "project_docs check: OK" > "$WORK/.golden"
  golden_eq "$WORK/.out" sorted && ok "$label classic check is exactly what it was" || bad "$label classic check changed: $(cat "$WORK/.out")"
  runo context "$rg"
  awk '/^## Open tasks/{p=1;next} /^## Latest agent entries/{p=0} p && NF' "$WORK/.out" > "$WORK/.open"
  printf '%s\n' "SMOKE-RG1 | agentA | IN_PROGRESS | 0h | -" "SMOKE-RG2 | agentB | PAUSE | 0h | LIMITE" > "$WORK/.golden"
  golden_eq "$WORK/.open" && ok "$label classic context Open tasks is exactly what it was" || bad "$label classic Open tasks changed"
  runo rotate "$rg"
  printf '%s\n' "project_docs rotate: not required" > "$WORK/.golden"
  golden_eq "$WORK/.out" && ok "$label classic rotate is exactly what it was" || bad "$label classic rotate changed"

  echo "== $label: brain template and check validation (F06-E03-T01) =="
  # A Factory project assembled by hand: classic init, a Factory section, and the
  # brain template (init does this itself once F06-E01-T02 lands). Extra arguments
  # are more Factory settings rows.
  brain_proj() {
    bn="$1"; shift
    bp="$WORK/${label}_$bn"
    mkdir -p "$bp"
    run_env PROJECT_DOCS_MODE=classic init "$bp" >/dev/null 2>&1
    seed_factory_section "$bp" "Mode | FACTORY" "$@"
    seed_min_roster "$bp"
    cp "$SCRIPT_DIR/../templates/Brain.md" "$bp/docs/Brain.md"
  }
  brain_bad() {  # brain_bad <fixture-name> <old text> <new text> <expected message>
    brain_proj "$1"
    seed_replace "$bp/docs/Brain.md" "$2" "$3"
    assert_failure "$label check rejects: $4" run check "$bp"
    grep -qF -- "$4" "$WORK/.out" && ok "$label check names it: $4" || bad "$label check does not name '$4': $(grep Brain "$WORK/.out" | head -3)"
  }

  brain_proj br_ok
  assert_success "$label the brain template passes check in Factory mode" run check "$bp"
  [ "$(grep -c '^| LRN-' "$bp/docs/Brain.md")" -eq 3 ] && ok "$label the template ships three seed rows" || bad "$label seed rows are not three"
  grep -q 'DEFAULT | \* |' "$bp/docs/Brain.md" && ok "$label seed DEFAULT rows trigger on *" || bad "$label seed DEFAULT rows missing"

  brain_proj br_missing
  rm -f "$bp/docs/Brain.md"
  assert_failure "$label Factory mode requires docs/Brain.md" run check "$bp"
  grep -q "MISSING: docs/Brain.md" "$WORK/.out" && ok "$label check names the missing Brain.md" || bad "$label missing Brain.md not named: $(cat "$WORK/.out")"

  brain_proj br_classic
  seed_replace "$bp/AGENTS.md" "| Mode | FACTORY |" "| Mode | CLASSIC |"
  printf 'not a brain at all\n' > "$bp/docs/Brain.md"
  assert_success "$label classic mode ignores docs/Brain.md entirely" run check "$bp"
  rm -f "$bp/docs/Brain.md"
  assert_success "$label classic mode does not require docs/Brain.md" run check "$bp"

  brain_bad br_id "| LRN-003 |" "| LEARN-3 |" "invalid ID format"
  brain_bad br_kind "| PATTERN |" "| TIPS |" "invalid Kind: TIPS"
  brain_bad br_status "| seed | CONFIRMED | 0 |" "| seed | N/A | 0 |" "invalid Status: N/A"
  brain_bad br_hits "| CONFIRMED | 0 | — |" "| CONFIRMED | many | — |" "invalid Hits: many"
  brain_bad br_last "| CONFIRMED | 0 | — |" "| CONFIRMED | 0 | yesterday |" "invalid Last used: yesterday"
  brain_bad br_name "| Reproduce a bug before fixing it |" "| Reproduce a bug before fixing it with one two three four five six |" "over the 10-word limit"
  brain_bad br_noname "| LRN-003 | Reproduce a bug before fixing it |" "| LRN-003 |  |" "has an empty Name"
  brain_bad br_notrigger "| PATTERN | bug fix regression |" "| PATTERN |  |" "has an empty Trigger"
  brain_bad br_nolesson "| bug fix regression | The RED test of a BUG task reproduces the reported failure first |" "| bug fix regression |  |" "has an empty Lesson"
  brain_bad br_noevid "| seed | CONFIRMED |" "|  | CONFIRMED |" "has an empty Evidence"
  brain_bad br_dup "| LRN-002 |" "| LRN-001 |" "duplicate ID: LRN-001"
  brain_bad br_cols "| LRN-003 | Reproduce a bug before fixing it |" "| LRN-003 | Reproduce a bug | before fixing it |" "columns, expected 9"
  brain_bad br_header "| Lesson | Evidence | Status |" "| Lesson | Proof | Status |" "missing '| ID | Name | Kind | Trigger | Lesson | Evidence | Status | Hits | Last used |'"

  brain_proj br_cap "Brain max entries | 2"
  assert_failure "$label more rows than Brain max entries fails check" run check "$bp"
  grep -q "has 3 entries, over the Brain max entries limit of 2" "$WORK/.out" && ok "$label check names the cap" || bad "$label cap message wrong: $(grep Brain "$WORK/.out")"

  brain_proj br_extra
  printf '%s\n' "| LRN-004 | Run the fast test file first | RECIPE | test unit fast | Run the single spec file before the whole suite | log:F01-E01-T01 | HYPOTHESIS | 0 | — |" "| LRN-005 | Module map for billing | MAP | billing invoice src/billing/ | Billing code lives in src/billing and its tests in tests/billing | tests/billing | CONFIRMED | 2 | 2026-10-20 |" >> "$bp/docs/Brain.md"
  assert_success "$label valid extra rows of every shape pass check" run check "$bp"

  echo "== $label: init defaults to factory, migrate --factory (F06-E01-T02) =="
  ip_new() { ip="$WORK/${label}_$1"; rm -rf "$ip"; mkdir -p "$ip"; }
  lines_kept() {  # lines_kept OLD NEW: every line of OLD is still in NEW, in order, nothing removed
    # (the empty roster placeholder row is the one line migrate --factory replaces)
    tr -d '\r' < "$1" | grep -v '^| — | — | — | — | — |$' > "$WORK/.old"; tr -d '\r' < "$2" > "$WORK/.new"
    [ "$(diff "$WORK/.old" "$WORK/.new" | grep -c '^<')" -eq 0 ]
  }

  # --- init on a brand-new project -------------------------------------------
  ip_new in_new
  assert_success "$label init on an empty project" run init "$ip"
  for f in AGENTS.md docs/Agentslog.md docs/ProductDescription.md docs/Stack_Tecnologies.md docs/Roadmap.md docs/Features.md docs/Brain.md; do
    [ -f "$ip/$f" ] && ok "$label init creates $f" || bad "$label init did not create $f"
  done
  [ -d "$ip/docs/specs" ] && [ -d "$ip/docs/brain/tasks" ] && ok "$label init creates docs/specs and docs/brain/tasks" || bad "$label factory folders missing"
  ip_new in_count
  runo init "$ip"
  grep -q '^project_docs init: 7 file(s) created$' "$WORK/.out" && ok "$label init reports seven files" || bad "$label init count wrong: $(grep 'project_docs init' "$WORK/.out")"
  grep -q '^+ created: docs/Brain.md$' "$WORK/.out" && ok "$label init names docs/Brain.md" || bad "$label Brain.md not named"
  grep -q '^## Factory$' "$ip/AGENTS.md" && grep -q '^| Mode | FACTORY |$' "$ip/AGENTS.md" && ok "$label the new AGENTS.md carries the Factory section" || bad "$label Factory section missing"
  runo mode "$ip"
  expect_first_line "$label a new project reports FACTORY" "project_docs mode: FACTORY (AGENTS.md)"
  assert_success "$label a new Factory project passes check" run check "$ip"

  # --- init --classic and the env override -----------------------------------
  ip_new in_classic
  runo init "$ip" --classic
  grep -q '^project_docs init: 6 file(s) created$' "$WORK/.out" && ok "$label init --classic creates six files" || bad "$label classic count wrong: $(grep 'project_docs init' "$WORK/.out")"
  [ ! -e "$ip/docs/Brain.md" ] && [ ! -e "$ip/docs/specs" ] && [ ! -e "$ip/docs/brain" ] && ok "$label init --classic creates no brain and no folders" || bad "$label classic init created factory files"
  ! grep -q '^## Factory$' "$ip/AGENTS.md" && ok "$label init --classic writes no Factory section" || bad "$label classic AGENTS.md has a Factory section"
  runo mode "$ip"
  expect_first_line "$label a --classic project reports CLASSIC" "project_docs mode: CLASSIC (default)"

  ip_new in_envclassic
  runo_env PROJECT_DOCS_MODE=classic init "$ip"
  grep -q '^project_docs init: 6 file(s) created$' "$WORK/.out" && ok "$label PROJECT_DOCS_MODE=classic makes init create six files" || bad "$label env classic ignored"

  ip_new in_envfactory
  runo_env PROJECT_DOCS_MODE=factory init "$ip"
  grep -q '^project_docs init: 7 file(s) created$' "$WORK/.out" && ok "$label PROJECT_DOCS_MODE=factory on a new project creates seven files" || bad "$label env factory ignored"

  # --- init never changes the mode of a project the skill already manages ----
  ip_new in_existing
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  cp "$ip/AGENTS.md" "$WORK/.agents_before"
  runo init "$ip"
  grep -q '^project_docs init: 0 file(s) created$' "$WORK/.out" && ok "$label init on a classic project creates nothing" || bad "$label init changed a classic project: $(cat "$WORK/.out")"
  [ ! -e "$ip/docs/Brain.md" ] && ! grep -q '^## Factory$' "$ip/AGENTS.md" && ok "$label init does not turn a classic project into Factory (BR-008)" || bad "$label classic project got Factory files"
  cmp -s "$WORK/.agents_before" "$ip/AGENTS.md" && ok "$label init leaves a classic AGENTS.md byte-identical" || bad "$label classic AGENTS.md changed"
  runo_env PROJECT_DOCS_MODE=factory init "$ip"
  [ ! -e "$ip/docs/Brain.md" ] && ok "$label PROJECT_DOCS_MODE=factory does not force init on an existing classic project" || bad "$label env factory converted a classic project"

  ip_new in_modeclassic
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  seed_factory_section "$ip" "Mode | CLASSIC"
  runo init "$ip"
  [ ! -e "$ip/docs/Brain.md" ] && ok "$label a Factory section with Mode CLASSIC keeps init classic" || bad "$label Mode CLASSIC project got a brain"

  ip_new in_twice
  run init "$ip" >/dev/null 2>&1
  cp "$ip/AGENTS.md" "$WORK/.agents_before"
  runo init "$ip"
  grep -q '^project_docs init: 0 file(s) created$' "$WORK/.out" && ok "$label a second init on a Factory project creates nothing" || bad "$label second init not idempotent: $(cat "$WORK/.out")"
  cmp -s "$WORK/.agents_before" "$ip/AGENTS.md" && ok "$label a second init leaves AGENTS.md byte-identical" || bad "$label second init changed AGENTS.md"

  ip_new in_handwritten
  printf '# My rules\n\nUse tabs.\n' > "$ip/AGENTS.md"
  cp "$ip/AGENTS.md" "$WORK/.agents_before"
  runo init "$ip"
  grep -q '^= merged skill block: AGENTS.md$' "$WORK/.out" && ok "$label init merges into a hand-written AGENTS.md" || bad "$label hand-written AGENTS.md not merged: $(cat "$WORK/.out")"
  lines_kept "$WORK/.agents_before" "$ip/AGENTS.md" && ok "$label the hand-written rules are kept" || bad "$label hand-written rules lost"
  grep -q '^## Factory$' "$ip/AGENTS.md" && [ -f "$ip/docs/Brain.md" ] && ok "$label a project with only a hand-written AGENTS.md starts in Factory" || bad "$label hand-written project not Factory"

  # --- migrate --factory ------------------------------------------------------
  ip_new mg_classic
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  cp "$ip/AGENTS.md" "$WORK/.agents_before"
  runo migrate "$ip"
  grep -q '^project_docs migrate: 0 change(s)$' "$WORK/.out" && ok "$label migrate without --factory changes nothing on a classic project" || bad "$label plain migrate changed it: $(cat "$WORK/.out")"
  [ ! -e "$ip/docs/Brain.md" ] && cmp -s "$WORK/.agents_before" "$ip/AGENTS.md" && ok "$label migrate without --factory adds no Factory files (BR-008)" || bad "$label plain migrate added factory files"

  ip_new mg_msgs
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  cp "$ip/AGENTS.md" "$WORK/.agents_before"
  assert_success "$label migrate --factory on a classic project" run migrate "$ip" --factory
  grep -q '^+ added: ## Factory section in AGENTS.md$' "$WORK/.out" && ok "$label migrate --factory adds the Factory section" || bad "$label section not added: $(cat "$WORK/.out")"
  grep -q '^+ added: default agent roster in AGENTS.md$' "$WORK/.out" && ok "$label migrate --factory fills an empty roster" || bad "$label roster not filled: $(cat "$WORK/.out")"
  grep -q '^+ created: docs/Brain.md$' "$WORK/.out" && ok "$label migrate --factory creates docs/Brain.md" || bad "$label Brain.md not created"
  grep -q '^+ created: docs/specs/$' "$WORK/.out" && grep -q '^+ created: docs/brain/tasks/$' "$WORK/.out" && ok "$label migrate --factory creates the folders" || bad "$label folders not reported"
  grep -q '^project_docs migrate: 6 change(s)$' "$WORK/.out" && ok "$label migrate --factory counts six changes" || bad "$label change count wrong: $(grep 'project_docs migrate' "$WORK/.out")"
  [ -f "$ip/docs/Brain.md" ] && [ -d "$ip/docs/specs" ] && [ -d "$ip/docs/brain/tasks" ] && ok "$label the brain and the folders exist on disk" || bad "$label migrate files missing on disk"
  lines_kept "$WORK/.agents_before" "$ip/AGENTS.md" && ok "$label migrate --factory removes nothing from AGENTS.md" || bad "$label migrate --factory removed lines"
  fl="$(grep -n '^## Factory$' "$ip/AGENTS.md" | cut -d: -f1)"; al="$(grep -n '^## Agent identity$' "$ip/AGENTS.md" | cut -d: -f1)"; el="$(grep -n 'project-documentation:end' "$ip/AGENTS.md" | cut -d: -f1)"
  [ -n "$fl" ] && [ -n "$al" ] && [ "$fl" -lt "$al" ] && [ "$al" -lt "$el" ] && ok "$label the Factory section sits before Agent identity inside the block" || bad "$label section order wrong: factory=$fl identity=$al end=$el"
  grep -q '^| claude-qa | AI | Claude | QA | — |$' "$ip/AGENTS.md" && ! grep -q '^| — | — | — | — | — |$' "$ip/AGENTS.md" && ok "$label the placeholder roster row is replaced by the defaults" || bad "$label roster not replaced"
  runo mode "$ip"
  expect_first_line "$label the migrated project reports FACTORY" "project_docs mode: FACTORY (AGENTS.md)"
  assert_success "$label a migrated project passes check" run check "$ip"

  cp "$ip/AGENTS.md" "$WORK/.agents_before"; cp "$ip/docs/Brain.md" "$WORK/.brain_before"
  runo migrate "$ip" --factory
  grep -q '^project_docs migrate: 0 change(s)$' "$WORK/.out" && ok "$label a second migrate --factory changes nothing" || bad "$label second migrate not idempotent: $(cat "$WORK/.out")"
  cmp -s "$WORK/.agents_before" "$ip/AGENTS.md" && cmp -s "$WORK/.brain_before" "$ip/docs/Brain.md" && ok "$label a second migrate --factory leaves the files byte-identical" || bad "$label second migrate changed files"
  [ "$(grep -c '^## Factory$' "$ip/AGENTS.md")" -eq 1 ] && ok "$label the Factory section appears once" || bad "$label Factory section duplicated"

  ip_new mg_roster
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  seed_replace "$ip/AGENTS.md" "| — | — | — | — | — |" "| my-agent | AI | Claude | BOTH | — |"
  runo migrate "$ip" --factory
  grep -q '^| my-agent | AI | Claude | BOTH | — |$' "$ip/AGENTS.md" && ! grep -q '^| claude-spec ' "$ip/AGENTS.md" && ok "$label migrate --factory keeps an existing roster" || bad "$label existing roster touched"
  ! grep -q 'default agent roster' "$WORK/.out" && ok "$label migrate --factory does not announce a roster it did not add" || bad "$label roster announced"

  ip_new mg_brain
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  mkdir -p "$ip/docs" && printf 'my own brain\n' > "$ip/docs/Brain.md"
  runo migrate "$ip" --factory
  [ "$(cat "$ip/docs/Brain.md" | tr -d '\r')" = "my own brain" ] && ok "$label migrate --factory never overwrites an existing docs/Brain.md" || bad "$label Brain.md overwritten"

  ip_new mg_modeclassic
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  seed_factory_section "$ip" "Mode | CLASSIC"
  runo migrate "$ip" --factory
  grep -q '^= kept: Mode is not FACTORY in AGENTS.md (set it to FACTORY to switch)$' "$WORK/.out" && ok "$label migrate --factory says it kept Mode CLASSIC" || bad "$label kept note missing: $(cat "$WORK/.out")"
  runo mode "$ip"
  expect_first_line "$label migrate --factory never flips an explicit Mode CLASSIC" "project_docs mode: CLASSIC (AGENTS.md)"

  ip_new mg_noidentity
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  awk '$0=="## Agent identity"{skip=1;next} skip && /^## /{skip=0} skip && /^<!--/{skip=0} !skip' "$ip/AGENTS.md" > "$WORK/.noid" && cp "$WORK/.noid" "$ip/AGENTS.md"
  ! grep -q '^## Agent identity$' "$ip/AGENTS.md" || bad "$label fixture still has Agent identity"
  runo migrate "$ip" --factory
  grep -q '^+ added: ## Agent identity section with the default roster in AGENTS.md$' "$WORK/.out" && ok "$label migrate --factory adds a missing Agent identity section" || bad "$label identity section not added: $(cat "$WORK/.out")"
  grep -q '^| claude-dev | AI | Claude | DEV | — |$' "$ip/AGENTS.md" && ok "$label the added section carries the default roster" || bad "$label default roster missing"

  echo "== $label: compact factory rules and the decisions pointer (F06-E01-T03) =="
  ptr='- In Factory mode the autonomy policy in `## Factory` replaces asking a human.'

  ip_new rl_new
  run init "$ip" >/dev/null 2>&1
  runo context "$ip"
  cbytes="$(tr -d '\r' < "$WORK/.out" | wc -c | tr -d ' ')"
  [ "$cbytes" -le 6912 ] && ok "$label a fresh Factory project context is $cbytes bytes, at most 6912" || bad "$label fresh Factory context is $cbytes bytes, over 6912"
  fbytes="$(awk '$0=="## Factory"{p=1} p&&/^## /&&$0!="## Factory"{exit} p' "$ip/AGENTS.md" | tr -d '\r' | wc -c | tr -d ' ')"
  [ "$fbytes" -le 1536 ] && ok "$label the Factory section is $fbytes bytes, at most 1.5 KiB" || bad "$label the Factory section is $fbytes bytes"
  for phrase in 'Never ask which task to take: run `next <agent>`' 'Lane: FAST' 'Phases: SPEC -> RED -> GREEN -> REVIEW -> DONE' 'GREEN never edits the tests recorded at RED' 'Record product guesses as HYPOTHESIS' 'RED-LINE' 'then `recall <task>`' '`checkpoint` before pausing'; do
    grep -qF -- "$phrase" "$ip/AGENTS.md" && ok "$label the Factory rules say: $phrase" || bad "$label the Factory rules lack: $phrase"
  done
  grep -qF -- "$ptr" "$ip/AGENTS.md" && ok "$label the decisions section points to ## Factory" || bad "$label the decisions pointer is missing"
  ! grep -q 'Escalate to the human' "$ip/AGENTS.md" && ok "$label the Factory AGENTS.md does not tell agents to escalate to a human" || bad "$label the Factory AGENTS.md still escalates to a human"
  runo mode "$ip"
  awk -F'|' '$0=="## Factory"{p=1;next} p&&/^## /{exit} p&&/^\|/ { n=$2; v=$3; gsub(/^ +| +$/,"",n); gsub(/^ +| +$/,"",v); if (n=="Setting"||n ~ /^-+$/) next; if (v=="—") v=""; print (v=="" ? n " =" : n " = " v) }' "$ip/AGENTS.md" | tr -d '\r' > "$WORK/.expected"
  [ "$(wc -l < "$WORK/.expected" | tr -d ' ')" -eq 10 ] && ok "$label the template settings table has ten rows" || bad "$label settings table rows: $(cat "$WORK/.expected")"
  tr -d '\r' < "$WORK/.out" > "$WORK/.modeout"
  missing=0
  while IFS= read -r line; do grep -qxF -- "$line" "$WORK/.modeout" || { missing=1; bad "$label template setting not equal to the code default: $line"; }; done < "$WORK/.expected"
  [ "$missing" -eq 0 ] && ok "$label every template setting equals the default the scripts use"

  ip_new rl_mig
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  grep -q 'Escalate to the human' "$ip/AGENTS.md" && ok "$label the classic block still escalates to a human" || bad "$label classic block changed"
  runo migrate "$ip" --factory
  grep -q '^+ added: Factory pointer in Technical and product decisions$' "$WORK/.out" && ok "$label migrate --factory announces the decisions pointer" || bad "$label pointer not announced: $(cat "$WORK/.out")"
  grep -q 'Escalate to the human' "$ip/AGENTS.md" && ok "$label migrate --factory keeps the classic bullet" || bad "$label classic bullet removed"
  [ "$(grep -cF -- "$ptr" "$ip/AGENTS.md")" -eq 1 ] && ok "$label the pointer is added once" || bad "$label pointer count wrong"
  eline="$(grep -n 'record the outcome either way\.' "$ip/AGENTS.md" | head -1 | cut -d: -f1)"
  nextline="$(sed -n "$((eline + 1))p" "$ip/AGENTS.md" | tr -d '\r')"
  [ "$nextline" = "$ptr" ] && ok "$label the pointer sits right after the escalate bullet" || bad "$label pointer misplaced: next line is [$nextline]"
  assert_success "$label a migrated project with the pointer passes check" run check "$ip"
  runo migrate "$ip" --factory
  grep -q '^project_docs migrate: 0 change(s)$' "$WORK/.out" && [ "$(grep -cF -- "$ptr" "$ip/AGENTS.md")" -eq 1 ] && ok "$label a second migrate --factory adds no second pointer" || bad "$label pointer not idempotent: $(cat "$WORK/.out")"

  ip_new rl_nobullet
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  seed_replace "$ip/AGENTS.md" "- Escalate to the human when a choice affects product behavior, cost," "- Ask the lead when a choice affects product behavior, cost,"
  runo migrate "$ip" --factory
  ! grep -q 'Factory pointer' "$WORK/.out" && ! grep -qF -- "$ptr" "$ip/AGENTS.md" && ok "$label no pointer is added when the project reworded the escalate bullet" || bad "$label pointer added to a reworded block"

  echo "== $label: Brain cap parsing and CRLF handling (F06-DEBT-01) =="
  crlf_file() { sed 's/$/\r/' "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }

  brain_proj db_big "Brain max entries | 99999999999"
  assert_success "$label a Brain max entries value that is too large falls back to the default" run check "$bp"
  brain_proj db_text "Brain max entries | lots"
  assert_success "$label a Brain max entries value that is text falls back to the default" run check "$bp"
  brain_proj db_zero "Brain max entries | 0"
  assert_success "$label a Brain max entries value of zero falls back to the default" run check "$bp"
  brain_proj db_lead "Brain max entries | 002"
  assert_failure "$label a leading zero does not change the cap" run check "$bp"
  grep -q "has 3 entries, over the Brain max entries limit of 2$" "$WORK/.out" && ok "$label the cap is printed without its leading zeros" || bad "$label cap text wrong: $(grep Brain "$WORK/.out")"
  brain_proj db_lead10 "Brain max entries | 0000000002"
  assert_failure "$label ten digits that are mostly zeros still mean the cap they spell" run check "$bp"
  grep -q "limit of 2$" "$WORK/.out" && ok "$label a ten digit cap with zeros reads as 2" || bad "$label ten digit cap wrong: $(grep Brain "$WORK/.out")"

  brain_proj db_crlf
  crlf_file "$bp/docs/Brain.md"
  assert_success "$label a Brain.md with CRLF line endings passes check" run check "$bp"
  seed_replace "$bp/docs/Brain.md" "| LRN-003 |" "| LEARN-3 |"
  assert_failure "$label a CRLF Brain.md still has its rows validated" run check "$bp"
  grep -q "invalid ID format" "$WORK/.out" && ok "$label the CRLF Brain.md row error is named" || bad "$label CRLF row error missing: $(grep Brain "$WORK/.out")"

  ip_new db_eol
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  crlf_file "$ip/AGENTS.md"
  runo migrate "$ip" --factory
  grep -q '^= normalized: AGENTS.md line endings (CRLF to LF)$' "$WORK/.out" && ok "$label migrate --factory says it made a CRLF AGENTS.md LF" || bad "$label normalization not announced: $(cat "$WORK/.out")"
  tr -d '\r' < "$ip/AGENTS.md" | cmp -s - "$ip/AGENTS.md" && ok "$label the migrated AGENTS.md has no carriage returns" || bad "$label carriage returns left"
  [ "$(grep -c '^## Factory$' "$ip/AGENTS.md")" -eq 1 ] && [ "$(grep -c '^## Agent identity$' "$ip/AGENTS.md")" -eq 1 ] && ok "$label the sections of a CRLF project are added once" || bad "$label CRLF project sections duplicated"
  grep -q '^| claude-qa | AI | Claude | QA | — |$' "$ip/AGENTS.md" && ok "$label the CRLF project gets the default roster" || bad "$label CRLF roster missing"
  assert_success "$label a migrated CRLF project passes check" run check "$ip"
  runo migrate "$ip" --factory
  grep -q '^project_docs migrate: 0 change(s)$' "$WORK/.out" && ok "$label a second migrate --factory on the CRLF project changes nothing" || bad "$label CRLF migrate not idempotent: $(cat "$WORK/.out")"

  ip_new db_roster
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  grep -vxF '| — | — | — | — | — |' "$ip/AGENTS.md" > "$ip/AGENTS.md.tmp" && mv "$ip/AGENTS.md.tmp" "$ip/AGENTS.md"
  runo migrate "$ip" --factory
  grep -q '^+ added: default agent roster in AGENTS.md$' "$WORK/.out" && ok "$label a roster table with no rows and no placeholder gets the default rows" || bad "$label roster not filled: $(cat "$WORK/.out")"
  grep -q '^| claude-dev | AI | Claude | DEV | — |$' "$ip/AGENTS.md" && ok "$label the default rows are in the table" || bad "$label default rows missing"
  cp "$ip/AGENTS.md" "$WORK/.agents_before"
  runo migrate "$ip" --factory
  grep -q '^project_docs migrate: 0 change(s)$' "$WORK/.out" && ! grep -q 'default agent roster' "$WORK/.out" && cmp -s "$WORK/.agents_before" "$ip/AGENTS.md" && ok "$label the roster is not announced or changed on a rerun" || bad "$label roster rerun not idempotent: $(cat "$WORK/.out")"

  # init and migrate flags: with no project argument, and not only right after it
  noproj() {  # noproj <dir> <command> [flags]: runs the command with the current folder as the project
    npd="$1"; shift
    if [ "$RUNNER" = "ps1_runner" ]; then
      npa=""; for npx in "$@"; do npa="$npa '$npx'"; done
      ( cd "$npd" && "$PWSH" -NoProfile -NonInteractive -Command "& '$PS1_BIN_NATIVE' $npa" ) >"$WORK/.out" 2>&1
    else
      ( cd "$npd" && sh "$SH_BIN" "$@" ) >"$WORK/.out" 2>&1
    fi
  }
  ip_new fl_noproj
  noproj "$ip" init --classic
  [ ! -e "$ip/docs/Brain.md" ] && [ -f "$ip/AGENTS.md" ] && grep -q '^project_docs init: 6 file(s) created$' "$WORK/.out" && ok "$label init --classic with no project argument uses the current folder" || bad "$label init --classic without a project failed: $(cat "$WORK/.out")"
  ip_new fl_noproj_m
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  noproj "$ip" migrate --factory
  grep -q '^+ added: ## Factory section in AGENTS.md$' "$WORK/.out" && ok "$label migrate --factory with no project argument uses the current folder" || bad "$label migrate --factory without a project failed: $(cat "$WORK/.out")"
  ip_new fl_late
  runo init "$ip" extra --classic
  grep -q '^project_docs init: 6 file(s) created$' "$WORK/.out" && ok "$label init finds --classic after another argument" || bad "$label late --classic ignored: $(cat "$WORK/.out")"
  ip_new fl_case
  runo init "$ip" --CLASSIC
  grep -q '^project_docs init: 7 file(s) created$' "$WORK/.out" && ok "$label the flags are case-sensitive, so --CLASSIC does not make init classic" || bad "$label --CLASSIC was honored: $(cat "$WORK/.out")"

  echo "== $label: spec template and check rules (F06-E02-T01) =="
  sedi() { sed "$1" "$2" > "$2.tmp" && mv "$2.tmp" "$2"; }  # no sed -i: it differs across the shells this runs under
  mkspec() {  # mkspec <project> <TASK-ID>: writes a valid, fully filled spec
    cat > "$1/docs/specs/$2.md" <<SPEC
# Spec $2 — Export the invoice list

## Summary

- Goal: Let a user export the invoice list as CSV
- Rules: BR-020
- Tags: invoice export csv src/billing/
<!-- context:end -->

## Scenarios

| ID | Given | When | Then | Level | Justification |
|---|---|---|---|---|---|
| S01 | Three invoices exist | The user asks for a CSV | One line per invoice is returned | UNIT | — |
| S02 | No invoices exist | The user asks for a CSV | Only the header line is returned | UNIT | — |
| S03 | The README mentions export | A maintainer reads it | The command is documented | NONE | Docs only, reviewed by the QA agent |

## Tests

- tests/billing/export.spec.sh (S01, S02)

## Out of scope

- Excel export
SPEC
  }
  spec_bad() {  # spec_bad <fixture-name> <sed expression> <expected message>
    sp_proj "$1"
    mkspec "$sp" F09-E01-T01
    sedi "$2" "$sp/docs/specs/F09-E01-T01.md"
    assert_failure "$label check rejects: $3" run check "$sp"
    grep -qF -- "$3" "$WORK/.out" && ok "$label check names it: $3" || bad "$label check does not name '$3': $(grep specs "$WORK/.out" | head -3)"
  }
  sp_proj() { sp="$WORK/${label}_sp_$1"; rm -rf "$sp"; mkdir -p "$sp"; run init "$sp" >/dev/null 2>&1; }

  sp_proj sp_ok
  mkspec "$sp" F09-E01-T01
  assert_success "$label a valid spec passes check" run check "$sp"
  ! grep -q 'docs/specs/.*UNKNOWN' "$WORK/.out" && ok "$label a fully filled spec raises no UNKNOWN warning" || bad "$label valid spec warned: $(grep 'docs/specs' "$WORK/.out")"

  sp_proj sp_tpl
  sed -e 's/{TASK}/F09-E01-T02/' -e 's/{NAME}/Draft spec from the template/' "$SCRIPT_DIR/../templates/Spec.md" > "$sp/docs/specs/F09-E01-T02.md"
  assert_success "$label a spec made from the template is structurally valid" run check "$sp"
  grep -q '^WARN: docs/specs/F09-E01-T02.md has 4 UNKNOWN field(s)$' "$WORK/.out" && ok "$label the template draft warns about its four UNKNOWN fields" || bad "$label template warning wrong: $(grep -i 'specs\|UNKNOWN' "$WORK/.out" | head -3)"

  sp_proj sp_none
  assert_success "$label an empty docs/specs folder passes check" run check "$sp"

  spec_bad sp_title 's/^# Spec F09-E01-T01 — .*/# Spec F09-E01-T99 — Wrong id/' "title must start with '# Spec F09-E01-T01'"
  spec_bad sp_nosummary '/^## Summary$/d' "is missing section '## Summary'"
  spec_bad sp_noscen '/^## Scenarios$/d' "is missing section '## Scenarios'"
  spec_bad sp_notests '/^## Tests$/d' "is missing section '## Tests'"
  spec_bad sp_noscope '/^## Out of scope$/d' "is missing section '## Out of scope'"
  spec_bad sp_nogoal '/^- Goal:/d' "Summary is missing '- Goal:'"
  spec_bad sp_emptygoal 's/^- Goal:.*/- Goal:/' "has an empty Goal"
  spec_bad sp_norules '/^- Rules:/d' "Summary is missing '- Rules:'"
  spec_bad sp_emptyrules 's/^- Rules:.*/- Rules:/' "has empty Rules"
  spec_bad sp_notags '/^- Tags:/d' "Summary is missing '- Tags:'"
  spec_bad sp_emptytags 's/^- Tags:.*/- Tags:/' "has empty Tags"
  spec_bad sp_nomarker '/<!-- context:end -->/d' "has no '<!-- context:end -->' marker inside ## Summary"
  spec_bad sp_header 's/| Then | Level |/| Result | Level |/' "has an invalid Scenarios header"
  spec_bad sp_nohdr '/^| ID | Given/d' "is missing the Scenarios header row"
  spec_bad sp_norows '/^| S0[0-9] /d' "has no scenarios"
  spec_bad sp_cols 's/^| S02 | No invoices exist | The user asks for a CSV | /| S02 | /' "scenario row 'S02' has 4 columns, expected 6"
  spec_bad sp_sid 's/^| S02 |/| T2 |/' "scenario ID 'T2' is not S01 style"
  spec_bad sp_dup 's/^| S02 |/| S01 |/' "duplicate scenario ID: S01"
  spec_bad sp_given 's/^| S01 | Three invoices exist |/| S01 |  |/' "scenario 'S01' has an empty Given"
  spec_bad sp_when 's/| The user asks for a CSV | One line/|  | One line/' "scenario 'S01' has an empty When"
  spec_bad sp_then 's/| One line per invoice is returned |/|  |/' "scenario 'S01' has an empty Then"
  spec_bad sp_level 's/| One line per invoice is returned | UNIT |/| One line per invoice is returned | UNITTEST |/' "scenario 'S01' has invalid Level: UNITTEST"
  spec_bad sp_none 's/| Docs only, reviewed by the QA agent |/| — |/' "scenario 'S03' has Level NONE without a Justification"
  spec_bad sp_none2 's/| Docs only, reviewed by the QA agent |/|  |/' "scenario 'S03' has Level NONE without a Justification"
  spec_bad sp_testfmt 's#^- tests/billing/export.spec.sh (S01, S02)#- tests/billing/export.spec.sh#' "Tests entry 'tests/billing/export.spec.sh' is not '- path (S01, S02)'"
  spec_bad sp_testref 's#(S01, S02)#(S01, S09)#' "Tests entry 'tests/billing/export.spec.sh' refers to unknown scenario S09"

  sp_proj sp_empty_tests
  mkspec "$sp" F09-E01-T01
  sedi '/^- tests\/billing/d' "$sp/docs/specs/F09-E01-T01.md"
  assert_success "$label an empty Tests section is fine before RED" run check "$sp"

  sp_proj sp_crlf
  mkspec "$sp" F09-E01-T01
  sedi 's/$/\r/' "$sp/docs/specs/F09-E01-T01.md"
  assert_success "$label a spec with CRLF line endings passes check" run check "$sp"

  sp_proj sp_two
  mkspec "$sp" F09-E01-T01
  mkspec "$sp" F09-E01-T02
  sedi '/^- Goal:/d' "$sp/docs/specs/F09-E01-T02.md"
  assert_failure "$label one bad spec among several fails check" run check "$sp"
  grep -q "docs/specs/F09-E01-T02.md Summary is missing" "$WORK/.out" && ! grep -q "docs/specs/F09-E01-T01.md" "$WORK/.out" && ok "$label only the bad spec is named" || bad "$label wrong specs named: $(grep specs "$WORK/.out")"

  sp_proj sp_classic
  mkspec "$sp" F09-E01-T01
  sedi '/^## Tests$/d' "$sp/docs/specs/F09-E01-T01.md"
  run_env PROJECT_DOCS_MODE=classic check "$sp" >/dev/null 2>&1 && ok "$label classic mode ignores docs/specs entirely" || bad "$label classic mode checked a spec"

  echo "== $label: phase roles in the roster and claim (F06-E02-T03) =="
  cl_proj() { cl="$WORK/${label}_cl_$1"; rm -rf "$cl"; mkdir -p "$cl"; run init "$cl" >/dev/null 2>&1; seed_plan_row "$cl" F09-E01-T01 "Role gated task"; }
  drop_rows() {  # drop_rows <file> <grep pattern>: removes the matching lines
    grep -v -- "$2" "$1" > "$1.tmp"; mv "$1.tmp" "$1"
  }
  ledger_entries() { grep -c '^## \[' "$cl/docs/Agentslog.md" | tr -d ' '; }

  cl_proj c_spec
  assert_success "$label a SPEC agent claims a task with no phase yet" run claim "$cl" claude-spec F09-E01-T01 "write the spec"
  [ "$(grep -c '^- Phase: SPEC$' "$cl/docs/Agentslog.md")" -eq 1 ] && ok "$label the claim records the phase it starts in" || bad "$label no Phase line after the claim"

  cl_proj c_dev
  before="$(ledger_entries)"
  assert_failure "$label a DEV agent cannot claim a task in the SPEC phase" run claim "$cl" claude-dev F09-E01-T01 "too early"
  grep -q "claim failed: claude-dev has role DEV, but phase SPEC of F09-E01-T01 needs SPEC (or BOTH)" "$WORK/.out" && ok "$label the refusal names the role and the phase" || bad "$label refusal text wrong: $(cat "$WORK/.out")"
  [ "$(ledger_entries)" = "$before" ] && ok "$label a refused claim writes nothing to the ledger" || bad "$label refused claim wrote an entry"
  assert_failure "$label a QA agent cannot claim a task in the SPEC phase" run claim "$cl" claude-qa F09-E01-T01 "wrong role"
  assert_failure "$label a QA agent of another model cannot claim it either" run claim "$cl" gemini-qa F09-E01-T01 "wrong role"
  assert_failure "$label an agent that is not in the roster cannot claim in Factory mode" run claim "$cl" someone-new F09-E01-T01 "unknown"
  grep -q "someone-new is not in the Agent identity table; Factory mode needs a role for each agent" "$WORK/.out" && ok "$label the refusal for an unknown agent says why" || bad "$label unknown agent text wrong: $(cat "$WORK/.out")"

  cl_proj c_both
  seed_replace "$cl/AGENTS.md" "| claude-spec | AI | Claude | SPEC |" "| claude-spec | AI | Claude | BOTH |"
  assert_success "$label a BOTH agent claims a SPEC phase task" run claim "$cl" claude-spec F09-E01-T01 "both roles"
  seed_entry "$cl" "$(now_ts)" claude-test F09-E01-T01 ASSIGNED "Role gated task" '- Assign: claude-dev\n- Phase: GREEN\n'
  assert_success "$label a BOTH agent also claims a GREEN phase task" run claim "$cl" claude-spec F09-E01-T01 "green too"
  grep -c '^- Phase: GREEN$' "$cl/docs/Agentslog.md" | grep -q '^2$' && ok "$label the claim keeps the phase the task is in" || bad "$label GREEN phase lost: $(grep '^- Phase' "$cl/docs/Agentslog.md" | tr '\n' ' ')"

  cl_proj c_green
  seed_replace "$cl/AGENTS.md" "| claude-dev | AI | Claude | DEV | — |" "| claude-dev | AI | Claude | DEVELOPER | dev-bot |"
  seed_entry "$cl" "$(now_ts)" claude-test F09-E01-T01 ASSIGNED "Role gated task" '- Assign: claude-test\n- Phase: GREEN\n'
  assert_failure "$label a SPEC agent cannot claim a GREEN phase task" run claim "$cl" claude-spec F09-E01-T01 "wrong phase"
  grep -q "claim failed: claude-spec has role SPEC, but phase GREEN of F09-E01-T01 needs DEV (or BOTH)" "$WORK/.out" && ok "$label a GREEN phase task needs the DEV role" || bad "$label GREEN refusal wrong: $(cat "$WORK/.out")"
  assert_failure "$label a TEST agent cannot claim a GREEN phase task" run claim "$cl" claude-test F09-E01-T01 "wrong phase"
  assert_success "$label a DEVELOPER role counts as DEV, claimed through an alias" run claim "$cl" dev-bot F09-E01-T01 "make it green"
  ! grep -q 'is assigned to' "$WORK/.out" && ok "$label no assignment warning when the role matches, even for another agent id" || bad "$label assignment warning in Factory mode: $(cat "$WORK/.out")"
  grep -q '^## \[.*\] | claude-dev | F09-E01-T01 | IN_PROGRESS' "$cl/docs/Agentslog.md" && ok "$label the alias is written as the roster id" || bad "$label alias not resolved"

  cl_proj c_red
  seed_entry "$cl" "$(now_ts)" claude-spec F09-E01-T01 ASSIGNED "Role gated task" '- Assign: claude-test\n- Phase: RED\n'
  assert_failure "$label a DEV agent cannot claim a RED phase task" run claim "$cl" claude-dev F09-E01-T01 "wrong phase"
  grep -q "needs TEST (or BOTH)" "$WORK/.out" && ok "$label a RED phase task needs the TEST role" || bad "$label RED refusal wrong: $(cat "$WORK/.out")"
  assert_success "$label a TEST agent claims a RED phase task" run claim "$cl" claude-test F09-E01-T01 "write the failing tests"

  # classic mode: roles and the phase line do not exist
  ip_new cl_classic
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  seed_plan_row "$ip" F09-E01-T01 "Role gated task"
  assert_success "$label classic mode lets any agent claim, roster or not" run claim "$ip" someone-new F09-E01-T01 "classic"
  ! grep -q '^- Phase:' "$ip/docs/Agentslog.md" && ok "$label classic mode writes no Phase line" || bad "$label classic claim wrote a Phase line"
  ip_new cl_classic_roster
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  seed_plan_row "$ip" F09-E01-T01 "Role gated task"
  seed_replace "$ip/AGENTS.md" "| — | — | — | — | — |" "| a-qa | AI | Claude | QA | — |"
  assert_success "$label classic mode ignores the role of the claiming agent" run claim "$ip" a-qa F09-E01-T01 "qa claims"

  # check: the roster rules of Factory mode
  ro_proj() { ro="$WORK/${label}_ro_$1"; rm -rf "$ro"; mkdir -p "$ro"; run init "$ro" >/dev/null 2>&1; }
  ro_proj ok
  assert_success "$label the default roster passes check in Factory mode" run check "$ro"
  ro_proj none
  drop_rows "$ro/AGENTS.md" '^| claude-\|^| gemini-'
  assert_failure "$label a Factory project without agents fails check" run check "$ro"
  grep -q "ERROR: Agent identity needs at least 2 agents in Factory mode (found 0)" "$WORK/.out" && grep -q "ERROR: Agent identity needs an agent with role QA (or BOTH) in Factory mode" "$WORK/.out" && ok "$label both roster errors are named" || bad "$label empty roster errors wrong: $(grep Agent "$WORK/.out")"
  ro_proj one
  drop_rows "$ro/AGENTS.md" '^| claude-spec\|^| claude-test\|^| claude-dev\|^| gemini-'
  assert_failure "$label a Factory project with one agent fails check" run check "$ro"
  grep -q "(found 1)" "$WORK/.out" && ! grep -q "role QA" "$WORK/.out" && ok "$label one agent is counted and its QA role is accepted" || bad "$label one agent text wrong: $(grep Agent "$WORK/.out")"
  ro_proj noqa
  drop_rows "$ro/AGENTS.md" '^| claude-qa\|^| gemini-qa'
  assert_failure "$label a Factory roster with no QA fails check" run check "$ro"
  grep -q "ERROR: Agent identity needs an agent with role QA (or BOTH) in Factory mode" "$WORK/.out" && ! grep -q "at least 2" "$WORK/.out" && ok "$label the missing QA role is named" || bad "$label no QA text wrong: $(grep Agent "$WORK/.out")"
  ro_proj badrole
  seed_replace "$ro/AGENTS.md" "| claude-test | AI | Claude | TEST |" "| claude-test | AI | Claude | TESTER |"
  assert_failure "$label an unknown role fails check" run check "$ro"
  grep -q "ERROR: Agent identity row 'claude-test' has invalid Role: TESTER" "$WORK/.out" && ok "$label the invalid role is named" || bad "$label invalid role text wrong: $(grep Agent "$WORK/.out")"
  ro_proj lower
  seed_replace "$ro/AGENTS.md" "| claude-dev | AI | Claude | DEV |" "| claude-dev | AI | Claude | dev |"
  assert_failure "$label a lowercase role fails check" run check "$ro"
  grep -q "has invalid Role: dev" "$WORK/.out" && ok "$label roles are case-sensitive" || bad "$label lowercase role text wrong: $(grep Agent "$WORK/.out")"
  ro_proj legal
  seed_replace "$ro/AGENTS.md" "| claude-dev | AI | Claude | DEV |" "| claude-dev | AI | Claude | DEVELOPER |"
  seed_replace "$ro/AGENTS.md" "| claude-test | AI | Claude | TEST |" "| claude-test | AI | Claude | OPS |"
  seed_replace "$ro/AGENTS.md" "| gemini-qa | AI | Gemini | QA |" "| gemini-qa | AI | Gemini | BOTH |"
  assert_success "$label DEVELOPER, OPS and BOTH are valid roles" run check "$ro"
  ro_proj twoboth
  drop_rows "$ro/AGENTS.md" '^| claude-spec\|^| claude-test\|^| claude-dev\|^| gemini-'
  seed_replace "$ro/AGENTS.md" "| claude-qa | AI | Claude | QA |" "| claude-qa | AI | Claude | BOTH |"
  printf '%s\n' "| claude-b | AI | Claude | BOTH | — |" > "$WORK/.row"
  awk -v rowfile="$WORK/.row" 'BEGIN { getline r < rowfile } { print } /^\| claude-qa \|/ { print r }' "$ro/AGENTS.md" > "$ro/AGENTS.md.tmp" && mv "$ro/AGENTS.md.tmp" "$ro/AGENTS.md"
  assert_success "$label two BOTH agents are enough for Factory mode" run check "$ro"
  ro_proj classic_bad
  drop_rows "$ro/AGENTS.md" '^| claude-\|^| gemini-'
  run_env PROJECT_DOCS_MODE=classic check "$ro" >/dev/null 2>&1 && ok "$label classic mode ignores the roster rules" || bad "$label classic mode applied the roster rules"

#FACTORY_CASES
}

file_hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else cksum "$1"; fi
}

# Current UTC timestamp in the ledger format.
now_ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

# Appends a hand-written ledger entry (header + body lines) for a given agent,
# task, state word and Name. Used to build REVIEW entries directly.
seed_entry() {
  proj="$1"; ts="$2"; agent="$3"; id="$4"; status="$5"; name="$6"; body="$7"
  printf '\n## [%s] | %s | %s | %s | %s\n%b' "$ts" "$agent" "$id" "$status" "$name" "$body" >> "$proj/docs/Agentslog.md"
}

# Appends N filler DONE entries in the exact shape append-log writes, in ONE
# process: 205 separate append-log runs cost minutes under PowerShell. The
# append-log command itself is still exercised by the bad-status assertion.
seed_fill() {
  proj="$1"; id="$2"; count="$3"; fill_ts="$(now_ts)"; i=1
  while [ "$i" -le "$count" ]; do
    printf '\n## [%s] | filler | %s | DONE\n- Summary: filler %s\n- Files: n/a\n- Verify: n/a\n- Follow-up: none\n' "$fill_ts" "$id" "$i"
    i=$((i + 1))
  done >> "$proj/docs/Agentslog.md"
}

# True when FILE (carriage returns stripped, optionally sorted) equals
# $WORK/.golden (sorted the same way). PowerShell ends lines with CRLF and may
# interleave stderr and stdout, so the golden comparisons normalise both.
golden_eq() {
  tr -d '\r' < "$1" > "$WORK/.norm"
  if [ "${2:-}" = "sorted" ]; then
    sort "$WORK/.norm" > "$WORK/.norm.s"; sort "$WORK/.golden" > "$WORK/.golden.s"
    cmp -s "$WORK/.golden.s" "$WORK/.norm.s"
  else
    cmp -s "$WORK/.golden" "$WORK/.norm"
  fi
}

# run with one extra environment variable (VAR=value) for that call only.
run_env() { ( export "$1"; shift; run "$@" ); }

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

# SMOKE_LAUNCHERS (default "sh ps1") picks the launchers to run; SMOKE_ONLY=factory
# skips the pre-factory suite. Two snapshots can run in parallel, one per launcher.
SMOKE_LAUNCHERS="${SMOKE_LAUNCHERS:-sh ps1}"
SMOKE_ONLY="${SMOKE_ONLY:-}"
want_launcher() { case " $SMOKE_LAUNCHERS " in *" $1 "*) return 0 ;; esac; return 1; }

RUNNER="sh_runner"
sh_runner() { sh "$SH_BIN" "$@"; }
if want_launcher sh; then
  echo "### sh: $SH_BIN ###"
  [ "$SMOKE_ONLY" = "factory" ] || run_suite sh
  run_factory_suite sh
fi

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

if ! want_launcher ps1; then
  echo "### ps1: not selected (SMOKE_LAUNCHERS=$SMOKE_LAUNCHERS) ###"
elif [ -n "$PWSH" ]; then
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
  [ "$SMOKE_ONLY" = "factory" ] || run_suite ps1
  run_factory_suite ps1
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
