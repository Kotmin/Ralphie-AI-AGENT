#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RALPH_DIR="$ROOT_DIR/scripts/ralph"
STATE_JSON="$ROOT_DIR/state.json"
PRD_MD="$ROOT_DIR/PRD.md"
PROGRESS_TXT="$ROOT_DIR/progress.txt"

# shellcheck source=lib.sh
source "$RALPH_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/ralph/ralph.sh [--iterations N] [--task-id US-XXX] [--force-new-task] [--no-worktree]

Defaults:
  --iterations N     default 10
Behavior:
  - Uses PRD.md checkboxes as source of truth for DONE.
  - Remembers current task in state.json to avoid bouncing between tasks mid-work.
EOF
}

ITERATIONS=10
TASK_ID=""
FORCE_NEW_TASK=0
NO_WORKTREE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations) ITERATIONS="${2:?}"; shift 2 ;;
    --task-id) TASK_ID="${2:?}"; shift 2 ;;
    --force-new-task) FORCE_NEW_TASK=1; shift ;;
    --no-worktree) NO_WORKTREE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

require_cmd git
require_cmd python3

detect_claude_cmd

ensure_files_exist "$PRD_MD" "$PROGRESS_TXT" "$STATE_JSON"
ensure_state_schema "$STATE_JSON"

# Resolve task:
if [[ -n "$TASK_ID" ]]; then
  :
else
  if [[ "$FORCE_NEW_TASK" -eq 1 ]]; then
    TASK_ID=""
  else
    TASK_ID="$(state_get "$STATE_JSON" '.current_task_id' || true)"
    if [[ -n "$TASK_ID" ]] && prd_task_is_done "$PRD_MD" "$TASK_ID"; then
      TASK_ID=""
    fi
  fi

  if [[ -z "$TASK_ID" ]]; then
    TASK_ID="$(prd_pick_next_task "$PRD_MD")"
  fi
fi

if [[ -z "$TASK_ID" ]]; then
  log "No remaining unchecked tasks found in PRD.md. Nothing to do."
  exit 0
fi

state_set "$STATE_JSON" ".current_task_id" "\"$TASK_ID\""
state_set "$STATE_JSON" ".status" "\"IN_PROGRESS\""
state_set "$STATE_JSON" ".last_event" "\"Selected task $TASK_ID\""

WORKTREE_DIR="$ROOT_DIR/.ralph/worktrees/$TASK_ID"
BRANCH_NAME="ralph/$TASK_ID"

if [[ "$NO_WORKTREE" -eq 1 ]]; then
  WORKDIR="$ROOT_DIR"
else
  prepare_worktree "$ROOT_DIR" "$WORKTREE_DIR" "$BRANCH_NAME"
  WORKDIR="$WORKTREE_DIR"
fi

log "Task: $TASK_ID"
log "Workdir: $WORKDIR"
log "Iterations: $ITERATIONS"
append_progress "$PROGRESS_TXT" "=== START $TASK_ID @ $(now_iso) ==="

for ((i=1; i<=ITERATIONS; i++)); do
  state_set "$STATE_JSON" ".iteration" "$i"
  state_set "$STATE_JSON" ".last_event" "\"Iteration $i\""

  # If already done (someone checked it off), stop early.
  if prd_task_is_done "$PRD_MD" "$TASK_ID"; then
    log "PRD shows $TASK_ID is DONE. Stopping."
    break
  fi

  PROMPT_FILE="$(mktemp)"
  trap 'rm -f "$PROMPT_FILE"' EXIT

    build_prompt \
    --out "$PROMPT_FILE" \
    --root "$ROOT_DIR" \
    --workdir "$WORKDIR" \
    --task "$TASK_ID" \
    --prd "$PRD_MD" \
    --progress "$PROGRESS_TXT" \
    --state "$STATE_JSON" \
    --questions "$ROOT_DIR/questions.md" \
    --answers "$ROOT_DIR/answers.md"


  log "Running Claude headless (fresh session) iteration=$i ..."
  set +e
  run_claude_headless "$WORKDIR" "$PROMPT_FILE"
  CLAUDE_RC=$?
  set -e

  if [[ "$CLAUDE_RC" -ne 0 ]]; then
    state_set "$STATE_JSON" ".status" "\"ERROR\""
    state_set "$STATE_JSON" ".last_event" "\"Claude exited non-zero: $CLAUDE_RC\""
    append_progress "$PROGRESS_TXT" "ERROR: Claude exited non-zero rc=$CLAUDE_RC @ $(now_iso)"
    maybe_notify "Ralph error on $TASK_ID (rc=$CLAUDE_RC)" "$PROGRESS_TXT"
    exit "$CLAUDE_RC"
  fi

  # Respect NEEDS_CLARIFICATION (Claude writes it)
  STATUS="$(state_get "$STATE_JSON" '.status' || true)"
  if [[ "$STATUS" == "NEEDS_CLARIFICATION" ]]; then
    log "Ralph paused: NEEDS_CLARIFICATION."
    append_progress "$PROGRESS_TXT" "PAUSE: NEEDS_CLARIFICATION @ $(now_iso)"
    maybe_notify "Ralph needs clarification for $TASK_ID" "$PROGRESS_TXT"
    exit 0
  fi

  if prd_task_is_done "$PRD_MD" "$TASK_ID"; then
    log "Task marked DONE in PRD.md."
    state_set "$STATE_JSON" ".status" "\"DONE\""
    state_set "$STATE_JSON" ".last_event" "\"PRD marked DONE\""
    append_progress "$PROGRESS_TXT" "=== DONE $TASK_ID @ $(now_iso) ==="
    maybe_notify "Ralph finished $TASK_ID" "$PROGRESS_TXT"
    # Auto-advance next task on next run; we keep current_task_id but it will be cleared next run.
    break
  fi

  append_progress "$PROGRESS_TXT" "Iteration $i completed @ $(now_iso)"
done

log "Done. Current state: $(state_get "$STATE_JSON" '.status' || echo UNKNOWN)"
