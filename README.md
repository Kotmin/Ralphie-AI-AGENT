# Ralphie — Repo-local Claude Code Loop
## Ralphie the AI Agent

This repo contains a minimal “Ralph Wiggum loop” runner for Claude Code.

Ralphie is a minimal, production-oriented automation loop for Claude Code
that prioritizes **clean context**, **repeatability**, and **git safety**.

## Core idea

- Each iteration runs Claude Code in a **fresh headless process**
- No chat history is reused
- Persistent memory lives in local tracking files
- Work happens in a git worktree

## Repository layout

Tracked (committed):
- `scripts/ralph/` — runner logic
- `.claude/commands/` — optional Claude command wrappers

Local only (gitignored):
- `.ralph/tracking/` — PRD, state, progress, questions
- `.ralph/worktrees/` — git worktrees
- `.ralph/logs/` — execution logs

## Tracking files

Located in `.ralph/tracking/`:

- `PRD.md` — source of truth (checkboxes)
- `state.json` — machine state
- `progress.txt` — append-only log
- `questions.md` — clarification requests
- `answers.md` — user replies

## Running

```bash
chmod +x scripts/ralph/*.sh
./scripts/ralph/ralph.sh
```

Ralph typically produces one working branch per run, suitable for review
and merge.

## Clarifications


1. If Ralph needs input:

2. It stops with NEEDS_CLARIFICATION

3. Questions appear in questions.md

4. Answer in answers.md

5. Re-run the scrip4t

