#!/usr/bin/env sh
# factory_dispatch.sh <project> [--watch] [--once]
#
# Passes the turn between the agent CLIs of a Factory project. The ledger is the channel: for
# each agent of .factory/dispatch.md, in order, it asks `next <agent>` and runs the CLI of the
# first one that has work, one CLI at a time. It detects quota limits in the output, puts the
# plan of that CLI in cooldown, writes the pause on behalf of the agent that was cut off, and
# lets a covering agent take the reviews of an agent that is out. Outside the project_docs core.
#
# Tests: PROJECT_DOCS_DISPATCH_NO_SLEEP=1 prints "sleep until HH:MM" instead of waiting and stops.
set -eu

case "${1:-}" in
  ''|-*) PROJECT="." ;;
  *) PROJECT="$1"; shift ;;
esac
WATCH=0
ONCE=0
for fd_a in "$@"; do
  case "$fd_a" in
    --watch) WATCH=1 ;;
    --once) ONCE=1 ;;
    *) echo "factory_dispatch: unknown option $fd_a" >&2; exit 2 ;;
  esac
done

PROJECT="$(CDPATH= cd -- "$PROJECT" 2>/dev/null && pwd)" || { echo "factory_dispatch: project folder not found" >&2; exit 1; }
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CORE="$SCRIPT_DIR/project_docs.sh"
PROMPT_TEMPLATE="$SCRIPT_DIR/../templates/dispatch-prompt.md"
FDIR="$PROJECT/.factory"
CONFIG="$FDIR/dispatch.md"
STATE="$FDIR/state.md"
RUNS="$FDIR/runs"
STOP="$FDIR/STOP"

fd_die() { echo "factory_dispatch: $*" >&2; exit 1; }
log() { printf 'dispatch: %s\n' "$*"; }
core() { sh "$CORE" "$@"; }
US="$(printf '\037')"

[ -f "$CONFIG" ] || fd_die "$CONFIG does not exist (run init or migrate --factory)"
case "$(core mode "$PROJECT" 2>/dev/null | head -n 1)" in
  *": FACTORY"*) ;;
  *) fd_die "the project is not in Factory mode" ;;
esac

# ---- the configuration ---------------------------------------------------------------------------
cfg_setting() {  # cfg_setting NAME DEFAULT
  fd_v="$(tr -d '\r' < "$CONFIG" | awk -F'|' -v want="$1" '
    /^## / { insec = ($0 == "## Settings"); next }
    insec && /^\|/ {
      k = $2; v = $3
      gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (k == want) { print v; exit }
    }
  ')"
  case "$fd_v" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$fd_v" ;; esac
}

agents_tsv() {  # id, plan, command, limit text, cooldown minutes, max runs per day, covers for
  tr -d '\r' < "$CONFIG" | awk -F'|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^## / { insec = ($0 == "## Agents"); next }
    insec && /^\|/ {
      line = $0; sub(/^\|/, "", line); sub(/\|[ \t]*$/, "", line)
      n = split(line, c, "|")
      for (i = 1; i <= n; i++) c[i] = trim(c[i])
      if (c[1] == "Agent id" || c[1] ~ /^-+$/ || c[1] == "") next
      cmd = c[3]
      if (cmd ~ /^`/) { sub(/^`/, "", cmd); sub(/`$/, "", cmd) }
      cool = (c[5] ~ /^[0-9]+$/ && c[5] + 0 > 0) ? c[5] : 60
      mr = c[6]; if (mr !~ /^[0-9]+$/) mr = ""
      cv = c[7]; if (cv == "—") cv = ""
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", c[1], c[2], cmd, c[4], cool, mr, cv
    }
  '
}

# ---- the state -------------------------------------------------------------------------------------
mkdir -p "$RUNS"
if [ ! -f "$STATE" ]; then
  printf '%s\n' "# Dispatcher state" "" "Written by factory_dispatch and not committed." "" "| Key | Value |" "|---|---|" > "$STATE"
fi
state_get() {
  awk -F'|' -v k="$1" '/^\|/ { key = $2; val = $3; gsub(/^[ \t]+|[ \t]+$/, "", key); gsub(/^[ \t]+|[ \t]+$/, "", val); if (key == k) { print val; exit } }' "$STATE"
}
state_num() {  # state_num KEY: the number stored under the key, 0 when there is none
  state_get "$1" | awk 'BEGIN { n = 0 } NR == 1 { n = $1 + 0 } END { print n }'
}
state_set() {
  awk -F'|' -v k="$1" -v v="$2" '
    /^\|/ { key = $2; gsub(/^[ \t]+|[ \t]+$/, "", key); if (key == k) { if (!done) print "| " k " | " v " |"; done = 1; next } }
    { print }
    END { if (!done) print "| " k " | " v " |" }
  ' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
state_del() {
  awk -F'|' -v k="$1" '/^\|/ { key = $2; gsub(/^[ \t]+|[ \t]+$/, "", key); if (key == k) next } { print }' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
state_prune() {  # drops expired cooldowns and the run counters of other days
  awk -F'|' -v now="$NOW" -v today="$TODAY" '
    /^\|/ {
      key = $2; val = $3; gsub(/^[ \t]+|[ \t]+$/, "", key); gsub(/^[ \t]+|[ \t]+$/, "", val)
      if (key ~ /^cooldown:/ && val + 0 <= now) next
      if (key ~ /^runs:/) { n = split(key, p, ":"); if (p[n] != today) next }
    }
    { print }
  ' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
state_min_cooldown() {
  awk -F'|' '/^\|/ { key = $2; val = $3; gsub(/^[ \t]+|[ \t]+$/, "", key); gsub(/^[ \t]+|[ \t]+$/, "", val); if (key ~ /^cooldown:/ && (m == "" || val + 0 < m)) m = val + 0 } END { if (m != "") print m }' "$STATE"
}

# ---- time ----------------------------------------------------------------------------------------------
clock() {  # sets NOW (epoch), SOD (seconds of the local day) and TODAY (local date)
  NOW="$(date +%s)"
  SOD="$(date +%H:%M:%S | awk -F: '{ print $1 * 3600 + $2 * 60 + $3 }')"
  TODAY="$(date +%Y-%m-%d)"
}
fmt_hm() {  # fmt_hm EPOCH: the local HH:MM of a moment after NOW
  awk -v e="$1" -v n="$NOW" -v s="$SOD" 'BEGIN { t = (s + e - n) % 86400; if (t < 0) t += 86400; printf "%02d:%02d", int(t / 3600), int((t % 3600) / 60) }'
}
reset_epoch() {  # reset_epoch OUTPUT-FILE: the moment of "resets 3:45pm", or nothing
  tr 'A-Z' 'a-z' < "$1" | awk -v now="$NOW" -v sod="$SOD" '
    match($0, /resets +[0-9][0-9]?(:[0-9][0-9])? *(am|pm)?/) {
      s = substr($0, RSTART, RLENGTH); sub(/^resets +/, "", s)
      ap = ""; if (s ~ /pm/) ap = "pm"; else if (s ~ /am/) ap = "am"
      gsub(/ *(am|pm)/, "", s)
      split(s, p, ":"); h = p[1] + 0; mi = (p[2] == "" ? 0 : p[2] + 0)
      if (ap == "pm" && h < 12) h += 12
      if (ap == "am" && h == 12) h = 0
      target = now - sod + h * 3600 + mi * 60
      if (target <= now) target += 86400
      print target; exit
    }
  '
}
has_limit() {  # has_limit OUTPUT-FILE "text; text": true when one of the texts is in the output
  tr 'A-Z' 'a-z' < "$1" | awk -v pats="$(printf '%s' "$2" | tr 'A-Z' 'a-z')" '
    BEGIN { n = split(pats, p, ";"); for (i = 1; i <= n; i++) { gsub(/^[ \t]+|[ \t]+$/, "", p[i]); if (p[i] != "") pat[++m] = p[i] } }
    { text = text " " $0 }
    END { for (i = 1; i <= m; i++) if (index(text, pat[i]) > 0) exit 0; exit 1 }
  '
}

# ---- what the core says --------------------------------------------------------------------------------
next_task() {  # next_task AGENT: the task id or none
  fd_t="$(core next "$PROJECT" "$1" 2>/dev/null | head -n 1 | tr -d '\r')" || fd_t="none"
  [ -n "$fd_t" ] || fd_t="none"
  printf '%s' "$fd_t"
}
status_line() {  # status_line TASK: the open-task line of status, or nothing
  core status "$PROJECT" 2>/dev/null | tr -d '\r' | awk -F' [|] ' -v t="$1" '$1 == t { print; exit }'
}
agent_holds() {  # agent_holds LINE AGENT: true when the agent holds the task, working on it or with a review answered
  ah_f="$(printf '%s' "$1" | awk -F' [|] ' '{ print $3 " " $4 }')"
  case "$ah_f" in "$2 IN_PROGRESS"|"$2 REVIEW"*) return 0 ;; esac
  return 1
}
agent_role() {
  awk -F'|' -v want="$1" '
    /^## / { insec = ($0 == "## Agent identity"); next }
    insec && /^\|/ { id = $2; role = $5; gsub(/^[ \t]+|[ \t]+$/, "", id); gsub(/^[ \t]+|[ \t]+$/, "", role); if (id == want) { print role; exit } }
  ' "$PROJECT/AGENTS.md"
}

# ---- one run ------------------------------------------------------------------------------------------------------
RUN_COUNT=0
OK_COUNT=0
LIMIT_COUNT=0
FAIL_COUNT=0
TIMEOUT_MIN="$(cfg_setting "Run timeout minutes" 60)"
IDLE_SEC="$(cfg_setting "Idle seconds" 300)"

run_agent() {  # run_agent AGENT TASK PLAN COMMAND LIMITTEXT COOLDOWN COVERED
  ra_agent="$1"; ra_task="$2"; ra_plan="$3"; ra_cmd="$4"; ra_limits="$5"; ra_cool="$6"; ra_covered="$7"
  RUN_COUNT=$((RUN_COUNT + 1))
  if [ -n "$ra_covered" ]; then
    log "run $RUN_COUNT: $ra_agent on $ra_task (covers $ra_covered)"
  else
    log "run $RUN_COUNT: $ra_agent on $ra_task"
  fi
  state_set "runs:$ra_agent:$TODAY" "$(( $(state_num "runs:$ra_agent:$TODAY") + 1 ))"
  ra_id="$(date +%Y%m%dT%H%M%S)-$(printf '%03d' "$RUN_COUNT")-$ra_agent"
  ra_prompt="$RUNS/$ra_id.prompt.md"
  ra_out="$RUNS/$ra_id.out"
  ra_line="$(status_line "$ra_task")"
  ra_phase="SPEC"; ra_lane="NORMAL"
  if [ -n "$ra_line" ]; then
    ra_tail="$(printf '%s' "$ra_line" | awk -F' [|] ' '{ print $NF }')"
    case "$ra_tail" in *" "*) ra_phase="${ra_tail%% *}"; ra_lane="${ra_tail#* }" ;; esac
  elif grep -F "| $ra_task |" "$PROJECT/docs/Roadmap.md" 2>/dev/null | grep -q 'Lane: FAST'; then
    ra_phase="GREEN"; ra_lane="FAST"
  fi
  ra_role="$(agent_role "$ra_agent")"
  ra_name="$(basename "$(CDPATH= cd -- "$PROJECT" && pwd)")"
  FD_A="$ra_agent" FD_R="$ra_role" FD_P="$ra_name" FD_T="$ra_task" FD_PH="$ra_phase" FD_L="$ra_lane" awk '
    function rep(s, k, v,   i) { while ((i = index(s, k)) > 0) s = substr(s, 1, i - 1) v substr(s, i + length(k)); return s }
    { s = $0; s = rep(s, "{AGENT}", ENVIRON["FD_A"]); s = rep(s, "{ROLE}", ENVIRON["FD_R"]); s = rep(s, "{PROJECT}", ENVIRON["FD_P"]); s = rep(s, "{TASK}", ENVIRON["FD_T"]); s = rep(s, "{PHASE}", ENVIRON["FD_PH"]); s = rep(s, "{LANE}", ENVIRON["FD_L"]); print s }
  ' "$PROMPT_TEMPLATE" > "$ra_prompt"
  ra_final="$(printf '%s' "$ra_cmd" | FD_PF="$ra_prompt" awk '{ s = $0; while ((i = index(s, "{PROMPT_FILE}")) > 0) s = substr(s, 1, i - 1) ENVIRON["FD_PF"] substr(s, i + 13); print s }')"
  ra_before="$(cksum < "$PROJECT/docs/Agentslog.md")"
  RC=0
  (
    cd "$PROJECT"
    FACTORY_AGENT="$ra_agent"; FACTORY_TASK="$ra_task"; FACTORY_PROJECT="$PROJECT"; FACTORY_PROMPT_FILE="$ra_prompt"
    export FACTORY_AGENT FACTORY_TASK FACTORY_PROJECT FACTORY_PROMPT_FILE
    unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN GEMINI_API_KEY GOOGLE_API_KEY
    if [ "$TIMEOUT_MIN" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
      timeout "$((TIMEOUT_MIN * 60))" sh -c "$ra_final"
    else
      sh -c "$ra_final"
    fi
  ) > "$ra_out" 2>&1 || RC=$?
  ra_after="$(cksum < "$PROJECT/docs/Agentslog.md")"
  clock
  if [ "$RC" -ne 0 ] && has_limit "$ra_out" "$ra_limits"; then
    LIMIT_COUNT=$((LIMIT_COUNT + 1))
    ra_until="$(reset_epoch "$ra_out")"
    if [ -z "$ra_until" ]; then ra_until=$((NOW + ra_cool * 60)); fi
    state_set "cooldown:$ra_plan" "$ra_until"
    log "run $RUN_COUNT limit: $ra_agent hit its limit, plan $ra_plan in cooldown until $(fmt_hm "$ra_until")"
    ra_line="$(status_line "$ra_task")"
    if agent_holds "$ra_line" "$ra_agent"; then
      core checkpoint "$PROJECT" "$ra_agent" "$ra_task" "limit reached" "resume after the cooldown" >/dev/null 2>&1 || true
      if core pause "$PROJECT" "$ra_agent" "$ra_task" LIMITE "limit until $(fmt_hm "$ra_until")" >/dev/null 2>&1; then
        log "run $RUN_COUNT paused $ra_task (LIMITE) for $ra_agent"
      else
        log "run $RUN_COUNT could not pause $ra_task for $ra_agent (pause was refused)"
      fi
    fi
  elif [ "$RC" -eq 0 ] && [ "$ra_before" != "$ra_after" ]; then
    OK_COUNT=$((OK_COUNT + 1))
    state_del "fails:$ra_agent:$ra_task"
    log "run $RUN_COUNT ok"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ra_fails=$(( $(state_num "fails:$ra_agent:$ra_task") + 1 ))
    state_set "fails:$ra_agent:$ra_task" "$ra_fails"
    log "run $RUN_COUNT failed (exit $RC), $ra_fails failure(s) for $ra_agent on $ra_task"
    ra_line="$(status_line "$ra_task")"
    if [ "$ra_fails" -ge 3 ] && agent_holds "$ra_line" "$ra_agent"; then
      core checkpoint "$PROJECT" "$ra_agent" "$ra_task" "three runs without progress" "needs a person" >/dev/null 2>&1 || true
      if core pause "$PROJECT" "$ra_agent" "$ra_task" BLOQUEO "dispatcher: 3 runs without progress" >/dev/null 2>&1; then
        state_del "fails:$ra_agent:$ra_task"
        log "run $RUN_COUNT blocked $ra_task after 3 failures"
      else
        log "run $RUN_COUNT could not block $ra_task (pause was refused); $ra_agent is skipped on it until the fails row of .factory/state.md is deleted"
      fi
    fi
  fi
}

# ---- who runs next -----------------------------------------------------------------------------------------------------
available() {  # available PLAN AGENT: true when the plan is not cooling down and the agent has runs left today
  av_cd="$(state_get "cooldown:$1")"
  if [ -n "$av_cd" ] && [ "$av_cd" -gt "$NOW" ]; then return 1; fi
  av_max="$(agents_tsv | awk -F'\t' -v a="$2" '$1 == a { print $6; exit }')"
  if [ -n "$av_max" ]; then
    av_runs="$(state_num "runs:$2:$TODAY")"
    if [ "$av_runs" -ge "$av_max" ]; then return 1; fi
  fi
  return 0
}
is_review() {  # is_review TASK: true when the task waits for a review
  case "$(status_line "$1" | awk -F' [|] ' '{ print $4 }')" in REVIEW*) return 0 ;; esac
  return 1
}
pick() {  # sets PICK_AGENT, PICK_TASK, PICK_ROW (the agents row) and PICK_COVERED
  PICK_AGENT=""; PICK_TASK=""; PICK_ROW=""; PICK_COVERED=""
  pk_rows="$(agents_tsv)"
  pk_us="$(printf '%s\n' "$pk_rows" | tr '\t' '\037')"
  while IFS="$US" read -r pk_id pk_plan pk_cmd pk_lim pk_cool pk_max pk_cov; do
    [ -n "$pk_id" ] || continue
    if available "$pk_plan" "$pk_id"; then
      pk_t="$(next_task "$pk_id")"
      if [ "$pk_t" != "none" ]; then
        pk_f="$(state_num "fails:$pk_id:$pk_t")"
        if [ "$pk_f" -ge 3 ]; then pk_t="none"; elif [ "$pk_f" -ge 2 ] && is_review "$pk_t"; then pk_t="none"; fi
      fi
      if [ "$pk_t" != "none" ]; then
        PICK_AGENT="$pk_id"; PICK_TASK="$pk_t"; PICK_ROW="$pk_id$US$pk_plan$US$pk_cmd$US$pk_lim$US$pk_cool$US$pk_max$US$pk_cov"; return 0
      fi
      if [ -n "$pk_cov" ]; then
        pk_cplan="$(printf '%s\n' "$pk_rows" | awk -F'\t' -v a="$pk_cov" '$1 == a { print $2; exit }')"
        pk_ct="$(next_task "$pk_cov")"
        if [ "$pk_ct" != "none" ] && is_review "$pk_ct" && [ "$(state_num "fails:$pk_id:$pk_ct")" -lt 3 ]; then
          pk_out=0
          if ! available "$pk_cplan" "$pk_cov"; then pk_out=1; fi
          if [ "$(state_num "fails:$pk_cov:$pk_ct")" -ge 2 ]; then pk_out=1; fi
          if [ "$pk_out" -eq 1 ]; then
            PICK_AGENT="$pk_id"; PICK_TASK="$pk_ct"; PICK_COVERED="$pk_cov"
            PICK_ROW="$pk_id$US$pk_plan$US$pk_cmd$US$pk_lim$US$pk_cool$US$pk_max$US$pk_cov"; return 0
          fi
        fi
      fi
    fi
  done <<EOF
$pk_us
EOF
  return 1
}

nap() {  # nap SECONDS: sleeps in steps of 30 seconds at most and stops early when .factory/STOP appears
  fd_left="$1"
  while [ "$fd_left" -gt 0 ] && [ ! -e "$STOP" ]; do
    fd_step="$fd_left"; [ "$fd_step" -le 30 ] || fd_step=30
    sleep "$fd_step"
    fd_left=$((fd_left - fd_step))
  done
}

# ---- the loop ----------------------------------------------------------------------------------------------------------------
while :; do
  if [ -e "$STOP" ]; then log "stop requested"; break; fi
  clock
  state_prune
  if pick; then
    IFS="$US" read -r ra_a ra_p ra_c ra_l ra_cd ra_mx ra_cv <<EOF
$PICK_ROW
EOF
    run_agent "$PICK_AGENT" "$PICK_TASK" "$ra_p" "$ra_c" "$ra_l" "$ra_cd" "$PICK_COVERED"
    if [ "$ONCE" -eq 1 ]; then break; fi
    continue
  fi
  fd_soon="$(state_min_cooldown)"
  if [ -n "$fd_soon" ]; then
    log "sleep until $(fmt_hm "$fd_soon")"
    if [ "${PROJECT_DOCS_DISPATCH_NO_SLEEP:-0}" = "1" ] || [ "$ONCE" -eq 1 ]; then break; fi
    fd_wait=$((fd_soon - NOW)); [ "$fd_wait" -gt 0 ] || fd_wait=1
    nap "$fd_wait"
    continue
  fi
  if [ "$WATCH" -eq 1 ] && [ "$ONCE" -eq 0 ]; then
    log "waiting $IDLE_SEC seconds for new work"
    if [ "${PROJECT_DOCS_DISPATCH_NO_SLEEP:-0}" = "1" ]; then break; fi
    nap "$IDLE_SEC"
    continue
  fi
  log "nothing to do"
  break
done
log "summary: runs=$RUN_COUNT ok=$OK_COUNT limits=$LIMIT_COUNT failures=$FAIL_COUNT"
