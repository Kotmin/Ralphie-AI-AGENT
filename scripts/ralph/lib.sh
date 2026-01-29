#!/usr/bin/env bash
set -euo pipefail

log() { printf '[ralph] %s\n' "$*" >&2; }
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 127; }
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
data.setdefault("run_id", "")
data.setdefault("current_task_id", "")
data.setdefault("planned_tasks", [])
data.setdefault("completed_tasks", [])
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
key = expr.strip().lstrip(".")
val = data.get(key, "")
if isinstance(val, str):
    print(val)
else:
    import json as _j
    print(_j.dumps(val))
PY
}

state_set() {
  local state="$1" keyexpr="$2" value="$3"
  python3 - "$state" "$keyexpr" "$value" <<'PY'
import json, sys
p, keyexpr, value = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(p, "r", encoding="utf-8"))
key = keyexpr.strip().lstrip(".")
try:
    v = json.loads(value)
except json.JSONDecodeError:
    v = value
data[key] = v
with open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
PY
}

# Set a JSON array from bash args
state_set_json_array() {
  local state="$1" keyexpr="$2"; shift 2
  python3 - "$state" "$keyexpr" "$@" <<'PY'
import json, sys
p, keyexpr, *items = sys.argv[1:]
data = json.load(open(p, "r", encoding="utf-8"))
key = keyexpr.strip().lstrip(".")
data[key] = items
with open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
PY
}

append_completed_task() {
  local state="$1" task="$2"
  python3 - "$state" "$task" <<'PY'
import json, sys
p, task = sys.argv[1], sys.argv[2]
data = json.load(open(p, "r", encoding="utf-8"))
done = data.get("completed_tasks", [])
if task and task not in done:
    done.append(task)
data["completed_tasks"] = done
with open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
PY
}

strip_json_string() {
  local s="${1:-}"
  # If it's a JSON string like "US-001", strip quotes; else return as-is.
  if [[ "$s" =~ ^\".*\"$ ]]; then
    echo "${s:1:${#s}-2}"
  else
    echo "$s"
  fi
}

append_progress() {
  local file="$1" line="$2"
  printf '%s\n' "$line" >> "$file"
}

detect_claude_cmd() {
  if command -v claude >/dev/null 2>&1; then
    export RALPH_CLAUDE_KIND="claude"
    return 0
  fi
  if command -v npx >/dev/null 2>&1; then
    export RALPH_CLAUDE_KIND="npx"
    return 0
  fi
  echo "Neither 'claude' nor 'npx' found. Install Claude Code or Node+NPX." >&2
  exit 127
}

claude_preflight() {
  local workdir="$1"
  local -a cmd=()
  case "${RALPH_CLAUDE_KIND:-}" in
    claude) cmd=(claude) ;;
    npx) cmd=(npx -y @anthropic-ai/claude-code) ;;
    *) return 1 ;;
  esac
  (cd "$workdir" && "${cmd[@]}" -p "Reply with: OK") >/dev/null 2>&1
}

run_claude_headless_logged() {
  local workdir="$1" prompt_file="$2" log_file="$3"
  local prompt
  prompt="$(cat "$prompt_file")"

  local -a cmd=()
  case "${RALPH_CLAUDE_KIND:-}" in
    claude) cmd=(claude) ;;
    npx) cmd=(npx -y @anthropic-ai/claude-code) ;;
    *)
      echo "RALPH_CLAUDE_KIND not set. Call detect_claude_cmd first." >&2
      return 127
      ;;
  esac

  mkdir -p "$(dirname "$log_file")"
  {
    echo "=== Ralph Claude Run @ $(now_iso) ==="
    echo "workdir=$workdir"
    echo "cmd=${cmd[*]} -p <prompt>"
    echo "prompt_file=$prompt_file"
    echo "log_file=$log_file"
    echo "===================================="
  } >>"$log_file"

  ( cd "$workdir" && "${cmd[@]}" -p "$prompt" ) >>"$log_file" 2>&1
}

sync_tracking_to_worktree() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  rsync -a --delete "$src/" "$dst/"
}

sync_tracking_from_worktree() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  rsync -a --delete "$src/" "$dst/"
}

log_contains_quota_limit() {
  local logf="$1"
  grep -Eqi 'hit your limit|rate limit|quota|resets [0-9]{1,2}(am|pm)' "$logf"
}

log_contains_permission_denied() {
  local logf="$1"
  grep -Eqi 'permission denied|not permitted|operation not permitted' "$logf"
}

run_with_timeout_and_observability() {
  local workdir="" prompt_file="" log_file="" timeout_sec=900 heartbeat_sec=15 verbose=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workdir) workdir="$2"; shift 2 ;;
      --prompt-file) prompt_file="$2"; shift 2 ;;
      --log-file) log_file="$2"; shift 2 ;;
      --timeout-sec) timeout_sec="$2"; shift 2 ;;
      --heartbeat-sec) heartbeat_sec="$2"; shift 2 ;;
      --verbose) verbose="$2"; shift 2 ;;
      *) echo "run_with_timeout_and_observability: unknown arg $1" >&2; return 2 ;;
    esac
  done

  run_claude_headless_logged "$workdir" "$prompt_file" "$log_file" &
  local pid=$!

  local tail_pid=""
  if [[ "$verbose" -eq 1 ]]; then
    ( tail -n 50 -f "$log_file" ) &
    tail_pid=$!
  fi

  ( while kill -0 "$pid" 2>/dev/null; do
      log "Claude still running (pid=$pid) ... $(now_iso) log=$log_file"
      sleep "$heartbeat_sec"
    done
  ) &
  local hb_pid=$!

  ( sleep "$timeout_sec"
    if kill -0 "$pid" 2>/dev/null; then
      log "Timeout (${timeout_sec}s) hit. Killing Claude pid=$pid"
      kill "$pid" 2>/dev/null || true
      sleep 2
      kill -9 "$pid" 2>/dev/null || true
    fi
  ) &
  local wd_pid=$!

  wait "$pid"
  local rc=$?

  kill "$hb_pid" 2>/dev/null || true
  kill "$wd_pid" 2>/dev/null || true
  if [[ -n "$tail_pid" ]]; then
    kill "$tail_pid" 2>/dev/null || true
  fi

  return "$rc"
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

git_worktree_remove_safe() {
  local root="$1" wt_dir="$2"
  (cd "$root" && {
    if git worktree list --porcelain | grep -Fq "worktree $wt_dir"; then
      git worktree remove --force "$wt_dir" >/dev/null 2>&1 || true
    fi
  })
  rm -rf "$wt_dir" 2>/dev/null || true
}

sanitize_worktree_path() {
  local p="$1"
  # Avoid slashes from branch names making nested directories unexpectedly
  echo "$p" | sed 's#[/: ]#_#g'
}

run_id_now() {
  date -u +"%Y%m%d-%H%M%S"
}

# PRD parsing

prd_pick_next_task() {
  local prd="$1"
  local line
  line="$(grep -E '^[#]{3}[[:space:]]+\[ \][[:space:]]+US-[0-9]+' "$prd" | head -n1 || true)"
  [[ -n "$line" ]] || return 0
  echo "$line" | sed -E 's/^###[[:space:]]+\[ \][[:space:]]+(US-[0-9]+).*/\1/'
}

prd_task_is_done() {
  local prd="$1" task="$2"
  grep -Eq "^[#]{3}[[:space:]]+\[x\][[:space:]]+$task\b" "$prd"
}

prd_plan_tasks() {
  local prd="$1" start_task="$2" batch_size="$3"

  # Plan tasks from first unchecked task at/after start_task (if present),
  # otherwise from first unchecked overall.
  local start_line
  start_line="$(grep -nE "^[#]{3}[[:space:]]+\\[ \\][[:space:]]+$start_task\\b" "$prd" | head -n1 | cut -d: -f1 || true)"

  if [[ -n "$start_line" ]]; then
    tail -n +"$start_line" "$prd" \
      | grep -E '^[#]{3}[[:space:]]+\[ \][[:space:]]+US-[0-9]+' \
      | head -n "$batch_size" \
      | sed -E 's/^###[[:space:]]+\[ \][[:space:]]+(US-[0-9]+).*/\1/'
  else
    grep -E '^[#]{3}[[:space:]]+\[ \][[:space:]]+US-[0-9]+' "$prd" \
      | head -n "$batch_size" \
      | sed -E 's/^###[[:space:]]+\[ \][[:space:]]+(US-[0-9]+).*/\1/'
  fi
}

task_in_list() {
  local needle="$1"; shift
  local t
  for t in "$@"; do
    [[ "$t" == "$needle" ]] && { echo 1; return 0; }
  done
  echo 0
}

next_pending_planned_task() {
  local prd="$1"; shift
  local t
  for t in "$@"; do
    if ! prd_task_is_done "$prd" "$t"; then
      echo "$t"
      return 0
    fi
  done
  echo ""
}

all_planned_tasks_done() {
  local prd="$1"; shift
  local t
  for t in "$@"; do
    if ! prd_task_is_done "$prd" "$t"; then
      return 1
    fi
  done
  return 0
}

# Branch naming

branch_name_from_tasks() {
  # Produces:
  # - ralph/US-001-US-005 if contiguous and short
  # - otherwise empty (caller falls back)
  local tasks=("$@")
  [[ "${#tasks[@]}" -ge 1 ]] || { echo ""; return 0; }

  local first="${tasks[0]}"
  local last="${tasks[-1]}"

  # Check contiguous numeric sequence US-XXX
  local i
  local first_n last_n cur_n
  first_n="$(echo "$first" | sed -E 's/^US-0*([0-9]+)$/\1/')"
  last_n="$(echo "$last" | sed -E 's/^US-0*([0-9]+)$/\1/')"
  [[ "$first_n" =~ ^[0-9]+$ && "$last_n" =~ ^[0-9]+$ ]] || { echo ""; return 0; }

  cur_n="$first_n"
  for ((i=0; i<${#tasks[@]}; i++)); do
    local expect="US-$(printf '%03d' "$cur_n")"
    if [[ "${tasks[$i]}" != "$expect" ]]; then
      echo ""
      return 0
    fi
    cur_n=$((cur_n + 1))
  done

  local name="ralph/$first-$last"
  # Hard cap to avoid pathological branch names
  if [[ "${#name}" -gt 60 ]]; then
    echo ""
    return 0
  fi
  echo "$name"
}

ensure_tracking_files_exist() {
  local track_dir="$1"
  local prd="$track_dir/PRD.md"
  local progress="$track_dir/progress.txt"
  local state="$track_dir/state.json"
  local questions="$track_dir/questions.md"
  local answers="$track_dir/answers.md"

  [[ -f "$prd" ]] || printf "# PRD: <Project Name>\n\n## User Stories\n\n### [ ] US-001: <Title>\n" >"$prd"
  [[ -f "$progress" ]] || printf "# Ralph Progress Log (append-only)\n" >"$progress"
  [[ -f "$state" ]] || printf '{ "run_id": "", "current_task_id": "", "planned_tasks": [], "completed_tasks": [], "iteration": 0, "status": "IDLE", "last_event": "", "questions": [] }\n' >"$state"
  [[ -f "$questions" ]] || printf "# Questions for User\n" >"$questions"
  [[ -f "$answers" ]] || printf "# Answers\n" >"$answers"
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

  local user_base="$HOME/.claude/CLAUDE.md"
  local overlay=""
  if [[ -f "$user_base" ]]; then
    overlay+="\n\n# User-level CLAUDE.md (from ~/.claude/CLAUDE.md)\n"
    overlay+="$(cat "$user_base")"
  fi

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

Current task: $task
Repo root: $root
Working directory: $workdir

$(cat "$skill_prompt")

# PRD.md (relevant section)
$(sed -n "/^### \\[ \\] $task\\b/,/^### \\[/p" "$prd" | head -n 220)

# progress.txt (tail)
$(tail -n 80 "$progress" 2>/dev/null || true)

# state.json
$(cat "$state")
EOF

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

  if [[ -n "$overlay" ]]; then
    printf "\n%s\n" "$overlay" >>"$out"
  fi
}

maybe_notify() {
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
