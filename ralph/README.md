# Ralph — Autonomous Claude Loop Runner

Minimal, production-oriented automation loop for Claude Code. Each iteration runs Claude
in a fresh headless process with no chat history. Persistent state lives in tracking files;
work happens in git worktrees.

## Install

```bash
cp -r ralph/ /path/to/new-project/ralph/
# Edit ralph/ralph.yaml for the new project
# Edit ralph/AGENTS.md with project-specific context
```

## Quick Start

```bash
# Sequential loop (build mode, reads from ralph.yaml)
ralph/ralph.sh

# Planning mode: generate IMPLEMENTATION_PLAN.md from PRD
ralph/ralph.sh --mode plan

# Parallel agents (reads agent table from ralph.yaml parallel.agents)
ralph/ralph-parallel.sh

# Background self-improvement agent
ralph/ralph-think.sh

# Fire-and-forget, then check
ralph/ralph-think.sh
tail -f .ralph/logs/think/<latest>.log
```

## Core Options (`ralph.sh`)

| Option | Default | Description |
|--------|---------|-------------|
| `--mode build\|plan` | build | Build: implement tasks. Plan: generate IMPLEMENTATION_PLAN.md |
| `--iterations N` | 10 | Max Claude invocations |
| `--batch-size N` | 5 | Tasks to plan per run |
| `--task-id W##-###` | — | Force a starting task |
| `--timeout-sec N` | 900 | Per-iteration timeout |
| `--verbose` | off | Tail Claude log while running |
| `--dry-run` | off | Print actions without running Claude |
| `--tracking-dir PATH` | .ralph/tracking | Override tracking directory |
| `--branch NAME` | auto | Explicit branch name |
| `--no-tests` | off | Skip test execution |
| `--integrate` | off | Rebase + merge when done |
| `--cleanup` | off | Remove worktree on success |

## Project Config (`ralph/ralph.yaml`)

```yaml
project: myproject
prd: PRD_PROJECT.md      # source-of-truth requirements
merge_into: dev          # default merge target

runner:
  test: "docker build --target test ... && docker run ..."
  build: "docker build --target builder ..."
  dev: "docker compose up"

known_test_failures:
  - "SomeTest"           # pre-existing failures to ignore

parallel:
  agents:
    - label: A
      task: W02-001
      batch: 1
    - label: B
      task: W02-002
      batch: 2
```

## Operational Guide (`ralph/AGENTS.md`)

Agents read `AGENTS.md` every iteration for:
- Exact commands to run for build/test/dev
- Known pre-existing test failures to ignore
- Commit format rules
- Project-specific learnings (agents may append)

Keep it ~60 lines. Not a changelog.

## File Roles

| File | Role |
|------|------|
| `ralph.yaml` | Machine config: commands, parallel plan |
| `AGENTS.md` | Agent operational guide: commands, learnings |
| `PROMPT_build.md` | Agent instructions (build mode) |
| `PROMPT_plan.md` | Agent instructions (planning mode) |
| `IMPLEMENTATION_PLAN.md` | Ralph self-improvement plan (ralph-think.sh) |
| `references/playbook-summary.md` | Bundled best-practice reference |
| `skills/merge-worktree/SKILL.md` | Merge-worktree Claude skill |

## Tracking Files (`.ralph/tracking/`)

| File | Purpose |
|------|---------|
| `PRD.md` | Task checklist — checkbox = done |
| `state.json` | Machine state (run_id, current_task, status) |
| `progress.txt` | Append-only execution log |
| `questions.md` | Agent clarification requests |
| `answers.md` | User answers |

**PRD checkbox is truth**: mark `[x]` only when acceptance criteria are met.

## Clarification Protocol

1. Agent sets `state.json.status = "NEEDS_CLARIFICATION"`
2. Agent writes questions to `questions.md`
3. User answers in `answers.md`
4. Re-run `ralph.sh` to resume

## Directory Layout (runtime, gitignored)

```
.ralph/
├── tracking/          # sequential run tracking
├── runs/
│   └── YYYYMMDD-HHMMSS/
│       └── agents/    # parallel agent tracking
│           ├── A/
│           └── B/
├── worktrees/         # git worktrees
├── logs/
│   └── YYYYMMDD-HHMMSS/
└── worktrees.json     # worktree ownership registry
```

## Dependencies

Required: `bash`, `git`, `python3`, `mktemp`, `date`, `rsync`, `claude` (or `npx`)

Optional: `curl` (for ntfy/slack/discord notifications)

## Git Safety

- Never force-push
- Never modify git config
- Use `git worktree remove --force` (not `rm -rf`) for worktree cleanup
- `git worktree prune` to clear stale entries
