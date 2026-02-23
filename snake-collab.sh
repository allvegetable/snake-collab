#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
DEFAULT_MAX_ROUNDS=3
DEFAULT_CMD_TIMEOUT=300

usage() {
  cat <<USAGE
Usage:
  $SCRIPT_NAME "<task_description>" [max_rounds] [project_dir]
  $SCRIPT_NAME -t "<task_description>" [-m max_rounds] [-p project_dir]

Args:
  task_description   Required. Task for REX to implement.
  max_rounds         Optional. Default: ${DEFAULT_MAX_ROUNDS}
  project_dir        Optional. Default: current directory
USAGE
}

err() {
  echo "[ERROR] $*" >&2
}

info() {
  echo "[INFO] $*"
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    err "Missing required command: $cmd"
    exit 1
  }
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

extract_section() {
  local name="$1"
  local file="$2"
  awk -v key="$name" '
    BEGIN { capture=0 }
    $0 ~ "^" key ":[[:space:]]*" {
      capture=1
      sub("^" key ":[[:space:]]*", "", $0)
      print
      next
    }
    capture && $0 ~ "^[A-Z_]+:[[:space:]]*" { exit }
    capture { print }
  ' "$file"
}

TASK=""
MAX_ROUNDS="$DEFAULT_MAX_ROUNDS"
CMD_TIMEOUT="${SNAKE_COLLAB_TIMEOUT:-$DEFAULT_CMD_TIMEOUT}"
PROJECT_DIR="$(pwd)"

while getopts ":t:m:p:h" opt; do
  case "$opt" in
    t) TASK="$OPTARG" ;;
    m) MAX_ROUNDS="$OPTARG" ;;
    p) PROJECT_DIR="$OPTARG" ;;
    h)
      usage
      exit 0
      ;;
    :)
      err "Option -$OPTARG requires an argument"
      usage
      exit 1
      ;;
    \?)
      err "Invalid option: -$OPTARG"
      usage
      exit 1
      ;;
  esac
done
shift $((OPTIND - 1))

if [[ -z "$TASK" ]]; then
  if [[ $# -ge 1 ]]; then
    TASK="$1"
  fi
  if [[ $# -ge 2 ]]; then
    MAX_ROUNDS="$2"
  fi
  if [[ $# -ge 3 ]]; then
    PROJECT_DIR="$3"
  fi
fi

if [[ -z "${TASK:-}" ]]; then
  err "task_description is required"
  usage
  exit 1
fi

if ! [[ "$MAX_ROUNDS" =~ ^[1-9][0-9]*$ ]]; then
  err "max_rounds must be a positive integer, got: $MAX_ROUNDS"
  exit 1
fi

if [[ ! -d "$PROJECT_DIR" ]]; then
  err "project_dir does not exist: $PROJECT_DIR"
  exit 1
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
LOG_DIR="$PROJECT_DIR/.collab/logs"
mkdir -p "$LOG_DIR"

require_cmd git
require_cmd codex
require_cmd claude
require_cmd timeout
require_cmd md5sum

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  err "OPENAI_API_KEY is required for REX (codex)"
  exit 1
fi
if [[ -z "${OPENAI_BASE_URL:-}" ]]; then
  err "OPENAI_BASE_URL is required for REX (codex)"
  exit 1
fi
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  err "ANTHROPIC_API_KEY is required for MK2 (claude)"
  exit 1
fi
ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-https://your-anthropic-base-url}"

if ! git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  err "project_dir is not a git repository: $PROJECT_DIR"
  exit 1
fi

session_id="$(date +%Y%m%d-%H%M%S)-$(printf '%04x%04x' "$RANDOM" "$RANDOM")"
info "Session: $session_id"
info "Project: $PROJECT_DIR"
info "Max rounds: $MAX_ROUNDS"
info "Command timeout: ${CMD_TIMEOUT}s"

previous_issue_sig=""
repeat_count=0
review_feedback=""

for ((round=1; round<=MAX_ROUNDS; round++)); do
  ts="$(date +%Y%m%d-%H%M%S)"
  round_prefix="${session_id}-round${round}"
  round_log="$LOG_DIR/${round_prefix}.log"
  rex_out="$LOG_DIR/${round_prefix}.rex.out"
  rex_err="$LOG_DIR/${round_prefix}.rex.err"
  mk2_out="$LOG_DIR/${round_prefix}.mk2.out"

  info "Round $round/$MAX_ROUNDS"

  {
    echo "SESSION: $session_id"
    echo "ROUND: $round"
    echo "TIMESTAMP: $ts"
    echo "TASK: $TASK"
    echo "PROJECT_DIR: $PROJECT_DIR"
    echo "---"
  } > "$round_log"

  rex_prompt=$(cat <<EOF_REX
You are REX, coding in repository: $PROJECT_DIR.

Primary task:
$TASK

Constraints:
- Make focused changes only for this task.
- Keep edits production-safe and consistent with existing style.
- Run lightweight validation if possible and summarize what changed.
- Do not ask for permission; just implement.

If review feedback exists, address all of it:
$review_feedback
EOF_REX
)

  set +e
  (
    cd "$PROJECT_DIR"
    OPENAI_API_KEY="$OPENAI_API_KEY" \
    OPENAI_BASE_URL="$OPENAI_BASE_URL" \
    timeout "${CMD_TIMEOUT}s" codex exec --full-auto "$rex_prompt"
  ) >"$rex_out" 2>"$rex_err"
  rex_exit=$?
  set -e

  {
    echo "[REX_EXIT] $rex_exit"
    echo "[REX_STDOUT]"
    cat "$rex_out"
    echo
    echo "[REX_STDERR]"
    cat "$rex_err"
    echo
  } >> "$round_log"

  if [[ $rex_exit -ne 0 ]]; then
    if [[ $rex_exit -eq 124 ]]; then
      err "REX timed out in round $round after ${CMD_TIMEOUT}s. See $round_log"
    else
      err "REX failed in round $round (exit=$rex_exit). See $round_log"
    fi
  fi

  status_porcelain="$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=all -- . || true)"
  diff_stat="$(git -C "$PROJECT_DIR" diff --stat -- . || true)"
  key_diff="$(git -C "$PROJECT_DIR" diff --unified=0 -- . | sed -n '1,240p' || true)"

  if [[ -z "$(trim "$status_porcelain")" ]]; then
    info "No git diff after REX in round $round; stopping."
    {
      echo "[MK2_SKIPPED] No changes detected"
      echo "[RESULT] STOPPED_NO_CHANGES"
    } >> "$round_log"
    exit 1
  fi

  mk2_prompt=$(cat <<EOF_MK2
You are MK2 reviewer. Review fast and concise.

Task context:
$TASK

Round: $round / $MAX_ROUNDS

Review only these changes:
[git diff --stat]
$diff_stat

[key diff (truncated)]
$key_diff

Output format strictly:
STATUS: LGTM|NEEDS_WORK
ISSUES:
- <short issue 1>
- <short issue 2>
NEXT_TASK:
<single concise instruction for REX>

Rules:
- Use LGTM only if changes are clearly acceptable.
- Keep ISSUES and NEXT_TASK short and actionable.
- If LGTM, set ISSUES to "- None" and NEXT_TASK to "No further work".
EOF_MK2
)

  set +e
  (
    cd "$PROJECT_DIR"
    export ANTHROPIC_BASE_URL ANTHROPIC_API_KEY
    if [[ -n "${HTTPS_PROXY:-}" ]]; then
      export HTTPS_PROXY
    fi
    timeout "${CMD_TIMEOUT}s" claude -p --dangerously-skip-permissions "$mk2_prompt"
  ) >"$mk2_out" 2>>"$round_log"
  mk2_exit=$?
  set -e

  {
    echo "[MK2_EXIT] $mk2_exit"
    echo "[MK2_OUTPUT]"
    cat "$mk2_out"
    echo
  } >> "$round_log"

  if [[ $mk2_exit -ne 0 ]]; then
    if [[ $mk2_exit -eq 124 ]]; then
      err "MK2 review timed out in round $round after ${CMD_TIMEOUT}s. See $round_log"
    else
      err "MK2 review failed in round $round (exit=$mk2_exit). See $round_log"
    fi
    exit 1
  fi

  status_line="$(grep -E '^[[:space:]]*STATUS:[[:space:]]*' "$mk2_out" | head -n1 || true)"
  if [[ -z "$(trim "$status_line")" ]]; then
    err "MK2 output missing STATUS in round $round; fallback to NEEDS_WORK."
    status="NEEDS_WORK"
  else
    status_raw="${status_line#STATUS:}"
    status="$(trim "$status_raw")"
  fi

  issues="$(extract_section "ISSUES" "$mk2_out" | sed '/^[[:space:]]*$/d' || true)"
  next_task="$(extract_section "NEXT_TASK" "$mk2_out" | sed '/^[[:space:]]*$/d' || true)"

  if [[ -z "$(trim "$issues")" ]]; then
    issues="- None provided by MK2"
  fi
  if [[ -z "$(trim "$next_task")" ]]; then
    next_task="No next task provided by MK2"
  fi

  if [[ "$status" != "LGTM" && "$status" != "NEEDS_WORK" ]]; then
    err "Invalid MK2 STATUS in round $round: '$status'. See $mk2_out"
    exit 1
  fi

  if [[ "$status" == "LGTM" ]]; then
    info "MK2 result: LGTM. Collaboration complete in round $round."
    {
      echo "[FINAL_STATUS] LGTM"
      echo "[FINAL_ROUND] $round"
    } >> "$round_log"
    exit 0
  fi

  issue_sig="$(printf '%s\n%s' "$issues" "$next_task" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//' | md5sum | awk '{print $1}')"

  if [[ -n "$previous_issue_sig" && "$issue_sig" == "$previous_issue_sig" ]]; then
    repeat_count=$((repeat_count + 1))
  else
    repeat_count=0
    previous_issue_sig="$issue_sig"
  fi

  if [[ $repeat_count -ge 2 ]]; then
    err "Same issue repeated 2 consecutive rounds. Escalating and exiting."
    {
      echo "[FINAL_STATUS] ESCALATED_REPEATED_ISSUE"
      echo "[REPEATED_ISSUE_COUNT] $repeat_count"
      echo "[REPEATED_ISSUE_SIGNATURE] $issue_sig"
    } >> "$round_log"
    exit 2
  fi

  review_feedback=$(cat <<EOF_FEEDBACK
MK2 review says NEEDS_WORK.
Please fix exactly these issues:
$issues

Next task from MK2:
$next_task
EOF_FEEDBACK
)

  info "MK2 result: NEEDS_WORK. Feedback will be sent to REX next round."
  {
    echo "[STATUS] NEEDS_WORK"
    echo "[ISSUES]"
    echo "$issues"
    echo "[NEXT_TASK]"
    echo "$next_task"
  } >> "$round_log"
done

err "Reached max rounds ($MAX_ROUNDS) without LGTM."
exit 3
