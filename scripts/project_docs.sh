#!/usr/bin/env sh
set -eu

COMMAND="${1:-help}"
PROJECT="${2:-.}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/../templates"
DOCS_DIR="$PROJECT/docs"
FILES="Agents.md Agentslog.md ProductDescription.md Stack_Tecnologies.md Roadmap.md Features.md"
CONTEXT_LIMIT=8192
LOG_BYTES_LIMIT=131072
LOG_ENTRIES_LIMIT=200

die() {
  echo "project_docs: $*" >&2
  exit 1
}

require_templates() {
  [ -d "$TEMPLATES_DIR" ] || die "templates directory not found: $TEMPLATES_DIR"
}

init_docs() {
  require_templates
  mkdir -p "$DOCS_DIR"
  created=0
  for file in $FILES; do
    if [ -f "$DOCS_DIR/$file" ]; then
      echo "= preserved: docs/$file"
    else
      cp "$TEMPLATES_DIR/$file" "$DOCS_DIR/$file"
      echo "+ created: docs/$file"
      created=$((created + 1))
    fi
  done
  echo "project_docs init: $created file(s) created"
}

extract_context_block() {
  file="$1"
  heading="$2"
  awk -v heading="$heading" '
    $0 == heading { active = 1 }
    active { print }
    active && /<!-- context:end -->/ { exit }
  ' "$file"
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

build_context() {
  [ -f "$DOCS_DIR/Agents.md" ] || die "run init first"
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-docs-context.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  {
    cat "$DOCS_DIR/Agents.md"
    echo
    extract_context_block "$DOCS_DIR/ProductDescription.md" "## Operational summary"
    echo
    extract_context_block "$DOCS_DIR/Stack_Tecnologies.md" "## Operational summary"
    echo
    extract_context_block "$DOCS_DIR/Features.md" "## Operational summary"
    echo
    extract_context_block "$DOCS_DIR/Roadmap.md" "## Active work"
    echo
    echo "## Latest agent entries"
    latest_log_entries
  } > "$tmp"
  bytes="$(wc -c < "$tmp" | tr -d ' ')"
  [ "$bytes" -le "$CONTEXT_LIMIT" ] ||
    die "hot context is ${bytes} bytes; compact summaries below ${CONTEXT_LIMIT}"
  cat "$tmp"
}

need() {
  file="$1"
  shift
  path="$DOCS_DIR/$file"
  if [ ! -f "$path" ]; then
    echo "MISSING: docs/$file" >&2
    CHECK_FAIL=1
    return
  fi
  for marker in "$@"; do
    if ! grep -qF -- "$marker" "$path"; then
      echo "INVALID docs/$file: missing '$marker'" >&2
      CHECK_FAIL=1
    fi
  done
}

check_docs() {
  CHECK_FAIL=0
  need Agents.md "## Repository rules" "## Startup" "## Close"
  need Agentslog.md "## Entry format" "## Entries"
  need ProductDescription.md "## Operational summary" "## Business rules"
  need Stack_Tecnologies.md "## Operational summary" "## Decisions"
  need Roadmap.md "## Active work" "## Near term"
  need Features.md "## Operational summary" "## Verified capabilities"

  if [ "$CHECK_FAIL" -eq 0 ] && ! build_context >/dev/null; then
    CHECK_FAIL=1
  fi

  if [ -f "$DOCS_DIR/Agentslog.md" ]; then
    log_bytes="$(wc -c < "$DOCS_DIR/Agentslog.md" | tr -d ' ')"
    log_entries="$(awk '
      $0 == "## Entries" { entries_section = 1; next }
      entries_section && /^## \[/ { count++ }
      END { print count + 0 }
    ' "$DOCS_DIR/Agentslog.md")"
    if [ "$log_bytes" -gt "$LOG_BYTES_LIMIT" ] ||
       [ "$log_entries" -gt "$LOG_ENTRIES_LIMIT" ]; then
      echo "ROTATE REQUIRED: Agentslog has ${log_entries} entries / ${log_bytes} bytes" >&2
      CHECK_FAIL=1
    fi
  fi

  if [ "$CHECK_FAIL" -eq 0 ]; then
    echo "project_docs check: OK"
  else
    die "check failed"
  fi
}

clean_field() {
  printf '%s' "$1" | tr '\r\n|' '   '
}

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
  log_entries="$(awk '
    $0 == "## Entries" { entries_section = 1; next }
    entries_section && /^## \[/ { count++ }
    END { print count + 0 }
  ' "$log")"
  if [ "$log_bytes" -le "$LOG_BYTES_LIMIT" ] &&
     [ "$log_entries" -le "$LOG_ENTRIES_LIMIT" ]; then
    echo "project_docs rotate: not required"
    return
  fi

  history="$DOCS_DIR/history"
  mkdir -p "$history"
  stamp="$(date -u +'%Y%m%d')"
  sequence=1
  while :; do
    suffix="$(printf '%03d' "$sequence")"
    archive="$history/Agentslog-$stamp-$suffix.md"
    [ -e "$archive" ] || break
    sequence=$((sequence + 1))
  done

  cp "$log" "$archive"
  source_hash="$(file_hash "$log")"
  archive_hash="$(file_hash "$archive")"
  [ "$source_hash" = "$archive_hash" ] || die "archive hash verification failed"

  tmp="$DOCS_DIR/.Agentslog.md.tmp.$$"
  {
    echo "# Agents log"
    echo
    echo "Recent append-only ledger. Older segments live in \`docs/history/\`."
    echo
    echo "## Entry format"
    echo
    echo '```markdown'
    echo "## [YYYY-MM-DDTHH:mm:ssZ] | agent | TASK-ID | DONE"
    echo "- Summary: observable outcome"
    echo "- Files: compact paths or component names"
    echo "- Verify: command and result"
    echo "- Follow-up: none or one pointer"
    echo '```'
    echo
    echo "## Previous segment"
    echo
    echo "- Archive: \`docs/history/$(basename "$archive")\`"
    echo "- SHA-256: \`$archive_hash\`"
    echo
    echo "## Entries"
  } > "$tmp"
  mv "$tmp" "$log"
  echo "project_docs rotate: archived $(basename "$archive")"
}

case "$COMMAND" in
  init) init_docs ;;
  check) check_docs ;;
  context) build_context ;;
  append-log) append_log "$@" ;;
  rotate) rotate_log ;;
  *)
    echo "Usage: project_docs.sh {init|check|context|append-log|rotate} <project> [args]"
    ;;
esac
