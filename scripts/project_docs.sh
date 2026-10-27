#!/usr/bin/env sh
set -eu

COMMAND="${1:-help}"
PROJECT="${2:-.}"
# init and migrate take flags (--classic, --factory); with no project given the
# first argument is already a flag, so the project is the current folder.
case "$COMMAND:$PROJECT" in
  init:--*|migrate:--*) shift; set -- "$COMMAND" . "$@"; PROJECT="." ;;
esac
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
MIN_WORK_MINUTES="${PROJECT_DOCS_MIN_WORK_MINUTES:-5}"
BLOCK_START='<!-- project-documentation:start -->'
BLOCK_END='<!-- project-documentation:end -->'
TAB="$(printf '\t')"
# Unit separator: a NON-whitespace IFS for read -r. A tab IFS is whitespace,
# so read merges adjacent empty fields (pausecat, conflict, handoff, ... are
# usually empty) and shifts every later variable. Pipe the task-state TSV
# through tr '\t' to US before any while-read loop.
US="$(printf '\037')"
# Shared awk helpers (spliced in front of awk programs with "$AWK_EPOCH"'...').
# iso_epoch turns YYYY-MM-DDTHH:MM:SSZ into epoch seconds without date(1), so
# the scanners can compare entry timestamps on any platform; is_old needs
# -v stale_s=<seconds>. No apostrophes in here: this text sits inside a
# single-quoted shell string and an apostrophe would end it.
AWK_EPOCH='
function iso_epoch(ts,   y,m,d,hh,mi,ss,era,yoe,mp,doy,doe) {
  if (ts !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) return -1
  y=substr(ts,1,4)+0; m=substr(ts,6,2)+0; d=substr(ts,9,2)+0
  hh=substr(ts,12,2)+0; mi=substr(ts,15,2)+0; ss=substr(ts,18,2)+0
  if (m<=2) y--
  era=int(y/400)
  yoe=y-era*400
  mp=(m+9)%12
  doy=int((153*mp+2)/5)+d-1
  doe=yoe*365+int(yoe/4)-int(yoe/100)+doy
  return (era*146097+doe-719468)*86400+hh*3600+mi*60+ss
}
function is_old(prev, cur,   a, b) {
  a=iso_epoch(prev); b=iso_epoch(cur)
  if (a<0 || b<0) return 0
  return (b-a) >= stale_s
}
'

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
# init_kind [--classic]: factory or classic (ADR-047). A project the skill does
# not manage yet starts in Factory mode; --classic or PROJECT_DOCS_MODE=classic
# keep the six-file project. A project it already manages never switches mode
# on its own: with a Factory section its Mode decides, without one it stays
# classic (BR-008). migrate --factory is the way to switch an existing one.
init_kind() {
  if [ "${1:-}" = "--classic" ]; then echo classic; return 0; fi
  ik_env="$(printf '%s' "${PROJECT_DOCS_MODE:-}" | tr 'A-Z' 'a-z')"
  if [ "$ik_env" = "classic" ]; then echo classic; return 0; fi
  if factory_section_exists; then
    ik_v="$(factory_setting Mode | tr 'a-z' 'A-Z')"
    if [ "$ik_v" = "FACTORY" ]; then echo factory; else echo classic; fi
    return 0
  fi
  if [ -f "$PROJECT/AGENTS.md" ] && has_block "$PROJECT/AGENTS.md"; then echo classic; return 0; fi
  for ik_rel in $CONTRACT_FILES; do
    [ "$ik_rel" = "AGENTS.md" ] && continue
    if [ -f "$PROJECT/$ik_rel" ]; then echo classic; return 0; fi
  done
  echo factory
}

# init_docs [dispatch args]: init <project> [--classic].
init_docs() {
  if [ "$#" -ge 2 ]; then shift 2; else shift "$#"; fi
  id_flag=""
  for id_a in "$@"; do
    if [ "$id_a" = "--classic" ]; then id_flag="--classic"; fi
  done
  init_run "$(init_kind "$id_flag")"
}

init_run() {
  require_templates
  created=0
  init_kind_v="$1"
  init_files="$CONTRACT_FILES"
  init_agents_tpl="$TEMPLATES_DIR/AGENTS.md"
  if [ "$init_kind_v" = "factory" ]; then
    init_files="$CONTRACT_FILES docs/Brain.md"
    init_agents_tpl="$TEMPLATES_DIR/AGENTS.factory.md"
    [ -f "$init_agents_tpl" ] || die "template missing: AGENTS.factory.md"
  fi
  for rel in $init_files; do
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
          replace_block "$target" "$init_agents_tpl" || true
          echo "= merged skill block: $rel"
        fi
      else
        replace_block "$target" "$init_agents_tpl" || true
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
  if [ "$init_kind_v" = "factory" ]; then
    mkdir -p "$DOCS_DIR/specs" "$DOCS_DIR/brain/tasks"
    factory_dispatch_setup
  fi
  echo "project_docs init: $created file(s) created"
  link_docs "$PROJECT" ""
}

# extract_section FILE HEADING: the heading line and everything up to (not
# including) the next "## " heading.
extract_section() {
  awk -v h="$2" '
    $0==h { p=1; print; next }
    p && /^## / { exit }
    p { print }
  ' "$1"
}

# insert_section TARGET SECTION_FILE BEFORE_HEADING: puts the section before the
# given heading when it exists, else before the managed-block end marker, else
# at the end of the file. Nothing already in TARGET is changed or removed.
insert_section() {
  is_tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-section.XXXXXX")"
  awk -v secfile="$2" -v before="$3" -v endm="$BLOCK_END" '
    BEGIN { n=0; while ((getline l < secfile) > 0) s[++n]=l; while (n>0 && s[n]=="") n-- }
    { sub(/\r$/, ""); lines[NR]=$0 }
    END {
      pos=0
      if (before!="") for (i=1;i<=NR;i++) if (lines[i]==before) { pos=i; break }
      if (!pos) for (i=1;i<=NR;i++) if (lines[i]==endm) { pos=i; break }
      if (!pos) pos=NR+1
      for (i=1;i<pos;i++) print lines[i]
      if (pos>1 && lines[pos-1]!="") print ""
      for (i=1;i<=n;i++) print s[i]
      if (pos<=NR) print ""
      for (i=pos;i<=NR;i++) print lines[i]
    }
  ' "$1" > "$is_tmp"
  mv "$is_tmp" "$1"
}

# factory_dispatch_setup: .factory/dispatch.md from the template, and the .gitignore block for
# the files the dispatcher generates. Additive and idempotent; says only what it adds and leaves the
# number of changes in FDS_CHANGED.
FDS_CHANGED=0
factory_dispatch_setup() {
  FDS_CHANGED=0
  fds_tpl="$TEMPLATES_DIR/dispatch.md"
  [ -f "$fds_tpl" ] || die "template missing: dispatch.md"
  if [ ! -f "$PROJECT/.factory/dispatch.md" ]; then
    mkdir -p "$PROJECT/.factory"
    cp "$fds_tpl" "$PROJECT/.factory/dispatch.md"
    echo "+ created: .factory/dispatch.md"
    FDS_CHANGED=$((FDS_CHANGED + 1))
  fi
  fds_gi="$PROJECT/.gitignore"
  fds_mark='# project-documentation dispatcher (generated files)'
  # the marker counts in any case, with trailing spaces, after a BOM or with CRLF endings
  if ! { [ -f "$fds_gi" ] && clean_stream < "$fds_gi" | awk -v m="$fds_mark" '{ sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); if (tolower($0) == m) f = 1 } END { exit f ? 0 : 1 }'; }; then
    {
      if [ -s "$fds_gi" ]; then
        if [ -n "$(tail -c 1 "$fds_gi")" ]; then echo; fi
        echo
      fi
      echo "$fds_mark"
      echo ".factory/state.md"
      echo ".factory/runs/"
    } >> "$fds_gi"
    echo "+ added: .gitignore block for .factory/state.md and .factory/runs/"
    FDS_CHANGED=$((FDS_CHANGED + 1))
  fi
}

# migrate_factory_additions: what migrate --factory adds to an existing project.
# Idempotent and additive: the Factory section, the default roster when there is
# none, docs/Brain.md and the docs/specs and docs/brain/tasks folders.
migrate_factory_additions() {
  mf_changed=0
  mf_tpl="$TEMPLATES_DIR/AGENTS.factory.md"
  [ -f "$mf_tpl" ] || die "template missing: AGENTS.factory.md"
  mf_agents="$PROJECT/AGENTS.md"
  mf_sec="$(mktemp "${TMPDIR:-/tmp}/project-docs-sec.XXXXXX")"
  # The edits below match whole lines, so a CRLF AGENTS.md is made LF first (and
  # said so); the check and the other commands read either ending.
  if ! tr -d '\r' < "$mf_agents" | cmp -s - "$mf_agents"; then
    mf_tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-eol.XXXXXX")"
    tr -d '\r' < "$mf_agents" > "$mf_tmp"
    mv "$mf_tmp" "$mf_agents"
    echo "= normalized: AGENTS.md line endings (CRLF to LF)"
    mf_changed=$((mf_changed + 1))
  fi
  if ! factory_section_exists; then
    extract_section "$mf_tpl" "## Factory" > "$mf_sec"
    insert_section "$mf_agents" "$mf_sec" "## Agent identity"
    echo "+ added: ## Factory section in AGENTS.md"
    mf_changed=$((mf_changed + 1))
  elif [ "$(factory_setting Mode | tr 'a-z' 'A-Z')" != "FACTORY" ]; then
    echo "= kept: Mode is not FACTORY in AGENTS.md (set it to FACTORY to switch)"
  fi
  if ! grep -qx "## Agent identity" "$mf_agents"; then
    extract_section "$mf_tpl" "## Agent identity" > "$mf_sec"
    insert_section "$mf_agents" "$mf_sec" ""
    echo "+ added: ## Agent identity section with the default roster in AGENTS.md"
    mf_changed=$((mf_changed + 1))
  elif [ -z "$(roster_rows)" ]; then
    extract_section "$mf_tpl" "## Agent identity" | awk '/^\|/ && !/^\| Agent id/ && !/^\|---/' > "$mf_sec"
    mf_tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-roster.XXXXXX")"
    mf_ph=0
    if grep -qxF -- '| — | — | — | — | — |' "$mf_agents"; then mf_ph=1; fi
    awk -v rowsfile="$mf_sec" -v ph="$mf_ph" '
      BEGIN { while ((getline l < rowsfile) > 0) r[++n]=l }
      $0=="## Agent identity" { insec=1; print; next }
      insec && /^## / { insec=0 }
      insec && !done && $0=="| — | — | — | — | — |" { for (i=1;i<=n;i++) print r[i]; done=1; next }
      { print }
      insec && !done && !ph && /^\|-/ { for (i=1;i<=n;i++) print r[i]; done=1 }
    ' "$mf_agents" > "$mf_tmp"
    if cmp -s "$mf_agents" "$mf_tmp"; then
      rm -f "$mf_tmp"
    else
      mv "$mf_tmp" "$mf_agents"
      echo "+ added: default agent roster in AGENTS.md"
      mf_changed=$((mf_changed + 1))
    fi
  fi
  # The classic block tells agents to escalate to a human; in Factory mode the
  # autonomy policy replaces that. Add the pointer after the bullet, never edit it.
  mf_ptr='- In Factory mode the autonomy policy in `## Factory` replaces asking a human.'
  if ! tr -d '\r' < "$mf_agents" | grep -qxF -- "$mf_ptr"; then
    mf_tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-pointer.XXXXXX")"
    awk -v ptr="$mf_ptr" '
      { print }
      f && /record the outcome either way\./ { print ptr; f=0 }
      /^- Escalate to the human when a choice affects product behavior, cost,/ { f=1 }
    ' "$mf_agents" > "$mf_tmp"
    if cmp -s "$mf_agents" "$mf_tmp"; then
      rm -f "$mf_tmp"
    else
      mv "$mf_tmp" "$mf_agents"
      echo "+ added: Factory pointer in Technical and product decisions"
      mf_changed=$((mf_changed + 1))
    fi
  fi
  rm -f "$mf_sec"
  if [ ! -f "$DOCS_DIR/Brain.md" ]; then
    cp "$TEMPLATES_DIR/Brain.md" "$DOCS_DIR/Brain.md"
    echo "+ created: docs/Brain.md"
    mf_changed=$((mf_changed + 1))
  fi
  for mf_d in "$DOCS_DIR/specs" "$DOCS_DIR/brain/tasks"; do
    if [ ! -d "$mf_d" ]; then
      mkdir -p "$mf_d"
      echo "+ created: ${mf_d#"$PROJECT"/}/"
      mf_changed=$((mf_changed + 1))
    fi
  done
  factory_dispatch_setup
  mf_changed=$((mf_changed + FDS_CHANGED))
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
  awk -v keep="${1:-5}" '
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
      start = count - (keep - 1)
      if (start < 1) start = 1
      for (i = start; i <= count; i++) printf "%s", entry[i]
    }
  ' "$DOCS_DIR/Agentslog.md"
}

# ---------------------------------------------------------------------------
# Agentslog scanner: one pass, reused by claim/pause/done/status/context/
# check/rotate. Emits one TSV line per task id (order of first appearance):
#   task  status  agent  timestamp  pause_category  conflict  ever_done  name
#   holder  handoff  review
# status is the word of the LAST entry (IN_PROGRESS, PAUSE, REVIEW, DONE).
# holder is the agent of the last IN_PROGRESS entry (the developer who owns
# the task, also while it is in REVIEW), or the last entry agent if there is
# none. handoff is the destination named by the latest "- Handoff:" line of
# the current review cycle (reset by a new IN_PROGRESS). review is PASS or
# FAIL when the LAST entry carries a "- Review:" line, otherwise empty. New
# fields are only ever appended: callers use cut -fN and read with a
# unit-separator IFS, so earlier columns must never move.
# Effective stage: REVIEW unless review is FAIL, which means the task is back
# with its holder (IN_PROGRESS for them).
# ---------------------------------------------------------------------------
all_task_states() {
  [ -f "$DOCS_DIR/Agentslog.md" ] || return 0
  # fac is 1 only in Factory mode: the Factory lines of the ledger (Phase, Spec-pass,
  # Red, Tests, Attempts) are read and derived from only then (BR-008).
  ats_fac=0
  if factory_on; then ats_fac=1; fi
  awk -v stale_s="$((STALE_HOURS * 3600))" -v fac="$ats_fac" "$AWK_EPOCH"'
    $0 == "## Entries" { in_entries=1; next }
    in_entries && /^## \[/ {
      line=$0
      sub(/^## \[/,"",line)
      sub(/\] \| /,"|",line)
      gsub(/ \| /,"|",line)
      split(line,f,"|")
      ts=f[1]; agent=f[2]; tid=f[3]; status=f[4]; name=f[5]
      if (fac && status == "AUDIT") { audited[tid]=1; cur=""; next }
      if (!(tid in seen)) { seen[tid]=1; order[++cnt]=tid }
      if (status=="IN_PROGRESS") {
        if (last_status[tid]=="IN_PROGRESS" && last_agent[tid]!=agent) {
          conflict[tid] = last_agent[tid] " vs " agent
        } else if (last_status[tid]=="REVIEW" && hold[tid]!="" && hold[tid]!=agent && !is_old(last_ts[tid], ts)) {
          conflict[tid] = hold[tid] " vs " agent
        }
        hold[tid]=agent
        last_handoff[tid]=""
      }
      if (status=="ASSIGNED") last_handoff[tid]=""
      if (status=="DONE") { ever_done[tid]=1 }
      last_status[tid]=status; last_agent[tid]=agent; last_ts[tid]=ts; last_pause[tid]=""
      last_review[tid]=""
      pdetail[tid]=""
      if (name!="") last_name[tid]=name
      cur=tid
      next
    }
    in_entries && cur!="" && /^- Pause:/ {
      line=$0
      sub(/^- Pause: /,"",line)
      dash=index(line," - ")
      if (dash>0) p=substr(line,1,dash-1); else p=line
      last_pause[cur]=p
      if (fac && dash > 0) pdetail[cur]=substr(line, dash + 3)
      if (fac && p == "BLOQUEO") { att[cur]=0; struggled[cur]=1 }
      next
    }
    in_entries && cur!="" && /^- Assign:/ {
      line=$0
      sub(/^- Assign:[ \t]*/,"",line); gsub(/[ \t]+$/,"",line)
      if (last_status[cur]=="ASSIGNED" && line!="") { hold[cur]=line; last_handoff[cur]=line }
      next
    }
    in_entries && cur!="" && /^- Handoff:/ {
      line=$0
      sub(/^- Handoff:[ \t]*/,"",line); gsub(/[ \t]+$/,"",line)
      last_handoff[cur]=line
      next
    }
    in_entries && cur!="" && fac && /^- Red:/ {
      line=$0
      sub(/^- Red:[ \t]*/,"",line); gsub(/[ \t]+$/,"",line)
      red[cur]=line
      next
    }
    in_entries && cur!="" && fac && /^- Tests:/ {
      line=$0
      sub(/^- Tests:[ \t]*/,"",line); gsub(/[ \t]+$/,"",line)
      tests[cur]=line
      next
    }
    in_entries && cur!="" && fac && /^- Cross-model:/ {
      line=$0
      sub(/^- Cross-model:[ \t]*/,"",line); gsub(/[ \t]+$/,"",line)
      cross[cur]=line
      next
    }
    in_entries && cur!="" && fac && /^- Lane:/ {
      line=$0
      sub(/^- Lane:[ \t]*/,"",line); gsub(/[ \t]+$/,"",line)
      lane[cur]=line
      if (line != "FAST") base[cur]=""
      next
    }
    in_entries && cur!="" && fac && /^- Base:/ {
      line=$0
      sub(/^- Base:[ \t]*/,"",line); gsub(/[ \t]+$/,"",line)
      base[cur]=line
      next
    }
    in_entries && cur!="" && fac && /^- Struggled:/ {
      struggled[cur]=1
      next
    }
    in_entries && cur!="" && fac && /^- Attempts:/ {
      line=$0
      sub(/^- Attempts:[ \t]*/,"",line); gsub(/[ \t]+$/,"",line)
      att[cur]=line + 0
      next
    }
    in_entries && cur!="" && fac && /^- Spec-pass:/ {
      line=$0
      sub(/^- Spec-pass:[ \t]*/,"",line); gsub(/[ \t]+$/,"",line)
      spec_pass[cur]=line
      next
    }
    in_entries && cur!="" && fac && /^- Phase:/ {
      line=$0
      sub(/^- Phase:[ \t]*/,"",line); gsub(/[ \t]+$/,"",line)
      if (line == "SPEC" && last_phase[cur] != "" && last_phase[cur] != "SPEC") spec_pass[cur]=""
      if (line == "RED" && last_phase[cur] == "GREEN") { att[cur]++; struggled[cur]=1 }
      if (line == "RED" || line == "SPEC") { red[cur]=""; tests[cur]="" }
      last_phase[cur]=line
      next
    }
    in_entries && cur!="" && /^- Review:/ {
      line=$0
      sub(/^- Review:[ \t]*/,"",line)
      dash=index(line," - ")
      if (dash>0) p=substr(line,1,dash-1); else p=line
      gsub(/[ \t]+$/,"",p)
      last_review[cur]=p
      if (fac) cross[cur]=""
      ph=last_phase[cur]; if (ph == "") ph="SPEC"
      if (fac && ph == "SPEC") { if (p ~ /^PASS/) spec_pass[cur]=last_agent[cur]; else spec_pass[cur]="" }
      if (fac && p ~ /^FAIL/) { att[cur]++; struggled[cur]=1 }
      next
    }
    END {
      for (i=1;i<=cnt;i++) {
        t=order[i]
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", t, last_status[t], last_agent[t], last_ts[t], last_pause[t], conflict[t], (t in ever_done ? "1" : "0"), last_name[t], (t in hold ? hold[t] : last_agent[t]), last_handoff[t], last_review[t], last_phase[t], spec_pass[t], red[t], tests[t], att[t] + 0, struggled[t] + 0, lane[t], base[t], cross[t], audited[t] + 0, pdetail[t]
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

# ---------------------------------------------------------------------------
# Agent identity. The optional "## Agent identity" table in the project root
# AGENTS.md lists one stable id per agent plus aliases. With at least one data
# row, claim/pause/handoff/review/done normalise the agent name to its Agent id
# (case-insensitive match against id and aliases); an unknown name only warns
# and is used as typed. Without the section or rows nothing changes: no
# normalisation, no warnings.
# ---------------------------------------------------------------------------
# roster_rows: one TSV line per data row: id kind model role aliases.
roster_rows() {
  [ -f "$PROJECT/AGENTS.md" ] || return 0
  awk '
    $0 == "## Agent identity" { insec=1; next }
    insec && /^## / { insec=0 }
    insec && /^\|/ {
      line=$0
      sub(/^\|/,"",line); sub(/\|[ \t]*$/,"",line)
      n=split(line,c,"|")
      for (i=1;i<=n;i++) gsub(/^[ \t]+|[ \t]+$/,"",c[i])
      id=c[1]
      if (id=="" || id=="Agent id" || id=="—" || id ~ /^-+$/) next
      printf "%s\t%s\t%s\t%s\t%s\n", id, c[2], c[3], c[4], c[5]
    }
  ' "$PROJECT/AGENTS.md"
}

# role_norm ROLE: DEVELOPER is the legacy name of DEV (D-05).
role_norm() {
  if [ "$1" = "DEVELOPER" ]; then printf 'DEV'; else printf '%s' "$1"; fi
}

# phase_role PHASE: the roster role that works in a phase (D-05).
phase_role() {
  case "$1" in
    SPEC) printf 'SPEC' ;;
    RED) printf 'TEST' ;;
    GREEN) printf 'DEV' ;;
    REVIEW) printf 'QA' ;;
    *) printf '' ;;
  esac
}

# require_phase_role AGENT PHASE TASK [VERB]: Factory mode only. The agent must be
# in the roster with the role of the phase, or BOTH.
require_phase_role() {
  rp_verb="${4:-claim}"
  rp_role="$(roster_role "$1")"
  if [ -z "$rp_role" ]; then
    die "$rp_verb failed: $1 is not in the Agent identity table; Factory mode needs a role for each agent"
  fi
  rp_norm="$(role_norm "$rp_role")"
  rp_need="$(phase_role "$2")"
  if [ -z "$rp_need" ]; then
    die "$rp_verb failed: $3 is in phase $2, which has no role (use SPEC, RED, GREEN or REVIEW)"
  fi
  if [ "$rp_norm" != "BOTH" ] && [ "$rp_norm" != "$rp_need" ]; then
    die "$rp_verb failed: $1 has role $rp_role, but phase $2 of $3 needs $rp_need (or BOTH)"
  fi
}

canonical_agent() {
  raw="$1"
  roster="$(roster_rows)"
  if [ -z "$roster" ]; then printf '%s' "$raw"; return 0; fi
  found="$(printf '%s\n' "$roster" | awk -F'\t' -v want="$raw" '
    BEGIN { w=tolower(want) }
    {
      if (tolower($1)==w) { print $1; exit }
      n=split($5,a,",")
      for (i=1;i<=n;i++) {
        x=a[i]; gsub(/^[ \t]+|[ \t]+$/,"",x)
        if (x!="" && x!="—" && tolower(x)==w) { print $1; exit }
      }
    }
  ')"
  if [ -n "$found" ]; then
    printf '%s' "$found"
  else
    echo "WARN: unknown agent \"$raw\" (not in the Agent identity table)" >&2
    printf '%s' "$raw"
  fi
}

# roster_role ID: prints the Role (DEVELOPER, QA or BOTH) of a roster id.
roster_role() {
  roster_rows | awk -F'\t' -v id="$1" '$1==id { print $4; exit }'
}

# Timestamp of the first IN_PROGRESS entry of a task in the hot ledger.
first_claim_ts() {
  [ -f "$DOCS_DIR/Agentslog.md" ] || return 0
  awk -v want="$1" '
    $0=="## Entries" { in_e=1; next }
    in_e && /^## \[/ {
      line=$0
      sub(/^## \[/,"",line); sub(/\] \| /,"|",line); gsub(/ \| /,"|",line)
      split(line,f,"|")
      if (f[3]==want && f[4]=="IN_PROGRESS") { print f[1]; exit }
    }
  ' "$DOCS_DIR/Agentslog.md"
}

# gap_label SECONDS: "3s" under a minute, otherwise "2m".
gap_label() {
  if [ "$1" -lt 60 ]; then printf '%ss' "$1"; else printf '%sm' "$(( $1 / 60 ))"; fi
}

# ---------------------------------------------------------------------------
# Factory mode (F06, ADR-023). The optional "## Factory" section of the project
# AGENTS.md holds a "Setting | Value" table the scripts read. Without the
# section, or with Mode CLASSIC, nothing in this block changes any behavior
# (BR-008). PROJECT_DOCS_MODE=classic or factory overrides the file (tests).
# A missing row, or a value of just an em dash, takes its default (ADR-025).
# ---------------------------------------------------------------------------
factory_setting_names() {
  printf '%s\n' "Mode" "Require TDD" "Independent review" "WIP per agent" "Max fix attempts" \
    "Fast lane max files" "Fast lane max lines" "Fast lane protected paths" \
    "Preferred reviewer" "Fallback reviewer" "Recall budget bytes" "Brain max entries"
}

factory_default() {
  case "$1" in
    "Mode") printf 'FACTORY' ;;
    "Require TDD") printf 'YES' ;;
    "Independent review") printf 'YES' ;;
    "WIP per agent") printf '1' ;;
    "Max fix attempts") printf '3' ;;
    "Fast lane max files") printf '5' ;;
    "Fast lane max lines") printf '150' ;;
    "Fast lane protected paths") printf 'prisma/ migrations/ auth/ rls/ security/' ;;
    "Recall budget bytes") printf '4096' ;;
    "Brain max entries") printf '80' ;;
    *) printf '' ;;
  esac
}

# factory_section_exists: true when AGENTS.md has a "## Factory" heading.
factory_section_exists() {
  [ -f "$PROJECT/AGENTS.md" ] || return 1
  awk '{ sub(/\r$/, "") } $0=="## Factory" { f=1 } END { exit (f ? 0 : 1) }' "$PROJECT/AGENTS.md"
}

# factory_raw_value NAME: the trimmed value cell of the row, or empty.
factory_raw_value() {
  [ -f "$PROJECT/AGENTS.md" ] || return 0
  awk -v want="$1" '
    { sub(/\r$/, "") }
    $0=="## Factory" { insec=1; next }
    insec && /^## / { insec=0 }
    insec && /^\|/ {
      line=$0
      sub(/^\|/,"",line); sub(/\|[ \t]*$/,"",line)
      n=split(line,c,"|")
      for (i=1;i<=n;i++) gsub(/^[ \t]+|[ \t]+$/,"",c[i])
      if (c[1]==want) { v=c[2]; if (v=="—") v=""; print v; exit }
    }
  ' "$PROJECT/AGENTS.md"
}

# factory_setting NAME: the effective value (the row, else the default).
factory_setting() {
  fs_v="$(factory_raw_value "$1")"
  if [ -z "$fs_v" ]; then fs_v="$(factory_default "$1")"; fi
  printf '%s' "$fs_v"
}

# factory_number NAME: the setting as a positive integer of at most nine digits
# without leading zeros; anything else (text, zero, a huge number) is the default.
factory_number() {
  fn_v="$(factory_setting "$1")"
  case "$fn_v" in ''|*[!0-9]*) factory_default "$1"; return 0 ;; esac
  while [ "${fn_v#0}" != "$fn_v" ]; do fn_v="${fn_v#0}"; done
  if [ -z "$fn_v" ] || [ "${#fn_v}" -gt 9 ]; then factory_default "$1"; return 0; fi
  printf '%s' "$fn_v"
}

# factory_resolve_mode: sets FACTORY_MODE (FACTORY or CLASSIC) and
# FACTORY_MODE_SOURCE (env, AGENTS.md or default). An unknown Mode value is
# CLASSIC: the conservative reading (ADR-045).
factory_resolve_mode() {
  fm_env="$(printf '%s' "${PROJECT_DOCS_MODE:-}" | tr 'A-Z' 'a-z')"
  case "$fm_env" in
    factory) FACTORY_MODE=FACTORY; FACTORY_MODE_SOURCE=env; return 0 ;;
    classic) FACTORY_MODE=CLASSIC; FACTORY_MODE_SOURCE=env; return 0 ;;
  esac
  if factory_section_exists; then
    fm_v="$(factory_setting Mode | tr 'a-z' 'A-Z')"
    if [ "$fm_v" = "FACTORY" ]; then FACTORY_MODE=FACTORY; else FACTORY_MODE=CLASSIC; fi
    FACTORY_MODE_SOURCE="AGENTS.md"
  else
    FACTORY_MODE=CLASSIC; FACTORY_MODE_SOURCE=default
  fi
}

# factory_on: true in Factory mode (resolved once per process).
factory_on() {
  [ -n "${FACTORY_MODE:-}" ] || factory_resolve_mode
  [ "$FACTORY_MODE" = "FACTORY" ]
}

# mode: which mode applies, and in Factory mode the effective settings.
cmd_mode() {
  factory_resolve_mode
  echo "project_docs mode: $FACTORY_MODE ($FACTORY_MODE_SOURCE)"
  if [ "$FACTORY_MODE" = "FACTORY" ]; then
    factory_setting_names | while IFS= read -r fm_n; do
      if [ "$fm_n" = "Mode" ]; then fm_val="$FACTORY_MODE"; else fm_val="$(factory_setting "$fm_n")"; fi
      if [ -z "$fm_val" ]; then echo "$fm_n ="; else echo "$fm_n = $fm_val"; fi
    done
  fi
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

# Open tasks: last entry IN_PROGRESS, PAUSE or REVIEW (a REVIEW task stays open
# until DONE, including after a Review: FAIL, when it is back with its holder).
open_task_states() {
  all_task_states | awk -F'\t' '$2=="IN_PROGRESS" || $2=="PAUSE" || $2=="REVIEW" || $2=="ASSIGNED"'
}

# stage_label STATUS REVIEW HANDOFF: the stage text status and context print.
# REVIEW shows the handoff destination (ASCII "->", so sh and PowerShell print
# the same bytes); REVIEW(PASS) once a reviewer passed it; a Review: FAIL means
# the task is back with its holder, i.e. IN_PROGRESS.
stage_label() {
  if [ "$1" = "ASSIGNED" ]; then
    if [ -n "$3" ]; then printf 'ASSIGNED->%s' "$3"; else printf 'ASSIGNED'; fi
    return 0
  fi
  if [ "$1" != "REVIEW" ]; then printf '%s' "$1"; return 0; fi
  if [ "$2" = "FAIL" ]; then printf 'IN_PROGRESS'; return 0; fi
  label="REVIEW"
  if [ "$2" = "PASS" ]; then label="REVIEW(PASS)"; fi
  if [ -n "$3" ]; then label="$label->$3"; fi
  printf '%s' "$label"
}

open_tasks_line() {
  [ -f "$DOCS_DIR/Agentslog.md" ] || return 0
  open_task_states | tr '\t' '\037' |
  while IFS="$US" read -r tid status agent ts pausecat conflict everdone name holder handoff review phase specpass red tests attempts struggled lane base cross audited pdetail rest; do
    [ -n "$tid" ] || continue
    hrs="$(age_hours "$ts")"
    reason="-"
    if [ "$status" = "PAUSE" ]; then reason="$pausecat"; fi
    shown="$agent"
    if [ "$status" = "REVIEW" ]; then shown="$holder"; fi
    printf '%s | %s | %s | %sh | %s\n' "$tid" "$shown" "$(stage_label "$status" "$review" "$handoff")" "$hrs" "$reason"
  done
}

build_context() {
  [ -f "$PROJECT/AGENTS.md" ] || die "run init first"
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-context.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  bc_keep=5
  while :; do
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
      if [ "$bc_keep" -lt 5 ]; then
        echo "## Latest agent entries (the latest $bc_keep only, to stay within $CONTEXT_LIMIT bytes)"
      else
        echo "## Latest agent entries"
      fi
      latest_log_entries "$bc_keep"
    } > "$tmp"
    bytes="$(wc -c < "$tmp" | tr -d ' ')"
    [ "$bytes" -le "$CONTEXT_LIMIT" ] && break
    # In Factory mode older entries give way before the command fails, so an agent that
    # starts with context always gets it; the summaries above are what has to be compacted.
    if factory_on && [ "$bc_keep" -gt 1 ]; then bc_keep=$((bc_keep - 1)); continue; fi
    die "hot context is ${bytes} bytes; compact summaries below ${CONTEXT_LIMIT}"
  done
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

# ---------------------------------------------------------------------------
# Name/Description taxonomy. Every Roadmap table carries a short, descriptive
# "Name" cell (<= 10 words; the rest of the detail goes in "Description" or
# the table's own free-text column) in the column right after ID. claim/
# pause/done refuse a task whose Name is missing or too long instead of
# silently copying it into the log; check sweeps every table the same way.
# ---------------------------------------------------------------------------
word_count() {
  printf '%s' "$1" | awk '{ n=split($0,w,/[ \t]+/); for(i=1;i<=n;i++) if (w[i]!="") c++ } END { print c+0 }'
}

# Returns the trimmed cell under the column named $2 ("Name") of the row
# whose ID (column 1 after the leading empty split field) equals $1,
# wherever that row lives in docs/Roadmap.md. Header-detected per table (the
# first `|` row after a non-`|` line), same convention as
# check_table_status_enum, so it works regardless of table shape or how many
# columns precede/follow Name.
roadmap_row_field() {
  id="$1"; colname="$2"
  awk -F'|' -v id="$id" -v colname="$colname" '
    !/^\|/ { expect_header=1; next }
    /^\|/ {
      line=$0
      sub(/^\|/,"",line); sub(/\|[ \t]*$/,"",line)
      ncol=split(line,c,"|")
      for (i=1;i<=ncol;i++) gsub(/^[ \t]+|[ \t]+$/,"",c[i])
      if (expect_header) {
        col=0
        for (i=1;i<=ncol;i++) if (c[i]==colname) col=i
        expect_header=0
        next
      }
      if (c[1]==id && col>0 && col<=ncol) { print c[col]; exit }
    }
  ' "$DOCS_DIR/Roadmap.md"
}

# Emits one "ID<TAB>Name" line per row, file-wide, for every table that has a
# Name column (same header detection as roadmap_row_field). Used to cross-
# check Agentslog entries against the Roadmap's current Name for each ID.
roadmap_all_names() {
  awk -F'|' '
    !/^\|/ { expect_header=1; next }
    /^\|/ {
      line=$0
      sub(/^\|/,"",line); sub(/\|[ \t]*$/,"",line)
      ncol=split(line,c,"|")
      for (i=1;i<=ncol;i++) gsub(/^[ \t]+|[ \t]+$/,"",c[i])
      if (expect_header) {
        namecol=0
        for (i=1;i<=ncol;i++) if (c[i]=="Name") namecol=i
        expect_header=0
        next
      }
      id=c[1]
      if (id=="" || id=="—" || id ~ /^-+$/) next
      if (namecol>0 && namecol<=ncol) printf "%s\t%s\n", id, c[namecol]
    }
  ' "$DOCS_DIR/Roadmap.md"
}

# dies if the Roadmap row for $1 has no usable Name: missing, empty, or over
# the 10-word limit. Called by claim/pause/done before they touch the log, so
# a bad Name blocks the action instead of propagating into Agentslog.
require_valid_name() {
  task="$1"; action="${2:-claim}"
  name="$(roadmap_row_field "$task" Name)"
  [ -n "$name" ] || die "$action failed: $task has no Name cell in docs/Roadmap.md (missing row, or the table predates the Name column; run migrate)"
  wc="$(word_count "$name")"
  if [ "$wc" -gt 10 ]; then
    die "$action failed: $task Name is $wc words, over the 10-word limit: \"$name\" — shorten it and move the rest into Description"
  fi
  printf '%s' "$name"
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
      # A lock released between the test and the stat leaves no age (or the filesystem report
      # of stat -f): ask again instead of reading it as an old lock and taking a fresh one.
      case "$lock_epoch" in
        ''|*[!0-9]*|0)
          if [ "$attempts" -ge 50 ]; then die "could not acquire docs/.lock (busy); retry"; fi
          sleep 0.1 2>/dev/null || sleep 1
          continue ;;
      esac
      now_epoch="$(date -u +%s)"
      if [ $((now_epoch - lock_epoch)) -ge 30 ]; then
        # An old lock is taken over by one waiter at a time, who reads its age again inside the
        # takeover: two waiters that saw the same old lock could otherwise both remove it, and the
        # second would remove the new lock of the first.
        if mkdir "$lockdir.takeover" 2>/dev/null; then
          lock_epoch2="$(stat -c %Y "$lockdir" 2>/dev/null || stat -f %m "$lockdir" 2>/dev/null || echo 0)"
          case "$lock_epoch2" in ''|*[!0-9]*) lock_epoch2=0 ;; esac
          if [ "$lock_epoch2" -gt 0 ] && [ $(( $(date -u +%s) - lock_epoch2 )) -ge 30 ]; then
            rmdir "$lockdir" 2>/dev/null || true
          fi
          rmdir "$lockdir.takeover" 2>/dev/null || true
        elif [ -d "$lockdir.takeover" ]; then
          # a takeover that died leaves its marker: it counts as old too
          take_epoch="$(stat -c %Y "$lockdir.takeover" 2>/dev/null || stat -f %m "$lockdir.takeover" 2>/dev/null || echo 0)"
          case "$take_epoch" in ''|*[!0-9]*) take_epoch=0 ;; esac
          if [ "$take_epoch" -gt 0 ] && [ $(( $(date -u +%s) - take_epoch )) -ge 30 ]; then rmdir "$lockdir.takeover" 2>/dev/null || true; fi
        fi
        if [ "$attempts" -ge 50 ]; then die "could not acquire docs/.lock (busy); retry"; fi
        sleep 0.1 2>/dev/null || sleep 1
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
  agent="$(canonical_agent "$(clean_arg "$1")")"
  task="$(clean_arg "$2")"
  summary="$(clean_arg "$3")"
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
    elif [ "$status" = "REVIEW" ]; then
      # During REVIEW the developer is still the holder: they may take it back
      # (after a FAIL, or to withdraw the handoff); anyone else only once the
      # last entry is stale.
      holder="$(printf '%s' "$state" | cut -f9)"
      if [ -n "$holder" ] && [ "$holder" != "$agent" ] && ! is_stale "$task"; then
        die "claim failed: $task is in REVIEW, held by $holder"
      fi
    elif [ "$status" = "ASSIGNED" ]; then
      # An assignment is a request, not a lock: another agent may still take
      # the task, but is told it was assigned to someone else.
      holder="$(printf '%s' "$state" | cut -f9)"
      if [ -n "$holder" ] && [ "$holder" != "$agent" ] && ! factory_on; then
        echo "WARN: $task is assigned to $holder, not $agent" >&2
      fi
    fi
  fi
  claim_phase=""
  if factory_on; then
    claim_phase="$(printf '%s' "${state:-}" | cut -f12)"
    [ -n "$claim_phase" ] || claim_phase="SPEC"
    claim_prev_lane="$(printf '%s' "${state:-}" | cut -f18)"
    claim_lane="NORMAL"
    case "$(roadmap_row_field "$task" Description)" in *"Lane: FAST"*) claim_lane="FAST" ;; esac
    claim_base=""
    if [ "$claim_lane" = "FAST" ]; then
      if [ "$claim_prev_lane" != "FAST" ] && [ -n "$(printf '%s' "${state:-}" | cut -f12)" ] && [ "$claim_phase" != "SPEC" ]; then
        die "claim failed: $task already went through the normal lane (phase $claim_phase); take Lane: FAST out of its row"
      fi
      claim_phase="GREEN"
      if [ "$claim_prev_lane" = "FAST" ]; then claim_base="$(printf '%s' "${state:-}" | cut -f19)"; fi
      if [ -z "$claim_base" ] && git_ready; then claim_base="$(git -C "$PROJECT" rev-parse HEAD 2>/dev/null)" || claim_base=""; fi
    elif [ "$claim_prev_lane" = "FAST" ]; then
      claim_phase="SPEC"
    fi
    require_phase_role "$agent" "$claim_phase" "$task"
    claim_att="$(printf '%s' "${state:-}" | cut -f16)"
    claim_max="$(factory_number "Max fix attempts")"
    if [ "${claim_att:-0}" -ge "$claim_max" ]; then
      die "claim failed: $task used $claim_att of $claim_max fix attempts; pause it with BLOQUEO and write the lesson, or raise Max fix attempts"
    fi
    claim_wip="$(factory_number "WIP per agent")"
    claim_busy="$(all_task_states | awk -F'\t' -v a="$agent" -v t="$task" '$2 == "IN_PROGRESS" && $3 == a && $1 != t { n++; ids = (ids == "" ? $1 : ids ", " $1) } END { if (n > 0) printf "%d %s", n, ids }')"
    if [ -n "$claim_busy" ] && [ "${claim_busy%% *}" -ge "$claim_wip" ]; then
      die "claim failed: $agent already has ${claim_busy%% *} task(s) in progress (WIP per agent is $claim_wip): ${claim_busy#* }"
    fi
  fi
  name="$(require_valid_name "$task")"
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  {
    echo
    echo "## [$timestamp] | $agent | $task | IN_PROGRESS | $name"
    echo "- Summary: $summary"
    echo "- Verify: pending"
    if factory_on; then
      echo "- Phase: $claim_phase"
      echo "- Lane: $claim_lane"
      if [ -n "$claim_base" ]; then echo "- Base: $claim_base"; fi
    fi
  } >> "$DOCS_DIR/Agentslog.md"
  roadmap_claim_row "$task" "$agent" "$timestamp"
  echo "project_docs claim: $task claimed by $agent"
}

# clean_field_text VALUE: the free text of a Factory command (step, lesson, ...):
# a run of CR/LF becomes one space, a bar becomes a slash, the ends are trimmed.
# This is what the PowerShell launcher does; clean_field (classic) differs, and
# stays as it is (BR-008).
# clean_stream: stdin to stdout without carriage returns and without a leading
# UTF-8 byte order mark, which is how the PowerShell launcher reads a file.
clean_stream() {
  tr -d '\r' | awk -v bom="$(printf '\357\273\277')" 'NR == 1 && index($0, bom) == 1 { $0 = substr($0, length(bom) + 1) } { print }'
}

clean_field_text() {
  printf '%s' "$1" | tr '\r\n' '\001\001' | awk '{ gsub(/\001+/, " "); gsub(/\|/, "/"); gsub(/^[ \t]+|[ \t]+$/, ""); print }'
}

# clean_arg VALUE: an argument of claim, pause, handoff, review, assign and done:
# the classic cleaner in classic mode, the one the PowerShell launcher uses in
# Factory mode, so both launchers write the same bytes.
clean_arg() {
  if factory_on; then clean_field_text "$1"; else clean_field "$1"; fi
}

# require_exit_zero VERB VERIFY: Factory mode. The verify must carry exit=0.
require_exit_zero() {
  rz_n="$(verify_exit "$2")"
  [ -n "$rz_n" ] || die "$1 failed: the verify needs exit=N (exit=0 when the checks pass)"
  exit_is_zero "$rz_n" || die "$1 failed: the verify says exit=$rz_n, not exit=0"
}

# require_tests_unchanged TASK STATE: handoff in GREEN. The test files recorded at
# RED (the Tests line) must be as they were at the Red sha; without git it only warns.
require_tests_unchanged() {
  rt_tests="$(printf '%s' "$2" | cut -f15)"
  [ -n "$rt_tests" ] || return 0
  rt_red="$(printf '%s' "$2" | cut -f14)"
  if [ -n "$rt_red" ] && git_ready; then
    git -C "$PROJECT" cat-file -e "$rt_red^{commit}" 2>/dev/null || die "handoff failed: the Red sha $rt_red is not in this repository"
    rt_diff="$(git -C "$PROJECT" -c core.quotepath=false diff --no-renames --relative --name-only "$rt_red" 2>/dev/null)" || die "handoff failed: git could not compare the files with the Red sha $rt_red"
    rt_list="$(mktemp "${TMPDIR:-/tmp}/project-docs-tests.XXXXXX")"
    printf '%s\n' "$rt_tests" | tr ' ' '\n' > "$rt_list"
    rt_changed="$(printf '%s\n' "$rt_diff" | awk -v tf="$rt_list" 'BEGIN { while ((getline p < tf) > 0) if (p != "") want[p] = 1 } ($0 in want) { printf "%s%s", sep, $0; sep = " " }')"
    rm -f "$rt_list"
    [ -z "$rt_changed" ] || die "handoff failed: test file(s) changed since RED ($rt_red): $rt_changed; a wrong test goes back to SPEC with advance"
  else
    echo "WARN: git is not available here, so the tests cannot be checked as unchanged since RED; the reviewer must write 'tests unchanged' in the review note" >&2
  fi
}

# require_tests_note TASK STATE NOTE: review PASS of a GREEN handoff whose tests git
# could not check needs the words "tests unchanged" in the note.
require_tests_note() {
  rn_tests="$(printf '%s' "$2" | cut -f15)"
  [ -n "$rn_tests" ] || return 0
  [ "$(printf '%s' "$2" | cut -f12)" = "GREEN" ] || return 0
  if [ -n "$(printf '%s' "$2" | cut -f14)" ] && git_ready; then return 0; fi
  printf '%s' "$3" | tr 'A-Z' 'a-z' | grep -q 'tests unchanged' || die "review failed: git could not check the tests of $1; the note must say 'tests unchanged'"
}

# ---------------------------------------------------------------------------
# The brain: docs/Brain.md rows read by recall, written by learn and retro, archived by
# rotate (F06-E03-T03 to T05). Only Factory mode.
# ---------------------------------------------------------------------------
# brain_rows_tsv: one line per well-formed row of the Entries table: the nine cells and
# then the row as written, separated by tabs.
brain_rows_tsv() {
  [ -f "$DOCS_DIR/Brain.md" ] || return 0
  clean_stream < "$DOCS_DIR/Brain.md" | tr '\t' ' ' | awk '
    $0 == "## Entries" { insec=1; next }
    insec && /^## / { insec=0 }
    insec && /^\|/ {
      line=$0; sub(/^\|/, "", line); sub(/\|[ \t]*$/, "", line)
      n=split(line, c, "|")
      for (i=1; i<=n; i++) gsub(/^[ \t]+|[ \t]+$/, "", c[i])
      if (c[1] == "ID" || c[1] ~ /^-+$/ || c[1] == "—" || n != 9) next
      orig=$0; gsub(/[ \t]+$/, "", orig)
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], orig
    }
  '
}

# brain_next_id: the next LRN id; ids of archived rows count, so an id is never reused.
brain_next_id() {
  bn_max="$( { cat "$DOCS_DIR/Brain.md" 2>/dev/null; cat "$DOCS_DIR"/history/brain-archive-*.md 2>/dev/null; } | tr -d '\r' | awk '
    /^\| LRN-[0-9]+ / { id=$2; sub(/^LRN-/, "", id); if (id + 0 > m) m = id + 0 }
    END { print m + 0 }
  ')"
  printf 'LRN-%03d' "$((bn_max + 1))"
}

# recall_words TEXT: the lower case ASCII words of four or more letters, one per line.
recall_words() {
  printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -c 'a-z' '\n' | LC_ALL=C awk 'length($0) >= 4'
}

# recall <project> <task-id>: what to read before working on a task, within the recall
# budget: the Roadmap row, the spec summary, the working memory and the brain rows
# whose Trigger matches the task, best first, whole rows only.
cmd_recall() {
  shift 2
  require_factory recall
  [ "$#" -ge 1 ] || die "recall requires: task-id"
  rc_task="$(clean_field_text "$1")"
  [ -f "$DOCS_DIR/Agentslog.md" ] || die "run init first"
  roadmap_has_id "$rc_task" || die "recall failed: $rc_task not found in docs/Roadmap.md"
  rc_budget="$(factory_number "Recall budget bytes")"
  rc_name="$(roadmap_row_field "$rc_task" Name)"
  rc_desc="$(roadmap_row_field "$rc_task" Description)"
  rc_acc="$(roadmap_row_field "$rc_task" "Acceptance check")"
  rc_status="$(roadmap_row_field "$rc_task" Status)"
  rc_owner="$(roadmap_row_field "$rc_task" Owner)"
  rc_deps="$(roadmap_row_field "$rc_task" "Depends on")"
  rc_spec="$DOCS_DIR/specs/$rc_task.md"
  rc_wm="$(working_memory_path "$rc_task")"
  rc_fixed="$(mktemp "${TMPDIR:-/tmp}/project-docs-recall.XXXXXX")"
  {
    echo "## Task"
    echo "- ID: $rc_task"
    echo "- Name: $rc_name"
    echo "- Description: ${rc_desc:-—}"
    if [ -n "$rc_acc" ]; then echo "- Acceptance check: $rc_acc"; fi
    echo "- Status: ${rc_status:-—}; Owner: ${rc_owner:-—}; Depends on: ${rc_deps:-—}"
    echo "## Spec summary"
    if [ -f "$rc_spec" ]; then
      clean_stream < "$rc_spec" | awk '
        /^## / { insec = ($0 == "## Summary"); next }
        insec && $0 != "<!-- context:end -->" && $0 != "" { print }
      '
    else
      echo "(no spec yet)"
    fi
    echo "## Now"
    if [ -f "$rc_wm" ] && has_working_now "$rc_task"; then
      clean_stream < "$rc_wm" | awk '
        /^## / { insec = ($0 == "## Now"); next }
        insec && $0 != "" { print }
      '
    else
      echo "(no working memory yet)"
    fi
    echo "## Brain"
  } > "$rc_fixed"
  rc_tags=""
  if [ -f "$rc_spec" ]; then
    rc_tags="$(clean_stream < "$rc_spec" | awk '/^- Tags:/ { sub(/^- Tags:[ \t]*/, ""); print; exit }')"
  fi
  rc_tokens="$( { recall_words "$rc_name $rc_desc $rc_deps"; printf '%s' "$rc_tags" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -s ' \t' '\n\n'; } | LC_ALL=C awk 'NF { print }' | LC_ALL=C sort -u | tr '\n' ' ')"
  rc_rows="$(brain_rows_tsv)"
  rc_total="$(printf '%s\n' "$rc_rows" | awk 'length($0) > 0 { n++ } END { print n + 0 }')"
  rc_used="$(LC_ALL=C wc -c < "$rc_fixed" | tr -d ' ')"
  rc_min=$(( rc_used + $(printf 'recall: 0 of %s brain entries shown\n' "$rc_total" | LC_ALL=C wc -c | tr -d ' ') ))
  if [ "$rc_min" -gt "$rc_budget" ]; then
    rm -f "$rc_fixed"
    die "recall failed: the task, the spec summary and the working memory take $rc_min bytes, over the Recall budget bytes of $rc_budget; shorten the spec Summary or the working memory"
  fi
  cat "$rc_fixed"
  rm -f "$rc_fixed"
  printf '%s\n' "$rc_rows" | LC_ALL=C awk -F'\t' -v tokens="$rc_tokens" -v used="$rc_used" -v budget="$rc_budget" -v total="$rc_total" '
    BEGIN { ntok = split(tokens, tk, " "); for (i = 1; i <= ntok; i++) has[tk[i]] = 1 }
    NF == 0 { next }
    {
      trig=tolower($4); score=0
      if (trig == "*") score = 1
      else {
        m = split(trig, tt, " "); split("", seen)
        for (j = 1; j <= m; j++) {
          t = tt[j]
          if (t == "" || (t in seen)) continue
          seen[t] = 1; hit = 0
          if (index(t, "/") > 0) { for (x in has) if (index(x, t) == 1) { hit = 1; break } }
          else if (t in has) hit = 1
          if (hit) score++
        }
      }
      if (score >= 1) { n++; S[n] = score; H[n] = $8 + 0; I[n] = $1; L[n] = $10 }
    }
    END {
      for (a = 2; a <= n; a++) {
        s = S[a]; h = H[a]; id2 = I[a]; l = L[a]; b = a - 1
        while (b >= 1 && (S[b] < s || (S[b] == s && (H[b] < h || (H[b] == h && I[b] > id2))))) { S[b+1] = S[b]; H[b+1] = H[b]; I[b+1] = I[b]; L[b+1] = L[b]; b-- }
        S[b+1] = s; H[b+1] = h; I[b+1] = id2; L[b+1] = l
      }
      bytes = used; k = 0
      for (a = 1; a <= n; a++) {
        final = "recall: " a " of " total " brain entries shown"
        if (bytes + length(L[a]) + 1 + length(final) + 1 > budget) break
        bytes += length(L[a]) + 1; k = a
      }
      for (a = 1; a <= k; a++) print L[a]
      print "recall: " k " of " total " brain entries shown"
    }
  '
}

# learn <project> <agent> <task-id> <kind> <name> <trigger> <lesson>: adds a lesson to the brain.
cmd_learn() {
  shift 2
  require_factory learn
  [ "$#" -ge 6 ] || die "learn requires: agent task-id kind name trigger lesson"
  for ln_a in "$@"; do
    case "$ln_a" in *'|'*) die "learn failed: no argument may contain a vertical bar" ;; esac
  done
  ln_agent="$(canonical_agent "$(clean_field_text "$1")")"
  ln_task="$(clean_field_text "$2")"
  ln_kind="$(clean_field_text "$3")"
  ln_name="$(clean_field_text "$(printf '%s' "$4" | tr '\t' ' ')")"
  ln_trigger="$(clean_field_text "$(printf '%s' "$5" | tr '\t' ' ')" | LC_ALL=C tr 'A-Z' 'a-z')"
  ln_lesson="$(clean_field_text "$(printf '%s' "$6" | tr '\t' ' ')")"
  case "$ln_kind" in
    PITFALL|PATTERN|RECIPE|DEFAULT|MAP) ;;
    *) die "learn failed: kind must be PITFALL, PATTERN, RECIPE, DEFAULT or MAP" ;;
  esac
  [ -n "$ln_name" ] || die "learn failed: the name is empty"
  ln_words="$(word_count "$ln_name")"
  [ "$ln_words" -le 10 ] || die "learn failed: the name is $ln_words words, over the 10-word limit"
  [ -n "$ln_trigger" ] || die "learn failed: the trigger is empty"
  [ -n "$ln_lesson" ] || die "learn failed: the lesson is empty"
  if [ "$ln_trigger" = "*" ] && [ "$ln_kind" != "DEFAULT" ]; then
    die "learn failed: the trigger * is only for DEFAULT lessons"
  fi
  [ -f "$DOCS_DIR/Agentslog.md" ] || die "run init first"
  [ -f "$DOCS_DIR/Brain.md" ] || die "learn failed: docs/Brain.md does not exist (run migrate --factory)"
  if ! roadmap_has_id "$ln_task" && ! task_state "$ln_task" >/dev/null 2>&1; then
    die "learn failed: $ln_task is not a task of this project"
  fi
  with_lock
  ln_rows="$(brain_rows_tsv)"
  ln_count="$(printf '%s\n' "$ln_rows" | awk 'length($0) > 0 { n++ } END { print n + 0 }')"
  ln_max="$(factory_number "Brain max entries")"
  ln_dup="$(printf '%s\n' "$ln_rows" | LC_ALL=C awk -F'\t' -v want="$(printf '%s' "$ln_name" | LC_ALL=C tr 'A-Z' 'a-z')" 'tolower($2) == want { print $1; exit }')"
  [ -z "$ln_dup" ] || die "learn failed: $ln_dup already has the name \"$ln_name\""
  if [ "$ln_count" -ge "$ln_max" ]; then
    die "learn failed: the brain already has $ln_count entries (Brain max entries is $ln_max); run rotate to archive the least used"
  fi
  ln_id="$(brain_next_id)"
  ln_row="| $ln_id | $ln_name | $ln_kind | $ln_trigger | $ln_lesson | log:$ln_task | HYPOTHESIS | 0 | — |"
  ln_tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-brain.XXXXXX")"
  clean_stream < "$DOCS_DIR/Brain.md" | LRN_ROW="$ln_row" awk -v n="$((ln_count + 1))" -v max="$ln_max" '
    { lines[NR] = $0 }
    END {
      insec = 0; last = 0
      for (i = 1; i <= NR; i++) {
        if (lines[i] == "## Entries") insec = 1
        else if (insec && lines[i] ~ /^## /) insec = 0
        if (insec && lines[i] ~ /^\|/) last = i
      }
      for (i = 1; i <= NR; i++) {
        l = lines[i]
        if (l ~ /^- Entries: /) l = "- Entries: " n " of " max
        print l
        if (i == last) print ENVIRON["LRN_ROW"]
      }
    }
  ' > "$ln_tmp"
  mv "$ln_tmp" "$DOCS_DIR/Brain.md"
  echo "project_docs learn: $ln_id added"
}

# brain_ids LIST: validates a list of lesson ids (or the word none) and prints it
# sorted and without repeats, as "LRN-001, LRN-003" or "none".
brain_ids() {
  bi_in="$(printf '%s' "$1" | tr ',' ' ')"
  if [ "$bi_in" = "none" ] || [ -z "$(printf '%s' "$bi_in" | tr -d ' ')" ]; then printf 'none'; return 0; fi
  bi_out=""
  for bi_t in $bi_in; do
    printf '%s' "$bi_t" | grep -Eq '^LRN-[0-9]{3,}$' || die "retro failed: \"$bi_t\" is not a lesson id like LRN-001 or the word none"
    bi_out="$bi_out$bi_t
"
  done
  printf '%s' "$bi_out" | LC_ALL=C sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g'
}

# retro <project> <agent> <task-id> <used-ids|none> <learned-ids|none>: records which lessons
# the task used and which it left behind in the ## Retro of its working memory.
cmd_retro() {
  shift 2
  require_factory retro
  [ "$#" -ge 4 ] || die "retro requires: agent task-id used-ids|none learned-ids|none"
  rt_agent="$(canonical_agent "$(clean_field_text "$1")")"
  rt_task="$(clean_field_text "$2")"
  [ -f "$DOCS_DIR/Agentslog.md" ] || die "run init first"
  if ! roadmap_has_id "$rt_task" && ! task_state "$rt_task" >/dev/null 2>&1; then
    die "retro failed: $rt_task is not a task of this project"
  fi
  has_working_now "$rt_task" || die "retro failed: $rt_task has no working memory yet (## Now); run checkpoint first"
  rt_used="$(brain_ids "$(clean_field_text "$3")")"
  rt_learned="$(brain_ids "$(clean_field_text "$4")")"
  rt_rows="$(brain_rows_tsv)"
  if [ "$rt_used" != "none" ]; then
    for rt_id in $(printf '%s' "$rt_used" | tr -d ','); do
      printf '%s\n' "$rt_rows" | awk -F'\t' -v id="$rt_id" '$1 == id { f = 1 } END { exit f ? 0 : 1 }' || die "retro failed: $rt_id is not in docs/Brain.md"
    done
  fi
  if [ "$rt_learned" != "none" ]; then
    for rt_id in $(printf '%s' "$rt_learned" | tr -d ','); do
      rt_ev="$(printf '%s\n' "$rt_rows" | awk -F'\t' -v id="$rt_id" '$1 == id { print $6; f = 1 } END { exit f ? 0 : 1 }')" || die "retro failed: $rt_id is not in docs/Brain.md"
      [ "$rt_ev" = "log:$rt_task" ] || die "retro failed: $rt_id was not learned for $rt_task (its Evidence is $rt_ev)"
    done
  fi
  if [ "$rt_learned" = "none" ]; then
    rt_struggled="$(task_state "$rt_task" 2>/dev/null | cut -f17)" || true
    if [ "${rt_struggled:-0}" = "1" ]; then
      die "retro failed: $rt_task had a Review: FAIL, a BLOQUEO or a move back to RED; record what was learned with learn first"
    fi
  fi
  with_lock
  rt_wm="$(working_memory_path "$rt_task")"
  rt_tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-retro.XXXXXX")"
  clean_stream < "$rt_wm" | RT_USED="$rt_used" RT_LEARNED="$rt_learned" awk '
    function emit() { if (!done) { print "- Used: " ENVIRON["RT_USED"]; print "- Learned: " ENVIRON["RT_LEARNED"]; done = 1 } }
    /^## / { if (inretro) emit(); inretro = ($0 == "## Retro"); if (inretro) seen = 1; print; if (inretro) emit(); next }
    inretro && (/^- Used:/ || /^- Learned:/) { next }
    { print }
    END { if (!seen) exit 3 }
  ' > "$rt_tmp" || { rm -f "$rt_tmp"; die "retro failed: docs/brain/tasks/$rt_task.md has no ## Retro section"; }
  mv "$rt_tmp" "$rt_wm"
  echo "project_docs retro: $rt_task recorded (used: $rt_used; learned: $rt_learned)"
}

# retro_read TASK: sets DONE_USED and DONE_LEARNED from the ## Retro of the working memory;
# dies when no retro was recorded (done in Factory mode needs it).
retro_read() {
  rr_wm="$(working_memory_path "$1")"
  DONE_USED=""
  DONE_LEARNED=""
  if [ -f "$rr_wm" ]; then
    DONE_USED="$(clean_stream < "$rr_wm" | awk '/^## / { insec = ($0 == "## Retro"); next } insec && /^- Used:/ { sub(/^- Used:[ \t]*/, ""); print; exit }')"
    DONE_LEARNED="$(clean_stream < "$rr_wm" | awk '/^## / { insec = ($0 == "## Retro"); next } insec && /^- Learned:/ { sub(/^- Learned:[ \t]*/, ""); print; exit }')"
  fi
  if [ -z "$DONE_USED" ] || [ "$DONE_USED" = "—" ] || [ -z "$DONE_LEARNED" ] || [ "$DONE_LEARNED" = "—" ]; then
    die "done failed: $1 has no retro yet; run retro first"
  fi
  if [ "$DONE_LEARNED" = "none" ]; then
    rr_s="$(task_state "$1" 2>/dev/null | cut -f17)" || true
    if [ "${rr_s:-0}" = "1" ]; then
      die "done failed: $1 had a Review: FAIL, a BLOQUEO or a move back to RED, so its retro cannot say learned none; run learn and retro again"
    fi
  fi
}

# brain_apply_hits IDS DATE: adds one hit and the date to every listed lesson (done in Factory mode).
brain_apply_hits() {
  [ "$1" != "none" ] || return 0
  [ -f "$DOCS_DIR/Brain.md" ] || return 0
  ah_tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-hits.XXXXXX")"
  clean_stream < "$DOCS_DIR/Brain.md" | AH_IDS="$1" awk -v day="$2" '
    BEGIN { n = split(ENVIRON["AH_IDS"], a, /, */); for (i = 1; i <= n; i++) want[a[i]] = 1 }
    $0 == "## Entries" { insec = 1 }
    insec && /^## / && $0 != "## Entries" { insec = 0 }
    insec && /^\|/ {
      line = $0; sub(/^\|/, "", line); sub(/\|[ \t]*$/, "", line)
      cn = split(line, c, "|")
      for (i = 1; i <= cn; i++) gsub(/^[ \t]+|[ \t]+$/, "", c[i])
      if (cn == 9 && (c[1] in want)) {
        c[8] = c[8] + 1; c[9] = day
        printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9]
        next
      }
    }
    { print }
  ' > "$ah_tmp"
  mv "$ah_tmp" "$DOCS_DIR/Brain.md"
}

# brain_gc: rotate in Factory mode. When the brain has more rows than Brain max entries,
# archives the least used rows (fewest hits, then oldest last use, then lowest id; never a
# DEFAULT with the trigger *) to docs/history until 75 percent of the maximum is left.
# Returns 0 and prints a line when it archived rows, 1 when there was nothing to do.
brain_gc() {
  factory_on || return 1
  [ -f "$DOCS_DIR/Brain.md" ] || return 1
  with_lock
  bg_max="$(factory_number "Brain max entries")"
  bg_rows="$(brain_rows_tsv)"
  bg_count="$(printf '%s\n' "$bg_rows" | awk 'length($0) > 0 { n++ } END { print n + 0 }')"
  [ "$bg_count" -gt "$bg_max" ] || return 1
  bg_target=$(( bg_max * 75 / 100 ))
  bg_drop=$(( bg_count - bg_target ))
  bg_ids="$(printf '%s\n' "$bg_rows" | awk -F'\t' '
    $3 == "DEFAULT" && $4 == "*" { next }
    NF == 0 { next }
    { d = $9; if (d == "—") d = "0000-00-00"; printf "%09d\t%s\t%s\n", $8, d, $1 }
  ' | LC_ALL=C sort | head -n "$bg_drop" | awk -F'\t' '{ print $3 }')"
  [ -n "$bg_ids" ] || return 1
  bg_stamp="$(date -u +'%Y%m%d')"
  bg_day="$(date -u +'%Y-%m-%d')"
  mkdir -p "$HISTORY_DIR"
  bg_seq=1
  while :; do
    bg_name="brain-archive-$bg_stamp-$(printf '%03d' "$bg_seq").md"
    [ ! -e "$HISTORY_DIR/$bg_name" ] && break
    bg_seq=$((bg_seq + 1))
  done
  bg_src="$(mktemp "${TMPDIR:-/tmp}/project-docs-brainarchive.XXXXXX")"
  {
    echo "# Brain archive $bg_day"
    echo
    echo "Rows archived from docs/Brain.md by rotate on $bg_day. Their ids are never reused."
    echo
    echo "| ID | Name | Kind | Trigger | Lesson | Evidence | Status | Hits | Last used |"
    echo "|---|---|---|---|---|---|---|---|---|"
    printf '%s\n' "$bg_rows" | BG_IDS="$bg_ids" awk -F'\t' 'BEGIN { n = split(ENVIRON["BG_IDS"], a, "\n"); for (i = 1; i <= n; i++) want[a[i]] = 1 } ($1 in want) { print $10 }'
  } > "$bg_src"
  cp "$bg_src" "$HISTORY_DIR/$bg_name"
  bg_h1="$(file_hash "$bg_src")"
  bg_h2="$(file_hash "$HISTORY_DIR/$bg_name")"
  rm -f "$bg_src"
  [ "$bg_h1" = "$bg_h2" ] || die "brain archive hash verification failed"
  bg_n="$(printf '%s\n' "$bg_ids" | awk 'length($0) > 0 { n++ } END { print n + 0 }')"
  bg_tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-brain.XXXXXX")"
  clean_stream < "$DOCS_DIR/Brain.md" | BG_IDS="$bg_ids" awk -v left="$((bg_count - bg_n))" -v max="$bg_max" -v day="$bg_day" -v name="$bg_name" -v hash="$bg_h2" -v moved="$bg_n" '
    BEGIN { n = split(ENVIRON["BG_IDS"], a, "\n"); for (i = 1; i <= n; i++) want[a[i]] = 1 }
    $0 == "## Entries" { insec = 1 }
    insec && /^## / && $0 != "## Entries" { insec = 0 }
    /^- Entries: / { print "- Entries: " left " of " max; next }
    /^- Last gc: / { print "- Last gc: " day " (" moved " archived to docs/history/" name ", SHA-256 " hash ")"; next }
    insec && /^\|/ {
      line = $0; sub(/^\|/, "", line)
      split(line, c, "|"); id = c[1]; gsub(/^[ \t]+|[ \t]+$/, "", id)
      if (id in want) next
    }
    { print }
  ' > "$bg_tmp"
  mv "$bg_tmp" "$DOCS_DIR/Brain.md"
  echo "project_docs rotate: brain archived $bg_n entries to $bg_name"
  return 0
}

# fast_git ARGS...: git in the project with the files the scripts maintain left out of the change.
fast_git() {
  git -C "$PROJECT" -c core.quotepath=false "$@" -- . ':(exclude)docs/Agentslog.md' ':(exclude)docs/Roadmap.md' ':(exclude)docs/Features.md' ':(exclude)docs/Brain.md' ':(exclude)docs/brain' ':(exclude)docs/history' ':(exclude)docs/specs' ':(exclude)docs/.lock'
}

# require_fast_size TASK STATE: handoff of a FAST task. The change since the Base sha must
# stay inside the lane: at most Fast lane max files files and Fast lane max lines lines,
# nothing under Fast lane protected paths, and for a BUG row at least one test file. The
# files the scripts maintain (ledger, Roadmap, Features, Brain, working memory, history,
# specs) do not count. Without git it only warns.
require_fast_size() {
  rf_base="$(printf '%s' "$2" | cut -f19)"
  if [ -z "$rf_base" ] || ! git_ready; then
    echo "WARN: git is not available here, so the size of the change cannot be checked; the reviewer must write 'fast lane ok' in the review note" >&2
    return 0
  fi
  git -C "$PROJECT" cat-file -e "$rf_base^{commit}" 2>/dev/null || die "handoff failed: the Base sha $rf_base is not in this repository"
  rf_tracked="$(fast_git diff --no-renames --relative --name-only "$rf_base" 2>/dev/null)" || die "handoff failed: git could not compare the change with the Base sha $rf_base"
  rf_untracked="$(fast_git ls-files --others --exclude-standard 2>/dev/null)" || die "handoff failed: git could not list the new files"
  rf_names="$(printf '%s\n%s\n' "$rf_tracked" "$rf_untracked" | LC_ALL=C sort -u | awk 'length($0) > 0')"
  rf_files="$(printf '%s\n' "$rf_names" | awk 'length($0) > 0 { n++ } END { print n + 0 }')"
  rf_numstat="$(fast_git diff --no-renames --relative --numstat "$rf_base" 2>/dev/null)" || die "handoff failed: git could not count the lines changed since the Base sha $rf_base"
  rf_lines="$(printf '%s\n' "$rf_numstat" | awk -F'\t' '$1 ~ /^[0-9]+$/ { n += $1 + $2 } END { print n + 0 }')"
  rf_untracked_lines=0
  while IFS= read -r rf_u; do
    [ -n "$rf_u" ] || continue
    rf_n="$(awk 'END { print NR }' "$PROJECT/$rf_u" 2>/dev/null)" || rf_n=0
    rf_untracked_lines=$((rf_untracked_lines + ${rf_n:-0}))
  done <<EOF
$rf_untracked
EOF
  rf_lines=$((rf_lines + rf_untracked_lines))
  rf_max_files="$(factory_number "Fast lane max files")"
  rf_max_lines="$(factory_number "Fast lane max lines")"
  rf_hint="save the work in the branch wip/$1, take Lane: FAST out of its row, go back to $rf_base and move the task to SPEC with advance"
  [ "$rf_files" -le "$rf_max_files" ] || die "handoff failed: task outgrew FAST lane ($rf_files files, the limit is $rf_max_files); $rf_hint"
  [ "$rf_lines" -le "$rf_max_lines" ] || die "handoff failed: task outgrew FAST lane ($rf_lines lines, the limit is $rf_max_lines); $rf_hint"
  rf_prot="$(factory_setting "Fast lane protected paths")"
  for rf_p in $rf_prot; do
    rf_hit="$(printf '%s\n' "$rf_names" | awk -v p="$rf_p" 'length($0) > 0 { s = "/" $0; if (index(s, "/" p) > 0) { print $0; exit } }')"
    [ -z "$rf_hit" ] || die "handoff failed: task outgrew FAST lane (it touches the protected path $rf_hit); $rf_hint"
  done
  case "$1" in
    F[0-9][0-9]-BUG-[0-9][0-9]*)
      rf_tests="$(printf '%s\n' "$rf_names" | awk 'length($0) > 0 { s = "/" $0; if (index(s, ".spec.") > 0 || index(s, ".test.") > 0 || index(s, "/test/") > 0 || index(s, "/tests/") > 0 || index(s, "/e2e/") > 0) { n++ } } END { print n + 0 }')"
      [ "$rf_tests" -gt 0 ] || die "handoff failed: task outgrew FAST lane (a BUG needs a test file in the change); $rf_hint"
      ;;
  esac
}

# require_fast_note TASK STATE NOTE: review PASS of a FAST handoff whose size git could not
# check needs the words "fast lane ok" in the note.
require_fast_note() {
  [ "$(printf '%s' "$2" | cut -f18)" = "FAST" ] || return 0
  if [ -n "$(printf '%s' "$2" | cut -f19)" ] && git_ready; then return 0; fi
  printf '%s' "$3" | tr 'A-Z' 'a-z' | grep -q 'fast lane ok' || die "review failed: git could not check the size of the change of $1; the note must say 'fast lane ok'"
}

# next <project> <agent>: the id of the task this agent should work on now, or none. Order:
# a task it already holds, a task assigned to it, a review waiting for it, a task paused by
# a quota limit that its role can resume, a task assigned to anyone in a phase of its role,
# and the first eligible TODO row of the Roadmap (Active work, Near term, Plan, Gaps).
cmd_next() {
  shift 2
  require_factory next
  [ "$#" -ge 1 ] || die "next requires: agent"
  nx_agent="$(canonical_agent "$(clean_field_text "$1")")"
  [ -f "$DOCS_DIR/Agentslog.md" ] || die "run init first"
  nx_raw="$(roster_role "$nx_agent")"
  [ -n "$nx_raw" ] || die "next failed: $nx_agent is not in the Agent identity table; Factory mode needs a role for each agent"
  nx_role="$(role_norm "$nx_raw")"
  nx_max="$(factory_number "Max fix attempts")"
  nx_indep=1
  if ! factory_yes "Independent review"; then nx_indep=0; fi
  nx_states="$(all_task_states)"
  nx_pref="$(factory_setting "Preferred reviewer")"
  nx_best="$(printf '%s\n' "$nx_states" | awk -F'\t' -v agent="$nx_agent" -v role="$nx_role" -v maxatt="$nx_max" -v indep="$nx_indep" -v pref="$nx_pref" '
    function prole(ph) { if (ph == "" || ph == "SPEC") return "SPEC"; if (ph == "RED") return "TEST"; if (ph == "GREEN") return "DEV"; if (ph == "REVIEW") return "QA"; return "" }
    function can_work(ph,   r) { r = prole(ph); return (r != "" && (role == "BOTH" || role == r)) }
    function can_review(ph) { return (role == "QA" || role == "BOTH" || ((ph == "" || ph == "SPEC") && role == "SPEC")) }
    function cand(p, t) { if (best == "" || p < bestp) { best = t; bestp = p } }
    NF == 0 { next }
    {
      t = $1; st = $2; ag = $3; pc = $5; hold = $9; hand = $10; rev = $11; ph = $12; att = $16 + 0
      if (st == "IN_PROGRESS" && ag == agent) cand(0, t)
      else if (st == "REVIEW" && rev != "" && hold == agent) cand(0, t)
      else if (st == "ASSIGNED" && hold == agent && can_work(ph) && att < maxatt) cand(1, t)
      else if (st == "REVIEW" && rev == "" && can_review(ph) && (indep == 0 || hold != agent) && (hand == agent || hand == "" || toupper(hand) == role || (role == "BOTH" && toupper(hand) == "QA"))) cand(2, t)
      else if (st == "PAUSE" && pc == "LIMITE" && can_work(ph) && att < maxatt) cand(3, t)
      else if (st == "ASSIGNED" && hold != agent && can_work(ph) && att < maxatt) cand(4, t)
    }
    END { if (best != "") print best }
  ')"
  if [ -n "$nx_best" ]; then printf '%s\n' "$nx_best"; return 0; fi
  nx_known="$(printf '%s\n' "$nx_states" | awk -F'\t' 'NF > 0 { printf "%s ", $1 }')"
  nx_todo="$(awk -F'|' -v known="$nx_known" -v role="$nx_role" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    BEGIN { kn = split(known, kk, " "); for (i = 1; i <= kn; i++) isknown[kk[i]] = 1 }
    /^## / {
      sect = $0; rank = 0
      if (sect ~ /^## Active work/) rank = 1
      else if (sect ~ /^## Near term/) rank = 2
      else if (sect ~ /^## Plan/) rank = 3
      else if (sect ~ /^## Gaps/) rank = 4
      hdr = 0; next
    }
    /^\|/ {
      line = $0; sub(/^\|/, "", line); sub(/\|[ \t]*$/, "", line)
      cn = split(line, c, "|")
      for (i = 1; i <= cn; i++) c[i] = trim(c[i])
      if (c[1] == "ID") { si = di = ei = ni = 0; for (i = 1; i <= cn; i++) { if (c[i] == "Status") si = i; if (c[i] == "Depends on") ei = i; if (c[i] == "Description") di = i; if (c[i] == "Name") ni = i } hdr = 1; next }
      if (c[1] ~ /^-+$/ || !hdr) next
      allid[c[1]] = 1
      if (rank > 0 && c[1] ~ /^[A-Za-z0-9]/ && !(ni && c[ni] == "UNKNOWN")) { rn++; RID[rn] = c[1]; RST[rn] = (si ? c[si] : ""); RDEP[rn] = (ei ? c[ei] : ""); RDESC[rn] = (di ? c[di] : ""); RK[rn] = rank }
    }
    END {
      for (k = 1; k <= 4; k++) for (r = 1; r <= rn; r++) {
        if (RK[r] != k || RST[r] != "TODO" || (RID[r] in isknown)) continue
        need = (index(RDESC[r], "Lane: FAST") > 0) ? "DEV" : "SPEC"
        if (role != "BOTH" && role != need) continue
        ok = 1
        m = split(RDEP[r], dd, /[ ,;]+/)
        for (j = 1; j <= m; j++) if (dd[j] ~ /^F[0-9][0-9]*-/ && (dd[j] in allid)) { ok = 0; break }
        if (ok) { print RID[r]; exit }
      }
    }
  ' "$DOCS_DIR/Roadmap.md")"
  if [ -n "$nx_todo" ]; then printf '%s\n' "$nx_todo"; return 0; fi
  if [ -n "$nx_pref" ] && [ "$nx_agent" = "$nx_pref" ]; then
    nx_audit="$(printf '%s\n' "$nx_states" | awk -F'\t' '$2 == "DONE" && $18 != "FAST" && $20 == "NO" && $21 + 0 == 0 { print $1; exit }')"
    if [ -n "$nx_audit" ]; then printf '%s\n' "$nx_audit"; return 0; fi
  fi
  printf 'none\n'
}

# roster_model ID: the Model cell of a roster id.
roster_model() {
  roster_rows | awk -F'\t' -v id="$1" '$1 == id { print $3; exit }'
}

# digest <project> [since]: what a human has to read, in at most 4 KiB: product guesses
# and decisions still HYPOTHESIS, open red lines, open gaps, new lessons, what closed,
# and the reviews (failures, reviews of one model, audits).
cmd_digest() {
  shift 2
  require_factory digest
  dg_since="${1:-}"
  if [ -n "$dg_since" ]; then
    dg_ok=0
    if printf '%s' "$dg_since" | grep -Eq '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])(T([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?Z?)?$'; then
      dg_ok=1
      dg_mm="$(printf '%s' "$dg_since" | cut -c6-7)"; dg_dd="$(printf '%s' "$dg_since" | cut -c9-10)"
      case "$dg_mm" in
        02) [ "$dg_dd" -le 29 ] || dg_ok=0 ;;
        04|06|09|11) [ "$dg_dd" -le 30 ] || dg_ok=0 ;;
      esac
    fi
    [ "$dg_ok" -eq 1 ] || die "digest requires an ISO date like 2026-10-27 or a timestamp like 2026-10-27T14:00:00Z"
  fi
  [ -f "$DOCS_DIR/Agentslog.md" ] || die "run init first"
  # awk function: the first N characters of a UTF-8 string, run in the C locale (bytes), so a
  # multibyte character is never cut in two
  dg_cut='function cut(s, n,   i, c, out, ch) { out = ""; ch = 0; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c !~ /[\200-\277]/) { ch++; if (ch > n) break } out = out c } return out }'
  dg_day="$(printf '%s' "$dg_since" | cut -c1-10)"
  dg_tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-digest.XXXXXX")"
  dg_states="$(all_task_states)"
  {
    echo "digest since ${dg_since:-the start of the ledger}"
    echo "## Product guesses"
    if [ -f "$DOCS_DIR/ProductDescription.md" ]; then
      clean_stream < "$DOCS_DIR/ProductDescription.md" | LC_ALL=C awk "$dg_cut"'
        /^\|/ {
          line=$0; sub(/^\|/, "", line); sub(/\|[ \t]*$/, "", line); n=split(line, c, "|")
          for (i=1; i<=n; i++) gsub(/^[ \t]+|[ \t]+$/, "", c[i])
          if (c[1] ~ /^BR-[0-9]+$/ && c[3] == "HYPOTHESIS" && c[4] ~ /^agent:/) printf "%s | %s | %s\n", c[1], cut(c[2], 80), c[4]
        }
      '
    fi > "$dg_tmp.part"
    if [ -f "$DOCS_DIR/Stack_Tecnologies.md" ]; then
      clean_stream < "$DOCS_DIR/Stack_Tecnologies.md" | LC_ALL=C awk -v since="$dg_day" "$dg_cut"'
        /^\|/ {
          line=$0; sub(/^\|/, "", line); sub(/\|[ \t]*$/, "", line); n=split(line, c, "|")
          for (i=1; i<=n; i++) gsub(/^[ \t]+|[ \t]+$/, "", c[i])
          if (c[1] ~ /^ADR-[0-9]+$/ && c[4] == "HYPOTHESIS" && (since == "" || c[5] >= since)) printf "%s | %s | %s\n", c[1], cut(c[2], 80), c[5]
        }
      ' >> "$dg_tmp.part"
    fi
    if [ -s "$dg_tmp.part" ]; then cat "$dg_tmp.part"; else echo "(none)"; fi
    echo "## Red lines"
    dg_red="$(printf '%s\n' "$dg_states" | awk -F'\t' '$2 == "PAUSE" && index($22, "RED-LINE:") == 1 { printf "%s | %s | %s\n", $1, $3, $22 }')"
    if [ -n "$dg_red" ]; then printf '%s\n' "$dg_red"; else echo "(none)"; fi
    echo "## Open gaps"
    dg_gaps="$(awk -F'|' '
      function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
      /^## / { insec = ($0 ~ /^## Gaps/); hdr = 0; next }
      insec && /^\|/ {
        line=$0; sub(/^\|/, "", line); sub(/\|[ \t]*$/, "", line); n=split(line, c, "|")
        for (i=1; i<=n; i++) c[i] = trim(c[i])
        if (c[1] == "ID") { ni = si = 0; for (i=1; i<=n; i++) { if (c[i] == "Name") ni = i; if (c[i] == "Status") si = i } hdr = 1; next }
        if (!hdr || c[1] ~ /^-+$/) next
        if (c[1] ~ /-GAP-/ && (si == 0 || c[si] != "DONE")) printf "%s | %s | %s\n", c[1], (ni ? c[ni] : ""), (si ? c[si] : "")
      }
    ' "$DOCS_DIR/Roadmap.md")"
    if [ -n "$dg_gaps" ]; then printf '%s\n' "$dg_gaps"; else echo "(none)"; fi
    echo "## New lessons"
    dg_les="$(brain_rows_tsv | awk -F'\t' '$7 == "HYPOTHESIS" { printf "%s | %s | %s\n", $1, $2, $6 }')"
    if [ -n "$dg_les" ]; then printf '%s\n' "$dg_les"; else echo "(none)"; fi
    echo "## Closed"
    printf '%s\n' "$dg_states" | awk -F'\t' -v since="$dg_since" '$2 == "DONE" && (since == "" || $4 >= since) { if ($18 == "FAST") f++; else n++ } END { print "NORMAL: " n + 0 ", FAST: " f + 0 }'
    echo "## Reviews"
    dg_fail="$(clean_stream < "$DOCS_DIR/Agentslog.md" | awk -v since="$dg_since" '
      /^## \[/ { ts = substr($0, 5, 20); on = (since == "" || ts >= since); next }
      on && /^- Review: FAIL/ { n++ }
      END { print n + 0 }
    ')"
    dg_cross="$(printf '%s\n' "$dg_states" | awk -F'\t' -v since="$dg_since" '$2 == "DONE" && $18 != "FAST" && $20 == "NO" && (since == "" || $4 >= since) { n++; if ($21 + 0 > 0) a++ } END { print n + 0 " " a + 0 }')"
    echo "Failed reviews: $dg_fail; NORMAL tasks closed with the same model reviewing: ${dg_cross% *}; audited by the preferred reviewer: ${dg_cross#* }"
  } > "$dg_tmp"
  rm -f "$dg_tmp.part"
  LC_ALL=C awk -v max=4096 "$dg_cut"'
    { L[NR] = $0; if (length(L[NR]) > 800) L[NR] = cut(L[NR], 197) "..." }
    END {
      total = 0; for (i = 1; i <= NR; i++) total += length(L[i]) + 1
      if (total <= max) { for (i = 1; i <= NR; i++) print L[i]; exit }
      bytes = 0; k = 0
      for (i = 1; i <= NR; i++) {
        foot = "digest: truncated, " (NR - i) " more lines, read the ledger and the Roadmap"
        if (bytes + length(L[i]) + 1 + length(foot) + 1 > max) break
        bytes += length(L[i]) + 1; k = i
      }
      for (i = 1; i <= k; i++) print L[i]
      print "digest: truncated, " (NR - k) " more lines, read the ledger and the Roadmap"
    }
  ' "$dg_tmp"
  rm -f "$dg_tmp"
}

# Commands that exist only in Factory mode refuse to run in classic mode.
require_factory() {
  factory_on || die "$1 needs Factory mode (see references/factory.md)"
}

# The working memory of a task: docs/brain/tasks/<TASK-ID>.md (F06-E03-T02).
working_memory_path() {
  printf '%s/brain/tasks/%s.md' "$DOCS_DIR" "$1"
}

# has_working_now TASK: true when the task has a working memory with a ## Now.
has_working_now() {
  hw_f="$(working_memory_path "$1")"
  [ -f "$hw_f" ] && tr -d '\r' < "$hw_f" | grep -qx '## Now'
}

# task_attempts TASK: how many times the task was sent back (Review: FAIL lines).
task_attempts() {
  ta_v="$(task_state "$1" | cut -f16)" || true
  printf '%s' "${ta_v:-0}"
}

# checkpoint <project> <agent> <task-id> <step> <next>: creates or updates the
# working memory of a task: rewrites ## Now and adds a line to ## Trail.
cmd_checkpoint() {
  shift 2
  require_factory checkpoint
  [ "$#" -ge 4 ] || die "checkpoint requires: agent task-id step next"
  agent="$(canonical_agent "$(clean_field_text "$1")")"
  task="$(clean_field_text "$2")"
  step="$(clean_field_text "$3")"
  nxt="$(clean_field_text "$4")"
  [ -n "$step" ] || die "checkpoint requires a non-empty step"
  [ -n "$nxt" ] || die "checkpoint requires a non-empty next"
  [ -f "$DOCS_DIR/Agentslog.md" ] || die "run init first"
  roadmap_has_id "$task" || die "checkpoint failed: $task not found in docs/Roadmap.md"
  with_lock
  wm="$(working_memory_path "$task")"
  mkdir -p "$DOCS_DIR/brain/tasks"
  if [ ! -f "$wm" ]; then
    [ -f "$TEMPLATES_DIR/WorkingMemory.md" ] || die "template missing: WorkingMemory.md"
    awk -v task="$task" '{ i = index($0, "{TASK}"); if (i > 0) $0 = substr($0, 1, i - 1) task substr($0, i + 6); print }' "$TEMPLATES_DIR/WorkingMemory.md" > "$wm"
  fi
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  attempts="$(task_attempts "$task")"
  wm_tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-memory.XXXXXX")"
  if ! clean_stream < "$wm" | WM_STEP="$step" WM_NEXT="$nxt" awk -v att="$attempts" -v ts="$timestamp" -v agent="$agent" '
    function flush_trail() {
      if (intrail && !added) {
        print "- " ts " " agent ": " ENVIRON["WM_STEP"]
        added=1
        while (nb > 0) { print ""; nb-- }
      }
    }
    $0 == "## Now" {
      flush_trail(); intrail=0; innow=1; hasnow=1
      print
      print "- Step: " ENVIRON["WM_STEP"]
      print "- Next: " ENVIRON["WM_NEXT"]
      print "- Attempts: " att
      print "- Updated: " ts
      print ""
      next
    }
    /^## / {
      flush_trail(); innow=0
      intrail = ($0 == "## Trail")
      if (intrail) hastrail=1
      print
      next
    }
    innow { next }
    intrail { if ($0 == "") { nb++; next } while (nb > 0) { print ""; nb-- } print; next }
    { print }
    END { flush_trail(); if (!hasnow || !hastrail) exit 3 }
  ' > "$wm_tmp"; then
    rm -f "$wm_tmp"
    die "checkpoint failed: docs/brain/tasks/$task.md is not a working memory file (needs ## Now and ## Trail)"
  fi
  mv "$wm_tmp" "$wm"
  echo "project_docs checkpoint: $task saved"
}

cmd_pause() {
  shift 2
  [ "$#" -ge 4 ] || die "pause requires: agent task-id category detail"
  agent="$(canonical_agent "$(clean_arg "$1")")"
  task="$(clean_arg "$2")"
  category="$(clean_arg "$3")"
  detail="$(clean_arg "$4")"
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
  if factory_on && [ "$status" = "REVIEW" ]; then
    pause_holder="$(printf '%s' "$state" | cut -f9)"
    [ "$pause_holder" = "$agent" ] || die "pause failed: $task is held by $pause_holder, not $agent"
  else
    [ "$status" = "IN_PROGRESS" ] || die "pause failed: $task is not IN_PROGRESS (current: $status)"
    [ "$owner" = "$agent" ] || die "pause failed: $task is owned by $owner, not $agent"
  fi
  if factory_on && ! has_working_now "$task"; then
    die "pause failed: $task has no working memory yet (## Now); run checkpoint first"
  fi
  name="$(require_valid_name "$task" pause)"
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  {
    echo
    echo "## [$timestamp] | $agent | $task | PAUSE | $name"
    echo "- Pause: $category - $detail"
  } >> "$DOCS_DIR/Agentslog.md"
  roadmap_update_row_inplace "$task" "PAUSE" "$agent@$timestamp" "$category"
  echo "project_docs pause: $task paused ($category)"
}

# handoff <agent> <task-id> <summary> <verify> [reviewer]
# The developer says the code is complete and their own verification passed.
# Written as a REVIEW entry (the Roadmap row stays IN_PROGRESS with the same
# Owner: the stage lives in the ledger only). Same ownership checks as pause.
cmd_handoff() {
  shift 2
  [ "$#" -ge 4 ] || die "handoff requires: agent task-id summary verify [reviewer]"
  agent="$(canonical_agent "$(clean_arg "$1")")"
  task="$(clean_arg "$2")"
  summary="$(clean_arg "$3")"
  verify="$(clean_arg "$4")"
  reviewer="$(clean_arg "${5:-}")"
  [ -f "$DOCS_DIR/Agentslog.md" ] || die "run init first"
  [ -n "$summary" ] || die "handoff requires a non-empty summary"
  if [ -z "$verify" ] || [ "$verify" = "pending" ]; then
    die "handoff requires a verify that is not empty or pending"
  fi
  with_lock
  if state="$(task_state "$task")"; then
    status="$(printf '%s' "$state" | cut -f2)"
    owner="$(printf '%s' "$state" | cut -f3)"
  else
    die "handoff failed: $task has no IN_PROGRESS entry to hand off"
  fi
  [ "$status" = "IN_PROGRESS" ] || die "handoff failed: $task is not IN_PROGRESS (current: $status)"
  [ "$owner" = "$agent" ] || die "handoff failed: $task is owned by $owner, not $agent"
  if factory_on; then
    handoff_phase="$(printf '%s' "$state" | cut -f12)"
    [ -n "$handoff_phase" ] || handoff_phase="SPEC"
    case "$handoff_phase" in
      SPEC|GREEN) ;;
      *) die "handoff failed: $task is in phase $handoff_phase; move it with advance" ;;
    esac
    require_exit_zero handoff "$verify"
    has_working_now "$task" || die "handoff failed: $task has no working memory yet (## Now); run checkpoint first"
    if [ "$(printf '%s' "$state" | cut -f18)" = "FAST" ]; then require_fast_size "$task" "$state"; fi
    if [ "$handoff_phase" = "GREEN" ]; then require_tests_unchanged "$task" "$state"; fi
  fi
  if factory_on && [ -z "$reviewer" ]; then
    if [ "$(printf '%s' "$state" | cut -f18)" = "FAST" ]; then
      reviewer="$(factory_setting "Fallback reviewer")"
    else
      reviewer="$(factory_setting "Preferred reviewer")"
    fi
    if [ "$reviewer" = "$agent" ]; then reviewer=""; fi
  fi
  name="$(require_valid_name "$task" handoff)"
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  hs_sha=""
  if factory_on && [ "$handoff_phase" = "SPEC" ] && [ -f "$DOCS_DIR/specs/$task.md" ]; then
    hs_sha="$(file_hash "$DOCS_DIR/specs/$task.md" | awk '{ print $1 }')"
  fi
  {
    echo
    echo "## [$timestamp] | $agent | $task | REVIEW | $name"
    echo "- Summary: $summary"
    echo "- Verify: $verify"
    if [ -n "$reviewer" ]; then echo "- Handoff: $reviewer"; fi
    if [ -n "$hs_sha" ]; then echo "- Spec-sha: $hs_sha"; fi
  } >> "$DOCS_DIR/Agentslog.md"
  if [ -n "$reviewer" ]; then
    echo "project_docs handoff: $task handed to review ($reviewer)"
  else
    echo "project_docs handoff: $task handed to review"
  fi
}

# review <agent> <task-id> <PASS|FAIL> <note> [verify]
# A reviewer answers a pending handoff. Written as a REVIEW entry in the
# reviewer's name carrying a "- Review: PASS|FAIL - note" line; the Roadmap row
# is not touched. After FAIL the task is back with its holder, who retakes it
# with claim. Reviewing your own handoff warns (a single-agent project must not
# freeze) unless PROJECT_DOCS_REQUIRE_INDEPENDENT_REVIEW=1.
cmd_review() {
  shift 2
  [ "$#" -ge 4 ] || die "review requires: agent task-id PASS|FAIL note [verify]"
  agent="$(canonical_agent "$(clean_arg "$1")")"
  task="$(clean_arg "$2")"
  result="$(clean_arg "$3")"
  note="$(clean_arg "$4")"
  verify="$(clean_arg "${5:-}")"
  [ -f "$DOCS_DIR/Agentslog.md" ] || die "run init first"
  case "$result" in
    PASS|FAIL) ;;
    *) die "review requires PASS or FAIL as the result" ;;
  esac
  [ -n "$note" ] || die "review requires a non-empty note"
  if [ "$verify" = "pending" ]; then die "review verify must not be pending"; fi
  if [ "$result" = "PASS" ] && [ -z "$verify" ]; then
    die "review PASS requires a verify that is not empty or pending"
  fi
  with_lock
  if state="$(task_state "$task")"; then
    status="$(printf '%s' "$state" | cut -f2)"
    holder="$(printf '%s' "$state" | cut -f9)"
    reviewed="$(printf '%s' "$state" | cut -f11)"
  else
    die "review failed: $task has no handoff to review"
  fi
  [ "$status" = "REVIEW" ] || die "review failed: $task has no pending handoff (current: $status)"
  [ -z "$reviewed" ] || die "review failed: $task was already reviewed ($reviewed); the holder must claim it again"
  if factory_on; then
    review_phase="$(printf '%s' "$state" | cut -f12)"
    [ -n "$review_phase" ] || review_phase="SPEC"
    if [ "$agent" = "$holder" ] && factory_yes "Independent review"; then
      die "review failed: $agent developed $task; an independent review is required"
    fi
    review_role="$(roster_role "$agent")"
    [ -n "$review_role" ] || die "review failed: $agent is not in the Agent identity table; Factory mode needs a role for each agent"
    review_norm="$(role_norm "$review_role")"
    if [ "$review_norm" != "QA" ] && [ "$review_norm" != "BOTH" ] && { [ "$review_phase" != "SPEC" ] || [ "$review_norm" != "SPEC" ]; }; then
      die "review failed: $agent has role $review_role, but a review of phase $review_phase needs QA (or BOTH)"
    fi
    if [ "$result" = "PASS" ]; then
      require_exit_zero review "$verify"
      require_tests_note "$task" "$state" "$note"
      require_fast_note "$task" "$state" "$note"
    fi
  fi
  if [ "$agent" = "$holder" ]; then
    if [ "${PROJECT_DOCS_REQUIRE_INDEPENDENT_REVIEW:-0}" = "1" ]; then
      die "review failed: $agent developed $task; an independent review is required"
    fi
    echo "WARN: self-review: $agent reviews its own handoff of $task" >&2
  fi
  if [ "$(roster_role "$agent")" = "DEVELOPER" ]; then
    echo "WARN: $agent has role DEVELOPER in the Agent identity table, not QA or BOTH" >&2
  fi
  name="$(require_valid_name "$task" review)"
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  review_cross=0
  if factory_on; then
    rv_hw="$(roster_model "$holder" | awk '{ print tolower($1) }')"
    rv_rw="$(roster_model "$agent" | awk '{ print tolower($1) }')"
    if [ "$rv_hw" = "$rv_rw" ]; then review_cross=1; fi
  fi
  {
    echo
    echo "## [$timestamp] | $agent | $task | REVIEW | $name"
    echo "- Summary: Review of the handoff from $holder"
    if [ -n "$verify" ]; then echo "- Verify: $verify"; fi
    echo "- Review: $result - $note"
    if [ "$review_cross" -eq 1 ]; then echo "- Cross-model: NO"; fi
  } >> "$DOCS_DIR/Agentslog.md"
  echo "project_docs review: $task $result by $agent"
}

# assign <agent> <task-id> <to-agent>
# Records that <agent> assigned the task to <to-agent> (an ASSIGNED entry with a
# "- Assign:" line) and sets the Roadmap Owner to <to-agent>@<timestamp>. The
# row stays TODO and no work starts: the assignee still has to claim. A task
# somebody is already working on (IN_PROGRESS, PAUSE, REVIEW) cannot be assigned.
# git_ready: true when git is installed and the project is inside a work tree.
git_ready() {
  command -v git >/dev/null 2>&1 && [ "$(git -C "$PROJECT" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]
}

# verify_exit TEXT: the number after the first exit= marker of a verify string.
verify_exit() {
  printf '%s' "$1" | awk '
    {
      start = 1
      while (match(substr($0, start), /exit=[0-9]+/)) {
        abs = start + RSTART - 1; len = RLENGTH
        pre = (abs > 1) ? substr($0, abs - 1, 1) : ""
        post = substr($0, abs + len, 1)
        if (pre !~ /[A-Za-z0-9_]/ && post !~ /[A-Za-z0-9_]/) { print substr($0, abs + 5, len - 5); exit }
        start = abs + len
      }
    }
  '
}

# exit_is_zero DIGITS: true when the digits spell zero (leading zeros ignored).
exit_is_zero() {
  ez_v="$1"
  while [ "${ez_v#0}" != "$ez_v" ]; do ez_v="${ez_v#0}"; done
  [ -z "$ez_v" ]
}

# factory_yes NAME: true unless the setting says NO (any case).
factory_yes() {
  fy_v="$(factory_setting "$1" | tr 'a-z' 'A-Z')"
  [ "$fy_v" != "NO" ]
}

# spec_unknown_count FILE: how many lines of a spec still say UNKNOWN.
spec_unknown_count() {
  tr -d '\r' < "$1" | awk '/UNKNOWN/ { n++ } END { print n + 0 }'
}

# spec_tests FILE: the test paths of the ## Tests section of a spec, one per line.
spec_tests() {
  tr -d '\r' < "$1" | awk '
    /^## / { sec=$0; next }
    sec == "## Tests" && /^- / { p=substr($0, 3); sub(/ .*/, "", p); print p }
  '
}

# default_assignee PHASE: the first roster id whose role is the one of the phase,
# else the first BOTH.
default_assignee() {
  da_need="$(phase_role "$1")"
  roster_rows | awk -F'\t' -v need="$da_need" '
    {
      r=$4; if (r == "DEVELOPER") r="DEV"
      if (ex == "" && r == need) ex=$1
      if (bo == "" && r == "BOTH") bo=$1
    }
    END { if (ex != "") print ex; else print bo }
  '
}

# Gate SPEC to RED: a valid spec without UNKNOWN and a review PASS from another agent.
advance_gate_spec() {
  ag_spec="$DOCS_DIR/specs/$1.md"
  [ -f "$ag_spec" ] || die "advance failed: docs/specs/$1.md does not exist (the SPEC phase produces it)"
  ag_out="$(spec_report "$ag_spec")"
  if printf '%s\n' "$ag_out" | grep -q '^ERROR:'; then
    printf '%s\n' "$ag_out" | grep '^ERROR:' >&2
    die "advance failed: docs/specs/$1.md has errors (see above)"
  fi
  ag_unk="$(spec_unknown_count "$ag_spec")"
  [ "$ag_unk" -eq 0 ] || die "advance failed: docs/specs/$1.md still has $ag_unk UNKNOWN field(s)"
  if factory_yes "Independent review"; then
    ag_by="$(printf '%s' "$state" | cut -f13)"
    [ -n "$ag_by" ] || die "advance failed: the spec of $1 has no Review: PASS yet (hand it off to a reviewer first)"
    [ "$ag_by" != "$2" ] || die "advance failed: the Review: PASS of the spec of $1 comes from $2 itself; another agent must review it"
    ag_rec="$(spec_sha_of "$1")"
    if [ -n "$ag_rec" ]; then
      ag_now="$(file_hash "$ag_spec" | awk '{ print $1 }')"
      [ "$ag_rec" = "$ag_now" ] || die "advance failed: docs/specs/$1.md changed after it was handed off for review (the review saw $(printf '%s' "$ag_rec" | cut -c1-8), the file is $(printf '%s' "$ag_now" | cut -c1-8) now); hand it off for review again"
    fi
  fi
}

# spec_sha_of TASK: the SHA-256 of the spec that the last handoff of the task recorded, or nothing.
spec_sha_of() {
  clean_stream < "$DOCS_DIR/Agentslog.md" | awk -v id="$1" '
    /^## \[/ { cur = 0; n = split($0, h, " [|] "); if (n >= 3 && h[3] == id) cur = 1; next }
    cur && /^- Spec-sha: / { sha = substr($0, 13) }
    END { print sha }
  '
}

# Gate RED to GREEN: failing tests (exit not 0), listed in the spec, existing and
# committed. Leaves ADV_RED_SHA and ADV_TESTS for the ledger entry.
advance_gate_red() {
  ar_n="$(verify_exit "$2")"
  [ -n "$ar_n" ] || die "advance failed: the verify of RED needs exit=N with N not 0 (the tests must fail first)"
  if exit_is_zero "$ar_n"; then
    die "advance failed: RED needs failing tests, but the verify says exit=0"
  fi
  ar_spec="$DOCS_DIR/specs/$1.md"
  [ -f "$ar_spec" ] || die "advance failed: docs/specs/$1.md does not exist"
  ar_tests="$(spec_tests "$ar_spec")"
  [ -n "$ar_tests" ] || die "advance failed: docs/specs/$1.md ## Tests lists no test file"
  ADV_RED_SHA=""
  ar_git=0
  if git_ready; then ar_git=1; fi
  ar_list=""
  while IFS= read -r ar_p; do
    [ -n "$ar_p" ] || continue
    [ -f "$PROJECT/$ar_p" ] || die "advance failed: test file '$ar_p' does not exist"
    if [ "$ar_git" -eq 1 ]; then
      if ! git -C "$PROJECT" ls-files --error-unmatch -- "$ar_p" >/dev/null 2>&1 || [ -n "$(git -C "$PROJECT" status --porcelain -- "$ar_p" 2>/dev/null)" ]; then
        die "advance failed: test file '$ar_p' is not committed (commit the failing tests before GREEN)"
      fi
    fi
    if [ -z "$ar_list" ]; then ar_list="$ar_p"; else ar_list="$ar_list $ar_p"; fi
  done <<EOF
$ar_tests
EOF
  ADV_TESTS="$ar_list"
  if [ "$ar_git" -eq 1 ]; then
    ADV_RED_SHA="$(git -C "$PROJECT" rev-parse HEAD 2>/dev/null)" || die "advance failed: the repository has no commit yet (commit the failing tests before GREEN)"
  else
    echo "WARN: git is not available here, so the tests cannot be checked as committed and no Red sha is recorded" >&2
  fi
}

# advance_untestable TASK: succeeds when RED has nothing to prove failing (D-08, ADR-091): the
# spec has scenarios, every one is Level NONE (each already needs a Justification) and the
# ## Tests section lists no file. A BUG row never qualifies (ADR-030): its RED is a test.
advance_untestable() {
  case "$1" in F[0-9][0-9]-BUG-[0-9][0-9]*) return 1 ;; esac
  [ -f "$DOCS_DIR/specs/$1.md" ] || return 1
  clean_stream < "$DOCS_DIR/specs/$1.md" | awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^## / { sec=$0; next }
    sec == "## Scenarios" && /^\|/ {
      line=$0; sub(/^\|/, "", line); sub(/\|[ \t]*$/, "", line)
      cn=split(line, c, "|")
      for (i=1; i<=cn; i++) c[i]=trim(c[i])
      if (c[1] == "ID" || c[1] ~ /^-+$/) next
      rows++
      if (c[5] != "NONE") other++
      next
    }
    sec == "## Tests" && /^- / { tests++ }
    END { exit !(rows > 0 && other == 0 && tests == 0) }
  '
}

# advance <project> <agent> <task-id> <next-phase> <verify> [to-agent]: moves the
# task to its next phase, checking the gate of the phase it leaves, and assigns it.
cmd_advance() {
  shift 2
  require_factory advance
  [ "$#" -ge 4 ] || die "advance requires: agent task-id next-phase verify [to-agent]"
  agent="$(canonical_agent "$(clean_field_text "$1")")"
  task="$(clean_field_text "$2")"
  next_phase="$(clean_field_text "$3")"
  verify="$(clean_field_text "$4")"
  to_arg=""
  if [ "$#" -ge 5 ]; then to_arg="$(canonical_agent "$(clean_field_text "$5")")"; fi
  [ -f "$DOCS_DIR/Agentslog.md" ] || die "run init first"
  [ -n "$verify" ] || die "advance requires a non-empty verify"
  roadmap_has_id "$task" || die "advance failed: $task not found in docs/Roadmap.md"
  with_lock
  state="$(task_state "$task")" || die "advance failed: $task has no IN_PROGRESS entry to advance"
  status="$(printf '%s' "$state" | cut -f2)"
  owner="$(printf '%s' "$state" | cut -f3)"
  cur_phase="$(printf '%s' "$state" | cut -f12)"
  [ -n "$cur_phase" ] || cur_phase="SPEC"
  [ "$status" = "IN_PROGRESS" ] || die "advance failed: $task is not IN_PROGRESS (current: $status)"
  [ "$owner" = "$agent" ] || die "advance failed: $task is owned by $owner, not $agent"
  allowed=0
  case "$cur_phase:$next_phase" in
    SPEC:RED|RED:GREEN|RED:SPEC|GREEN:SPEC|GREEN:RED) allowed=1 ;;
    SPEC:GREEN) if ! factory_yes "Require TDD"; then allowed=1; fi ;;
  esac
  if [ "$allowed" -ne 1 ]; then
    die "advance failed: $task cannot move from $cur_phase to $next_phase (allowed: SPEC to RED, RED to GREEN, back to SPEC or RED; GREEN to REVIEW is handoff)"
  fi
  has_working_now "$task" || die "advance failed: $task has no working memory yet (## Now); run checkpoint first"
  if [ "$(printf '%s' "$state" | cut -f18)" = "FAST" ] && [ "$next_phase" != "SPEC" ]; then
    die "advance failed: $task is a FAST task; it only goes back to SPEC, when it outgrew the lane"
  fi
  if [ -n "$to_arg" ]; then
    to_agent="$to_arg"
    require_phase_role "$to_agent" "$next_phase" "$task" advance
  else
    to_agent="$(default_assignee "$next_phase")"
    [ -n "$to_agent" ] || die "advance failed: no agent in the Agent identity table has the role $(phase_role "$next_phase") for phase $next_phase; pass to-agent"
  fi
  ADV_RED_SHA=""
  ADV_TESTS=""
  if [ "$cur_phase" = "SPEC" ]; then
    advance_gate_spec "$task" "$agent"
  elif [ "$cur_phase:$next_phase" = "RED:GREEN" ] && factory_yes "Require TDD"; then
    # a spec of Level NONE only has no test to fail: no Red sha and no test paths are recorded
    if ! advance_untestable "$task"; then advance_gate_red "$task" "$verify"; fi
  fi
  name="$(require_valid_name "$task" advance)"
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  {
    echo
    echo "## [$timestamp] | $agent | $task | ASSIGNED | $name"
    echo "- Summary: Moved to $next_phase, assigned to $to_agent"
    echo "- Phase: $next_phase"
    echo "- Assign: $to_agent"
    echo "- Verify: $verify"
    if [ -n "$ADV_RED_SHA" ]; then echo "- Red: $ADV_RED_SHA"; fi
    if [ -n "$ADV_TESTS" ]; then echo "- Tests: $ADV_TESTS"; fi
  } >> "$DOCS_DIR/Agentslog.md"
  roadmap_update_row_inplace "$task" "IN_PROGRESS" "$to_agent@$timestamp" "—"
  echo "project_docs advance: $task moved to $next_phase, assigned to $to_agent"
}

cmd_assign() {
  shift 2
  [ "$#" -ge 3 ] || die "assign requires: agent task-id to-agent"
  agent="$(canonical_agent "$(clean_arg "$1")")"
  task="$(clean_arg "$2")"
  to_agent="$(canonical_agent "$(clean_arg "$3")")"
  [ -f "$DOCS_DIR/Agentslog.md" ] || die "run init first"
  [ -n "$to_agent" ] || die "assign requires a non-empty to-agent"
  if ! roadmap_has_id "$task"; then
    die "assign failed: $task not found in docs/Roadmap.md"
  fi
  with_lock
  if state="$(task_state "$task")"; then
    status="$(printf '%s' "$state" | cut -f2)"
    holder="$(printf '%s' "$state" | cut -f9)"
    case "$status" in
      IN_PROGRESS|PAUSE|REVIEW) die "assign failed: $task is $status, held by $holder" ;;
    esac
  fi
  name="$(require_valid_name "$task" assign)"
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  {
    echo
    echo "## [$timestamp] | $agent | $task | ASSIGNED | $name"
    echo "- Summary: Assigned to $to_agent"
    echo "- Assign: $to_agent"
  } >> "$DOCS_DIR/Agentslog.md"
  roadmap_update_row_inplace "$task" "TODO" "$to_agent@$timestamp" "—"
  echo "project_docs assign: $task assigned to $to_agent"
}

cmd_done() {
  shift 2
  [ "$#" -ge 5 ] || die "done requires: agent task-id summary files verify"
  agent="$(canonical_agent "$(clean_arg "$1")")"
  task="$(clean_arg "$2")"
  summary="$(clean_arg "$3")"
  files="$(clean_arg "$4")"
  verify="$(clean_arg "$5")"
  [ -n "$verify" ] || die "done requires a non-empty verify"
  if factory_on; then require_exit_zero done "$verify"; fi
  with_lock
  # Who may close a task: nobody has an entry for it (retroactive close, the
  # normal case for batches), the holder, the reviewer who left Review: PASS,
  # anyone once the last entry is stale, or anyone with PROJECT_DOCS_FORCE=1.
  if state="$(task_state "$task")"; then
    status="$(printf '%s' "$state" | cut -f2)"
    last_agent="$(printf '%s' "$state" | cut -f3)"
    holder="$(printf '%s' "$state" | cut -f9)"
    review="$(printf '%s' "$state" | cut -f11)"
    allowed=0
    if [ "$agent" = "$holder" ]; then
      allowed=1
    elif [ "$status" = "REVIEW" ] && [ "$review" = "PASS" ] && [ "$agent" = "$last_agent" ]; then
      allowed=1
    elif [ "${PROJECT_DOCS_FORCE:-0}" = "1" ]; then
      allowed=1
    elif is_stale "$task"; then
      allowed=1
    fi
    [ "$allowed" -eq 1 ] || die "done failed: $task is held by $holder"
    if factory_on; then
      if [ "$status" != "REVIEW" ] || [ "$review" != "PASS" ]; then
        die "done failed: $task has no Review: PASS yet (status $status, last review ${review:-none})"
      fi
    fi
    if [ "$status" = "REVIEW" ] && [ "$review" != "PASS" ]; then
      if [ "$review" = "FAIL" ]; then
        echo "WARN: $task: closing without a passing review (the last review was FAIL)" >&2
      else
        echo "WARN: $task: closing without a passing review (the handoff is still pending)" >&2
      fi
    fi
  fi
  if factory_on && ! task_state "$task" >/dev/null 2>&1; then
    die "done failed: $task has no ledger entries; claim it first"
  fi
  if factory_on; then
    # BR-009: a task of the normal lane closes from GREEN, which only advance reaches, after a
    # reviewed spec and failing tests. A task with no phase at all was claimed before the project
    # moved to Factory mode and is not held to it; the fast lane starts in GREEN.
    dn_state="$(task_state "$task" 2>/dev/null)" || dn_state=""
    dn_phase="$(printf '%s' "$dn_state" | cut -f12)"
    if [ -n "$dn_phase" ] && [ "$dn_phase" != "GREEN" ] && [ "$(printf '%s' "$dn_state" | cut -f18)" != "FAST" ]; then
      die "done failed: $task is in phase $dn_phase; a task of the normal lane closes from GREEN, after a reviewed spec and failing tests (advance moves it)"
    fi
  fi
  vlow="$(printf '%s' "$verify" | tr 'A-Z' 'a-z' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$vlow" in
    none|n/a|"no run"|ninguno|"—"|unknown)
      echo "WARN: verify \"$verify\" says nothing about what was checked" >&2 ;;
  esac
  DONE_USED=""
  DONE_LEARNED=""
  DONE_CROSS=""
  if factory_on; then
    retro_read "$task"
    DONE_CROSS="$(task_state "$task" 2>/dev/null | cut -f20)" || DONE_CROSS=""
  fi
  name="$(require_valid_name "$task" done)"
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  claim_ts="$(first_claim_ts "$task")"
  if [ -n "$claim_ts" ]; then
    gap="$(awk -v a="$claim_ts" -v b="$timestamp" "$AWK_EPOCH"'BEGIN { x=iso_epoch(a); y=iso_epoch(b); if (x<0 || y<0) print -1; else print y-x }')"
    if [ "$gap" -ge 0 ] && [ "$gap" -lt $(( MIN_WORK_MINUTES * 60 )) ]; then
      echo "WARN: $task was claimed and closed $(gap_label "$gap") apart; claim before the first edit so the work is visible while it happens" >&2
    fi
  fi
  {
    echo
    echo "## [$timestamp] | $agent | $task | DONE | $name"
    echo "- Summary: $summary"
    echo "- Files: $files"
    echo "- Verify: $verify"
    if factory_on; then echo "- Brain: used $DONE_USED; learned $DONE_LEARNED"; fi
    if factory_on && [ "$DONE_CROSS" = "NO" ]; then echo "- Cross-model: NO"; fi
  } >> "$DOCS_DIR/Agentslog.md"
  roadmap_remove_row_file "$task"
  features_add_capability "$task" "$summary" "$verify" "$timestamp"
  if factory_on; then
    brain_apply_hits "$DONE_USED" "$(printf '%s' "$timestamp" | cut -c1-10)"
    rm -f "$(working_memory_path "$task")"
  fi
  echo "project_docs done: $task closed"
}

cmd_status() {
  [ -f "$DOCS_DIR/Agentslog.md" ] || die "run init first"
  open_task_states | tr '\t' '\037' |
  while IFS="$US" read -r tid status agent ts pausecat conflict everdone name holder handoff review phase specpass red tests attempts struggled lane base cross audited pdetail rest; do
    [ -n "$tid" ] || continue
    hrs="$(age_hours "$ts")"
    reason="-"
    if [ "$status" = "PAUSE" ]; then reason="$pausecat"; fi
    stale=""
    if [ "$status" != "PAUSE" ] && [ "$status" != "ASSIGNED" ] && [ "$hrs" != "?" ] && [ "$hrs" -ge "$STALE_HOURS" ]; then
      stale=" (stale)"
    fi
    shown="$agent"
    if [ "$status" = "REVIEW" ]; then shown="$holder"; fi
    if factory_on; then
      sphase="${phase:-SPEC}"
      if [ "$status" = "REVIEW" ]; then sphase="REVIEW"; fi
      slane="${lane:-NORMAL}"
      printf '%s | %s | %s | %s | %sh%s | %s | %s %s\n' "$tid" "$name" "$shown" "$(stage_label "$status" "$review" "$handoff")" "$hrs" "$stale" "$reason" "$sphase" "$slane"
    else
      printf '%s | %s | %s | %s | %sh%s | %s\n' "$tid" "$name" "$shown" "$(stage_label "$status" "$review" "$handoff")" "$hrs" "$stale" "$reason"
    fi
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
      echo "| ID | Name | Severity | Phase | Description | Status | Owner | Depends on | Pause reason |"
      echo "|---|---|---|---|---|---|---|---|---|"
      echo "| — | — | — | — | — | — | — | — | — |"
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

# Non-destructive, idempotent: inserts a short "Name" column (<= 10 words;
# the rest of the detail stays in Description or the table's own free-text
# column) into every Roadmap table that doesn't have one yet. Detects each
# table's kind by its header (same convention as check_table_status_enum),
# not by position, so it runs after ensure_roadmap_sections has already
# normalized Active work's column count and also catches whatever shape
# roadmap_migrate_yaml_to_table just emitted, in the same migrate run:
#   - Active work / Plan task rows (Outcome + Owner): Outcome is preserved
#     verbatim as Description; Name is derived as its first 10 words.
#   - Near term rows (Outcome, no Owner): Outcome -> Name, renamed in place,
#     not truncated (no Description column there) -- a row whose old Outcome
#     exceeds 10 words will still fail check's word limit until shortened by
#     hand, same as any other flagged-for-review migration output.
#   - Gaps/Bugs/Technical Debt rows (Severity + Phase): Description is
#     preserved verbatim; Name is derived as its first 10 words.
# A table that already has a Name column, or has no ID column at all (not
# one of ours), passes through byte-for-byte.
roadmap_migrate_add_name_column() {
  file="$DOCS_DIR/Roadmap.md"
  [ -f "$file" ] || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-roadmap.XXXXXX")"
  awk '
    # Strips the leading/trailing table-row "|" before splitting, so c[1] is
    # the first real cell (never an empty field from before the leading
    # pipe) — every caller here passes a whole "| a | b |" line verbatim.
    function trimsplit(s, out,    n,i,c,line) {
      line=s
      sub(/^\|/,"",line); sub(/\|[ \t]*$/,"",line)
      n=split(line,c,"|")
      for (i=1;i<=n;i++) { t=c[i]; gsub(/^[ \t]+|[ \t]+$/,"",t); out[i]=t }
      return n
    }
    function first_n_words(s, n,    arr,cnt,i,out,lim) {
      cnt=split(s,arr,/[ \t]+/)
      lim=(cnt<n ? cnt : n)
      out=""
      for (i=1;i<=lim;i++) if (arr[i]!="") out=(out=="" ? arr[i] : out" "arr[i])
      if (out=="") out="UNKNOWN"
      return out
    }
    BEGIN { expect_header=1; expect_sep=0; state="none" }
    !/^\|/ { print; expect_header=1; expect_sep=0; next }
    expect_header {
      ncol=trimsplit($0,c)
      has_id=0; has_name=0; has_outcome=0; has_owner=0; has_sev=0; has_phase=0
      for (i=1;i<=ncol;i++) {
        if (c[i]=="ID") has_id=1
        if (c[i]=="Name") has_name=1
        if (c[i]=="Outcome") has_outcome=1
        if (c[i]=="Owner") has_owner=1
        if (c[i]=="Severity") has_sev=1
        if (c[i]=="Phase") has_phase=1
      }
      expect_header=0
      if (!has_id || has_name) { state="other"; print; next }
      if (has_outcome && has_owner) {
        state="task"
        print "| ID | Name | Description | Acceptance check | Status | Owner | Depends on | Pause reason |"
        expect_sep=1; next
      }
      if (has_outcome) {
        state="nearterm"
        print "| ID | Name | Acceptance check | Status | Depends on |"
        expect_sep=1; next
      }
      if (has_sev && has_phase) {
        state="gaps"
        print "| ID | Name | Severity | Phase | Description | Status | Owner | Depends on | Pause reason |"
        expect_sep=1; next
      }
      state="other"; print; next
    }
    expect_sep {
      expect_sep=0
      if (state=="task") { print "|---|---|---|---|---|---|---|---|"; next }
      if (state=="nearterm") { print "|---|---|---|---|---|"; next }
      if (state=="gaps") { print "|---|---|---|---|---|---|---|---|---|"; next }
      print; next
    }
    state=="task" {
      ncol=trimsplit($0,c)
      printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n", c[1], first_n_words(c[2],10), c[2], c[3], c[4], c[5], c[6], c[7]
      next
    }
    state=="nearterm" {
      ncol=trimsplit($0,c)
      printf "| %s | %s | %s | %s | %s |\n", c[1], c[2], c[3], c[4], c[5]
      next
    }
    state=="gaps" {
      ncol=trimsplit($0,c)
      printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", c[1], first_n_words(c[4],10), c[2], c[3], c[4], c[5], c[6], c[7], c[8]
      next
    }
    { print }
  ' "$file" > "$tmp"
  if cmp -s "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
  return 0
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
  mig_factory=0
  if [ "$#" -ge 2 ]; then shift 2; else shift "$#"; fi
  for mig_a in "$@"; do
    if [ "$mig_a" = "--factory" ]; then mig_factory=1; fi
  done
  variant="$(find_case_variant "$PROJECT" "AGENTS.md")"
  if [ -n "$variant" ] && [ "$variant" != "AGENTS.md" ]; then
    rename_case "$PROJECT/$variant" "$PROJECT/AGENTS.md"
    changed=$((changed + 1))
    echo "= renamed: $variant -> AGENTS.md"
  fi
  # Ensure base files (and a plain AGENTS.md block) exist first; the legacy
  # merge below runs last so its combined content is not clobbered by
  # init's own template-only block write.
  init_run classic
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
  if roadmap_migrate_add_name_column; then
    changed=$((changed + 1))
    echo "= converted: docs/Roadmap.md rows now have a Name column (derived from the"
    echo "  first 10 words of the prior Outcome/Description text; review each Name by"
    echo "  hand, including any Near term row that may still exceed 10 words)"
  fi
  if [ "$mig_factory" -eq 1 ]; then
    migrate_factory_additions
    changed=$((changed + mf_changed))
  fi
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
  cle_fac=0
  if factory_on; then cle_fac=1; fi
  out="$(awk -v stale_s="$((STALE_HOURS * 3600))" -v fac="$cle_fac" "$AWK_EPOCH"'
    $0 == "## Entries" { in_entries=1; next }
    in_entries && /^## \[/ {
      if (hdr != "") { validate() }
      hdr=$0
      line=$0
      sub(/^## \[/,"",line)
      sub(/\] \| /,"|",line)
      gsub(/ \| /,"|",line)
      split(line,f,"|")
      status=f[4]; tidnow=f[3]; agentnow=f[2]; name=f[5]; tsnow=f[1]
      if (status=="IN_PROGRESS" && last_status[tidnow]=="IN_PROGRESS" && last_agent[tidnow]!=agentnow) {
        print "ERROR: conflicting concurrent claim on " tidnow ": " last_agent[tidnow] " and " agentnow
      } else if (status=="IN_PROGRESS" && last_status[tidnow]=="REVIEW" && hold[tidnow]!="" && hold[tidnow]!=agentnow && !is_old(last_ts[tidnow], tsnow)) {
        # Two REVIEW entries by different agents (developer, reviewer) are
        # normal; only a third agent starting work on a task that is held by
        # someone else, and not stale, is a conflict.
        print "ERROR: conflicting concurrent claim on " tidnow ": " hold[tidnow] " and " agentnow
      }
      if (status=="IN_PROGRESS") hold[tidnow]=agentnow
      last_status[tidnow]=status
      last_agent[tidnow]=agentnow
      last_ts[tidnow]=tsnow
      pauseline=""
      verifyline=""
      summaryline=""
      handoffline=""
      reviewline=""
      assignline=""
      next
    }
    in_entries && /^- Pause:/ { pauseline=$0; next }
    in_entries && /^- Verify:/ { verifyline=$0; next }
    in_entries && /^- Summary:/ { summaryline=$0; next }
    in_entries && /^- Handoff:/ { handoffline=$0; next }
    in_entries && /^- Review:/ { reviewline=$0; next }
    in_entries && /^- Assign:/ { assignline=$0; next }
    END { if (hdr != "") validate() }
    function validate(   body,dash,cat,detail,rres,rdetail) {
      if (status!="IN_PROGRESS" && status!="PAUSE" && status!="DONE" && status!="REVIEW" && status!="ASSIGNED" && !(fac && status=="AUDIT")) {
        print "ERROR: invalid status in entry (expected IN_PROGRESS, PAUSE, REVIEW, ASSIGNED or DONE): " hdr
      }
      if (status=="ASSIGNED") {
        body=assignline
        sub(/^- Assign:[ \t]*/,"",body); gsub(/[ \t]+$/,"",body)
        if (assignline=="" || body=="") {
          print "ERROR: ASSIGNED entry missing Assign target: " hdr
        }
      }
      if (status=="REVIEW") {
        rres=""; rdetail=""
        if (reviewline!="") {
          body=reviewline
          sub(/^- Review:[ 	]*/,"",body)
          dash=index(body," - ")
          rres=(dash>0) ? substr(body,1,dash-1) : body
          rdetail=(dash>0) ? substr(body,dash+3) : ""
          gsub(/^[ 	]+|[ 	]+$/,"",rres); gsub(/^[ 	]+|[ 	]+$/,"",rdetail)
          if (rres!="PASS" && rres!="FAIL") {
            print "ERROR: REVIEW entry has invalid Review result (expected PASS or FAIL): " hdr
          }
          if (rdetail=="") {
            print "ERROR: REVIEW entry missing Review detail: " hdr
          }
        }
        body=summaryline
        sub(/^- Summary:[ 	]*/,"",body); gsub(/[ 	]+$/,"",body)
        if (summaryline=="" || body=="") {
          print "ERROR: REVIEW entry missing Summary: " hdr
        }
        # A handoff and a Review: PASS say what was verified; a Review: FAIL
        # may carry no Verify (the reviewer verified nothing that passed).
        if (verifyline=="") {
          if (rres!="FAIL") print "ERROR: REVIEW entry missing Verify line: " hdr
        } else {
          body=verifyline
          sub(/^- Verify:[ 	]*/,"",body); gsub(/[ 	]+$/,"",body)
          if (body=="" || body=="pending") {
            print "ERROR: REVIEW entry has empty or pending Verify: " hdr
          }
        }
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
      if (name!="") {
        wc=split(name,nw,/[ \t]+/)
        if (wc>10) print "ERROR: entry Name is " wc " words, over the 10-word limit: " hdr
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

# Every Roadmap table's row carries a short, descriptive Name (<= 10 words;
# the rest of the detail goes in Description or the table's own free-text
# column) in the column right after ID. Same per-table header detection as
# check_table_status_enum. A table that has an ID column but no Name column
# at all (not yet migrated) is reported once, by its header, rather than
# silently skipped.
check_table_name_wordlimit() {
  rel="$1"; max="$2"
  path="$PROJECT/$rel"
  [ -f "$path" ] || return 0
  out="$(awk -v max="$max" -v rel="$rel" '
    BEGIN { expect_header=1; namecol=0 }
    !/^\|/ { expect_header=1; next }
    /^\|/ {
      line=$0
      sub(/^\|/,"",line); sub(/\|[ \t]*$/,"",line)
      ncol=split(line,c,"|")
      for (i=1;i<=ncol;i++) gsub(/^[ \t]+|[ \t]+$/,"",c[i])
      if (expect_header) {
        idcol=0; namecol=0
        for (i=1;i<=ncol;i++) {
          if (c[i]=="ID") idcol=i
          if (c[i]=="Name") namecol=i
        }
        if (idcol>0 && namecol==0) {
          print "ERROR: " rel " table \"" $0 "\" has no Name column; run migrate"
        }
        expect_header=0
        next
      }
      id=c[1]
      if (id=="" || id=="—" || id ~ /^-+$/) next
      if (namecol>0 && namecol<=ncol) {
        nm=c[namecol]
        if (nm=="") {
          print "ERROR: " rel " row '\''" id "'\'' has an empty Name"
        } else {
          wc=split(nm,w,/[ \t]+/)
          if (wc>max) print "ERROR: " rel " row '\''" id "'\'' Name is " wc " words, over the " max "-word limit: " nm
        }
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

# For every ID that has a Name in docs/Roadmap.md, the most recent Agentslog
# entry that carried a Name for that ID must agree with it — claim/pause/done
# write the Roadmap Name into the log automatically, so a mismatch means
# either was hand-edited out of sync afterward. An entry with no Name field
# at all (pre-feature history, or an append-log entry) is not a mismatch.
check_agentslog_roadmap_names() {
  rn_file="$(mktemp "${TMPDIR:-/tmp}/project-docs-rmnames.XXXXXX")"
  roadmap_all_names > "$rn_file"
  out="$(all_task_states | awk -F'\t' -v rnf="$rn_file" '
    BEGIN { while ((getline line < rnf) > 0) { split(line,p,"\t"); rname[p[1]]=p[2] } }
    {
      tid=$1; lname=$8
      if (lname=="" ) next
      if ((tid in rname) && rname[tid]!=lname) {
        print "ERROR: " tid " Agentslog Name (\"" lname "\") does not match docs/Roadmap.md Name (\"" rname[tid] "\")"
      }
    }
  ')"
  rm -f "$rn_file"
  if [ -n "$out" ]; then
    printf '%s\n' "$out" >&2
    CHECK_FAIL=1
  fi
}

# Warns (never fails) about agent names in the hot ledger that are neither an
# Agent id nor an alias, at most 10 of them plus a count. Silent without a roster.
check_roster_names() {
  [ -f "$DOCS_DIR/Agentslog.md" ] || return 0
  rf="$(mktemp "${TMPDIR:-/tmp}/project-docs-roster.XXXXXX")"
  roster_rows > "$rf"
  if [ ! -s "$rf" ]; then rm -f "$rf"; return 0; fi
  awk -F'\t' '
    FNR==NR {
      known[tolower($1)]=1
      n=split($5,a,",")
      for (i=1;i<=n;i++) { x=a[i]; gsub(/^[ \t]+|[ \t]+$/,"",x); if (x!="" && x!="—") known[tolower(x)]=1 }
      next
    }
    $0=="## Entries" { in_e=1; next }
    in_e && /^## \[/ {
      line=$0
      sub(/^## \[/,"",line); sub(/\] \| /,"|",line); gsub(/ \| /,"|",line)
      split(line,f,"|")
      ag=f[2]
      if (!(tolower(ag) in known) && !(ag in seen)) { seen[ag]=1; order[++cnt]=ag }
    }
    END {
      for (i=1;i<=cnt && i<=10;i++) print "WARN: unknown agent \"" order[i] "\" in the ledger (not in the Agent identity table)"
      if (cnt>10) print "WARN: " (cnt-10) " more unknown agent name(s) in the ledger"
    }
  ' "$rf" "$DOCS_DIR/Agentslog.md" >&2
  rm -f "$rf"
}

# One summary line plus at most the 5 most recent tasks closed within
# PROJECT_DOCS_MIN_WORK_MINUTES (default 5) of their first claim. Closing a
# batch afterwards is legitimate: this only says so. Never fails.
check_instant_closes() {
  [ -f "$DOCS_DIR/Agentslog.md" ] || return 0
  awk -v min_s="$(( MIN_WORK_MINUTES * 60 ))" -v min_m="$MIN_WORK_MINUTES" "$AWK_EPOCH"'
    $0=="## Entries" { in_e=1; next }
    in_e && /^## \[/ {
      line=$0
      sub(/^## \[/,"",line); sub(/\] \| /,"|",line); gsub(/ \| /,"|",line)
      split(line,f,"|")
      ts=f[1]; tid=f[3]; st=f[4]
      if (st=="IN_PROGRESS" && !(tid in first)) first[tid]=ts
      if (st=="DONE" && (tid in first) && !(tid in counted)) {
        counted[tid]=1
        e1=iso_epoch(first[tid]); e2=iso_epoch(ts)
        if (e1>=0 && e2>=0) {
          closed++
          g=e2-e1
          if (g>=0 && g<min_s) { quick++; qid[quick]=tid; qgap[quick]=g }
        }
      }
    }
    END {
      if (quick>0) {
        print "WARN: " quick " of " closed " closed tasks were closed within " min_m " min of their claim"
        start=quick-4; if (start<1) start=1
        for (i=start;i<=quick;i++) {
          g=qgap[i]; lab=(g<60 ? g "s" : int(g/60) "m")
          print "WARN: " qid[i] " was claimed and closed " lab " apart; claim before the first edit so the work is visible while it happens"
        }
      }
    }
  ' "$DOCS_DIR/Agentslog.md" >&2
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
  check_roster_names
  check_instant_closes
  for name in $LINK_TARGETS_DEFAULT; do
    rel="$(link_target_path "$name")"
    full="$PROJECT/$rel"
    if [ -f "$full" ] && ! has_block "$full"; then
      echo "WARN: $rel has no project-documentation redirect block; run 'link'" >&2
    fi
  done
  if [ -f "$DOCS_DIR/Agentslog.md" ]; then
    # A REVIEW whose last entry says Review: FAIL is back with its holder, so
    # it is reported as IN_PROGRESS; a pending or passed REVIEW as REVIEW.
    stale_out="$(all_task_states | awk -F'\t' '
      $2=="IN_PROGRESS" { print $1"\t"$4"\tIN_PROGRESS" }
      $2=="REVIEW" { print $1"\t"$4"\t"($11=="FAIL" ? "IN_PROGRESS" : "REVIEW") }
    ')"
    if [ -n "$stale_out" ]; then
      printf '%s\n' "$stale_out" | while IFS="$TAB" read -r tid ts stage; do
        [ -n "$tid" ] || continue
        hrs="$(age_hours "$ts")"
        if [ "$hrs" != "?" ] && [ "$hrs" -ge "$STALE_HOURS" ]; then
          if [ "$stage" = "REVIEW" ]; then
            echo "WARN: $tid has been in REVIEW for ${hrs}h (>= ${STALE_HOURS}h)" >&2
          else
            echo "WARN: $tid has been IN_PROGRESS for ${hrs}h (>= ${STALE_HOURS}h)" >&2
          fi
        fi
      done
    fi
  fi
}

# Brain.md validation (Factory mode only, F06-E03-T01). One row per lesson; the
# vertical bar never appears inside a cell, so a row with a different column
# count is itself an error. The 047 escapes below are apostrophes.
check_brain_rows() {
  path="$DOCS_DIR/Brain.md"
  [ -f "$path" ] || return 0
  bm="$(factory_number "Brain max entries")"
  out="$(tr -d '\r' < "$path" | awk -v max="$bm" '
    $0=="## Entries" { insec=1; next }
    insec && /^## / { insec=0 }
    insec && /^\|/ {
      line=$0
      sub(/^\|/,"",line); sub(/\|[ \t]*$/,"",line)
      n=split(line,c,"|")
      for (i=1;i<=n;i++) gsub(/^[ \t]+|[ \t]+$/,"",c[i])
      id=c[1]
      if (id=="ID" || id ~ /^-+$/ || id=="—") next
      rows++
      pre="ERROR: docs/Brain.md row \047" id "\047 "
      if (n!=9) { print pre "has " (n == 0 ? 1 : n) " columns, expected 9"; next }
      if (id !~ /^LRN-[0-9][0-9][0-9]+$/) print pre "has invalid ID format (expected LRN-xxx)"
      if (id in seen) print "ERROR: docs/Brain.md duplicate ID: " id
      seen[id]=1
      if (c[2]=="") print pre "has an empty Name"
      else { wc=split(c[2],w,/[ \t]+/); if (wc>10) print pre "Name is " wc " words, over the 10-word limit" }
      k=c[3]
      if (k!="PITFALL" && k!="PATTERN" && k!="RECIPE" && k!="DEFAULT" && k!="MAP") print pre "has invalid Kind: " k
      if (c[4]=="") print pre "has an empty Trigger"
      if (c[5]=="") print pre "has an empty Lesson"
      if (c[6]=="") print pre "has an empty Evidence"
      if (c[7]!="CONFIRMED" && c[7]!="HYPOTHESIS") print pre "has invalid Status: " c[7]
      if (c[8] !~ /^[0-9]+$/) print pre "has invalid Hits: " c[8]
      if (c[9]!="—" && c[9] !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) print pre "has invalid Last used: " c[9]
      if (c[7]=="CONFIRMED" && c[8] ~ /^[0-9]+$/ && c[8] + 0 >= 5) print "WARN: docs/Brain.md row \047" id "\047 is CONFIRMED with " c[8] " hits; promote it to a rule in AGENTS.md, an ADR or a BR"
    }
    END { if (rows>max) print "ERROR: docs/Brain.md has " rows " entries, over the Brain max entries limit of " max }
  ')"
  if [ -n "$out" ]; then
    printf '%s\n' "$out" >&2
    if printf '%s\n' "$out" | grep -q '^ERROR:'; then CHECK_FAIL=1; fi
  fi
}

# Spec validation (Factory mode only, F06-E02-T01). A spec is docs/specs/<TASK-ID>.md
# (templates/Spec.md). Structure problems are errors; fields still UNKNOWN are
# one warning per spec, because a draft spec is normal during the SPEC phase.
# The 047 escapes below are apostrophes.
spec_report() {
  clean_stream < "$1" | awk -v id="$(basename "$1" .md)" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function err(m) { n++; msg[n] = "ERROR: docs/specs/" id ".md " m }
    NR==1 {
      t = "# Spec " id
      if (index($0, t) != 1 || (length($0) > length(t) && substr($0, length(t) + 1, 1) != " ")) err("title must start with \047" t "\047")
    }
    /UNKNOWN/ { unk++ }
    /^## / { sec=$0; seen[sec]=1; next }
    $0 == "<!-- context:end -->" { if (sec == "## Summary") marker=1; next }
    sec == "## Summary" && /^- Goal:/ { hasGoal=1; if (trim(substr($0, 8)) == "") err("has an empty Goal"); next }
    sec == "## Summary" && /^- Rules:/ { hasRules=1; if (trim(substr($0, 9)) == "") err("has empty Rules"); next }
    sec == "## Summary" && /^- Tags:/ { hasTags=1; if (trim(substr($0, 8)) == "") err("has empty Tags"); next }
    sec == "## Scenarios" && /^\|/ {
      line=$0; sub(/^\|/, "", line); sub(/\|[ \t]*$/, "", line)
      cn=split(line, c, "|")
      if (cn == 0) cn = 1
      for (i=1; i<=cn; i++) c[i]=trim(c[i])
      if (c[1] == "ID") {
        hdr=1
        if (cn != 6 || c[2] != "Given" || c[3] != "When" || c[4] != "Then" || c[5] != "Level" || c[6] != "Justification") err("has an invalid Scenarios header")
        next
      }
      if (c[1] ~ /^-+$/) next
      rows++
      sid=c[1]
      if (cn != 6) { err("scenario row \047" sid "\047 has " cn " columns, expected 6"); next }
      if (sid !~ /^S[0-9][0-9]+$/) err("scenario ID \047" sid "\047 is not S01 style")
      if (sid in scid) err("duplicate scenario ID: " sid)
      scid[sid]=1
      if (c[2] == "") err("scenario \047" sid "\047 has an empty Given")
      if (c[3] == "") err("scenario \047" sid "\047 has an empty When")
      if (c[4] == "") err("scenario \047" sid "\047 has an empty Then")
      lv=c[5]
      if (lv != "UNIT" && lv != "INTEGRATION" && lv != "CONTRACT" && lv != "E2E" && lv != "NONE") err("scenario \047" sid "\047 has invalid Level: " lv)
      else if (lv == "NONE" && (c[6] == "" || c[6] == "—")) err("scenario \047" sid "\047 has Level NONE without a Justification")
      next
    }
    sec == "## Tests" && /^- / { tn++; tl[tn]=$0; next }
    END {
      split("## Summary|## Scenarios|## Tests|## Out of scope", req, "|")
      for (i=1; i<=4; i++) if (!(req[i] in seen)) err("is missing section \047" req[i] "\047")
      if ("## Summary" in seen) {
        if (!hasGoal) err("Summary is missing \047- Goal:\047")
        if (!hasRules) err("Summary is missing \047- Rules:\047")
        if (!hasTags) err("Summary is missing \047- Tags:\047")
        if (!marker) err("has no \047<!-- context:end -->\047 marker inside ## Summary")
      }
      if ("## Scenarios" in seen) {
        if (!hdr) err("is missing the Scenarios header row")
        if (rows == 0) err("has no scenarios")
      }
      for (i=1; i<=tn; i++) {
        e=tl[i]
        if (e !~ /^- [^ ]+ \(S[0-9][0-9]+(, S[0-9][0-9]+)*\)$/) { err("Tests entry \047" substr(e, 3) "\047 is not \047- path (S01, S02)\047"); continue }
        p=substr(e, 3); path=p; sub(/ .*/, "", path)
        if (path ~ /^[\/\\]/ || path ~ /^[A-Za-z]:/ || path ~ /(^|[\/\\])\.\.([\/\\]|$)/) err("Tests entry \047" path "\047 must be a relative path inside the project (no absolute path, drive letter or .. segment)")
        r=p; sub(/^.* \(/, "", r); sub(/\)$/, "", r)
        k=split(r, refs, ", ")
        for (j=1; j<=k; j++) if (!(refs[j] in scid)) err("Tests entry \047" path "\047 refers to unknown scenario " refs[j])
      }
      for (i=1; i<=n; i++) print msg[i]
      if (unk > 0) print "WARN: docs/specs/" id ".md has " unk " UNKNOWN field(s)"
    }
  '
}

check_specs() {
  [ -d "$DOCS_DIR/specs" ] || return 0
  for cs_f in "$DOCS_DIR"/specs/*.md; do
    [ -f "$cs_f" ] || continue
    cs_out="$(spec_report "$cs_f")"
    [ -n "$cs_out" ] || continue
    printf '%s\n' "$cs_out" >&2
    if printf '%s\n' "$cs_out" | grep -q '^ERROR:'; then CHECK_FAIL=1; fi
  done
}

# Roster rules of Factory mode (F06-E02-T03): valid roles, at least two agents and
# one that can review. The 047 escapes below are apostrophes.
check_factory_roster() {
  cr_out="$(roster_rows | awk -F'\t' '
    NF == 0 { next }
    {
      n++; r=$4
      if (r != "SPEC" && r != "TEST" && r != "DEV" && r != "QA" && r != "OPS" && r != "BOTH" && r != "DEVELOPER") print "ERROR: Agent identity row \047" $1 "\047 has invalid Role: " r
      if (r == "QA" || r == "BOTH") qa=1
    }
    END {
      if (n < 2) print "ERROR: Agent identity needs at least 2 agents in Factory mode (found " n + 0 ")"
      if (!qa) print "ERROR: Agent identity needs an agent with role QA (or BOTH) in Factory mode"
    }
  ')"
  if [ -n "$cr_out" ]; then
    printf '%s\n' "$cr_out" >&2
    CHECK_FAIL=1
  fi
}

# Working memory validation (Factory mode only, F06-E03-T02): every file in
# docs/brain/tasks has the three sections and a well-formed ## Now.
# The 047 escapes below are apostrophes.
memory_report() {
  clean_stream < "$1" | awk -v id="$(basename "$1" .md)" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function err(m) { n++; msg[n] = "ERROR: docs/brain/tasks/" id ".md " m }
    NR==1 {
      t = "# Working memory " id
      if (index($0, t) != 1 || (length($0) > length(t) && substr($0, length(t) + 1, 1) != " ")) err("title must start with \047" t "\047")
    }
    /^## / { sec=$0; seen[sec]=1; next }
    sec == "## Now" && /^- Step:/ { hs=1; if (trim(substr($0, 8)) == "") err("Now has an empty Step"); next }
    sec == "## Now" && /^- Next:/ { hn=1; if (trim(substr($0, 8)) == "") err("Now has an empty Next"); next }
    sec == "## Now" && /^- Attempts:/ { ha=1; v=trim(substr($0, 12)); if (v !~ /^[0-9]+$/) err("Now has invalid Attempts: " v); next }
    sec == "## Now" && /^- Updated:/ { hu=1; v=trim(substr($0, 11)); if (v != "—" && v !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) err("Now has invalid Updated: " v); next }
    END {
      split("## Now|## Trail|## Retro", req, "|")
      for (i=1; i<=3; i++) if (!(req[i] in seen)) err("is missing section \047" req[i] "\047")
      if ("## Now" in seen) {
        if (!hs) err("Now is missing \047- Step:\047")
        if (!hn) err("Now is missing \047- Next:\047")
        if (!ha) err("Now is missing \047- Attempts:\047")
        if (!hu) err("Now is missing \047- Updated:\047")
      }
      for (i=1; i<=n; i++) print msg[i]
    }
  '
}

check_working_memory() {
  [ -d "$DOCS_DIR/brain/tasks" ] || return 0
  for cw_f in "$DOCS_DIR"/brain/tasks/*.md; do
    [ -f "$cw_f" ] || continue
    cw_out="$(memory_report "$cw_f")"
    [ -n "$cw_out" ] || continue
    printf '%s\n' "$cw_out" >&2
    CHECK_FAIL=1
  done
}

# A task in RED or GREEN of the normal lane has a spec without UNKNOWN fields (F06-E02-T06).
check_phase_specs() {
  cps_list="$(open_task_states | awk -F'\t' '($12 == "RED" || $12 == "GREEN") && $18 != "FAST" { print $1 " " $12 }')"
  [ -n "$cps_list" ] || return 0
  while IFS=' ' read -r cps_t cps_p; do
    [ -n "$cps_t" ] || continue
    if [ ! -f "$DOCS_DIR/specs/$cps_t.md" ]; then
      echo "ERROR: $cps_t is in phase $cps_p but docs/specs/$cps_t.md does not exist" >&2
      CHECK_FAIL=1
    else
      cps_unk="$(spec_unknown_count "$DOCS_DIR/specs/$cps_t.md")"
      if [ "$cps_unk" -gt 0 ]; then
        echo "ERROR: $cps_t is in phase $cps_p but docs/specs/$cps_t.md still has $cps_unk UNKNOWN field(s)" >&2
        CHECK_FAIL=1
      fi
    fi
  done <<EOF
$cps_list
EOF
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
  if factory_on; then
    need docs/Brain.md "## Operational summary" "<!-- context:end -->" "## Entries" "| ID | Name | Kind | Trigger | Lesson | Evidence | Status | Hits | Last used |"
  fi

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
    check_agentslog_roadmap_names
  fi

  check_id_format_in_section docs/ProductDescription.md "## Business rules" '^BR-[0-9][0-9][0-9]+$' "Business rules"
  check_id_format_in_section docs/Stack_Tecnologies.md "## Technical decisions (ADRs)" '^ADR-[0-9][0-9][0-9]+$' "Technical decisions"
  check_id_format_in_section docs/Roadmap.md "## Plan" '^F[0-9]' "Plan"
  check_table_status_enum docs/ProductDescription.md "CONFIRMED HYPOTHESIS UNKNOWN" "epistemic"
  check_table_status_enum docs/Stack_Tecnologies.md "CONFIRMED HYPOTHESIS UNKNOWN" "epistemic"
  check_table_status_enum docs/Roadmap.md "TODO IN_PROGRESS PAUSE DONE" "workflow"
  check_table_name_wordlimit docs/Roadmap.md 10
  if factory_on; then check_brain_rows; check_specs; check_factory_roster; check_working_memory; check_phase_specs; fi

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
    if brain_gc; then return; fi
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

  open_summary="$(open_task_states)"
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
    echo "## [YYYY-MM-DDTHH:mm:ssZ] | agent | TASK-ID | IN_PROGRESS | Name"
    echo "- Summary: what the agent will do or did"
    echo "- Files: paths or component names (optional)"
    echo "- Verify: command and result, or \"pending\" (required for DONE and REVIEW)"
    echo "- Pause: CATEGORY - detail (required for PAUSE)"
    echo "- Handoff: reviewer agent or role (optional, REVIEW)"
    echo "- Review: PASS|FAIL - detail (optional, REVIEW)"
    echo "- Assign: agent (required for ASSIGNED)"
    echo '```'
    echo
    echo "## Previous segment"
    echo
    echo "- Archive: \`docs/history/$archive_name\`"
    echo "- SHA-256: \`$archive_hash\`"
    echo
    echo "## Entries"
    if [ -n "$open_summary" ]; then
      printf '%s\n' "$open_summary" | tr '\t' '\037' | while IFS="$US" read -r tid status agent ts pausecat conflict everdone name holder handoff review phase specpass red tests attempts struggled lane base cross audited pdetail rest; do
        [ -n "$tid" ] || continue
        att_carry="${attempts:-0}"
        case "$review" in
          FAIL*) if [ "$status" = "REVIEW" ] && [ "$att_carry" -gt 0 ]; then att_carry=$((att_carry - 1)); fi ;;
        esac
        if [ "$status" = "REVIEW" ]; then
          # The developer who holds the task is not necessarily the agent of the
          # last entry (a reviewer wrote it), so re-open the holder first and
          # then the REVIEW entry with its handoff/review lines; otherwise done
          # by the holder would stop working after a rotation.
          echo
          echo "## [$ts] | $holder | $tid | IN_PROGRESS | $name"
          echo "- Summary: carried forward from docs/history/$archive_name at rotation"
          if [ -n "$phase" ]; then echo "- Phase: $phase"; fi
          if [ -n "$specpass" ]; then echo "- Spec-pass: $specpass"; fi
          rot_sha="$(spec_sha_of "$tid")"; if [ -n "$rot_sha" ]; then echo "- Spec-sha: $rot_sha"; fi
          if [ -n "$red" ]; then echo "- Red: $red"; fi
          if [ -n "$tests" ]; then echo "- Tests: $tests"; fi
          if [ "$att_carry" -gt 0 ]; then echo "- Attempts: $att_carry"; fi
          if [ "${struggled:-0}" = "1" ]; then echo "- Struggled: yes"; fi
          if [ -n "$lane" ]; then echo "- Lane: $lane"; fi
          if [ -n "$base" ]; then echo "- Base: $base"; fi
        fi
        echo
        echo "## [$ts] | $agent | $tid | $status | $name"
        echo "- Summary: carried forward from docs/history/$archive_name at rotation"
        if [ "$status" != "REVIEW" ] && [ -n "$phase" ]; then echo "- Phase: $phase"; fi
        if [ "$status" != "REVIEW" ] && [ -n "$specpass" ]; then echo "- Spec-pass: $specpass"; fi
        if [ "$status" != "REVIEW" ]; then rot_sha="$(spec_sha_of "$tid")"; if [ -n "$rot_sha" ]; then echo "- Spec-sha: $rot_sha"; fi; fi
        if [ "$status" != "REVIEW" ] && [ -n "$red" ]; then echo "- Red: $red"; fi
        if [ "$status" != "REVIEW" ] && [ -n "$tests" ]; then echo "- Tests: $tests"; fi
        if [ "$status" != "REVIEW" ] && [ "$att_carry" -gt 0 ]; then echo "- Attempts: $att_carry"; fi
        if [ "$status" != "REVIEW" ] && [ "${struggled:-0}" = "1" ]; then echo "- Struggled: yes"; fi
        if [ "$status" != "REVIEW" ] && [ -n "$lane" ]; then echo "- Lane: $lane"; fi
        if [ "$status" != "REVIEW" ] && [ -n "$base" ]; then echo "- Base: $base"; fi
        if [ "$status" = "PAUSE" ]; then
          if [ -n "$pdetail" ]; then echo "- Pause: $pausecat - $pdetail"; else echo "- Pause: $pausecat - see docs/history/$archive_name for detail"; fi
        fi
        if [ "$status" = "ASSIGNED" ]; then
          echo "- Assign: $holder"
        fi
        if [ "$status" = "REVIEW" ]; then
          echo "- Verify: carried forward from docs/history/$archive_name"
          if [ -n "$handoff" ]; then echo "- Handoff: $handoff"; fi
          if [ -n "$review" ]; then echo "- Review: $review - carried forward from docs/history/$archive_name"; fi
          if [ -n "$cross" ]; then echo "- Cross-model: $cross"; fi
        fi
      done
    fi
    # A closed task of the normal lane that one model reviewed and nobody audited yet stays in the
    # ledger as a DONE entry, so the audit queue of the preferred reviewer survives the rotation.
    # Only when a preferred reviewer is set (nobody else audits), and the 20 latest at most, so a
    # queue nobody works off cannot keep the ledger over its limit.
    if factory_on && [ -n "$(factory_setting "Preferred reviewer")" ]; then
      all_task_states | awk -F'\t' '$2 == "DONE" && $18 != "FAST" && $20 == "NO" && $21 + 0 == 0' | LC_ALL=C sort -t "$(printf '\t')" -k4,4 -k1,1 | tail -n 20 | tr '\t' '\037' | while IFS="$US" read -r tid status agent ts pausecat conflict everdone name holder handoff review phase specpass red tests attempts struggled lane base cross audited pdetail rest; do
        [ -n "$tid" ] || continue
        echo
        echo "## [$ts] | $agent | $tid | DONE | $name"
        echo "- Summary: carried forward from docs/history/$archive_name at rotation, still to be audited"
        echo "- Files: see docs/history/$archive_name"
        echo "- Verify: carried forward from docs/history/$archive_name"
        echo "- Cross-model: NO"
      done
    fi
  } > "$tmp"
  mv "$tmp" "$log"
  echo "project_docs rotate: archived $archive_name"
  brain_gc || true
}

case "$COMMAND" in
  init) init_docs "$@" ;;
  check) check_docs ;;
  context) build_context ;;
  append-log) append_log "$@" ;;
  rotate) rotate_log ;;
  migrate) migrate_docs "$@" ;;
  link) cmd_link "$@" ;;
  claim) cmd_claim "$@" ;;
  pause) cmd_pause "$@" ;;
  handoff) cmd_handoff "$@" ;;
  review) cmd_review "$@" ;;
  mode) cmd_mode ;;
  checkpoint) cmd_checkpoint "$@" ;;
  recall) cmd_recall "$@" ;;
  learn) cmd_learn "$@" ;;
  retro) cmd_retro "$@" ;;
  digest) cmd_digest "$@" ;;
  next) cmd_next "$@" ;;
  advance) cmd_advance "$@" ;;
  assign) cmd_assign "$@" ;;
  done) cmd_done "$@" ;;
  status) cmd_status ;;
  *)
    echo "Usage: project_docs.sh {init|check|context|append-log|rotate|migrate|link|claim|pause|handoff|review|assign|done|status|mode|checkpoint|advance|recall|learn|retro|next|digest} <project> [args]"
    ;;
esac
