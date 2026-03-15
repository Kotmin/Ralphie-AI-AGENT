# AGENTS.md — Ralphie AI Agent

Operational guide for autonomous agents working in this repository.
Keep concise. Update Learnings as you discover things.

## Build & Validate

This repo ships Ralph itself — the loop runner. There is no build step.

- **lint/check**: `bash -n ralph/ralph.sh && bash -n ralph/lib.sh && bash -n ralph/ralph-parallel.sh`
- **dry run**: `ralph/ralph.sh --dry-run`
- **parallel dry run**: `ralph/ralph-parallel.sh --dry-run`

## Known Pre-existing Failures

- Orphaned worktrees in `.ralph/worktrees/` from prior test runs — ignore, they are cleaned up by `--cleanup-stale 1`.

## Commit Format

Standard tasks:
```
US-XXX: short description
```

Infra/tooling:
```
feat|fix|refactor|docs|test|chore(scope): description
```

Rules:
- No AI/Claude mentions in commits or trailers
- One commit = one complete, buildable, logically coherent change
- Mark PRD checkbox `[x]` only when acceptance criteria are fully met

## Tracking Files (inside worktree at `.ralph_tracking/`)

- `PRD.md` — checkbox source of truth. Mark `[x]` when done.
- `progress.txt` — append-only log: what changed, what's next, blockers.
- `state.json` — machine state. Set `status = "NEEDS_CLARIFICATION"` + write to `questions.md` if blocked.

## Learnings

(Agents append discovered project-specific execution details here.)
