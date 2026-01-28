#!/usr/bin/env bash
set -euo pipefail

log() { printf '[ralph] %s\n' "$*" >&2; }
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 127; }
}

ensure_files_exist() {
  for f in "$@"; do
    [[ -f "$f" ]] || { echo "Missing required file: $f" >&2; exit 2; }
  done
}

ensure_state_schema() {
  local state="$1"
  python3 - "$state" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, "r", encoding="utf-8") as f:
    try:
        data = json.load(f)
    except json.JSONDecodeError:
        data = {}
data.setdefault("current_task_id", "")
data.setdefault("iteration", 0)
data.setdefault("status", "IDLE")
data.setdefault("last_event", "")
data.setdefault("questions", [])
with open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
PY
}

state_get() {
  local state="$1" expr="$2"
  python3 - "$state" "$expr" <<'PY'
import json, sys
p, expr = sys.argv[1], sys.argv[2]
data = json.load(open(p, "r", encoding="utf-8"))
# very small "jq-like" getter for known keys
# expr format: .key
key = expr.strip().lstrip(".")
val = data.get(key, "")
if isinstance(val, str):
    print(val)
else:
    import json as _j; print(_j.dumps(val))
PY
}

state_set() {
  local state="$1" keyexpr="$2" value="$3"
  python3 - "$state" "$keyexpr" "$value" <<'PY'
import json, sys
p, keyexpr, value = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(p, "r", encoding="utf-8"))
key = keyexpr.strip().lstrip(".")
# value is passed already JSON-ish for strings in caller; attempt parse
try:
    v = json.loads(value)
except json.JSONDecodeError:
    v = value
data[key] = v
with open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
PY
}

append_progress() {
  local file="$1" line="$2"
  printf '%s\n' "$line" >> "$file"
}

detect_claude_cmd() {
  if command -v claude >/dev/null 2>&1; then
    export RALPH_CLAUDE_CMD="claude"
    return 0
  fi
  if command -v npx >/dev/null 2>&1; then
    export RALPH_CLAUDE_CMD="npx -y @anthropic-ai/claude-code"
    return 0
  fi
  echo "Neither 'claude' nor 'npx' found. Install Claude Code or Node+NPX." >&2
  exit 127
}

run_claude_headless() {
  local workdir="$1" prompt_file="$2"
  # Headless mode is documented as -p/--print. :contentReference[oaicite:3]{index=3}
  local prompt
  prompt="$(cat "$prompt_file")"

  (cd "$workdir" && bash -lc "$RALPH_CLAUDE_CMD -p \"\$PROMPT\"") \
    PROMPT="$prompt"
}

prepare_worktree() {
  local root="$1" wt_dir="$2" branch="$3"
  mkdir -p "$(dirname "$wt_dir")"
  (cd "$root" && git rev-parse --is-inside-work-tree >/dev/null)

  if [[ -d "$wt_dir/.git" ]] || [[ -f "$wt_dir/.git" ]]; then
    log "Worktree exists: $wt_dir"
    return 0
  fi

  (cd "$root" && {
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      git worktree add "$wt_dir" "$branch"
    else
      git worktree add -b "$branch" "$wt_dir"
    fi
  })
}

# PRD format convention:
# Each task heading must be:
#   ### [ ] US-002: Title
# and DONE is:
#   ### [x] US-002: Title
prd_pick_next_task() {
  local prd="$1"
  # first unchecked
  local line
  line="$(grep -E '^[#]{3}[[:space:]]+\[ \][[:space:]]+US-[0-9]+' "$prd" | head -n1 || true)"
  [[ -n "$line" ]] || return 0
  echo "$line" | sed -E 's/^###[[:space:]]+\[ \][[:space:]]+(US-[0-9]+).*/\1/'
}

prd_task_is_done() {
  local prd="$1" task="$2"
  grep -Eq "^[#]{3}[[:space:]]+\[x\][[:space:]]+$task\b" "$prd"
}

build_prompt() {
  local out="" root="" workdir="" task="" prd="" progress="" state="" questions="" answers=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      --root) root="$2"; shift 2 ;;
      --workdir) workdir="$2"; shift 2 ;;
      --task) task="$2"; shift 2 ;;
      --prd) prd="$2"; shift 2 ;;
      --progress) progress="$2"; shift 2 ;;
      --state) state="$2"; shift 2 ;;
      --questions) questions="$2"; shift 2 ;;
      --answers) answers="$2"; shift 2 ;;
      *) echo "build_prompt: unknown arg $1" >&2; exit 2 ;;
    esac
  done

  local skill_prompt="$root/scripts/ralph/prompt.md"

  # Optional user-level overlays (kept minimal here; we’ll improve detection later)
  local user_base="$HOME/.claude/CLAUDE.md"
  local overlay=""

  if [[ -f "$user_base" ]]; then
    overlay+="\n\n# User-level CLAUDE.md (from ~/.claude/CLAUDE.md)\n"
    overlay+="$(cat "$user_base")"
  fi

  # Keep prompts small: include tails only.
  local QUESTIONS_TAIL=""
  local ANSWERS_TAIL=""

  if [[ -n "$questions" && -f "$questions" ]]; then
    QUESTIONS_TAIL="$(tail -n 120 "$questions" 2>/dev/null || true)"
  fi

  if [[ -n "$answers" && -f "$answers" ]]; then
    ANSWERS_TAIL="$(tail -n 200 "$answers" 2>/dev/null || true)"
  fi

  cat >"$out" <<EOF
You are running in a Ralph loop.
IMPORTANT:
- Treat PRD.md checkboxes as the source of truth for DONE.
- Update PRD.md by checking the checkbox [x] when the task is fully done.
- Append brief notes to progress.txt (keep it short, high-signal).
- Keep state.json valid JSON.
- If you need clarification, set:
  { "status": "NEEDS_CLARIFICATION", "questions": ["..."] }
  and write the same questions to questions.md. Then stop.

Current task: $task
Repo root: $root
Working directory: $workdir

$(cat "$skill_prompt")

# PRD.md (relevant)
$(sed -n "/^### \\[ \\] $task\\b/,/^### \\[/p" "$prd" | head -n 220)

# progress.txt (tail)
$(tail -n 80 "$progress" 2>/dev/null || true)

# state.json
$(cat "$state")
EOF

  # Add questions/answers only if present (avoid empty noise).
  if [[ -n "$QUESTIONS_TAIL" ]]; then
    cat >>"$out" <<EOF

# questions.md (tail)
$QUESTIONS_TAIL
EOF
  fi

  if [[ -n "$ANSWERS_TAIL" ]]; then
    cat >>"$out" <<EOF

# answers.md (tail)
$ANSWERS_TAIL
EOF
  fi

  # Append overlay last.
  if [[ -n "$overlay" ]]; then
    printf "\n%s\n" "$overlay" >>"$out"
  fi
}


maybe_notify() {
  # Optional ntfy.sh; enable by setting:
  #   NTFY_URL (default https://ntfy.sh)
  #   NTFY_TOPIC (required)
  # and ensure curl exists.
  local title="$1" file="$2"
  local url="${NTFY_URL:-https://ntfy.sh}"
  local topic="${NTFY_TOPIC:-}"
  [[ -n "$topic" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0

  local msg
  msg="$(tail -n 40 "$file" 2>/dev/null || true)"
  curl -fsS -X POST \
    -H "Title: $title" \
    --data-binary "$msg" \
    "$url/$topic" >/dev/null || true
}
