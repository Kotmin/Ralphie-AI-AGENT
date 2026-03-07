#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RALPH_DIR="$ROOT_DIR/ralph"

TRACK_DIR="${RALPH_TRACK_DIR:-$ROOT_DIR/.ralph/tracking}"

# Workspaces
WORKTREE_BASE="$ROOT_DIR/.ralph/worktrees"
LOG_BASE="$ROOT_DIR/.ralph/logs"

# shellcheck source=lib.sh
source "$RALPH_DIR/lib.sh"

# Load project config from ralph/ralph.yaml (sets RALPH_TEST_CMD, etc.)
load_project_config "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: ralph/ralph.sh [options]

Core options:
  --iterations N         default 3 (max Claude invocations for this run)
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
  --cleanup-on-fail      remove worktree even on failure
  --cleanup-stale N      remove Ralph worktrees older than N days (default 7)

Branching:
  --branch NAME          explicit branch name (skips auto naming)
  --branch-from-tasks 0|1   default 1 (try name like ralph/US-001-US-005 when clean)

Testing:
  --max-retries N        max test retries per task (default 3)
  --no-tests             skip test discovery and execution

Syncing:
  --sync                 fetch and ff-only pull before starting

Integration:
  --integrate            rebase and integrate changes when done
  --target-branch NAME   branch to integrate into (default: current branch at start)
  --tracking-dir PATH    override tracking directory (default: .ralph/tracking)

Notes:
- Source of truth for DONE is the PRD checkbox in .ralph/tracking/PRD.md
- Tracking is synced into worktree at .ralph_tracking/ for Claude
EOF
}

ITERATIONS=3
BATCH_SIZE=5
TASK_ID=""
FORCE_NEW_TASK=0
NO_WORKTREE=0
MODE="build"  # build | plan

TIMEOUT_SEC=900
HEARTBEAT_SEC=15
VERBOSE=0
DRY_RUN=0

RESET_WORKTREE=0
CLEANUP=0
CLEANUP_ON_FAIL=0
CLEANUP_STALE=0
STALE_DAYS=7

BRANCH_NAME=""
BRANCH_FROM_TASKS=1

# US-006: Test-and-fix loop settings
MAX_RETRIES=3
RUN_TESTS=1
SKIP_PREFLIGHT=0
MAX_NO_PROGRESS=2

# US-013: Safe sync settings
SYNC_BEFORE_RUN=0

# US-012: Integration settings
INTEGRATE_ON_DONE=0
INVOKED_BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations) ITERATIONS="${2:?}"; shift 2 ;;
    --batch-size) BATCH_SIZE="${2:?}"; shift 2 ;;
    --task-id) TASK_ID="${2:?}"; shift 2 ;;
    --force-new-task) FORCE_NEW_TASK=1; shift ;;
    --no-worktree) NO_WORKTREE=1; shift ;;
    --mode) MODE="${2:?}"; shift 2 ;;
    --timeout-sec) TIMEOUT_SEC="${2:?}"; shift 2 ;;
    --heartbeat-sec) HEARTBEAT_SEC="${2:?}"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --reset-worktree) RESET_WORKTREE=1; shift ;;
    --cleanup) CLEANUP=1; shift ;;
    --cleanup-on-fail) CLEANUP_ON_FAIL=1; shift ;;
    --cleanup-stale) CLEANUP_STALE=1; STALE_DAYS="${2:-7}"; shift 2 ;;
    --branch) BRANCH_NAME="${2:?}"; shift 2 ;;
    --branch-from-tasks) BRANCH_FROM_TASKS="${2:?}"; shift 2 ;;
    --max-retries) MAX_RETRIES="${2:?}"; shift 2 ;;
    --no-tests) RUN_TESTS=0; shift ;;
    --no-preflight) SKIP_PREFLIGHT=1; shift ;;
    --max-no-progress) MAX_NO_PROGRESS="${2:?}"; shift 2 ;;
    --sync) SYNC_BEFORE_RUN=1; shift ;;
    --integrate) INTEGRATE_ON_DONE=1; shift ;;
    --target-branch) INVOKED_BRANCH="${2:?}"; shift 2 ;;
    --tracking-dir) TRACK_DIR="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# Resolve prompt file from mode
case "$MODE" in
  plan)  RALPH_PROMPT_FILE="$RALPH_DIR/PROMPT_plan.md" ;;
  build) RALPH_PROMPT_FILE="$RALPH_DIR/PROMPT_build.md" ;;
  *)     echo "Unknown --mode: $MODE (use build or plan)" >&2; exit 2 ;;
esac

QUESTIONS_MD="$TRACK_DIR/questions.md"
ANSWERS_MD="$TRACK_DIR/answers.md"
STATE_JSON="$TRACK_DIR/state.json"
PRD_MD="$TRACK_DIR/PRD.md"
PROGRESS_TXT="$TRACK_DIR/progress.txt"

# US-012: Detect invoked branch if not specified
if [[ -z "$INVOKED_BRANCH" ]]; then
  INVOKED_BRANCH="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"
fi

# US-002: Command Capability Verification
# Verify all required commands before proceeding
if ! verify_required_commands; then
  echo "ERROR: Required commands missing. Cannot proceed." >&2
  exit 127
fi

detect_claude_cmd

# US-001: Repository State Scan (Bootstrap)
# Validates repo structure and creates .ralph directories if needed
if ! repo_scan_bootstrap "$ROOT_DIR"; then
  echo "ERROR: Repository scan failed. Cannot proceed." >&2
  exit 1
fi

# US-014: Cleanup stale worktrees if requested
if [[ "$CLEANUP_STALE" -eq 1 ]]; then
  cleanup_stale_worktrees "$ROOT_DIR" "$STALE_DAYS"
fi

# US-014: Detect orphan worktrees at startup
ORPHANS="$(detect_orphan_worktrees "$ROOT_DIR" 2>/dev/null || true)"
if [[ -n "$ORPHANS" ]]; then
  log "WARNING: Orphaned Ralph worktrees detected:"
  echo "$ORPHANS" | while IFS= read -r line; do log "  $line"; done
fi

# Ensure tracking files exist (repo-local, gitignored)
ensure_tracking_files_exist "$TRACK_DIR"

ensure_state_schema "$STATE_JSON"

# US-008: Check for clarification protocol - resume only if answers exist
PREV_STATUS="$(strip_json_string "$(state_get "$STATE_JSON" '.status' || true)")"
if [[ "$PREV_STATUS" == "NEEDS_CLARIFICATION" ]]; then
  log "Previous run requested clarification."
  # Check if answers.md has content beyond the header
  ANSWER_LINES="$(tail -n +2 "$ANSWERS_MD" 2>/dev/null | grep -v '^[[:space:]]*$' | wc -l)"
  if [[ "$ANSWER_LINES" -eq 0 ]]; then
    log "ERROR: No answers found in $ANSWERS_MD"
    log "Please add answers to the questions in $QUESTIONS_MD before resuming."
    exit 1
  fi
  log "Found answers - resuming execution."
  state_set "$STATE_JSON" ".status" "\"IN_PROGRESS\""
  state_set "$STATE_JSON" ".last_event" "\"Resumed after clarification\""
  append_progress "$PROGRESS_TXT" "RESUME: from NEEDS_CLARIFICATION @ $(now_iso)"
fi

# Preflight: verify headless works and quota/auth is OK (cheap)
if [[ "$DRY_RUN" -eq 0 && "$SKIP_PREFLIGHT" -eq 0 ]]; then
  log "Preflight: checking Claude headless availability..."
  if ! claude_preflight "$ROOT_DIR"; then
    log "Preflight failed (auth/quota?). Exiting early."
    exit 1
  fi
fi

# US-013: Optional safe sync before run
if [[ "$SYNC_BEFORE_RUN" -eq 1 ]]; then
  log "Syncing with remote (--sync requested)..."
  if ! safe_sync_branch "$ROOT_DIR"; then
    log "ERROR: Safe sync failed. Remote has diverged - manual resolution required."
    state_set "$STATE_JSON" ".status" "\"SYNC_CONFLICT\""
    state_set "$STATE_JSON" ".last_event" "\"Remote sync failed - ff-only not possible\""
    exit 1
  fi
fi

# If user forces a task-id, we'll honor it as starting task.
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

# US-003: If no unchecked tasks remain, set status to DONE
if [[ -z "$TASK_ID" ]]; then
  log "No remaining unchecked tasks found in PRD. Setting status to DONE."
  state_set "$STATE_JSON" ".status" "\"DONE\""
  state_set "$STATE_JSON" ".last_event" "\"All tasks completed\""
  append_progress "$PROGRESS_TXT" "=== ALL_TASKS_DONE @ $(now_iso) ==="
  exit 0
fi

# US-003: Write selected task to state immediately
state_set "$STATE_JSON" ".current_task_id" "\"$TASK_ID\""

# Plan batch (list of task IDs)
mapfile -t PLANNED_TASKS < <(prd_plan_tasks "$PRD_MD" "$TASK_ID" "$BATCH_SIZE")
if [[ "${#PLANNED_TASKS[@]}" -eq 0 ]]; then
  log "Could not plan tasks (PRD format?)."
  exit 2
fi

# Establish run_id if missing or invalid ("null" from JSON null, empty, or quoted empty)
RUN_ID="$(state_get "$STATE_JSON" '.run_id' || true)"
if [[ -z "$RUN_ID" || "$RUN_ID" == "\"\"" || "$RUN_ID" == "null" ]]; then
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
state_set "$STATE_JSON" ".branch" "\"$BRANCH_NAME\""
state_set "$STATE_JSON" ".last_event" "\"Planned ${#PLANNED_TASKS[@]} tasks on branch $BRANCH_NAME\""
append_progress "$PROGRESS_TXT" "=== RUN_START run_id=$RUN_ID branch=$BRANCH_NAME @ $(now_iso) ==="

if [[ "$NO_WORKTREE" -eq 1 ]]; then
  WORKDIR="$ROOT_DIR"
  state_set "$STATE_JSON" ".worktree_path" "\"(none - running in root)\""
else
  prepare_worktree "$ROOT_DIR" "$WORKTREE_DIR" "$BRANCH_NAME"
  WORKDIR="$WORKTREE_DIR"
  # US-004: Record worktree path in state for observability
  state_set "$STATE_JSON" ".worktree_path" "\"$WORKTREE_DIR\""
  # US-014: Register worktree ownership
  register_worktree "$ROOT_DIR" "$WORKTREE_DIR" "$RUN_ID" "$BRANCH_NAME"
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
log "Max retries: $MAX_RETRIES | Run tests: $RUN_TESTS"

# US-006: Track retry counts per task
declare -A TASK_RETRIES
declare -A TASK_NO_PROGRESS

# Determine test command: prefer ralph.yaml config, fall back to auto-discovery
TEST_CMD=""
if [[ "$RUN_TESTS" -eq 1 ]]; then
  if [[ -n "${RALPH_TEST_CMD:-}" ]]; then
    TEST_CMD="$RALPH_TEST_CMD"
    log "Test command (from ralph.yaml): $TEST_CMD"
  else
    TEST_CMD="$(discover_test_command "$WORKDIR" "$PRD_MD" "")"
    if [[ -n "$TEST_CMD" ]]; then
      log "Discovered test command: $TEST_CMD"
    else
      log "No test command discovered - tests will be skipped"
    fi
  fi
fi

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
    --answers "$WORKDIR/.ralph_tracking/answers.md" \
    --skill-prompt "$RALPH_PROMPT_FILE"

  LOG_FILE="$LOG_DIR/iter-$(printf '%03d' "$i")-$CUR_TASK.log"
  log "Iteration=$i task=$CUR_TASK starting. Log: $LOG_FILE"
  append_progress "$PROGRESS_TXT" "ITER_START: run_id=$RUN_ID task=$CUR_TASK iter=$i @ $(now_iso) log=$LOG_FILE"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] Would run Claude for iter=$i task=$CUR_TASK"
    continue
  fi

  PREV_SHA="$(git -C "$WORKDIR" rev-parse HEAD 2>/dev/null || true)"

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

  # No-op detection: if Claude produced no commits and no uncommitted changes,
  # auto-advance after MAX_NO_PROGRESS consecutive idle iterations.
  if ! prd_task_is_done "$PRD_MD" "$CUR_TASK"; then
    CUR_SHA="$(git -C "$WORKDIR" rev-parse HEAD 2>/dev/null || true)"
    WORKDIR_DIRTY="$(git -C "$WORKDIR" status --porcelain 2>/dev/null || true)"
    if [[ "$CUR_SHA" == "$PREV_SHA" && -z "$WORKDIR_DIRTY" ]]; then
      TASK_NO_PROGRESS["$CUR_TASK"]=$(( ${TASK_NO_PROGRESS["$CUR_TASK"]:-0} + 1 ))
      NOP="${TASK_NO_PROGRESS[$CUR_TASK]}"
      log "Task $CUR_TASK: no changes iter=$i (no-op $NOP/$MAX_NO_PROGRESS)"
      append_progress "$PROGRESS_TXT" "NO_PROGRESS: run_id=$RUN_ID task=$CUR_TASK nop=$NOP/$MAX_NO_PROGRESS @ $(now_iso)"
      if [[ "$NOP" -ge "$MAX_NO_PROGRESS" ]]; then
        log "Task $CUR_TASK: auto-advancing after $NOP no-op iterations"
        prd_mark_task_done "$PRD_MD" "$CUR_TASK"
        append_completed_task "$STATE_JSON" "$CUR_TASK"
        append_progress "$PROGRESS_TXT" "AUTO_DONE: run_id=$RUN_ID task=$CUR_TASK (no-op x$NOP) @ $(now_iso)"
        TASK_NO_PROGRESS["$CUR_TASK"]=0
      fi
    else
      TASK_NO_PROGRESS["$CUR_TASK"]=0
    fi
  fi

  # US-006: Run tests if task appears done and tests are available
  if prd_task_is_done "$PRD_MD" "$CUR_TASK"; then
    if [[ -n "$TEST_CMD" && "$RUN_TESTS" -eq 1 ]]; then
      log "Task $CUR_TASK marked done - running tests..."
      TEST_LOG="$LOG_DIR/iter-$(printf '%03d' "$i")-$CUR_TASK-tests.log"

      if run_test_command "$WORKDIR" "$TEST_CMD" "$TEST_LOG"; then
        # Tests passed - verify commit discipline (US-009)
        verify_commit_discipline "$WORKDIR" "$CUR_TASK" || true
        verify_clean_git_status "$WORKDIR" || true
        # Task is truly done
        append_completed_task "$STATE_JSON" "$CUR_TASK"
        append_progress "$PROGRESS_TXT" "TASK_DONE: run_id=$RUN_ID task=$CUR_TASK (tests passed) @ $(now_iso)"
        log "Task $CUR_TASK completed with passing tests."
        TASK_RETRIES["$CUR_TASK"]=0
      else
        # Tests failed - increment retry counter
        TASK_RETRIES["$CUR_TASK"]=$((${TASK_RETRIES["$CUR_TASK"]:-0} + 1))
        RETRY_COUNT="${TASK_RETRIES["$CUR_TASK"]}"
        append_progress "$PROGRESS_TXT" "TEST_FAIL: run_id=$RUN_ID task=$CUR_TASK retry=$RETRY_COUNT/$MAX_RETRIES @ $(now_iso)"

        if [[ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]]; then
          # Max retries exceeded - stop
          state_set "$STATE_JSON" ".status" "\"TEST_FAILURE\""
          state_set "$STATE_JSON" ".last_event" "\"Tests failed after $MAX_RETRIES retries for $CUR_TASK\""
          append_progress "$PROGRESS_TXT" "STOP: TEST_FAILURE run_id=$RUN_ID task=$CUR_TASK retries=$RETRY_COUNT @ $(now_iso)"
          log "ERROR: Tests failed after $MAX_RETRIES retries for task $CUR_TASK"
          maybe_notify "Ralph test failure (run $RUN_ID task $CUR_TASK)" "$PROGRESS_TXT"
          exit 1
        else
          # Unmark task as done (Claude marked it prematurely) - it will retry
          log "Tests failed (retry $RETRY_COUNT/$MAX_RETRIES) - will retry task $CUR_TASK"
          # Note: We don't unmark in PRD - Claude should see the failure context next iteration
        fi
      fi
    else
      # No tests to run - verify commit discipline (US-009)
      verify_commit_discipline "$WORKDIR" "$CUR_TASK" || true
      verify_clean_git_status "$WORKDIR" || true
      # Task is done
      append_completed_task "$STATE_JSON" "$CUR_TASK"
      append_progress "$PROGRESS_TXT" "TASK_DONE: run_id=$RUN_ID task=$CUR_TASK (no tests) @ $(now_iso)"
      log "Task $CUR_TASK marked DONE in PRD."
    fi
  fi
done

# Final status
if all_planned_tasks_done "$PRD_MD" "${PLANNED_TASKS[@]}"; then
  state_set "$STATE_JSON" ".status" "\"DONE\""
  state_set "$STATE_JSON" ".last_event" "\"All planned tasks done\""
  append_progress "$PROGRESS_TXT" "=== RUN_DONE run_id=$RUN_ID branch=$BRANCH_NAME @ $(now_iso) ==="

  # US-012: Integration on completion
  if [[ "$INTEGRATE_ON_DONE" -eq 1 && "$NO_WORKTREE" -eq 0 ]]; then
    log "Integrating changes into $INVOKED_BRANCH..."
    if integrate_with_rebase "$WORKDIR" "$INVOKED_BRANCH" "$TEST_CMD"; then
      if finalize_integration "$ROOT_DIR" "$WORKDIR" "$INVOKED_BRANCH"; then
        append_progress "$PROGRESS_TXT" "INTEGRATED: run_id=$RUN_ID into $INVOKED_BRANCH @ $(now_iso)"
        log "Integration successful"
      else
        state_set "$STATE_JSON" ".status" "\"INTEGRATION_FAILED\""
        state_set "$STATE_JSON" ".last_event" "\"Failed to finalize integration\""
        append_progress "$PROGRESS_TXT" "INTEGRATION_FAILED: run_id=$RUN_ID @ $(now_iso)"
        log "ERROR: Integration failed"
      fi
    else
      state_set "$STATE_JSON" ".status" "\"REBASE_CONFLICT\""
      state_set "$STATE_JSON" ".last_event" "\"Rebase conflict - manual resolution required\""
      append_progress "$PROGRESS_TXT" "REBASE_CONFLICT: run_id=$RUN_ID @ $(now_iso)"
      log "ERROR: Rebase conflict - manual resolution required"
    fi
  fi

  maybe_notify "Ralph finished run $RUN_ID" "$PROGRESS_TXT"
else
  state_set "$STATE_JSON" ".status" "\"STOPPED\""
  state_set "$STATE_JSON" ".last_event" "\"Iterations exhausted or stopped\""
  append_progress "$PROGRESS_TXT" "=== RUN_STOP run_id=$RUN_ID branch=$BRANCH_NAME @ $(now_iso) ==="
fi

FINAL_STATUS="$(strip_json_string "$(state_get "$STATE_JSON" '.status' || true)")"
log "Run complete. State: $FINAL_STATUS"

# US-014: Worktree cleanup logic
if [[ "$NO_WORKTREE" -eq 0 ]]; then
  SHOULD_CLEANUP=0

  # Cleanup on success
  if [[ "$CLEANUP" -eq 1 && "$FINAL_STATUS" == "DONE" ]]; then
    SHOULD_CLEANUP=1
  fi

  # Cleanup on failure (if explicitly requested)
  if [[ "$CLEANUP_ON_FAIL" -eq 1 && "$FINAL_STATUS" != "DONE" ]]; then
    SHOULD_CLEANUP=1
  fi

  if [[ "$SHOULD_CLEANUP" -eq 1 ]]; then
    log "Cleanup: Removing worktree $WORKTREE_DIR"
    git_worktree_remove_safe "$ROOT_DIR" "$WORKTREE_DIR"
    unregister_worktree "$ROOT_DIR" "$WORKTREE_DIR"
    append_progress "$PROGRESS_TXT" "CLEANUP: worktree=$WORKTREE_DIR @ $(now_iso)"
  else
    log "Worktree preserved at: $WORKTREE_DIR"
  fi
fi
