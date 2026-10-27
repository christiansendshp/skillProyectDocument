#!/usr/bin/env sh
# fake_cli.sh <prompt-file>
#
# A stand-in for the claude and gemini CLIs in the dispatcher tests: it never touches a real
# quota. It reads one line per run from the file named by FAKE_CLI_SCRIPT, the first line that
# starts with "<agent>: " where the agent is FACTORY_AGENT (the dispatcher exports it), and
# removes that line. A line is a list of actions separated by " ;; ":
#
#   ok:<command of project_docs>   the project argument is added after the command, for example
#                                  ok:handoff claude-dev F01-E01-T01 "done" exit=0 gemini-qa
#   tryok:<command of project_docs> the same, but a failure does not end the line
#   exec:<command line>            runs a command in the project (a test, sed...); its exit code
#                                  is the value of {EXIT} in the actions that follow
#   write:<path>=<text>            writes a file in the project; \n in the text is a new line
#   git:<arguments>                runs git in the project
#   limit:<text>                   prints the text and exits 1, like a CLI that hit its quota
#   fail:<text>                    prints the text on stderr and exits 1
#
# Arguments are plain words or "double quoted" strings, so the same line works in fake_cli.ps1.
# A run with no line left for its agent exits 3. FAKE_CLI_LOG, if set, gets one line per run.
set -u

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CORE="$HERE/../project_docs.sh"
AGENT="${FACTORY_AGENT:-}"
TASK="${FACTORY_TASK:-}"
PROJECT="${FACTORY_PROJECT:-.}"
SCRIPT="${FAKE_CLI_SCRIPT:-}"

if [ -z "$SCRIPT" ] || [ ! -f "$SCRIPT" ]; then
  echo "fake_cli: FAKE_CLI_SCRIPT does not name a file" >&2
  exit 3
fi
line="$(awk -v a="$AGENT" 'index($0, a ": ") == 1 { print substr($0, length(a) + 3); exit }' "$SCRIPT")"
if [ -z "$line" ]; then
  echo "fake_cli: no action left for $AGENT" >&2
  exit 3
fi
awk -v a="$AGENT" 'index($0, a ": ") == 1 && !done { done = 1; next } { print }' "$SCRIPT" > "$SCRIPT.tmp" && mv "$SCRIPT.tmp" "$SCRIPT"
if [ -n "${FAKE_CLI_LOG:-}" ]; then printf '%s %s %s\n' "$AGENT" "$TASK" "$line" >> "$FAKE_CLI_LOG"; fi

actions="$(printf '%s\n' "$line" | awk '{ n = split($0, a, / ;; /); for (i = 1; i <= n; i++) print a[i] }')"
printf '%s\n' "$actions" | while IFS= read -r act; do
  kind="${act%%:*}"
  payload="${act#*:}"
  payload="$(printf '%s' "$payload" | sed "s/{EXIT}/${last_exit:-0}/g")"
  case "$kind" in
    ok|tryok)
      cmd="${payload%% *}"
      rest=""
      case "$payload" in *" "*) rest="${payload#* }" ;; esac
      if eval "sh \"\$CORE\" \"\$cmd\" \"\$PROJECT\" $rest"; then rc=0; else rc=$?; fi
      if [ "$kind" = "tryok" ]; then last_exit=$rc; elif [ "$rc" -ne 0 ]; then exit 1; fi
      ;;
    exec)
      if ( cd "$PROJECT" && eval "$payload" ); then last_exit=0; else last_exit=$?; fi
      ;;
    write)
      path="${payload%%=*}"
      text="${payload#*=}"
      mkdir -p "$(dirname "$PROJECT/$path")"
      printf '%b\n' "$text" > "$PROJECT/$path"
      ;;
    git)
      eval "git -C \"\$PROJECT\" $payload" || exit 1
      ;;
    limit)
      printf '%s\n' "$payload"
      exit 1
      ;;
    fail)
      printf '%s\n' "${payload:-fake_cli: failed}" >&2
      exit 1
      ;;
    *)
      echo "fake_cli: unknown action $kind" >&2
      exit 2
      ;;
  esac
done
