# Ralphie — Repo-local Claude Code Loop

This repo contains a minimal "Ralph Wiggum loop" runner for Claude Code.

Ralphie is a minimal, production-oriented automation loop for Claude Code
that prioritizes **clean context**, **repeatability**, and **git safety**.

## Core idea

- Each iteration runs Claude Code in a **fresh headless process**
- No chat history is reused
- Persistent memory lives in local tracking files
- Work happens in isolated git worktrees

## Repository layout

**Tracked (committed):**
- `scripts/ralph/` — runner logic (`ralph.sh`, `lib.sh`, `prompt.md`)
- `CLAUDE.md` — project instructions for Claude
- `PRD.md` — global task definitions

**Local only (gitignored):**
- `.ralph/tracking/` — PRD, state, progress, questions
- `.ralph/worktrees/` — git worktrees
- `.ralph/logs/` — execution logs
- `.ralph/worktrees.json` — worktree ownership manifest

## Quick Start

```bash
# Basic run (10 iterations, batch of 5 tasks)
./scripts/ralph/ralph.sh

# Custom iterations
./scripts/ralph/ralph.sh --iterations 20

# Start from specific task
./scripts/ralph/ralph.sh --task-id US-002

# Dry run (print actions without running Claude)
./scripts/ralph/ralph.sh --dry-run
```

## CLI Options

### Core Options
| Option | Default | Description |
|--------|---------|-------------|
| `--iterations N` | 10 | Max Claude invocations |
| `--batch-size N` | 5 | Tasks to plan per run |
| `--task-id US-XXX` | — | Force starting task |
| `--force-new-task` | off | Ignore stored current_task_id |
| `--no-worktree` | off | Run in repo root (not recommended) |

### Observability
| Option | Default | Description |
|--------|---------|-------------|
| `--timeout-sec N` | 900 | Per-iteration timeout |
| `--heartbeat-sec N` | 15 | Heartbeat interval |
| `--verbose` | off | Tail Claude log while running |
| `--dry-run` | off | Print actions without running |

### Worktree Lifecycle
| Option | Default | Description |
|--------|---------|-------------|
| `--reset-worktree` | off | Recreate worktree for this run |
| `--cleanup` | off | Remove worktree when done successfully |
| `--cleanup-on-fail` | off | Remove worktree even on failure |
| `--cleanup-stale N` | 7 | Remove worktrees older than N days |

### Branching
| Option | Default | Description |
|--------|---------|-------------|
| `--branch NAME` | auto | Explicit branch name |
| `--branch-from-tasks` | 1 | Auto-name like `ralph/US-001-US-005` |

### Testing
| Option | Default | Description |
|--------|---------|-------------|
| `--max-retries N` | 3 | Max test retries per task |
| `--no-tests` | off | Skip test discovery and execution |

### Syncing & Integration
| Option | Default | Description |
|--------|---------|-------------|
| `--sync` | off | Fetch and ff-only pull before starting |
| `--integrate` | off | Rebase and merge changes when done |
| `--target-branch NAME` | current | Branch to integrate into |

## Tracking Files

Located in `.ralph/tracking/`:

| File | Purpose |
|------|---------|
| `PRD.md` | Task definitions with checkboxes (source of truth) |
| `state.json` | Machine state (run_id, status, current task) |
| `progress.txt` | Append-only execution log |
| `questions.md` | Clarification requests from Ralph |
| `answers.md` | User responses to questions |

## Status Values

| Status | Meaning |
|--------|---------|
| `IDLE` | Ready to start |
| `IN_PROGRESS` | Currently executing |
| `DONE` | All planned tasks completed |
| `STOPPED` | Iterations exhausted |
| `ERROR` | Claude exited non-zero |
| `RATE_LIMIT` | API quota hit |
| `NEEDS_CLARIFICATION` | Waiting for user answers |
| `TEST_FAILURE` | Tests failed after max retries |
| `REBASE_CONFLICT` | Integration conflict needs manual resolution |
| `SYNC_CONFLICT` | Remote sync failed (ff-only not possible) |

## Clarification Protocol

When Ralph encounters ambiguous requirements:

1. Sets `state.json` status to `NEEDS_CLARIFICATION`
2. Writes questions to `questions.md`
3. Execution pauses cleanly
4. User adds answers to `answers.md`
5. Re-run the script to resume

## Test Discovery

Ralph automatically discovers test commands in this priority order:

1. Test command defined in PRD task description
2. Config file test command (`package.json`, `pyproject.toml`, `Makefile`)
3. Common framework detection (pytest, npm test, go test, cargo test, etc.)
4. Skip tests if no mechanism found

Use `--no-tests` to disable test execution entirely.

## Integration Workflow

For automated rebase and merge:

```bash
# Run tasks and integrate when done
./scripts/ralph/ralph.sh --integrate --target-branch main

# With sync before starting
./scripts/ralph/ralph.sh --sync --integrate
```

Integration uses rebase-and-prove strategy:
- Rebases worktree commits onto target branch
- Runs validation tests after rebase
- Fast-forwards target branch only if tests pass
- Stops with `REBASE_CONFLICT` if manual resolution needed

## Worktree Management

Ralph tracks worktree ownership for safe cleanup:

```bash
# Clean up worktrees older than 14 days
./scripts/ralph/ralph.sh --cleanup-stale 14

# Remove worktree even if run fails
./scripts/ralph/ralph.sh --cleanup-on-fail
```

Orphaned worktrees are detected at startup and logged as warnings.

## Dependencies

**Required:** `bash`, `git`, `python3`, `mktemp`, `date`, `rsync`, `claude` (or `npx`)

**Optional:** `curl` (for ntfy notifications via `NTFY_URL`/`NTFY_TOPIC` env vars)

