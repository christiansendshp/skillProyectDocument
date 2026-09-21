#!/usr/bin/env sh
set -eu

COMMAND="${1:-help}"
PROJECT="${2:-.}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/../templates"
ADAPTERS_DIR="$SCRIPT_DIR/../adapters"
DOCS_DIR="$PROJECT/docs"
HISTORY_DIR="$DOCS_DIR/history"
CONTRACT_FILES="AGENTS.md docs/Agentslog.md docs/ProductDescription.md docs/Stack_Tecnologies.md docs/Roadmap.md docs/Features.md"
LINK_TARGETS_DEFAULT="claude gemini cursor windsurf cline copilot antigravity"
CONTEXT_LIMIT=8192
LOG_BYTES_LIMIT=131072
LOG_ENTRIES_LIMIT=200
STALE_HOURS="${PROJECT_DOCS_STALE_HOURS:-24}"
BLOCK_START='<!-- project-documentation:start -->'
BLOCK_END='<!-- project-documentation:end -->'
TAB="$(printf '\t')"

die() {
  echo "project_docs: $*" >&2
  exit 1
}

require_templates() {
  [ -d "$TEMPLATES_DIR" ] || die "templates directory not found: $TEMPLATES_DIR"
}

require_adapters() {
  [ -d "$ADAPTERS_DIR" ] || die "adapters directory not found: $ADAPTERS_DIR"
}

clean_field() {
  printf '%s' "$1" | tr '\r\n|' '   '
}

# ---------------------------------------------------------------------------
# Idempotent marker block: create or merge CONTENT_FILE into TARGET between
# BLOCK_START/BLOCK_END, preserving everything else byte-for-byte. Returns 0
# if TARGET changed, 1 if it already matched.
# ---------------------------------------------------------------------------
replace_block() {
  target="$1"
  content_file="$2"
  dir="$(dirname "$target")"
  [ -d "$dir" ] || mkdir -p "$dir"
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-block.XXXXXX")"
  if [ ! -f "$target" ]; then
    {
      echo "$BLOCK_START"
      cat "$content_file"
      echo "$BLOCK_END"
    } > "$tmp"
  else
    range="$(awk -v s="$BLOCK_START" -v e="$BLOCK_END" '
      $0==s { sline=NR }
      $0==e && sline && !found { eline=NR; found=1 }
      END { if (found) print sline" "eline }
    ' "$target")"
    if [ -n "$range" ]; then
      sline="${range%% *}"
      eline="${range##* }"
      before_end=$((sline - 1))
      after_start=$((eline + 1))
      total="$(awk 'END{print NR}' "$target")"
      : > "$tmp"
      if [ "$before_end" -ge 1 ]; then
        sed -n "1,${before_end}p" "$target" >> "$tmp"
      fi
      echo "$BLOCK_START" >> "$tmp"
      cat "$content_file" >> "$tmp"
      echo "$BLOCK_END" >> "$tmp"
      if [ -n "$total" ] && [ "$after_start" -le "$total" ]; then
        sed -n "${after_start},\$p" "$target" >> "$tmp"
      fi
    else
      {
        echo "$BLOCK_START"
        cat "$content_file"
        echo "$BLOCK_END"
        echo
        cat "$target"
      } > "$tmp"
    fi
  fi
  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$target"
  return 0
}

has_block() {
  [ -f "$1" ] && grep -qF -- "$BLOCK_START" "$1"
}

# ---------------------------------------------------------------------------
# Case-variant helpers (matter on case-sensitive filesystems; harmless
# no-ops elsewhere since the OS itself prevents the collision).
# ---------------------------------------------------------------------------
list_case_variants() {
  dir="$1"
  name="$2"
  [ -d "$dir" ] || return 0
  lname="$(printf '%s' "$name" | tr 'A-Z' 'a-z')"
  for f in "$dir"/*; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    lbase="$(printf '%s' "$base" | tr 'A-Z' 'a-z')"
    if [ "$lbase" = "$lname" ]; then
      echo "$base"
    fi
  done
}

find_case_variant() {
  list_case_variants "$1" "$2" | head -n 1
}

rename_case() {
  from="$1"
  to="$2"
  dir="$(dirname "$from")"
  tmp="$dir/.project-docs-rename-tmp"
  if git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if ! git -C "$PROJECT" mv "$from" "$tmp" 2>/dev/null; then mv "$from" "$tmp"; fi
    if ! git -C "$PROJECT" mv "$tmp" "$to" 2>/dev/null; then mv "$tmp" "$to"; fi
  else
    mv "$from" "$tmp"
    mv "$tmp" "$to"
  fi
}

remove_file() {
  path="$1"
  if git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if ! git -C "$PROJECT" rm -q -- "$path" 2>/dev/null; then rm -f "$path"; fi
  else
    rm -f "$path"
  fi
}

# ---------------------------------------------------------------------------
# init / link
# ---------------------------------------------------------------------------
init_docs() {
  require_templates
  created=0
  for rel in $CONTRACT_FILES; do
    target="$PROJECT/$rel"
    base="$(basename "$rel")"
    dir="$(dirname "$target")"
    [ -d "$dir" ] || mkdir -p "$dir"
    existed=0
    if [ -f "$target" ]; then existed=1; fi
    if [ "$base" = "AGENTS.md" ]; then
      if [ "$existed" -eq 1 ]; then
        if has_block "$target"; then
          echo "= preserved: $rel"
        else
          replace_block "$target" "$TEMPLATES_DIR/AGENTS.md" || true
          echo "= merged skill block: $rel"
        fi
      else
        replace_block "$target" "$TEMPLATES_DIR/AGENTS.md" || true
        echo "+ created: $rel"
        created=$((created + 1))
      fi
    else
      if [ "$existed" -eq 1 ]; then
        echo "= preserved: $rel"
      else
        cp "$TEMPLATES_DIR/$base" "$target"
        echo "+ created: $rel"
        created=$((created + 1))
      fi
    fi
  done
  echo "project_docs init: $created file(s) created"
  link_docs "$PROJECT" ""
}

link_target_path() {
  case "$1" in
    claude) echo "CLAUDE.md" ;;
    gemini) echo "GEMINI.md" ;;
    cursor) echo ".cursorrules" ;;
    windsurf) echo ".windsurfrules" ;;
    cline) echo ".clinerules" ;;
    copilot) echo ".github/copilot-instructions.md" ;;
    antigravity) echo ".antigravity/rules.md" ;;
  esac
}

link_source_file() {
  case "$1" in
    claude) echo "$ADAPTERS_DIR/CLAUDE.md" ;;
    antigravity) echo "$ADAPTERS_DIR/.antigravity/rules.md" ;;
    *) echo "$ADAPTERS_DIR/redirect.md" ;;
  esac
}

link_docs() {
  project="$1"
  create_list="${2:-}"
  require_adapters
  for name in $LINK_TARGETS_DEFAULT; do
    rel="$(link_target_path "$name")"
    full="$project/$rel"
    create=0
    for c in $(printf '%s' "$create_list" | tr ',' ' '); do
      if [ "$c" = "$name" ]; then create=1; fi
    done
    if [ "$name" = "cursor" ] && [ ! -f "$full" ] && [ -d "$project/.cursor/rules" ]; then
      full="$project/.cursor/rules/project-documentation.mdc"
      rel=".cursor/rules/project-documentation.mdc"
      create=1
    fi
    if [ -f "$full" ] || [ "$create" -eq 1 ]; then
      src="$(link_source_file "$name")"
      replace_block "$full" "$src" || true
      echo "= linked: $rel"
    fi
  done
}

cmd_link() {
  shift 2
  create_list=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --create) create_list="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  link_docs "$PROJECT" "$create_list"
  echo "project_docs link: done"
}

# ---------------------------------------------------------------------------
# context extraction
# ---------------------------------------------------------------------------
extract_context_block() {
  file="$1"
  heading="$2"
  awk -v heading="$heading" '
    $0 == heading { active = 1 }
    active { print }
    active && /<!-- context:end -->/ { exit }
  ' "$file"
}

count_log_entries() {
  awk '
    $0 == "## Entries" { entries_section = 1; next }
    entries_section && /^## \[/ { count++ }
    END { print count + 0 }
  ' "$1"
}

latest_log_entries() {
  awk '
    $0 == "## Entries" {
      entries_section = 1
      next
    }
    entries_section && /^## \[/ {
      count++
      entry[count] = $0 ORS
      active = 1
      next
    }
    active { entry[count] = entry[count] $0 ORS }
    END {
      start = count - 4
      if (start < 1) start = 1
      for (i = start; i <= count; i++) printf "%s", entry[i]
    }
  ' "$DOCS_DIR/Agentslog.md"
}

# ---------------------------------------------------------------------------
# Agentslog scanner: one pass, reused by claim/pause/done/status/context/
# check/rotate. Emits one TSV line per task id (order of first appearance):
#   task  status  agent  timestamp  pause_category  conflict  ever_done
# ---------------------------------------------------------------------------
all_task_states() {
  [ -f "$DOCS_DIR/Agentslog.md" ] || return 0
  awk '
    $0 == "## Entries" { in_entries=1; next }
    in_entries && /^## \[/ {
      line=$0
      sub(/^## \[/,"",line)
      sub(/\] \| /,"|",line)
      gsub(/ \| /,"|",line)
      split(line,f,"|")
      ts=f[1]; agent=f[2]; tid=f[3]; status=f[4]
      if (!(tid in seen)) { seen[tid]=1; order[++cnt]=tid }
      if (status=="IN_PROGRESS" && last_status[tid]=="IN_PROGRESS" && last_agent[tid]!=agent) {
        conflict[tid] = last_agent[tid] " vs " agent
      }
      if (status=="DONE") { ever_done[tid]=1 }
      last_status[tid]=status; last_agent[tid]=agent; last_ts[tid]=ts; last_pause[tid]=""
      cur=tid
      next
    }
    in_entries && cur!="" && /^- Pause:/ {
      line=$0
      sub(/^- Pause: /,"",line)
      dash=index(line," - ")
      if (dash>0) p=substr(line,1,dash-1); else p=line
      last_pause[cur]=p
      next
    }
    END {
      for (i=1;i<=cnt;i++) {
        t=order[i]
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", t, last_status[t], last_agent[t], last_ts[t], last_pause[t], conflict[t], (t in ever_done ? "1" : "0")
      }
    }
  ' "$DOCS_DIR/Agentslog.md"
}

task_state() {
  all_task_states | awk -F'\t' -v t="$1" '$1==t{print; found=1} END{exit (found?0:1)}'
}

age_hours() {
  ts="$1"
  now="$(date -u +%s)"
  then_epoch="$(date -u -d "$ts" +%s 2>/dev/null || true)"
  if [ -z "$then_epoch" ]; then
    then_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null || true)"
  fi
  if [ -z "$then_epoch" ]; then
    echo "?"
    return
  fi
  echo $(( (now - then_epoch) / 3600 ))
}

is_stale() {
  task="$1"
  if state="$(task_state "$task")"; then
    ts="$(printf '%s' "$state" | cut -f4)"
    hrs="$(age_hours "$ts")"
    if [ "$hrs" != "?" ] && [ "$hrs" -ge "$STALE_HOURS" ]; then
      return 0
    fi
  fi
  return 1
}

open_tasks_line() {
  [ -f "$DOCS_DIR/Agentslog.md" ] || return 0
  all_task_states | awk -F'\t' '$2=="IN_PROGRESS" || $2=="PAUSE"' |
  while IFS="$TAB" read -r tid status agent ts pausecat conflict everdone; do
    [ -n "$tid" ] || continue
    hrs="$(age_hours "$ts")"
    reason="-"
    if [ "$status" = "PAUSE" ]; then reason="$pausecat"; fi
    printf '%s | %s | %s | %sh | %s\n' "$tid" "$agent" "$status" "$hrs" "$reason"
  done
}

build_context() {
  [ -f "$PROJECT/AGENTS.md" ] || die "run init first"
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-context.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  {
    cat "$PROJECT/AGENTS.md"
    echo
    extract_context_block "$DOCS_DIR/ProductDescription.md" "## Operational summary"
    echo
    extract_context_block "$DOCS_DIR/Stack_Tecnologies.md" "## Operational summary"
    echo
    extract_context_block "$DOCS_DIR/Features.md" "## Operational summary"
    echo
    extract_context_block "$DOCS_DIR/Roadmap.md" "## Active work"
    echo
    echo "## Open tasks"
    open_tasks_line
    echo
    echo "## Latest agent entries"
    latest_log_entries
  } > "$tmp"
  bytes="$(wc -c < "$tmp" | tr -d ' ')"
  [ "$bytes" -le "$CONTEXT_LIMIT" ] ||
    die "hot context is ${bytes} bytes; compact summaries below ${CONTEXT_LIMIT}"
  cat "$tmp"
}

# ---------------------------------------------------------------------------
# Features.md stays a plain table (unchanged by the Roadmap rewrite below).
# ---------------------------------------------------------------------------
table_ids() {
  file="$1"
  [ -f "$file" ] || return 0
  awk -F'|' '
    /^\|/ {
      id=$2
      gsub(/^[ \t]+|[ \t]+$/,"",id)
      if (id=="" || id=="ID" || id=="—" || id ~ /^-+$/) next
      print id
    }
  ' "$file"
}

features_ids() { table_ids "$DOCS_DIR/Features.md"; }

# ---------------------------------------------------------------------------
# Roadmap/Features table rows. Every table this tool edits ends in the same
# four trailing columns (Status, Owner, Depends on, Pause reason), so cells
# are addressed from the end regardless of how many columns precede them.
# ---------------------------------------------------------------------------
roadmap_ids() { table_ids "$DOCS_DIR/Roadmap.md"; }

roadmap_has_id() {
  roadmap_ids | grep -qxF -- "$1"
}

roadmap_has_id_prefix() {
  roadmap_ids | grep -q -- "^$1"
}

roadmap_section_of() {
  awk -F'|' -v id="$1" '
    /^## Active work/ { sect="active" }
    /^## Plan/ { sect="plan" }
    /^## Gaps, Bugs & Technical Debt/ { sect="gaps" }
    /^## Near term/ { sect="near" }
    /^\|/ {
      cell=$2; gsub(/^[ \t]+|[ \t]+$/,"",cell)
      if (cell==id) { print sect; exit }
    }
  ' "$DOCS_DIR/Roadmap.md"
}

roadmap_update_row_inplace() {
  task="$1"; status="$2"; owner="$3"; pr="$4"
  file="$DOCS_DIR/Roadmap.md"
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-roadmap.XXXXXX")"
  awk -F'|' -v OFS='|' -v id="$task" -v status="$status" -v owner="$owner" -v pr="$pr" '
    /^\|/ {
      cell=$2; gsub(/^[ \t]+|[ \t]+$/,"",cell)
      if (cell==id) {
        $(NF-4) = " " status " "
        $(NF-3) = " " owner " "
        $(NF-1) = " " pr " "
        print; next
      }
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

roadmap_move_to_active() {
  task="$1"; status="$2"; owner="$3"; pr="$4"
  file="$DOCS_DIR/Roadmap.md"
  row="$(awk -F'|' -v id="$task" '/^\|/ { cell=$2; gsub(/^[ \t]+|[ \t]+$/,"",cell); if (cell==id) { print; exit } }' "$file")"
  newrow="$(printf '%s\n' "$row" | awk -F'|' -v OFS='|' -v status="$status" -v owner="$owner" -v pr="$pr" '{ $(NF-4)=" " status " "; $(NF-3)=" " owner " "; $(NF-1)=" " pr " "; print }')"
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-roadmap.XXXXXX")"
  awk -F'|' -v id="$task" '/^\|/ { cell=$2; gsub(/^[ \t]+|[ \t]+$/,"",cell); if (cell==id) next } { print }' "$file" > "$tmp"
  tmp2="$(mktemp "${TMPDIR:-/tmp}/project-docs-roadmap.XXXXXX")"
  # The row becomes the LAST row of the Active work table (walking back from
  # the context:end marker over the blank line that separates them), not a
  # line just above the marker, which would detach it from the table and
  # break Markdown rendering. The empty-table placeholder row goes away.
  awk -v row="$newrow" -v marker="<!-- context:end -->" '
    { line[NR]=$0 }
    END {
      m=0; aw=0; k=0
      for (i=1;i<=NR;i++) {
        if (!aw && line[i]=="## Active work") aw=i
        if (!m && line[i]==marker) m=i
      }
      if (m) for (i=m-1;i>=1;i--) {
        if (line[i] ~ /^\|/) { k=i; break }
        if (line[i] ~ /^#/) break
      }
      for (i=1;i<=NR;i++) {
        skip=0
        if (aw && m && i>aw && i<m && line[i] ~ /^\|/) {
          t=line[i]; gsub(/[| \t]/,"",t); gsub(/—/,"",t)
          if (t=="") skip=1
        }
        if (!k && i==m) print row
        if (!skip) print line[i]
        if (k && i==k) print row
      }
      if (!m) print row
    }
  ' "$tmp" > "$tmp2"
  mv "$tmp2" "$file"
  rm -f "$tmp"
}

roadmap_remove_row_file() {
  task="$1"
  file="$DOCS_DIR/Roadmap.md"
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-roadmap.XXXXXX")"
  awk -F'|' -v id="$task" '/^\|/ { cell=$2; gsub(/^[ \t]+|[ \t]+$/,"",cell); if (cell==id) next } { print }' "$file" > "$tmp"
  mv "$tmp" "$file"
}

roadmap_claim_row() {
  task="$1"; agent="$2"; ts="$3"
  owner="$agent@$ts"
  section="$(roadmap_section_of "$task")"
  if [ "$section" = "plan" ]; then
    roadmap_move_to_active "$task" "IN_PROGRESS" "$owner" "—"
  else
    roadmap_update_row_inplace "$task" "IN_PROGRESS" "$owner" "—"
  fi
}

update_features_summary() {
  file="$1"; verify="$2"; date_only="$3"
  count="$(table_ids "$file" | wc -l | tr -d ' ')"
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-features.XXXXXX")"
  awk -v n="$count" -v v="$verify" -v d="$date_only" '
    /^- Verified capabilities:/ { print "- Verified capabilities: " n; next }
    /^- Latest verification:/ { print "- Latest verification: `" v "` (" d ")"; next }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# Records a closed task in Features.md. When its ID is a task under an EPIC
# (`F01-E01-T01`, inferred from the ID shape, not a stored field) and no
# other Roadmap row still shares that epic prefix, also rolls the epic up
# with its own Features row.
features_add_capability() {
  task="$1"; summary="$2"; verify="$3"; timestamp="$4"
  file="$DOCS_DIR/Features.md"
  date_only="${timestamp%%T*}"
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-features.XXXXXX")"
  awk -v ph='| — | — | — | — | — |' '$0==ph { next } { print }' "$file" > "$tmp"
  mv "$tmp" "$file"
  printf '| %s | %s | %s | log:%s | %s |\n' "$task" "$summary" "$verify" "$task" "$date_only" >> "$file"
  epic="$(printf '%s' "$task" | sed 's/^\(F[0-9][0-9]*-E[0-9][0-9]*\)-.*/\1/')"
  if [ "$epic" != "$task" ]; then
    if ! roadmap_has_id_prefix "${epic}-" && ! table_ids "$file" | grep -qxF -- "$epic"; then
      printf '| %s | Epic complete | all tasks DONE | log:%s | %s |\n' "$epic" "$task" "$date_only" >> "$file"
    fi
  fi
  update_features_summary "$file" "$verify" "$date_only"
}

# ---------------------------------------------------------------------------
# Lock: claim/pause/done mutate Agentslog.md and Roadmap.md together. Locking
# is atomic only within one working copy; across machines, commit and push
# the claim entry immediately so other agents see it before they claim.
# ---------------------------------------------------------------------------
with_lock() {
  lockdir="$DOCS_DIR/.lock"
  attempts=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [ -d "$lockdir" ]; then
      lock_epoch="$(stat -c %Y "$lockdir" 2>/dev/null || stat -f %m "$lockdir" 2>/dev/null || echo 0)"
      now_epoch="$(date -u +%s)"
      if [ $((now_epoch - lock_epoch)) -ge 30 ]; then
        rmdir "$lockdir" 2>/dev/null || true
        continue
      fi
    fi
    if [ "$attempts" -ge 50 ]; then
      die "could not acquire docs/.lock (busy); retry"
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
  trap 'rmdir "$lockdir" 2>/dev/null || true' EXIT HUP INT TERM
}

cmd_claim() {
  shift 2
  [ "$#" -ge 3 ] || die "claim requires: agent task-id summary"
  agent="$(clean_field "$1")"
  task="$(clean_field "$2")"
  summary="$(clean_field "$3")"
  [ -f "$DOCS_DIR/Agentslog.md" ] || die "run init first"
  if ! roadmap_has_id "$task"; then
    die "claim failed: $task not found in docs/Roadmap.md"
  fi
  with_lock
  if state="$(task_state "$task")"; then
    status="$(printf '%s' "$state" | cut -f2)"
    owner="$(printf '%s' "$state" | cut -f3)"
    pausecat="$(printf '%s' "$state" | cut -f5)"
    if [ "$status" = "IN_PROGRESS" ]; then
      if [ "$owner" != "$agent" ] && ! is_stale "$task"; then
        die "claim failed: $task is IN_PROGRESS, owned by $owner"
      fi
    elif [ "$status" = "PAUSE" ]; then
      if [ "$pausecat" != "LIMITE" ] && [ "$owner" != "$agent" ]; then
        die "claim failed: $task is PAUSE ($pausecat); resolvable only by $owner until the reason clears"
      fi
    fi
  fi
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  {
    echo
    echo "## [$timestamp] | $agent | $task | IN_PROGRESS"
    echo "- Summary: $summary"
    echo "- Verify: pending"
  } >> "$DOCS_DIR/Agentslog.md"
  roadmap_claim_row "$task" "$agent" "$timestamp"
  echo "project_docs claim: $task claimed by $agent"
}

cmd_pause() {
  shift 2
  [ "$#" -ge 4 ] || die "pause requires: agent task-id category detail"
  agent="$(clean_field "$1")"
  task="$(clean_field "$2")"
  category="$(clean_field "$3")"
  detail="$(clean_field "$4")"
  case "$category" in
    LIMITE|ESPERA_RESPUESTA|BLOQUEO|OTRO) ;;
    *) die "pause requires category one of LIMITE, ESPERA_RESPUESTA, BLOQUEO, OTRO" ;;
  esac
  [ -n "$detail" ] || die "pause requires a non-empty detail"
  with_lock
  if state="$(task_state "$task")"; then
    status="$(printf '%s' "$state" | cut -f2)"
    owner="$(printf '%s' "$state" | cut -f3)"
  else
    die "pause failed: $task has no IN_PROGRESS entry to pause"
  fi
  [ "$status" = "IN_PROGRESS" ] || die "pause failed: $task is not IN_PROGRESS (current: $status)"
  [ "$owner" = "$agent" ] || die "pause failed: $task is owned by $owner, not $agent"
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  {
    echo
    echo "## [$timestamp] | $agent | $task | PAUSE"
    echo "- Pause: $category - $detail"
  } >> "$DOCS_DIR/Agentslog.md"
  roadmap_update_row_inplace "$task" "PAUSE" "$agent@$timestamp" "$category"
  echo "project_docs pause: $task paused ($category)"
}

cmd_done() {
  shift 2
  [ "$#" -ge 5 ] || die "done requires: agent task-id summary files verify"
  agent="$(clean_field "$1")"
  task="$(clean_field "$2")"
  summary="$(clean_field "$3")"
  files="$(clean_field "$4")"
  verify="$(clean_field "$5")"
  [ -n "$verify" ] || die "done requires a non-empty verify"
  with_lock
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  {
    echo
    echo "## [$timestamp] | $agent | $task | DONE"
    echo "- Summary: $summary"
    echo "- Files: $files"
    echo "- Verify: $verify"
  } >> "$DOCS_DIR/Agentslog.md"
  roadmap_remove_row_file "$task"
  features_add_capability "$task" "$summary" "$verify" "$timestamp"
  echo "project_docs done: $task closed"
}

cmd_status() {
  [ -f "$DOCS_DIR/Agentslog.md" ] || die "run init first"
  all_task_states | awk -F'\t' '$2=="IN_PROGRESS" || $2=="PAUSE"' |
  while IFS="$TAB" read -r tid status agent ts pausecat conflict everdone; do
    [ -n "$tid" ] || continue
    hrs="$(age_hours "$ts")"
    reason="-"
    if [ "$status" = "PAUSE" ]; then reason="$pausecat"; fi
    stale=""
    if [ "$status" = "IN_PROGRESS" ] && [ "$hrs" != "?" ] && [ "$hrs" -ge "$STALE_HOURS" ]; then
      stale=" (stale)"
    fi
    printf '%s | %s | %s | %sh%s | %s\n' "$tid" "$agent" "$status" "$hrs" "$stale" "$reason"
  done
}

# ---------------------------------------------------------------------------
# migrate
# ---------------------------------------------------------------------------
ensure_roadmap_sections() {
  file="$DOCS_DIR/Roadmap.md"
  [ -f "$file" ] || return 0
  if ! grep -qF "## Plan" "$file"; then
    {
      echo
      echo "## Plan"
      echo
      echo "Full PHASE -> EPIC -> TASK -> SUBTASK hierarchy for pending work."
      echo
    } >> "$file"
  fi
  if ! grep -qF "## Gaps, Bugs & Technical Debt" "$file"; then
    {
      echo
      echo "## Gaps, Bugs & Technical Debt"
      echo
      echo "| ID | Severity | Phase | Description | Status | Owner | Depends on | Pause reason |"
      echo "|---|---|---|---|---|---|---|---|"
      echo "| — | — | — | — | — | — | — | — |"
    } >> "$file"
  fi
  if ! grep -qF "## Out of scope" "$file"; then
    {
      echo
      echo "## Out of scope"
      echo
      echo "- \`UNKNOWN\`"
    } >> "$file"
  fi
  active_has_pause_reason="$(awk '
    /^## Active work/ { a=1; next }
    /^## Near term/ { a=0 }
    a && /^\| ID \|/ { print (index($0,"Pause reason") > 0) ? "1" : "0"; exit }
  ' "$file")"
  if [ "$active_has_pause_reason" != "1" ]; then
    tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-roadmap.XXXXXX")"
    awk '
      /^## Active work/ { active=1 }
      /^## Near term/ { active=0 }
      /^## Plan/ { active=0 }
      active && /^\| ID \|/ { print $0 " Pause reason |"; next }
      active && /^\|---/ { print $0 "---|"; next }
      active && /^\|/ { sub(/\|[ \t]*$/,"| — |"); print; next }
      { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  fi
}

# True if docs/Roadmap.md still uses the per-entry YAML block format from the
# short-lived schema this skill used before reverting to Markdown tables. A
# table-format file (fresh from the template, or already migrated) has no
# ```yaml fence, so this doubles as the idempotency check below.
roadmap_needs_yaml_migration() {
  file="$DOCS_DIR/Roadmap.md"
  [ -f "$file" ] || return 1
  grep -qE '^```yaml[ \t]*$' "$file"
}

# Non-destructive per-entry YAML -> table conversion. Every entry keeps its
# ID (the hard requirement); PHASE/THEME/EPIC/FEATURE become headings (the
# spine's `parent` chain is walked, up to 8 hops, to place each heading under
# its nearest PHASE and each TASK/SUBTASK/FEATURE row under its nearest
# EPIC); GAP/BUG/DECISION/BLOCKER/and other cross-cutting entries become rows
# in "## Gaps, Bugs & Technical Debt" (a DECISION's question/options/decision
# fields are not representable in the table schema and are dropped after
# converting the ID and title — review those by hand). An entry whose parent
# chain never reaches a PHASE is kept, not dropped, under a synthesized
# "F00-ORPHANED" phase for manual placement.
roadmap_migrate_yaml_to_table() {
  file="$DOCS_DIR/Roadmap.md"
  roadmap_needs_yaml_migration || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-roadmap.XXXXXX")"
  nearterm="$(awk '/^## Plan/{exit} /^## Near term/{p=1} p{print}' "$TEMPLATES_DIR/Roadmap.md")"
  {
    awk '/^## Active work/{exit} {print}' "$TEMPLATES_DIR/Roadmap.md"
    awk -v nearterm="$nearterm

" '
      BEGIN { insection="" }
      /^## Plan/ { insection="plan"; next }
      /^## Cross-cutting/ { insection="cross"; next }
      /^```yaml/ {
        infence=1; id=""; type=""; title=""; status=""; parent=""; agent=""
        desc=""; accept=""; sev=""; ph=""; deps=""; pendkey=""; capturedac=0
        next
      }
      infence && /^```[ \t]*$/ {
        infence=0
        if (id!="" && !(id in seen)) {
          seen[id]=1; order[++n]=id
          etype[id]=type; etitle[id]=title; estatus[id]=status; eparent[id]=parent
          eagent[id]=agent; edesc[id]=desc; eaccept[id]=accept; esev[id]=sev
          ephase[id]=ph; edeps[id]=deps; esection[id]=insection
        }
        next
      }
      infence {
        line=$0
        if (line ~ /^[A-Za-z_][A-Za-z0-9_]*:/) {
          colon=index(line,":")
          key=substr(line,1,colon-1)
          val=substr(line,colon+1)
          sub(/^[ \t]+/,"",val); gsub(/[ \t]+$/,"",val)
          pendkey=""
          if (key=="id") id=val
          else if (key=="type") type=val
          else if (key=="title") { title=val; gsub(/"/,"",title) }
          else if (key=="status") status=val
          else if (key=="parent") { parent=val; gsub(/"/,"",parent) }
          else if (key=="assigned_agent") { agent=val; gsub(/"/,"",agent) }
          else if (key=="severity") sev=val
          else if (key=="phase") ph=val
          else if (key=="depends_on") pendkey="dep"
          else if (key=="description") {
            if (val=="" || val==">" || val=="|") { pendkey="desc"; desc="" }
            else { desc=val; gsub(/"/,"",desc) }
          }
          else if (key=="acceptance_criteria") { pendkey="ac"; capturedac=0 }
          next
        }
        if (line ~ /^[ \t]+-[ \t]/) {
          item=line
          sub(/^[ \t]+-[ \t]+/,"",item)
          gsub(/^[ \t]+|[ \t]+$/,"",item)
          if (pendkey=="dep") { gsub(/"/,"",item); deps=(deps==""?item:deps";"item) }
          else if (pendkey=="ac") capturedac=1
          next
        }
        if (pendkey=="desc" && line ~ /^[ \t]+/) {
          t=line; gsub(/^[ \t]+|[ \t]+$/,"",t)
          desc=(desc==""?t:desc" "t)
          next
        }
        if (pendkey=="ac" && capturedac==1 && line ~ /^[ \t]+description:/) {
          t=line
          sub(/^[ \t]+description:[ \t]*/,"",t)
          gsub(/^[ \t]+|[ \t]+$/,"",t); gsub(/"/,"",t)
          if (accept=="") accept=t
          next
        }
        if (line ~ /^[ \t]/) next
        pendkey=""
      }
      function walk_up_for_type(startid, wanttype,    cur, hops) {
        cur = startid
        hops = 0
        while (cur != "" && hops < 8) {
          if (etype[cur] == wanttype) return cur
          cur = eparent[cur]
          hops++
        }
        return ""
      }
      function map_wf_status(s) {
        if (s=="IDEA" || s=="BACKLOG" || s=="READY" || s=="PENDING") return "TODO"
        if (s=="IN_PROGRESS" || s=="REVIEW" || s=="TESTING") return "IN_PROGRESS"
        if (s=="BLOCKED") return "PAUSE"
        if (s=="DONE" || s=="DECIDED") return "DONE"
        if (s=="CANCELLED" || s=="DEFERRED") return "TODO"
        return "TODO"
      }
      function orfield(v) { return (v=="" ? "—" : v) }
      function orstr(v, fb) { return (v=="" ? fb : v) }
      function print_row(id,    st, ag, dp) {
        st = map_wf_status(estatus[id])
        ag = orfield(eagent[id])
        dp = orfield(edeps[id]); gsub(/;/,", ",dp)
        printf "| %s | %s | %s | %s | %s | %s | — |\n", id, orstr(edesc[id],etitle[id]), orstr(eaccept[id],"UNKNOWN"), st, ag, dp
      }
      function print_gap_row(id,    st, ag, dp) {
        st = map_wf_status(estatus[id])
        ag = orfield(eagent[id])
        dp = orfield(edeps[id]); gsub(/;/,", ",dp)
        printf "| %s | %s | %s | %s | %s | %s | %s | — |\n", id, orfield(esev[id]), orfield(ephase[id]), orstr(edesc[id],etitle[id]), st, ag, dp
      }
      END {
        for (i=1;i<=n;i++) {
          id=order[i]
          if (esection[id]!="plan") continue
          t=etype[id]
          if (t=="EPIC") epic_phase[id]=walk_up_for_type(eparent[id],"PHASE")
          else if (t=="THEME") theme_phase[id]=walk_up_for_type(eparent[id],"PHASE")
          else if (t=="TASK" || t=="SUBTASK" || t=="FEATURE") {
            row_epic[id]=walk_up_for_type(eparent[id],"EPIC")
            if (row_epic[id]=="") row_phase[id]=walk_up_for_type(eparent[id],"PHASE")
            st=map_wf_status(estatus[id])
            if (st=="IN_PROGRESS" || st=="PAUSE") is_active[id]=1
          }
        }
        print "## Active work"
        print ""
        print "| ID | Outcome | Acceptance check | Status | Owner | Depends on | Pause reason |"
        print "|---|---|---|---|---|---|---|"
        activecount=0
        for (i=1;i<=n;i++) { id=order[i]; if (is_active[id]) { print_row(id); activecount++ } }
        if (!activecount) print "| — | — | — | — | — | — | — |"
        print ""
        print "<!-- context:end -->"
        print ""
        printf "%s", nearterm
        anyphase=0
        for (i=1;i<=n;i++) if (esection[order[i]]=="plan" && etype[order[i]]=="PHASE") anyphase=1
        print "## Plan"
        print ""
        visionid=""
        for (i=1;i<=n;i++) { if (etype[order[i]]=="VISION") { visionid=order[i]; break } }
        if (visionid!="") printf "**Vision:** %s\n", orstr(edesc[visionid],etitle[visionid])
        else printf "**Vision:** `UNKNOWN`\n"
        print ""
        if (!anyphase) {
          print "### F01 — UNKNOWN phase name"
          print ""
          print "#### F01-E01 — UNKNOWN epic name"
          print ""
          print "| ID | Outcome | Acceptance check | Status | Owner | Depends on | Pause reason |"
          print "|---|---|---|---|---|---|---|"
          print "| F01-E01-T01 | UNKNOWN | UNKNOWN | TODO | — | — | — |"
        }
        for (i=1;i<=n;i++) {
          id=order[i]
          if (esection[id]!="plan" || etype[id]!="PHASE") continue
          printf "\n### %s — %s\n", id, etitle[id]
          if (edesc[id]!="" && edesc[id]!=etitle[id]) printf "\n%s\n", edesc[id]
          for (j=1;j<=n;j++) {
            tid=order[j]
            if (esection[tid]=="plan" && etype[tid]=="THEME" && theme_phase[tid]==id) {
              printf "\n#### %s — %s\n", tid, etitle[tid]
              if (edesc[tid]!="" && edesc[tid]!=etitle[tid]) printf "\n%s\n", edesc[tid]
            }
          }
          rowcount=0
          for (j=1;j<=n;j++) {
            rid=order[j]
            if (esection[rid]=="plan" && (etype[rid]=="TASK"||etype[rid]=="SUBTASK"||etype[rid]=="FEATURE") && row_phase[rid]==id && !is_active[rid]) rowcount++
          }
          if (rowcount>0) {
            print ""
            print "| ID | Outcome | Acceptance check | Status | Owner | Depends on | Pause reason |"
            print "|---|---|---|---|---|---|---|"
            for (j=1;j<=n;j++) {
              rid=order[j]
              if (esection[rid]=="plan" && (etype[rid]=="TASK"||etype[rid]=="SUBTASK"||etype[rid]=="FEATURE") && row_phase[rid]==id && !is_active[rid]) print_row(rid)
            }
          }
          for (j=1;j<=n;j++) {
            eid=order[j]
            if (esection[eid]=="plan" && etype[eid]=="EPIC" && epic_phase[eid]==id) {
              printf "\n##### %s — %s\n", eid, etitle[eid]
              if (edesc[eid]!="" && edesc[eid]!=etitle[eid]) printf "\n%s\n", edesc[eid]
              print ""
              print "| ID | Outcome | Acceptance check | Status | Owner | Depends on | Pause reason |"
              print "|---|---|---|---|---|---|---|"
              erowcount=0
              for (k=1;k<=n;k++) {
                rid=order[k]
                if (esection[rid]=="plan" && (etype[rid]=="TASK"||etype[rid]=="SUBTASK"||etype[rid]=="FEATURE") && row_epic[rid]==eid && !is_active[rid]) { print_row(rid); erowcount++ }
              }
              if (erowcount==0) print "| — | — | — | — | — | — | — |"
            }
          }
        }
        orphanhdr=0
        for (i=1;i<=n;i++) {
          id=order[i]
          if (esection[id]!="plan" || is_active[id]) continue
          t=etype[id]; isorphan=0
          if (t=="EPIC" && epic_phase[id]=="") isorphan=1
          else if (t=="THEME" && theme_phase[id]=="") isorphan=1
          else if ((t=="TASK"||t=="SUBTASK"||t=="FEATURE") && row_epic[id]=="" && row_phase[id]=="") isorphan=1
          if (isorphan) {
            if (!orphanhdr) {
              print "\n### F00-ORPHANED — Migrated entries needing manual placement"
              print ""
              print "| ID | Outcome | Acceptance check | Status | Owner | Depends on | Pause reason |"
              print "|---|---|---|---|---|---|---|"
              orphanhdr=1
            }
            print_row(id)
          }
        }
        print ""
        print "## Gaps, Bugs & Technical Debt"
        print ""
        print "Errors, defects, or significant technical debt found by any agent. Same"
        print "trailing columns as above, so an entry can be `claim`ed and `done` like any"
        print "task. ID prefix marks the kind: `Fxx-GAP-xx` (missing capability),"
        print "`Fxx-BUG-xx` (defect), `Fxx-DEBT-xx` (technical debt)."
        print ""
        print "| ID | Severity | Phase | Description | Status | Owner | Depends on | Pause reason |"
        print "|---|---|---|---|---|---|---|---|"
        gaprows=0
        for (i=1;i<=n;i++) { if (esection[order[i]]=="cross") { print_gap_row(order[i]); gaprows++ } }
        if (!gaprows) print "| — | — | — | — | — | — | — | — |"
        print ""
        print "## Out of scope"
        print ""
        print "- `UNKNOWN`"
      }
    ' "$file"
  } > "$tmp"
  mv "$tmp" "$file"
  return 0
}

migrate_docs() {
  require_templates
  changed=0
  variant="$(find_case_variant "$PROJECT" "AGENTS.md")"
  if [ -n "$variant" ] && [ "$variant" != "AGENTS.md" ]; then
    rename_case "$PROJECT/$variant" "$PROJECT/AGENTS.md"
    changed=$((changed + 1))
    echo "= renamed: $variant -> AGENTS.md"
  fi
  # Ensure base files (and a plain AGENTS.md block) exist first; the legacy
  # merge below runs last so its combined content is not clobbered by
  # init's own template-only block write.
  init_docs
  legacy="$(find_case_variant "$DOCS_DIR" "Agents.md")"
  if [ -n "$legacy" ]; then
    legacy_path="$DOCS_DIR/$legacy"
    target="$PROJECT/AGENTS.md"
    tmp_legacy="$(mktemp "${TMPDIR:-/tmp}/project-docs-legacy.XXXXXX")"
    {
      cat "$TEMPLATES_DIR/AGENTS.md"
      echo
      echo "<!-- migrated from docs/$legacy -->"
      cat "$legacy_path"
    } > "$tmp_legacy"
    replace_block "$target" "$tmp_legacy" || true
    rm -f "$tmp_legacy"
    remove_file "$legacy_path"
    changed=$((changed + 1))
    echo "= migrated: docs/$legacy -> AGENTS.md (content preserved, file removed)"
  fi
  if roadmap_migrate_yaml_to_table; then
    changed=$((changed + 1))
    echo "= converted: docs/Roadmap.md per-entry YAML -> tables (IDs preserved; review DECISION"
    echo "  entries and any F00-ORPHANED rows by hand)"
  fi
  ensure_roadmap_sections
  echo "project_docs migrate: $changed change(s)"
}

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------
need() {
  rel="$1"; shift
  path="$PROJECT/$rel"
  if [ ! -f "$path" ]; then
    echo "MISSING: $rel" >&2
    CHECK_FAIL=1
    return
  fi
  for marker in "$@"; do
    if ! grep -qF -- "$marker" "$path"; then
      echo "INVALID $rel: missing '$marker'" >&2
      CHECK_FAIL=1
    fi
  done
}

check_log_rotation() {
  log="$DOCS_DIR/Agentslog.md"
  log_bytes="$(wc -c < "$log" | tr -d ' ')"
  log_entries="$(count_log_entries "$log")"
  if [ "$log_bytes" -gt "$LOG_BYTES_LIMIT" ] || [ "$log_entries" -gt "$LOG_ENTRIES_LIMIT" ]; then
    echo "ROTATE REQUIRED: Agentslog has ${log_entries} entries / ${log_bytes} bytes" >&2
    CHECK_FAIL=1
  fi
}

check_log_entries() {
  log="$DOCS_DIR/Agentslog.md"
  out="$(awk '
    $0 == "## Entries" { in_entries=1; next }
    in_entries && /^## \[/ {
      if (hdr != "") { validate() }
      hdr=$0
      line=$0
      sub(/^## \[/,"",line)
      sub(/\] \| /,"|",line)
      gsub(/ \| /,"|",line)
      split(line,f,"|")
      status=f[4]; tidnow=f[3]; agentnow=f[2]
      if (status=="IN_PROGRESS" && last_status[tidnow]=="IN_PROGRESS" && last_agent[tidnow]!=agentnow) {
        print "ERROR: conflicting concurrent claim on " tidnow ": " last_agent[tidnow] " and " agentnow
      }
      last_status[tidnow]=status
      last_agent[tidnow]=agentnow
      pauseline=""
      verifyline=""
      next
    }
    in_entries && /^- Pause:/ { pauseline=$0; next }
    in_entries && /^- Verify:/ { verifyline=$0; next }
    END { if (hdr != "") validate() }
    function validate(   body,dash,cat,detail) {
      if (status!="IN_PROGRESS" && status!="PAUSE" && status!="DONE") {
        print "ERROR: invalid status in entry: " hdr
      }
      if (status=="PAUSE") {
        if (pauseline=="") {
          print "ERROR: PAUSE entry missing Pause line: " hdr
        } else {
          body=pauseline
          sub(/^- Pause: /,"",body)
          dash=index(body," - ")
          cat=(dash>0) ? substr(body,1,dash-1) : body
          detail=(dash>0) ? substr(body,dash+3) : ""
          if (cat!="LIMITE" && cat!="ESPERA_RESPUESTA" && cat!="BLOQUEO" && cat!="OTRO") {
            print "ERROR: PAUSE entry has invalid category: " hdr
          }
          if (detail=="") {
            print "ERROR: PAUSE entry missing detail: " hdr
          }
        }
      }
      if (status=="DONE") {
        if (verifyline=="") {
          print "ERROR: DONE entry missing Verify line: " hdr
        } else {
          body=verifyline
          sub(/^- Verify: /,"",body)
          gsub(/^[ \t]+|[ \t]+$/,"",body)
          if (body=="" || body=="pending") {
            print "ERROR: DONE entry has empty or pending Verify: " hdr
          }
        }
      }
    }
  ' "$log")"
  if [ -n "$out" ]; then
    printf '%s\n' "$out" >&2
    CHECK_FAIL=1
  fi
}

history_has_done() {
  tid="$1"
  [ -d "$HISTORY_DIR" ] || return 1
  for f in "$HISTORY_DIR"/*.md; do
    [ -e "$f" ] || continue
    if grep -qE "^## \[[^]]*\] \| [^|]* \| $tid \| DONE" "$f"; then
      return 0
    fi
  done
  return 1
}

epic_history_done() {
  epic="$1"
  prefix="${epic}-"
  if all_task_states | awk -F'\t' -v p="$prefix" '$1 ~ "^"p && $7=="1"{f=1} END{exit(f?0:1)}'; then
    return 0
  fi
  if [ -d "$HISTORY_DIR" ]; then
    for f in "$HISTORY_DIR"/*.md; do
      [ -e "$f" ] || continue
      if grep -qE "^## \[[^]]*\] \| [^|]* \| ${prefix}[^ ]* \| DONE" "$f"; then
        return 0
      fi
    done
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Epistemic taxonomy and canonical-ID hardening. Two disjoint Status
# vocabularies exist by design: fact tables in ProductDescription.md and
# Stack_Tecnologies.md use the epistemic one (CONFIRMED/HYPOTHESIS/UNKNOWN —
# is this true?); work-item tables in Roadmap.md use the workflow one
# (TODO/IN_PROGRESS/PAUSE/DONE — what state is this task in?). Never mix the
# two: a table's Status column means one or the other depending on which
# file it lives in, never both.
# ---------------------------------------------------------------------------

# Validates every table's Status column in $rel against $allowed (space-
# separated), file-wide. Detects each table's own header (the first `|` row
# after a non-`|` line) so it re-locates the Status column per table instead
# of assuming a fixed position; placeholder rows (id blank/—/dashes) are
# skipped, same convention as table_ids().
check_table_status_enum() {
  rel="$1"; allowed="$2"; label="$3"
  path="$PROJECT/$rel"
  [ -f "$path" ] || return 0
  out="$(awk -v allowed="$allowed" -v label="$label" -v rel="$rel" '
    BEGIN {
      na=split(allowed,a," ")
      for (i=1;i<=na;i++) ok[a[i]]=1
      expect_header=1; statuscol=0
    }
    !/^\|/ { expect_header=1; next }
    /^\|/ {
      line=$0
      sub(/^\|/,"",line); sub(/\|[ \t]*$/,"",line)
      ncol=split(line,c,"|")
      for (i=1;i<=ncol;i++) gsub(/^[ \t]+|[ \t]+$/,"",c[i])
      if (expect_header) {
        statuscol=0
        for (i=1;i<=ncol;i++) if (c[i]=="Status") statuscol=i
        expect_header=0
        next
      }
      id=c[1]
      if (id=="" || id=="—" || id ~ /^-+$/) next
      if (statuscol>0 && statuscol<=ncol) {
        st=c[statuscol]
        if (!(st in ok)) print "ERROR: " rel " row '\''" id "'\'' has invalid " label " Status: " st
      }
    }
  ' "$path")"
  if [ -n "$out" ]; then
    printf '%s\n' "$out" >&2
    CHECK_FAIL=1
  fi
}

# Validates every row's ID (first column) under the exact "## <heading>"
# section of $rel against ERE $regex. Header/separator/placeholder rows are
# recognized by content (id blank/"ID"/—/dashes), so a section with several
# tables (Roadmap's one-per-epic Plan tables) needs no per-table state. Rows
# under "### F00-ORPHANED" are exempt: migrate places them there verbatim
# (ID preserved, not reshaped) specifically for manual review, so a legacy
# ID that doesn't fit the current convention is expected, not an error.
check_id_format_in_section() {
  rel="$1"; heading="$2"; regex="$3"; label="$4"
  path="$PROJECT/$rel"
  [ -f "$path" ] || return 0
  out="$(awk -v heading="$heading" -v re="$regex" -v rel="$rel" -v label="$label" '
    $0==heading { insec=1; next }
    insec && /^## / { insec=0; orphan=0 }
    insec && /^### F00-ORPHANED/ { orphan=1 }
    insec && orphan && /^#/ && $0 !~ /^### F00-ORPHANED/ { orphan=0 }
    insec && /^\|/ {
      line=$0
      sub(/^\|/,"",line); sub(/\|[ \t]*$/,"",line)
      split(line,c,"|")
      id=c[1]
      gsub(/^[ \t]+|[ \t]+$/,"",id)
      if (id=="" || id=="ID" || id=="—" || id ~ /^-+$/) next
      if (orphan) next
      if (id !~ re) print "ERROR: " rel " " label " has invalid ID format: " id
    }
  ' "$path")"
  if [ -n "$out" ]; then
    printf '%s\n' "$out" >&2
    CHECK_FAIL=1
  fi
}

check_roadmap_features_ids() {
  rm_file="$(mktemp "${TMPDIR:-/tmp}/project-docs-rmids.XXXXXX")"
  ft_file="$(mktemp "${TMPDIR:-/tmp}/project-docs-ftids.XXXXXX")"
  roadmap_ids > "$rm_file"
  features_ids > "$ft_file"
  out="$(all_task_states | awk -F'\t' -v rmf="$rm_file" -v ftf="$ft_file" '
    BEGIN {
      while ((getline line < rmf) > 0) rm[line]=1
      while ((getline line < ftf) > 0) { ft[line]=1; order[++n]=line }
    }
    {
      tid=$1; everdone=$7
      logtid_order[++lc]=tid
      log_done[tid]=(everdone=="1")
      if (!(tid in rm) && !(tid in ft)) {
        print "ERROR: log ID " tid " not found in Roadmap or Features"
      }
    }
    END {
      for (i=1;i<=n;i++) {
        t=order[i]
        if (log_done[t]) continue
        ok=0
        if (t ~ /^F[0-9]+-E[0-9]+$/) {
          prefix = t "-"
          any=0; all=1
          for (j=1;j<=lc;j++) {
            cid=logtid_order[j]
            if (index(cid, prefix)==1) {
              any=1
              if (!log_done[cid]) all=0
            }
          }
          if (any && all) ok=1
        }
        if (!ok) {
          print "ERROR: Features ID " t " has no DONE entry in the log"
        }
      }
    }
  ')"
  rm -f "$rm_file" "$ft_file"
  if [ -n "$out" ]; then
    remaining=""
    while IFS= read -r line; do
      case "$line" in
        "ERROR: Features ID "*" has no DONE entry in the log")
          tid="${line#ERROR: Features ID }"
          tid="${tid% has no DONE entry in the log}"
          if printf '%s' "$tid" | grep -qE '^F[0-9]+-E[0-9]+$'; then
            if epic_history_done "$tid"; then continue; fi
          else
            if history_has_done "$tid"; then continue; fi
          fi
          ;;
      esac
      remaining="$remaining
$line"
    done <<EOF
$out
EOF
    out="$remaining"
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out" >&2
    CHECK_FAIL=1
  fi
}

check_warnings() {
  unknown_count=0
  for f in docs/ProductDescription.md docs/Stack_Tecnologies.md docs/Features.md; do
    path="$PROJECT/$f"
    if [ -f "$path" ]; then
      c="$(extract_context_block "$path" "## Operational summary" | awk '{n+=gsub(/UNKNOWN/,"UNKNOWN")} END{print n+0}')"
      unknown_count=$((unknown_count + c))
    fi
  done
  if [ "$unknown_count" -gt 0 ]; then
    echo "WARN: $unknown_count UNKNOWN field(s) in Operational summaries" >&2
  fi
  for name in $LINK_TARGETS_DEFAULT; do
    rel="$(link_target_path "$name")"
    full="$PROJECT/$rel"
    if [ -f "$full" ] && ! has_block "$full"; then
      echo "WARN: $rel has no project-documentation redirect block; run 'link'" >&2
    fi
  done
  if [ -f "$DOCS_DIR/Agentslog.md" ]; then
    stale_out="$(all_task_states | awk -F'\t' '$2=="IN_PROGRESS"{print $1"\t"$4}')"
    if [ -n "$stale_out" ]; then
      printf '%s\n' "$stale_out" | while IFS="$TAB" read -r tid ts; do
        [ -n "$tid" ] || continue
        hrs="$(age_hours "$ts")"
        if [ "$hrs" != "?" ] && [ "$hrs" -ge "$STALE_HOURS" ]; then
          echo "WARN: $tid has been IN_PROGRESS for ${hrs}h (>= ${STALE_HOURS}h)" >&2
        fi
      done
    fi
  fi
}

check_docs() {
  CHECK_FAIL=0
  need AGENTS.md "## Repository rules" "## Startup" "## Close"
  legacy="$(find_case_variant "$DOCS_DIR" "Agents.md")"
  if [ -n "$legacy" ]; then
    echo "MIGRATION REQUIRED: docs/$legacy found; run 'migrate'" >&2
    CHECK_FAIL=1
  fi
  root_variants="$(list_case_variants "$PROJECT" "AGENTS.md" | wc -l | tr -d ' ')"
  if [ "$root_variants" -gt 1 ]; then
    echo "ERROR: multiple case variants of AGENTS.md coexist at project root" >&2
    CHECK_FAIL=1
  fi
  need docs/Agentslog.md "## Entry format" "## Entries"
  need docs/ProductDescription.md \
    "## Operational summary" "<!-- context:end -->" \
    "## Users and outcomes" "| User or role | Needed outcome | Status | Source |" \
    "## Business rules" "| ID | Rule | Status | Source or verification |" \
    "## Main flows" "| Flow | Start -> outcome | Status |" \
    "## Glossary" "| Term | Meaning | Status |" \
    "## Out of scope"
  need docs/Stack_Tecnologies.md \
    "## Operational summary" "<!-- context:end -->" \
    "## Architecture & Data" \
    "## Critical commands" \
    "## Environment variables & secrets" "| Variable | Purpose | Required | Example (Non-secret) |" \
    "## Technical decisions (ADRs)" "| ID | Decision | Context/Reason | Status | Date |" \
    "## Out of scope"
  need docs/Roadmap.md \
    "## Active work" "<!-- context:end -->" \
    "## Near term" "## Plan" "## Gaps, Bugs & Technical Debt" "## Out of scope"
  need docs/Features.md "## Operational summary" "## Verified capabilities"

  if roadmap_needs_yaml_migration; then
    echo "MIGRATION REQUIRED: docs/Roadmap.md still uses the per-entry YAML format; run 'migrate'" >&2
    CHECK_FAIL=1
  fi

  if [ "$CHECK_FAIL" -eq 0 ]; then
    if ! build_context >/dev/null; then
      CHECK_FAIL=1
    fi
  fi

  if [ -f "$DOCS_DIR/Agentslog.md" ]; then
    check_log_rotation
    check_log_entries
    check_roadmap_features_ids
  fi

  check_id_format_in_section docs/ProductDescription.md "## Business rules" '^BR-[0-9][0-9][0-9]+$' "Business rules"
  check_id_format_in_section docs/Stack_Tecnologies.md "## Technical decisions (ADRs)" '^ADR-[0-9][0-9][0-9]+$' "Technical decisions"
  check_id_format_in_section docs/Roadmap.md "## Plan" '^F[0-9]' "Plan"
  check_table_status_enum docs/ProductDescription.md "CONFIRMED HYPOTHESIS UNKNOWN" "epistemic"
  check_table_status_enum docs/Stack_Tecnologies.md "CONFIRMED HYPOTHESIS UNKNOWN" "epistemic"
  check_table_status_enum docs/Roadmap.md "TODO IN_PROGRESS PAUSE DONE" "workflow"

  check_warnings

  if [ "$CHECK_FAIL" -eq 0 ]; then
    echo "project_docs check: OK"
  else
    die "check failed"
  fi
}

# ---------------------------------------------------------------------------
# append-log (legacy/manual escape hatch, unchanged contract), rotate
# ---------------------------------------------------------------------------
append_log() {
  shift 2
  [ "$#" -ge 6 ] ||
    die "append-log requires: agent task status summary files verify [follow-up]"
  agent="$(clean_field "$1")"
  task="$(clean_field "$2")"
  status="$(clean_field "$3")"
  summary="$(clean_field "$4")"
  files="$(clean_field "$5")"
  verify="$(clean_field "$6")"
  follow_up="$(clean_field "${7:-none}")"
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  {
    echo
    echo "## [$timestamp] | $agent | $task | $status"
    echo "- Summary: $summary"
    echo "- Files: $files"
    echo "- Verify: $verify"
    echo "- Follow-up: $follow_up"
  } >> "$DOCS_DIR/Agentslog.md"
  echo "project_docs append-log: entry added"
}

file_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "rotation requires sha256sum or shasum"
  fi
}

rotate_log() {
  log="$DOCS_DIR/Agentslog.md"
  [ -f "$log" ] || die "run init first"
  log_bytes="$(wc -c < "$log" | tr -d ' ')"
  log_entries="$(count_log_entries "$log")"
  if [ "$log_bytes" -le "$LOG_BYTES_LIMIT" ] && [ "$log_entries" -le "$LOG_ENTRIES_LIMIT" ]; then
    echo "project_docs rotate: not required"
    return
  fi

  mkdir -p "$HISTORY_DIR"
  stamp="$(date -u +'%Y%m%d')"
  sequence=1
  while :; do
    suffix="$(printf '%03d' "$sequence")"
    archive="$HISTORY_DIR/Agentslog-$stamp-$suffix.md"
    if [ ! -e "$archive" ]; then break; fi
    sequence=$((sequence + 1))
  done

  cp "$log" "$archive"
  source_hash="$(file_hash "$log")"
  archive_hash="$(file_hash "$archive")"
  [ "$source_hash" = "$archive_hash" ] || die "archive hash verification failed"

  open_summary="$(all_task_states | awk -F'\t' '$2=="IN_PROGRESS" || $2=="PAUSE"')"
  archive_name="$(basename "$archive")"

  tmp="$DOCS_DIR/.Agentslog.md.tmp.$$"
  {
    echo "# Agents log"
    echo
    echo "Append-only ledger and the source of truth for task ownership. Older"
    echo "segments live in \`docs/history/\`."
    echo
    echo "## Entry format"
    echo
    echo '```markdown'
    echo "## [YYYY-MM-DDTHH:mm:ssZ] | agent | TASK-ID | IN_PROGRESS"
    echo "- Summary: what the agent will do or did"
    echo "- Files: paths or component names (optional)"
    echo "- Verify: command and result, or \"pending\" (required for DONE)"
    echo "- Pause: CATEGORY - detail (required for PAUSE)"
    echo '```'
    echo
    echo "## Previous segment"
    echo
    echo "- Archive: \`docs/history/$archive_name\`"
    echo "- SHA-256: \`$archive_hash\`"
    echo
    echo "## Entries"
    if [ -n "$open_summary" ]; then
      printf '%s\n' "$open_summary" | while IFS="$TAB" read -r tid status agent ts pausecat conflict everdone; do
        [ -n "$tid" ] || continue
        echo
        echo "## [$ts] | $agent | $tid | $status"
        echo "- Summary: carried forward from docs/history/$archive_name at rotation"
        if [ "$status" = "PAUSE" ]; then
          echo "- Pause: $pausecat - see docs/history/$archive_name for detail"
        fi
      done
    fi
  } > "$tmp"
  mv "$tmp" "$log"
  echo "project_docs rotate: archived $archive_name"
}

case "$COMMAND" in
  init) init_docs ;;
  check) check_docs ;;
  context) build_context ;;
  append-log) append_log "$@" ;;
  rotate) rotate_log ;;
  migrate) migrate_docs ;;
  link) cmd_link "$@" ;;
  claim) cmd_claim "$@" ;;
  pause) cmd_pause "$@" ;;
  done) cmd_done "$@" ;;
  status) cmd_status ;;
  *)
    echo "Usage: project_docs.sh {init|check|context|append-log|rotate|migrate|link|claim|pause|done|status} <project> [args]"
    ;;
esac
