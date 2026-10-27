#!/usr/bin/env sh
# diff_regression.sh <baseline-commit> <sh|ps1>
#
# The differential run behind BR-008: a project without a Factory section must behave exactly as it did
# before Factory mode. It builds an old-style project with the scripts of a BASELINE commit (a release
# from before Factory mode, for example the master of the previous release), then runs the same commands
# with the baseline scripts and with the scripts of this working tree on identical copies, and compares
# stdout, stderr, exit code and the resulting ledger, Roadmap and Features once timestamps, archive names
# and hashes are normalised. Prints SAME or DIFF per step and `RESULT fail=N`; exits 1 when N is not 0.
# Needs git (to take the baseline out with git archive). Nothing here changes the repository.
set -u

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO="$(CDPATH= cd -- "$HERE/../.." && pwd)"
if [ "$#" -ne 2 ] || { [ "$2" != "sh" ] && [ "$2" != "ps1" ]; }; then
  echo "usage: diff_regression.sh <baseline-commit> <sh|ps1>" >&2
  exit 2
fi
BASE_COMMIT="$1"; LANG_="$2"
W="$(mktemp -d "${TMPDIR:-/tmp}/diffreg.XXXXXX")"
trap 'rm -rf "$W"' EXIT HUP INT TERM
PROJECT_DOCS_MIN_WORK_MINUTES=0; export PROJECT_DOCS_MIN_WORK_MINUTES

nat() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
PWSH=""
if [ "$LANG_" = "ps1" ]; then
  if command -v pwsh >/dev/null 2>&1; then PWSH="pwsh"
  elif command -v powershell.exe >/dev/null 2>&1; then PWSH="powershell.exe"
  else echo "no PowerShell on PATH" >&2; exit 2; fi
fi

mkdir -p "$W/base" "$W/new"
( cd "$REPO" && git archive "$BASE_COMMIT" scripts templates adapters ) | tar -x -C "$W/base" || { echo "cannot take $BASE_COMMIT out of git" >&2; exit 2; }
cp -r "$REPO/scripts" "$REPO/templates" "$REPO/adapters" "$W/new/"

run_with() {  # run_with <base|new> <command> <project> [arguments...]
  rw_which="$1"; rw_cmd="$2"; rw_proj="$3"; shift 3
  if [ "$LANG_" = "sh" ]; then
    sh "$W/$rw_which/scripts/project_docs.sh" "$rw_cmd" "$rw_proj" "$@" 2>&1
  else
    rw_line="& '$(nat "$W/$rw_which/scripts/project_docs.ps1")' '$rw_cmd' '$(nat "$rw_proj")'"
    for rw_a in "$@"; do rw_line="$rw_line '$(printf '%s' "$rw_a" | sed "s/'/''/g")'"; done
    "$PWSH" -NoProfile -NonInteractive -Command "$rw_line" 2>&1
  fi
}

# ---- the old-style fixture, made with the BASELINE scripts ------------------------------------------------
FIX="$W/fixture"; mkdir -p "$FIX"
run_with base init "$FIX" >/dev/null
awk '
  /^\| F01-E01-T01 \|/ && !done {
    print "| F01-E01-T01 | First regression task | detail | real accept | TODO | — | — | — |"
    print "| F01-E01-T02 | Second regression task | detail | real accept | TODO | — | — | — |"
    print "| F01-E01-T03 | Third regression task | detail | real accept | TODO | — | — | — |"
    print "| F01-E01-T04 | Fourth regression task | detail | real accept | TODO | — | — | — |"
    print "| F01-E01-T05 | Fifth regression task | detail | real accept | TODO | — | — | — |"
    done = 1; next
  }
  { print }
' "$FIX/docs/Roadmap.md" > "$FIX/docs/Roadmap.md.tmp" && mv "$FIX/docs/Roadmap.md.tmp" "$FIX/docs/Roadmap.md"
run_with base claim "$FIX" agentA F01-E01-T01 "working on one" >/dev/null
run_with base claim "$FIX" agentB F01-E01-T02 "working on two" >/dev/null
run_with base pause "$FIX" agentB F01-E01-T02 LIMITE "context limit" >/dev/null
run_with base claim "$FIX" agentC F01-E01-T03 "working on three" >/dev/null
run_with base done "$FIX" agentC F01-E01-T03 "finished three" "src/three" "tests pass" >/dev/null
run_with base append-log "$FIX" agentD F01-E01-T05 DONE "legacy style entry" "n/a" "n/a" >/dev/null
echo "fixture ledger:"; grep '^## \[' "$FIX/docs/Agentslog.md"

cp -r "$FIX" "$W/f_base"; cp -r "$FIX" "$W/f_new"
norm() {  # the parts that legitimately differ between two runs: time, archive names, hashes, PowerShell noise
  sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/<TS>/g; s/Agentslog-[0-9]{8}-[0-9]{3}\.md/<ARCHIVE>/g; s/[0-9a-f]{64}/<SHA>/g' |
    tr -d '\r' | grep -v 'project_docs\.ps1: [0-9]' | grep -Ev '^ *[+] |CategoryInfo|FullyQualifiedErrorId|^ *$'
  true
}
fail=0
cmp_cmd() {  # cmp_cmd <label> <command> [arguments...]
  cc_label="$1"; cc_cmd="$2"; shift 2
  { run_with base "$cc_cmd" "$W/f_base" "$@"; echo "exit=$?"; } | norm | sed "s#$W/f_base#<PROJ>#g" > "$W/o_base.txt"
  { run_with new "$cc_cmd" "$W/f_new" "$@"; echo "exit=$?"; } | norm | sed "s#$W/f_new#<PROJ>#g" > "$W/o_new.txt"
  if cmp -s "$W/o_base.txt" "$W/o_new.txt"; then
    echo "SAME  $cc_label"
  else
    echo "DIFF  $cc_label"; diff "$W/o_base.txt" "$W/o_new.txt" | head -12; fail=1
  fi
}
cmp_cmd "check" check
cmp_cmd "status" status
cmp_cmd "context" context
cmp_cmd "rotate (not required)" rotate
cmp_cmd "claim a free task" claim agentE F01-E01-T04 "start four"
cmp_cmd "claim a task held by another agent (must fail the same way)" claim agentZ F01-E01-T01 "steal"
cmp_cmd "pause by the owner" pause agentE F01-E01-T04 OTRO "switching"
cmp_cmd "reclaim a LIMITE pause by another agent" claim agentF F01-E01-T02 "resume two"
cmp_cmd "done by the owner" done agentF F01-E01-T02 "finished two" "src/two" "tests pass"
cmp_cmd "status after the commands" status
cmp_cmd "context after the commands" context
cmp_cmd "check after the commands" check
for same_f in Agentslog Roadmap Features; do
  norm < "$W/f_base/docs/$same_f.md" > "$W/s_base.txt"; norm < "$W/f_new/docs/$same_f.md" > "$W/s_new.txt"
  if cmp -s "$W/s_base.txt" "$W/s_new.txt"; then echo "SAME  resulting $same_f.md"; else echo "DIFF  resulting $same_f.md"; diff "$W/s_base.txt" "$W/s_new.txt" | head -8; fail=1; fi
done
echo "RESULT fail=$fail  (baseline $BASE_COMMIT, $LANG_)"
[ "$fail" -eq 0 ]
