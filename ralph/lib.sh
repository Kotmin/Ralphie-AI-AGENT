#!/usr/bin/env bash
set -euo pipefail

log() { printf '[ralph] %s\n' "$*" >&2; }
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# ─── Project Config (ralph.yaml) ──────────────────────────────────────────────

# Read a dotted key from ralph.yaml using python3 (no external yaml deps).
# Usage: yaml_get <yaml_file> <dotted.key>
yaml_get() {
  local yaml_file="$1" key="$2"
  python3 - "$yaml_file" "$key" <<'PY'
import sys, re

def parse_yaml(lines):
    """Minimal YAML parser: scalars, block scalars (|), nested dicts, list-of-dicts."""
    root = {}
    stack = [(-1, root)]   # (indent, container)

    def current(): return stack[-1][1]
    def pop_to(indent):
        while len(stack) > 1 and stack[-1][0] >= indent:
            stack.pop()

    i = 0
    while i < len(lines):
        raw = lines[i]
        stripped = raw.lstrip()
        if not stripped or stripped.startswith("#"):
            i += 1; continue
        indent = len(raw) - len(stripped)

        # List item
        if stripped.startswith("- "):
            pop_to(indent)
            parent = stack[-1][1]
            # The parent dict's last key should be the list container
            if isinstance(parent, dict) and parent:
                list_key = list(parent.keys())[-1]
                if not isinstance(parent[list_key], list):
                    parent[list_key] = []
                item = {}
                parent[list_key].append(item)
                rest = stripped[2:].strip()
                m = re.match(r'^([\w-]+)\s*:\s*(.*)', rest)
                if m:
                    item[m.group(1)] = m.group(2).strip().strip("\"'")
                stack.append((indent + 2, item))
            i += 1; continue

        pop_to(indent)
        m = re.match(r'^([\w-]+)\s*:\s*(.*)', stripped)
        if not m:
            i += 1; continue

        k, v = m.group(1), m.group(2).strip()
        parent = current()

        if v == "|":
            # Block scalar
            block = []
            i += 1
            base = None
            while i < len(lines):
                bl = lines[i]
                bs = bl.lstrip()
                if not bs:
                    block.append(""); i += 1; continue
                bi = len(bl) - len(bs)
                if base is None: base = bi
                if bi < base: break
                block.append(bl[base:].rstrip())
                i += 1
            parent[k] = "\n".join(block).strip()
            continue
        elif v in ("", "~"):
            d = {}
            parent[k] = d
            stack.append((indent, d))
        else:
            parent[k] = v.strip("\"'")
        i += 1
    return root

p, key = sys.argv[1], sys.argv[2]
try:
    with open(p, "r", encoding="utf-8") as f:
        lines = f.readlines()
    data = parse_yaml(lines)
    val = data
    for part in key.split("."):
        val = val.get(part, "") if isinstance(val, dict) else ""
    if isinstance(val, (list, dict)):
        import json; print(json.dumps(val))
    else:
        print(val or "")
except Exception:
    print("")
PY
}

# Load project config from ralph/ralph.yaml into exported env vars.
# Sets: RALPH_TEST_CMD, RALPH_BUILD_CMD, RALPH_DEV_CMD, RALPH_PRD,
#       RALPH_MERGE_INTO, RALPH_PROJECT
load_project_config() {
  local root="${1:-}"
  if [[ -z "$root" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
  local yaml="$root/ralph/ralph.yaml"

  if [[ ! -f "$yaml" ]]; then
    log "WARNING: $yaml not found — skipping project config load"
    return 0
  fi

  RALPH_PROJECT="$(yaml_get "$yaml" "project")"
  RALPH_PRD="$(yaml_get "$yaml" "prd")"
  RALPH_MERGE_INTO="$(yaml_get "$yaml" "merge_into")"
  RALPH_TEST_CMD="$(yaml_get "$yaml" "runner.test")"
  RALPH_BUILD_CMD="$(yaml_get "$yaml" "runner.build")"
  RALPH_DEV_CMD="$(yaml_get "$yaml" "runner.dev")"

  export RALPH_PROJECT RALPH_PRD RALPH_MERGE_INTO RALPH_TEST_CMD RALPH_BUILD_CMD RALPH_DEV_CMD
  log "Config: project=${RALPH_PROJECT} prd=${RALPH_PRD} merge_into=${RALPH_MERGE_INTO}"
}

# Source parallel agent table from ralph.yaml into shell variables.
# After calling: AGENT_LABELS array, AGENT_TASK_<label>, AGENT_BATCH_<label>
load_parallel_agents() {
  local yaml="$1"
  local agent_sh
  agent_sh="$(python3 - "$yaml" <<'PY'
import sys, re

def parse_agents(lines):
    agents = []
    in_agents = False
    current = None
    for line in lines:
        s = line.lstrip()
        indent = len(line) - len(s)
        if re.match(r'agents\s*:', s):
            in_agents = True; continue
        if not in_agents: continue
        if not s or s.startswith("#"): continue
        if indent == 0 and not s.startswith("-"): break
        if s.startswith("- "):
            if current is not None: agents.append(current)
            current = {}
            rest = s[2:].strip()
            m = re.match(r'([\w-]+):\s*(.*)', rest)
            if m: current[m.group(1)] = m.group(2).strip().strip("\"'")
        elif current is not None and indent >= 4:
            m = re.match(r'([\w-]+):\s*(.*)', s)
            if m: current[m.group(1)] = m.group(2).strip().strip("\"'")
    if current is not None: agents.append(current)
    return agents

with open(sys.argv[1], "r") as f:
    lines = f.readlines()

agents = parse_agents(lines)
labels = [a.get("label", "") for a in agents]
print(f'AGENT_LABELS=({" ".join(labels)})')
for a in agents:
    lbl = a.get("label", "")
    print(f'AGENT_TASK_{lbl}="{a.get("task", "")}"')
    print(f'AGENT_BATCH_{lbl}="{a.get("batch", "1")}"')
PY
)"
  eval "$agent_sh"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 127; }
}

# US-002: Command Capability Verification
# Verifies all required system commands are available before execution.
# Lists ALL missing commands (doesn't fail on first).
verify_required_commands() {
  local missing=()

  # Required commands
  local cmds=(bash git python3 mktemp date rsync)
  for cmd in "${cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  # Verify git worktree subcommand works
  if command -v git >/dev/null 2>&1; then
    if ! git worktree list >/dev/null 2>&1; then
      missing+=("git-worktree (git worktree subcommand not functional)")
    fi
  fi

  # Claude CLI: need either 'claude' or 'npx'
  local has_claude=0
  if command -v claude >/dev/null 2>&1; then
    has_claude=1
  elif command -v npx >/dev/null 2>&1; then
    has_claude=1
  fi
  if [[ "$has_claude" -eq 0 ]]; then
    missing+=("claude OR npx (for @anthropic-ai/claude-code)")
  fi

  # Report results
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "Command verification FAILED. Missing commands:"
    for cmd in "${missing[@]}"; do
      log "  - $cmd"
    done
    return 1
  fi

  log "Command verification: OK (all required commands available)"
  return 0
}

# US-001: Repository State Scan (Bootstrap)
# Scans repository structure and validates required files exist.
# Fails fast if critical files are missing.
repo_scan_bootstrap() {
  local root="$1"
  local errors=()
  local warnings=()

  log "Repository scan starting: $root"

  # Validate root exists and is a directory
  if [[ ! -d "$root" ]]; then
    log "ERROR: Root directory does not exist: $root"
    return 1
  fi

  # Check if inside a git repository
  if ! (cd "$root" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    errors+=("Not a git repository: $root")
  fi

  # Required: CLAUDE.md
  local claude_md="$root/CLAUDE.md"
  if [[ -f "$claude_md" ]]; then
    log "  [OK] CLAUDE.md: present"
  else
    errors+=("Missing required file: CLAUDE.md")
  fi

  # .ralph directory structure
  local ralph_dir="$root/.ralph"
  local tracking_dir="$ralph_dir/tracking"
  local worktrees_dir="$ralph_dir/worktrees"
  local logs_dir="$ralph_dir/logs"

  # Create .ralph structure if missing
  if [[ -d "$ralph_dir" ]]; then
    log "  [OK] .ralph/: present"
  else
    mkdir -p "$ralph_dir"
    log "  [CREATED] .ralph/"
  fi

  # Create subdirectories
  for subdir in tracking worktrees logs; do
    local dir="$ralph_dir/$subdir"
    if [[ -d "$dir" ]]; then
      log "  [OK] .ralph/$subdir/: present"
    else
      mkdir -p "$dir"
      log "  [CREATED] .ralph/$subdir/"
    fi
  done

  # Fail fast if errors
  if [[ ${#errors[@]} -gt 0 ]]; then
    log "Repository scan FAILED:"
    for err in "${errors[@]}"; do
      log "  ERROR: $err"
    done
    return 1
  fi

  # Output warnings if any
  if [[ ${#warnings[@]} -gt 0 ]]; then
    for warn in "${warnings[@]}"; do
      log "  WARNING: $warn"
    done
  fi

  log "Repository scan complete: OK"
  return 0
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

# US-007: Safe Stop Helper
# Sets status, logs reason, notifies, and exits cleanly
safe_stop() {
  local state_json="$1"
  local progress_file="$2"
  local status="$3"
  local reason="$4"
  local run_id="${5:-}"
  local exit_code="${6:-0}"

  state_set "$state_json" ".status" "\"$status\""
  state_set "$state_json" ".last_event" "\"$reason\""
  append_progress "$progress_file" "STOP: $status run_id=$run_id reason=\"$reason\" @ $(now_iso)"
  log "Stopping: $status - $reason"

  exit "$exit_code"
}

# US-010: Log state transitions consistently
# Logs to both stderr and progress.txt for observability
log_state_transition() {
  local progress_file="$1"
  local from_status="$2"
  local to_status="$3"
  local reason="${4:-}"
  local timestamp
  timestamp="$(now_iso)"

  local msg="STATE: $from_status -> $to_status"
  [[ -n "$reason" ]] && msg="$msg ($reason)"
  msg="$msg @ $timestamp"

  log "$msg"
  append_progress "$progress_file" "$msg"
}

# US-011: Test Command Discovery & Execution
# Discovers test command based on priority rules.
# Returns empty string if no test mechanism found (does not fail).
discover_test_command() {
  local workdir="$1"
  local prd_file="${2:-}"
  local task_id="${3:-}"

  # Priority 1: Check PRD task for explicit test command
  if [[ -n "$prd_file" && -f "$prd_file" && -n "$task_id" ]]; then
    local task_section
    task_section="$(sed -n "/^### \\[.\\] $task_id\\b/,/^### \\[/p" "$prd_file" | head -n -1)"
    # Look for "Test:" or "Test command:" in task section
    local prd_test
    prd_test="$(echo "$task_section" | grep -Ei '^[*-]?\s*(test|test command|run test):' | head -n1 | sed -E 's/^[*-]?\s*(test|test command|run test):\s*`?([^`]+)`?.*/\2/i' || true)"
    if [[ -n "$prd_test" ]]; then
      echo "$prd_test"
      return 0
    fi
  fi

  # Priority 2: Check repo config files
  # package.json
  if [[ -f "$workdir/package.json" ]]; then
    local npm_test
    npm_test="$(python3 -c "import json; d=json.load(open('$workdir/package.json')); print(d.get('scripts',{}).get('test',''))" 2>/dev/null || true)"
    if [[ -n "$npm_test" && "$npm_test" != "echo \"Error: no test specified\" && exit 1" ]]; then
      # Check for package manager
      if [[ -f "$workdir/pnpm-lock.yaml" ]]; then
        echo "pnpm test"
      elif [[ -f "$workdir/yarn.lock" ]]; then
        echo "yarn test"
      else
        echo "npm test"
      fi
      return 0
    fi
  fi

  # Gradle wrapper
  if [[ -f "$workdir/gradlew" ]]; then
    echo "./gradlew test --no-daemon"
    return 0
  fi

  # Maven wrapper or bare Maven
  if [[ -f "$workdir/pom.xml" ]]; then
    if [[ -f "$workdir/mvnw" ]]; then
      echo "./mvnw -q test"
    else
      echo "mvn -q test"
    fi
    return 0
  fi

  # pyproject.toml with pytest
  if [[ -f "$workdir/pyproject.toml" ]]; then
    if grep -q 'pytest' "$workdir/pyproject.toml" 2>/dev/null; then
      echo "pytest"
      return 0
    fi
  fi

  # Makefile with test target
  if [[ -f "$workdir/Makefile" ]]; then
    if grep -qE '^test:' "$workdir/Makefile" 2>/dev/null; then
      echo "make test"
      return 0
    fi
  fi

  # Priority 3: Detect common frameworks
  # Python: pytest or unittest
  if [[ -d "$workdir/tests" ]] || [[ -d "$workdir/test" ]]; then
    if command -v pytest >/dev/null 2>&1; then
      echo "pytest"
      return 0
    fi
  fi

  # Ruby/Rails
  if [[ -f "$workdir/Gemfile" ]]; then
    if grep -q 'rspec' "$workdir/Gemfile" 2>/dev/null; then
      echo "bundle exec rspec"
      return 0
    fi
    if [[ -f "$workdir/Rakefile" ]] && grep -q 'Rails' "$workdir/Rakefile" 2>/dev/null; then
      echo "bundle exec rails test"
      return 0
    fi
  fi

  # Go
  if [[ -f "$workdir/go.mod" ]]; then
    echo "go test ./..."
    return 0
  fi

  # Rust
  if [[ -f "$workdir/Cargo.toml" ]]; then
    echo "cargo test"
    return 0
  fi

  # Priority 4: No test mechanism found - return empty (not an error)
  echo ""
  return 0
}

# US-009: Verify commit discipline for a task
# Checks that the most recent commit follows the format: US-XXX: <title>
verify_commit_discipline() {
  local workdir="$1"
  local task_id="$2"

  # Get the most recent commit message
  local commit_msg
  commit_msg="$(cd "$workdir" && git log -1 --format=%s 2>/dev/null || true)"

  if [[ -z "$commit_msg" ]]; then
    log "WARNING: No commits found in worktree"
    return 0  # Not an error - maybe no changes needed
  fi

  # Check if commit message starts with the task ID
  if [[ "$commit_msg" =~ ^$task_id: ]]; then
    log "Commit discipline OK: $commit_msg"
    return 0
  else
    log "WARNING: Latest commit doesn't follow format '$task_id: <title>'"
    log "  Found: $commit_msg"
    return 1
  fi
}

# Check git status is clean in worktree
verify_clean_git_status() {
  local workdir="$1"

  local status
  status="$(cd "$workdir" && git status --porcelain 2>/dev/null || true)"

  if [[ -z "$status" ]]; then
    return 0
  else
    log "WARNING: Git status not clean after task completion"
    return 1
  fi
}

# Run discovered test command and return exit code
run_test_command() {
  local workdir="$1"
  local test_cmd="$2"
  local log_file="${3:-/dev/null}"

  if [[ -z "$test_cmd" ]]; then
    log "No test command available - skipping tests"
    return 0
  fi

  log "Running tests: $test_cmd"
  (cd "$workdir" && eval "$test_cmd") >>"$log_file" 2>&1
  local rc=$?

  if [[ "$rc" -eq 0 ]]; then
    log "Tests passed"
  else
    log "Tests failed (exit code: $rc)"
  fi

  return "$rc"
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

  ( cd "$workdir" && "${cmd[@]}" --dangerously-skip-permissions -p "$prompt" ) >>"$log_file" 2>&1
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

# US-012: Integrate changes with rebase-and-prove strategy
# Rebases worktree commits onto the invoked branch and runs validation
integrate_with_rebase() {
  local workdir="$1"
  local target_branch="$2"
  local test_cmd="${3:-}"

  log "Starting rebase integration onto $target_branch..."

  # Check for uncommitted changes
  if ! verify_clean_git_status "$workdir"; then
    log "ERROR: Uncommitted changes in worktree - cannot integrate"
    return 1
  fi

  # Get current branch in worktree
  local current_branch
  current_branch="$(cd "$workdir" && git rev-parse --abbrev-ref HEAD)"
  log "Current worktree branch: $current_branch"

  # Fetch latest
  (cd "$workdir" && git fetch origin --quiet 2>/dev/null) || true

  # Attempt rebase
  log "Rebasing $current_branch onto origin/$target_branch..."
  local rebase_output
  if ! rebase_output="$(cd "$workdir" && git rebase "origin/$target_branch" 2>&1)"; then
    log "Rebase encountered conflicts"

    # Check for conflict markers
    local conflicts
    conflicts="$(cd "$workdir" && git diff --name-only --diff-filter=U 2>/dev/null || true)"

    if [[ -n "$conflicts" ]]; then
      log "Unresolved conflicts in: $conflicts"
      # Abort rebase - cannot auto-resolve
      (cd "$workdir" && git rebase --abort 2>/dev/null) || true
      log "Rebase aborted - manual conflict resolution required"
      return 1
    fi
  fi

  # Check for any remaining conflict markers in files
  if (cd "$workdir" && grep -rl '<<<<<<< ' --include='*.py' --include='*.js' --include='*.ts' --include='*.sh' --include='*.rb' --include='*.go' --include='*.java' --include='*.kt' . 2>/dev/null | head -1 | grep -q .); then
    log "ERROR: Conflict markers found in files after rebase"
    (cd "$workdir" && git rebase --abort 2>/dev/null) || true
    return 1
  fi

  log "Rebase successful"

  # Run tests if available
  if [[ -n "$test_cmd" ]]; then
    log "Running validation after rebase..."
    if ! (cd "$workdir" && eval "$test_cmd" >/dev/null 2>&1); then
      log "ERROR: Tests failed after rebase"
      return 1
    fi
    log "Tests passed after rebase"
  fi

  log "Integration successful - worktree is ready for merge"
  return 0
}

# Fast-forward the target branch to the rebased worktree commit
finalize_integration() {
  local root_dir="$1"
  local worktree_dir="$2"
  local target_branch="$3"

  # Get the commit SHA from worktree
  local worktree_sha
  worktree_sha="$(cd "$worktree_dir" && git rev-parse HEAD)"

  log "Finalizing integration: fast-forwarding $target_branch to $worktree_sha"

  # Update the target branch in the main repo
  (cd "$root_dir" && git fetch "$worktree_dir" HEAD:"$target_branch" --force 2>/dev/null) || {
    log "ERROR: Failed to update $target_branch"
    return 1
  }

  log "Integration complete: $target_branch updated"
  return 0
}

# US-013: Safe sync of invoked branch
# Fetches and attempts ff-only pull. Returns non-zero if ff-only fails.
safe_sync_branch() {
  local workdir="$1"
  local branch="${2:-}"

  # Always safe to fetch
  log "Fetching from remote..."
  (cd "$workdir" && git fetch --quiet 2>/dev/null) || true

  # Check if branch has a remote tracking branch
  local tracking
  tracking="$(cd "$workdir" && git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null || true)"

  if [[ -z "$tracking" ]]; then
    log "No remote tracking branch - skipping pull"
    return 0
  fi

  log "Remote tracking branch: $tracking"

  # Attempt ff-only pull
  local pull_output
  if pull_output="$(cd "$workdir" && git pull --ff-only 2>&1)"; then
    log "Fast-forward sync successful"
    return 0
  else
    log "ERROR: Fast-forward sync failed. Remote has diverged."
    log "Output: $pull_output"
    log "Manual intervention required - cannot auto-merge remote changes."
    return 1
  fi
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

# US-014: Worktree ownership tracking
WORKTREE_MANIFEST=".ralph/worktrees.json"

# Register a worktree as Ralph-owned
register_worktree() {
  local root="$1"
  local wt_path="$2"
  local run_id="$3"
  local branch="$4"

  local manifest="$root/$WORKTREE_MANIFEST"
  local timestamp
  timestamp="$(now_iso)"

  python3 - "$manifest" "$wt_path" "$run_id" "$branch" "$timestamp" <<'PY'
import json, sys, os
manifest_path, wt_path, run_id, branch, timestamp = sys.argv[1:6]

data = {"worktrees": []}
if os.path.exists(manifest_path):
    try:
        with open(manifest_path, "r") as f:
            data = json.load(f)
    except:
        pass

# Add new worktree entry
data["worktrees"].append({
    "path": wt_path,
    "run_id": run_id,
    "branch": branch,
    "created": timestamp,
    "owner": "ralph"
})

with open(manifest_path, "w") as f:
    json.dump(data, f, indent=2)
PY
  log "Registered worktree: $wt_path (run_id=$run_id)"
}

# Unregister a worktree
unregister_worktree() {
  local root="$1"
  local wt_path="$2"

  local manifest="$root/$WORKTREE_MANIFEST"
  [[ -f "$manifest" ]] || return 0

  python3 - "$manifest" "$wt_path" <<'PY'
import json, sys, os
manifest_path, wt_path = sys.argv[1:3]

if not os.path.exists(manifest_path):
    sys.exit(0)

with open(manifest_path, "r") as f:
    data = json.load(f)

data["worktrees"] = [w for w in data.get("worktrees", []) if w.get("path") != wt_path]

with open(manifest_path, "w") as f:
    json.dump(data, f, indent=2)
PY
  log "Unregistered worktree: $wt_path"
}

# List all Ralph-owned worktrees
list_ralph_worktrees() {
  local root="$1"
  local manifest="$root/$WORKTREE_MANIFEST"

  [[ -f "$manifest" ]] || return 0

  python3 - "$manifest" <<'PY'
import json, sys
manifest_path = sys.argv[1]
with open(manifest_path, "r") as f:
    data = json.load(f)
for wt in data.get("worktrees", []):
    print(f"{wt['path']}\t{wt['run_id']}\t{wt['created']}")
PY
}

# Cleanup stale worktrees older than N days
cleanup_stale_worktrees() {
  local root="$1"
  local max_age_days="${2:-7}"
  local manifest="$root/$WORKTREE_MANIFEST"

  [[ -f "$manifest" ]] || return 0

  log "Checking for stale worktrees (older than $max_age_days days)..."

  local stale_paths
  stale_paths="$(python3 - "$manifest" "$max_age_days" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone

manifest_path, max_days = sys.argv[1], int(sys.argv[2])
cutoff = datetime.now(timezone.utc) - timedelta(days=max_days)

with open(manifest_path, "r") as f:
    data = json.load(f)

for wt in data.get("worktrees", []):
    try:
        created = datetime.fromisoformat(wt["created"].replace("Z", "+00:00"))
        if created < cutoff:
            print(wt["path"])
    except:
        pass
PY
)"

  if [[ -z "$stale_paths" ]]; then
    log "No stale worktrees found"
    return 0
  fi

  while IFS= read -r wt_path; do
    log "Removing stale worktree: $wt_path"
    git_worktree_remove_safe "$root" "$wt_path"
    unregister_worktree "$root" "$wt_path"
  done <<< "$stale_paths"
}

# Detect orphaned worktrees (in manifest but not in git worktree list)
detect_orphan_worktrees() {
  local root="$1"
  local manifest="$root/$WORKTREE_MANIFEST"

  [[ -f "$manifest" ]] || return 0

  local git_worktrees
  git_worktrees="$(cd "$root" && git worktree list --porcelain | grep '^worktree ' | sed 's/^worktree //')"

  python3 - "$manifest" "$git_worktrees" <<'PY'
import json, sys

manifest_path = sys.argv[1]
git_worktrees = set(sys.argv[2].strip().split('\n')) if sys.argv[2].strip() else set()

with open(manifest_path, "r") as f:
    data = json.load(f)

for wt in data.get("worktrees", []):
    if wt["path"] not in git_worktrees:
        print(f"ORPHAN: {wt['path']} (run_id={wt['run_id']}, created={wt['created']})")
PY
}

sanitize_worktree_path() {
  local p="$1"
  echo "$p" | sed 's#[: ]#_#g'
}

run_id_now() {
  date -u +"%Y%m%d-%H%M%S"
}

# PRD parsing

prd_pick_next_task() {
  local prd="$1"
  local line
  line="$(grep -E '^[#]{3}[[:space:]]+\[ \][[:space:]]+[A-Z][A-Z0-9]*-[0-9]+' "$prd" | head -n1 || true)"
  [[ -n "$line" ]] || return 0
  echo "$line" | sed -E 's/^###[[:space:]]+\[ \][[:space:]]+([A-Z][A-Z0-9]*-[0-9]+).*/\1/'
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
      | grep -E '^[#]{3}[[:space:]]+\[ \][[:space:]]+[A-Z][A-Z0-9]*-[0-9]+' \
      | head -n "$batch_size" \
      | sed -E 's/^###[[:space:]]+\[ \][[:space:]]+([A-Z][A-Z0-9]*-[0-9]+).*/\1/'
  else
    grep -E '^[#]{3}[[:space:]]+\[ \][[:space:]]+[A-Z][A-Z0-9]*-[0-9]+' "$prd" \
      | head -n "$batch_size" \
      | sed -E 's/^###[[:space:]]+\[ \][[:space:]]+([A-Z][A-Z0-9]*-[0-9]+).*/\1/'
  fi
}

prd_mark_task_done() {
  local prd="$1" task="$2"
  sed -i -E "s/^(###[[:space:]]+)\[ \]([[:space:]]+$task\b)/\1[x]\2/" "$prd"
}

task_in_list() {
  local needle="$1"; shift
  local t
  for t in "$@"; do
    [[ "$t" == "$needle" ]] && return 0
  done
  return 1
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
  local tasks=("$@")
  [[ "${#tasks[@]}" -ge 1 ]] || { echo ""; return 0; }

  local first="${tasks[0]}"
  local last="${tasks[-1]}"

  # US-XXX: verify contiguous sequence before naming
  local first_n last_n
  first_n="$(echo "$first" | sed -E 's/^US-0*([0-9]+)$/\1/')"
  last_n="$(echo "$last" | sed -E 's/^US-0*([0-9]+)$/\1/')"
  if [[ "$first_n" =~ ^[0-9]+$ && "$last_n" =~ ^[0-9]+$ ]]; then
    local i cur_n="$first_n"
    for ((i=0; i<${#tasks[@]}; i++)); do
      local expect="US-$(printf '%03d' "$cur_n")"
      if [[ "${tasks[$i]}" != "$expect" ]]; then
        echo ""
        return 0
      fi
      cur_n=$((cur_n + 1))
    done
    local name="ralph/$first-$last"
    [[ "${#name}" -le 60 ]] && echo "$name" || echo ""
    return 0
  fi

  # Other formats (W##-###, etc.): use first-last if they share the same prefix
  local first_pfx last_pfx
  first_pfx="$(echo "$first" | sed -E 's/^([A-Z][A-Z0-9]+-).*/\1/')"
  last_pfx="$(echo "$last" | sed -E 's/^([A-Z][A-Z0-9]+-).*/\1/')"
  if [[ "$first_pfx" == "$last_pfx" && -n "$first_pfx" ]]; then
    local name="ralph/$first-$last"
    [[ "${#name}" -le 60 ]] && echo "$name" || echo ""
    return 0
  fi

  echo ""
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
  local out="" root="" workdir="" task="" prd="" progress="" state="" questions="" answers="" skill_prompt_override=""
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
      --skill-prompt) skill_prompt_override="$2"; shift 2 ;;
      *) echo "build_prompt: unknown arg $1" >&2; exit 2 ;;
    esac
  done

  # Prompt file: explicit override > ralph/PROMPT_build.md > legacy prompt.md
  local skill_prompt
  if [[ -n "$skill_prompt_override" && -f "$skill_prompt_override" ]]; then
    skill_prompt="$skill_prompt_override"
  elif [[ -f "$root/ralph/PROMPT_build.md" ]]; then
    skill_prompt="$root/ralph/PROMPT_build.md"
  else
    skill_prompt="$root/scripts/ralph/prompt.md"  # legacy fallback
  fi

  # AGENTS.md: inject if present
  local agents_md=""
  if [[ -f "$root/ralph/AGENTS.md" ]]; then
    agents_md="$(cat "$root/ralph/AGENTS.md")"
  fi

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

# AGENTS.md (operational guide)
$agents_md

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
