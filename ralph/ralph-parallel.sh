#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RALPH_SCRIPT="$ROOT_DIR/ralph/ralph.sh"

source "$ROOT_DIR/ralph/lib.sh"

# Load project config (RALPH_TEST_CMD, RALPH_PRD, etc.)
load_project_config "$ROOT_DIR"

# PRD source: from ralph.yaml or default
PRD_SOURCE="$ROOT_DIR/${RALPH_PRD:-PRD.md}"

SKIP_W00=0
DRY_RUN=0
CLEAN=0
ITERATIONS=15
TIMEOUT_SEC=1200

usage() {
  cat <<'EOF'
Usage: ralph/ralph-parallel.sh [options]

  --skip-w00        Skip Phase 1 (W00 baseline already done)
  --clean           Remove all ralph worktrees and tracking dirs before starting
                    (uses git worktree remove + prune — safe cleanup)
  --dry-run         Print plan without executing
  --iterations N    Per-agent max iterations (default 15)
  --timeout-sec N   Per-agent timeout in seconds (default 1200)
  -h|--help

Flow:
  Phase 1 — W00-001 sequential (optional baseline scan, --skip-w00 to skip)
  Phase 2 — agents in parallel (from ralph/ralph.yaml parallel.agents table)
  Phase 3 — test gate: RALPH_TEST_CMD per worktree
  Phase 4 — merge report
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-w00)    SKIP_W00=1; shift ;;
    --clean)       CLEAN=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --iterations)  ITERATIONS="${2:?}"; shift 2 ;;
    --timeout-sec) TIMEOUT_SEC="${2:?}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

mkdir -p "$ROOT_DIR/.ralph/logs"

[[ -f "$PRD_SOURCE" ]] || { echo "ERROR: $PRD_SOURCE not found" >&2; exit 1; }

if [[ "$CLEAN" -eq 1 ]]; then
  log "Cleaning up ralph worktrees and tracking dirs..."
  local_wt_base="$ROOT_DIR/.ralph/worktrees"
  if [[ -d "$local_wt_base" ]]; then
    for wt in "$local_wt_base"/*/; do
      [[ -d "$wt" ]] || continue
      git_worktree_remove_safe "$ROOT_DIR" "$wt"
    done
  fi
  git -C "$ROOT_DIR" worktree prune
  rm -rf "$ROOT_DIR/.ralph/tracking" "$ROOT_DIR/.ralph/tracking-"* \
         "$ROOT_DIR/.ralph/runs" "$ROOT_DIR/.ralph/worktrees.json" 2>/dev/null || true
  log "Clean done."
fi

# Load agent table from ralph.yaml parallel.agents
RALPH_YAML="$ROOT_DIR/ralph/ralph.yaml"
[[ -f "$RALPH_YAML" ]] || { echo "ERROR: $RALPH_YAML not found" >&2; exit 1; }
load_parallel_agents "$RALPH_YAML"

# RUN_ID for this parallel run (namespaces all tracking dirs and logs)
PARALLEL_RUN_ID="$(run_id_now)"
PARALLEL_LOG_BASE="$ROOT_DIR/.ralph/logs/$PARALLEL_RUN_ID"
mkdir -p "$ROOT_DIR/.ralph/logs" "$PARALLEL_LOG_BASE"

_init_tracking() {
  local dir="$1"
  mkdir -p "$dir"
  cp "$PRD_SOURCE" "$dir/PRD.md"
  [[ -f "$dir/progress.txt" ]] || printf "# Ralph Progress Log\n" > "$dir/progress.txt"
  [[ -f "$dir/state.json" ]]   || printf '{"run_id":"","current_task_id":"","planned_tasks":[],"completed_tasks":[],"iteration":0,"status":"IDLE","last_event":"","questions":[]}\n' > "$dir/state.json"
  [[ -f "$dir/questions.md" ]] || printf "# Questions\n" > "$dir/questions.md"
  [[ -f "$dir/answers.md" ]]   || printf "# Answers\n" > "$dir/answers.md"
}

_run_agent() {
  local label="$1" tracking="$2" task="$3" batch="$4" branch="$5"
  local logf="$PARALLEL_LOG_BASE/agent-${label}.log"
  log "Agent [$label] start task=$task branch=$branch"
  "$RALPH_SCRIPT" \
    --tracking-dir  "$tracking" \
    --task-id       "$task" \
    --batch-size    "$batch" \
    --branch        "$branch" \
    --iterations    "$ITERATIONS" \
    --timeout-sec   "$TIMEOUT_SEC" \
    --no-preflight \
    2>&1 | tee "$logf"
}

# ─── Phase 1: W00 Baseline ────────────────────────────────────────────────────

if [[ "$SKIP_W00" -eq 0 ]]; then
  log "=== Phase 1: W00 baseline (sequential) ==="
  W00_TRACK="$ROOT_DIR/.ralph/tracking"
  _init_tracking "$W00_TRACK"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] ralph.sh --task-id W00-001 --batch-size 2 --branch W00-baseline"
  else
    _run_agent "W00-baseline" "$W00_TRACK" "W00-001" "2" "W00-baseline"
    W00_STATUS="$(strip_json_string "$(state_get "$W00_TRACK/state.json" '.status' 2>/dev/null || echo 'UNKNOWN')")"
    if [[ "$W00_STATUS" != "DONE" ]]; then
      log "ERROR: W00 baseline status=$W00_STATUS — check $PARALLEL_LOG_BASE/agent-W00-baseline.log"
      exit 1
    fi
  fi
  log "=== Phase 1 done ==="
fi

# ─── Phase 2: Parallel Agents (from ralph.yaml) ───────────────────────────────

log "=== Phase 2: parallel agents (${#AGENT_LABELS[@]} agents from ralph.yaml) ==="

declare -A AGENT_BRANCH AGENT_TRACK AGENT_PID AGENT_TASK_MAP AGENT_BATCH_MAP

for label in "${AGENT_LABELS[@]}"; do
  # Resolve per-label task/batch from variables set by load_parallel_agents
  task_var="AGENT_TASK_${label}"
  batch_var="AGENT_BATCH_${label}"
  task="${!task_var}"
  batch="${!batch_var}"
  branch="agent-${label}"
  tracking="$ROOT_DIR/.ralph/runs/$PARALLEL_RUN_ID/agents/$label"

  AGENT_BRANCH["$label"]="$branch"
  AGENT_TRACK["$label"]="$tracking"
  AGENT_TASK_MAP["$label"]="$task"
  AGENT_BATCH_MAP["$label"]="$batch"

  _init_tracking "$tracking"

  baseline_prd="$ROOT_DIR/.ralph/tracking/PRD.md"
  [[ -f "$baseline_prd" ]] && cp "$baseline_prd" "$tracking/PRD.md"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] Agent [$label]: task=$task batch=$batch branch=$branch tracking=$tracking"
    continue
  fi

  _run_agent "$label" "$tracking" "$task" "$batch" "$branch" &
  AGENT_PID["$label"]=$!
  log "Launched [$label] pid=${AGENT_PID[$label]}"
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "[DRY-RUN] done."
  exit 0
fi

log "Waiting for all agents..."
declare -A AGENT_RC
for label in "${AGENT_LABELS[@]}"; do
  wait "${AGENT_PID[$label]}" && AGENT_RC["$label"]=0 || AGENT_RC["$label"]=$?
  log "Agent [$label] finished rc=${AGENT_RC[$label]}"
done
log "=== Phase 2 done ==="

# ─── Phase 3: Test Gate ───────────────────────────────────────────────────────

log "=== Phase 3: test gate ==="

READY=()
FAILED=()

# Test command from ralph.yaml (RALPH_TEST_CMD set by load_project_config)
GATE_TEST_CMD="${RALPH_TEST_CMD:-}"

for label in "${AGENT_LABELS[@]}"; do
  branch="${AGENT_BRANCH[$label]}"
  worktree="$ROOT_DIR/.ralph/worktrees/$branch"
  testlog="$PARALLEL_LOG_BASE/tests-${label}.log"

  if [[ ! -d "$worktree" ]]; then
    log "SKIP [$label]: worktree not found at $worktree"
    FAILED+=("$label — worktree missing")
    continue
  fi

  log "Testing [$label]: $worktree"

  if [[ -z "$GATE_TEST_CMD" ]]; then
    log "SKIP [$label]: no test command configured in ralph.yaml"
    READY+=("$label  branch=$branch (no tests)")
    continue
  fi

  if (cd "$worktree" && eval "$GATE_TEST_CMD") > "$testlog" 2>&1; then
    log "PASS [$label]"
    READY+=("$label  branch=$branch")
  else
    log "FAIL [$label] — see $testlog"
    FAILED+=("$label — see $PARALLEL_LOG_BASE/tests-${label}.log")
  fi
done

log "=== Phase 3 done ==="

# ─── Summary ──────────────────────────────────────────────────────────────────

MERGE_INTO="${RALPH_MERGE_INTO:-dev}"

echo ""
echo "════════════════════════════════════════════════"
echo "  Ralph Parallel — Summary (run $PARALLEL_RUN_ID)"
echo "════════════════════════════════════════════════"
echo ""
echo "Agent results:"
for label in "${AGENT_LABELS[@]}"; do
  task="${AGENT_TASK_MAP[$label]}"
  rc="${AGENT_RC[$label]:-N/A}"
  printf "  [%-6s] task=%-10s  rc=%s\n" "$label" "$task" "$rc"
done
echo ""

if [[ "${#READY[@]}" -gt 0 ]]; then
  echo "Ready to merge into $MERGE_INTO (tests passed):"
  for info in "${READY[@]}"; do
    echo "  + $info"
  done
  echo ""
fi

if [[ "${#FAILED[@]}" -gt 0 ]]; then
  echo "Fix before merging:"
  for info in "${FAILED[@]}"; do
    echo "  - $info"
  done
  echo ""
fi

echo "Logs: .ralph/logs/$PARALLEL_RUN_ID/"
echo ""

[[ "${#FAILED[@]}" -eq 0 ]]
