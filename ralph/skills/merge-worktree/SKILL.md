---
name: merge-worktree
description: Use when the user says "merge worktree", "merge worktrees", "merge branches to dev", "integrate ralph worktrees", wants to merge completed ralph worktree branches into a target branch, or asks to clean up and integrate agent work.
version: 1.0.0
---

# merge-worktree Skill

Merge completed ralph worktree branches into a target branch with full validation.

## When This Skill Applies

- "merge worktrees"
- "merge branches to dev"
- "merge the ralph agents into dev"
- "integrate worktree results"
- "finalize and clean up worktrees"

## Parameters (parsed from user message)

- `[worktree-filter]` — optional name/branch fragment to match specific worktrees (default: all)
- `[--into <branch>]` — target branch to merge into (default: `dev`)

Examples:
- `/merge-worktree` — merge all worktrees into dev
- `/merge-worktree W02-agent-W02-A` — merge one specific worktree
- `/merge-worktree --into main` — merge all into main
- `/merge-worktree W02-agent-W02-A main` — merge one into main

## Execution Steps

For each matching worktree (in order, sequentially):

### 1. Discover
- Read `.ralph/worktrees.json` to find registered worktrees
- Also scan `.ralph/worktrees/` for directories not in the manifest
- Apply filter if argument provided

### 2. Validate State
- Check `state.json` in the worktree's tracking dir: `status` must be `DONE`
- Verify git status is clean (`git status --porcelain` returns empty)
- If not DONE or not clean: **warn + skip**, continue with next worktree

### 3. Task Verification
- Read `completed_tasks` from state.json
- Verify each completed task is checked `[x]` in `PRD_PROJECT.md`
- Warn on mismatches but do not block

### 4. Docker Test Gate
- Run test command from `ralph/ralph.yaml` runner.test
- If tests fail: **block this worktree** (do not merge), report failure, continue with others

### 5. Rebase
- `git fetch origin` in worktree
- `git rebase origin/<target-branch>` for linear history
- If conflict: **abort rebase, skip worktree**, report conflicting files

### 6. Fast-Forward Merge
- From repo root: `git merge --ff-only <worktree-branch>`
- Or: push worktree HEAD to target branch ref via fetch

### 7. Post-Merge Test
- Run tests again on merged branch
- If fail: **hard stop** — merged state is broken, user must intervene

### 8. Mark Tasks Done in PRD
- For each task in the worktree's `completed_tasks`: mark `[x]` in `PRD_PROJECT.md`

### 9. Cleanup
- `git worktree remove --force <path>`
- `git worktree prune`
- Remove from `worktrees.json`

## Final Report

Print a summary table:

```
Worktree            Branch              Status
──────────────────────────────────────────────────
W02-agent-W02-A     W02-agent-W02-A    ✓ merged
W02-agent-W02-B     W02-agent-W02-B    ✓ merged
W02-agent-W02-C     W02-agent-W02-C    ✗ tests failed (see .ralph/logs/)
W02-agent-W02-D     W02-agent-W02-D    ✗ rebase conflict in src/main/...
```

## Key Rules

- Never force-push
- Never modify git config
- Rebase before merge (for linear history)
- Post-merge test failure = hard stop (do not continue with remaining worktrees)
- Use `git_worktree_remove_safe` pattern (never bare `rm -rf` a worktree)
