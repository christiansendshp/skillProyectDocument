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
  grep -q '^project_docs migrate: 8 change(s)$' "$WORK/.out" && ok "$label migrate --factory counts eight changes" || bad "$label change count wrong: $(grep 'project_docs migrate' "$WORK/.out")"
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

  echo "== $label: working memory and the checkpoint command (F06-E03-T02) =="
  wm_proj() { wm="$WORK/${label}_wm_$1"; rm -rf "$wm"; mkdir -p "$wm"; run init "$wm" >/dev/null 2>&1; seed_plan_row "$wm" F09-E01-T01 "Memory task"; wmf="$wm/docs/brain/tasks/F09-E01-T01.md"; }

  wm_proj w_new
  [ ! -e "$wmf" ] && ok "$label a new Factory project has no working memory file yet" || bad "$label working memory exists before any checkpoint"
  assert_success "$label checkpoint creates the working memory of a task" run checkpoint "$wm" claude-dev F09-E01-T01 "wrote the parser" "wire the command"
  grep -q '^project_docs checkpoint: F09-E01-T01 saved$' "$WORK/.out" && ok "$label checkpoint says it saved the task" || bad "$label checkpoint output wrong: $(cat "$WORK/.out")"
  [ -f "$wmf" ] && ok "$label the file is docs/brain/tasks/<TASK-ID>.md" || bad "$label working memory file missing"
  [ "$(head -n 1 "$wmf" | tr -d '\r')" = "# Working memory F09-E01-T01" ] && ok "$label the title carries the task id" || bad "$label title wrong: $(head -n 1 "$wmf")"
  grep -q '^- Step: wrote the parser$' "$wmf" && grep -q '^- Next: wire the command$' "$wmf" && grep -q '^- Attempts: 0$' "$wmf" && ok "$label ## Now holds the step, the next step and the attempts" || bad "$label Now wrong: $(sed -n 3,8p "$wmf")"
  grep -Eq '^- Updated: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$wmf" && ok "$label ## Now carries the update time" || bad "$label Updated wrong"
  grep -Eq '^- [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z claude-dev: wrote the parser$' "$wmf" && ok "$label ## Trail gets a line with time, agent and step" || bad "$label Trail wrong"
  grep -q '^- Used: —$' "$wmf" && grep -q '^- Learned: —$' "$wmf" && ok "$label ## Retro starts empty" || bad "$label Retro wrong"
  tr -d '\r' < "$wmf" | grep -n '^## ' | tr '\n' ' ' | grep -q '^3:## Now 9:## Trail 12:## Retro $' && ok "$label the three sections come in order" || bad "$label sections wrong: $(grep -n '^## ' "$wmf" | tr '\n' ' ')"

  assert_success "$label a second checkpoint updates the file" run checkpoint "$wm" claude-dev F09-E01-T01 "wired the command" "run the full suite"
  [ "$(grep -c '^## Now$' "$wmf")" -eq 1 ] && grep -q '^- Step: wired the command$' "$wmf" && ! grep -q '^- Step: wrote the parser$' "$wmf" && ok "$label ## Now is rewritten, not repeated" || bad "$label Now not rewritten: $(sed -n 3,8p "$wmf")"
  [ "$(grep -c ' claude-dev: ' "$wmf")" -eq 2 ] && grep -n 'wrote the parser' "$wmf" | head -1 | grep -q 'claude-dev: wrote' && ok "$label ## Trail keeps both steps, oldest first" || bad "$label Trail wrong: $(grep claude-dev "$wmf")"
  [ "$(grep -c '^## ' "$wmf")" -eq 3 ] && ok "$label still exactly three sections" || bad "$label section count changed"

  wm_proj w_attempts
  seed_entry "$wm" "$(now_ts)" claude-qa F09-E01-T01 REVIEW "Memory task" '- Summary: reviewed\n- Review: FAIL - not enough\n'
  seed_entry "$wm" "$(now_ts)" claude-qa F09-E01-T01 REVIEW "Memory task" '- Summary: reviewed again\n- Review: FAIL - still not enough\n'
  seed_entry "$wm" "$(now_ts)" claude-qa F09-E01-T02 REVIEW "Other task" '- Summary: other\n- Review: FAIL - other\n'
  run checkpoint "$wm" claude-dev F09-E01-T01 "retry" "fix it" >/dev/null 2>&1
  grep -q '^- Attempts: 2$' "$wmf" && ok "$label Attempts counts the Review: FAIL entries of this task only" || bad "$label Attempts wrong: $(grep Attempts "$wmf")"

  wm_proj w_text
  run checkpoint "$wm" claude-dev F09-E01-T01 'C:\temp\new | step' "next step's text" >/dev/null 2>&1
  grep -qF -- '- Step: C:\temp\new / step' "$wmf" && grep -qF -- "- Next: next step's text" "$wmf" && ok "$label backslashes and apostrophes survive, a bar becomes a slash" || bad "$label text mangled: $(sed -n 3,6p "$wmf")"

  wm_proj w_crlf
  run checkpoint "$wm" claude-dev F09-E01-T01 "first" "second" >/dev/null 2>&1
  sed 's/$/\r/' "$wmf" > "$wmf.tmp" && mv "$wmf.tmp" "$wmf"
  assert_success "$label checkpoint reads a working memory with CRLF line endings" run checkpoint "$wm" claude-dev F09-E01-T01 "third" "fourth"
  tr -d '\r' < "$wmf" | cmp -s - "$wmf" && [ "$(grep -c ' claude-dev: ' "$wmf")" -eq 2 ] && ok "$label the rewritten file is LF and keeps its trail" || bad "$label CRLF rewrite wrong"

  wm_proj w_bad
  assert_failure "$label checkpoint needs four arguments" run checkpoint "$wm" claude-dev F09-E01-T01 "only a step"
  grep -q 'checkpoint requires: agent task-id step next' "$WORK/.out" && ok "$label the usage message names the arguments" || bad "$label usage text wrong: $(cat "$WORK/.out")"
  assert_failure "$label checkpoint refuses an empty step" run checkpoint "$wm" claude-dev F09-E01-T01 " " "next"
  grep -q 'checkpoint requires a non-empty step' "$WORK/.out" && ok "$label the empty step is named" || bad "$label empty step text wrong: $(cat "$WORK/.out")"
  assert_failure "$label checkpoint refuses an empty next step" run checkpoint "$wm" claude-dev F09-E01-T01 "step" " "
  grep -q 'checkpoint requires a non-empty next' "$WORK/.out" && ok "$label the empty next step is named" || bad "$label empty next text wrong: $(cat "$WORK/.out")"
  assert_failure "$label checkpoint refuses a task that is not in the Roadmap" run checkpoint "$wm" claude-dev F99-E99-T99 "step" "next"
  grep -q 'checkpoint failed: F99-E99-T99 not found in docs/Roadmap.md' "$WORK/.out" && ok "$label the missing task is named" || bad "$label missing task text wrong: $(cat "$WORK/.out")"
  [ ! -e "$wm/docs/brain/tasks/F99-E99-T99.md" ] && ok "$label a refused checkpoint creates no file" || bad "$label refused checkpoint created a file"

  wm_proj w_corrupt
  run checkpoint "$wm" claude-dev F09-E01-T01 "a" "b" >/dev/null 2>&1
  sedi '/^## Trail$/d' "$wmf"
  cp "$wmf" "$WORK/.wm_before"
  assert_failure "$label checkpoint refuses a working memory without ## Trail" run checkpoint "$wm" claude-dev F09-E01-T01 "c" "d"
  grep -q 'is not a working memory file (needs ## Now and ## Trail)' "$WORK/.out" && cmp -s "$WORK/.wm_before" "$wmf" && ok "$label the damaged file is reported and left untouched" || bad "$label damaged file handling wrong: $(cat "$WORK/.out")"

  ip_new w_classic
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  seed_plan_row "$ip" F09-E01-T01 "Memory task"
  assert_failure "$label checkpoint does not run in classic mode" run checkpoint "$ip" claude-dev F09-E01-T01 "a" "b"
  grep -q 'checkpoint needs Factory mode' "$WORK/.out" && [ ! -e "$ip/docs/brain" ] && ok "$label classic mode says so and creates nothing" || bad "$label classic checkpoint wrong: $(cat "$WORK/.out")"

  # pause needs a ## Now in Factory mode
  wm_proj w_pause
  run claim "$wm" claude-spec F09-E01-T01 "work" >/dev/null 2>&1
  before="$(grep -c '^## \[' "$wm/docs/Agentslog.md")"
  assert_failure "$label pause is refused when the task has no working memory" run pause "$wm" claude-spec F09-E01-T01 OTRO "stopping"
  grep -q 'pause failed: F09-E01-T01 has no working memory yet (## Now); run checkpoint first' "$WORK/.out" && [ "$(grep -c '^## \[' "$wm/docs/Agentslog.md")" = "$before" ] && ok "$label the refusal says to run checkpoint and writes nothing" || bad "$label pause refusal wrong: $(cat "$WORK/.out")"
  mkdir -p "$wm/docs/brain/tasks" && printf '# Working memory F09-E01-T01\n\n## Trail\n\n## Retro\n' > "$wmf"
  assert_failure "$label a working memory file without ## Now does not count" run pause "$wm" claude-spec F09-E01-T01 OTRO "stopping"
  run checkpoint "$wm" claude-spec F09-E01-T01 "half way" "continue" >/dev/null 2>&1
  rm -f "$wmf"
  run checkpoint "$wm" claude-spec F09-E01-T01 "half way" "continue" >/dev/null 2>&1
  assert_success "$label pause works once the task has a ## Now" run pause "$wm" claude-spec F09-E01-T01 OTRO "stopping"

  ip_new w_pause_classic
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  seed_plan_row "$ip" F09-E01-T01 "Memory task"
  run claim "$ip" someone F09-E01-T01 "work" >/dev/null 2>&1
  assert_success "$label classic pause needs no working memory" run pause "$ip" someone F09-E01-T01 OTRO "stopping"

  # check validates the working memory files
  wm_bad() {  # wm_bad <fixture-name> <sed expression> <expected message>
    wm_proj "$1"
    run checkpoint "$wm" claude-dev F09-E01-T01 "a step" "a next step" >/dev/null 2>&1
    sedi "$2" "$wmf"
    assert_failure "$label check rejects: $3" run check "$wm"
    grep -qF -- "$3" "$WORK/.out" && ok "$label check names it: $3" || bad "$label check does not name '$3': $(grep brain "$WORK/.out" | head -3)"
  }
  wm_proj w_ok
  run checkpoint "$wm" claude-dev F09-E01-T01 "a step" "a next step" >/dev/null 2>&1
  assert_success "$label a working memory written by checkpoint passes check" run check "$wm"
  wm_bad wc_trail '/^## Trail$/d' "is missing section '## Trail'"
  wm_bad wc_retro '/^## Retro$/d' "is missing section '## Retro'"
  wm_bad wc_now '/^## Now$/d' "is missing section '## Now'"
  wm_bad wc_step 's/^- Step:.*/- Step:/' "Now has an empty Step"
  wm_bad wc_next 's/^- Next:.*/- Next: /' "Now has an empty Next"
  wm_bad wc_attempts 's/^- Attempts:.*/- Attempts: x/' "Now has invalid Attempts: x"
  wm_bad wc_updated 's/^- Updated:.*/- Updated: yesterday/' "Now has invalid Updated: yesterday"
  wm_bad wc_nonext '/^- Next:/d' "Now is missing '- Next:'"
  wm_bad wc_title '1s/.*/# Working memory OTHER/' "title must start with '# Working memory F09-E01-T01'"
  wm_proj w_classic_check
  printf 'garbage\n' > "$wmf"
  run_env PROJECT_DOCS_MODE=classic check "$wm" >/dev/null 2>&1 && ok "$label classic mode ignores docs/brain/tasks" || bad "$label classic mode checked a working memory"

  echo "== $label: the phase survives rotate and odd phase lines (F06-E02-T03 retake) =="
  ph_proj() { ph="$WORK/${label}_ph_$1"; rm -rf "$ph"; mkdir -p "$ph"; run init "$ph" >/dev/null 2>&1; seed_plan_row "$ph" F09-E01-T01 "Phase task"; seed_plan_row "$ph" F09-E01-T02 "Review phase task"; }

  ph_proj rot
  seed_replace "$ph/AGENTS.md" "| WIP per agent | 1 |" "| WIP per agent | 2 |"
  seed_entry "$ph" "$(now_ts)" claude-test F09-E01-T01 ASSIGNED "Phase task" '- Assign: claude-dev\n- Phase: GREEN\n'
  seed_entry "$ph" "$(now_ts)" claude-dev F09-E01-T02 IN_PROGRESS "Review phase task" '- Summary: working\n- Verify: pending\n- Phase: GREEN\n'
  seed_entry "$ph" "$(now_ts)" claude-dev F09-E01-T02 REVIEW "Review phase task" '- Summary: ready\n- Verify: exit=0\n- Handoff: claude-qa\n'
  seed_fill "$ph" F09-FILL-01 205
  assert_success "$label rotate runs on a Factory ledger with open phases" run rotate "$ph"
  grep -q '^project_docs rotate: archived ' "$WORK/.out" && ok "$label the ledger was rotated" || bad "$label rotate did not archive: $(cat "$WORK/.out")"
  [ "$(grep -c '^- Phase: GREEN$' "$ph/docs/Agentslog.md")" -ge 2 ] && ok "$label rotate carries the phase of every open task" || bad "$label phase lost in rotate: $(grep '^- Phase' "$ph/docs/Agentslog.md" | tr '\n' ' ')"
  assert_failure "$label after rotate the SPEC agent still cannot take a GREEN task" run claim "$ph" claude-spec F09-E01-T01 "wrong phase"
  grep -q 'phase GREEN of F09-E01-T01 needs DEV' "$WORK/.out" && ok "$label the refusal still knows the phase" || bad "$label phase unknown after rotate: $(cat "$WORK/.out")"
  assert_failure "$label after rotate the QA agent cannot work a GREEN task" run claim "$ph" claude-qa F09-E01-T01 "not their phase"
  assert_success "$label after rotate the DEV agent takes the GREEN task" run claim "$ph" claude-dev F09-E01-T01 "make it pass"
  assert_success "$label after rotate the holder of a task in REVIEW takes it back" run claim "$ph" claude-dev F09-E01-T02 "after review"

  ph_proj odd
  seed_replace "$ph/AGENTS.md" "| claude-spec | AI | Claude | SPEC |" "| claude-spec | AI | Claude | BOTH |"
  seed_entry "$ph" "$(now_ts)" claude-test F09-E01-T01 ASSIGNED "Phase task" '- Assign: claude-spec\n- Phase: FOO\n'
  assert_failure "$label a task in a phase nobody works is refused, even for a BOTH agent" run claim "$ph" claude-spec F09-E01-T01 "odd phase"
  grep -q 'claim failed: F09-E01-T01 is in phase FOO, which has no role (use SPEC, RED, GREEN or REVIEW)' "$WORK/.out" && ok "$label the refusal names the unknown phase" || bad "$label unknown phase text wrong: $(cat "$WORK/.out")"
  seed_entry "$ph" "$(now_ts)" claude-test F09-E01-T02 ASSIGNED "Review phase task" '- Assign: claude-dev\n- phase: GREEN\n'
  assert_failure "$label a lower case phase line is not a phase line" run claim "$ph" claude-dev F09-E01-T02 "lower case"
  grep -q 'phase SPEC of F09-E01-T02 needs SPEC' "$WORK/.out" && ok "$label the task is still in SPEC for both launchers" || bad "$label lower case phase read: $(cat "$WORK/.out")"

  echo "== $label: phases and the advance command with gates (F06-E02-T02) =="
  git_commit() {  # git_commit <dir> <message>: commits everything, with no identity or signing prompts
    git -C "$1" add -A >/dev/null 2>&1 && git -C "$1" -c user.name=smoke -c user.email=smoke@example.com -c commit.gpgsign=false commit -q -m "$2" >/dev/null 2>&1
  }
  adv_proj() {  # adv_proj <name>: a Factory project whose task sits in SPEC with a valid spec and a working memory
    av="$WORK/${label}_av_$1"; rm -rf "$av"; mkdir -p "$av"; run init "$av" >/dev/null 2>&1
    seed_plan_row "$av" F09-E01-T01 "Advance task"
    run claim "$av" claude-spec F09-E01-T01 "write the spec" >/dev/null 2>&1
    mkspec "$av" F09-E01-T01
    run checkpoint "$av" claude-spec F09-E01-T01 "spec written" "ask for review" >/dev/null 2>&1
  }
  adv_reviewed() {  # adv_reviewed [reviewer] [PASS|FAIL]: the spec author hands the spec off, the reviewer answers, the author takes it back
    run handoff "$av" claude-spec F09-E01-T01 "spec ready" "exit=0" "${1:-claude-qa}" >/dev/null 2>&1
    run review "$av" "${1:-claude-qa}" F09-E01-T01 "${2:-PASS}" "spec checked" "exit=0" >/dev/null 2>&1
    run claim "$av" claude-spec F09-E01-T01 "advance it" >/dev/null 2>&1
  }
  adv_count() { grep -c '^## \[' "$av/docs/Agentslog.md" | tr -d ' '; }
  adv_refused() {  # adv_refused <description> <expected text> <advance arguments...>
    ad_desc="$1"; ad_want="$2"; shift 2
    ad_before="$(adv_count)"
    assert_failure "$label $ad_desc" run advance "$av" "$@"
    tr '\n\r' '  ' < "$WORK/.out" | tr -s ' ' | grep -qF -- "$ad_want" && ok "$label $ad_desc: the message names it" || bad "$label $ad_desc: text wrong, wanted [$ad_want]: $(cat "$WORK/.out")"
    [ "$(adv_count)" = "$ad_before" ] && ok "$label $ad_desc: nothing is written" || bad "$label $ad_desc: an entry was written"
  }
  last_entry() { awk '/^## \[/ { buf=""; } { buf = buf $0 "\n" } END { printf "%s", buf }' "$av/docs/Agentslog.md" | tr -d '\r'; }

  # ---- SPEC to RED: the refusals first, none of them changes anything ----------
  adv_proj a_main
  adv_reviewed
  adv_refused "advance refuses a phase the task cannot reach from SPEC" "advance failed: F09-E01-T01 cannot move from SPEC to GREEN" claude-spec F09-E01-T01 GREEN "exit=1"
  adv_refused "advance refuses REVIEW, which is the handoff command" "cannot move from SPEC to REVIEW" claude-spec F09-E01-T01 REVIEW "exit=0"
  adv_refused "advance refuses DONE, which is the done command" "cannot move from SPEC to DONE" claude-spec F09-E01-T01 DONE "exit=0"
  adv_refused "advance phases are upper case" "cannot move from SPEC to red" claude-spec F09-E01-T01 red "exit=0"
  adv_refused "advance needs a verify" "advance requires a non-empty verify" claude-spec F09-E01-T01 RED " "
  adv_refused "advance needs all its arguments" "advance requires: agent task-id next-phase verify [to-agent]" claude-spec F09-E01-T01 RED
  adv_refused "advance refuses a task that is not in the Roadmap" "advance failed: F99-E99-T99 not found in docs/Roadmap.md" claude-spec F99-E99-T99 RED "exit=0"
  adv_refused "only the holder advances a task" "advance failed: F09-E01-T01 is owned by claude-spec, not claude-qa" claude-qa F09-E01-T01 RED "exit=0"
  adv_refused "the agent that takes the next phase needs its role" "advance failed: claude-dev has role DEV, but phase RED of F09-E01-T01 needs TEST (or BOTH)" claude-spec F09-E01-T01 RED "exit=0" claude-dev
  adv_refused "an agent outside the roster cannot take the next phase" "advance failed: nobody is not in the Agent identity table" claude-spec F09-E01-T01 RED "exit=0" nobody
  mv "$av/docs/brain/tasks/F09-E01-T01.md" "$WORK/.wm_keep"
  adv_refused "advance needs the working memory of the task" "advance failed: F09-E01-T01 has no working memory yet (## Now); run checkpoint first" claude-spec F09-E01-T01 RED "exit=0"
  mv "$WORK/.wm_keep" "$av/docs/brain/tasks/F09-E01-T01.md"
  cp "$av/docs/specs/F09-E01-T01.md" "$WORK/.spec_keep"
  rm -f "$av/docs/specs/F09-E01-T01.md"
  adv_refused "the SPEC gate needs the spec file" "advance failed: docs/specs/F09-E01-T01.md does not exist" claude-spec F09-E01-T01 RED "exit=0"
  cp "$WORK/.spec_keep" "$av/docs/specs/F09-E01-T01.md"
  sedi '/^## Tests$/d' "$av/docs/specs/F09-E01-T01.md"
  adv_refused "the SPEC gate refuses a spec with errors" "advance failed: docs/specs/F09-E01-T01.md has errors (see above)" claude-spec F09-E01-T01 RED "exit=0"
  grep -q "is missing section '## Tests'" "$WORK/.out" && ok "$label the SPEC gate shows the spec errors" || bad "$label spec errors not shown: $(cat "$WORK/.out")"
  cp "$WORK/.spec_keep" "$av/docs/specs/F09-E01-T01.md"
  sedi 's/^- Goal:.*/- Goal: UNKNOWN/' "$av/docs/specs/F09-E01-T01.md"
  adv_refused "the SPEC gate refuses a spec with UNKNOWN fields" "advance failed: docs/specs/F09-E01-T01.md still has 1 UNKNOWN field(s)" claude-spec F09-E01-T01 RED "exit=0"
  cp "$WORK/.spec_keep" "$av/docs/specs/F09-E01-T01.md"
  cp "$av/AGENTS.md" "$WORK/.agents_keep"
  drop_rows "$av/AGENTS.md" '^| claude-test'
  adv_refused "advance says when no agent has the role of the next phase" "advance failed: no agent in the Agent identity table has the role TEST for phase RED; pass to-agent" claude-spec F09-E01-T01 RED "exit=0"
  cp "$WORK/.agents_keep" "$av/AGENTS.md"

  assert_success "$label advance moves a reviewed task from SPEC to RED" run advance "$av" claude-spec F09-E01-T01 RED "spec reviewed, exit=0"
  grep -q '^project_docs advance: F09-E01-T01 moved to RED, assigned to claude-test$' "$WORK/.out" && ok "$label advance says where the task went and to whom" || bad "$label advance output wrong: $(cat "$WORK/.out")"
  last_entry > "$WORK/.last"
  grep -q '^## \[.*\] | claude-spec | F09-E01-T01 | ASSIGNED | Advance task$' "$WORK/.last" && grep -q '^- Phase: RED$' "$WORK/.last" && grep -q '^- Assign: claude-test$' "$WORK/.last" && grep -q '^- Verify: spec reviewed, exit=0$' "$WORK/.last" && ok "$label the ledger gets an ASSIGNED entry with the phase, the assignee and the verify" || bad "$label ledger entry wrong: $(cat "$WORK/.last")"
  grep -E '^\| F09-E01-T01 \| Advance task \|' "$av/docs/Roadmap.md" | grep -q 'IN_PROGRESS | claude-test@' && ok "$label the Roadmap row stays IN_PROGRESS and changes owner" || bad "$label Roadmap row wrong: $(grep F09-E01-T01 "$av/docs/Roadmap.md")"
  assert_failure "$label the next phase cannot be claimed by the wrong role" run claim "$av" claude-dev F09-E01-T01 "too soon"
  assert_success "$label the agent with the role of the next phase claims it" run claim "$av" claude-test F09-E01-T01 "write the failing tests"
  [ "$(grep -c '^- Phase: RED$' "$av/docs/Agentslog.md")" -eq 2 ] && ok "$label the claim keeps the RED phase" || bad "$label RED phase lost"

  # ---- the review gate -----------------------------------------------------------
  adv_proj a_noreview
  adv_refused "the SPEC gate needs a review" "advance failed: the spec of F09-E01-T01 has no Review: PASS yet (hand it off to a reviewer first)" claude-spec F09-E01-T01 RED "exit=0"
  adv_reviewed claude-qa FAIL
  adv_refused "a Review: FAIL does not open the gate" "has no Review: PASS yet" claude-spec F09-E01-T01 RED "exit=0"
  run handoff "$av" claude-spec F09-E01-T01 "spec ready again" "exit=0" claude-qa >/dev/null 2>&1
  seed_entry "$av" "$(now_ts)" claude-spec F09-E01-T01 REVIEW "Advance task" '- Summary: reviewed by the author\n- Review: PASS - looks fine to me\n'
  run claim "$av" claude-spec F09-E01-T01 "advance it" >/dev/null 2>&1
  adv_refused "a Review: PASS from the author does not count" "advance failed: the Review: PASS of the spec of F09-E01-T01 comes from claude-spec itself; another agent must review it" claude-spec F09-E01-T01 RED "exit=0"
  seed_replace "$av/AGENTS.md" "| Independent review | YES |" "| Independent review | NO |"
  assert_success "$label Independent review NO drops the review requirement" run advance "$av" claude-spec F09-E01-T01 RED "no review needed here, exit=0"

  adv_proj a_gemini
  adv_reviewed gemini-qa PASS
  assert_success "$label a Review: PASS from any other agent opens the gate" run advance "$av" claude-spec F09-E01-T01 RED "exit=0" claude-test
  grep -q 'assigned to claude-test$' "$WORK/.out" && ok "$label an explicit to-agent is used" || bad "$label to-agent ignored: $(cat "$WORK/.out")"

  adv_proj a_rotate
  adv_reviewed
  seed_fill "$av" F09-FILL-02 205
  assert_success "$label rotate runs on a ledger with a reviewed spec" run rotate "$av"
  grep -q '^project_docs rotate: archived ' "$WORK/.out" && grep -q '^- Spec-pass: claude-qa$' "$av/docs/Agentslog.md" && ok "$label rotate carries who passed the spec review" || bad "$label spec review lost in rotate: $(grep -c 'Spec-pass' "$av/docs/Agentslog.md")"
  assert_success "$label the SPEC gate still opens after rotate" run advance "$av" claude-spec F09-E01-T01 RED "exit=0"

  adv_proj a_inreview
  run handoff "$av" claude-spec F09-E01-T01 "spec ready" "exit=0" claude-qa >/dev/null 2>&1
  adv_refused "advance needs the task in progress" "advance failed: F09-E01-T01 is not IN_PROGRESS (current: REVIEW)" claude-spec F09-E01-T01 RED "exit=0"

  ip_new a_classic
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  assert_failure "$label advance does not run in classic mode" run advance "$ip" claude-spec F09-E01-T01 RED "exit=0"
  grep -q 'advance needs Factory mode' "$WORK/.out" && ok "$label classic mode says so" || bad "$label classic advance text wrong: $(cat "$WORK/.out")"

  # ---- RED to GREEN with git: the tests must fail and be committed -----------------
  red_proj() {  # red_proj <name>: reviewed spec advanced to RED, the test agent has the task and a test file exists
    adv_proj "$1"; adv_reviewed
    run advance "$av" claude-spec F09-E01-T01 RED "spec reviewed, exit=0" >/dev/null 2>&1
    run claim "$av" claude-test F09-E01-T01 "write the failing tests" >/dev/null 2>&1
    mkdir -p "$av/tests/billing"
    printf '#!/bin/sh\nexit 1\n' > "$av/tests/billing/export.spec.sh"
    run checkpoint "$av" claude-test F09-E01-T01 "tests written" "move to GREEN" >/dev/null 2>&1
  }
  red_proj r_git
  git -C "$av" init -q >/dev/null 2>&1
  adv_refused "the RED gate needs an exit marker" "advance failed: the verify of RED needs exit=N with N not 0 (the tests must fail first)" claude-test F09-E01-T01 GREEN "the tests fail"
  adv_refused "the RED gate needs failing tests" "advance failed: RED needs failing tests, but the verify says exit=0" claude-test F09-E01-T01 GREEN "all green, exit=0"
  adv_refused "leading zeros do not turn exit=0 into a failure" "RED needs failing tests, but the verify says exit=0" claude-test F09-E01-T01 GREEN "exit=000"
  adv_refused "the RED gate refuses tests that are not committed" "advance failed: test file 'tests/billing/export.spec.sh' is not committed (commit the failing tests before GREEN)" claude-test F09-E01-T01 GREEN "exit=1"
  git_commit "$av" "tests"
  printf '# edited\n' >> "$av/tests/billing/export.spec.sh"
  adv_refused "the RED gate refuses a test file with uncommitted changes" "is not committed" claude-test F09-E01-T01 GREEN "exit=1"
  git -C "$av" checkout -q -- tests/billing/export.spec.sh >/dev/null 2>&1
  mv "$av/tests/billing/export.spec.sh" "$WORK/.test_keep"
  adv_refused "the RED gate refuses a missing test file" "advance failed: test file 'tests/billing/export.spec.sh' does not exist" claude-test F09-E01-T01 GREEN "exit=1"
  mv "$WORK/.test_keep" "$av/tests/billing/export.spec.sh"
  cp "$av/docs/specs/F09-E01-T01.md" "$WORK/.spec_keep"
  sedi '/^- tests\/billing/d' "$av/docs/specs/F09-E01-T01.md"
  adv_refused "the RED gate needs tests listed in the spec" "advance failed: docs/specs/F09-E01-T01.md ## Tests lists no test file" claude-test F09-E01-T01 GREEN "exit=1"
  cp "$WORK/.spec_keep" "$av/docs/specs/F09-E01-T01.md"
  assert_success "$label advance moves failing, committed tests from RED to GREEN" run advance "$av" claude-test F09-E01-T01 GREEN "2 tests fail: exit=2"
  grep -q '^project_docs advance: F09-E01-T01 moved to GREEN, assigned to claude-dev$' "$WORK/.out" && ok "$label the GREEN phase goes to the DEV agent" || bad "$label GREEN output wrong: $(cat "$WORK/.out")"
  last_entry > "$WORK/.last"
  head_sha="$(git -C "$av" rev-parse HEAD)"
  grep -q "^- Red: $head_sha\$" "$WORK/.last" && grep -q '^- Tests: tests/billing/export.spec.sh$' "$WORK/.last" && ok "$label the entry records the Red sha and the test paths" || bad "$label Red entry wrong: $(cat "$WORK/.last")"

  # ---- without git, and the way back ---------------------------------------------------
  red_proj r_nogit
  assert_success "$label advance works without git" run advance "$av" claude-test F09-E01-T01 GREEN "exit=1"
  grep -q 'WARN: git is not available here' "$WORK/.out" && ok "$label the missing git is a warning" || bad "$label no git warning: $(cat "$WORK/.out")"
  last_entry > "$WORK/.last"
  ! grep -q '^- Red:' "$WORK/.last" && grep -q '^- Tests: tests/billing/export.spec.sh$' "$WORK/.last" && ok "$label no Red sha without git, the test paths are still recorded" || bad "$label no-git entry wrong: $(cat "$WORK/.last")"
  run claim "$av" claude-dev F09-E01-T01 "make it pass" >/dev/null 2>&1
  run checkpoint "$av" claude-dev F09-E01-T01 "started" "implement" >/dev/null 2>&1
  adv_refused "GREEN cannot skip to REVIEW with advance" "cannot move from GREEN to REVIEW" claude-dev F09-E01-T01 REVIEW "exit=0"
  assert_success "$label a wrong test sends the task from GREEN back to SPEC" run advance "$av" claude-dev F09-E01-T01 SPEC "scenario S02 is wrong, exit=1"
  grep -q 'moved to SPEC, assigned to claude-spec$' "$WORK/.out" && ok "$label back to SPEC goes to the SPEC agent" || bad "$label SPEC output wrong: $(cat "$WORK/.out")"
  run claim "$av" claude-spec F09-E01-T01 "fix the spec" >/dev/null 2>&1
  run checkpoint "$av" claude-spec F09-E01-T01 "fixed" "review again" >/dev/null 2>&1
  adv_refused "a task that went back to SPEC needs a new review" "has no Review: PASS yet" claude-spec F09-E01-T01 RED "exit=0"
  adv_reviewed
  assert_success "$label after a new review the task moves to RED again" run advance "$av" claude-spec F09-E01-T01 RED "exit=0"
  run claim "$av" claude-test F09-E01-T01 "rewrite the tests" >/dev/null 2>&1
  run checkpoint "$av" claude-test F09-E01-T01 "rewritten" "go" >/dev/null 2>&1
  run advance "$av" claude-test F09-E01-T01 GREEN "exit=1" >/dev/null 2>&1
  run claim "$av" claude-dev F09-E01-T01 "second try" >/dev/null 2>&1
  run checkpoint "$av" claude-dev F09-E01-T01 "second" "go" >/dev/null 2>&1
  assert_success "$label a bad test sends GREEN back to RED" run advance "$av" claude-dev F09-E01-T01 RED "test S01 asserts the wrong thing, exit=1"
  grep -q 'moved to RED, assigned to claude-test$' "$WORK/.out" && ok "$label back to RED goes to the TEST agent" || bad "$label RED output wrong: $(cat "$WORK/.out")"

  adv_proj t_notdd
  seed_replace "$av/AGENTS.md" "| Require TDD | YES |" "| Require TDD | NO |"
  adv_reviewed
  assert_success "$label Require TDD NO lets a reviewed spec go straight to GREEN" run advance "$av" claude-spec F09-E01-T01 GREEN "spec reviewed, exit=0"
  grep -q 'moved to GREEN, assigned to claude-dev$' "$WORK/.out" && ok "$label the GREEN phase goes to the DEV agent without RED" || bad "$label no-TDD output wrong: $(cat "$WORK/.out")"

  echo "== $label: a spec whose scenarios are all Level NONE reaches GREEN with no failing test (D-08, ADR-091) =="
  mkspec_none() {  # mkspec_none <project> <TASK-ID> [listed test path]: a valid spec whose only scenario is Level NONE; it lists a test file only when one is given
    cat > "$1/docs/specs/$2.md" <<SPEC
# Spec $2 — Document the export command

## Summary

- Goal: Document the export command in the README
- Rules: BR-020
- Tags: readme export docs/
<!-- context:end -->

## Scenarios

| ID | Given | When | Then | Level | Justification |
|---|---|---|---|---|---|
| S01 | The README has no export section | A maintainer reads it | The command is documented | NONE | Docs only, reviewed by the QA agent |

## Tests

${3:+- $3 (S01)}

## Out of scope

- Other commands
SPEC
  }
  none_proj() {  # none_proj <name> <TASK-ID> [listed test path]: a Factory project with a reviewed all-NONE spec, advanced to RED and checkpointed by the test agent
    av="$WORK/${label}_nn_$1"; rm -rf "$av"; mkdir -p "$av"; run init "$av" >/dev/null 2>&1
    seed_plan_row "$av" "$2" "Document the export command"
    run claim "$av" claude-spec "$2" "write the spec" >/dev/null 2>&1
    mkspec_none "$av" "$2" "${3:-}"
    run checkpoint "$av" claude-spec "$2" "spec written" "ask for review" >/dev/null 2>&1
    run handoff "$av" claude-spec "$2" "spec ready" "exit=0" claude-qa >/dev/null 2>&1
    run review "$av" claude-qa "$2" PASS "spec checked" "exit=0" >/dev/null 2>&1
    run claim "$av" claude-spec "$2" "advance it" >/dev/null 2>&1
    run advance "$av" claude-spec "$2" RED "spec reviewed, exit=0" >/dev/null 2>&1
    run claim "$av" claude-test "$2" "no tests apply" >/dev/null 2>&1
    run checkpoint "$av" claude-test "$2" "nothing to test" "move to GREEN" >/dev/null 2>&1
  }
  none_proj n_ok F09-E01-T01
  assert_success "$label an all-NONE spec is valid" run check "$av"
  git -C "$av" init -q >/dev/null 2>&1
  assert_success "$label advance moves an all-NONE spec from RED to GREEN with no failing test" run advance "$av" claude-test F09-E01-T01 GREEN "docs only, no tests apply, exit=0"
  grep -q '^project_docs advance: F09-E01-T01 moved to GREEN, assigned to claude-dev$' "$WORK/.out" && ok "$label the GREEN phase goes to the DEV agent" || bad "$label GREEN output wrong: $(cat "$WORK/.out")"
  av_entry="$(awk '/^## \[/ { buf=""; } { buf = buf $0 "\n" } END { printf "%s", buf }' "$av/docs/Agentslog.md" | tr -d '\r')"
  printf '%s\n' "$av_entry" | grep -q '^- Phase: GREEN$' && ! printf '%s\n' "$av_entry" | grep -q '^- Red:\|^- Tests:' && ok "$label the entry records GREEN and no Red sha or test paths" || bad "$label NONE entry wrong: $av_entry"
  run claim "$av" claude-dev F09-E01-T01 "write the docs" >/dev/null 2>&1
  run checkpoint "$av" claude-dev F09-E01-T01 "docs written" "review" >/dev/null 2>&1
  assert_success "$label a GREEN task with no tests hands off" run handoff "$av" claude-dev F09-E01-T01 "docs written" "README read, exit=0" claude-qa
  assert_success "$label its review PASS needs no 'tests unchanged' note" run review "$av" claude-qa F09-E01-T01 PASS "the README documents the command" "exit=0"
  run retro "$av" claude-dev F09-E01-T01 none none >/dev/null 2>&1
  assert_success "$label a task with an all-NONE spec closes from GREEN" run done "$av" claude-dev F09-E01-T01 "docs written" "README.md" "exit=0"
  assert_success "$label check passes after it" run check "$av"

  none_proj n_listed F09-E01-T01 tests/docs/readme.spec.sh
  adv_refused "an all-NONE spec that lists a test file still needs it to fail first" "advance failed: RED needs failing tests, but the verify says exit=0" claude-test F09-E01-T01 GREEN "docs only, exit=0"
  none_proj n_bug F09-BUG-01
  adv_refused "a BUG row never takes the Level NONE way: its RED is a test that reproduces it" "advance failed: RED needs failing tests, but the verify says exit=0" claude-test F09-BUG-01 GREEN "docs only, exit=0"
  adv_refused "a BUG row with no test listed is refused too" "advance failed: docs/specs/F09-BUG-01.md ## Tests lists no test file" claude-test F09-BUG-01 GREEN "exit=1"
  red_proj n_mixed
  mv "$av/tests/billing/export.spec.sh" "$WORK/.test_keep"
  adv_refused "a spec with a testable scenario is not exempt: S01 and S02 are UNIT" "advance failed: test file 'tests/billing/export.spec.sh' does not exist" claude-test F09-E01-T01 GREEN "exit=1"
  mv "$WORK/.test_keep" "$av/tests/billing/export.spec.sh"

  echo "== $label: spec and working memory edge cases found in review (F06-E02-T01, F06-E03-T02) =="
  # a test path with a parenthesis, a BOM, blank cells, zero-cell rows and files that are not specs
  sp_proj rt_paren
  mkspec "$sp" F09-E01-T01
  seed_replace "$sp/docs/specs/F09-E01-T01.md" "- tests/billing/export.spec.sh (S01, S02)" "- app/(auth)/login.test.ts (S01, S02)"
  assert_success "$label a test path with a parenthesis is a valid Tests entry" run check "$sp"
  seed_replace "$sp/docs/specs/F09-E01-T01.md" "- app/(auth)/login.test.ts (S01, S02)" "- app/(auth)/login.test.ts (S01, S09)"
  assert_failure "$label the scenarios of that entry are read after the last parenthesis" run check "$sp"
  grep -q "Tests entry 'app/(auth)/login.test.ts' refers to unknown scenario S09" "$WORK/.out" && ok "$label only the unknown scenario is reported" || bad "$label paren entry text wrong: $(grep specs "$WORK/.out")"

  sp_proj rt_bom
  mkspec "$sp" F09-E01-T01
  printf '\357\273\277' | cat - "$sp/docs/specs/F09-E01-T01.md" > "$sp/docs/specs/F09-E01-T01.md.tmp" && mv "$sp/docs/specs/F09-E01-T01.md.tmp" "$sp/docs/specs/F09-E01-T01.md"
  assert_success "$label a spec that starts with a UTF-8 byte order mark passes check" run check "$sp"

  sp_proj rt_nbsp
  mkspec "$sp" F09-E01-T01
  seed_replace "$sp/docs/specs/F09-E01-T01.md" "Three invoices exist" "$(printf '\302\240')"
  assert_success "$label a cell of non-breaking spaces is content, not an empty cell" run check "$sp"

  sp_proj rt_bar
  mkspec "$sp" F09-E01-T01
  printf '%s\n' '|' '||' > "$WORK/.bars"
  awk -v barfile="$WORK/.bars" '{ print } /^\| S03 \|/ { while ((getline l < barfile) > 0) print l }' "$sp/docs/specs/F09-E01-T01.md" > "$sp/docs/specs/F09-E01-T01.md.tmp" && mv "$sp/docs/specs/F09-E01-T01.md.tmp" "$sp/docs/specs/F09-E01-T01.md"
  assert_failure "$label a table row made of bars is rejected" run check "$sp"
  [ "$(grep -c "scenario row '' has 1 columns, expected 6" "$WORK/.out")" -eq 2 ] && ok "$label both bar rows count as one empty cell in sh and ps1" || bad "$label bar rows text wrong: $(grep specs "$WORK/.out")"

  sp_proj rt_names
  mkspec "$sp" F09-E01-T01
  printf 'not a spec\n' > "$sp/docs/specs/.draft.md"
  printf 'not a spec\n' > "$sp/docs/specs/NOTES.MD"
  printf 'not a spec\n' > "$sp/docs/specs/notes.txt"
  assert_success "$label only lower case .md files that do not start with a dot are specs" run check "$sp"

  # free text, ids and BOM in the working memory
  wm_proj rt_text
  run checkpoint "$wm" claude-dev "F09-E01-T01 " "two  spaces   kept" "  trimmed ends  " >/dev/null 2>&1
  grep -q '^- Step: two  spaces   kept$' "$wmf" && grep -q '^- Next: trimmed ends$' "$wmf" && ok "$label inner spaces are kept, the ends are trimmed" || bad "$label spaces wrong: $(sed -n 3,6p "$wmf")"
  [ -f "$wmf" ] && ok "$label a task id with a trailing space is trimmed" || bad "$label task id with a space not found"

  wm_proj rt_bom
  run checkpoint "$wm" claude-dev F09-E01-T01 "first" "second" >/dev/null 2>&1
  printf '\357\273\277' | cat - "$wmf" > "$wmf.tmp" && mv "$wmf.tmp" "$wmf"
  assert_success "$label a working memory with a byte order mark passes check" run check "$wm"
  assert_success "$label checkpoint reads a working memory with a byte order mark" run checkpoint "$wm" claude-dev F09-E01-T01 "third" "fourth"
  [ "$(head -c 3 "$wmf" | od -An -tx1 | tr -d ' \n')" != "efbbbf" ] && [ "$(grep -c ' claude-dev: ' "$wmf")" -eq 2 ] && ok "$label the rewritten file has no byte order mark and keeps its trail" || bad "$label BOM rewrite wrong"

  adv_proj rt_verify
  adv_reviewed
  assert_success "$label advance trims its verify" run advance "$av" claude-spec F09-E01-T01 RED "   spec ok, exit=0   "
  last_entry > "$WORK/.last"
  grep -q '^- Verify: spec ok, exit=0$' "$WORK/.last" && ok "$label the ledger verify has no surrounding spaces" || bad "$label verify not trimmed: $(cat "$WORK/.last")"

  echo "== $label: exit markers, unchanged tests, review errors, WIP and attempts (F06-E02-T04, F06-E02-T05, F06-E01-T05) =="
  gr_proj() {  # gr_proj <name> <git|nogit>: a task in GREEN held by claude-dev, with a working memory
    red_proj "$1"
    red_sha=""
    if [ "$2" = "git" ]; then git -C "$av" init -q >/dev/null 2>&1; git_commit "$av" "tests"; red_sha="$(git -C "$av" rev-parse HEAD)"; fi
    run advance "$av" claude-test F09-E01-T01 GREEN "exit=1" >/dev/null 2>&1
    run claim "$av" claude-dev F09-E01-T01 "make it pass" >/dev/null 2>&1
    run checkpoint "$av" claude-dev F09-E01-T01 "started" "implement" >/dev/null 2>&1
  }
  out_has() {  # the text is in the last output, line wraps of the PowerShell error stream folded
    tr '\n\r' '  ' < "$WORK/.out" | tr -s ' ' | grep -qF -- "$1"
  }
  refused() {  # refused <description> <expected text> <command...>
    rf_desc="$1"; rf_want="$2"; shift 2
    rf_before="$(grep -c '^## \[' "$av/docs/Agentslog.md" | tr -d ' ')"
    assert_failure "$label $rf_desc" run "$@"
    out_has "$rf_want" && ok "$label $rf_desc: the message names it" || bad "$label $rf_desc: text wrong, wanted [$rf_want]: $(cat "$WORK/.out")"
    [ "$(grep -c '^## \[' "$av/docs/Agentslog.md" | tr -d ' ')" = "$rf_before" ] && ok "$label $rf_desc: nothing is written" || bad "$label $rf_desc: an entry was written"
  }

  # ---- handoff: the verify and the tests recorded at RED -----------------------------------
  gr_proj h_git git
  refused "handoff needs an exit marker in Factory mode" "handoff failed: the verify needs exit=N (exit=0 when the checks pass)" handoff "$av" claude-dev F09-E01-T01 "implemented" "the tests pass" claude-qa
  refused "handoff refuses a failing verify" "handoff failed: the verify says exit=1, not exit=0" handoff "$av" claude-dev F09-E01-T01 "implemented" "2 failed: exit=1" claude-qa
  mv "$av/docs/brain/tasks/F09-E01-T01.md" "$WORK/.wm_keep"
  refused "handoff needs the working memory" "handoff failed: F09-E01-T01 has no working memory yet (## Now); run checkpoint first" handoff "$av" claude-dev F09-E01-T01 "implemented" "exit=0" claude-qa
  mv "$WORK/.wm_keep" "$av/docs/brain/tasks/F09-E01-T01.md"
  printf '# edited in GREEN\n' >> "$av/tests/billing/export.spec.sh"
  refused "handoff refuses a test file changed after RED (uncommitted)" "handoff failed: test file(s) changed since RED ($red_sha): tests/billing/export.spec.sh; a wrong test goes back to SPEC with advance" handoff "$av" claude-dev F09-E01-T01 "implemented" "exit=0" claude-qa
  git_commit "$av" "weaken the test"
  refused "handoff refuses a test file changed after RED (committed)" "test file(s) changed since RED" handoff "$av" claude-dev F09-E01-T01 "implemented" "exit=0" claude-qa
  git -C "$av" checkout -q "$red_sha" -- tests/billing/export.spec.sh >/dev/null 2>&1
  git_commit "$av" "restore the test"
  assert_success "$label handoff passes once the tests are as they were at RED" run handoff "$av" claude-dev F09-E01-T01 "implemented" "all pass, exit=0" claude-qa
  refused "review PASS needs an exit marker" "review failed: the verify needs exit=N (exit=0 when the checks pass)" review "$av" claude-qa F09-E01-T01 PASS "looks good" "ran the suite"
  refused "review PASS needs exit=0" "review failed: the verify says exit=3, not exit=0" review "$av" claude-qa F09-E01-T01 PASS "looks good" "exit=3"
  assert_success "$label review PASS with git needs no note about the tests" run review "$av" claude-qa F09-E01-T01 PASS "looks good" "exit=0"
  refused "done needs an exit marker" "done failed: the verify needs exit=N (exit=0 when the checks pass)" done "$av" claude-dev F09-E01-T01 "implemented" "src/" "all green"
  refused "done refuses a failing verify" "done failed: the verify says exit=1, not exit=0" done "$av" claude-dev F09-E01-T01 "implemented" "src/" "exit=1"
  run retro "$av" claude-dev F09-E01-T01 none none >/dev/null 2>&1
  assert_success "$label done closes a reviewed task with exit=0" run done "$av" claude-dev F09-E01-T01 "implemented" "src/" "suite passes, exit=0"

  red_proj h_red
  refused "handoff is not for a task in RED" "handoff failed: F09-E01-T01 is in phase RED; move it with advance" handoff "$av" claude-test F09-E01-T01 "tests ready" "exit=0" claude-qa

  adv_proj h_spec
  refused "a spec handoff needs an exit marker too" "handoff failed: the verify needs exit=N" handoff "$av" claude-spec F09-E01-T01 "spec ready" "spec checked" claude-qa

  gr_proj h_nogit nogit
  assert_success "$label handoff without git warns that the tests cannot be checked" run handoff "$av" claude-dev F09-E01-T01 "implemented" "exit=0" claude-qa
  grep -q "WARN: git is not available here, so the tests cannot be checked as unchanged since RED; the reviewer must write 'tests unchanged' in the review note" "$WORK/.out" && ok "$label the warning tells the reviewer what to write" || bad "$label no-git warning wrong: $(cat "$WORK/.out")"
  refused "review PASS without git needs 'tests unchanged' in the note" "review failed: git could not check the tests of F09-E01-T01; the note must say 'tests unchanged'" review "$av" claude-qa F09-E01-T01 PASS "looks good" "exit=0"
  assert_success "$label review PASS with 'tests unchanged' in the note" run review "$av" claude-qa F09-E01-T01 PASS "Looks good, Tests Unchanged since RED" "exit=0"

  gr_proj h_rotate git
  seed_fill "$av" F09-FILL-03 205
  assert_success "$label rotate runs on a GREEN task" run rotate "$av"
  grep -q "^- Red: $red_sha\$" "$av/docs/Agentslog.md" && grep -q '^- Tests: tests/billing/export.spec.sh$' "$av/docs/Agentslog.md" && ok "$label rotate carries the Red sha and the test paths" || bad "$label Red lost in rotate: $(grep -E '^- (Red|Tests)' "$av/docs/Agentslog.md" | tr '\n' ' ')"
  printf '# edited after rotate\n' >> "$av/tests/billing/export.spec.sh"
  refused "the tests stay protected after rotate" "handoff failed: test file(s) changed since RED" handoff "$av" claude-dev F09-E01-T01 "implemented" "exit=0" claude-qa

  # ---- review and done: warnings become errors in Factory mode -----------------------------
  gr_proj r_self git
  run handoff "$av" claude-dev F09-E01-T01 "implemented" "exit=0" claude-qa >/dev/null 2>&1
  refused "a self-review is an error in Factory mode" "review failed: claude-dev developed F09-E01-T01; an independent review is required" review "$av" claude-dev F09-E01-T01 PASS "mine is fine" "exit=0"
  refused "a reviewer must have the QA role for a GREEN handoff" "review failed: claude-test has role TEST, but a review of phase GREEN needs QA (or BOTH)" review "$av" claude-test F09-E01-T01 PASS "fine" "exit=0"
  refused "a reviewer must be in the roster" "review failed: nobody is not in the Agent identity table; Factory mode needs a role for each agent" review "$av" nobody F09-E01-T01 PASS "fine" "exit=0"
  seed_replace "$av/AGENTS.md" "| Independent review | YES |" "| Independent review | NO |"
  seed_replace "$av/AGENTS.md" "| claude-dev | AI | Claude | DEV |" "| claude-dev | AI | Claude | BOTH |"
  assert_success "$label Independent review NO turns the self-review back into a warning" run review "$av" claude-dev F09-E01-T01 PASS "self checked" "exit=0"
  grep -q 'WARN: self-review: claude-dev reviews its own handoff of F09-E01-T01' "$WORK/.out" && ok "$label the self-review warning is the classic one" || bad "$label no self-review warning: $(cat "$WORK/.out")"

  adv_proj r_spec
  printf '%s\n' "| claude-spec2 | AI | Claude | SPEC | — |" > "$WORK/.row"
  awk -v rowfile="$WORK/.row" 'BEGIN { getline r < rowfile } { print } /^\| claude-spec \|/ { print r }' "$av/AGENTS.md" > "$av/AGENTS.md.tmp" && mv "$av/AGENTS.md.tmp" "$av/AGENTS.md"
  run handoff "$av" claude-spec F09-E01-T01 "spec ready" "exit=0" claude-spec2 >/dev/null 2>&1
  assert_success "$label an agent with the SPEC role may review a spec" run review "$av" claude-spec2 F09-E01-T01 PASS "spec reads well" "exit=0"

  adv_proj d_none
  refused "done needs a review in Factory mode" "done failed: F09-E01-T01 has no Review: PASS yet (status IN_PROGRESS, last review none)" done "$av" claude-spec F09-E01-T01 "spec" "docs/" "exit=0"
  run handoff "$av" claude-spec F09-E01-T01 "spec ready" "exit=0" claude-qa >/dev/null 2>&1
  refused "done refuses a handoff nobody reviewed" "done failed: F09-E01-T01 has no Review: PASS yet (status REVIEW, last review none)" done "$av" claude-spec F09-E01-T01 "spec" "docs/" "exit=0"
  run review "$av" claude-qa F09-E01-T01 FAIL "unclear" "exit=1" >/dev/null 2>&1
  refused "done refuses after a Review: FAIL" "last review FAIL" done "$av" claude-spec F09-E01-T01 "spec" "docs/" "exit=0"
  seed_plan_row "$av" F09-E01-T09 "A task nobody claimed"
  refused "done refuses a task with no ledger entries" "done failed: F09-E01-T09 has no ledger entries; claim it first" done "$av" claude-spec F09-E01-T09 "nothing" "docs/" "exit=0"

  ip_new d_classic
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  seed_plan_row "$ip" F09-E01-T01 "Classic task"
  run claim "$ip" someone F09-E01-T01 "work" >/dev/null 2>&1
  run handoff "$ip" someone F09-E01-T01 "ready" "tests ran fine" reviewer >/dev/null 2>&1
  assert_success "$label classic mode still lets a task close without a passing review" run done "$ip" someone F09-E01-T01 "done" "src/" "none"
  grep -q 'WARN: F09-E01-T01: closing without a passing review (the handoff is still pending)' "$WORK/.out" && grep -q 'says nothing about what was checked' "$WORK/.out" && ok "$label classic mode only warns about both" || bad "$label classic done warnings wrong: $(cat "$WORK/.out")"

  # ---- claim: WIP per agent ------------------------------------------------------------------
  wp_proj() { av="$WORK/${label}_wp_$1"; rm -rf "$av"; mkdir -p "$av"; run init "$av" >/dev/null 2>&1; seed_plan_row "$av" F09-E01-T01 "First wip task"; seed_plan_row "$av" F09-E01-T02 "Second wip task"; seed_plan_row "$av" F09-E01-T03 "Third wip task"; }
  wp_proj one
  run claim "$av" claude-spec F09-E01-T01 "first" >/dev/null 2>&1
  refused "a second task is refused when WIP per agent is 1" "claim failed: claude-spec already has 1 task(s) in progress (WIP per agent is 1): F09-E01-T01" claim "$av" claude-spec F09-E01-T02 "second"
  assert_success "$label the holder may claim its own task again" run claim "$av" claude-spec F09-E01-T01 "again"
  seed_replace "$av/AGENTS.md" "| WIP per agent | 1 |" "| WIP per agent | 2 |"
  assert_success "$label WIP per agent 2 allows a second task" run claim "$av" claude-spec F09-E01-T02 "second"
  refused "the limit still applies at 2" "claim failed: claude-spec already has 2 task(s) in progress (WIP per agent is 2): F09-E01-T01, F09-E01-T02" claim "$av" claude-spec F09-E01-T03 "third"
  run checkpoint "$av" claude-spec F09-E01-T01 "spec" "review" >/dev/null 2>&1
  run handoff "$av" claude-spec F09-E01-T01 "spec ready" "exit=0" claude-qa >/dev/null 2>&1
  assert_success "$label a task waiting for review does not count as work in progress" run claim "$av" claude-spec F09-E01-T03 "third"
  ip_new wp_classic
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  seed_plan_row "$ip" F09-E01-T01 "First wip task"; seed_plan_row "$ip" F09-E01-T02 "Second wip task"
  run claim "$ip" someone F09-E01-T01 "first" >/dev/null 2>&1
  assert_success "$label classic mode has no WIP limit" run claim "$ip" someone F09-E01-T02 "second"

  # ---- claim: fix attempts ---------------------------------------------------------------------
  at_proj() {  # at_proj <name> <fails>: a GREEN task of claude-dev handed off and failed <fails> times
    av="$WORK/${label}_at_$1"; rm -rf "$av"; mkdir -p "$av"; run init "$av" >/dev/null 2>&1
    seed_plan_row "$av" F09-E01-T01 "Attempts task"
    seed_entry "$av" "$(now_ts)" claude-test F09-E01-T01 ASSIGNED "Attempts task" '- Assign: claude-dev\n- Phase: GREEN\n'
    at_i=0
    while [ "$at_i" -lt "$2" ]; do
      seed_entry "$av" "$(now_ts)" claude-dev F09-E01-T01 IN_PROGRESS "Attempts task" '- Summary: try\n- Verify: pending\n- Phase: GREEN\n'
      seed_entry "$av" "$(now_ts)" claude-dev F09-E01-T01 REVIEW "Attempts task" '- Summary: ready\n- Verify: exit=0\n- Handoff: claude-qa\n'
      seed_entry "$av" "$(now_ts)" claude-qa F09-E01-T01 REVIEW "Attempts task" '- Summary: review\n- Review: FAIL - not yet\n'
      at_i=$((at_i + 1))
    done
  }
  at_proj two 2
  assert_success "$label two failed reviews are below the default limit of three" run claim "$av" claude-dev F09-E01-T01 "third try"
  run checkpoint "$av" claude-dev F09-E01-T01 "trying" "go" >/dev/null 2>&1
  grep -q '^- Attempts: 2$' "$av/docs/brain/tasks/F09-E01-T01.md" && ok "$label the working memory shows two attempts" || bad "$label attempts wrong: $(grep Attempts "$av/docs/brain/tasks/F09-E01-T01.md")"
  at_proj three 3
  run checkpoint "$av" claude-dev F09-E01-T01 "stuck" "ask for help" >/dev/null 2>&1
  grep -q '^- Attempts: 3$' "$av/docs/brain/tasks/F09-E01-T01.md" && ok "$label the working memory shows three attempts" || bad "$label attempts wrong: $(grep Attempts "$av/docs/brain/tasks/F09-E01-T01.md")"
  refused "the claim after the third failed review is refused" "claim failed: F09-E01-T01 used 3 of 3 fix attempts; pause it with BLOQUEO and write the lesson, or raise Max fix attempts" claim "$av" claude-dev F09-E01-T01 "fourth try"
  assert_success "$label the holder pauses a task in REVIEW with BLOQUEO" run pause "$av" claude-dev F09-E01-T01 BLOQUEO "three reviews failed"
  assert_success "$label after the BLOQUEO the attempts start again" run claim "$av" claude-dev F09-E01-T01 "after the lesson"
  at_proj max 2
  seed_replace "$av/AGENTS.md" "| Max fix attempts | 3 |" "| Max fix attempts | 2 |"
  refused "Max fix attempts is read from the table" "claim failed: F09-E01-T01 used 2 of 2 fix attempts" claim "$av" claude-dev F09-E01-T01 "again"
  at_proj back 1
  seed_replace "$av/AGENTS.md" "| Max fix attempts | 3 |" "| Max fix attempts | 2 |"
  seed_entry "$av" "$(now_ts)" claude-dev F09-E01-T01 ASSIGNED "Attempts task" '- Assign: claude-test\n- Phase: RED\n'
  refused "a move from GREEN back to RED counts as an attempt" "claim failed: F09-E01-T01 used 2 of 2 fix attempts" claim "$av" claude-test F09-E01-T01 "rewrite the tests"
  at_proj rot 3
  seed_replace "$av/AGENTS.md" "| Max fix attempts | 3 |" "| Max fix attempts | 5 |"
  seed_fill "$av" F09-FILL-04 205
  run rotate "$av" >/dev/null 2>&1
  # the carried REVIEW entry brings its own FAIL line, so the carried count is one less
  grep -q '^- Attempts: 2$' "$av/docs/Agentslog.md" && ok "$label rotate carries the attempts, one less than the FAIL line it also carries" || bad "$label attempts lost in rotate: $(grep Attempts "$av/docs/Agentslog.md" | tr '\n' ' ')"
  run checkpoint "$av" claude-dev F09-E01-T01 "after rotate" "go" >/dev/null 2>&1
  grep -q '^- Attempts: 3$' "$av/docs/brain/tasks/F09-E01-T01.md" && ok "$label the count survives rotate" || bad "$label count after rotate wrong: $(grep Attempts "$av/docs/brain/tasks/F09-E01-T01.md")"
  ip_new at_classic
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  seed_plan_row "$ip" F09-E01-T01 "Attempts task"
  seed_entry "$ip" "$(now_ts)" a F09-E01-T01 REVIEW "Attempts task" '- Summary: r\n- Verify: v\n- Review: FAIL - x\n'
  seed_entry "$ip" "$(now_ts)" a F09-E01-T01 REVIEW "Attempts task" '- Summary: r\n- Verify: v\n- Review: FAIL - x\n'
  seed_entry "$ip" "$(now_ts)" a F09-E01-T01 REVIEW "Attempts task" '- Summary: r\n- Verify: v\n- Review: FAIL - x\n'
  assert_success "$label classic mode has no attempts limit" run claim "$ip" a F09-E01-T01 "again"

  # classic mode: the Factory lines of the ledger mean nothing, and rotate carries none of them (BR-008)
  ip_new cx_rotate
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  seed_plan_row "$ip" F09-E01-T01 "Classic failed task"
  seed_plan_row "$ip" F09-E01-T02 "Classic passed task"
  seed_entry "$ip" "$(now_ts)" a F09-E01-T01 IN_PROGRESS "Classic failed task" '- Summary: work\n- Verify: pending\n- Phase: GREEN\n'
  seed_entry "$ip" "$(now_ts)" a F09-E01-T01 REVIEW "Classic failed task" '- Summary: ready\n- Verify: tests\n- Handoff: b\n- Red: abc123\n- Tests: t.sh\n'
  seed_entry "$ip" "$(now_ts)" b F09-E01-T01 REVIEW "Classic failed task" '- Summary: review\n- Review: FAIL - no\n- Attempts: 7\n- Spec-pass: b\n'
  seed_entry "$ip" "$(now_ts)" a F09-E01-T02 IN_PROGRESS "Classic passed task" '- Summary: work\n- Verify: pending\n'
  seed_entry "$ip" "$(now_ts)" a F09-E01-T02 REVIEW "Classic passed task" '- Summary: ready\n- Verify: tests\n- Handoff: b\n'
  seed_entry "$ip" "$(now_ts)" b F09-E01-T02 REVIEW "Classic passed task" '- Summary: review\n- Review: PASS - good\n'
  seed_fill "$ip" F09-FILL-05 205
  assert_success "$label rotate runs on a classic ledger with reviewed tasks" run rotate "$ip"
  ! grep -Eq '^- (Phase|Spec-pass|Red|Tests|Attempts):' "$ip/docs/Agentslog.md" && ok "$label classic rotate carries no Factory line" || bad "$label classic rotate carried: $(grep -E '^- (Phase|Spec-pass|Red|Tests|Attempts):' "$ip/docs/Agentslog.md" | tr '\n' ' ')"
  grep -q '^- Review: PASS - carried forward' "$ip/docs/Agentslog.md" && grep -q '^- Review: FAIL - carried forward' "$ip/docs/Agentslog.md" && ok "$label classic rotate still carries the reviews" || bad "$label classic reviews lost"

  echo "== $label: recall, learn, retro and brain gc (F06-E03-T03, F06-E03-T04, F06-E03-T05) =="
  bn_proj() {  # bn_proj <name>: a Factory project with one task whose row has real words in its description
    bn="$WORK/${label}_bn_$1"; rm -rf "$bn"; mkdir -p "$bn"; run init "$bn" >/dev/null 2>&1
    seed_plan_row "$bn" F09-E01-T01 "Export invoices as CSV"
    seed_replace "$bn/docs/Roadmap.md" "| F09-E01-T01 | Export invoices as CSV | details | works |" "| F09-E01-T01 | Export invoices as CSV | Export the invoice list from billing as a CSV file | Totals match |"
    bnb="$bn/docs/Brain.md"
  }
  set_setting() {  # set_setting <project> "<Name> | <Value>": adds a row right after Mode; the latest one wins
    ss_f="$1/AGENTS.md"
    awk -v row="| $2 |" '{ print } /^\| Mode \| FACTORY \|$/ { print row }' "$ss_f" > "$ss_f.tmp" && mv "$ss_f.tmp" "$ss_f"
  }
  brain_refused() {  # brain_refused <description> <expected text> <command...>
    br_desc="$1"; br_want="$2"; shift 2
    br_before="$(cat "$bnb" 2>/dev/null | cksum)"
    assert_failure "$label $br_desc" run "$@"
    out_has "$br_want" && ok "$label $br_desc: the message names it" || bad "$label $br_desc: text wrong, wanted [$br_want]: $(cat "$WORK/.out")"
    [ "$(cat "$bnb" 2>/dev/null | cksum)" = "$br_before" ] && ok "$label $br_desc: the brain is untouched" || bad "$label $br_desc: the brain changed"
  }

  # ---- learn ------------------------------------------------------------------------------------------
  bn_proj l_main
  assert_success "$label learn adds a lesson to the brain" run learn "$bn" claude-dev F09-E01-T01 PITFALL "Invoice totals drift when rounding early" "Invoice Rounding" "Round once at the end of the sum"
  grep -q '^project_docs learn: LRN-004 added$' "$WORK/.out" && ok "$label learn says which id it used" || bad "$label learn output wrong: $(cat "$WORK/.out")"
  grep -qxF '| LRN-004 | Invoice totals drift when rounding early | PITFALL | invoice rounding | Round once at the end of the sum | log:F09-E01-T01 | HYPOTHESIS | 0 | — |' "$bnb" && ok "$label the new row has the trigger in lower case, the task as evidence and no hits" || bad "$label row wrong: $(grep LRN-004 "$bnb")"
  grep -q '^- Entries: 4 of 80$' "$bnb" && ok "$label the entry count in the summary follows" || bad "$label summary count wrong: $(grep Entries: "$bnb")"
  assert_success "$label the brain with the new row passes check" run check "$bn"
  assert_success "$label a second lesson gets the next id" run learn "$bn" claude-dev F09-E01-T01 MAP "Billing module map" "src/billing/ billing" "Billing code lives in src/billing"
  grep -q 'LRN-005 added' "$WORK/.out" && ok "$label ids go up by one" || bad "$label second id wrong: $(cat "$WORK/.out")"
  assert_success "$label a DEFAULT lesson may fire on every task" run learn "$bn" claude-dev F09-E01-T01 DEFAULT "Prefer small commits" "*" "Commit each phase on its own"
  mkdir -p "$bn/docs/history" && printf '| LRN-020 | Archived row | PATTERN | x | y | z | HYPOTHESIS | 0 | — |\n' > "$bn/docs/history/brain-archive-20260101-001.md"
  assert_success "$label an archived id is never reused" run learn "$bn" claude-dev F09-E01-T01 RECIPE "Run the export spec first" "export csv" "Run one spec file before the suite"
  grep -q 'LRN-021 added' "$WORK/.out" && ok "$label the next id is above the archived ones" || bad "$label id after archive wrong: $(cat "$WORK/.out")"
  brain_refused "learn refuses a bar in a text" "learn failed: no argument may contain a vertical bar" learn "$bn" claude-dev F09-E01-T01 PITFALL "bad|name" "x" "y"
  brain_refused "learn refuses an unknown kind" "learn failed: kind must be PITFALL, PATTERN, RECIPE, DEFAULT or MAP" learn "$bn" claude-dev F09-E01-T01 TIP "A name" "x" "y"
  brain_refused "learn refuses a name over ten words" "learn failed: the name is 11 words, over the 10-word limit" learn "$bn" claude-dev F09-E01-T01 PITFALL "one two three four five six seven eight nine ten eleven" "x" "y"
  brain_refused "learn refuses an empty trigger" "learn failed: the trigger is empty" learn "$bn" claude-dev F09-E01-T01 PITFALL "A name" " " "y"
  brain_refused "learn refuses an empty lesson" "learn failed: the lesson is empty" learn "$bn" claude-dev F09-E01-T01 PITFALL "A name" "x" " "
  brain_refused "learn keeps the * trigger for DEFAULT lessons" "learn failed: the trigger * is only for DEFAULT lessons" learn "$bn" claude-dev F09-E01-T01 PITFALL "Another name" "*" "y"
  brain_refused "learn refuses a task that does not exist" "learn failed: F99-E99-T99 is not a task of this project" learn "$bn" claude-dev F99-E99-T99 PITFALL "Yet another" "x" "y"
  brain_refused "learn refuses a name the brain already has" "learn failed: LRN-004 already has the name \"invoice TOTALS drift when rounding early\"" learn "$bn" claude-dev F09-E01-T01 PITFALL "invoice TOTALS drift when rounding early" "x" "y"
  brain_refused "learn needs all its arguments" "learn requires: agent task-id kind name trigger lesson" learn "$bn" claude-dev F09-E01-T01 PITFALL "A name"
  bn_proj l_cap
  set_setting "$bn" "Brain max entries | 4"
  assert_success "$label learn works up to the limit" run learn "$bn" claude-dev F09-E01-T01 PITFALL "Fourth row" "x" "y"
  brain_refused "learn refuses past Brain max entries" "learn failed: the brain already has 4 entries (Brain max entries is 4); run rotate to archive the least used" learn "$bn" claude-dev F09-E01-T01 PITFALL "Fifth row" "x" "y"
  ip_new l_classic
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  assert_failure "$label learn does not run in classic mode" run learn "$ip" a F09-E01-T01 PITFALL "A name" "x" "y"
  out_has "learn needs Factory mode" && ok "$label classic mode says so" || bad "$label classic learn text wrong: $(cat "$WORK/.out")"

  # ---- recall ----------------------------------------------------------------------------------------------
  bn_proj rc_main
  run claim "$bn" claude-spec F09-E01-T01 "write the spec" >/dev/null 2>&1
  mkspec "$bn" F09-E01-T01
  run checkpoint "$bn" claude-spec F09-E01-T01 "wrote the parser" "wire the command" >/dev/null 2>&1
  run learn "$bn" claude-dev F09-E01-T01 PITFALL "Invoice totals drift when rounding early" "invoice rounding" "Round once at the end of the sum" >/dev/null 2>&1
  run learn "$bn" claude-dev F09-E01-T01 MAP "Billing module map" "src/billing/ billing" "Billing code lives in src/billing" >/dev/null 2>&1
  run learn "$bn" claude-dev F09-E01-T01 RECIPE "Run only the export tests first" "export csv" "Run one spec file before the suite" >/dev/null 2>&1
  run learn "$bn" claude-dev F09-E01-T01 PITFALL "Payroll batch size limit" "payroll batch" "Batches over 500 rows time out" >/dev/null 2>&1
  run learn "$bn" claude-dev F09-E01-T01 PATTERN "A regression test for every bug" "regression" "Write the failing test first" >/dev/null 2>&1
  seed_replace "$bnb" "Run one spec file before the suite | log:F09-E01-T01 | HYPOTHESIS | 0 |" "Run one spec file before the suite | log:F09-E01-T01 | HYPOTHESIS | 3 |"
  assert_success "$label recall prints the task, the spec summary, the working memory and the matching brain rows" run recall "$bn" F09-E01-T01
  tr -d '\r' < "$WORK/.out" | grep -v '^- Updated:' > "$WORK/.recall"
  printf '%s\n' "## Task" "- ID: F09-E01-T01" "- Name: Export invoices as CSV" "- Description: Export the invoice list from billing as a CSV file" "- Acceptance check: Totals match" "- Status: IN_PROGRESS; Owner: $(grep -E '^\| F09-E01-T01 \|' "$bn/docs/Roadmap.md" | awk -F'|' '{ o=$7; gsub(/^ +| +$/, "", o); print o }'); Depends on: —" "## Spec summary" "- Goal: Let a user export the invoice list as CSV" "- Rules: BR-020" "- Tags: invoice export csv src/billing/" "## Now" "- Step: wrote the parser" "- Next: wire the command" "- Attempts: 0" "## Brain" \
    "| LRN-006 | Run only the export tests first | RECIPE | export csv | Run one spec file before the suite | log:F09-E01-T01 | HYPOTHESIS | 3 | — |" \
    "| LRN-005 | Billing module map | MAP | src/billing/ billing | Billing code lives in src/billing | log:F09-E01-T01 | HYPOTHESIS | 0 | — |" \
    "$(grep '^| LRN-001 ' "$bnb")" "$(grep '^| LRN-002 ' "$bnb")" \
    "| LRN-004 | Invoice totals drift when rounding early | PITFALL | invoice rounding | Round once at the end of the sum | log:F09-E01-T01 | HYPOTHESIS | 0 | — |" \
    "recall: 5 of 8 brain entries shown" > "$WORK/.golden"
  golden_eq "$WORK/.recall" && ok "$label recall output: matching rows only, best score first, hits then id break ties" || { bad "$label recall output differs"; diff "$WORK/.golden" "$WORK/.recall" | head -10; }
  cp "$WORK/.recall" "$WORK/.recall1"
  run recall "$bn" F09-E01-T01 >/dev/null 2>&1; run recall "$bn" F09-E01-T01 > "$WORK/.out" 2>&1
  tr -d '\r' < "$WORK/.out" | grep -v '^- Updated:' | cmp -s - "$WORK/.recall1" && ok "$label recall is deterministic" || bad "$label recall changed between two runs"
  set_setting "$bn" "Recall budget bytes | 1000"
  assert_success "$label recall with a small budget still succeeds" run recall "$bn" F09-E01-T01
  rbytes="$(tr -d '\r' < "$WORK/.out" | wc -c | tr -d ' ')"
  [ "$rbytes" -le 1000 ] && ok "$label recall output is $rbytes bytes, within the budget of 1000" || bad "$label recall output is $rbytes bytes, over 1000"
  rshown="$(tr -d '\r' < "$WORK/.out" | tail -n 1 | sed 's/^recall: \([0-9]*\) of .*/\1/')"
  rrows="$(tr -d '\r' < "$WORK/.out" | grep -c '^| LRN-')"
  [ "$rshown" = "$rrows" ] && [ "$rshown" -ge 1 ] && [ "$rshown" -lt 5 ] && ok "$label whole rows were dropped from the end, $rshown of the 5 matches stay, the count agrees" || bad "$label rows shown $rshown but $rrows printed"
  tr -d '\r' < "$WORK/.out" | grep '^| LRN-' | while IFS= read -r rline; do grep -qxF -- "$rline" "$bnb" || echo "cut: $rline"; done > "$WORK/.cut"
  [ ! -s "$WORK/.cut" ] && ok "$label every printed row is a whole row of the brain" || bad "$label a row was cut: $(cat "$WORK/.cut")"
  set_setting "$bn" "Recall budget bytes | 100"
  assert_failure "$label a budget the task parts do not fit in is an error" run recall "$bn" F09-E01-T01
  out_has "over the Recall budget bytes of 100; shorten the spec Summary or the working memory" && ok "$label the error tells what to shorten" || bad "$label budget error text wrong: $(cat "$WORK/.out")"
  bn_proj rc_bare
  assert_success "$label recall works for a task with no spec and no working memory" run recall "$bn" F09-E01-T01
  out_has "(no spec yet)" && out_has "(no working memory yet)" && ok "$label the missing parts are said, not skipped" || bad "$label bare recall wrong: $(cat "$WORK/.out")"
  tr -d '\r' < "$WORK/.out" | tail -n 1 | grep -q '^recall: [0-9]* of 3 brain entries shown$' && ok "$label the last line counts the brain rows" || bad "$label last line wrong: $(tail -n 2 "$WORK/.out")"
  assert_failure "$label recall refuses a task that is not in the Roadmap" run recall "$bn" F99-E99-T99
  out_has "recall failed: F99-E99-T99 not found in docs/Roadmap.md" && ok "$label the missing task is named" || bad "$label recall missing task text: $(cat "$WORK/.out")"
  ip_new rc_classic
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  assert_failure "$label recall does not run in classic mode" run recall "$ip" F01-E01-T01
  out_has "recall needs Factory mode" && ok "$label classic mode says so" || bad "$label classic recall text wrong: $(cat "$WORK/.out")"

  # ---- retro and done --------------------------------------------------------------------------------------
  rt_proj() {  # rt_proj <name>: a task the spec agent finished and the QA agent passed, ready for retro
    bn_proj "$1"
    run claim "$bn" claude-spec F09-E01-T01 "write the spec" >/dev/null 2>&1
    # these cases are about the retro and the lessons, not about the phases: the task is put in GREEN
    seed_entry "$bn" "$(now_ts)" claude-spec F09-E01-T01 IN_PROGRESS "Export invoices as CSV" '- Summary: in GREEN\n- Verify: pending\n- Phase: GREEN\n'
    run checkpoint "$bn" claude-spec F09-E01-T01 "spec done" "review" >/dev/null 2>&1
    run learn "$bn" claude-dev F09-E01-T01 PITFALL "Invoice totals drift when rounding early" "invoice rounding" "Round once at the end of the sum" >/dev/null 2>&1
  }
  rt_review() {
    run handoff "$bn" claude-spec F09-E01-T01 "spec ready" "exit=0" claude-qa >/dev/null 2>&1
    run review "$bn" claude-qa F09-E01-T01 PASS "fine" "exit=0" >/dev/null 2>&1
  }
  rt_proj r_main
  wmr="$bn/docs/brain/tasks/F09-E01-T01.md"
  brain_refused "retro refuses an id that is not a lesson id" "retro failed: \"banana\" is not a lesson id like LRN-001 or the word none" retro "$bn" claude-spec F09-E01-T01 banana none
  brain_refused "retro refuses a used lesson that does not exist" "retro failed: LRN-777 is not in docs/Brain.md" retro "$bn" claude-spec F09-E01-T01 LRN-777 none
  brain_refused "retro refuses a learned lesson that is from another task" "retro failed: LRN-002 was not learned for F09-E01-T01 (its Evidence is seed)" retro "$bn" claude-spec F09-E01-T01 none LRN-002
  brain_refused "retro refuses a task that is not in the project" "retro failed: F99-E99-T99 is not a task of this project" retro "$bn" claude-spec F99-E99-T99 none none
  rt_review
  brain_refused "done in Factory mode needs a retro" "done failed: F09-E01-T01 has no retro yet; run retro first" done "$bn" claude-spec F09-E01-T01 "spec" "docs/" "exit=0"
  assert_success "$label retro records the used and the learned lessons, sorted and without repeats" run retro "$bn" claude-spec F09-E01-T01 "LRN-003, LRN-001 LRN-001" "LRN-004"
  grep -q '^project_docs retro: F09-E01-T01 recorded (used: LRN-001, LRN-003; learned: LRN-004)$' "$WORK/.out" && ok "$label retro says what it recorded" || bad "$label retro output wrong: $(cat "$WORK/.out")"
  grep -q '^- Used: LRN-001, LRN-003$' "$wmr" && grep -q '^- Learned: LRN-004$' "$wmr" && ok "$label the working memory ## Retro has both lines" || bad "$label Retro lines wrong: $(sed -n '/## Retro/,$p' "$wmr")"
  assert_success "$label retro can be run again and replaces its lines" run retro "$bn" claude-spec F09-E01-T01 "LRN-001, LRN-003" "LRN-004"
  [ "$(grep -c '^- Used:' "$wmr")" -eq 1 ] && ok "$label a second retro does not repeat the lines" || bad "$label retro lines repeated"
  assert_success "$label done closes the task once the retro is recorded" run done "$bn" claude-spec F09-E01-T01 "spec" "docs/" "exit=0"
  done_ts="$(grep -E '^## \[.*\] \| claude-spec \| F09-E01-T01 \| DONE' "$bn/docs/Agentslog.md" | sed 's/^## \[\([0-9-]*\)T.*/\1/')"
  grep -q '^- Brain: used LRN-001, LRN-003; learned LRN-004$' "$bn/docs/Agentslog.md" && ok "$label the DONE entry says what was used and learned" || bad "$label Brain line missing: $(grep '^- Brain' "$bn/docs/Agentslog.md")"
  grep -qxF "| LRN-001 | Prefer the most reversible option | DEFAULT | * | When two options are equivalent choose the one cheaper to undo and record it as an ADR | seed | CONFIRMED | 1 | $done_ts |" "$bnb" && ok "$label a used lesson gets one hit and the date" || bad "$label hits wrong: $(grep LRN-001 "$bnb")"
  grep '^| LRN-003 ' "$bnb" | grep -q "| 1 | $done_ts |\$" && ok "$label every used lesson is updated" || bad "$label LRN-003 not updated: $(grep LRN-003 "$bnb")"
  grep '^| LRN-002 ' "$bnb" | grep -q '| 0 | — |$' && ok "$label a lesson that was not used keeps its hits" || bad "$label LRN-002 changed"
  [ ! -e "$wmr" ] && ok "$label done deletes the working memory" || bad "$label working memory left behind"
  ! grep -q 'F09-E01-T01' "$bn/docs/Roadmap.md" && ok "$label done still removes the Roadmap row" || bad "$label Roadmap row left"
  assert_success "$label a project after done and retro passes check" run check "$bn"

  rt_proj r_none
  rt_review
  assert_success "$label retro none none is fine for a task without trouble" run retro "$bn" claude-spec F09-E01-T01 none none
  assert_success "$label done after retro none none" run done "$bn" claude-spec F09-E01-T01 "spec" "docs/" "exit=0"
  grep -q '^- Brain: used none; learned none$' "$bn/docs/Agentslog.md" && ok "$label the DONE entry says none and none" || bad "$label none Brain line missing"

  rt_proj r_fail
  seed_entry "$bn" "$(now_ts)" claude-qa F09-E01-T01 REVIEW "Export invoices as CSV" '- Summary: review\n- Review: FAIL - not yet\n'
  brain_refused "retro refuses learned none after a Review FAIL" "retro failed: F09-E01-T01 had a Review: FAIL, a BLOQUEO or a move back to RED; record what was learned with learn first" retro "$bn" claude-spec F09-E01-T01 none none
  assert_success "$label retro with a learned lesson is accepted after a FAIL" run retro "$bn" claude-spec F09-E01-T01 none LRN-004
  rt_proj r_rotate
  seed_entry "$bn" "$(now_ts)" claude-qa F09-E01-T01 REVIEW "Export invoices as CSV" '- Summary: review\n- Review: FAIL - not yet\n'
  seed_fill "$bn" F09-FILL-06 205
  run rotate "$bn" >/dev/null 2>&1
  grep -q '^- Struggled: yes$' "$bn/docs/Agentslog.md" && ok "$label rotate carries the struggled flag" || bad "$label struggled flag lost in rotate"
  brain_refused "the lesson rule still holds after rotate" "retro failed: F09-E01-T01 had a Review: FAIL" retro "$bn" claude-spec F09-E01-T01 none none
  rt_proj r_pause
  seed_entry "$bn" "$(now_ts)" claude-spec F09-E01-T01 PAUSE "Export invoices as CSV" '- Pause: BLOQUEO - stuck\n'
  brain_refused "a BLOQUEO also asks for a lesson" "retro failed: F09-E01-T01 had a Review: FAIL, a BLOQUEO or a move back to RED" retro "$bn" claude-spec F09-E01-T01 none none

  # ---- brain gc in rotate and the promotion warning ------------------------------------------------
  gc_proj() {  # gc_proj <name> <max>: a brain with twelve rows of known hits and dates
    bn_proj "$1"
    set_setting "$bn" "Brain max entries | $2"
    { printf '%s\n' "# Brain" "" "## Operational summary" "" "- Entries: 12 of $2" "- Last gc: —" "" "<!-- context:end -->" "" "## Entries" "" "| ID | Name | Kind | Trigger | Lesson | Evidence | Status | Hits | Last used |" "|---|---|---|---|---|---|---|---|---|"
      printf '%s\n' "| LRN-001 | Prefer the most reversible option | DEFAULT | * | Choose the option cheaper to undo | seed | CONFIRMED | 0 | — |" \
        "| LRN-002 | Ambiguous rule takes the stricter behavior | DEFAULT | * | Record a HYPOTHESIS BR row | seed | CONFIRMED | 0 | — |" \
        "| LRN-003 | Never used and never dated | PATTERN | alpha | Lesson three | log:A | HYPOTHESIS | 0 | — |" \
        "| LRN-004 | Used five times lately | PATTERN | beta | Lesson four | log:B | CONFIRMED | 5 | 2026-10-01 |" \
        "| LRN-005 | Never used but dated early | PITFALL | gamma | Lesson five | log:C | HYPOTHESIS | 0 | 2026-09-01 |" \
        "| LRN-006 | Used twice long ago | RECIPE | delta | Lesson six | log:D | HYPOTHESIS | 2 | 2026-10-10 |" \
        "| LRN-007 | Never used and never dated too | MAP | epsilon | Lesson seven | log:E | HYPOTHESIS | 0 | — |" \
        "| LRN-008 | Used twice a bit earlier | PITFALL | zeta | Lesson eight | log:F | HYPOTHESIS | 2 | 2026-10-05 |" \
        "| LRN-009 | Used once | PATTERN | eta | Lesson nine | log:G | HYPOTHESIS | 1 | — |" \
        "| LRN-010 | Used nine times | RECIPE | theta | Lesson ten | log:H | CONFIRMED | 9 | 2026-10-20 |" \
        "| LRN-011 | Never used dated late | MAP | iota | Lesson eleven | log:I | HYPOTHESIS | 0 | 2026-10-02 |" \
        "| LRN-012 | Used three times | PITFALL | kappa | Lesson twelve | log:J | HYPOTHESIS | 3 | 2026-10-03 |"; } > "$bnb"
  }
  gc_proj g_main 8
  assert_failure "$label a brain over its limit fails check" run check "$bn"
  out_has "docs/Brain.md has 12 entries, over the Brain max entries limit of 8" && ok "$label check names the cap" || bad "$label cap text wrong: $(grep Brain "$WORK/.out")"
  out_has "WARN: docs/Brain.md row 'LRN-004' is CONFIRMED with 5 hits; promote it to a rule in AGENTS.md, an ADR or a BR" && out_has "row 'LRN-010' is CONFIRMED with 9 hits" && ok "$label check warns about CONFIRMED lessons with five hits or more" || bad "$label promotion warnings wrong: $(grep WARN "$WORK/.out")"
  ! out_has "row 'LRN-001' is CONFIRMED with" && ok "$label a CONFIRMED lesson with no hits is not a candidate" || bad "$label LRN-001 warned"
  assert_success "$label rotate archives the least used rows of a brain over its limit" run rotate "$bn"
  gcname="$(ls "$bn/docs/history" | grep '^brain-archive-' | head -n 1)"
  out_has "project_docs rotate: brain archived 6 entries to $gcname" && ok "$label rotate says how many rows it archived and where" || bad "$label gc output wrong: $(cat "$WORK/.out")"
  for gid in 003 007 005 011 009 008; do ! grep -q "^| LRN-$gid " "$bnb" && grep -q "^| LRN-$gid " "$bn/docs/history/$gcname" || bad "$label LRN-$gid was not moved"; done
  for gid in 001 002 004 006 010 012; do grep -q "^| LRN-$gid " "$bnb" || bad "$label LRN-$gid left the brain"; done
  [ "$(grep -c '^| LRN-' "$bnb")" -eq 6 ] && [ "$(grep -c '^| LRN-' "$bn/docs/history/$gcname")" -eq 6 ] && ok "$label the six least used rows moved: fewest hits, then oldest, then lowest id; the DEFAULT rows with * stayed" || bad "$label gc moved the wrong rows: $(grep '^| LRN-' "$bnb" | cut -c1-9 | tr '\n' ' ')"
  grep -q '^- Entries: 6 of 8$' "$bnb" && ok "$label the entry count follows the archive" || bad "$label count after gc: $(grep Entries: "$bnb")"
  gchash="$(file_hash "$bn/docs/history/$gcname")"
  grep -q "^- Last gc: [0-9-]* (6 archived to docs/history/$gcname, SHA-256 $gchash)\$" "$bnb" && ok "$label the summary records the archive and its SHA-256" || bad "$label Last gc line wrong: $(grep 'Last gc' "$bnb")"
  assert_success "$label the brain passes check after the archive" run check "$bn"
  assert_success "$label rotate says not required once the brain fits" run rotate "$bn"
  out_has "project_docs rotate: not required" && ok "$label nothing left to archive" || bad "$label second rotate text: $(cat "$WORK/.out")"
  assert_success "$label a lesson added after the archive does not reuse an archived id" run learn "$bn" claude-dev F09-E01-T01 PITFALL "A new lesson after the archive" "omega" "Keep going"
  out_has "LRN-013 added" && ok "$label the next id is above every archived id" || bad "$label id after gc wrong: $(cat "$WORK/.out")"
  gc_proj g_protected 2
  run rotate "$bn" >/dev/null 2>&1
  grep -q '^| LRN-001 ' "$bnb" && grep -q '^| LRN-002 ' "$bnb" && ok "$label DEFAULT rows with * are never archived, even over a tiny limit" || bad "$label a protected row was archived"
  ip_new g_classic
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  assert_success "$label classic rotate on a small ledger is unchanged" run rotate "$ip"
  [ "$(tr -d '\r' < "$WORK/.out")" = "project_docs rotate: not required" ] && ok "$label classic rotate prints only its own line" || bad "$label classic rotate text: $(cat "$WORK/.out")"

  echo "== $label: the exit marker is strict and the test comparison fails closed (F06-E02-T04 retake) =="
  gr_proj x_exit git
  refused "an exit marker inside a longer word is not a marker" "handoff failed: the verify needs exit=N (exit=0 when the checks pass)" handoff "$av" claude-dev F09-E01-T01 "impl" "preexit=0 and exit=0x2" claude-qa
  refused "exit=0 followed by letters is not a marker" "handoff failed: the verify needs exit=N (exit=0 when the checks pass)" handoff "$av" claude-dev F09-E01-T01 "impl" "suite exit=0x2" claude-qa
  refused "EXIT in capitals is not a marker" "handoff failed: the verify needs exit=N (exit=0 when the checks pass)" handoff "$av" claude-dev F09-E01-T01 "impl" "EXIT=0" claude-qa
  assert_success "$label a bad marker followed by a good one counts the good one" run handoff "$av" claude-dev F09-E01-T01 "impl" "run one exit=1x, run two exit=0" claude-qa

  gr_proj x_many git
  awk 'BEGIN { for (i = 1; i <= 2500; i++) printf "tests/gen/case%04d.sh ", i; printf "tests/billing/export.spec.sh" }' > "$WORK/.many"
  seed_entry "$av" "$(now_ts)" claude-dev F09-E01-T01 IN_PROGRESS "Advance task" "- Summary: more tests\n- Verify: pending\n- Phase: GREEN\n- Tests: $(cat "$WORK/.many")\n"
  assert_success "$label a very long list of test paths is compared without trouble" run handoff "$av" claude-dev F09-E01-T01 "impl" "exit=0" claude-qa
  seed_entry "$av" "$(now_ts)" claude-qa F09-E01-T01 REVIEW "Advance task" '- Summary: review\n- Review: FAIL - once more\n'
  run claim "$av" claude-dev F09-E01-T01 "again" >/dev/null 2>&1
  printf '# edited\n' >> "$av/tests/billing/export.spec.sh"
  refused "a changed test is still found among thousands of paths" "handoff failed: test file(s) changed since RED ($red_sha): tests/billing/export.spec.sh" handoff "$av" claude-dev F09-E01-T01 "impl" "exit=0" claude-qa

  echo "== $label: next and the fast lane (F06-E01-T04, F06-E02-T06) =="
  nx_proj() { nx="$WORK/${label}_nx_$1"; rm -rf "$nx"; mkdir -p "$nx"; run init "$nx" >/dev/null 2>&1; }
  nx_is() {  # nx_is <description> <agent> <expected>
    runo next "$nx" "$2"
    nx_got="$(head -n 1 "$WORK/.out" | tr -d '\r')"
    [ "$nx_got" = "$3" ] && ok "$label $1" || bad "$label $1: got [$nx_got], wanted [$3]"
  }
  add_agent() {  # add_agent <project> "<roster row>": puts the row after claude-qa
    aa_f="$1/AGENTS.md"
    awk -v row="$2" '{ print } /^\| claude-qa \|/ { print row }' "$aa_f" > "$aa_f.tmp" && mv "$aa_f.tmp" "$aa_f"
  }
  # the template's own TODO row would be everybody's first task: close it (seed_plan_row needs the row as its anchor)
  drop_template_row() { seed_replace "$1/docs/Roadmap.md" "| F01-E01-T01 | UNKNOWN | UNKNOWN | UNKNOWN | TODO |" "| F01-E01-T01 | UNKNOWN | UNKNOWN | UNKNOWN | DONE |"; }

  nx_proj n_fresh
  nx_is "next does not offer the template stub row (its Name is UNKNOWN) to a SPEC agent" claude-spec none
  nx_is "next gives a DEV agent nothing when there is no FAST row" claude-dev none
  nx_is "next gives a TEST agent nothing" claude-test none
  nx_is "next gives a QA agent nothing" claude-qa none
  nx_is "next gives the other QA agent nothing" gemini-qa none
  add_agent "$nx" "| claude-all | AI | Claude | BOTH | — |"
  nx_is "the stub row is not offered to a BOTH agent either" claude-all none
  drop_template_row "$nx"
  seed_plan_row "$nx" F09-E01-T01 "A real task"
  nx_is "next gives a SPEC agent the first real TODO row" claude-spec F09-E01-T01
  nx_is "next gives a BOTH agent the first real TODO row" claude-all F09-E01-T01
  assert_failure "$label next refuses an agent that is not in the roster" run next "$nx" nobody
  out_has "next failed: nobody is not in the Agent identity table; Factory mode needs a role for each agent" && ok "$label the unknown agent is named" || bad "$label unknown agent text: $(cat "$WORK/.out")"
  assert_failure "$label next needs an agent" run next "$nx"
  out_has "next requires: agent" && ok "$label the usage is named" || bad "$label next usage text: $(cat "$WORK/.out")"
  ip_new n_classic
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  assert_failure "$label next does not run in classic mode" run next "$ip" claude-spec
  out_has "next needs Factory mode" && ok "$label classic mode says so" || bad "$label classic next text: $(cat "$WORK/.out")"

  nx_proj n_lanes
  drop_template_row "$nx"
  seed_plan_row "$nx" F09-E01-T01 "Build the feature"
  seed_plan_row "$nx" F09-E01-T02 "Fix a typo"
  seed_replace "$nx/docs/Roadmap.md" "| F09-E01-T02 | Fix a typo | details | works |" "| F09-E01-T02 | Fix a typo | Fix a typo in the README. Lane: FAST | works |"
  seed_replace "$nx/docs/Roadmap.md" "| F09-E01-T01 | Build the feature | details | works | TODO | — | — | — |" "| F09-E01-T01 | Build the feature | details | works | TODO | — | F09-E01-T03 | — |"
  seed_plan_row "$nx" F09-E01-T03 "Prepare the ground"
  nx_is "a row blocked by an open dependency is skipped" claude-spec F09-E01-T03
  nx_is "a FAST row goes to a DEV agent" claude-dev F09-E01-T02
  run claim "$nx" claude-spec F09-E01-T03 "prepare" >/dev/null 2>&1
  nx_is "an agent is sent back to the task it holds" claude-spec F09-E01-T03
  add_agent "$nx" "| claude-all | AI | Claude | BOTH | — |"
  nx_is "a task whose dependency is still open stays blocked, the FAST row is next for a BOTH agent" claude-all F09-E01-T02

  nx_proj n_order
  drop_template_row "$nx"
  add_agent "$nx" "| claude-all | AI | Claude | BOTH | — |"
  seed_plan_row "$nx" F09-E01-T09 "A todo task"
  nx_is "with only a TODO row that is the answer" claude-all F09-E01-T09
  seed_plan_row "$nx" F09-E01-T05 "Assigned to another"
  seed_entry "$nx" "$(now_ts)" claude-spec F09-E01-T05 ASSIGNED "Assigned to another" '- Assign: claude-dev\n- Phase: GREEN\n'
  nx_is "a task assigned to another agent of the role comes before a TODO row" claude-all F09-E01-T05
  seed_plan_row "$nx" F09-E01-T04 "Paused by a limit"
  seed_entry "$nx" "$(now_ts)" claude-dev F09-E01-T04 IN_PROGRESS "Paused by a limit" '- Summary: work\n- Verify: pending\n- Phase: GREEN\n'
  seed_entry "$nx" "$(now_ts)" claude-dev F09-E01-T04 PAUSE "Paused by a limit" '- Pause: LIMITE - limit until later\n'
  nx_is "a task paused by a limit comes before a task assigned to another" claude-all F09-E01-T04
  seed_plan_row "$nx" F09-E01-T03 "Waiting for review"
  seed_entry "$nx" "$(now_ts)" claude-dev F09-E01-T03 IN_PROGRESS "Waiting for review" '- Summary: work\n- Verify: pending\n- Phase: GREEN\n'
  seed_entry "$nx" "$(now_ts)" claude-dev F09-E01-T03 REVIEW "Waiting for review" '- Summary: ready\n- Verify: exit=0\n- Handoff: claude-all\n'
  nx_is "a review waiting for the agent comes before a paused task" claude-all F09-E01-T03
  seed_plan_row "$nx" F09-E01-T02 "Assigned to me"
  seed_entry "$nx" "$(now_ts)" claude-spec F09-E01-T02 ASSIGNED "Assigned to me" '- Assign: claude-all\n- Phase: GREEN\n'
  nx_is "a task assigned to the agent comes before a review" claude-all F09-E01-T02
  seed_plan_row "$nx" F09-E01-T01 "Mine in progress"
  seed_entry "$nx" "$(now_ts)" claude-all F09-E01-T01 IN_PROGRESS "Mine in progress" '- Summary: work\n- Verify: pending\n- Phase: GREEN\n'
  nx_is "a task the agent already holds comes first" claude-all F09-E01-T01

  nx_proj n_review
  drop_template_row "$nx"
  seed_plan_row "$nx" F09-E01-T01 "Reviewed by claude-qa"
  seed_plan_row "$nx" F09-E01-T02 "Reviewed by anyone"
  seed_entry "$nx" "$(now_ts)" claude-dev F09-E01-T01 IN_PROGRESS "Reviewed by claude-qa" '- Summary: work\n- Verify: pending\n- Phase: GREEN\n'
  seed_entry "$nx" "$(now_ts)" claude-dev F09-E01-T01 REVIEW "Reviewed by claude-qa" '- Summary: ready\n- Verify: exit=0\n- Handoff: claude-qa\n'
  seed_entry "$nx" "$(now_ts)" claude-dev F09-E01-T02 IN_PROGRESS "Reviewed by anyone" '- Summary: work\n- Verify: pending\n- Phase: GREEN\n'
  seed_entry "$nx" "$(now_ts)" claude-dev F09-E01-T02 REVIEW "Reviewed by anyone" '- Summary: ready\n- Verify: exit=0\n'
  nx_is "a review handed to an agent is that agent's" claude-qa F09-E01-T01
  nx_is "a review handed to nobody goes to the other QA agent" gemini-qa F09-E01-T02
  nx_is "a DEV agent is not offered the review of its own work" claude-dev none
  nx_is "a SPEC agent is not offered the review of a GREEN task" claude-spec none
  seed_entry "$nx" "$(now_ts)" claude-qa F09-E01-T01 REVIEW "Reviewed by claude-qa" '- Summary: review\n- Review: PASS - fine\n'
  nx_is "a review that was answered is not offered again" claude-qa F09-E01-T02

  nx_proj n_pause
  drop_template_row "$nx"
  seed_plan_row "$nx" F09-E01-T01 "Paused by a limit"
  seed_entry "$nx" "$(now_ts)" claude-dev F09-E01-T01 IN_PROGRESS "Paused by a limit" '- Summary: work\n- Verify: pending\n- Phase: GREEN\n'
  seed_entry "$nx" "$(now_ts)" claude-dev F09-E01-T01 PAUSE "Paused by a limit" '- Pause: LIMITE - limit until later\n'
  nx_is "any agent of the role may resume a task paused by a limit" claude-dev F09-E01-T01
  nx_is "an agent of another role may not" claude-test none
  seed_entry "$nx" "$(now_ts)" claude-dev F09-E01-T01 PAUSE "Paused by a limit" '- Pause: BLOQUEO - needs a decision\n'
  nx_is "a task paused with BLOQUEO is skipped" claude-dev none
  seed_entry "$nx" "$(now_ts)" claude-dev F09-E01-T01 PAUSE "Paused by a limit" '- Pause: ESPERA_RESPUESTA - RED-LINE: production deploy\n'
  nx_is "a red line is skipped" claude-dev none

  nx_proj n_attempts
  drop_template_row "$nx"
  seed_plan_row "$nx" F09-E01-T01 "Out of attempts"
  seed_entry "$nx" "$(now_ts)" claude-test F09-E01-T01 ASSIGNED "Out of attempts" '- Assign: claude-dev\n- Phase: GREEN\n- Attempts: 3\n'
  nx_is "a task with no attempts left is not offered" claude-dev none
  seed_replace "$nx/AGENTS.md" "| Max fix attempts | 3 |" "| Max fix attempts | 4 |"
  nx_is "the limit comes from the settings table" claude-dev F09-E01-T01

  # ---- the fast lane ---------------------------------------------------------------------------------
  ft_proj() {  # ft_proj <name> <git|nogit>: a FAST task of claude-dev; two files and ten lines are the limits
    ft="$WORK/${label}_ft_$1"; rm -rf "$ft"; mkdir -p "$ft"; run init "$ft" >/dev/null 2>&1
    drop_template_row "$ft"
    seed_plan_row "$ft" F09-E01-T01 "Fix the typo"
    seed_replace "$ft/docs/Roadmap.md" "| F09-E01-T01 | Fix the typo | details | works |" "| F09-E01-T01 | Fix the typo | Fix the typo in the README. Lane: FAST | works |"
    set_setting "$ft" "Fast lane max files | 2"
    set_setting "$ft" "Fast lane max lines | 10"
    mkdir -p "$ft/src"; printf 'one\n' > "$ft/src/base.sh"
    if [ "$2" = "git" ]; then git -C "$ft" init -q >/dev/null 2>&1; git_commit "$ft" "base"; fast_base="$(git -C "$ft" rev-parse HEAD)"; fi
  }
  ft_refused() {  # ft_refused <description> <expected text> <command...>
    fr_desc="$1"; fr_want="$2"; shift 2
    fr_before="$(grep -c '^## \[' "$ft/docs/Agentslog.md" | tr -d ' ')"
    assert_failure "$label $fr_desc" run "$@"
    out_has "$fr_want" && ok "$label $fr_desc: the message names it" || bad "$label $fr_desc: text wrong, wanted [$fr_want]: $(cat "$WORK/.out")"
    [ "$(grep -c '^## \[' "$ft/docs/Agentslog.md" | tr -d ' ')" = "$fr_before" ] && ok "$label $fr_desc: nothing is written" || bad "$label $fr_desc: an entry was written"
  }
  ft_proj f_main git
  assert_failure "$label a SPEC agent cannot claim a FAST task" run claim "$ft" claude-spec F09-E01-T01 "wrong role"
  out_has "claude-spec has role SPEC, but phase GREEN of F09-E01-T01 needs DEV (or BOTH)" && ok "$label a FAST task is DEV work" || bad "$label FAST role text: $(cat "$WORK/.out")"
  assert_success "$label a DEV agent claims a FAST task" run claim "$ft" claude-dev F09-E01-T01 "fix it"
  last_entry_of() { awk '/^## \[/ { buf="" } { buf = buf $0 "\n" } END { printf "%s", buf }' "$1/docs/Agentslog.md" | tr -d '\r'; }
  last_entry_of "$ft" > "$WORK/.last"
  grep -q '^- Phase: GREEN$' "$WORK/.last" && grep -q '^- Lane: FAST$' "$WORK/.last" && grep -q "^- Base: $fast_base\$" "$WORK/.last" && ok "$label the claim records the lane, the phase GREEN and the Base sha" || bad "$label FAST claim entry wrong: $(cat "$WORK/.last")"
  run checkpoint "$ft" claude-dev F09-E01-T01 "started" "fix the typo" >/dev/null 2>&1
  ft_refused "advance cannot take a FAST task to RED" "advance failed: F09-E01-T01 is a FAST task; it only goes back to SPEC, when it outgrew the lane" advance "$ft" claude-dev F09-E01-T01 RED "exit=1"
  printf 'a\n' > "$ft/src/a.sh"; printf 'b\n' > "$ft/src/b.sh"; printf 'c\n' > "$ft/src/c.sh"
  ft_refused "handoff refuses a FAST task that touches too many files" "handoff failed: task outgrew FAST lane (3 files, the limit is 2); save the work in the branch wip/F09-E01-T01, take Lane: FAST out of its row, go back to $fast_base and move the task to SPEC with advance" handoff "$ft" claude-dev F09-E01-T01 "fixed" "exit=0" claude-qa
  rm -f "$ft/src/c.sh"
  awk 'BEGIN { for (i = 1; i <= 12; i++) print i }' > "$ft/src/a.sh"
  ft_refused "handoff refuses a FAST task with too many lines" "task outgrew FAST lane (13 lines, the limit is 10)" handoff "$ft" claude-dev F09-E01-T01 "fixed" "exit=0" claude-qa
  printf 'a\n' > "$ft/src/a.sh"; rm -f "$ft/src/b.sh"
  mkdir -p "$ft/src/auth"; printf 'x\n' > "$ft/src/auth/login.sh"
  ft_refused "handoff refuses a FAST task that touches a protected path" "task outgrew FAST lane (it touches the protected path src/auth/login.sh)" handoff "$ft" claude-dev F09-E01-T01 "fixed" "exit=0" claude-qa
  rm -rf "$ft/src/auth"
  assert_success "$label handoff accepts a FAST task inside the limits (the ledger and the working memory do not count)" run handoff "$ft" claude-dev F09-E01-T01 "fixed" "exit=0" claude-qa
  assert_success "$label review PASS of a FAST task with git needs no extra words" run review "$ft" claude-qa F09-E01-T01 PASS "fine" "exit=0"
  assert_success "$label retro none none is enough for a FAST task without trouble" run retro "$ft" claude-dev F09-E01-T01 none none
  assert_success "$label done closes a FAST task with no spec and no RED" run done "$ft" claude-dev F09-E01-T01 "fixed" "src/" "exit=0"
  assert_success "$label a project with a closed FAST task passes check" run check "$ft"

  ft_proj f_bug git
  seed_plan_row "$ft" F09-BUG-01 "A bug in the parser"
  seed_replace "$ft/docs/Roadmap.md" "| F09-BUG-01 | A bug in the parser | details | works |" "| F09-BUG-01 | A bug in the parser | The parser drops a line. Lane: FAST | works |"
  run claim "$ft" claude-dev F09-BUG-01 "fix the bug" >/dev/null 2>&1
  run checkpoint "$ft" claude-dev F09-BUG-01 "started" "fix" >/dev/null 2>&1
  printf 'fixed\n' > "$ft/src/parser.sh"
  ft_refused "a FAST BUG needs a test file in the change" "task outgrew FAST lane (a BUG needs a test file in the change)" handoff "$ft" claude-dev F09-BUG-01 "fixed" "exit=0" claude-qa
  mkdir -p "$ft/tests"; printf 't\n' > "$ft/tests/parser.test.sh"
  assert_success "$label a FAST BUG with a test file in the change is accepted" run handoff "$ft" claude-dev F09-BUG-01 "fixed" "exit=0" claude-qa

  ft_proj f_promote git
  run claim "$ft" claude-dev F09-E01-T01 "fix it" >/dev/null 2>&1
  run checkpoint "$ft" claude-dev F09-E01-T01 "started" "fix the typo" >/dev/null 2>&1
  printf 'a\n' > "$ft/src/a.sh"; printf 'b\n' > "$ft/src/b.sh"; printf 'c\n' > "$ft/src/c.sh"
  ft_refused "the FAST task outgrows the lane" "task outgrew FAST lane (3 files, the limit is 2)" handoff "$ft" claude-dev F09-E01-T01 "fixed" "exit=0" claude-qa
  git -C "$ft" branch wip/F09-E01-T01 >/dev/null 2>&1
  assert_success "$label the outgrown task goes back to SPEC with advance" run advance "$ft" claude-dev F09-E01-T01 SPEC "outgrew the lane, exit=1"
  out_has "moved to SPEC, assigned to claude-spec" && ok "$label it is assigned to the SPEC agent" || bad "$label promotion output: $(cat "$WORK/.out")"
  assert_failure "$label while the row still says FAST the SPEC agent cannot take it" run claim "$ft" claude-spec F09-E01-T01 "spec it"
  seed_replace "$ft/docs/Roadmap.md" "Fix the typo in the README. Lane: FAST" "Fix the typo in the README"
  assert_success "$label once Lane: FAST is out of the row the SPEC agent claims it" run claim "$ft" claude-spec F09-E01-T01 "spec it"
  last_entry_of "$ft" > "$WORK/.last"
  grep -q '^- Phase: SPEC$' "$WORK/.last" && grep -q '^- Lane: NORMAL$' "$WORK/.last" && ! grep -q '^- Base:' "$WORK/.last" && ok "$label the claim starts the normal lane in SPEC" || bad "$label promotion claim entry: $(cat "$WORK/.last")"
  assert_success "$label check is green after the way back to SPEC" run check "$ft"

  ft_proj f_nogit nogit
  run claim "$ft" claude-dev F09-E01-T01 "fix it" >/dev/null 2>&1
  run checkpoint "$ft" claude-dev F09-E01-T01 "started" "fix the typo" >/dev/null 2>&1
  last_entry_of "$ft" > "$WORK/.last"
  grep -q '^- Lane: FAST$' "$WORK/.last" && ! grep -q '^- Base:' "$WORK/.last" && ok "$label without git the claim records the lane and no Base" || bad "$label no-git claim entry: $(cat "$WORK/.last")"
  assert_success "$label handoff of a FAST task without git warns" run handoff "$ft" claude-dev F09-E01-T01 "fixed" "exit=0" claude-qa
  out_has "WARN: git is not available here, so the size of the change cannot be checked; the reviewer must write 'fast lane ok' in the review note" && ok "$label the warning tells the reviewer what to write" || bad "$label FAST no-git warning: $(cat "$WORK/.out")"
  ft_refused "review PASS needs 'fast lane ok' when git could not check" "review failed: git could not check the size of the change of F09-E01-T01; the note must say 'fast lane ok'" review "$ft" claude-qa F09-E01-T01 PASS "fine" "exit=0"
  assert_success "$label review PASS with 'fast lane ok' in the note" run review "$ft" claude-qa F09-E01-T01 PASS "Fast Lane OK, tiny change" "exit=0"

  ft_proj f_rotate git
  run claim "$ft" claude-dev F09-E01-T01 "fix it" >/dev/null 2>&1
  run checkpoint "$ft" claude-dev F09-E01-T01 "started" "fix the typo" >/dev/null 2>&1
  seed_fill "$ft" F09-FILL-07 205
  run rotate "$ft" >/dev/null 2>&1
  grep -q '^- Lane: FAST$' "$ft/docs/Agentslog.md" && grep -q "^- Base: $fast_base\$" "$ft/docs/Agentslog.md" && ok "$label rotate carries the lane and the Base sha" || bad "$label lane lost in rotate: $(grep -E '^- (Lane|Base)' "$ft/docs/Agentslog.md" | tr '\n' ' ')"
  printf 'a\n' > "$ft/src/a.sh"; printf 'b\n' > "$ft/src/b.sh"; printf 'c\n' > "$ft/src/c.sh"
  ft_refused "the size limits still apply after rotate" "task outgrew FAST lane (3 files, the limit is 2)" handoff "$ft" claude-dev F09-E01-T01 "fixed" "exit=0" claude-qa

  ft_proj f_again git
  run claim "$ft" claude-dev F09-E01-T01 "fix it" >/dev/null 2>&1
  run checkpoint "$ft" claude-dev F09-E01-T01 "started" "fix the typo" >/dev/null 2>&1
  printf 'a\n' > "$ft/src/a.sh"
  git_commit "$ft" "moves the head past the Base"
  run handoff "$ft" claude-dev F09-E01-T01 "fixed" "exit=0" claude-qa >/dev/null 2>&1
  run review "$ft" claude-qa F09-E01-T01 FAIL "not yet" "exit=1" >/dev/null 2>&1
  run claim "$ft" claude-dev F09-E01-T01 "again" >/dev/null 2>&1
  [ "$(grep -c "^- Base: $fast_base\$" "$ft/docs/Agentslog.md")" -eq 2 ] && ok "$label a new claim keeps the original Base, not the new head" || bad "$label Base changed: $(grep '^- Base' "$ft/docs/Agentslog.md" | tr '\n' ' ')"

  # ---- check: RED and GREEN of the normal lane need a spec ------------------------------------------------
  ps_proj() { ps="$WORK/${label}_ps_$1"; rm -rf "$ps"; mkdir -p "$ps"; run init "$ps" >/dev/null 2>&1; drop_template_row "$ps"; seed_plan_row "$ps" F09-E01-T01 "A normal task"; }
  ps_proj no_spec
  seed_entry "$ps" "$(now_ts)" claude-test F09-E01-T01 ASSIGNED "A normal task" '- Assign: claude-dev\n- Phase: GREEN\n'
  assert_failure "$label a task in GREEN with no spec fails check" run check "$ps"
  out_has "ERROR: F09-E01-T01 is in phase GREEN but docs/specs/F09-E01-T01.md does not exist" && ok "$label check names the missing spec" || bad "$label missing spec text: $(grep ERROR "$WORK/.out")"
  sed -e 's/{TASK}/F09-E01-T01/' -e 's/{NAME}/A normal task/' "$SCRIPT_DIR/../templates/Spec.md" > "$ps/docs/specs/F09-E01-T01.md"
  assert_failure "$label a spec with UNKNOWN fields is not enough in GREEN" run check "$ps"
  out_has "ERROR: F09-E01-T01 is in phase GREEN but docs/specs/F09-E01-T01.md still has 4 UNKNOWN field(s)" && ok "$label check names the UNKNOWN fields" || bad "$label UNKNOWN text: $(grep ERROR "$WORK/.out")"
  mkspec "$ps" F09-E01-T01
  assert_success "$label a valid spec satisfies the phase rule" run check "$ps"
  ps_proj spec_phase
  seed_entry "$ps" "$(now_ts)" claude-spec F09-E01-T01 IN_PROGRESS "A normal task" '- Summary: spec\n- Verify: pending\n- Phase: SPEC\n- Lane: NORMAL\n'
  assert_success "$label a task still in SPEC needs no finished spec" run check "$ps"
  ps_proj fast_exempt
  seed_entry "$ps" "$(now_ts)" claude-dev F09-E01-T01 IN_PROGRESS "A normal task" '- Summary: fix\n- Verify: pending\n- Phase: GREEN\n- Lane: FAST\n'
  assert_success "$label a FAST task in GREEN needs no spec" run check "$ps"

  echo "== $label: status phases, cross-model reviews, audits and the digest (F06-E04-T01 to T03) =="
  # ---- status with phase and lane -------------------------------------------------------------------
  st_proj() { st="$WORK/${label}_st_$1"; rm -rf "$st"; mkdir -p "$st"; run init "$st" >/dev/null 2>&1; drop_template_row "$st"; }
  st_proj main
  seed_entry "$st" "$(now_ts)" claude-dev F09-E01-T01 IN_PROGRESS "Fast fix" '- Summary: fix\n- Verify: pending\n- Phase: GREEN\n- Lane: FAST\n'
  seed_entry "$st" "$(now_ts)" claude-dev F09-E01-T02 IN_PROGRESS "Reviewed work" '- Summary: work\n- Verify: pending\n- Phase: GREEN\n'
  seed_entry "$st" "$(now_ts)" claude-dev F09-E01-T02 REVIEW "Reviewed work" '- Summary: ready\n- Verify: exit=0\n- Handoff: claude-qa\n'
  seed_entry "$st" "$(now_ts)" claude-spec F09-E01-T03 IN_PROGRESS "Paused work" '- Summary: spec\n- Verify: pending\n'
  seed_entry "$st" "$(now_ts)" claude-spec F09-E01-T03 PAUSE "Paused work" '- Pause: LIMITE - limit until later\n'
  seed_entry "$st" "$(now_ts)" claude-spec F09-E01-T04 ASSIGNED "Assigned work" '- Assign: claude-test\n- Phase: RED\n'
  assert_success "$label status runs on a Factory project" run status "$st"
  printf '%s\n' "F09-E01-T01 | Fast fix | claude-dev | IN_PROGRESS | 0h | - | GREEN FAST" \
    "F09-E01-T02 | Reviewed work | claude-dev | REVIEW->claude-qa | 0h | - | REVIEW NORMAL" \
    "F09-E01-T03 | Paused work | claude-spec | PAUSE | 0h | LIMITE | SPEC NORMAL" \
    "F09-E01-T04 | Assigned work | claude-spec | ASSIGNED->claude-test | 0h | - | RED NORMAL" > "$WORK/.golden"
  golden_eq "$WORK/.out" && ok "$label status adds the phase and the lane to every open task in Factory mode" || { bad "$label Factory status differs"; diff "$WORK/.golden" "$WORK/.out" | head -8; }
  run_env PROJECT_DOCS_MODE=classic status "$st" > "$WORK/.out" 2>&1
  printf '%s\n' "F09-E01-T01 | Fast fix | claude-dev | IN_PROGRESS | 0h | -" \
    "F09-E01-T02 | Reviewed work | claude-dev | REVIEW->claude-qa | 0h | -" \
    "F09-E01-T03 | Paused work | claude-spec | PAUSE | 0h | LIMITE" \
    "F09-E01-T04 | Assigned work | claude-spec | ASSIGNED->claude-test | 0h | -" > "$WORK/.golden"
  golden_eq "$WORK/.out" && ok "$label the same ledger in classic mode prints no phase and no lane" || { bad "$label classic status changed"; diff "$WORK/.golden" "$WORK/.out" | head -8; }

  # ---- the cross-model marker, the default reviewer and the audits -----------------------------------------------
  cm_proj() {
    cm="$WORK/${label}_cm_$1"; rm -rf "$cm"; mkdir -p "$cm"; run init "$cm" >/dev/null 2>&1; drop_template_row "$cm"
    seed_plan_row "$cm" F09-E01-T01 "Cross model task"
    run claim "$cm" claude-spec F09-E01-T01 "work" >/dev/null 2>&1
    seed_entry "$cm" "$(now_ts)" claude-spec F09-E01-T01 IN_PROGRESS "Cross model task" '- Summary: in GREEN\n- Verify: pending\n- Phase: GREEN\n'
    run checkpoint "$cm" claude-spec F09-E01-T01 "spec" "review" >/dev/null 2>&1
  }
  cm_proj same
  assert_success "$label handoff without a reviewer works" run handoff "$cm" claude-spec F09-E01-T01 "ready" "exit=0"
  grep -q '^project_docs handoff: F09-E01-T01 handed to review$' "$WORK/.out" && [ "$(last_entry_of "$cm" | grep -c '^- Handoff:')" -eq 0 ] && ok "$label with no Preferred reviewer the handoff has no addressee" || bad "$label handoff output: $(cat "$WORK/.out")"
  assert_success "$label a review by an agent of the same model" run review "$cm" claude-qa F09-E01-T01 PASS "fine" "exit=0"
  last_entry_of "$cm" > "$WORK/.last"
  grep -q '^- Cross-model: NO$' "$WORK/.last" && ok "$label the review is marked Cross-model: NO" || bad "$label no marker: $(cat "$WORK/.last")"
  run retro "$cm" claude-spec F09-E01-T01 none none >/dev/null 2>&1
  assert_success "$label done closes it" run done "$cm" claude-spec F09-E01-T01 "spec" "docs/" "exit=0"
  last_entry_of "$cm" > "$WORK/.last"
  grep -q '^- Cross-model: NO$' "$WORK/.last" && ok "$label the DONE entry keeps the marker for the audit" || bad "$label DONE without the marker: $(cat "$WORK/.last")"

  cm_proj other
  run handoff "$cm" claude-spec F09-E01-T01 "ready" "exit=0" gemini-qa >/dev/null 2>&1
  run review "$cm" gemini-qa F09-E01-T01 PASS "fine" "exit=0" >/dev/null 2>&1
  last_entry_of "$cm" > "$WORK/.last"
  ! grep -q '^- Cross-model:' "$WORK/.last" && ok "$label a review by another model has no marker" || bad "$label marker on a cross-model review: $(cat "$WORK/.last")"

  cm_proj pref
  set_setting "$cm" "Preferred reviewer | gemini-qa"
  set_setting "$cm" "Fallback reviewer | claude-qa"
  assert_success "$label handoff of a normal task goes to the Preferred reviewer" run handoff "$cm" claude-spec F09-E01-T01 "ready" "exit=0"
  grep -q '^project_docs handoff: F09-E01-T01 handed to review (gemini-qa)$' "$WORK/.out" && last_entry_of "$cm" | grep -q '^- Handoff: gemini-qa$' && ok "$label the Preferred reviewer is the default addressee" || bad "$label default reviewer wrong: $(cat "$WORK/.out")"
  cm_proj pref_explicit
  set_setting "$cm" "Preferred reviewer | gemini-qa"
  assert_success "$label an explicit reviewer beats the setting" run handoff "$cm" claude-spec F09-E01-T01 "ready" "exit=0" claude-qa
  grep -q 'handed to review (claude-qa)' "$WORK/.out" && ok "$label the addressee is the one given" || bad "$label explicit reviewer ignored: $(cat "$WORK/.out")"
  cm_proj pref_self
  set_setting "$cm" "Preferred reviewer | claude-spec"
  assert_success "$label a Preferred reviewer that holds the task is not used" run handoff "$cm" claude-spec F09-E01-T01 "ready" "exit=0"
  grep -q '^project_docs handoff: F09-E01-T01 handed to review$' "$WORK/.out" && ok "$label the handoff has no addressee then" || bad "$label self reviewer used: $(cat "$WORK/.out")"
  ft_proj cm_fast git
  set_setting "$ft" "Preferred reviewer | gemini-qa"
  set_setting "$ft" "Fallback reviewer | claude-qa"
  run claim "$ft" claude-dev F09-E01-T01 "fix" >/dev/null 2>&1
  run checkpoint "$ft" claude-dev F09-E01-T01 "started" "fix" >/dev/null 2>&1
  printf 'a\n' > "$ft/src/a.sh"
  assert_success "$label a FAST handoff goes to the Fallback reviewer" run handoff "$ft" claude-dev F09-E01-T01 "fixed" "exit=0"
  grep -q 'handed to review (claude-qa)' "$WORK/.out" && ok "$label FAST work never uses the Preferred reviewer" || bad "$label FAST reviewer wrong: $(cat "$WORK/.out")"

  au_proj() {
    au="$WORK/${label}_au_$1"; rm -rf "$au"; mkdir -p "$au"; run init "$au" >/dev/null 2>&1; drop_template_row "$au"
    set_setting "$au" "Preferred reviewer | gemini-qa"
    seed_plan_row "$au" F09-E01-T10 "Same model normal"; seed_plan_row "$au" F09-E01-T11 "Other model normal"; seed_plan_row "$au" F09-E01-T12 "Same model fast"
    seed_entry "$au" "$(now_ts)" claude-dev F09-E01-T10 IN_PROGRESS "Same model normal" '- Summary: w\n- Verify: pending\n- Phase: GREEN\n- Lane: NORMAL\n'
    seed_entry "$au" "$(now_ts)" claude-qa F09-E01-T10 REVIEW "Same model normal" '- Summary: r\n- Verify: exit=0\n- Review: PASS - ok\n- Cross-model: NO\n'
    seed_entry "$au" "$(now_ts)" claude-dev F09-E01-T10 DONE "Same model normal" '- Summary: d\n- Files: x\n- Verify: exit=0\n- Cross-model: NO\n'
    seed_entry "$au" "$(now_ts)" claude-dev F09-E01-T11 IN_PROGRESS "Other model normal" '- Summary: w\n- Verify: pending\n- Phase: GREEN\n- Lane: NORMAL\n'
    seed_entry "$au" "$(now_ts)" gemini-qa F09-E01-T11 REVIEW "Other model normal" '- Summary: r\n- Verify: exit=0\n- Review: PASS - ok\n'
    seed_entry "$au" "$(now_ts)" claude-dev F09-E01-T11 DONE "Other model normal" '- Summary: d\n- Files: x\n- Verify: exit=0\n'
    seed_entry "$au" "$(now_ts)" claude-dev F09-E01-T12 IN_PROGRESS "Same model fast" '- Summary: w\n- Verify: pending\n- Phase: GREEN\n- Lane: FAST\n'
    seed_entry "$au" "$(now_ts)" claude-qa F09-E01-T12 REVIEW "Same model fast" '- Summary: r\n- Verify: exit=0\n- Review: PASS - ok\n- Cross-model: NO\n'
    seed_entry "$au" "$(now_ts)" claude-dev F09-E01-T12 DONE "Same model fast" '- Summary: d\n- Files: x\n- Verify: exit=0\n- Cross-model: NO\n'
  }
  au_proj main
  runo next "$au" gemini-qa
  [ "$(head -n 1 "$WORK/.out" | tr -d '\r')" = "F09-E01-T10" ] && ok "$label the Preferred reviewer is offered a closed normal task reviewed by one model" || bad "$label audit candidate wrong: $(cat "$WORK/.out")"
  runo next "$au" claude-qa
  [ "$(head -n 1 "$WORK/.out" | tr -d '\r')" = "none" ] && ok "$label other agents are not offered audits" || bad "$label audit offered to claude-qa: $(cat "$WORK/.out")"
  assert_success "$label an audit is recorded with append-log" run append-log "$au" gemini-qa F09-E01-T10 AUDIT "audited, nothing wrong" "src/" "exit=0"
  runo next "$au" gemini-qa
  [ "$(head -n 1 "$WORK/.out" | tr -d '\r')" = "none" ] && ok "$label an audited task is not offered again (the FAST and the cross-model ones never were)" || bad "$label audit offered twice: $(cat "$WORK/.out")"
  assert_success "$label the AUDIT status is valid in Factory mode" run check "$au"
  runo status "$au"
  ! grep -q 'F09-E01-T10' "$WORK/.out" && ok "$label an audit does not reopen the task" || bad "$label task reopened by the audit: $(cat "$WORK/.out")"
  ip_new au_classic
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  run append-log "$ip" a F01-E01-T01 AUDIT "x" "y" "z" >/dev/null 2>&1
  assert_failure "$label classic check still rejects the AUDIT status" run check "$ip"
  out_has "invalid status in entry" && ok "$label classic vocabulary is unchanged" || bad "$label classic AUDIT text: $(cat "$WORK/.out")"

  # ---- digest ---------------------------------------------------------------------------------------------------------
  dg_proj() {
    dg="$WORK/${label}_dg_$1"; rm -rf "$dg"; mkdir -p "$dg"; run init "$dg" >/dev/null 2>&1; drop_template_row "$dg"
    seed_replace "$dg/docs/ProductDescription.md" "| BR-001 | UNKNOWN | UNKNOWN | UNKNOWN |" "| BR-001 | Invoices round half up | HYPOTHESIS | agent:claude-dev F09-E01-T01 |"
    seed_replace "$dg/docs/Stack_Tecnologies.md" "| ADR-001 | UNKNOWN | UNKNOWN | HYPOTHESIS | UNKNOWN |" "| ADR-001 | Use CSV for exports | Simple | HYPOTHESIS | 2026-10-26 |"
    awk '{ print } /^\| ID \| Name \| Severity/ { getline; print; print "| F09-GAP-01 | Which payment provider | High | F09 | Text | TODO | — | — | — |" }' "$dg/docs/Roadmap.md" > "$dg/docs/Roadmap.md.tmp" && mv "$dg/docs/Roadmap.md.tmp" "$dg/docs/Roadmap.md"
    seed_plan_row "$dg" F09-E01-T01 "A paused task"
    seed_entry "$dg" "$(now_ts)" claude-dev F09-E01-T01 IN_PROGRESS "A paused task" '- Summary: w\n- Verify: pending\n- Phase: GREEN\n'
    seed_entry "$dg" "$(now_ts)" claude-dev F09-E01-T01 PAUSE "A paused task" '- Pause: ESPERA_RESPUESTA - RED-LINE: production deploy\n'
    run learn "$dg" claude-dev F09-E01-T01 PITFALL "Invoice totals drift" "invoice rounding" "Round once" >/dev/null 2>&1
    seed_entry "$dg" "2026-10-26T10:00:00Z" claude-dev F09-E01-T10 IN_PROGRESS "Normal one" '- Summary: w\n- Verify: pending\n- Phase: GREEN\n- Lane: NORMAL\n'
    seed_entry "$dg" "2026-10-26T10:05:00Z" claude-qa F09-E01-T10 REVIEW "Normal one" '- Summary: r\n- Verify: exit=0\n- Review: FAIL - not yet\n'
    seed_entry "$dg" "2026-10-26T10:10:00Z" claude-qa F09-E01-T10 REVIEW "Normal one" '- Summary: r\n- Verify: exit=0\n- Review: PASS - ok\n- Cross-model: NO\n'
    seed_entry "$dg" "2026-10-26T10:15:00Z" claude-dev F09-E01-T10 DONE "Normal one" '- Summary: d\n- Files: x\n- Verify: exit=0\n- Cross-model: NO\n'
    seed_entry "$dg" "2026-10-26T10:20:00Z" gemini-qa F09-E01-T10 AUDIT "Normal one" '- Summary: a\n- Files: x\n- Verify: exit=0\n'
    seed_entry "$dg" "2026-10-26T11:00:00Z" claude-dev F09-E01-T11 IN_PROGRESS "Normal two" '- Summary: w\n- Verify: pending\n- Phase: GREEN\n- Lane: NORMAL\n'
    seed_entry "$dg" "2026-10-26T11:05:00Z" claude-qa F09-E01-T11 REVIEW "Normal two" '- Summary: r\n- Verify: exit=0\n- Review: PASS - ok\n- Cross-model: NO\n'
    seed_entry "$dg" "2026-10-26T11:10:00Z" claude-dev F09-E01-T11 DONE "Normal two" '- Summary: d\n- Files: x\n- Verify: exit=0\n- Cross-model: NO\n'
    seed_entry "$dg" "2026-10-26T12:00:00Z" claude-dev F09-E01-T12 IN_PROGRESS "Fast one" '- Summary: w\n- Verify: pending\n- Phase: GREEN\n- Lane: FAST\n'
    seed_entry "$dg" "2026-10-26T12:10:00Z" claude-dev F09-E01-T12 DONE "Fast one" '- Summary: d\n- Files: x\n- Verify: exit=0\n'
  }
  dg_proj main
  assert_success "$label digest lists every kind of item" run digest "$dg"
  printf '%s\n' "digest since the start of the ledger" "## Product guesses" "BR-001 | Invoices round half up | agent:claude-dev F09-E01-T01" "ADR-001 | Use CSV for exports | 2026-10-26" \
    "## Red lines" "F09-E01-T01 | claude-dev | RED-LINE: production deploy" "## Open gaps" "F09-GAP-01 | Which payment provider | TODO" \
    "## New lessons" "LRN-004 | Invoice totals drift | log:F09-E01-T01" "## Closed" "NORMAL: 2, FAST: 1" "## Reviews" \
    "Failed reviews: 1; NORMAL tasks closed with the same model reviewing: 2; audited by the preferred reviewer: 1" > "$WORK/.golden"
  golden_eq "$WORK/.out" && ok "$label the digest has every section, in order" || { bad "$label digest differs"; diff "$WORK/.golden" "$WORK/.out" | head -12; }
  assert_success "$label digest takes a date" run digest "$dg" 2026-10-26T11:00:00Z
  tr -d '\r' < "$WORK/.out" > "$WORK/.norm"
  grep -q '^digest since 2026-10-26T11:00:00Z$' "$WORK/.norm" && grep -q '^NORMAL: 1, FAST: 1$' "$WORK/.norm" && grep -q '^Failed reviews: 0;' "$WORK/.norm" && ok "$label the date keeps only what happened since" || bad "$label digest since wrong: $(cat "$WORK/.norm")"
  assert_success "$label digest since a later day drops the old decisions" run digest "$dg" 2099-01-01
  tr -d '\r' < "$WORK/.out" > "$WORK/.norm"
  ! grep -q '^ADR-001' "$WORK/.norm" && grep -q '^BR-001' "$WORK/.norm" && grep -q '^NORMAL: 0, FAST: 0$' "$WORK/.norm" && ok "$label ADRs and closed tasks are filtered by date, open guesses are not" || bad "$label digest 2099: $(cat "$WORK/.norm")"
  assert_failure "$label digest refuses a date that is not one" run digest "$dg" yesterday
  out_has "digest requires an ISO date like 2026-10-27 or a timestamp like 2026-10-27T14:00:00Z" && ok "$label the date format is named" || bad "$label digest date text: $(cat "$WORK/.out")"
  dg_proj big
  awk 'BEGIN { for (i = 5; i <= 80; i++) printf "| LRN-%03d | A lesson that is still a guess number %d | PATTERN | zeta%d | Lesson text %d | log:F09-E01-T01 | HYPOTHESIS | 0 | — |\n", i, i, i, i }' > "$WORK/.lessons"
  { cat "$dg/docs/Brain.md"; cat "$WORK/.lessons"; } > "$dg/docs/Brain.md.tmp" && mv "$dg/docs/Brain.md.tmp" "$dg/docs/Brain.md"
  assert_success "$label digest of a big brain still succeeds" run digest "$dg"
  dgb="$(tr -d '\r' < "$WORK/.out" | wc -c | tr -d ' ')"
  [ "$dgb" -le 4096 ] && ok "$label the digest is $dgb bytes, at most 4 KiB" || bad "$label digest is $dgb bytes"
  tr -d '\r' < "$WORK/.out" | tail -n 1 | grep -q '^digest: truncated, [0-9]* more lines, read the ledger and the Roadmap$' && ok "$label what does not fit is said, not cut silently" || bad "$label truncation line missing: $(tail -n 2 "$WORK/.out")"
  assert_failure "$label digest does not run in classic mode" run_env PROJECT_DOCS_MODE=classic digest "$dg"
  out_has "digest needs Factory mode" && ok "$label classic mode says so" || bad "$label classic digest text: $(cat "$WORK/.out")"

  echo "== $label: next gives a reviewed task back to its holder (F06-E01-T06) =="
  rv_task() {  # rv_task <name> <verdict line or none> [rounds]: a GREEN task of claude-dev handed to claude-qa and answered
    nx_proj "$1"; drop_template_row "$nx"
    seed_plan_row "$nx" F09-E01-T01 "Reviewed task"
    rv_n="${3:-1}"; rv_i=0
    while [ "$rv_i" -lt "$rv_n" ]; do
      seed_entry "$nx" "$(now_ts)" claude-dev F09-E01-T01 IN_PROGRESS "Reviewed task" '- Summary: work\n- Verify: pending\n- Phase: GREEN\n'
      seed_entry "$nx" "$(now_ts)" claude-dev F09-E01-T01 REVIEW "Reviewed task" '- Summary: ready\n- Verify: exit=0\n- Handoff: claude-qa\n'
      if [ "$2" != "none" ]; then
        seed_entry "$nx" "$(now_ts)" claude-qa F09-E01-T01 REVIEW "Reviewed task" "- Summary: review\n- Verify: exit=0\n- Review: $2\n"
      fi
      rv_i=$((rv_i + 1))
    done
  }
  rv_task waiting none
  nx_is "a task waiting for its review is not offered to its holder" claude-dev none
  nx_is "a task waiting for its review is offered to the reviewer" claude-qa F09-E01-T01
  rv_task passed "PASS - fine"
  nx_is "after a PASS the holder is given the task to close it" claude-dev F09-E01-T01
  nx_is "the reviewer is not offered a task it already answered" claude-qa none
  nx_is "another QA agent is not offered it either" gemini-qa none
  nx_is "a spec agent is not offered it" claude-spec none
  nx_is "a test agent is not offered it" claude-test none
  rv_task failed "FAIL - fix the rounding"
  nx_is "after a FAIL the holder is given the task to retake it" claude-dev F09-E01-T01
  nx_is "the reviewer is not offered a failed task" claude-qa none
  rv_task exhausted "FAIL - still wrong" 3
  nx_is "with no attempts left the holder still gets the task, to pause it with BLOQUEO" claude-dev F09-E01-T01
  rv_task first_wins "PASS - fine"
  seed_plan_row "$nx" F09-E01-T02 "Another task"
  nx_is "a task the agent holds comes before a TODO row" claude-dev F09-E01-T01
  nx_is "a TODO row is still offered to the agents that hold nothing" claude-spec F09-E01-T02

  echo "== $label: init and migrate add the dispatcher configuration (F06-E06-T01) =="
  GI_MARK='# project-documentation dispatcher (generated files)'
  ip_new dsp_init
  assert_success "$label init creates the dispatcher configuration" run init "$ip"
  grep -q '^+ created: .factory/dispatch.md$' "$WORK/.out" && ok "$label init says it created .factory/dispatch.md" || bad "$label init output: $(cat "$WORK/.out")"
  cmp -s "$ip/.factory/dispatch.md" "$SCRIPT_DIR/../templates/dispatch.md" && ok "$label .factory/dispatch.md is the template" || bad "$label dispatch.md differs from the template"
  grep -q '^project_docs init: 7 file(s) created$' "$WORK/.out" && ok "$label the count of files created stays the contract files" || bad "$label init count: $(grep 'project_docs init' "$WORK/.out")"
  grep -qxF -- "$GI_MARK" "$ip/.gitignore" && grep -qx '.factory/state.md' "$ip/.gitignore" && grep -qx '.factory/runs/' "$ip/.gitignore" && ok "$label .gitignore ignores the state and the runs of the dispatcher" || bad "$label .gitignore: $(cat "$ip/.gitignore" 2>&1)"
  grep -qx '.factory/dispatch.md' "$ip/.gitignore" && bad "$label the configuration must be committed, not ignored" || ok "$label the configuration is not ignored"
  cp "$ip/.gitignore" "$WORK/.gi_before"; cp "$ip/.factory/dispatch.md" "$WORK/.dsp_before"
  assert_success "$label a second init" run init "$ip"
  ! grep -q '^+ created: .factory/dispatch.md$' "$WORK/.out" && ! grep -q 'gitignore' "$WORK/.out" && ok "$label a second init adds nothing" || bad "$label second init output: $(cat "$WORK/.out")"
  cmp -s "$WORK/.gi_before" "$ip/.gitignore" && [ "$(grep -cF -- "$GI_MARK" "$ip/.gitignore")" -eq 1 ] && ok "$label the .gitignore block is not duplicated" || bad "$label .gitignore changed: $(cat "$ip/.gitignore")"
  printf 'my own command\n' > "$ip/.factory/dispatch.md"
  run init "$ip" >/dev/null 2>&1
  [ "$(tr -d '\r' < "$ip/.factory/dispatch.md")" = "my own command" ] && ok "$label init never overwrites an existing .factory/dispatch.md" || bad "$label dispatch.md overwritten"

  ip_new dsp_gitignore
  printf 'node_modules\nbuild/' > "$ip/.gitignore"
  run init "$ip" >/dev/null 2>&1
  [ "$(sed -n '1,2p' "$ip/.gitignore" | tr -d '\r' | tr '\n' ',')" = "node_modules,build/," ] && ok "$label an existing .gitignore keeps its lines (a missing final newline is added)" || bad "$label .gitignore start: $(cat "$ip/.gitignore")"
  [ "$(sed -n '3p' "$ip/.gitignore" | tr -d '\r')" = "" ] && [ "$(sed -n '4p' "$ip/.gitignore" | tr -d '\r')" = "$GI_MARK" ] && ok "$label the block comes after a blank line" || bad "$label .gitignore block: $(cat "$ip/.gitignore")"
  [ "$(tail -n 2 "$ip/.gitignore" | tr -d '\r' | tr '\n' ',')" = ".factory/state.md,.factory/runs/," ] && ok "$label the block ends with the two generated paths" || bad "$label .gitignore tail: $(cat "$ip/.gitignore")"
  ip_new dsp_crlf
  printf 'dist\r\n%s\r\n.factory/state.md\r\n.factory/runs/\r\n' "$GI_MARK" > "$ip/.gitignore"
  cp "$ip/.gitignore" "$WORK/.gi_before"
  run init "$ip" >/dev/null 2>&1
  cmp -s "$WORK/.gi_before" "$ip/.gitignore" && ok "$label a .gitignore with the block and CRLF endings is left alone" || bad "$label CRLF .gitignore changed"

  ip_new dsp_classic
  assert_success "$label init --classic" run init "$ip" --classic
  [ ! -e "$ip/.factory" ] && [ ! -e "$ip/.gitignore" ] && ok "$label a classic project gets no .factory folder and no .gitignore" || bad "$label classic init created dispatcher files"

  ip_new dsp_migrate
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  assert_success "$label migrate --factory on a classic project" run migrate "$ip" --factory
  grep -q '^+ created: .factory/dispatch.md$' "$WORK/.out" && grep -q '^+ added: .gitignore block for .factory/state.md and .factory/runs/$' "$WORK/.out" && ok "$label migrate --factory reports the configuration and the .gitignore block" || bad "$label migrate output: $(cat "$WORK/.out")"
  grep -q '^project_docs migrate: 8 change(s)$' "$WORK/.out" && ok "$label the two dispatcher changes count" || bad "$label migrate count: $(grep 'project_docs migrate' "$WORK/.out")"
  cmp -s "$ip/.factory/dispatch.md" "$SCRIPT_DIR/../templates/dispatch.md" && ok "$label migrate --factory writes the template" || bad "$label migrated dispatch.md differs"
  cp "$ip/.gitignore" "$WORK/.gi_before"
  assert_success "$label a second migrate --factory" run migrate "$ip" --factory
  grep -q '^project_docs migrate: 0 change(s)$' "$WORK/.out" && cmp -s "$WORK/.gi_before" "$ip/.gitignore" && [ "$(grep -cF -- "$GI_MARK" "$ip/.gitignore")" -eq 1 ] && ok "$label a second migrate --factory changes nothing and adds no second block" || bad "$label second migrate: $(cat "$WORK/.out")"
  assert_success "$label check passes on the migrated project" run check "$ip"

  echo "== $label: fixes after the QA of a711b68 (F06-E03-T03 to T05, F06-E02-T04, F06-E02-T06, F06-E01-T06) =="
  TAB="$(printf '\t')"
  # ---- a tab inside a lesson is a space -----------------------------------------------------------------
  bn_proj tab
  assert_success "$label learn accepts a lesson with a tab in it" run learn "$bn" claude-dev F09-E01-T01 RECIPE "Tab row" invoice "before${TAB}after the tab"
  [ "$(grep -c "$TAB" "$bnb")" -eq 0 ] && grep -q '^| LRN-004 | Tab row | RECIPE | invoice | before after the tab | log:F09-E01-T01 |' "$bnb" && ok "$label the tab became a space in the brain row" || bad "$label brain row: $(grep LRN-004 "$bnb")"
  assert_success "$label recall on that brain" run recall "$bn" F09-E01-T01
  out_has "Tab row" && out_has "before after the tab" && ok "$label recall prints the row whole" || bad "$label recall row: $(cat "$WORK/.out")"
  sedi "s/after the tab/after${TAB}the tab/" "$bnb"
  assert_success "$label recall on a row edited by hand to hold a tab" run recall "$bn" F09-E01-T01
  out_has "Tab row" && out_has "before after the tab" && out_has "recall: 3 of 4 brain entries shown" && ok "$label a tab typed into the file reads as a space and the count stays right" || bad "$label recall after the edit: $(cat "$WORK/.out")"
  gc_proj g_tab 8
  sedi "s/Lesson three/Lesson${TAB}three/" "$bnb"
  assert_success "$label rotate with a tab in a lesson" run rotate "$bn"
  gcname="$(ls "$bn/docs/history" | grep '^brain-archive-' | head -n 1)"
  out_has "brain archived 6 entries to $gcname" && [ "$(grep -c '^| LRN-' "$bn/docs/history/$gcname")" -eq 6 ] && grep -q '^| LRN-003 ' "$bn/docs/history/$gcname" && ok "$label every archived row reaches the archive, the tab one included" || bad "$label archive rows: $(grep -c '^| LRN-' "$bn/docs/history/$gcname") $(cat "$WORK/.out")"
  [ "$(grep -c '^| LRN-' "$bnb")" -eq 6 ] && ok "$label six rows stay in the brain" || bad "$label rows left: $(grep -c '^| LRN-' "$bnb")"

  # ---- done asks for the lesson again when the task struggled after its retro ----------------------------
  rt_proj r_stale
  assert_success "$label retro none none while the task has no trouble yet" run retro "$bn" claude-spec F09-E01-T01 none none
  run handoff "$bn" claude-spec F09-E01-T01 "spec ready" "exit=0" claude-qa >/dev/null 2>&1
  assert_success "$label the reviewer fails it" run review "$bn" claude-qa F09-E01-T01 FAIL "not yet"
  # the task is in GREEN, which the spec agent cannot claim: the retake is written into the ledger
  seed_entry "$bn" "$(now_ts)" claude-spec F09-E01-T01 IN_PROGRESS "Export invoices as CSV" '- Summary: retaken after the FAIL\n- Verify: pending\n- Phase: GREEN\n'
  run handoff "$bn" claude-spec F09-E01-T01 "spec ready again" "exit=0" claude-qa >/dev/null 2>&1
  assert_success "$label the second review passes" run review "$bn" claude-qa F09-E01-T01 PASS "fine" "exit=0"
  brain_refused "done refuses a task that struggled after its retro said learned none" "done failed: F09-E01-T01 had a Review: FAIL, a BLOQUEO or a move back to RED, so its retro cannot say learned none; run learn and retro again" done "$bn" claude-spec F09-E01-T01 "spec" "docs/" "exit=0"
  assert_success "$label retro again with the lesson learned" run retro "$bn" claude-spec F09-E01-T01 none LRN-004
  assert_success "$label done then closes the task" run done "$bn" claude-spec F09-E01-T01 "spec" "docs/" "exit=0"

  # ---- the exit marker: an underscore is part of a word ---------------------------------------------------
  gr_proj y_exit git
  refused "pre_exit=0 is not a marker" "handoff failed: the verify needs exit=N (exit=0 when the checks pass)" handoff "$av" claude-dev F09-E01-T01 "impl" "pre_exit=0 or exit_0=1" claude-qa
  assert_success "$label exit=0 next to punctuation is still a marker" run handoff "$av" claude-dev F09-E01-T01 "impl" "suite (exit=0)." claude-qa

  # ---- a rename is a delete and an add --------------------------------------------------------------------
  gr_proj y_rename git
  git -C "$av" mv tests/billing/export.spec.sh tests/billing/export2.spec.sh
  printf 'exit 0\n' > "$av/tests/billing/export2.spec.sh"
  refused "a recorded test renamed after RED counts as changed" "handoff failed: test file(s) changed since RED ($red_sha): tests/billing/export.spec.sh" handoff "$av" claude-dev F09-E01-T01 "impl" "exit=0" claude-qa

  ft_proj y_rename git
  mkdir -p "$ft/auth"; printf 'secret\n' > "$ft/auth/login.sh"; git_commit "$ft" "auth"
  run claim "$ft" claude-dev F09-E01-T01 "fix it" >/dev/null 2>&1
  run checkpoint "$ft" claude-dev F09-E01-T01 "started" "fix" >/dev/null 2>&1
  git -C "$ft" mv auth/login.sh src/login.sh
  ft_refused "a rename out of a protected path touches that path" "task outgrew FAST lane (it touches the protected path auth/login.sh)" handoff "$ft" claude-dev F09-E01-T01 "fixed" "exit=0" claude-qa

  ft_proj y_space git
  run claim "$ft" claude-dev F09-E01-T01 "fix it" >/dev/null 2>&1
  run checkpoint "$ft" claude-dev F09-E01-T01 "started" "fix" >/dev/null 2>&1
  awk 'BEGIN { for (i = 1; i <= 20; i++) print i }' > "$ft/src/big file.sh"
  ft_refused "the lines of an untracked file with a space in its name are counted" "task outgrew FAST lane (20 lines, the limit is 10)" handoff "$ft" claude-dev F09-E01-T01 "fixed" "exit=0" claude-qa

  ft_proj y_gitfail git
  run claim "$ft" claude-dev F09-E01-T01 "fix it" >/dev/null 2>&1
  run checkpoint "$ft" claude-dev F09-E01-T01 "started" "fix" >/dev/null 2>&1
  printf 'not an index' > "$ft/.git/index"
  ft_refused "a git failure stops the handoff of a FAST task" "handoff failed: git could not" handoff "$ft" claude-dev F09-E01-T01 "fixed" "exit=0" claude-qa

  # ---- next: a handoff addressed to a role, and the stub row -------------------------------------------------
  nx_proj y_role
  drop_template_row "$nx"
  seed_plan_row "$nx" F09-E01-T01 "Reviewed by role"
  add_agent "$nx" "| claude-all | AI | Claude | BOTH | — |"
  seed_entry "$nx" "$(now_ts)" claude-dev F09-E01-T01 IN_PROGRESS "Reviewed by role" '- Summary: work\n- Verify: pending\n- Phase: GREEN\n'
  seed_entry "$nx" "$(now_ts)" claude-dev F09-E01-T01 REVIEW "Reviewed by role" '- Summary: ready\n- Verify: exit=0\n- Handoff: QA\n'
  nx_is "a review addressed to the role QA is offered to a QA agent" claude-qa F09-E01-T01
  nx_is "a review addressed to the role QA is offered to the other QA agent" gemini-qa F09-E01-T01
  nx_is "a review addressed to the role QA is offered to a BOTH agent" claude-all F09-E01-T01
  nx_is "a review addressed to the role QA is not offered to its developer" claude-dev none
  nx_is "a review addressed to the role QA is not offered to a SPEC agent" claude-spec none
  nx_proj y_role_dev
  drop_template_row "$nx"
  seed_plan_row "$nx" F09-E01-T01 "Reviewed by a role"
  seed_entry "$nx" "$(now_ts)" claude-dev F09-E01-T01 IN_PROGRESS "Reviewed by a role" '- Summary: work\n- Verify: pending\n- Phase: GREEN\n'
  seed_entry "$nx" "$(now_ts)" claude-dev F09-E01-T01 REVIEW "Reviewed by a role" '- Summary: ready\n- Verify: exit=0\n- Handoff: claude-qa\n'
  nx_is "a review addressed to one agent is not offered to the other QA agent" gemini-qa none

  echo "== $label: context gives up older entries before it fails in Factory mode (F06-E01-T07) =="
  cx_fill() {  # cx_fill <project>: five DONE entries with long summaries
    cx_words="$(awk 'BEGIN { for (i = 0; i < 90; i++) printf "word%02d ", i }')"
    for cx_i in 1 2 3 4 5; do
      seed_entry "$1" "$(now_ts)" claude-dev "F09-FILL-0$cx_i" DONE "Filler $cx_i" "- Summary: $cx_words\n- Files: x\n- Verify: exit=0\n"
    done
  }
  cx_bytes() { tr -d '\r' < "$WORK/.out" | wc -c | tr -d ' '; }
  ip_new cx_fresh
  run init "$ip" >/dev/null 2>&1
  assert_success "$label context of a fresh Factory project" run context "$ip"
  grep -q '^## Latest agent entries$' "$WORK/.out" && ok "$label a context that fits keeps its heading and its five entries" || bad "$label fresh heading: $(grep 'Latest agent' "$WORK/.out")"
  ip_new cx_big
  run init "$ip" >/dev/null 2>&1
  cx_fill "$ip"
  assert_success "$label context of a Factory project whose five entries would not fit" run context "$ip"
  [ "$(cx_bytes)" -le 8192 ] && ok "$label the output is within 8192 bytes ($(cx_bytes))" || bad "$label context is $(cx_bytes) bytes"
  tr -d '\r' < "$WORK/.out" | grep -q '^## Latest agent entries (the latest [1-4] only, to stay within 8192 bytes)$' && ok "$label the heading says how many entries are shown" || bad "$label heading: $(grep 'Latest agent' "$WORK/.out")"
  cx_n="$(tr -d '\r' < "$WORK/.out" | sed -n 's/^## Latest agent entries (the latest \([1-4]\) only.*/\1/p')"
  [ "$(tr -d '\r' < "$WORK/.out" | grep -c '^## \[')" = "$cx_n" ] && ok "$label that many entries are printed" || bad "$label entries printed: $(grep -c '^## \[' "$WORK/.out") instead of $cx_n"
  tr -d '\r' < "$WORK/.out" | grep -q '| F09-FILL-05 | DONE |' && ok "$label the entries kept are the latest ones" || bad "$label the latest entry is missing"
  ip_new cx_classic
  run init "$ip" --classic >/dev/null 2>&1
  cx_fill "$ip"
  assert_failure "$label the same ledger in a classic project still fails" run context "$ip"
  out_has "hot context is " && out_has "bytes; compact summaries below 8192" && ok "$label the classic error is the one it always was" || bad "$label classic context text: $(cat "$WORK/.out")"
  ip_new cx_huge
  run init "$ip" >/dev/null 2>&1
  cx_pad="$(awk 'BEGIN { for (i = 0; i < 900; i++) printf "abcdefghi " }')"
  awk -v pad="$cx_pad" '$0 == "| — | — | — | — | — | — | — | — |" && !done { print "| F09-E01-T01 | A task with a very long text | " pad " | Done | TODO | — | — | — |"; done = 1; next } { print }' "$ip/docs/Roadmap.md" > "$ip/docs/Roadmap.md.tmp" && mv "$ip/docs/Roadmap.md.tmp" "$ip/docs/Roadmap.md"
  assert_failure "$label context still fails when what is above the entries does not fit" run context "$ip"
  out_has "hot context is " && out_has "bytes; compact summaries below 8192" && ok "$label the error asks to compact the summaries" || bad "$label huge context text: $(cat "$WORK/.out")"

  echo "== $label: fixes after the QA of 2b97a0b (F06-E04-T01, F06-E04-T03, F06-E06-T01, F06-DEBT-04) =="
  # ---- digest: the date, the counts, characters and long lines ---------------------------------------------
  dg_proj r2
  for dg_bad in 2026-99-99 2026-02-30 2026-04-31 2026-10-27T: 2026-10-27T25:00:00Z 2026-10-27T14:60:00Z yesterday 2026-10-27Z 2026-1-5; do
    assert_failure "$label digest refuses the date $dg_bad" run digest "$dg" "$dg_bad"
  done
  for dg_good in 2026-10-27 2026-10-27T14:00 2026-10-27T14:00:00Z 2026-02-29; do
    assert_success "$label digest accepts the date $dg_good" run digest "$dg" "$dg_good"
  done
  runo digest "$dg"
  out_has "same model reviewing: 2; audited by the preferred reviewer: 1" && ok "$label without a date it counts every closed task reviewed by one model" || bad "$label digest counts: $(tail -n 1 "$WORK/.out")"
  runo digest "$dg" 2026-10-26T11:00:00Z
  out_has "NORMAL: 1, FAST: 1" && out_has "same model reviewing: 1; audited by the preferred reviewer: 0" && ok "$label the cross-model and audit counts follow the date" || bad "$label digest since: $(tail -n 3 "$WORK/.out")"
  runo digest "$dg" 2099-01-01
  out_has "NORMAL: 0, FAST: 0" && out_has "same model reviewing: 0; audited by the preferred reviewer: 0" && ok "$label a date in the future counts nothing" || bad "$label digest future: $(tail -n 3 "$WORK/.out")"
  dg_proj mb
  dg_a79="$(awk 'BEGIN { for (i = 0; i < 79; i++) printf "a" }')"
  seed_replace "$dg/docs/ProductDescription.md" "| BR-001 | Invoices round half up | HYPOTHESIS |" "| BR-001 | ${dg_a79}éñ | HYPOTHESIS |"
  assert_success "$label digest of a rule whose name has accents" run digest "$dg"
  tr -d '\r' < "$WORK/.out" | grep -q "^BR-001 | ${dg_a79}é | agent:" && ! grep -q 'éñ' "$WORK/.out" && ok "$label a name is cut at 80 characters, never inside one" || bad "$label BR line: $(grep BR-001 "$WORK/.out")"
  dg_proj long
  dg_long="$(awk 'BEGIN { for (i = 0; i < 600; i++) printf "abcdefghi " }')"
  seed_plan_row "$dg" F09-E01-T20 "A very long red line"
  seed_entry "$dg" "$(now_ts)" claude-dev F09-E01-T20 IN_PROGRESS "A very long red line" '- Summary: w\n- Verify: pending\n- Phase: GREEN\n'
  seed_entry "$dg" "$(now_ts)" claude-dev F09-E01-T20 PAUSE "A very long red line" "- Pause: ESPERA_RESPUESTA - RED-LINE: $dg_long\n"
  assert_success "$label digest with a red line whose detail is six thousand characters" run digest "$dg"
  [ "$(tr -d '\r' < "$WORK/.out" | wc -c | tr -d ' ')" -le 4096 ] && out_has "## Open gaps" && out_has "## Reviews" && tr -d '\r' < "$WORK/.out" | grep -q '^F09-E01-T20 | claude-dev | RED-LINE: .*\.\.\.$' && ok "$label the long line is cut and the sections after it stay" || bad "$label long digest: $(tr -d '\r' < "$WORK/.out" | wc -c) bytes: $(tail -n 3 "$WORK/.out" | cut -c1-120)"

  # ---- rotate keeps the closed tasks that wait for an audit ---------------------------------------------------
  au_proj r2
  seed_fill "$au" F09-FILL-08 205
  assert_success "$label rotate of a ledger with a closed task that waits for its audit" run rotate "$au"
  runo next "$au" gemini-qa
  [ "$(head -n 1 "$WORK/.out" | tr -d '\r')" = "F09-E01-T10" ] && ok "$label the audit queue survives the rotation" || bad "$label next after rotate: $(cat "$WORK/.out")"
  grep -q '^## \[.*\] | claude-dev | F09-E01-T10 | DONE |' "$au/docs/Agentslog.md" && ! grep -q '| F09-E01-T11 | DONE |' "$au/docs/Agentslog.md" && ! grep -q '| F09-E01-T12 | DONE |' "$au/docs/Agentslog.md" && ok "$label only the normal-lane task reviewed by one model is carried" || bad "$label carried entries: $(grep -E '\| DONE \|' "$au/docs/Agentslog.md" | cut -c1-90)"
  assert_success "$label the audit is recorded after the rotation" run append-log "$au" gemini-qa F09-E01-T10 AUDIT "audited, nothing wrong" "src/" "exit=0"
  seed_fill "$au" F09-FILL-09 205
  run rotate "$au" >/dev/null 2>&1
  runo next "$au" gemini-qa
  [ "$(head -n 1 "$WORK/.out" | tr -d '\r')" = "none" ] && ok "$label an audited task is not carried again" || bad "$label next after the second rotate: $(cat "$WORK/.out")"
  au_proj r2np
  sedi '/^| Preferred reviewer | gemini-qa |$/d' "$au/AGENTS.md"
  seed_fill "$au" F09-FILL-11 205
  run rotate "$au" >/dev/null 2>&1
  ! grep -q '| F09-E01-T10 | DONE |' "$au/docs/Agentslog.md" && ok "$label with no Preferred reviewer nobody audits, so rotate carries no closed task" || bad "$label a closed task was carried with no Preferred reviewer"
  au_proj r2cap
  cap_i=20
  while [ "$cap_i" -le 44 ]; do
    cap_id="F09-E02-T$cap_i"
    seed_entry "$au" "2026-09-$(printf '%02d' $((cap_i - 14)))T10:00:00Z" claude-dev "$cap_id" IN_PROGRESS "Closed one model $cap_i" '- Summary: w\n- Verify: pending\n- Phase: GREEN\n- Lane: NORMAL\n'
    seed_entry "$au" "2026-09-$(printf '%02d' $((cap_i - 14)))T10:05:00Z" claude-dev "$cap_id" DONE "Closed one model $cap_i" '- Summary: d\n- Files: x\n- Verify: exit=0\n- Cross-model: NO\n'
    cap_i=$((cap_i + 1))
  done
  seed_fill "$au" F09-FILL-12 205
  run rotate "$au" >/dev/null 2>&1
  [ "$(grep -c '| F09-E0[12]-T[0-9]* | DONE |' "$au/docs/Agentslog.md")" -eq 20 ] && grep -q '| F09-E02-T44 | DONE |' "$au/docs/Agentslog.md" && ! grep -q '| F09-E02-T24 | DONE |' "$au/docs/Agentslog.md" && ok "$label rotate carries at most the 20 latest closed tasks that wait for an audit" || bad "$label carried: $(grep -c '| F09-E0[12]-T[0-9]* | DONE |' "$au/docs/Agentslog.md")"
  ip_new r2tie
  run init "$ip" >/dev/null 2>&1
  set_setting "$ip" "Preferred reviewer | gemini-qa"
  tie_i=44
  while [ "$tie_i" -ge 20 ]; do
    tie_id="F09-E03-T$tie_i"
    seed_entry "$ip" "2026-09-15T10:00:00Z" claude-dev "$tie_id" IN_PROGRESS "Tied close $tie_i" '- Summary: w\n- Verify: pending\n- Phase: GREEN\n- Lane: NORMAL\n'
    seed_entry "$ip" "2026-09-15T10:00:00Z" claude-dev "$tie_id" DONE "Tied close $tie_i" '- Summary: d\n- Files: x\n- Verify: exit=0\n- Cross-model: NO\n'
    tie_i=$((tie_i - 1))
  done
  seed_fill "$ip" F09-FILL-13 205
  run rotate "$ip" >/dev/null 2>&1
  tie_got="$(grep '| F09-E03-T[0-9]* | DONE |' "$ip/docs/Agentslog.md" | sed 's/.*| F09-E03-T\([0-9]*\) | DONE.*/\1/' | sort -n | tr '\n' ' ')"
  [ "$tie_got" = "25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 " ] && ok "$label closed tasks with the same timestamp are carried by task id, the same twenty in both launchers" || bad "$label tied tasks carried: $tie_got"

  # ---- the marker of the .gitignore block is found in other writings --------------------------------------------------
  GI_MARK='# project-documentation dispatcher (generated files)'
  for gi_v in bom upper spaces; do
    ip_new "gi_$gi_v"
    run init "$ip" >/dev/null 2>&1
    case "$gi_v" in
      bom) printf '\357\273\277%s\n.factory/state.md\n.factory/runs/\n' "$GI_MARK" > "$ip/.gitignore" ;;
      upper) printf '# PROJECT-DOCUMENTATION DISPATCHER (GENERATED FILES)\n.factory/state.md\n.factory/runs/\n' > "$ip/.gitignore" ;;
      spaces) printf '  %s   \n.factory/state.md\n.factory/runs/\n' "$GI_MARK" > "$ip/.gitignore" ;;
    esac
    cp "$ip/.gitignore" "$WORK/.gi_before"
    run migrate "$ip" --factory >/dev/null 2>&1
    cmp -s "$WORK/.gi_before" "$ip/.gitignore" && ok "$label the .gitignore block is found with a $gi_v marker and not added again" || bad "$label .gitignore changed with a $gi_v marker: $(cat "$ip/.gitignore" | tr -d '\r')"
  done

  # ---- the docs lock: parallel commands do not lose work ---------------------------------------------------------------
  bn_proj par
  for par_i in 1 2 3; do
    ( run learn "$bn" claude-dev F09-E01-T01 PITFALL "Parallel lesson $par_i" "parallel$par_i" "Text $par_i" > "$WORK/.par$par_i" 2>&1 ) &
  done
  wait
  [ "$(grep -c '^| LRN-' "$bnb")" -eq 6 ] && [ "$(grep '^| LRN-' "$bnb" | cut -d'|' -f2 | sort -u | wc -l | tr -d ' ')" -eq 6 ] && ok "$label three lessons added at the same time are three lessons with three ids" || bad "$label parallel learn: $(grep '^| LRN-' "$bnb" | cut -c1-40 | tr '\n' '~') $(cat "$WORK"/.par1 "$WORK"/.par2 "$WORK"/.par3 | tr '\n' '~' | cut -c1-300)"
  # an old lock (a command that died) is taken over once, also when several commands find it at the same time
  bn_proj stale
  mkdir -p "$bn/docs/.lock"
  stale_ok=0
  if touch -d '3 minutes ago' "$bn/docs/.lock" 2>/dev/null; then stale_ok=1
  elif touch -t "$(date -v-3M +%Y%m%d%H%M.%S 2>/dev/null)" "$bn/docs/.lock" 2>/dev/null; then stale_ok=1; fi
  if [ "$stale_ok" -eq 1 ]; then
    for par_i in 1 2 3 4; do
      ( run learn "$bn" claude-dev F09-E01-T01 PITFALL "Stale lesson $par_i" "stale$par_i" "Text $par_i" > "$WORK/.par$par_i" 2>&1 ) &
    done
    wait
    [ "$(grep -c '^| LRN-' "$bnb")" -eq 7 ] && [ ! -e "$bn/docs/.lock" ] && [ ! -e "$bn/docs/.lock.takeover" ] && ok "$label four commands that find an old lock take it over once, lose nothing and leave no lock" || bad "$label stale lock: $(grep -c '^| LRN-' "$bnb") rows, lock $( [ -e "$bn/docs/.lock" ] && echo left || echo gone ), takeover $( [ -e "$bn/docs/.lock.takeover" ] && echo left || echo gone )"
  fi

  echo "== $label: test paths of a spec stay inside the project (F06-DEBT-03) =="
  spec_bad sp_abs 's#tests/billing/export.spec.sh#/etc/export.spec.sh#' "Tests entry '/etc/export.spec.sh' must be a relative path inside the project (no absolute path, drive letter or .. segment)"
  spec_bad sp_drive 's#tests/billing/export.spec.sh#C:/tests/export.spec.sh#' "Tests entry 'C:/tests/export.spec.sh' must be a relative path inside the project"
  spec_bad sp_dots 's#tests/billing/export.spec.sh#../root.test.sh#' "Tests entry '../root.test.sh' must be a relative path inside the project"
  spec_bad sp_dots_mid 's#tests/billing/export.spec.sh#tests/../../x.test.sh#' "Tests entry 'tests/../../x.test.sh' must be a relative path inside the project"
  sp_proj sp_dots_name
  mkspec "$sp" F09-E01-T01
  sedi 's#tests/billing/export.spec.sh#tests/a..b/.hidden.sh#' "$sp/docs/specs/F09-E01-T01.md"
  assert_success "$label a path with dots inside a name is a path inside the project" run check "$sp"

  echo "== $label: the review of a spec is bound to the content it saw (F06-DEBT-02) =="
  adv_proj sha_edit
  adv_reviewed
  sh_now="$(file_hash "$av/docs/specs/F09-E01-T01.md" | awk '{ print $1 }')"
  grep -q "^- Spec-sha: $sh_now\$" "$av/docs/Agentslog.md" && ok "$label the handoff of a spec records its SHA-256" || bad "$label no Spec-sha: $(grep 'Spec-sha' "$av/docs/Agentslog.md")"
  printf '%s\n' '- Excel export, decided after the review' >> "$av/docs/specs/F09-E01-T01.md"
  adv_refused "advance refuses a spec edited after the review that passed it" "docs/specs/F09-E01-T01.md changed after it was handed off for review (the review saw $(printf '%s' "$sh_now" | cut -c1-8)" claude-spec F09-E01-T01 RED "spec reviewed, exit=0"
  run handoff "$av" claude-spec F09-E01-T01 "spec ready again" "exit=0" claude-qa >/dev/null 2>&1
  run review "$av" claude-qa F09-E01-T01 PASS "spec checked again" "exit=0" >/dev/null 2>&1
  run claim "$av" claude-spec F09-E01-T01 "advance it" >/dev/null 2>&1
  assert_success "$label a new handoff and a new review let the edited spec go on" run advance "$av" claude-spec F09-E01-T01 RED "spec reviewed, exit=0"

  adv_proj sha_same
  adv_reviewed
  assert_success "$label an unchanged spec goes on" run advance "$av" claude-spec F09-E01-T01 RED "spec reviewed, exit=0"

  adv_proj sha_rotate
  adv_reviewed
  seed_fill "$av" F09-FILL-10 205
  run rotate "$av" >/dev/null 2>&1
  grep -q '^- Spec-sha: ' "$av/docs/Agentslog.md" && ok "$label rotate carries the SHA-256 of the spec" || bad "$label Spec-sha lost in rotate"
  printf '%s\n' '- A change after the rotation' >> "$av/docs/specs/F09-E01-T01.md"
  adv_refused "the binding still holds after rotate" "changed after it was handed off for review" claude-spec F09-E01-T01 RED "spec reviewed, exit=0"

  adv_proj sha_legacy
  adv_reviewed
  sedi '/^- Spec-sha: /d' "$av/docs/Agentslog.md"
  printf '%s\n' '- A change nobody can compare against' >> "$av/docs/specs/F09-E01-T01.md"
  assert_success "$label a review recorded before the SHA-256 existed has nothing to compare" run advance "$av" claude-spec F09-E01-T01 RED "spec reviewed, exit=0"

  echo "== $label: done closes a normal-lane task only from GREEN (BR-009) =="
  bn_proj gate
  run claim "$bn" claude-spec F09-E01-T01 "write the spec" >/dev/null 2>&1
  run checkpoint "$bn" claude-spec F09-E01-T01 "spec done" "review" >/dev/null 2>&1
  run handoff "$bn" claude-spec F09-E01-T01 "spec ready" "exit=0" claude-qa >/dev/null 2>&1
  run review "$bn" claude-qa F09-E01-T01 PASS "fine" "exit=0" >/dev/null 2>&1
  run retro "$bn" claude-spec F09-E01-T01 none none >/dev/null 2>&1
  brain_refused "done refuses a normal-lane task that never left SPEC, reviewed or not" "done failed: F09-E01-T01 is in phase SPEC; a task of the normal lane closes from GREEN, after a reviewed spec and failing tests (advance moves it)" done "$bn" claude-spec F09-E01-T01 "spec" "docs/" "exit=0"
  [ -f "$bn/docs/Roadmap.md" ] && grep -q 'F09-E01-T01' "$bn/docs/Roadmap.md" && ok "$label the row stays in the Roadmap" || bad "$label the row was removed"
  # a task claimed before the project moved to Factory mode has no phase and is not held to it
  bn_proj legacy
  seed_entry "$bn" "$(now_ts)" claude-spec F09-E01-T01 IN_PROGRESS "Export invoices as CSV" '- Summary: claimed before Factory mode\n- Verify: pending\n'
  run checkpoint "$bn" claude-spec F09-E01-T01 "work" "review" >/dev/null 2>&1
  run handoff "$bn" claude-spec F09-E01-T01 "ready" "exit=0" claude-qa >/dev/null 2>&1
  run review "$bn" claude-qa F09-E01-T01 PASS "fine" "exit=0" >/dev/null 2>&1
  run retro "$bn" claude-spec F09-E01-T01 none none >/dev/null 2>&1
  assert_success "$label a task claimed before Factory mode (no phase at all) may close" run done "$bn" claude-spec F09-E01-T01 "work" "docs/" "exit=0"
  # its retake after a failed review, or from a pause, keeps it as it was: no phase and no lane (ADR-092)
  bn_proj legacy_retake
  seed_entry "$bn" "$(now_ts)" claude-spec F09-E01-T01 IN_PROGRESS "Export invoices as CSV" '- Summary: claimed before Factory mode\n- Verify: pending\n'
  run checkpoint "$bn" claude-spec F09-E01-T01 "work" "review" >/dev/null 2>&1
  run handoff "$bn" claude-spec F09-E01-T01 "ready" "exit=0" claude-qa >/dev/null 2>&1
  run review "$bn" claude-qa F09-E01-T01 FAIL "not yet" "exit=0" >/dev/null 2>&1
  assert_success "$label a task started before Factory mode is retaken after a failed review" run claim "$bn" claude-spec F09-E01-T01 "retake"
  [ "$(grep -c '^- Phase:' "$bn/docs/Agentslog.md")" -eq 0 ] && [ "$(grep -c '^- Lane:' "$bn/docs/Agentslog.md")" -eq 0 ] && ok "$label the retake writes no phase and no lane" || bad "$label the retake invented a phase or a lane: $(grep -E '^- (Phase|Lane):' "$bn/docs/Agentslog.md" | tr '\n' ' ')"
  run checkpoint "$bn" claude-spec F09-E01-T01 "fixed" "review" >/dev/null 2>&1
  run handoff "$bn" claude-spec F09-E01-T01 "fixed" "exit=0" claude-qa >/dev/null 2>&1
  run review "$bn" claude-qa F09-E01-T01 PASS "fine now" "exit=0" >/dev/null 2>&1
  run learn "$bn" claude-spec F09-E01-T01 PITFALL "Run the export before the handoff" "export csv" "Run the export once before asking for a review" >/dev/null 2>&1
  run retro "$bn" claude-spec F09-E01-T01 none LRN-004 >/dev/null 2>&1
  assert_success "$label and it still closes after the retake" run done "$bn" claude-spec F09-E01-T01 "work" "docs/" "exit=0"
  bn_proj legacy_pause
  seed_entry "$bn" "$(now_ts)" claude-spec F09-E01-T01 IN_PROGRESS "Export invoices as CSV" '- Summary: claimed before Factory mode\n- Verify: pending\n'
  run checkpoint "$bn" claude-spec F09-E01-T01 "work" "later" >/dev/null 2>&1
  run pause "$bn" claude-spec F09-E01-T01 OTRO "out for a day" >/dev/null 2>&1
  assert_success "$label a task started before Factory mode is retaken after a pause" run claim "$bn" claude-spec F09-E01-T01 "back"
  [ "$(grep -c '^- Phase:' "$bn/docs/Agentslog.md")" -eq 0 ] && ok "$label the claim after a pause writes no phase" || bad "$label the claim after a pause invented a phase"
  bn_proj legacy_new
  seed_entry "$bn" "$(now_ts)" claude-spec F09-E01-T01 ASSIGNED "Export invoices as CSV" '- Assign: claude-spec\n'
  assert_success "$label a task that was only assigned still starts in SPEC" run claim "$bn" claude-spec F09-E01-T01 "start"
  [ "$(grep -c '^- Phase: SPEC$' "$bn/docs/Agentslog.md")" -eq 1 ] && ok "$label a first claim in Factory mode writes the SPEC phase" || bad "$label first claim phase wrong: $(grep -E '^- Phase:' "$bn/docs/Agentslog.md" | tr '\n' ' ')"
  # append-log is not a way around the lifecycle: it cannot start, hold, assign or close a task (ADR-093)
  bn_proj appendlog
  al_before="$(grep -c '^## \[' "$bn/docs/Agentslog.md")"
  assert_failure "$label append-log refuses to start a task in Factory mode" run append-log "$bn" claude-spec F09-E01-T01 IN_PROGRESS "manual start" docs/ pending
  grep -q 'append-log failed: IN_PROGRESS is a lifecycle status' "$WORK/.out" && ok "$label the refusal names the status" || bad "$label append-log text wrong: $(cat "$WORK/.out")"
  tr '\n\r' '  ' < "$WORK/.out" | tr -s ' ' | grep -qF 'use claim, pause, handoff, review, advance, assign or done' && ok "$label the refusal names the commands to use" || bad "$label append-log refusal does not name the commands: $(cat "$WORK/.out")"
  for al_st in REVIEW PAUSE ASSIGNED DONE; do
    assert_failure "$label append-log refuses $al_st in Factory mode" run append-log "$bn" claude-spec F09-E01-T01 "$al_st" "manual" docs/ pending
  done
  [ "$(grep -c '^## \[' "$bn/docs/Agentslog.md")" = "$al_before" ] && ok "$label a refused append-log writes nothing" || bad "$label a refused append-log wrote an entry"
  assert_success "$label append-log still records an audit in Factory mode" run append-log "$bn" claude-qa F09-E01-T01 AUDIT "audit ok" docs/ "exit=0"
  ip_new al_classic
  run_env PROJECT_DOCS_MODE=classic init "$ip" >/dev/null 2>&1
  assert_success "$label append-log in classic mode keeps accepting every status" run append-log "$ip" claude-spec F09-E01-T01 IN_PROGRESS "manual start" docs/ pending
  # a task that went through advance closes from GREEN (the cases of the evidence block do it with git), and the fast lane starts in GREEN
  ft_proj gate_fast nogit
  run claim "$ft" claude-dev F09-E01-T01 "fix it" >/dev/null 2>&1
  run checkpoint "$ft" claude-dev F09-E01-T01 "started" "fix" >/dev/null 2>&1
  run handoff "$ft" claude-dev F09-E01-T01 "fixed" "exit=0" claude-qa >/dev/null 2>&1
  run review "$ft" claude-qa F09-E01-T01 PASS "fast lane ok" "exit=0" >/dev/null 2>&1
  run retro "$ft" claude-dev F09-E01-T01 none none >/dev/null 2>&1
  assert_success "$label a fast-lane task closes from GREEN without any advance" run done "$ft" claude-dev F09-E01-T01 "fixed" "src/" "exit=0"

#FACTORY_CASES
}

# The dispatcher (F06-E06-T02 to T04), with fake CLIs: scripts/tests/fake_cli.sh and .ps1 read one
# line of a script file per run and call project_docs, so no real quota is ever spent. The suite
# runs the dispatcher of the launcher (factory_dispatch.sh or .ps1) over the project_docs of the
# same launcher.
run_dispatch_suite() {
  label="$1"
  run() { "$RUNNER" "$@"; }
  unset PROJECT_DOCS_MODE
  echo "== $label: the dispatcher passes the turn between fake CLIs (F06-E06-T04) =="
  dp_cmd() {  # the command cell that starts the fake CLI of this launcher
    if [ "$label" = "sh" ]; then
      printf 'sh "%s" "{PROMPT_FILE}"' "$SCRIPT_DIR/tests/fake_cli.sh"
    else
      printf 'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%s" "{PROMPT_FILE}"' "$(to_native_path "$SCRIPT_DIR/tests/fake_cli.ps1")"
    fi
  }
  dp_config() {  # dp_config <project>: the template's tables with the fake CLI as every command
    DP_CMD="$(dp_cmd)" awk -F'|' '
      /^\| (gemini-qa|claude-spec|claude-test|claude-dev|claude-qa) \|/ {
        n = split($0, c, "|")
        printf "|%s|%s| `%s` |", c[2], c[3], ENVIRON["DP_CMD"]
        for (i = 5; i < n; i++) printf "%s|", c[i]
        printf "\n"
        next
      }
      { print }
    ' "$SCRIPT_DIR/../templates/dispatch.md" > "$1/.factory/dispatch.md"
  }
  dp_proj() {  # dp_proj <name>: a Factory project whose dispatcher runs the fake CLI, no task yet
    dp="$WORK/${label}_dp_$1"; rm -rf "$dp"; mkdir -p "$dp"
    run init "$dp" >/dev/null 2>&1
    seed_replace "$dp/docs/Roadmap.md" "| F01-E01-T01 | UNKNOWN | UNKNOWN | UNKNOWN | TODO |" "| F01-E01-T01 | UNKNOWN | UNKNOWN | UNKNOWN | DONE |"
    dp_config "$dp"
    : > "$dp/fake.txt"
  }
  dp_fast() {  # dp_fast <project> <TASK-ID> <title>: a TODO row for a FAST task
    seed_plan_row "$1" "$2" "$3"
    seed_replace "$1/docs/Roadmap.md" "| $2 | $3 | details |" "| $2 | $3 | Lane: FAST $3 |"
  }
  dp_script() {  # dp_script <agent> <actions...>: adds one line to the script of the current project
    dps_a="$1"; shift
    printf '%s: %s\n' "$dps_a" "$*" >> "$dp/fake.txt"
  }
  dp_take() {  # dp_take <TASK> <reviewer>: the run of the developer that takes a FAST task and hands it off
    dp_script claude-dev "ok:claim claude-dev $1 \"fix\" ;; write:src/$1.txt=fixed ;; ok:checkpoint claude-dev $1 \"fixed\" \"hand off\" ;; ok:handoff claude-dev $1 \"fixed\" exit=0 $2"
  }
  dp_close() {  # dp_close <TASK>: the run of the developer that closes a reviewed task
    dp_script claude-dev "ok:retro claude-dev $1 none none ;; ok:done claude-dev $1 \"fixed\" src/$1.txt exit=0"
  }
  dp_run() {  # dp_run [options]: runs the dispatcher of this launcher on $dp; the output stays in $WORK/.out
    if [ "$label" = "sh" ]; then
      ( FAKE_CLI_SCRIPT="$dp/fake.txt"; FAKE_CLI_LOG="$dp/fake.log"; PROJECT_DOCS_DISPATCH_NO_SLEEP=1
        export FAKE_CLI_SCRIPT FAKE_CLI_LOG PROJECT_DOCS_DISPATCH_NO_SLEEP
        if [ -n "${DP_SET_KEYS:-}" ]; then ANTHROPIC_API_KEY=secret-a; GEMINI_API_KEY=secret-b; export ANTHROPIC_API_KEY GEMINI_API_KEY; fi
        sh "$SCRIPT_DIR/factory_dispatch.sh" "$dp" "$@" ) > "$WORK/.out" 2>&1
    else
      ( FAKE_CLI_SCRIPT="$(to_native_path "$dp/fake.txt")"; FAKE_CLI_LOG="$(to_native_path "$dp/fake.log")"; PROJECT_DOCS_DISPATCH_NO_SLEEP=1
        export FAKE_CLI_SCRIPT FAKE_CLI_LOG PROJECT_DOCS_DISPATCH_NO_SLEEP
        if [ -n "${DP_SET_KEYS:-}" ]; then ANTHROPIC_API_KEY=secret-a; GEMINI_API_KEY=secret-b; export ANTHROPIC_API_KEY GEMINI_API_KEY; fi
        "$PWSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(to_native_path "$SCRIPT_DIR/factory_dispatch.ps1")" "$(to_native_path "$dp")" "$@" ) > "$WORK/.out" 2>&1
    fi
    dp_rc=$?
  }
  dp_out() { tr -d '\r' < "$WORK/.out"; }
  dp_has() {  # dp_has <description> <text>: the dispatcher output has the text
    if dp_out | grep -qF -- "$2"; then ok "$label $1"; else bad "$label $1: missing [$2] in: $(dp_out | head -n 14 | tr '\n' '~' | cut -c1-600)"; fi
  }
  dp_lacks() {  # dp_lacks <description> <text>
    if dp_out | grep -qF -- "$2"; then bad "$label $1: found [$2]"; else ok "$label $1"; fi
  }
  dp_last_entry() { awk '/^## \[/ { buf="" } { buf = buf $0 "\n" } END { printf "%s", buf }' "$dp/docs/Agentslog.md" | tr -d '\r'; }
  dp_review_entry() {  # the last entry that holds a review verdict
    awk '/^## \[/ { if (hasrev) keep = buf; buf = ""; hasrev = 0 } { buf = buf $0 "\n" } /^- Review: / { hasrev = 1 } END { if (hasrev) keep = buf; printf "%s", keep }' "$dp/docs/Agentslog.md" | tr -d '\r'
  }
  dp_order() { awk '{ print $1 }' "$dp/fake.log" | tr '\n' ' '; }
  dp_left() { grep -c '' "$dp/fake.txt" | tr -d ' '; }
  dp_next() {  # dp_next <agent>: the first line of next for the agent
    run next "$dp" "$1" 2>&1 | head -n 1 | tr -d '\r'
  }
  dp_sedi() { sed "$1" "$2" > "$2.tmp" && mv "$2.tmp" "$2"; }
  dp_status_line() { run status "$dp" 2>&1 | tr -d '\r' | grep "^$1 |" | head -n 1; }

  # ---- case 22: the turn passes from the developer to the reviewer and back, with nobody in between ----
  dp_proj turn
  dp_fast "$dp" F09-E01-T01 "Fix the typo"
  dp_take F09-E01-T01 gemini-qa
  dp_script gemini-qa "ok:review gemini-qa F09-E01-T01 PASS \"fast lane ok\" exit=0"
  dp_close F09-E01-T01
  dp_run
  [ "$dp_rc" -eq 0 ] && ok "$label the dispatcher ends with exit 0" || bad "$label dispatcher exit $dp_rc: $(dp_out | head -n 8 | tr '\n' '~')"
  dp_has "the developer runs first" "dispatch: run 1: claude-dev on F09-E01-T01"
  dp_has "the reviewer is launched on the same task" "dispatch: run 2: gemini-qa on F09-E01-T01"
  dp_has "the developer is called back to close the reviewed task" "dispatch: run 3: claude-dev on F09-E01-T01"
  dp_has "the summary counts three good runs" "dispatch: summary: runs=3 ok=3 limits=0 failures=0"
  dp_has "the dispatcher stops when there is nothing left to do" "dispatch: nothing to do"
  [ "$(dp_order)" = "claude-dev gemini-qa claude-dev " ] && ok "$label the fake CLIs ran in that order" || bad "$label order: $(dp_order)"
  dp_last_entry > "$WORK/.last"
  grep -q '^## \[.*\] | claude-dev | F09-E01-T01 | DONE | ' "$WORK/.last" && ok "$label the ledger ends with the task DONE" || bad "$label last entry: $(cat "$WORK/.last")"
  [ -f "$dp/.factory/state.md" ] && [ -d "$dp/.factory/runs" ] && ok "$label the dispatcher keeps its state and its run folder under .factory" || bad "$label no state or no runs folder"
  [ "$(ls "$dp/.factory/runs"/*.prompt.md 2>/dev/null | wc -l | tr -d ' ')" = "3" ] && [ "$(ls "$dp/.factory/runs"/*.out 2>/dev/null | wc -l | tr -d ' ')" = "3" ] && ok "$label every run left its prompt and its output" || bad "$label run files: $(ls "$dp/.factory/runs")"
  grep -q 'You are claude-dev (role DEV) in ' "$dp"/.factory/runs/*-001-claude-dev.prompt.md && grep -q 'Task F09-E01-T01, phase GREEN, lane FAST\.' "$dp"/.factory/runs/*-001-claude-dev.prompt.md && ok "$label the prompt names the agent, its role, the task, the phase and the lane" || bad "$label prompt: $(cat "$dp"/.factory/runs/*-001-claude-dev.prompt.md)"

  # ---- --once, options and the guards ---------------------------------------------------------------------------
  dp_proj once
  dp_fast "$dp" F09-E01-T01 "Fix the typo"
  dp_take F09-E01-T01 gemini-qa
  dp_script gemini-qa "ok:review gemini-qa F09-E01-T01 PASS \"fast lane ok\" exit=0"
  dp_run --once
  dp_has "--once makes a single run" "dispatch: summary: runs=1 ok=1 limits=0 failures=0"
  [ "$(dp_left)" = "1" ] && ok "$label the second script line is left for the next run" || bad "$label script lines left: $(dp_left)"
  dp_run --bogus
  [ "$dp_rc" -eq 2 ] && dp_has "an unknown option is refused" "factory_dispatch: unknown option --bogus" || bad "$label unknown option exit $dp_rc: $(dp_out | head -n 3)"
  dp_proj noconfig
  rm -f "$dp/.factory/dispatch.md"
  dp_run
  [ "$dp_rc" -ne 0 ] && dp_has "a project with no .factory/dispatch.md is refused" "dispatch.md does not exist (run init or migrate --factory)" || bad "$label no config accepted"
  dp="$WORK/${label}_dp_classic"; rm -rf "$dp"; mkdir -p "$dp"
  run init "$dp" --classic >/dev/null 2>&1
  mkdir -p "$dp/.factory"; cp "$SCRIPT_DIR/../templates/dispatch.md" "$dp/.factory/dispatch.md"; : > "$dp/fake.txt"
  dp_run
  [ "$dp_rc" -ne 0 ] && dp_has "a classic project is refused" "the project is not in Factory mode" || bad "$label classic project accepted"

  # ---- case 23: Gemini runs out of quota, Claude QA covers the review and the marker says so -------------------
  dp_proj gemini_limit
  dp_fast "$dp" F09-E01-T01 "Fix the typo"
  dp_take F09-E01-T01 gemini-qa
  dp_script gemini-qa "limit:RESOURCE_EXHAUSTED: quota exceeded for this model"
  dp_script claude-qa "ok:review claude-qa F09-E01-T01 PASS \"fast lane ok\" exit=0"
  dp_close F09-E01-T01
  dp_run
  dp_has "the Gemini run is launched first" "dispatch: run 2: gemini-qa on F09-E01-T01"
  dp_has "its quota text puts the gemini plan in cooldown" "dispatch: run 2 limit: gemini-qa hit its limit, plan gemini in cooldown until "
  dp_has "claude-qa takes the review in its place" "dispatch: run 3: claude-qa on F09-E01-T01 (covers gemini-qa)"
  dp_has "the dispatcher then waits for the cooldown" "dispatch: sleep until "
  dp_lacks "no pause is written for an agent that held nothing" "(LIMITE) for gemini-qa"
  dp_review_entry > "$WORK/.last"
  grep -q '^- Review: PASS - fast lane ok$' "$WORK/.last" && grep -q '^- Cross-model: NO$' "$WORK/.last" && ok "$label the covered review carries Cross-model: NO" || bad "$label covered review: $(cat "$WORK/.last")"
  dp_last_entry > "$WORK/.last"
  grep -q '^- Cross-model: NO$' "$WORK/.last" && ok "$label the DONE entry keeps the marker for the audit" || bad "$label DONE entry: $(cat "$WORK/.last")"
  grep -q '^| cooldown:gemini | [0-9][0-9]* |$' "$dp/.factory/state.md" && ok "$label the cooldown of the plan is in the state file" || bad "$label state: $(cat "$dp/.factory/state.md")"
  grep -q 'cooldown:claude' "$dp/.factory/state.md" && bad "$label the claude plan must not be cooling down" || ok "$label the claude plan keeps working while gemini waits"

  # ---- case 24: Claude runs out of quota: every claude agent waits, the owner's task is paused, then resumed -------
  dp_proj claude_limit
  dp_fast "$dp" F09-E01-T01 "Fix the typo"
  dp_script claude-dev "ok:claim claude-dev F09-E01-T01 \"fix\" ;; ok:checkpoint claude-dev F09-E01-T01 \"started\" \"continue\" ;; limit:You've hit your session limit · resets 3:45pm"
  dp_run
  dp_has "the limit text puts the claude plan in cooldown until the reset time" "dispatch: run 1 limit: claude-dev hit its limit, plan claude in cooldown until 15:45"
  dp_has "the dispatcher writes the pause for the owner" "dispatch: run 1 paused F09-E01-T01 (LIMITE) for claude-dev"
  dp_has "with nothing else to run it sleeps until the reset" "dispatch: sleep until 15:45"
  dp_status_line F09-E01-T01 > "$WORK/.line"
  grep -q 'PAUSE' "$WORK/.line" && grep -q 'LIMITE' "$WORK/.line" && ok "$label the task is paused with the LIMITE category" || bad "$label status: $(cat "$WORK/.line")"
  dp_last_entry > "$WORK/.last"
  grep -q '^- Pause: LIMITE - limit until 15:45$' "$WORK/.last" && ok "$label the pause says until when" || bad "$label pause entry: $(cat "$WORK/.last")"
  [ -f "$dp/docs/brain/tasks/F09-E01-T01.md" ] && grep -q 'limit reached' "$dp/docs/brain/tasks/F09-E01-T01.md" && ok "$label the working memory says where the work stopped" || bad "$label working memory missing"
  [ "$(dp_next claude-dev)" = "F09-E01-T01" ] && ok "$label after the cooldown next gives the paused task back to the claude agent" || bad "$label next after the limit: $(dp_next claude-dev)"
  dp_run
  dp_has "while the cooldown lasts nothing runs" "dispatch: sleep until 15:45"
  dp_has "a second pass starts no run" "dispatch: summary: runs=0 ok=0 limits=0 failures=0"
  dp_sedi 's/^| cooldown:claude | [0-9]* |$/| cooldown:claude | 1 |/' "$dp/.factory/state.md"
  dp_script claude-dev "ok:claim claude-dev F09-E01-T01 \"fix\" ;; ok:checkpoint claude-dev F09-E01-T01 \"resumed\" \"hand off\" ;; ok:handoff claude-dev F09-E01-T01 \"fixed\" exit=0 claude-qa"
  dp_script claude-qa "ok:review claude-qa F09-E01-T01 PASS \"fast lane ok\" exit=0"
  dp_close F09-E01-T01
  dp_run
  dp_has "an expired cooldown is dropped and the paused task is resumed" "dispatch: run 1: claude-dev on F09-E01-T01"
  dp_has "the reviewer follows" "dispatch: run 2: claude-qa on F09-E01-T01"
  grep -q 'cooldown:claude' "$dp/.factory/state.md" && bad "$label the expired cooldown stayed in the state file" || ok "$label the expired cooldown left the state file"

  # ---- case 25: failures, fallback, block, the daily cap, the stop file and the audit -----------------------------
  dp_proj two_failures
  dp_fast "$dp" F09-E01-T01 "Fix the typo"
  dp_take F09-E01-T01 gemini-qa
  dp_script gemini-qa "fail:the model said no"
  dp_script gemini-qa "fail:the model said no again"
  dp_script claude-qa "ok:review claude-qa F09-E01-T01 PASS \"fast lane ok\" exit=0"
  dp_close F09-E01-T01
  dp_run
  dp_has "the first failure of the reviewer is counted" "dispatch: run 2 failed (exit 1), 1 failure(s) for gemini-qa on F09-E01-T01"
  dp_has "the second failure of the same review is counted" "dispatch: run 3 failed (exit 1), 2 failure(s) for gemini-qa on F09-E01-T01"
  dp_has "after two failures the fallback reviewer takes the review" "dispatch: run 4: claude-qa on F09-E01-T01 (covers gemini-qa)"
  dp_review_entry > "$WORK/.last"
  grep -q '^- Cross-model: NO$' "$WORK/.last" && ok "$label the fallback review is marked Cross-model: NO" || bad "$label fallback review: $(cat "$WORK/.last")"

  dp_proj blocked
  dp_fast "$dp" F09-E01-T01 "Fix the typo"
  dp_script claude-dev "ok:claim claude-dev F09-E01-T01 \"fix\" ;; ok:checkpoint claude-dev F09-E01-T01 \"started\" \"continue\" ;; fail:the model crashed"
  dp_script claude-dev "fail:the model crashed"
  dp_script claude-dev "fail:the model crashed"
  dp_run
  dp_has "the third failure on a task of its own blocks it" "dispatch: run 3 blocked F09-E01-T01 after 3 failures"
  dp_status_line F09-E01-T01 > "$WORK/.line"
  grep -q 'PAUSE' "$WORK/.line" && grep -q 'BLOQUEO' "$WORK/.line" && ok "$label the task is paused with BLOQUEO" || bad "$label status: $(cat "$WORK/.line")"
  dp_last_entry > "$WORK/.last"
  grep -q '^- Pause: BLOQUEO - dispatcher: 3 runs without progress$' "$WORK/.last" && ok "$label the pause explains what happened" || bad "$label block entry: $(cat "$WORK/.last")"
  dp_has "after the block there is nothing to do" "dispatch: nothing to do"
  [ "$(dp_next claude-dev)" = "none" ] && ok "$label next skips the blocked task" || bad "$label next after the block: $(dp_next claude-dev)"

  dp_proj daily_cap
  dp_fast "$dp" F09-E01-T02 "Second fix"
  dp_fast "$dp" F09-E01-T01 "First fix"
  awk -F'|' '
    $2 ~ /^ claude-dev / { n = split($0, c, "|"); printf "|%s|%s|%s|%s|%s| 1 |%s|\n", c[2], c[3], c[4], c[5], c[6], c[8]; next }
    { print }
  ' "$dp/.factory/dispatch.md" > "$dp/.factory/dispatch.md.tmp" && mv "$dp/.factory/dispatch.md.tmp" "$dp/.factory/dispatch.md"
  dp_take F09-E01-T01 claude-qa
  dp_take F09-E01-T02 claude-qa
  dp_script claude-qa "ok:review claude-qa F09-E01-T01 PASS \"fast lane ok\" exit=0"
  dp_run
  dp_has "the developer runs once" "dispatch: run 1: claude-dev on F09-E01-T01"
  dp_has "the reviewer runs once" "dispatch: run 2: claude-qa on F09-E01-T01"
  dp_lacks "the developer is not launched again today" "dispatch: run 3"
  dp_has "the summary shows two runs" "dispatch: summary: runs=2 ok=2 limits=0 failures=0"
  [ "$(dp_left)" = "1" ] && ok "$label the second developer line was never consumed" || bad "$label lines left: $(dp_left)"
  grep -q '^| runs:claude-dev:[0-9-]* | 1 |$' "$dp/.factory/state.md" && ok "$label the runs of the day are counted in the state file" || bad "$label state: $(cat "$dp/.factory/state.md")"

  dp_proj stop
  dp_fast "$dp" F09-E01-T01 "Fix the typo"
  dp_script claude-dev "write:.factory/STOP=stop ;; ok:claim claude-dev F09-E01-T01 \"fix\" ;; ok:checkpoint claude-dev F09-E01-T01 \"started\" \"continue\""
  dp_script claude-dev "ok:checkpoint claude-dev F09-E01-T01 \"more\" \"continue\""
  dp_run
  dp_has "the run in progress finishes" "dispatch: run 1 ok"
  dp_has "the stop file ends the loop" "dispatch: stop requested"
  dp_has "no second run starts" "dispatch: summary: runs=1 ok=1 limits=0 failures=0"
  [ "$(dp_left)" = "1" ] && ok "$label the next line stays in the script" || bad "$label lines left: $(dp_left)"

  dp_proj audit
  seed_replace "$dp/AGENTS.md" "| Mode | FACTORY |" "| Mode | FACTORY |
| Preferred reviewer | gemini-qa |"
  seed_plan_row "$dp" F09-E01-T10 "Reviewed by one model"
  seed_entry "$dp" "$(now_ts)" claude-dev F09-E01-T10 IN_PROGRESS "Reviewed by one model" '- Summary: w\n- Verify: pending\n- Phase: GREEN\n- Lane: NORMAL\n'
  seed_entry "$dp" "$(now_ts)" claude-qa F09-E01-T10 REVIEW "Reviewed by one model" '- Summary: r\n- Verify: exit=0\n- Review: PASS - ok\n- Cross-model: NO\n'
  seed_entry "$dp" "$(now_ts)" claude-dev F09-E01-T10 DONE "Reviewed by one model" '- Summary: d\n- Files: x\n- Verify: exit=0\n- Cross-model: NO\n'
  dp_script gemini-qa "ok:append-log gemini-qa F09-E01-T10 AUDIT \"audited, nothing wrong\" src/ exit=0"
  dp_run
  dp_has "with no other work the preferred reviewer audits" "dispatch: run 1: gemini-qa on F09-E01-T10"
  dp_has "the audit run is a good run" "dispatch: summary: runs=1 ok=1 limits=0 failures=0"
  dp_last_entry > "$WORK/.last"
  grep -q '^## \[.*\] | gemini-qa | F09-E01-T10 | AUDIT' "$WORK/.last" && ok "$label the audit is an AUDIT entry of the preferred reviewer" || bad "$label audit entry: $(cat "$WORK/.last")"
  run status "$dp" > "$WORK/.out" 2>&1
  ! grep -q 'F09-E01-T10' "$WORK/.out" && ok "$label the audit does not reopen the task" || bad "$label task reopened: $(cat "$WORK/.out")"
  dp_script gemini-qa "fail:no second audit expected"
  dp_run
  dp_has "an audited task is not audited again" "dispatch: nothing to do"

  # ---- round 2 of the QA: no spin, paths, numbers, keys, plans, reset forms ---------------------------------------
  echo "== $label: the dispatcher after the QA of 2b97a0b =="
  # a pause that is refused ends the pair for the day instead of starting it again for ever
  dp_proj nospin
  dp_fast "$dp" F09-E01-T01 "Fix the typo"
  dp_script claude-dev "write:docs/brain/tasks/F09-E01-T01.md=this is not a working memory ;; ok:claim claude-dev F09-E01-T01 \"fix\" ;; fail:boom"
  dp_script claude-dev "fail:boom"
  dp_script claude-dev "fail:boom"
  dp_script claude-dev "fail:boom"
  dp_run
  dp_has "the third failure tries to block the task" "dispatch: run 3 could not block F09-E01-T01 (pause was refused)"
  dp_lacks "a refused pause is not logged as blocked" "dispatch: run 3 blocked"
  dp_lacks "no fourth run starts" "dispatch: run 4"
  dp_has "the dispatcher ends with nothing to do" "dispatch: nothing to do"
  dp_has "three failures are in the summary" "dispatch: summary: runs=3 ok=0 limits=0 failures=3"
  [ "$(dp_left)" = "1" ] && ok "$label the fourth line of the script stays unused" || bad "$label script lines left: $(dp_left)"
  grep -q '^| fails:claude-dev:F09-E01-T01 | 3 |$' "$dp/.factory/state.md" && ok "$label the counter stays at three, so the pair is skipped" || bad "$label state: $(cat "$dp/.factory/state.md")"

  # a failure followed by a success clears the counter
  dp_proj clear
  dp_fast "$dp" F09-E01-T01 "Fix the typo"
  dp_script claude-dev "fail:first try"
  dp_script claude-dev "ok:claim claude-dev F09-E01-T01 \"fix\" ;; ok:checkpoint claude-dev F09-E01-T01 \"started\" \"continue\""
  dp_run --once
  grep -q '^| fails:claude-dev:F09-E01-T01 | 1 |$' "$dp/.factory/state.md" && ok "$label a failed run is counted" || bad "$label state after one failure: $(cat "$dp/.factory/state.md")"
  dp_run --once
  ! grep -q 'fails:' "$dp/.factory/state.md" && ok "$label a good run clears the counter" || bad "$label state after a good run: $(cat "$dp/.factory/state.md")"

  # options and the project folder
  dp_proj opts
  dp_run -x
  [ "$dp_rc" -eq 2 ] && dp_has "a dash option the dispatcher does not know is refused" "factory_dispatch: unknown option -x" || bad "$label -x exit $dp_rc: $(dp_out | head -n 3)"
  dp_save="$dp"; dp="$WORK/${label}_dp_never_made"; rm -rf "$dp"
  dp_run
  [ "$dp_rc" -eq 1 ] && dp_has "a project folder that does not exist is refused" "factory_dispatch: project folder not found" || bad "$label missing folder exit $dp_rc: $(dp_out | head -n 3)"
  dp="$dp_save"
  dp_run --watch
  dp_has "--watch waits for new work when there is none" "dispatch: waiting 300 seconds for new work"

  # a relative project path (the CLI runs inside the project, so the paths it gets are absolute)
  if [ "$label" = "sh" ]; then
    dp_proj rel
    dp_fast "$dp" F09-E01-T01 "Fix the typo"
    dp_script claude-dev "exec:test -f \"\$FACTORY_PROMPT_FILE\" && echo prompt-found ;; ok:claim claude-dev F09-E01-T01 \"fix\" ;; ok:checkpoint claude-dev F09-E01-T01 \"started\" \"continue\""
    ( cd "$(dirname "$dp")" && FAKE_CLI_SCRIPT="$dp/fake.txt"; FAKE_CLI_LOG="$dp/fake.log"; PROJECT_DOCS_DISPATCH_NO_SLEEP=1
      export FAKE_CLI_SCRIPT FAKE_CLI_LOG PROJECT_DOCS_DISPATCH_NO_SLEEP
      sh "$SCRIPT_DIR/factory_dispatch.sh" "$(basename "$dp")" --once ) > "$WORK/.out" 2>&1
    dp_has "a relative project path works" "dispatch: run 1 ok"
    cat "$dp"/.factory/runs/*.out | grep -q '^prompt-found$' && ok "$label the CLI finds its prompt file" || bad "$label prompt path: $(cat "$dp"/.factory/runs/*.out)"
  fi

  # a cooldown that is not a number takes 60 minutes; a configuration with CRLF endings is read
  dp_proj badcool
  dp_fast "$dp" F09-E01-T01 "Fix the typo"
  awk -F'|' '$2 ~ /^ claude-dev / { n = split($0, c, "|"); printf "|%s|%s|%s|%s| abc |%s|%s|\n", c[2], c[3], c[4], c[5], c[7], c[8]; next } { print }' "$dp/.factory/dispatch.md" > "$dp/.factory/dispatch.md.tmp" && mv "$dp/.factory/dispatch.md.tmp" "$dp/.factory/dispatch.md"
  dp_script claude-dev "ok:claim claude-dev F09-E01-T01 \"fix\" ;; ok:checkpoint claude-dev F09-E01-T01 \"started\" \"continue\" ;; limit:You've hit your session limit"
  dp_run
  dp_has "a limit with no reset time and a bad Cooldown cell still sets a cooldown" "plan claude in cooldown until"
  dp_cd="$(sed -n 's/^| cooldown:claude | \([0-9]*\) |$/\1/p' "$dp/.factory/state.md")"
  dp_now="$(date +%s)"
  [ -n "$dp_cd" ] && [ "$dp_cd" -ge $((dp_now + 3300)) ] && [ "$dp_cd" -le $((dp_now + 3900)) ] && ok "$label the cooldown is about sixty minutes" || bad "$label cooldown epoch $dp_cd, now $dp_now"
  dp_proj crlf
  dp_fast "$dp" F09-E01-T01 "Fix the typo"
  sed 's/$/\r/' "$dp/.factory/dispatch.md" > "$dp/.factory/dispatch.md.tmp" && mv "$dp/.factory/dispatch.md.tmp" "$dp/.factory/dispatch.md"
  dp_script claude-dev "ok:claim claude-dev F09-E01-T01 \"fix\" ;; ok:checkpoint claude-dev F09-E01-T01 \"started\" \"continue\""
  dp_run --once
  dp_has "a configuration with CRLF endings finds its agents" "dispatch: run 1: claude-dev on F09-E01-T01"

  # API keys are not handed over: the CLIs use the login of the subscription
  dp_proj keys
  dp_fast "$dp" F09-E01-T01 "Fix the typo"
  dp_script claude-dev "env:ANTHROPIC_API_KEY ;; env:GEMINI_API_KEY ;; ok:claim claude-dev F09-E01-T01 \"fix\" ;; ok:checkpoint claude-dev F09-E01-T01 \"started\" \"continue\""
  DP_SET_KEYS=1 dp_run --once
  cat "$dp"/.factory/runs/*.out > "$WORK/.keys"
  tr -d '\r' < "$WORK/.keys" | grep -q '^ANTHROPIC_API_KEY=unset$' && tr -d '\r' < "$WORK/.keys" | grep -q '^GEMINI_API_KEY=unset$' && ! grep -q 'secret' "$WORK/.keys" && ok "$label the API key variables of the dispatcher do not reach the CLI" || bad "$label keys: $(cat "$WORK/.keys")"

  # one plan, one quota: a limit of claude-dev keeps claude-qa waiting too
  dp_proj planwide
  dp_fast "$dp" F09-E01-T02 "Second typo"
  dp_fast "$dp" F09-E01-T01 "Fix the typo"
  dp_take F09-E01-T01 claude-qa
  dp_script claude-dev "ok:claim claude-dev F09-E01-T02 \"fix\" ;; ok:checkpoint claude-dev F09-E01-T02 \"started\" \"continue\" ;; limit:You've hit your session limit · resets 3:45pm"
  dp_script claude-qa "ok:review claude-qa F09-E01-T01 PASS \"fast lane ok\" exit=0"
  dp_run
  dp_has "the limit of claude-dev puts the claude plan in cooldown" "dispatch: run 2 limit: claude-dev hit its limit, plan claude in cooldown until 15:45"
  dp_lacks "claude-qa, of the same plan, does not run" "claude-qa on F09-E01-T01"
  dp_has "the dispatcher waits for the plan" "dispatch: sleep until 15:45"
  [ "$(dp_left)" = "1" ] && ok "$label the review waits in the script" || bad "$label script lines left: $(dp_left)"

  # the forms of the reset time, and a limit text in capitals
  dp_limit_case() {  # dp_limit_case <name> <output of the CLI> <HH:MM the cooldown ends>
    dp_proj "$1"
    dp_fast "$dp" F09-E01-T01 "Fix the typo"
    dp_script claude-dev "ok:claim claude-dev F09-E01-T01 \"fix\" ;; ok:checkpoint claude-dev F09-E01-T01 \"started\" \"continue\" ;; limit:$2"
    dp_run --once
    dp_has "the reset time in [$2] ends the cooldown at $3" "plan claude in cooldown until $3"
  }
  dp_limit_case reset_midnight "You've hit your session limit · resets 12am" 00:00
  dp_limit_case reset_hour "You've hit your weekly limit - resets 9am" 09:00
  dp_limit_case reset_caps "YOU'VE HIT YOUR SESSION LIMIT. RESETS 11:30PM" 23:30
  dp_limit_case reset_24h "You've hit your opus limit, resets 15:45" 15:45

  # a Cooldown of 0 is 60 minutes; a file is not a project folder; a pause that is refused after a limit
  dp_proj zerocool
  dp_fast "$dp" F09-E01-T01 "Fix the typo"
  awk -F'|' '$2 ~ /^ claude-dev / { n = split($0, c, "|"); printf "|%s|%s|%s|%s| 0 |%s|%s|\n", c[2], c[3], c[4], c[5], c[7], c[8]; next } { print }' "$dp/.factory/dispatch.md" > "$dp/.factory/dispatch.md.tmp" && mv "$dp/.factory/dispatch.md.tmp" "$dp/.factory/dispatch.md"
  dp_script claude-dev "ok:claim claude-dev F09-E01-T01 \"fix\" ;; ok:checkpoint claude-dev F09-E01-T01 \"started\" \"continue\" ;; limit:You've hit your session limit"
  dp_run --once
  dp_cd="$(sed -n 's/^| cooldown:claude | \([0-9]*\) |$/\1/p' "$dp/.factory/state.md")"
  dp_now="$(date +%s)"
  [ -n "$dp_cd" ] && [ "$dp_cd" -ge $((dp_now + 3300)) ] && ok "$label a Cooldown minutes of 0 waits sixty minutes, not none" || bad "$label cooldown epoch $dp_cd, now $dp_now"
  dp_proj notfolder
  dp_save="$dp"; dp="$dp_save/.factory/dispatch.md"
  dp_run
  [ "$dp_rc" -eq 1 ] && dp_has "a file given as the project is refused like a missing folder" "factory_dispatch: project folder not found" || bad "$label file as project exit $dp_rc: $(dp_out | head -n 3)"
  dp="$dp_save"
  dp_proj limitrefused
  dp_fast "$dp" F09-E01-T01 "Fix the typo"
  dp_script claude-dev "write:docs/brain/tasks/F09-E01-T01.md=this is not a working memory ;; ok:claim claude-dev F09-E01-T01 \"fix\" ;; limit:You've hit your session limit"
  dp_run
  dp_has "a refused pause after a limit is logged as it is" "dispatch: run 1 could not pause F09-E01-T01 for claude-dev (pause was refused)"
  dp_lacks "it is not logged as paused" "paused F09-E01-T01 (LIMITE)"
  dp_has "the plan still waits" "dispatch: sleep until "

  # the actions of the fake CLI that the other cases do not use
  dp_proj actions
  dp_fast "$dp" F09-E01-T01 "Fix the typo"
  dp_script claude-dev "exec:git rev-parse --verify nothing-here-at-all ;; write:code1.txt=code {EXIT} ;; git:--version ;; tryok:handoff claude-dev F09-E01-T01 \"x\" exit=0 ;; write:code2.txt=code {EXIT} ;; ok:claim claude-dev F09-E01-T01 \"fix\" ;; ok:checkpoint claude-dev F09-E01-T01 \"started\" \"continue\""
  dp_run --once
  [ "$(tr -d '\r' < "$dp/code1.txt")" = "code 128" ] && ok "$label exec leaves its exit code in {EXIT}" || bad "$label code1: $(cat "$dp/code1.txt" 2>&1)"
  [ "$(tr -d '\r' < "$dp/code2.txt")" = "code 1" ] && ok "$label tryok does not end the line and leaves its exit code in {EXIT}" || bad "$label code2: $(cat "$dp/code2.txt" 2>&1)"
  dp_has "the action line ran to its end" "dispatch: run 1 ok"
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
# skips the pre-factory suite and SMOKE_ONLY=dispatch runs only the dispatcher suite. Two
# snapshots can run in parallel, one per launcher.
SMOKE_LAUNCHERS="${SMOKE_LAUNCHERS:-sh ps1}"
SMOKE_ONLY="${SMOKE_ONLY:-}"
want_launcher() { case " $SMOKE_LAUNCHERS " in *" $1 "*) return 0 ;; esac; return 1; }

RUNNER="sh_runner"
sh_runner() { sh "$SH_BIN" "$@"; }
if want_launcher sh; then
  echo "### sh: $SH_BIN ###"
  [ "$SMOKE_ONLY" = "factory" ] || [ "$SMOKE_ONLY" = "dispatch" ] || run_suite sh
  [ "$SMOKE_ONLY" = "dispatch" ] || run_factory_suite sh
  run_dispatch_suite sh
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
  [ "$SMOKE_ONLY" = "factory" ] || [ "$SMOKE_ONLY" = "dispatch" ] || run_suite ps1
  [ "$SMOKE_ONLY" = "dispatch" ] || run_factory_suite ps1
  run_dispatch_suite ps1
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
