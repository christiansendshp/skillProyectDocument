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
}

file_hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else cksum "$1"; fi
}

seed_task() {
  proj="$1"
  file="$proj/docs/Roadmap.md"
  awk '/^\|---\|---\|---\|---\|---\|---\|---\|$/ && !done { print; print "| SMOKE-T01 | Smoke task one | works | TODO | - | - | - |"; done=1; next } { print }' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

seed_task2() {
  proj="$1"
  file="$proj/docs/Roadmap.md"
  awk '/^\|---\|---\|---\|---\|---\|---\|---\|$/ && !done { print; print "| SMOKE-T02 | Smoke task two | works | TODO | - | - | - |"; done=1; next } { print }' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
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
