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

# shellcheck source=lib.sh
source "$RALPH_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/ralph/ralph.sh [options]

Options:
  --iterations N         default 10
  --task-id US-XXX       force a specific task
  --force-new-task       ignore stored current_task_id
  --no-worktree          run in repo root instead of worktree
  --timeout-sec N        per-iteration timeout (default 900)
  --heartbeat-sec N      heartbeat interval (default 15)
  --verbose              tail Claude log while running
  --dry-run              print actions but do not run Claude
EOF
}



ITERATIONS=10
TASK_ID=""
FORCE_NEW_TASK=0
NO_WORKTREE=0
TIMEOUT_SEC=900
HEARTBEAT_SEC=15
VERBOSE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations) ITERATIONS="${2:?}"; shift 2 ;;
    --task-id) TASK_ID="${2:?}"; shift 2 ;;
    --force-new-task) FORCE_NEW_TASK=1; shift ;;
    --no-worktree) NO_WORKTREE=1; shift ;;
    --timeout-sec) TIMEOUT_SEC="${2:?}"; shift 2 ;;
    --heartbeat-sec) HEARTBEAT_SEC="${2:?}"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
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
[[ -f "$PRD_MD" ]] || printf "# PRD\n\n## User Stories\n\n### [ ] US-001: <Title>\n" >"$PRD_MD"
[[ -f "$PROGRESS_TXT" ]] || printf "# Ralph Progress Log (append-only)\n" >"$PROGRESS_TXT"
[[ -f "$STATE_JSON" ]] || printf '{ "current_task_id": "", "iteration": 0, "status": "IDLE", "last_event": "", "questions": [] }\n' >"$STATE_JSON"
[[ -f "$QUESTIONS_MD" ]] || printf "# Questions for User\n" >"$QUESTIONS_MD"
[[ -f "$ANSWERS_MD" ]] || printf "# Answers\n" >"$ANSWERS_MD"

ensure_state_schema "$STATE_JSON"

# Preflight: verify headless works and quota/auth is OK (cheap)
if [[ "$DRY_RUN" -eq 0 ]]; then
  log "Preflight: checking Claude headless availability..."
  if ! claude_preflight "$ROOT_DIR"; then
    log "Preflight failed (auth/quota?). Exiting early."
    exit 1
  fi
fi

# Resolve task from tracking PRD/state
if [[ -z "$TASK_ID" ]]; then
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
  log "No remaining unchecked tasks found in PRD. Nothing to do."
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

# Ensure worktree is writable (real FS permission sanity)
chmod -R u+rwX "$WORKDIR" 2>/dev/null || true

LOG_DIR="$ROOT_DIR/.ralph/logs/$TASK_ID"
mkdir -p "$LOG_DIR"

log "Task: $TASK_ID"
log "Workdir: $WORKDIR"
log "Iterations: $ITERATIONS"
log "Timeout/iter: ${TIMEOUT_SEC}s"
append_progress "$PROGRESS_TXT" "=== START $TASK_ID @ $(now_iso) ==="

for ((i=1; i<=ITERATIONS; i++)); do
  state_set "$STATE_JSON" ".iteration" "$i"
  state_set "$STATE_JSON" ".last_event" "\"Iteration $i\""

  if prd_task_is_done "$PRD_MD" "$TASK_ID"; then
    log "PRD shows $TASK_ID is DONE. Stopping."
    break
  fi

  # Sync tracking into worktree as .ralph_tracking/
  sync_tracking_to_worktree "$TRACK_DIR" "$WORKDIR/.ralph_tracking"

  PROMPT_FILE="$(mktemp)"
  trap 'rm -f "$PROMPT_FILE"' EXIT

  build_prompt \
    --out "$PROMPT_FILE" \
    --root "$ROOT_DIR" \
    --workdir "$WORKDIR" \
    --task "$TASK_ID" \
    --prd "$WORKDIR/.ralph_tracking/PRD.md" \
    --progress "$WORKDIR/.ralph_tracking/progress.txt" \
    --state "$WORKDIR/.ralph_tracking/state.json" \
    --questions "$WORKDIR/.ralph_tracking/questions.md" \
    --answers "$WORKDIR/.ralph_tracking/answers.md"

  LOG_FILE="$LOG_DIR/iter-$(printf '%03d' "$i").log"
  log "Iteration=$i starting. Log: $LOG_FILE"
  append_progress "$PROGRESS_TXT" "ITER_START: $TASK_ID iter=$i @ $(now_iso) log=$LOG_FILE"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] Would run Claude for iter=$i"
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

  # Fail-fast classifiers (quota / permission) based on log content
  if log_contains_quota_limit "$LOG_FILE"; then
    state_set "$STATE_JSON" ".status" "\"RATE_LIMIT\""
    state_set "$STATE_JSON" ".last_event" "\"Quota/limit hit\""
    append_progress "$PROGRESS_TXT" "STOP: RATE_LIMIT iter=$i @ $(now_iso)"
    maybe_notify "Ralph stopped: rate limit ($TASK_ID)" "$PROGRESS_TXT"
    exit 0
  fi

  if log_contains_permission_denied "$LOG_FILE"; then
    state_set "$STATE_JSON" ".status" "\"PERMISSION_DENIED\""
    state_set "$STATE_JSON" ".last_event" "\"Permission denied (see log)\""
    append_progress "$PROGRESS_TXT" "STOP: PERMISSION_DENIED iter=$i @ $(now_iso) log=$LOG_FILE"
    maybe_notify "Ralph blocked: permissions ($TASK_ID)" "$PROGRESS_TXT"
    exit 0
  fi

  log "Iteration=$i finished rc=$CLAUDE_RC. Log: $LOG_FILE"
  append_progress "$PROGRESS_TXT" "ITER_END: $TASK_ID iter=$i rc=$CLAUDE_RC @ $(now_iso) log=$LOG_FILE"

  if [[ "$CLAUDE_RC" -ne 0 ]]; then
    state_set "$STATE_JSON" ".status" "\"ERROR\""
    state_set "$STATE_JSON" ".last_event" "\"Claude exited non-zero: $CLAUDE_RC\""
    append_progress "$PROGRESS_TXT" "ERROR: rc=$CLAUDE_RC iter=$i @ $(now_iso)"
    maybe_notify "Ralph error on $TASK_ID (iter=$i rc=$CLAUDE_RC)" "$PROGRESS_TXT"
    exit "$CLAUDE_RC"
  fi

  STATUS="$(state_get "$STATE_JSON" '.status' || true)"
  if [[ "$STATUS" == "NEEDS_CLARIFICATION" ]]; then
    log "Paused: NEEDS_CLARIFICATION. Answer in $ANSWERS_MD."
    append_progress "$PROGRESS_TXT" "PAUSE: NEEDS_CLARIFICATION iter=$i @ $(now_iso)"
    maybe_notify "Ralph needs clarification ($TASK_ID)" "$PROGRESS_TXT"
    exit 0
  fi

  if prd_task_is_done "$PRD_MD" "$TASK_ID"; then
    log "Task marked DONE in PRD."
    state_set "$STATE_JSON" ".status" "\"DONE\""
    state_set "$STATE_JSON" ".last_event" "\"PRD marked DONE\""
    append_progress "$PROGRESS_TXT" "=== DONE $TASK_ID @ $(now_iso) ==="
    maybe_notify "Ralph finished $TASK_ID" "$PROGRESS_TXT"
    break
  fi
done

log "Done. Current state: $(state_get "$STATE_JSON" '.status' || echo UNKNOWN)"
