#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RALPH_DIR="$ROOT_DIR/scripts/ralph"

TRACK_DIR="$ROOT_DIR/.ralph/tracking"
QUESTIONS_MD="$TRACK_DIR/questions.md"
ANSWERS_MD="$TRACK_DIR/answers.md"
STATE_JSON="$TRACK_DIR/state.json"
PRD_MD="$TRACK_DIR/PRD.md"
PROGRESS_TXT="$TRACK_DIR/progress.txt"

# Workspaces
WORKTREE_BASE="$ROOT_DIR/.ralph/worktrees"
LOG_BASE="$ROOT_DIR/.ralph/logs"

# shellcheck source=lib.sh
source "$RALPH_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/ralph/ralph.sh [options]

Core options:
  --iterations N         default 10 (max Claude invocations for this run)
  --batch-size N         default 5 (how many unchecked tasks to plan for this run)
  --task-id US-XXX       force a specific starting task (still plans a batch from there if possible)
  --force-new-task       ignore stored current_task_id
  --no-worktree          run in repo root instead of worktree (not recommended)

Observability:
  --timeout-sec N        per-iteration timeout (default 900)
  --heartbeat-sec N      heartbeat interval (default 15)
  --verbose              tail Claude log while running
  --dry-run              print actions but do not run Claude

Worktree lifecycle:
  --reset-worktree       remove and recreate worktree for this run branch
  --cleanup              remove worktree when run finishes successfully

Branching:
  --branch NAME          explicit branch name (skips auto naming)
  --branch-from-tasks 0|1   default 1 (try name like ralph/US-001-US-005 when clean)

Notes:
- Source of truth for DONE is the PRD checkbox in .ralph/tracking/PRD.md
- Tracking is synced into worktree at .ralph_tracking/ for Claude
EOF
}

ITERATIONS=10
BATCH_SIZE=5
TASK_ID=""
FORCE_NEW_TASK=0
NO_WORKTREE=0

TIMEOUT_SEC=900
HEARTBEAT_SEC=15
VERBOSE=0
DRY_RUN=0

RESET_WORKTREE=0
CLEANUP=0

BRANCH_NAME=""
BRANCH_FROM_TASKS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations) ITERATIONS="${2:?}"; shift 2 ;;
    --batch-size) BATCH_SIZE="${2:?}"; shift 2 ;;
    --task-id) TASK_ID="${2:?}"; shift 2 ;;
    --force-new-task) FORCE_NEW_TASK=1; shift ;;
    --no-worktree) NO_WORKTREE=1; shift ;;
    --timeout-sec) TIMEOUT_SEC="${2:?}"; shift 2 ;;
    --heartbeat-sec) HEARTBEAT_SEC="${2:?}"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --reset-worktree) RESET_WORKTREE=1; shift ;;
    --cleanup) CLEANUP=1; shift ;;
    --branch) BRANCH_NAME="${2:?}"; shift 2 ;;
    --branch-from-tasks) BRANCH_FROM_TASKS="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

require_cmd git
require_cmd python3
require_cmd mktemp
require_cmd date
require_cmd rsync

detect_claude_cmd

# Ensure tracking files exist (repo-local, gitignored)
mkdir -p "$TRACK_DIR"
ensure_tracking_files_exist "$TRACK_DIR"

ensure_state_schema "$STATE_JSON"

# Preflight: verify headless works and quota/auth is OK (cheap)
if [[ "$DRY_RUN" -eq 0 ]]; then
  log "Preflight: checking Claude headless availability..."
  if ! claude_preflight "$ROOT_DIR"; then
    log "Preflight failed (auth/quota?). Exiting early."
    exit 1
  fi
fi

# If user forces a task-id, we’ll honor it as starting task.
# Otherwise we load from state unless force-new-task.
if [[ -z "$TASK_ID" ]]; then
  if [[ "$FORCE_NEW_TASK" -eq 1 ]]; then
    TASK_ID=""
  else
    TASK_ID="$(state_get "$STATE_JSON" '.current_task_id' || true)"
    if [[ -n "$TASK_ID" ]] && prd_task_is_done "$PRD_MD" "$TASK_ID"; then
      TASK_ID=""
    fi
  fi
fi

# If still empty, pick next unchecked
if [[ -z "$TASK_ID" ]]; then
  TASK_ID="$(prd_pick_next_task "$PRD_MD")"
fi

if [[ -z "$TASK_ID" ]]; then
  log "No remaining unchecked tasks found in PRD. Nothing to do."
  exit 0
fi

# Plan batch (list of task IDs)
mapfile -t PLANNED_TASKS < <(prd_plan_tasks "$PRD_MD" "$TASK_ID" "$BATCH_SIZE")
if [[ "${#PLANNED_TASKS[@]}" -eq 0 ]]; then
  log "Could not plan tasks (PRD format?)."
  exit 2
fi

# Establish run_id if missing
RUN_ID="$(state_get "$STATE_JSON" '.run_id' || true)"
if [[ -z "$RUN_ID" || "$RUN_ID" == "\"\"" ]]; then
  RUN_ID="$(run_id_now)"
  state_set "$STATE_JSON" ".run_id" "\"$RUN_ID\""
fi

# Set planned tasks in state
state_set_json_array "$STATE_JSON" ".planned_tasks" "${PLANNED_TASKS[@]}"

# Determine branch name if not explicitly given
if [[ -z "$BRANCH_NAME" ]]; then
  if [[ "$BRANCH_FROM_TASKS" -eq 1 ]]; then
    BRANCH_NAME="$(branch_name_from_tasks "${PLANNED_TASKS[@]}")"
  fi
  if [[ -z "$BRANCH_NAME" ]]; then
    BRANCH_NAME="ralph/run-$RUN_ID"
  fi
fi

# One worktree per run branch
WORKTREE_DIR="$WORKTREE_BASE/$BRANCH_NAME"
WORKTREE_DIR="$(sanitize_worktree_path "$WORKTREE_DIR")"

# Possibly reset worktree if requested
if [[ "$RESET_WORKTREE" -eq 1 && "$NO_WORKTREE" -eq 0 ]]; then
  log "Resetting worktree: $WORKTREE_DIR"
  git_worktree_remove_safe "$ROOT_DIR" "$WORKTREE_DIR"
fi

state_set "$STATE_JSON" ".status" "\"IN_PROGRESS\""
state_set "$STATE_JSON" ".last_event" "\"Planned ${#PLANNED_TASKS[@]} tasks on branch $BRANCH_NAME\""
append_progress "$PROGRESS_TXT" "=== RUN_START run_id=$RUN_ID branch=$BRANCH_NAME @ $(now_iso) ==="

if [[ "$NO_WORKTREE" -eq 1 ]]; then
  WORKDIR="$ROOT_DIR"
else
  prepare_worktree "$ROOT_DIR" "$WORKTREE_DIR" "$BRANCH_NAME"
  WORKDIR="$WORKTREE_DIR"
fi

chmod -R u+rwX "$WORKDIR" 2>/dev/null || true

LOG_DIR="$LOG_BASE/$RUN_ID"
mkdir -p "$LOG_DIR"

log "Run ID: $RUN_ID"
log "Branch: $BRANCH_NAME"
log "Workdir: $WORKDIR"
log "Planned tasks: ${PLANNED_TASKS[*]}"
log "Iterations: $ITERATIONS | Batch size: $BATCH_SIZE"
log "Timeout/iter: ${TIMEOUT_SEC}s"

# Main loop: iterate Claude invocations, advancing tasks as PRD checkboxes are ticked.
for ((i=1; i<=ITERATIONS; i++)); do
  state_set "$STATE_JSON" ".iteration" "$i"
  state_set "$STATE_JSON" ".last_event" "\"Iteration $i\""

    # Determine current task: prefer state.current_task_id if it’s planned & not done.
  CUR_TASK="$(strip_json_string "$(state_get "$STATE_JSON" '.current_task_id' || true)")"

  NEED_PICK=0
  if [[ -z "$CUR_TASK" ]]; then
    NEED_PICK=1
  elif ! task_in_list "$CUR_TASK" "${PLANNED_TASKS[@]}"; then
    NEED_PICK=1
  elif prd_task_is_done "$PRD_MD" "$CUR_TASK"; then
    NEED_PICK=1
  fi

  if [[ "$NEED_PICK" -eq 1 ]]; then
    CUR_TASK="$(next_pending_planned_task "$PRD_MD" "${PLANNED_TASKS[@]}")"
    if [[ -z "$CUR_TASK" ]]; then
      log "All planned tasks appear DONE. Finishing run."
      break
    fi
    state_set "$STATE_JSON" ".current_task_id" "\"$CUR_TASK\""
  fi


  # Sync tracking into worktree as .ralph_tracking/
  sync_tracking_to_worktree "$TRACK_DIR" "$WORKDIR/.ralph_tracking"

  PROMPT_FILE="$(mktemp)"
  trap 'rm -f "$PROMPT_FILE"' EXIT

  build_prompt \
    --out "$PROMPT_FILE" \
    --root "$ROOT_DIR" \
    --workdir "$WORKDIR" \
    --task "$CUR_TASK" \
    --prd "$WORKDIR/.ralph_tracking/PRD.md" \
    --progress "$WORKDIR/.ralph_tracking/progress.txt" \
    --state "$WORKDIR/.ralph_tracking/state.json" \
    --questions "$WORKDIR/.ralph_tracking/questions.md" \
    --answers "$WORKDIR/.ralph_tracking/answers.md"

  LOG_FILE="$LOG_DIR/iter-$(printf '%03d' "$i")-$CUR_TASK.log"
  log "Iteration=$i task=$CUR_TASK starting. Log: $LOG_FILE"
  append_progress "$PROGRESS_TXT" "ITER_START: run_id=$RUN_ID task=$CUR_TASK iter=$i @ $(now_iso) log=$LOG_FILE"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] Would run Claude for iter=$i task=$CUR_TASK"
    continue
  fi

  set +e
  run_with_timeout_and_observability \
    --workdir "$WORKDIR" \
    --prompt-file "$PROMPT_FILE" \
    --log-file "$LOG_FILE" \
    --timeout-sec "$TIMEOUT_SEC" \
    --heartbeat-sec "$HEARTBEAT_SEC" \
    --verbose "$VERBOSE"
  CLAUDE_RC=$?
  set -e

  # Sync tracking back to root (source of truth)
  sync_tracking_from_worktree "$WORKDIR/.ralph_tracking" "$TRACK_DIR"

  # Fail-fast classifiers
  if log_contains_quota_limit "$LOG_FILE"; then
    state_set "$STATE_JSON" ".status" "\"RATE_LIMIT\""
    state_set "$STATE_JSON" ".last_event" "\"Quota/limit hit\""
    append_progress "$PROGRESS_TXT" "STOP: RATE_LIMIT run_id=$RUN_ID iter=$i @ $(now_iso)"
    maybe_notify "Ralph stopped: rate limit (run $RUN_ID)" "$PROGRESS_TXT"
    exit 0
  fi

  if log_contains_permission_denied "$LOG_FILE"; then
    state_set "$STATE_JSON" ".status" "\"PERMISSION_DENIED\""
    state_set "$STATE_JSON" ".last_event" "\"Permission denied (see log)\""
    append_progress "$PROGRESS_TXT" "STOP: PERMISSION_DENIED run_id=$RUN_ID iter=$i @ $(now_iso) log=$LOG_FILE"
    maybe_notify "Ralph blocked: permissions (run $RUN_ID)" "$PROGRESS_TXT"
    exit 0
  fi

  log "Iteration=$i finished rc=$CLAUDE_RC (task=$CUR_TASK)."
  append_progress "$PROGRESS_TXT" "ITER_END: run_id=$RUN_ID task=$CUR_TASK iter=$i rc=$CLAUDE_RC @ $(now_iso) log=$LOG_FILE"

  if [[ "$CLAUDE_RC" -ne 0 ]]; then
    state_set "$STATE_JSON" ".status" "\"ERROR\""
    state_set "$STATE_JSON" ".last_event" "\"Claude exited non-zero: $CLAUDE_RC\""
    append_progress "$PROGRESS_TXT" "ERROR: run_id=$RUN_ID task=$CUR_TASK rc=$CLAUDE_RC iter=$i @ $(now_iso)"
    maybe_notify "Ralph error (run $RUN_ID task $CUR_TASK rc=$CLAUDE_RC)" "$PROGRESS_TXT"
    exit "$CLAUDE_RC"
  fi

  STATUS="$(strip_json_string "$(state_get "$STATE_JSON" '.status' || true)")"
  if [[ "$STATUS" == "NEEDS_CLARIFICATION" ]]; then
    log "Paused: NEEDS_CLARIFICATION. Answer in $ANSWERS_MD."
    append_progress "$PROGRESS_TXT" "PAUSE: NEEDS_CLARIFICATION run_id=$RUN_ID task=$CUR_TASK iter=$i @ $(now_iso)"
    maybe_notify "Ralph needs clarification (run $RUN_ID task $CUR_TASK)" "$PROGRESS_TXT"
    exit 0
  fi

  # If current task got marked done, record it
  if prd_task_is_done "$PRD_MD" "$CUR_TASK"; then
    append_completed_task "$STATE_JSON" "$CUR_TASK"
    append_progress "$PROGRESS_TXT" "TASK_DONE: run_id=$RUN_ID task=$CUR_TASK @ $(now_iso)"
    log "Task $CUR_TASK marked DONE in PRD."
  fi
done

# Final status
if all_planned_tasks_done "$PRD_MD" "${PLANNED_TASKS[@]}"; then
  state_set "$STATE_JSON" ".status" "\"DONE\""
  state_set "$STATE_JSON" ".last_event" "\"All planned tasks done\""
  append_progress "$PROGRESS_TXT" "=== RUN_DONE run_id=$RUN_ID branch=$BRANCH_NAME @ $(now_iso) ==="
  maybe_notify "Ralph finished run $RUN_ID" "$PROGRESS_TXT"
else
  state_set "$STATE_JSON" ".status" "\"STOPPED\""
  state_set "$STATE_JSON" ".last_event" "\"Iterations exhausted or stopped\""
  append_progress "$PROGRESS_TXT" "=== RUN_STOP run_id=$RUN_ID branch=$BRANCH_NAME @ $(now_iso) ==="
fi

log "Run complete. State: $(strip_json_string "$(state_get "$STATE_JSON" '.status' || true)")"

# Optional cleanup
if [[ "$CLEANUP" -eq 1 && "$NO_WORKTREE" -eq 0 ]]; then
  log "Cleanup requested. Removing worktree: $WORKTREE_DIR"
  git_worktree_remove_safe "$ROOT_DIR" "$WORKTREE_DIR"
fi
