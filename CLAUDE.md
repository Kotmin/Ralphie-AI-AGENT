# CLAUDE.md

This is the **Ralphie** source repository — the portable autonomous loop runner for Claude Code.

See `ralph/README.md` for full tool documentation.

## Developing Ralph

### Running Ralph on this repo's own PRD

```bash
# Basic run (implements tasks from PRD.md)
ralph/ralph.sh

# Planning mode (generates IMPLEMENTATION_PLAN.md from PRD.md)
ralph/ralph.sh --mode plan

# Parallel agents (reads agent table from ralph/ralph.yaml)
ralph/ralph-parallel.sh

# Background self-improvement agent
ralph/ralph-think.sh
```

### Testing Changes

Before committing changes to ralph scripts, verify the loop works:

```bash
# Dry run — prints actions without running Claude
ralph/ralph.sh --dry-run

# Parallel dry run
ralph/ralph-parallel.sh --dry-run
```

## Directory Structure

```
ralph/                          # portable tool dir (cp -r to install)
├── ralph.sh                    # main loop runner
├── ralph-parallel.sh           # generic parallel orchestrator
├── ralph-think.sh              # background self-improvement agent
├── lib.sh                      # shared utilities
├── notify.sh                   # notifications (mock, ntfy, slack, discord)
├── PROMPT_build.md             # build mode agent instructions
├── PROMPT_plan.md              # planning mode agent instructions
├── AGENTS.md                   # agent operational guide template
├── ralph.yaml                  # project config template
├── IMPLEMENTATION_PLAN.md      # ralph self-improvement plan (committed)
├── references/
│   └── playbook-summary.md     # bundled Huntley playbook reference
└── skills/
    └── merge-worktree/
        └── SKILL.md            # merge-worktree skill

PRD.md                          # ralph's own improvement tasks (source of truth)
IMPLEMENTATION_PLAN.md          # ralph's working implementation plan (LLM-generated)
```

## Installing Ralph into Another Project

```bash
cp -r ralph/ /path/to/project/ralph/
# Edit ralph/ralph.yaml with project-specific commands
# Edit ralph/AGENTS.md with project-specific context
```

## Commit Format

```
feat|fix|docs|refactor|test|chore(<scope>): description
```

Rules:
- No AI/Claude mentions in commit messages or trailers
- One commit = one complete, working change

## Key Conventions

- **PRD checkbox is truth**: Mark `[x]` only when acceptance criteria met
- **Git safety**: Never force push, don't modify git config
- **Worktree cleanup**: Use `git worktree remove --force` not `rm -rf`
