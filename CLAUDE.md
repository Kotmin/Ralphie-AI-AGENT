# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ralphie is a minimal, production-oriented automation loop for Claude Code that prioritizes clean context, repeatability, and git safety. Each iteration runs Claude Code in a fresh headless process with no chat history — persistent memory lives in local tracking files, and work happens in git worktrees.

## Commands

### Running the Loop

```bash
# Basic run (10 iterations, batch of 5 tasks)
./scripts/ralph/ralph.sh

# Custom iterations
./scripts/ralph/ralph.sh --iterations 20

# Start from specific task
./scripts/ralph/ralph.sh --task-id US-002

# Verbose mode (tail logs while running)
./scripts/ralph/ralph.sh --verbose

# Dry run (print actions without running Claude)
./scripts/ralph/ralph.sh --dry-run
```

### Key CLI Options

| Option | Default | Description |
|--------|---------|-------------|
| `--iterations N` | 10 | Max Claude invocations |
| `--batch-size N` | 5 | Tasks to plan per run |
| `--task-id US-XXX` | — | Force starting task |
| `--timeout-sec N` | 900 | Per-iteration timeout |
| `--verbose` | off | Tail Claude log |
| `--reset-worktree` | off | Recreate worktree |
| `--cleanup` | off | Remove worktree when done |

## Architecture

### Execution Model

1. **Fresh Process Per Iteration** — Each Claude invocation starts clean
2. **No Chat History** — Conversation memory clears between iterations
3. **Persistent Tracking** — State lives in `.ralph/tracking/` (source of truth)
4. **Git Worktree Isolation** — Work happens in isolated worktrees under `.ralph/worktrees/`

### Directory Structure

```
scripts/ralph/
├── ralph.sh      # Main loop runner
├── lib.sh        # Shared utilities (state management, PRD parsing, git ops)
└── prompt.md     # Claude execution instructions

.ralph/           # Runtime directory (gitignored)
├── tracking/     # Source of truth
│   ├── PRD.md        # Task checklist (checkboxes = done)
│   ├── state.json    # Machine state (run_id, current_task, status)
│   ├── progress.txt  # Append-only execution log
│   ├── questions.md  # Clarification requests
│   └── answers.md    # User responses
├── worktrees/    # Git worktrees (one per run)
└── logs/         # Execution logs
```

### Tracking Files

**PRD.md** — Task checkbox format:
```markdown
### [ ] US-001: Task title
Description and acceptance criteria...

### [x] US-002: Completed task
```

**state.json** schema:
```json
{
  "run_id": "YYYYMMDD-HHMMSS",
  "current_task_id": "US-001",
  "planned_tasks": ["US-001", "US-002"],
  "completed_tasks": [],
  "iteration": 1,
  "status": "IN_PROGRESS|IDLE|DONE|STOPPED|ERROR|RATE_LIMIT|NEEDS_CLARIFICATION"
}
```

### Status Values

- **IDLE** — Ready to start
- **IN_PROGRESS** — Currently executing
- **DONE** — All planned tasks completed
- **STOPPED** — Iterations exhausted
- **ERROR** — Claude exited non-zero
- **RATE_LIMIT** — Quota hit
- **NEEDS_CLARIFICATION** — Waiting for user answers in `answers.md`

## Clarification Protocol

When Ralph needs input:
1. Sets `state.json.status` to `NEEDS_CLARIFICATION`
2. Writes questions to `questions.md`
3. User answers in `answers.md`
4. Re-run the script

## Dependencies

Required: `bash`, `git`, `python3`, `mktemp`, `date`, `rsync`, `claude` (or `npx @anthropic-ai/claude-code`)

Optional: `curl` (for ntfy notifications via `NTFY_URL`/`NTFY_TOPIC` env vars)

## Key Conventions

- **Task IDs**: `US-XXX` format (three digits)
- **PRD checkbox is truth**: Mark `[x]` only when acceptance criteria met
- **Minimal changes**: Small commits, avoid bloating context
- **Stop when ambiguous**: Use clarification protocol instead of guessing
- **Git safety**: Never force push, don't modify git config
