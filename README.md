## Ralphie the AI Agent

Why?

This version supports sessions separation. Maybe we add some additional features

# Ralph Loop (Claude Code) — Repo-local automation

This repo contains a minimal “Ralph Wiggum loop” runner for Claude Code.

Core idea:
- Each iteration runs Claude Code in a **fresh headless process** (no accumulated chat context).
- Persistent memory lives in repo files: `PRD.md`, `progress.txt`, `state.json`.

## Requirements
- Linux/macOS
- `git`, `bash`, `python3`
- Claude Code CLI:
  - `claude` (preferred), or
  - `npx -y @anthropic-ai/claude-code` fallback

## Files
- `PRD.md` — source of truth for task completion (checkboxes)
- `progress.txt` — append-only log
- `state.json` — machine state (current task, iteration, status)
- `questions.md` — written by Ralph when clarification is needed
- `answers.md` — edited by you; used to resume after clarification

## PRD format
Tasks must be defined like:

### [ ] US-001: Title
...
### [x] US-001: Title

Ralph marks a task done only by checking `[x]`.

## Run
```bash
chmod +x scripts/ralph/*.sh
./scripts/ralph/ralph.sh
