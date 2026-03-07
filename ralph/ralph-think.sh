#!/usr/bin/env bash
# ralph-think.sh — Background self-improvement agent for ralph itself.
# Spawns a Claude agent that inventories current ralph capabilities,
# compares against the bundled playbook, and updates ralph/IMPLEMENTATION_PLAN.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib.sh"

WAIT=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: ralph/ralph-think.sh [options]

Spawns a background Claude agent that reviews ralph's current state,
compares against best practices (playbook-summary.md), and updates
ralph/IMPLEMENTATION_PLAN.md with improvement tasks.

Options:
  --wait      Block until the agent completes (default: fire-and-forget)
  --dry-run   Print the prompt that would be sent, do not run Claude
  -h|--help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait)    WAIT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

detect_claude_cmd

LOG_DIR="$ROOT_DIR/.ralph/logs/think"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/think-$(run_id_now).log"

PROMPT_FILE="$(mktemp /tmp/ralph-think-XXXXXX.md)"
trap 'rm -f "$PROMPT_FILE"' EXIT

cat > "$PROMPT_FILE" <<'PROMPT'
You are a ralph self-improvement agent. Your job is to review ralph's current
implementation, compare it against best practices, and update
`ralph/IMPLEMENTATION_PLAN.md` with an accurate inventory and improvement tasks.

## What to do

1. **Inventory ralph/** — Read all scripts in `ralph/` and understand what each does.
   Use parallel subagents to read files efficiently.

2. **Read references** — Study `ralph/references/playbook-summary.md` for best
   practice patterns to compare against.

3. **Read current plan** — Read `ralph/IMPLEMENTATION_PLAN.md` to see what's
   already tracked.

4. **Update ralph/IMPLEMENTATION_PLAN.md** — Rewrite the file with:
   - An accurate "Current Capabilities" inventory (what ralph actually has)
   - "Gaps vs Huntley Playbook" section with US-format tasks for improvements
   - "Completed Improvements" section for done items
   - Keep tasks actionable and small enough for one iteration

5. **Commit** the updated plan:
   ```
   chore(ralph): update self-improvement plan
   ```

## Rules

- Only modify `ralph/IMPLEMENTATION_PLAN.md` — do not touch project code.
- Keep the plan concise and scannable — not an essay.
- Mark genuinely completed items as [x].
- Do not invent improvements that are already implemented.
- Stop after committing. Do not implement any improvements.
PROMPT

log "ralph-think: log=$LOG_FILE"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "[dry-run] Prompt:"
  cat "$PROMPT_FILE"
  exit 0
fi

declare -a cmd=()
case "${RALPH_CLAUDE_KIND:-}" in
  claude) cmd=(claude --dangerously-skip-permissions -p) ;;
  npx)    cmd=(npx -y @anthropic-ai/claude-code --dangerously-skip-permissions -p) ;;
  *)
    echo "RALPH_CLAUDE_KIND not set. Call detect_claude_cmd first." >&2
    exit 127
    ;;
esac

PROMPT_CONTENT="$(cat "$PROMPT_FILE")"

if [[ "$WAIT" -eq 1 ]]; then
  log "ralph-think: running (blocking)..."
  (cd "$ROOT_DIR" && "${cmd[@]}" "$PROMPT_CONTENT") >> "$LOG_FILE" 2>&1
  log "ralph-think: done. log=$LOG_FILE"
else
  log "ralph-think: running in background..."
  (cd "$ROOT_DIR" && "${cmd[@]}" "$PROMPT_CONTENT") >> "$LOG_FILE" 2>&1 &
  THINK_PID=$!
  log "ralph-think: pid=$THINK_PID log=$LOG_FILE"
fi
