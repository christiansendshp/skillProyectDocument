#!/usr/bin/env sh
# dogfood.sh <sh|ps1> [workdir]
#
# The dogfooding run of section 8 of docs/features/ia-factory.md (steps 1 to 5 and 7; the real CLIs of
# step 6 and the repository adopting Factory mode of step 8 are described in docs/features/
# ia-factory-dogfooding.md). It builds a Factory project, writes
# the script the fake CLIs follow, and then lets the dispatcher run the whole lifecycle one run at a
# time (--once): the driver only reads (context, recall, digest, status, check, next) and moves the
# clock of a cooldown. Everything that changes the project is done by a fake agent the dispatcher
# launched. Nothing here spends the quota of Claude or Gemini.
#
#   F90-E01-T01  normal lane: spec, spec review by gemini-qa, RED, GREEN, a failed review, GREEN again,
#                Gemini out of quota, claude-qa covers the review, retro with a lesson, done, audit
#   F90-E01-T02  fast lane from end to end, reviewed by the fallback reviewer
#   F90-E01-T03  fast lane that outgrows the lane and goes back to SPEC
#   F90-E01-T04  a red line: paused for a person, skipped by next, listed by digest
#
# Prints the measurements of the run and exits 1 when an expectation fails.
set -u

LAUNCHER="${1:-sh}"
case "$LAUNCHER" in sh|ps1) ;; *) echo "usage: dogfood.sh sh|ps1 [workdir]" >&2; exit 2 ;; esac
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SCRIPTS="$(CDPATH= cd -- "$HERE/.." && pwd)"
WORK="${2:-$(mktemp -d "${TMPDIR:-/tmp}/dogfood.XXXXXX")}"
mkdir -p "$WORK"
P="$WORK/dogfood project"
rm -rf "$P"; mkdir -p "$P"
FAKE="$WORK/fake.txt"; FLOG="$WORK/fake.log"
: > "$FAKE"; rm -f "$FLOG"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

nat() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
PWSH=""
if [ "$LAUNCHER" = "ps1" ]; then
  if command -v pwsh >/dev/null 2>&1; then PWSH="pwsh"
  elif command -v powershell.exe >/dev/null 2>&1; then PWSH="powershell.exe"
  else echo "no PowerShell on PATH" >&2; exit 2; fi
fi

core() {  # core <command> <project> [args...]: the project_docs of this launcher
  if [ "$LAUNCHER" = "sh" ]; then sh "$SCRIPTS/project_docs.sh" "$@"; return $?; fi
  dc_cmd="$1"; dc_proj="$2"; shift 2
  dc_line="& '$(nat "$SCRIPTS/project_docs.ps1")' '$dc_cmd' '$(nat "$dc_proj")'"
  for dc_a in "$@"; do dc_line="$dc_line '$(printf '%s' "$dc_a" | sed "s/'/''/g")'"; done
  "$PWSH" -NoProfile -NonInteractive -Command "$dc_line"
}
dispatch() {  # dispatch [options]: one invocation of the dispatcher of this launcher
  if [ "$LAUNCHER" = "sh" ]; then
    ( FAKE_CLI_SCRIPT="$FAKE"; FAKE_CLI_LOG="$FLOG"; PROJECT_DOCS_DISPATCH_NO_SLEEP=1
      export FAKE_CLI_SCRIPT FAKE_CLI_LOG PROJECT_DOCS_DISPATCH_NO_SLEEP
      sh "$SCRIPTS/factory_dispatch.sh" "$P" "$@" )
  else
    ( FAKE_CLI_SCRIPT="$(nat "$FAKE")"; FAKE_CLI_LOG="$(nat "$FLOG")"; PROJECT_DOCS_DISPATCH_NO_SLEEP=1
      export FAKE_CLI_SCRIPT FAKE_CLI_LOG PROJECT_DOCS_DISPATCH_NO_SLEEP
      "$PWSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(nat "$SCRIPTS/factory_dispatch.ps1")" "$(nat "$P")" "$@" )
  fi
}
bytes() { tr -d '\r' | wc -c | tr -d ' '; }
row_after() {  # row_after <file> <anchor start> <row>: puts a row right after the line that starts with the anchor
  RA_ROW="$3" awk -v a="$2" 'BEGIN { n = length(a) } { print } substr($0, 1, n) == a && !done { print ENVIRON["RA_ROW"]; done = 1 }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# ---- the setup: what a person does once ------------------------------------------------------------
echo "== setup ($LAUNCHER): a Factory project with the roster of D-21 =="
core init "$P" >/dev/null 2>&1
for dg_c in "user.email dogfood@example.invalid" "user.name Dogfood" "commit.gpgsign false"; do
  git -C "$P" init -q 2>/dev/null; git -C "$P" config $dg_c
done
# settings: the preferred and the fallback reviewer, and a fast lane of two files
row_after "$P/AGENTS.md" "| Mode | FACTORY |" "| Fast lane max files | 2 |"
row_after "$P/AGENTS.md" "| Mode | FACTORY |" "| Fallback reviewer | claude-qa |"
row_after "$P/AGENTS.md" "| Mode | FACTORY |" "| Preferred reviewer | gemini-qa |"
# the work: the template stub becomes done and four real rows take its place (each goes right after it)
awk '{ if ($0 ~ /^\| F01-E01-T01 \| UNKNOWN \| UNKNOWN \| UNKNOWN \| TODO \|/) sub(/TODO/, "DONE"); print }' "$P/docs/Roadmap.md" > "$P/docs/Roadmap.md.tmp" && mv "$P/docs/Roadmap.md.tmp" "$P/docs/Roadmap.md"
row_after "$P/docs/Roadmap.md" "| F01-E01-T01 |" "| F90-E01-T04 | Delete the production invoice archive | Remove every archived invoice from the production store | The archive is empty | TODO | — | — | — |"
row_after "$P/docs/Roadmap.md" "| F01-E01-T01 |" "| F90-E01-T03 | Update three configuration files | Point three configuration files at the new endpoint. Lane: FAST | The files name the new endpoint | TODO | — | — | — |"
row_after "$P/docs/Roadmap.md" "| F01-E01-T01 |" "| F90-E01-T02 | Fix the typo in the readme | Fix the typo in the readme heading. Lane: FAST | The heading is spelled right | TODO | — | — | — |"
row_after "$P/docs/Roadmap.md" "| F01-E01-T01 |" "| F90-E01-T01 | Round invoice totals half up | Round every invoice total half up to two decimals when it is shown | The total of the sample invoice reads 1.24 | TODO | — | — | — |"
# the dispatcher configuration: the fake CLI of this launcher as every command
if [ "$LAUNCHER" = "sh" ]; then
  DF_CMD="sh \"$SCRIPTS/tests/fake_cli.sh\" \"{PROMPT_FILE}\""
else
  DF_CMD="powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"$(nat "$SCRIPTS/tests/fake_cli.ps1")\" \"{PROMPT_FILE}\""
fi
DF_CMD="$DF_CMD" awk '
  /^\| (gemini-qa|claude-spec|claude-test|claude-dev|claude-qa) \|/ {
    n = split($0, c, "|")
    printf "|%s|%s| `%s` |", c[2], c[3], ENVIRON["DF_CMD"]
    for (i = 5; i < n; i++) printf "%s|", c[i]
    printf "\n"
    next
  }
  { print }
' "$SCRIPTS/../templates/dispatch.md" > "$P/.factory/dispatch.md"
git -C "$P" add -A >/dev/null 2>&1; git -C "$P" commit -q -m "base" >/dev/null 2>&1

# ---- the script of the fake agents: one line per run of an agent, in the order its runs come ----------------
cat > "$FAKE" <<'EOF'
claude-spec: ok:claim claude-spec F90-E01-T01 "write the spec" ;; write:docs/specs/F90-E01-T01.md=# Spec F90-E01-T01 — Round invoice totals half up\n\n## Summary\n\n- Goal: Show every invoice total rounded half up to two decimals\n- Rules: —\n- Tags: invoice total rounding src/\n<!-- context:end -->\n\n## Scenarios\n\n| ID | Given | When | Then | Level | Justification |\n|---|---|---|---|---|---|\n| S01 | The sample invoice adds up to 1.235 | The total is shown | It reads 1.24 | UNIT | — |\n| S02 | The readme describes the rounding | A maintainer reads it | The rule is documented | NONE | Docs only, reviewed by the QA agent |\n\n## Tests\n\n- tests/check.sh (S01)\n\n## Out of scope\n\n- Other currencies ;; ok:checkpoint claude-spec F90-E01-T01 "spec written" "hand it to a reviewer" ;; ok:handoff claude-spec F90-E01-T01 "spec ready for review" exit=0 gemini-qa
gemini-qa: ok:review gemini-qa F90-E01-T01 PASS "the spec is clear and testable" exit=0
claude-spec: ok:claim claude-spec F90-E01-T01 "continue after the review" ;; ok:advance claude-spec F90-E01-T01 RED "spec reviewed, exit=0"
claude-spec: ok:claim claude-spec F90-E01-T04 "look at the task" ;; ok:checkpoint claude-spec F90-E01-T04 "it deletes production data" "wait for a person" ;; ok:pause claude-spec F90-E01-T04 ESPERA_RESPUESTA "RED-LINE: deletes production data"
claude-test: ok:claim claude-test F90-E01-T01 "write the failing test" ;; write:tests/check.sh=#!/bin/sh\ngrep -q '^1.24' src/total.txt ;; git:add -A ;; git:commit -q -m tests ;; exec:sh tests/check.sh ;; ok:checkpoint claude-test F90-E01-T01 "test written, it fails" "implement" ;; ok:advance claude-test F90-E01-T01 GREEN "the test fails first, exit={EXIT}"
claude-dev: ok:claim claude-dev F90-E01-T01 "implement the rounding" ;; write:src/total.txt=1.24\nDEBUG total printed ;; exec:sh tests/check.sh ;; ok:checkpoint claude-dev F90-E01-T01 "implemented" "hand off" ;; ok:handoff claude-dev F90-E01-T01 "rounding implemented" exit={EXIT} gemini-qa
gemini-qa: ok:review gemini-qa F90-E01-T01 FAIL "a debug line is left in src/total.txt"
claude-dev: ok:claim claude-dev F90-E01-T01 "fix what the review found" ;; write:src/total.txt=1.24 ;; exec:sh tests/check.sh ;; ok:learn claude-dev F90-E01-T01 PITFALL "Debug output left in the results" total "Search the change for debug prints before the handoff" ;; ok:checkpoint claude-dev F90-E01-T01 "debug line removed" "hand off" ;; ok:handoff claude-dev F90-E01-T01 "no debug line left" exit={EXIT} gemini-qa
gemini-qa: limit:RESOURCE_EXHAUSTED: quota exceeded for this model
claude-dev: ok:claim claude-dev F90-E01-T02 "fix the typo" ;; write:readme.txt=Invoices ;; exec:sh tests/check.sh ;; ok:checkpoint claude-dev F90-E01-T02 "typo fixed" "hand off" ;; ok:handoff claude-dev F90-E01-T02 "typo fixed" exit={EXIT}
claude-dev: ok:claim claude-dev F90-E01-T03 "update the configuration" ;; write:conf/a.txt=endpoint ;; write:conf/b.txt=endpoint ;; write:conf/c.txt=endpoint ;; ok:checkpoint claude-dev F90-E01-T03 "three files changed" "hand off" ;; tryok:handoff claude-dev F90-E01-T03 "configuration updated" exit=0 ;; exec:git checkout -q -b wip/F90-E01-T03 && git add conf && git commit -q -m wip && git checkout -q - ;; ok:advance claude-dev F90-E01-T03 SPEC "the task outgrew the lane, exit=1" ;; exec:sed s/Lane:.FAST// docs/Roadmap.md > docs/Roadmap.md.tmp && mv docs/Roadmap.md.tmp docs/Roadmap.md
claude-spec: ok:claim claude-spec F90-E01-T03 "spec the larger task" ;; ok:checkpoint claude-spec F90-E01-T03 "it touches three files" "split it first" ;; ok:pause claude-spec F90-E01-T03 OTRO "split it into smaller tasks first"
claude-qa: ok:review claude-qa F90-E01-T02 PASS "the typo is fixed" exit=0
claude-dev: ok:retro claude-dev F90-E01-T02 none none ;; ok:done claude-dev F90-E01-T02 "typo fixed" readme.txt exit=0
claude-qa: ok:review claude-qa F90-E01-T01 PASS "the debug line is gone and the test passes" exit=0
claude-dev: ok:retro claude-dev F90-E01-T01 LRN-001 LRN-004 ;; ok:done claude-dev F90-E01-T01 "rounding half up" src/total.txt exit=0
gemini-qa: ok:append-log gemini-qa F90-E01-T01 AUDIT "audited after the quota came back, nothing wrong" src/ exit=0
EOF

# ---- the run: one dispatcher run at a time, and the reads of the measurements --------------------------------
echo "== run ($LAUNCHER): the dispatcher passes the turn =="
CTX_MAX=0; RECALL_BYTES=""; RECALL_ROWS=""; RUNS=0; MAXRUNS=40; AUDITED=0
while [ "$RUNS" -lt "$MAXRUNS" ]; do
  dispatch --once > "$WORK/.run" 2>&1
  tr -d '\r' < "$WORK/.run" | grep -E '^dispatch: (run|sleep|nothing|stop)' | grep -v '^dispatch: run [0-9]* ok$' | sed 's/^/  /'
  c="$(core context "$P" 2>/dev/null | bytes)"; [ "$c" -gt "$CTX_MAX" ] && CTX_MAX="$c"
  if [ -z "$RECALL_BYTES" ] && core status "$P" 2>/dev/null | tr -d '\r' | grep -q '^F90-E01-T01 .* | GREEN NORMAL$'; then
    core recall "$P" F90-E01-T01 > "$WORK/.recall" 2>/dev/null
    RECALL_BYTES="$(bytes < "$WORK/.recall")"
    RECALL_ROWS="$(tr -d '\r' < "$WORK/.recall" | tail -n 1)"
  fi
  if tr -d '\r' < "$WORK/.run" | grep -q '^dispatch: summary: runs=0 '; then
    # nothing could run: the quota of the gemini plan is out; let the cooldown pass once and look again
    if [ "$AUDITED" -eq 0 ] && grep -q 'cooldown:gemini' "$P/.factory/state.md" 2>/dev/null; then
      sed 's/^| cooldown:gemini | [0-9]* |$/| cooldown:gemini | 1 |/' "$P/.factory/state.md" > "$P/.factory/state.md.tmp" && mv "$P/.factory/state.md.tmp" "$P/.factory/state.md"
      AUDITED=1
      echo "  (the cooldown of the gemini plan is over)"
      RUNS=$((RUNS + 1))
      continue
    fi
    break
  fi
  RUNS=$((RUNS + 1))
done

# ---- the results ----------------------------------------------------------------------------------------------------------
echo "== results ($LAUNCHER) =="
LEDGER="$P/docs/Agentslog.md"
core check "$P" > "$WORK/.check" 2>&1 && ok "check passes on the project after the run" || bad "check failed: $(tail -n 4 "$WORK/.check" | tr '\n' '~')"
core status "$P" 2>&1 | tr -d '\r' > "$WORK/.status"
! grep -q '^F90-E01-T01 ' "$WORK/.status" && ! grep -q '^F90-E01-T02 ' "$WORK/.status" && ok "the normal and the fast task are closed" || bad "tasks still open: $(cat "$WORK/.status")"
grep -q '^F90-E01-T03 .* PAUSE .*SPEC NORMAL$' "$WORK/.status" && ok "the task that outgrew the fast lane is back in SPEC (paused for a person)" || bad "T03 status: $(grep T03 "$WORK/.status")"
grep -q '^F90-E01-T04 .* PAUSE .*SPEC NORMAL$' "$WORK/.status" && ok "the red line task waits for a person" || bad "T04 status: $(grep T04 "$WORK/.status")"
core next "$P" claude-spec 2>&1 | tr -d '\r' | head -n 1 | grep -qx 'none' && ok "next skips the red line and the paused tasks" || bad "next for claude-spec gives work"
grep -E "^## \[[^]]*\] \| gemini-qa \| F90-E01-T01 \| REVIEW" "$LEDGER" >/dev/null && ok "gemini-qa reviewed the task" || bad "no review by gemini-qa"
awk '/^## \[/ { hdr = $0; sub(/^## \[[^]]*\] \| /, "", hdr) } /^- Review: PASS/ && hdr ~ /^claude-qa \| F90-E01-T01 / { f = 1 } /^- Cross-model: NO/ && hdr ~ /^claude-qa \| F90-E01-T01 / { m = 1 } END { exit (f && m) ? 0 : 1 }' "$LEDGER" && ok "claude-qa passed the review while the gemini plan was out, marked Cross-model: NO" || bad "no covered review"
awk '/^## \[/ { in_done = ($0 ~ /\| F90-E01-T01 \| DONE \|/) } in_done && /^- Cross-model: NO/ { f = 1 } END { exit f ? 0 : 1 }' "$LEDGER" && ok "the DONE entry keeps the marker" || bad "DONE entry without the marker"
grep -q '^## \[.*\] | gemini-qa | F90-E01-T01 | AUDIT' "$LEDGER" && ok "gemini-qa audited the closed task when its quota came back" || bad "no audit entry"
grep -q '^- Brain: used LRN-001; learned LRN-004$' "$LEDGER" && ok "the retro recorded the lesson used and the lesson learned" || bad "no Brain line for T01"
grep '^| LRN-004 ' "$P/docs/Brain.md" | grep -q 'Debug output left in the results' && ok "the lesson of the failed review is in the brain" || bad "lesson missing"
[ ! -e "$P/docs/brain/tasks/F90-E01-T01.md" ] && ok "the working memory of a closed task is gone" || bad "working memory left"
core digest "$P" > "$WORK/.digest" 2>&1
D_BYTES="$(tr -d '\r' < "$WORK/.digest" | bytes)"
grep -q 'F90-E01-T04' "$WORK/.digest" && grep -q 'RED-LINE: deletes production data' "$WORK/.digest" && ok "digest lists the red line" || bad "digest without the red line: $(cat "$WORK/.digest")"
[ "$D_BYTES" -le 4096 ] && ok "digest is $D_BYTES bytes, within 4096" || bad "digest is $D_BYTES bytes"
[ "$CTX_MAX" -le 8192 ] && ok "context never went over 8192 bytes (largest: $CTX_MAX)" || bad "context reached $CTX_MAX bytes"
[ -n "$RECALL_BYTES" ] && [ "$RECALL_BYTES" -le 4096 ] && ok "recall of the task in GREEN was $RECALL_BYTES bytes ($RECALL_ROWS)" || bad "recall bytes: ${RECALL_BYTES:-none}"
FINAL_CTX="$(core context "$P" 2>/dev/null | bytes)"

# ---- a classic project becomes a Factory project ------------------------------------------------------------
M="$WORK/classic project"; rm -rf "$M"; mkdir -p "$M"
core init "$M" --classic >/dev/null 2>&1
core mode "$M" 2>&1 | tr -d '\r' | head -n 1 | grep -q 'CLASSIC' && ok "init --classic makes a classic project" || bad "mode of the classic project: $(core mode "$M" 2>&1 | head -n 1)"
core migrate "$M" --factory > "$WORK/.migrate" 2>&1
tr -d '\r' < "$WORK/.migrate" | grep -q '^project_docs migrate: [1-9][0-9]* change(s)$' && ok "migrate --factory brings it over" || bad "migrate output: $(cat "$WORK/.migrate")"
core mode "$M" 2>&1 | tr -d '\r' | head -n 1 | grep -q 'FACTORY' && ok "the project is in Factory mode now" || bad "mode after migrate"
core check "$M" > "$WORK/.check" 2>&1 && ok "check passes on the migrated project" || bad "check on the migrated project: $(tail -n 3 "$WORK/.check" | tr '\n' '~')"
core migrate "$M" --factory 2>&1 | tr -d '\r' | grep -q '^project_docs migrate: 0 change(s)$' && ok "a second migrate --factory changes nothing" || bad "second migrate not idempotent"

echo "== measurements ($LAUNCHER) =="
echo "dispatcher runs: $(grep -c '' "$FLOG" 2>/dev/null || echo 0)"
for ag in claude-spec claude-test claude-dev claude-qa gemini-qa; do
  echo "  runs of $ag: $(awk -v a="$ag" '$1 == a { n++ } END { print n + 0 }' "$FLOG" 2>/dev/null)"
done
for ag in gemini-qa claude-qa; do
  echo "  reviews written by $ag: $(grep -cE "^## \[[^]]*\] \| $ag \| [^|]* \| REVIEW \|" "$LEDGER")"
done
echo "context bytes: first run to last, largest $CTX_MAX, at the end $FINAL_CTX"
echo "recall bytes for the task in GREEN: ${RECALL_BYTES:-n/a} ($RECALL_ROWS)"
echo "digest bytes: $D_BYTES"
echo "ledger entries: $(grep -c '^## \[' "$LEDGER")"
echo "== $LAUNCHER: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
