---
name: install-ralph
description: Use when the user wants to install Ralph into another project, copy ralph to a new repo, set up ralph in a project, or add the ralph tool to an existing codebase. Examples: "install ralph into /path/to/project", "add ralph to my project", "set up ralph in ~/dev/myapp".
version: 1.0.0
---

# install Skill

Copy Ralph into another project repository.

## When This Skill Applies

- "install ralph into <path>"
- "add ralph to my project"
- "set up ralph in <path>"
- "copy ralph to <path>"

## Parameters (parsed from user message)

- `[target-path]` — absolute path to the target project (required)

If `[target-path]` is not provided, ask the user for it before proceeding.

## Execution Steps

### 1. Validate target

Run `RALPH_INSTALL_SCRIPT <target-path>`.

The script handles all validation and copying.

### 2. Post-install guidance

After the script completes successfully, remind the user:

```
Ralph installed. Next steps:
  1. Edit <target>/ralph/ralph.yaml  — set project name, prd filename, test command
  2. Edit <target>/ralph/AGENTS.md   — add project-specific context for agents
  3. Write your PRD (or scaffold it): "create a prd" in Claude Code
  4. Generate a plan: ralph/ralph.sh --mode plan
  5. Run the build:  ralph/ralph.sh --iterations 3
```

## Global Setup (use from any project)

By default this skill only works when Claude Code is open in the ralph source repo.
To trigger it from **any** Claude Code session on this machine, place it in the
user-level skills directory (`~/.claude/skills/`):

```bash
RALPH_REPO="/absolute/path/to/ralphie-ai-agent"   # <-- update this once

mkdir -p ~/.claude/skills/install-ralph

cp "$RALPH_REPO/ralph/skills/install/SKILL.md" ~/.claude/skills/install-ralph/SKILL.md

# Replace the placeholder with the absolute path to install.sh (one-time)
sed -i "s|RALPH_INSTALL_SCRIPT|$RALPH_REPO/ralph/skills/install/install.sh|g" \
   ~/.claude/skills/install-ralph/SKILL.md
```

After this, say **"install ralph into /path/to/my-project"** from any Claude Code session.

> `install.sh` auto-detects its own location via `BASH_SOURCE[0]` — no changes needed
> inside the script. Only the SKILL.md needs the absolute path so Claude knows where
> to find it when invoked outside the ralph repo.

## Key Rules

- Never overwrite `ralph/ralph.yaml` if it already exists in the target project
- Never modify git config in the target repo
- Always use the script — do not manually copy files
