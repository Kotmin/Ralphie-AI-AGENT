# AGENTS.md — <Project Name>

Operational guide for autonomous agents. Keep concise (~60 lines). Update Learnings as you discover things.

## Build & Validate

Commands are defined in `ralph/ralph.yaml`. When the prompt says "run tests" or "validate", use:

- **test**: `<test command from ralph.yaml>`
- **build check**: `<build command from ralph.yaml>`
- **dev**: `<dev command from ralph.yaml>`

Replace the above with your actual commands after editing `ralph/ralph.yaml`.

## Known Pre-existing Failures (ignore — do not try to fix)

(none by default — add here if your project has flaky or intentionally failing tests)

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
